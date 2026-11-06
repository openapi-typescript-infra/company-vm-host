> Shared-company agent and CI VM infrastructure is implemented separately in
> [`host-service/`](host-service/README.md). It exposes API v1 to independently
> deployed company agents and adds guarded migration from legacy macVM slots.

# mac-runner — provision Macs as isolated, ephemeral GitHub Actions runners

Provisions any Apple-silicon Mac — over SSH or locally — as a fleet of
**ephemeral, org-level** self-hosted GitHub Actions runners, in three
flavors:

- **Linux (arm64) slots** — the runner and the job live entirely inside an
  [apple/container](https://github.com/apple/container) Linux VM that is
  created fresh for each job and destroyed afterward (`--rm`). Jobs cannot
  touch the host at all.
- **Linux (amd64) slots** — the same ephemeral apple/container model, but the
  image is built and run for x86_64 under Rosetta translation, so the runner
  registers as an `x64` runner (`uname -m` → `x86_64`). For jobs that must run
  on amd64. Translation is ~2-5x slower than native arm64.
- **Linux VM slots (docker-capable)** — for Linux jobs that need to run or
  build containers themselves (docker build, testcontainers, compose). Each
  job gets a fresh apple/container **machine** — a lightweight VM booting a
  systemd image with a rootful dockerd inside — created for the job and
  deleted afterward, so jobs share nothing. The guest has qemu binfmt as a
  fallback for amd64-only job containers (`docker run --platform amd64 …`);
  it is slower than Rosetta and has fidelity holes (e.g. postgres), so
  prefer multi-arch images or the amd64 VM slots below.
- **Linux VM slots (amd64)** — a docker-capable slot whose VM is a _full_
  x86_64 guest emulated by QEMU under [Lima](https://lima-vm.io): a true
  amd64 kernel, dockerd, and runner. Use when the runner itself (and
  docker's default platform) must be amd64. Whole-system emulation is slow;
  requires QEMU on the host (`brew install qemu`). These VMs are persistent
  and scrubbed between jobs (processes killed, docker state purged, work
  dir wiped) — weaker job-to-job isolation than the per-job machines.
- **macOS slots** — for jobs that need macOS itself. Each slot runs as its
  own hidden, unprivileged service user (`_ghrunner1`, …); between jobs all
  of the user's processes are killed and its work/temp/cache directories are
  wiped.
- **macOS VM slots** — VM-grade isolation for macOS jobs via
  [Tart](https://github.com/openai/tart): each job gets a fresh
  copy-on-write clone of a base macOS image, and the VM is deleted after the
  job. Max 2 per host (Apple's limit on concurrent macOS VMs).

Every slot is a root LaunchDaemon that loops: **mint a single-use
just-in-time (JIT) runner config from the GitHub API → run exactly one job →
scrub → repeat**. Nothing persistent is ever registered with GitHub, and the
PAT stays in a root-only file that jobs can never read.

## Prerequisites

- Target Mac: Apple silicon, macOS 26+ (required by apple/container; macOS
  slots alone work on older versions), reachable over SSH as an admin user.
- For amd64 Lima VM slots (`LINUXVM_AMD64_RUNNERS > 0`): QEMU on the host
  (`brew install qemu`). No extra prerequisite for amd64 container slots —
  they reuse the Rosetta that apple/container already needs.
- A GitHub token that can create JIT runner configs for the org:
  - **Fine-grained PAT (recommended):** resource owner = your org,
    Organization permissions → **Self-hosted runners: Read and write**,
    nothing else. Give it a short expiry and rotate via re-provisioning.
    If you use warm schedules / on-demand slots (any `*_POLICY`), the same
    PAT additionally needs Repository permissions → **Actions: Read** on the
    repos the dispatcher watches — see "Warm schedules and on-demand slots".
  - Classic PAT with `admin:org` also works but is far more powerful — avoid.

## Quick start

```sh
cp runner.env.example runner.env   # edit: org, slot counts, labels
./provision.sh runner.example.com   # remote Mac over SSH
./provision.sh --local                # or: this Mac (in a pinch)
./provision.sh -b runner.example.com   # detach: bootstrap survives SSH drops
```

Over SSH you'll type the SSH password once (the script multiplexes one
connection), paste the PAT once, and type the remote sudo password once;
`--local` skips straight to the PAT and sudo prompts. Re-run the same
command any time to change slot counts, bump versions, rotate the PAT, or
provision a brand-new Mac. **Note:** re-provisioning restarts all slots,
interrupting any job currently running.

With `-b` the script uploads the payload, takes the PAT and sudo prompts as
usual, then launches the bootstrap detached on the target and returns — the
provision keeps going if the SSH connection drops or your machine sleeps.
Use it whenever the bootstrap will download something big over a slow link
(first macvm image pull, amd64 Lima VM creation). Watch progress and get the
result with:

```sh
ssh runner.example.com tail -f /var/log/ghrunner-bootstrap.log
ssh runner.example.com cat /var/log/ghrunner-bootstrap.status  # exit code; absent while running
```

A second `-b` provision while one is still running is refused (the pid is
in `/var/run/ghrunner-bootstrap.pid`).

Target the runners from workflows:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, arm64] # Linux container slot
    # runs-on: [self-hosted, linux, x64]      # amd64 container slot (Rosetta)
    # runs-on: [self-hosted, linux, arm64, docker]  # per-job machine slot (docker available)
    # runs-on: [self-hosted, linux, x64, docker]    # amd64 Lima VM slot (QEMU)
    # runs-on: [self-hosted, macos, arm64]    # native macOS slot (or VM slot)
    # runs-on: [self-hosted, macos, arm64, vm]  # macOS VM slot only
```

Because runners are ephemeral JIT runners, they only appear in
_Org settings → Actions → Runners_ momentarily between jobs and while busy —
an empty list while idle is normal. Check slot logs on the host for the
"listening for jobs" state.

## What lands on the Mac

| Path                                       | Purpose                                                                                                                                       |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `/opt/ghrunner/bin/run-slot.sh`            | per-slot supervisor (mint JIT → one job → scrub)                                                                                              |
| `/opt/ghrunner/bin/dispatch.sh`            | dispatcher: starts scheduled/on-demand slot cycles (only if a `*_POLICY` is set)                                                              |
| `/opt/ghrunner/bin/slot-lib.sh`            | kind/label/policy/schedule helpers shared by the scripts above                                                                                |
| `/etc/ghrunner/{config.env,github.pat}`    | config + PAT, root-only (0600)                                                                                                                |
| `/var/ghrunner/slots/mac-N/`               | home + runner install for macOS slot N                                                                                                        |
| `/var/ghrunner/tart/`                      | Tart home, images, VM clones, and headless login keychain (only if macvm slots)                                                               |
| `/var/ghrunner/container/`                 | apple/container home: image store, kernels, per-job machines                                                                                  |
| `/opt/ghrunner/linuxvm-image/`             | build context for the docker-capable machine image (linuxvm slots)                                                                            |
| `/var/ghrunner/lima/`                      | Lima home: template + persistent amd64 (QEMU) docker VMs                                                                                      |
| `/usr/local/lima/`                         | Lima (only if linuxvmamd64 slots configured)                                                                                                  |
| `/var/ghrunner/log/*.log`                  | per-slot logs (rotated by newsyslog)                                                                                                          |
| `/var/log/ghrunner-bootstrap.{log,status}` | detached-provision (`-b`) log + exit code                                                                                                     |
| `/Library/LaunchDaemons/com.ghrunner.*`    | one daemon per slot (restarts after every job and on boot, unless dispatcher-managed) plus `com.ghrunner.dispatcher` when policies are in use |
| `/usr/local/bin/container`                 | apple/container (only if Linux slots configured)                                                                                              |
| `/usr/local/tart/`, `/usr/local/bin/tart`  | Tart (only if macvm slots configured)                                                                                                         |

Service users: `_ghrunner1..N` (macOS slots), `_ghcontainer` (owns the
container VMs, machines, and image store), `_ghtart` (owns the Tart VMs and
image store), and `_ghlima` (owns the amd64 Lima VMs). All hidden,
non-admin, random throwaway passwords, no SSH access.

## Isolation model & residual risks

- **Linux jobs (linux slots):** strong isolation — each job runs in a fresh
  lightweight VM with its own kernel, with only the JIT config injected. No
  host filesystem is mounted. Note: no Docker inside the job (no nested
  containers) — that's what linuxvm slots are for. The amd64 (linuxamd64)
  slots share this model; the image and runner are x86_64, translated by
  Rosetta inside the arm64 VM.
- **Linux jobs (linuxvm slots):** strong isolation — each job runs in a
  fresh apple/container machine (its own kernel and dockerd), created for
  the job and deleted afterward, with no host mounts (`--home-mount none`).
  Docker access is root-in-VM, but the VM dies with the job, so there is
  nothing to tamper with for later jobs.
- **Linux jobs (linuxvmamd64 slots):** VM-grade isolation from the _host_
  (no mounts), but consecutive jobs share the persistent QEMU VM and its
  docker daemon — docker access is effectively root-in-VM, so a malicious
  job could tamper with the VM for later jobs in the same slot. The scrub
  between jobs (kill all runner processes, delete all containers/images/
  volumes, wipe work dir) handles the common cases, not a determined
  attacker. Route only trusted, docker-needing jobs here; bump `LINUXVM_*`
  resource values or `RUNNER_VERSION` to force full VM recreation on the
  next provision.
- **macOS jobs (mac slots):** user-level isolation. Jobs run unprivileged and
  can't read other users' files, the PAT, or other slots; the slot is
  process-killed and scrubbed after every job. Residual risk: a malicious job
  shares the kernel with the host and could attack local network services or
  fill the disk. Use a macvm slot for jobs that warrant stronger isolation.
- **macOS jobs (macvm slots):** strong isolation — each job runs in a fresh
  copy-on-write clone of the base Tart image, deleted afterward. With the
  default NAT network the guest's admin/admin credentials are only reachable
  from the host. **Setting `MACVM_BRIDGE_IFACE` gives that up**: the guest
  joins the host's LAN with its own address, so its admin/admin SSH and its
  (enabled-by-default) Screen Sharing are exposed to everything that can
  reach that network. Bridge only onto a network whose reachability you
  control, and change `MACVM_SSH_PASSWORD` from the shipped default if you
  do. See "Reaching macOS VM slots".
  Hard cap of 2 concurrent macOS VMs per host (Virtualization framework /
  macOS EULA), and no nested VMs/containers inside the guest. Since user-level
  mac slots are the only way past the 2-VM cap, both kinds can coexist.
- **JIT configs** are single-use and job-scoped; the org-level PAT is only
  ever read by the root supervisor.
- **The PAT travels through the host's `/usr/bin/curl`**, which trusts
  macOS's `/etc/ssl/cert.pem` and checks no revocation. After the eMudhra CA
  key compromise (Oct 2026), run `./distrust-emudhra.sh` on each host. It
  removes the two affected roots and tests GitHub against the result before
  replacing the file. A macOS update can restore the stock file; re-running
  is safe. The macvm bake runs the same script in the guest.
- Standard advice for self-hosted runners still applies: don't let them run
  jobs from public-repo pull requests; use a restricted runner group.

## Custom Linux runner images (flavors)

Beyond the default Linux slots, `LINUX_FLAVORS` defines extra fleets of
containerized runners with their own images and labels — e.g. a `node20`
fleet targeted with `runs-on: [self-hosted, linux, arm64, node-20]`:

```sh
LINUX_FLAVORS="node20 java21"
LINUX_FLAVOR_node20_RUNNERS=2
LINUX_FLAVOR_node20_BUILD_DIR=examples/node20        # relative to runner.env
LINUX_FLAVOR_node20_LABELS=self-hosted,linux,arm64,node-20
LINUX_FLAVOR_node20_DISK=40G                         # optional per-job scratch
LINUX_FLAVOR_java21_RUNNERS=1
LINUX_FLAVOR_java21_IMAGE=ghcr.io/acme/ci-java21-arm64:latest
LINUX_FLAVOR_java21_LABELS=self-hosted,linux,arm64,java-21
```

- **`_BUILD_DIR` flavors** are shipped with the payload and built on the
  host every provision (layer caching makes unchanged builds fast). The
  bundled base image is always available to `FROM ghrunner-linux:<version>`
  — see `examples/node20/Dockerfile` — which inherits the runner install and
  entrypoint, so your Dockerfile only adds toolchains.
- **`_IMAGE` flavors** are pulled from a registry at provision time. The
  image must satisfy the runner contract: Linux for the flavor's arch
  (default arm64), Actions runner installed, entrypoint that runs
  `./run.sh --jitconfig "$GH_JIT_CONFIG"`.
  Private registries need a one-time manual login as the service user:
  `sudo launchctl asuser "$(id -u _ghcontainer)" sudo -u _ghcontainer -H
/usr/local/bin/container registry login <registry>`.
- **`_ARCH=amd64`** makes a flavor's fleet x86_64, exactly like the
  `linuxamd64` slots (built and run under Rosetta — see "amd64 Linux
  runners"): `_BUILD_DIR` contexts are built with `--arch amd64` and may
  build `FROM ghrunner-linux-amd64:<version>` (always available when an
  amd64 flavor is configured); `_IMAGE` pulls pin `--platform linux/amd64`,
  so the reference must have an amd64 variant. Unlabeled amd64 flavors
  default to the `LINUX_AMD64_LABELS` label set (`x64`, not `arm64`).
- **`_ROSETTA=true`** is an arm64-only Apple Container runtime option for an
  image that must execute isolated x86_64 Linux tools. It keeps the runner,
  Node and JVM native arm64 while translating only those tool processes. It
  is deliberately separate from `_ARCH=amd64`, which translates the entire
  Linux userspace and remains the portable choice for x86 Kubernetes nodes.
- **`_DISK`** gives every job a newly-created named volume of that size,
  mounted at `/ghrunner-scratch` and deleted when the job exits. Images opt
  into it by putting their high-churn paths under that mount. This keeps large
  checkouts/build trees off the container root filesystem without sharing
  state between jobs. A supervisor killed mid-job can leave the volume behind;
  its next cycle removes the leftover before creating a fresh one.

Shipped image contexts build with `LINUX_BUILD_CPUS` (default `4`) and
`LINUX_BUILD_MEMORY` (default `8G`). `LINUX_IMAGE_BUILD_TIMEOUT` defaults to
3600 seconds; raise it for unusually slow hosts or registries.

After a successful provision, the supervisor removes retired images in its
own `ghrunner-linux*` namespace, retaining only tags needed by enabled slots.
This prevents large Android images from accumulating after a flavor is
disabled or a runner version changes. `LINUX_IMAGE_GC=false` disables it;
`LINUX_IMAGE_MIN_FREE_GB` (default `80`) controls the post-cleanup low-space
warning. It deliberately does not call `container image prune --all`, which
could remove unrelated images owned by the container service account.

Flavor slots appear as `com.ghrunner.linux.<flavor>-<n>` daemons with logs
at `/var/ghrunner/log/linux.<flavor>-<n>.log`. Removing a flavor from
`LINUX_FLAVORS` (or lowering its `_RUNNERS`) prunes its daemons on the next
provision.

### Company Android build image

`android-image/` is the portable Linux build environment for
`your-org/your-app`. It is a self-contained OCI image rather than a thin
layer over the host-local `ghrunner-linux` image, so the resulting artifact can
be pushed to a registry and used by a Kubernetes Job. Its default entrypoint
implements this project's JIT runner contract. When arguments are supplied
instead, it initializes scratch storage, drops to UID/GID 1001, and runs those
arguments as a general Android build command; this is the intended Kubernetes
Job contract.

The Android builders have three distinct deployment roles:

| Variant               | Intended deployment                        | Role                                                                          |
| --------------------- | ------------------------------------------ | ----------------------------------------------------------------------------- |
| arm64 Darwin          | Tart `mobile-bake` VM on the runner host   | Primary mobile runner; builds Android and iOS                                 |
| amd64 Linux           | Published `android-image` on Kubernetes    | Portable, native Linux Android runner                                         |
| arm64 Linux + Rosetta | `androidrosetta` flavor on the runner host | Validated fallback; native Node/Java/Gradle with translated x86_64 host tools |

The Dockerfile builds both Linux architectures. Google's Android SDK/NDK and
Hermes still contain x86_64-only Linux host tools: amd64 nodes execute them
natively, while the arm64 image uses Apple Container's Rosetta bridge for just
those processes. The image contains Node, Yarn, Java, EAS, gcloud, the app's
Android compile platform plus the legacy one, both Build Tools, both NDKs (Expo
Updates has been seen selecting the older) and CMake — every version taken from
the repo's `versions.env` (see "Version pins" below), never written into the
Dockerfile. It also carries an inert, headless Cloudflare WARP client for
sites that need their own private route. The Android, gcloud and WARP artifacts
are checksummed, the image records what it was built with in
`/etc/ghrunner-versions.env`, and the build includes a network-free toolchain
verifier that checks the image against that file.

The example configuration documents an optional arm64/Rosetta Linux flavor. Change only its count to activate
the fallback; its resource settings should be chosen for your host:

```sh
MACVM_RUNNERS=1
MACVM_IMAGE=ghrunner-mobile-v5

LINUX_FLAVORS="androidrosetta"
LINUX_FLAVOR_androidrosetta_RUNNERS=0  # set to 1 for fallback capacity
LINUX_FLAVOR_androidrosetta_BUILD_DIR=../android-image
LINUX_FLAVOR_androidrosetta_LABELS=self-hosted,linux,arm64,company-android-rosetta
LINUX_FLAVOR_androidrosetta_CPUS=4
LINUX_FLAVOR_androidrosetta_MEMORY=20G
LINUX_FLAVOR_androidrosetta_DISK=80G
LINUX_FLAVOR_androidrosetta_ARCH=arm64
LINUX_FLAVOR_androidrosetta_ROSETTA=true
LINUX_FLAVOR_androidrosetta_WARP_ORG=your-company
```

Build and smoke-test it directly on a Mac before provisioning. Every pin is a
default-less `ARG`, so the build needs `versions.env` passed as build args
(`provision.sh` does this for flavor builds; by hand, the inline `sed` turns
each line into one — keep it inline, an unquoted variable is not word-split
in zsh):

```sh
container build --arch amd64 --cpus 6 --memory 8G \
  $(sed -n 's/^\([A-Z0-9_]*=.*\)/--build-arg \1/p' versions.env) \
  --tag ghrunner-android-dev:2.335.1 android-image
container run --rm --arch amd64 \
  --entrypoint /usr/local/bin/verify-android-toolchain \
  ghrunner-android-dev:2.335.1
```

Keep the Dockerfile under about 13KB. apple/container caps a Dockerfile at
16384 bytes ([apple/container#735](https://github.com/apple/container/issues/735)),
and from roughly 14KB up the client fails with only
`Stream unexpectedly closed`; `bootstrap.sh` refuses to build past 14KB so the
cause is named. Long explanations belong here, not in the Dockerfile.

On Apple silicon, the `androidrosetta` flavor builds the same image as arm64
and runs it with `--rosetta`. Node/Java/Gradle remain native while the SDK's
`linux-x86_64` NDK/CMake tools and application-locked Hermes compiler are
translated. It has a distinct `company-android-rosetta` label:

```sh
container build --arch arm64 --cpus 6 --memory 8G \
  $(sed -n 's/^\([A-Z0-9_]*=.*\)/--build-arg \1/p' versions.env) \
  --build-arg RUNNER_ARCH=arm64 --build-arg IMAGE_ARCH=arm64 \
  --tag ghrunner-android-rosetta-dev:2.335.1 android-image
container run --rm --arch arm64 --rosetta \
  --entrypoint /usr/local/bin/verify-android-toolchain \
  ghrunner-android-rosetta-dev:2.335.1
```

The image also carries a **Gradle seed** (`/opt/ghrunner-gradle-seed`): at
build time it prebuilds the stock Expo template for the app's SDK
(`EXPO_SDK` in `versions.env`) and runs its release build with the JS bundle
excluded, which fetches the wrapper distribution, the Android Gradle Plugin,
Kotlin, KSP, React Native and Expo module dependencies and populates the
artifact transforms. The entrypoint copies the seed into the job's scratch
Gradle home, so the first Gradle invocation of a job starts warm instead of
downloading ~2GB. Only a real build does this; resolving declared dependencies
alone leaves the compile toolchain and every transform cold (what the v6 macOS
bake did). It is best-effort and never fails the build; check the
`gradle seed:` size in the build log, and pass `--build-arg GRADLE_PREWARM=none`
to skip it. The template lacks the app's third-party native SDKs (Agora,
Braze, Stripe...), which still download per job.

Cross-job persistence for this image is by **remote caches**, not volumes: a
Kubernetes node has nothing to share between jobs, and Gradle's own state
does not survive being copied between runs (see the macvm notes in
`run-slot.sh`). Both are opt-in through the container environment and inert
otherwise:

| Env                                                                                                             | Effect                                                                                                                                                                                                                                              |
| --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CCACHE_REMOTE_STORAGE` (e.g. `redis://cache:6379` or `http://cache/ccache`)                                    | The entrypoint routes the NDK C++ compile through ccache (`CMAKE_{C,CXX}_COMPILER_LAUNCHER`) with a per-job local cache in scratch and this remote tier. Also enabled by a `/ghrunner-cache/ccache` mount, for a host directory on the runner host. |
| `GRADLE_REMOTE_CACHE_URL` (+ optional `GRADLE_REMOTE_CACHE_USER`/`_PASSWORD`, `GRADLE_REMOTE_CACHE_PUSH=false`) | An init script in the job's Gradle home adds this HTTP build cache (a `gradle/build-cache-node` deployment works) as the remote tier of the already-enabled build cache.                                                                            |

The NDK compile matters most: with a warm Gradle build cache it is about
three quarters of the remaining Gradle time (seven modules x four ABIs), and
AGP's native build tasks are not build-cacheable, so ccache is the only thing
that reuses it.

The Android image places the Actions checkout, EAS local staging directory,
Gradle state, setup-node/setup-java tool cache, XDG cache and temporary files
under `/ghrunner-scratch`. Outside this runner supervisor, mount sufficiently
large ephemeral storage there, leave the entrypoint intact, and supply the
build command as container arguments; the root entrypoint fixes volume
ownership and immediately drops to UID/GID 1001. If a platform overrides the
entrypoint, it must arrange equivalent ownership and environment setup. Do not
bake GCP, Expo, signing or registry credentials into the image; the existing
workflow obtains them at job runtime.

the runner host itself does not route the company's private `10.42.0.0/16` network, and an
apple/container guest does not inherit a host VPN in any case. Setting the
flavor's `_WARP_ORG` makes `run-slot.sh` grant only `CAP_NET_ADMIN` and pass the
host's root-only WARP service token through a temporary env file. The image
enrolls and connects before the build, retains the required policy as a
root-only file, removes the token from the job environment, and best-effort
deregisters on exit. The Android build user intentionally has no `sudo` access,
so job steps cannot read that policy. When the outer container interface is
only 1280 bytes (as on apple/container), the entrypoint lowers the WARP TUN to
1200 to leave room for WireGuard encapsulation; without that adjustment,
larger HTTPS requests can disappear into a path-MTU black hole while small
health checks still succeed. Leave
`_WARP_ORG` unset in Kubernetes when the node network already reaches the
private routes; the same image then starts no VPN process and needs no added
capability.

A persistent [Cloudflare Mesh](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/)
node is the natural next step if several disposable container flavors need
private routing or per-job device enrollment becomes noisy. For one the runner host
slot it adds more machinery than it removes: a persistent Linux gateway,
forwarding/NAT between apple/container's guest subnet and that gateway, and
Cloudflare-side Mesh route/profile state. Mesh is also currently beta. Keep the
direct opt-in client until those operational costs are justified.

The Rosetta runner completed a full manually dispatched `mobile-apps` EAS
build, including GraphQL code generation, native compilation, Sentry source
map upload and AAB artifact upload. React Native's generated Gradle project
must select `/opt/hermes/build/bin/hermesc` in its post-prebuild hook when that
path exists; Darwin and ordinary amd64 Linux builds are unaffected by that
conditional. Production mobile workflows can remain on the primary macOS VM
label while this flavor stays at zero as fallback capacity.

## amd64 (x86_64) Linux runners

Apple silicon is arm64, so amd64 runners are emulated. Two independent knobs
cover the two Linux flavors — set either or both:

```sh
LINUX_AMD64_RUNNERS=2         # ephemeral apple/container slots, x86_64 image
LINUXVM_AMD64_RUNNERS=1       # full x86_64 QEMU VM, docker-capable
LINUX_AMD64_LABELS=self-hosted,linux,x64
LINUXVM_AMD64_LABELS=self-hosted,linux,x64,docker
```

Target them with `runs-on: [self-hosted, linux, x64]` (or add `docker` for
the VM slots). Both register as genuine x64 runners (`RUNNER_ARCH=X64`,
`uname -m` → `x86_64`).

- **`linuxamd64` (container):** the bundled Dockerfile is built with
  `container build --arch amd64` (pulling the amd64 Ubuntu base and the
  `actions-runner-linux-x64` tarball) and run with `container run --arch
amd64`. Rosetta 2 — already required by apple/container's builder —
  translates x86*64 in userspace inside the arm64 VM. Image:
  `ghrunner-linux-amd64:<version>`. Resources default to the `LINUX**`values; override with`LINUX_AMD64_CPUS`/`LINUX_AMD64_MEMORY`. Fastest
  amd64 option (~2-5x native), best for jobs that just need to *be\* amd64.
  Needs a custom toolchain image too? Flavors take `LINUX_FLAVOR_<f>_ARCH=amd64`
  — see "Custom Linux runner images (flavors)".
- **`linuxvmamd64` (QEMU VM):** a full x86*64 guest under QEMU whole-system
  emulation — the kernel, dockerd, and runner are all truly amd64, and
  docker builds amd64 by default without `--platform`. Slower than Rosetta,
  but the only option when you need a real amd64 kernel or amd64-native
  docker. **Requires QEMU on the host:** `brew install qemu` (bootstrap
  aborts with instructions if it's missing). Resources default to the
  `LINUXVM*\*`values; override with`LINUXVM_AMD64_CPUS`/`LINUXVM_AMD64_MEMORY`/`LINUXVM_AMD64_DISK`. First provision is slow:
  QEMU downloads and installs Ubuntu + docker under emulation.

For the middle ground — an arm64 job that occasionally runs amd64 _containers_
(`docker run --platform amd64 …`) — the arm64 linuxvm machines ship qemu-user
binfmt, so their dockerd can run amd64 images without an amd64 slot. Caveats:
qemu user emulation is markedly slower than the Rosetta translation the old
Lima-based slots had, and some software does not survive it (postgres's
`pg_ctl` is a known casualty). Prefer multi-arch images where they exist, and
route jobs that genuinely depend on amd64-only images to the linuxvmamd64
slots.

## Toolchains on macOS slots

Slot users are unprivileged, so jobs see exactly what any other user on the
Mac can see: **machine-wide installs work, per-user installs don't.**

- Works as-is: `/Applications/Xcode.app` (accept the license once:
  `sudo xcodebuild -license accept`), Homebrew in `/opt/homebrew` (jobs can
  run brew-installed tools; they can't `brew install`), system-wide gems
  (`sudo gem install fastlane cocoapods` → `/Library/Ruby/Gems`).
- Invisible to slots: anything under another user's home — rbenv/asdf
  installs, `~/Library/Android/sdk`, user-level gem dirs. Move these to a
  shared location (e.g. Android SDK to `/opt/android-sdk`).
- Wire up PATH and env via `runner.env` (the runner's native `.path`/`.env`
  mechanism): `MAC_EXTRA_PATH=...` prepends to the job PATH, and each
  `MAC_ENV_<NAME>=value` becomes an env var (e.g. `MAC_ENV_ANDROID_HOME`,
  `MAC_ENV_LANG=en_US.UTF-8` — fastlane wants a UTF-8 locale).
- By default every job starts with cold caches (the scrub wipes
  `~/Library/Caches`). For mobile CI that means re-fetching pods/gems per
  job; set `MAC_KEEP_CACHES=true` to trade a little job-to-job hygiene for
  speed.

For a heavyweight, reproducible toolchain, consider a macvm slot with a
tooling image instead (e.g. `ghcr.io/cirruslabs/macos-tahoe-xcode:latest`,
which ships Xcode/brew/common mobile tooling) — the toolchain is versioned
with the image and every job gets it fresh.

macvm slots take the same `.path`/`.env` treatment through
`MACVM_EXTRA_PATH` and `MACVM_ENV_<NAME>`, which are kept separate from the
`MAC_*` pair because they name paths inside the guest rather than on the
host. A guest job's shell is non-interactive and inherits very little, so
two settings matter for iOS work:

- `MACVM_ENV_LANG=en_US.UTF-8` is effectively required. Without a UTF-8
  locale Ruby falls back to ASCII-8BIT and CocoaPods aborts in
  `unicode_normalize`. `expo prebuild` only _warns_ when `pod install`
  fails, so the visible symptom is a confusing `'ios/ExampleDev.xcworkspace'
does not exist` from `xcodebuild` minutes later.
- `MACVM_EXTRA_PATH` restores dirs `path_helper` would otherwise have added;
  without it `/usr/local/bin` (`warp-cli`) and `/opt/homebrew/bin` are off
  the job PATH.

A macvm job otherwise starts with exactly the caches its image baked in, and
loses whatever it adds when the VM is deleted. `MACVM_KEEP_CACHES=true`
keeps a per-slot host directory (`/var/ghrunner/cache/macvm-<n>`), shares a
clone of it into the guest over virtiofs (`tart run --dir`) and, before the
runner starts, redirects the guest's cache paths onto it:

| In the guest                                                                                                                                                                               | Persisted as                     | How                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `~/Library/Caches/CocoaPods`, `~/.cocoapods/repos`                                                                                                                                         | `cocoapods/`, `cocoapods-repos/` | symlink                                                                                                                                                                                                                                  |
| `~/.yarn/berry/cache` (Yarn's global cache, when a repo enables it)                                                                                                                        | `yarn/`                          | symlink                                                                                                                                                                                                                                  |
| `~/.npm`                                                                                                                                                                                   | `npm/`                           | symlink                                                                                                                                                                                                                                  |
| `~/.gradle/caches/{modules-2,build-cache-1,jars-9}`, `~/.gradle/wrapper` (dependency, build and wrapper caches; the slot turns on `org.gradle.caching` in the guest's `gradle.properties`) | `gradle/`                        | rsync mirror of these content-addressed stores only: synced in at boot, back after the job. The live user home stays on the guest disk, since Gradle's binary stores break on virtiofs and its transform workspaces reject merged copies |
| ccache                                                                                                                                                                                     | `ccache/`                        | `CCACHE_DIR` (+ `CCACHE_MAXSIZE=20G`, and `CCACHE_BINARY` when the image has ccache) in the runner `.env`                                                                                                                                |
| runner tool cache (setup-node downloads etc.)                                                                                                                                              | `toolcache/`                     | `RUNNER_TOOL_CACHE` in the runner `.env`                                                                                                                                                                                                 |
| anything else a workflow wants kept                                                                                                                                                        | —                                | `GHRUNNER_CACHE_DIR` names the share                                                                                                                                                                                                     |

A share subdirectory that does not exist yet is seeded from the image's copy
of that path, so a fresh host starts as warm as the image. Any of the env
defaults yields to a `MACVM_ENV_<NAME>` of the same name. The setup is
non-fatal: if the share is not mounted or not writable the slot logs a
WARNING and the job runs on the image's caches as before.

The guest never writes the kept copy directly. The slot directory holds
`canonical/` (what the next cycle starts from), `work/` (this cycle's APFS
clone of it, made with `cp -c` at boot, instant and costing no disk until
the job changes something; this is the directory actually shared into the
guest) and `prev/` (the canonical before the last promotion). When the
runner exits, `work/` is promoted to `canonical/` only if the job ran to
completion: Succeeded and Failed both count, since a red build still leaves
valid dependencies and ccache objects behind. A cancelled job, a killed
runner or a VM that died mid-job leave half-written files on the share, so
their `work/` is discarded instead. That is what stops one bad cycle from
poisoning the slot for every later job, the trade-off `MAC_KEEP_CACHES`
still makes. The runner's exit status does not carry the job result, so the
slot reads it from the runner's own "completed with result" line.

`mise run runner:caches` shows sizes (du counts each clone at full size, so
read the per-store lines under `canonical/`); `runner:caches clear [n]`
wipes canonical and prev; `runner:caches rollback n` swaps canonical and
prev to undo the last promotion (run it again to swap back). Because
seeding comes from the image only, a slot added later starts colder than
its siblings (no ccache, no tool cache, only the image's Gradle stores);
`runner:caches seed 1 2` clones slot 1's canonical onto slot 2. `seed` and
`rollback` refuse while an affected slot is mid-job and restart an idle
cycle of the changed slot so its next boot clones the new canonical.
Pruning a slot (lowering `MACVM_RUNNERS`) removes its `work/` and `prev/`
but keeps `canonical/`, so the slot comes back warm if the count goes up
again; `clear n` is the explicit way to drop it for good.

For React Native / Expo iOS builds the big win is ccache: add
`MACVM_ENV_USE_CCACHE=1` (the app's Podfile reads it at `pod install` and
routes the compile through the wrappers), bake `ccache` into the image, and
let the slot export `CCACHE_BINARY` (it does so automatically when the guest
has ccache on PATH: React Native's wrappers read that variable from the
environment, and Xcode does not pass the build setting of the same name to
compile tasks, so without it the wrappers silently run plain clang). For the
Android NDK compile, which Gradle's build cache cannot cover, set
`MACVM_ENV_CMAKE_C_COMPILER_LAUNCHER` and `MACVM_ENV_CMAKE_CXX_COMPILER_LAUNCHER`
to the ccache binary: CMake reads them at configure time. Add
`MACVM_ENV_CCACHE_SLOPPINESS=pch_defines,time_macros` as well: a third of the
NDK compiles consume a precompiled header, and ccache refuses those ("could
not use precompiled header" under Uncacheable calls in `ccache -s -v`) unless
told to tolerate the PCH's macros and time stamps in its hash. Then
pin `eas build --local`'s staging dir with `MACVM_ENV_EAS_LOCAL_BUILD_WORKINGDIR`
so compile command lines are identical from job to job (EAS otherwise stages
each build under a fresh uuid path, and ccache hashes those paths). Pair it
with `MACVM_ENV_EAS_LOCAL_BUILD_SKIP_CLEANUP=1`: the plugin's end-of-build
`rm -rf` of the staging dir is pointless in a throwaway VM and, on the fixed
path, has failed the step with `ENOTEMPTY ... rmdir .../build/.git` after a
successful build (something, most likely Watchman, wrote into `.git` while
the delete ran). The plugin refuses a non-empty staging dir, so this assumes
one `eas build --local` per job, which is how the mobile-apps workflows are
laid out. `envs/example.env` has the worked example.

## Baking a custom macOS VM image

When the stock cirruslabs images don't cover your stack, bake your own:

```sh
cp -R examples/macos-tooling my-bake     # edit bake.env + scripts/*.sh
./bake-image.sh -d my-bake runner.example.com
```

`bake.sh` clones `BAKE_BASE_IMAGE`, boots it headless, runs each
`scripts/*.sh` inside the guest over SSH (lexical order, as the admin user,
passwordless sudo available), shuts it down, and saves the result as a
local image named `BAKE_IMAGE_NAME`. Then point the macvm slots at it:

```sh
MACVM_IMAGE=ghrunner-macos-tooling-v1    # in runner.env
./provision.sh runner.example.com
```

Notes:

- The bake pauses macvm slot daemons while it runs (macOS 2-VM limit) and
  resumes them afterwards — bake when the queue is quiet, since pausing
  interrupts a running job.
- `-b` detaches the bake on the target and returns immediately, so a slow
  bake (first base-image pull, big toolchain install) survives SSH drops and
  this machine sleeping — the same flag `provision.sh` takes:
  ```sh
  ./bake-image.sh -d my-bake -b runner.example.com
  ssh runner.example.com tail -f /var/log/ghrunner-bake.log
  ssh runner.example.com cat  /var/log/ghrunner-bake.status   # exit code; absent while running
  ```
- Each guest script has a controller-side deadline
  (`BAKE_SCRIPT_TIMEOUT_MIN`, default 120). If a guest process keeps its SSH
  channel open past that limit, the bake fails, deletes the temporary VM, and
  restores the paused runner slots instead of taking the host offline
  indefinitely.
- `BAKE_DISK_SIZE_GB` grows the image's disk (the cirruslabs images ship
  140 GB). Every job VM is a clone of the image, so this is each job's disk.
  The bake grows the work VM before it boots; the image's tart-guest-agent
  expands the APFS container at boot, and the bake waits for that and fails
  if the container did not grow. Job clones then boot full size. Growing live only works when the container
  is the last partition, as in the cirruslabs Tahoe images; an image with a
  recovery partition after it fails the bake (see
  [Tart's FAQ](https://tart.run/faq/#disk-resizing)). The disk is sparse, so
  the host pays only for what jobs write, but size host free space for every
  macvm slot filling its disk at once.
- Set env for jobs (`ANDROID_HOME`, `JAVA_HOME`, custom `PATH`, …) by
  appending to `/etc/zshenv` in a bake script. The runner starts in the
  guest as a non-interactive `zsh -c`, which sources `/etc/zshenv` but not
  login profiles, so that is where exported vars reach every job step.
  `examples/macos-tooling` is fastlane + cocoapods only; the `mobile-bake`
  dir is the your-org/your-app image (adds jq, Watchman, xcpretty, Node,
  the Android SDK with NDK/CMake, and Maestro), wired up this way.
- Cache warming (macvm slots get a fresh VM per job, so only home-dir caches
  baked into the image survive): `mobile-bake` pre-fetches the Gradle wrapper
  distribution with no auth, and — when `BAKE_PRIME_TOKEN` is set in the
  bake shell — clones the app and warms the Android/iOS native dependency
  caches (`~/.gradle`, `~/.cocoapods`) into the image. Any `BAKE_PRIME_*` var
  is streamed into the guest bake scripts over SSH stdin, so credentials do
  not appear in the host's process list. GCP registry auth is required at bake
  time. VPN-only GraphQL codegen is skipped by default because bake VMs are
  intentionally not WARP-enrolled; set `BAKE_PRIME_WITH_CODEGEN=1` only when
  the guest has a verified private route.
- Two bake dirs, one set of scripts: `ios-bake` is `mobile-bake` **without the
  Android toolchain**, staged for when Android builds move to a dedicated
  runner. Its `scripts/` are symlinks into `mobile-bake/scripts` (the payload
  tar dereferences them), and the only real difference is
  `BAKE_WITH_ANDROID=0` in its `bake.env`, which those scripts read — so the
  two images cannot drift. `BAKE_WITH_*` vars are forwarded into the guest
  like `BAKE_PRIME_*`, and default to on, so `mobile-bake` is unaffected.
  ```sh
  BAKE_DIR=ios-bake mise run runner:bake        # -> ghrunner-ios-v1
  ```
  Dropped: cmdline-tools, platforms android-36/35, build-tools, NDK, CMake,
  the Gradle wrapper prefetch, the `~/.gradle` warm, and the
  `ANDROID_HOME`/`ANDROID_SDK_ROOT`/`ANDROID_NDK_HOME` exports — several GB of
  image and a good slice of bake time. **Kept:** Temurin 17 and Maestro, which
  only look Android-only; Maestro is a JVM tool driving an iOS simulator.
  `ghrunner-ios-v1` has never been baked — verify it and get a green iOS build
  out of it before pointing `MACVM_IMAGE` at it.
- Treat images as immutable: to update tooling, bump `BAKE_IMAGE_NAME`
  (e.g. `-v2`), re-bake, update `MACVM_IMAGE`, re-provision. Old images can
  be removed with `tart delete <name>` (asuser wrapper).
- Pin what the bake pulls, or the same scripts produce a different image
  next month. `mobile-bake`/`ios-bake` reference the cirruslabs base by
  **digest** (`ghcr.io/...@sha256:...`; tart takes a digest or a tag, not
  both — `bake.env` records which tag it was and how to look up another).
  Every toolchain version the scripts install — Node/Java majors, the Android
  SDK packages, the Gradle wrapper, the Maestro CLI (the installer otherwise
  takes the newest) — comes from the repo's `versions.env` (see "Version
  pins" below), which `bake-image.sh` ships with the payload and the scripts
  source in the guest; the scripts assert what they installed against it.
  Homebrew formulae still float within their major; a bake log records what
  they resolved to.
- **Version pins live in one file, `versions.env`**, read by the bake scripts,
  the `android-image` Dockerfile (as `--build-arg`s) and its verifier. The
  "synced" block mirrors what `your-org/your-app` declares — Node in its
  install-build action, Yarn in `packageManager`, Java in its eas-build-ship
  action, compileSdk in `app.config.ts`, Build Tools and NDK in React Native's
  `gradle/libs.versions.toml`, the Gradle wrapper in Expo's prebuild template —
  and `./derive-versions.sh` regenerates that block from a checkout, fetching
  the two package-sourced values from the npm registry when the checkout has
  no `node_modules`. `mise run runner:pins` diffs it against `versions.env`
  and checks the tools this repo pins on its own cadence (Maestro, gcloud, EAS
  CLI) still satisfy the minimums `scripts/doctor.sh` and `eas.json` state.
  It is a diff, not an auto-bump: moving a pin is a `BAKE_IMAGE_NAME` bump and
  a re-bake, and for Maestro a suite run. The deep prime then closes the loop
  at bake time: after the warm build, `20-prime-repo.sh` prints a **pin
  check** next to the cache summary comparing `versions.env` with what that
  checkout and build actually used — the installed React Native's catalog,
  the wrapper `expo prebuild` wrote, the NDK Gradle logged while configuring,
  and the CMake binary AGP ran (from the generated project's `.cxx/`). `DRIFT`
  there means the file is stale; the image still works.
- The images and the runtime caches are complementary: the bake prime is
  what a _first_ job on a host sees, `MACVM_KEEP_CACHES` (see "Toolchains on
  macOS slots") is what keeps every job after it warm and survives re-bakes.
- **Baked images live in `_ghtart`'s home (`/var/ghrunner/tart`), so
  `uninstall.sh` destroys them** — it deletes the service users and
  `rm -rf /var/ghrunner`. Re-provisioning is safe (it never touches the image
  store), but anything that has been uninstalled needs a re-bake before a
  slot can use its image, or the slot fails with `tart clone failed`.
- Debugging a build is far faster in a hand-driven guest than through
  Actions: job VMs are ephemeral, so every attempt pays a cold cache
  (~30+ min for this app). Clone the image, `tart run --net-bridged=<iface>`,
  drop an SSH key into the guest, and iterate over the LAN; fold what you
  learn back into the bake scripts and re-bake once at the end.
- The baked image only exists on that host; bake per host, or `tart push`
  it to a registry and use the registry ref as `MACVM_IMAGE`.
- Smoke-test an image before wiring it to slots (no runner registered):
  ```sh
  ./verify-macvm.sh runner.example.com ghrunner-mobile-v1
  ```
  Clones it to a throwaway VM, boots it, and prints the tooling + env a job
  would see (checks run over a non-interactive `ssh`, i.e. the same
  `zsh -c`/`/etc/zshenv` path the runner uses), then tears it down. Defaults
  to `MACVM_IMAGE` from the config if no image is given; pauses macvm slots
  while it runs.

### Application-specific private registry and VPN access

Configure private package access and internal API routes for your own application.
The mobile image includes the gcloud CLI for projects using Artifact Registry;
provide short-lived credentials in the job rather than baking them into an image.
Projects using a different registry should supply their own authentication flow.

If code generation or dependency installation needs private network access,
configure the appropriate WARP organization and service token explicitly. There
is no default organization. Verify the actual endpoints and network requirements
for your application before enabling this integration.

So guests that lack a private network route enroll in Cloudflare WARP at boot.
The macvm image ships `warp-cli` **unregistered on purpose**: a registration
identifies one device, so a baked one would be shared by every clone and would
break for all of them the moment that device were deleted. `run-slot.sh` writes
`/Library/Managed Preferences/com.cloudflare.warp.plist` into each guest and
enrols it, using a service token kept on the host:

```sh
WARP_AUTH_CLIENT_ID=... WARP_AUTH_CLIENT_SECRET=... ./provision.sh runner.example.com
```

That lands root-only in `/etc/ghrunner/warp.env`, so rotating the token is a
re-provision rather than a re-bake; the non-secret org name is
`MACVM_WARP_ORG` or a flavor's `_WARP_ORG` in the env config. macvm enrollment
is deliberately non-fatal — a bad token logs a `WARNING` in the slot log
instead of putting launchd into a crash-loop. An opted-in Linux flavor fails
before accepting a job when WARP cannot connect because its private route is
part of that flavor's declared build environment.

Three traps worth knowing if enrolment misbehaves:

- **"Connected" is not "healthy".** Right after enrolment `warp-cli status`
  reports `Network: unstable` for anywhere from ten seconds to several
  minutes, and traffic through the tunnel can stall in that window (npm's
  audit POST took up to 3 minutes on cold-boot canaries while plain GETs to
  the same host were fine). `run-slot.sh` waits up to `MACVM_WARP_SETTLE_MAX`
  seconds (default 90) for `Network: healthy` before starting the runner,
  logs how long it took, and starts anyway if it never arrives.

- **The WARP daemon only attempts service-token auth on a fresh start.** If it
  started before the plist existed it caches "no registration", and later
  `registration new` calls return without ever calling Access. `run-slot.sh`
  therefore `launchctl kickstart -k`s the daemon after writing the plist.
- Zero Trust needs a Service Auth rule under _Settings → WARP Client → Device
  enrollment permissions_, as its **own Allow policy with no identity-based
  Require conditions** — a service token cannot satisfy those. When it is
  missing the daemon logs `Access JWT redirect did not include 'token' query
parameter` and helpfully asks `Is Service Auth allowed in Device Enrollment
Rules in the Dashboard?`. Check the policy without a VM:
  ```sh
  curl -sS -D- -o/dev/null \
    -H "CF-Access-Client-Id: $ID" -H "CF-Access-Client-Secret: $SECRET" \
    https://<team>.cloudflareaccess.com/warp
  ```
  A working policy 302s to `com.cloudflare.warp://...auth?token=<jwt>`; a
  broken one redirects to the interactive login page.

Guest disk is worth watching: a full iOS build needs ~21GB, and the baked
image leaves ~47GB free of the base image's 130GB volume.

## Reaching macOS VM slots

By default a macvm guest sits on Tart's NAT network (192.168.64.x) and is
reachable only from its host. That is fine for running jobs — the slot
supervisor talks to it over SSH — but it means nobody can attach to a build
that is misbehaving.

Setting `MACVM_BRIDGE_IFACE` to a host NIC bridges guests onto that NIC's
network instead, so each takes its own DHCP lease. `tart run
--net-bridged=list <any-vm>` lists the interfaces that qualify; en0 is
usually Ethernet and en1 Wi-Fi, and Wi-Fi does work despite the usual
warnings about bridging over 802.11.

Set `MACVM_MAC_1` (and `MACVM_MAC_2` for a second slot) to unique,
locally-administered unicast addresses such as `02:47:48:52:00:01`. Tart
normally assigns a new random MAC to every clone; because these VMs are
deleted and recreated for every job, that can rapidly consume DHCP leases.
A stable address also lets the network administrator create a DHCP
reservation, making the slot's DNS and Screen Sharing address dependable.
Keep the values unique across all runner hosts.

Each guest is then named `<host>-vm-<slot>` — `runner-vm-1`, `runner-vm-2`
— matching the runner names that appear in GitHub. On a network that
auto-registers DNS from DHCP, that makes them reachable by name, e.g. Screen
Sharing to `runner-vm-1.example.com` (cirruslabs images ship with Screen
Sharing enabled; log in as `MACVM_SSH_USER`/`MACVM_SSH_PASSWORD`). The names
are fixed per slot, so they can be handed out before anything boots. Each
slot logs the name it registered when the runner starts:

```
starting macOS VM runner 'runner-macvm-1-a3f9' in ghrunner-vm-1 (192.168.50.209, screen sharing at runner-vm-1)
```

The VM only exists while a job is running — it is deleted at job end, and
the next job gets a fresh clone under the same name.

Two caveats. The naming happens over SSH after boot, so for the first few
seconds a guest is in DNS under the image's baked hostname; two slots
starting together briefly collide there before both settle. And bridging
puts guests on a real network with the image's default credentials — read
the bullet under "Isolation model & residual risks" before enabling it.

## Warm schedules and on-demand slots

An always-on slot buys instant job pickup at the cost of idle resources —
for VM kinds that is real memory (an idle 8G macvm guest genuinely holds
~8G) and, for macvm, one of the host's two macOS-VM seats. A per-kind
`*_POLICY` in `runner.env` trades some job-start latency for those
resources:

- `always` (default) — the slot loops on KeepAlive and a runner listens
  around the clock. Exactly today's behavior.
- `scheduled` — the slot is warm (always-listening) inside its warm
  schedule; outside it the slot is fully torn down and a small dispatcher
  daemon boots it only when a matching job queues.
- `ondemand` — never warm; every cycle is demand-booted.

```sh
MACVM_POLICY=scheduled
WARM_SCHEDULE="Mon-Fri 08:00-19:00"      # host-local time; quote it
DISPATCH_REPOS="mobile-apps"             # repos watched for queued jobs
```

Any kind takes a policy the same way (`MAC_POLICY`, `LINUX_POLICY`,
`LINUX_AMD64_POLICY`, `LINUXVM_POLICY`, `LINUXVM_AMD64_POLICY`,
`LINUX_FLAVOR_<name>_POLICY`), and `<KIND>_WARM_SCHEDULE` overrides the
global schedule per kind. Schedules are comma-separated
`Days HH:MM-HH:MM` entries — `Day` or `Day-Day` (Mon..Sun, ranges may wrap:
`Fri-Mon`), `24:00` meaning midnight; a window must not cross midnight
(split it into two entries).

How it works, in terms of the existing machinery:

- Managed slots are deployed **without** `KeepAlive`; the
  `com.ghrunner.dispatcher` daemon starts their cycles instead. Inside the
  warm window it keeps every slot of the kind running, so behavior matches
  `always` (job-to-job restart can lag up to `DISPATCH_INTERVAL` instead of
  launchd's 15s).
- Each cycle's runner gets an **idle deadline** from `run-slot.sh`: a warm
  runner listens until the window closes, a demand-booted one for
  `DISPATCH_IDLE_TIMEOUT` (default 10 min). A runner that hasn't taken a
  job by then is retired through the kind's normal teardown — that is what
  shuts the VM down for the night. A runner the GitHub API reports busy is
  never killed; jobs always run to completion, even past the window close.
- While any managed slot is cold, the dispatcher polls the `DISPATCH_REPOS`
  every `DISPATCH_INTERVAL` (default 60s) for queued jobs at least
  `DISPATCH_MIN_QUEUE_AGE` (default 30s) old — younger jobs are usually
  about to be taken by an already-listening runner elsewhere — whose labels
  fit a cold kind, and kickstarts just enough slots to cover them. A slot
  booted for a job that evaporates (taken by another host, run cancelled)
  retires itself after the idle timeout.

Expect a cold macvm pickup to cost the poll interval plus the full cycle
setup — clone, boot, WARP enrollment, runner install — about 2–3 minutes
from queue to job start. `linuxvmamd64` is the slow extreme: its persistent
QEMU VM is stopped when the slot retires idle, and a cold boot under
whole-system emulation takes many minutes. For `mac` slots a policy frees
no resources (there is no VM); it only limits when jobs run.

Two PAT notes: demand polling reads workflow runs/jobs, so the PAT needs
repository **Actions: Read** on the watched repos in addition to the org
self-hosted-runners write (bootstrap probes the first watched repo and
warns if the token can't see it). Leaving `DISPATCH_REPOS` empty falls back
to scanning the org's `DISPATCH_REPO_LIMIT` most recently pushed repos each
pass — it works, but it is API-hungrier and can miss a rarely-pushed repo,
so set the list explicitly where you can.

Multiple hosts can run dispatchers against the same org; they coordinate
only through GitHub's job queue, so two cold hosts may occasionally both
boot for one job — the loser retires after the idle timeout. Dispatcher
activity lands in `/var/ghrunner/log/dispatcher.log`
(`mise run runner:logs dispatcher`).

## Operations

If you have [mise](https://mise.jdx.dev), `mise-tasks/runner/` wraps the
common administration against a host, so none of the SSH and service-user
incantations below have to be typed by hand:

```sh
mise tasks                        # list them all
mise run runner:status            # config, slot daemons, VMs, disk
mise run runner:slots             # which slot daemons are loaded
mise run runner:logs macvm-1      # follow a slot log (no arg: list them)
mise run runner:restart macvm-1   # force-restart a slot
mise run runner:vms               # running VMs + their Screen Sharing URLs
mise run runner:vnc 1             # tunnel macvm-1 to vnc://localhost:5901
mise run runner:caches            # persistent macvm cache sizes; 'clear [n]', 'seed 1 2', 'rollback n'
mise run runner:fleet             # runners as GitHub sees them
mise run runner:tart list         # tart/container/limactl as the right user
mise run runner:container ls
mise run runner:lima list
mise run runner:ssh               # shell on the host (args run as a command)
mise run runner:provision         # provision.sh -b with the right config
mise run runner:verify            # verify-macvm.sh
mise run runner:bake              # bake-image.sh -b
mise run runner:pins              # diff versions.env against a mobile-apps checkout (runs locally)
```

Bridged macVMs (the normal mode) are directly reachable — `runner:vms`
prints their DNS name and `vnc://` URL. `runner:vnc` is for the NAT fallback
(`MACVM_BRIDGE_IFACE` cleared), where guests are reachable from the runner
host but not from the LAN: it resolves the slot's current private address and
keeps a stable, localhost-only Screen Sharing endpoint, so VM recreation does
not change the operator workflow. Keep the task running while Screen Sharing
is connected.

Which host they target comes from three variables in `mise.toml` —
`GHRUNNER_ENV` (which `envs/<name>.env` to read), `GHRUNNER_HOST` and
`GHRUNNER_USER`. Override them for another host without adding any tasks:

```sh
GHRUNNER_ENV=otherbox GHRUNNER_HOST=other-runner.example.com mise run runner:status
```

The equivalent by hand:

```sh
ssh runner.example.com
tail -f /var/ghrunner/log/linux-1.log        # watch a slot
sudo launchctl list | grep com.ghrunner      # slot daemons
sudo launchctl kickstart -k system/com.ghrunner.mac-1   # force-restart a slot
sudo /opt/ghrunner/bin/uninstall.sh          # remove everything
```

To run `container` or `tart` commands against the service users by hand,
plain `sudo -u` is not enough — their apiservers authorize clients by
launchd session, so wrap commands in `launchctl asuser` like the scripts do:

```sh
sudo launchctl asuser "$(id -u _ghcontainer)" sudo -u _ghcontainer -H \
  /usr/local/bin/container list
sudo launchctl asuser "$(id -u _ghcontainer)" sudo -u _ghcontainer -H \
  /usr/local/bin/container machine ls
sudo launchctl asuser "$(id -u _ghtart)" sudo -u _ghtart -H \
  /usr/local/bin/tart list
sudo launchctl asuser "$(id -u _ghlima)" sudo -u _ghlima -H \
  /usr/local/lima/bin/limactl list
```

- **Add/remove slots:** edit `MAC_RUNNERS` / `LINUX_RUNNERS` in `runner.env`,
  re-run `./provision.sh`.
- **Disable a host:** set every `*_RUNNERS` count to 0 (including any
  `LINUX_FLAVOR_*_RUNNERS`) and re-provision. All slot daemons are unloaded
  and their backing containers/VMs are torn down, but the installed tooling,
  service users, slot homes, and — importantly — tart's image store with your
  baked macOS images are left intact. No PAT is needed for a zero-slot run.
  Re-enable by restoring the counts and provisioning again. Prefer this over
  `uninstall.sh`, which deletes `_ghtart` and takes every pulled and baked
  macOS image with it.
- **Upgrade runner version:** bump `RUNNER_VERSION` (see
  [actions/runner releases](https://github.com/actions/runner/releases)),
  re-run. macOS installs are replaced and the Linux image is rebuilt. GitHub
  stops delivering jobs to runners more than a few releases behind ("Runner
  version vX is deprecated and cannot receive messages"; the slot log shows
  it looping on that line right after "Listening for Jobs"), so bump on a
  monthly cadence rather than waiting for the queue to stall.
- **Upgrade tart:** bump `TART_VERSION` (see
  [tart releases](https://github.com/openai/tart/releases)), re-run. The
  app bundle is swapped in place, so the bootstrap refuses while any `tart`
  process is alive (a job in flight, or a bake): provision after the warm
  window closes or once `mise run runner:status` shows the macvm slots idle,
  and it goes through. `CONTAINER_VERSION` and `LIMA_VERSION` are pinned the
  same way (both directions) and only act when their slot kinds are enabled.
- **Dependency updates:** Dependabot (`.github/dependabot.yml`) covers the
  workflow actions and the Ubuntu base images of the Linux runner images.
  The host tool pins above are outside any ecosystem it knows, so the
  `Pin bumps` workflow runs `./check-pins.sh --apply` every Monday and opens
  a PR when a newer release exists (`./check-pins.sh` alone shows the drift
  locally and exits 1). Merging changes nothing on a host until it is
  provisioned; the PR body repeats the tart after-hours rule.
- **Rotate the PAT:** re-run and paste the new token (leave empty to keep the
  existing one).
- **Factory resets** (all via `runner.env` edit + re-provision unless noted):
  - _linuxvm machines:_ nothing to reset — every job already gets a fresh
    machine. The machine image (`ghrunner-linuxvm:<version>`) is rebuilt on
    every provision with layer caching, so Dockerfile changes land on the
    next provision and `RUNNER_VERSION` bumps land as a new tag.
  - _amd64 Lima VMs (linuxvmamd64):_ bump `LINUXVM_RESET` to any new value —
    the VMs are deleted and recreated from scratch (Ubuntu re-download is
    cached). Changing `LINUXVM_AMD64_*` resources or `RUNNER_VERSION` has
    the same effect.
  - _Linux container images:_ bump `RUNNER_VERSION`, or delete the image on
    the host (`container image rm ghrunner-linux:<ver>`, or
    `ghrunner-linux-amd64:<ver>` for amd64, via the asuser wrapper) and
    re-provision to force a rebuild. The containers themselves are already
    fresh per job.
  - _A mac slot:_ `sudo rm -rf /var/ghrunner/slots/mac-N` on the host, then
    re-provision (reinstalls the runner for that slot).
  - _Everything:_ `sudo /opt/ghrunner/bin/uninstall.sh`, then provision from
    scratch (you'll need to paste the PAT again — it's wiped too).

## Troubleshooting

- **Scheduled slot never boots off-hours** — check
  `/var/ghrunner/log/dispatcher.log`. "cannot list runs" means the PAT
  lacks repo _Actions: read_ on the watched repos; no dispatcher log at all
  means no `*_POLICY` was set at provision time. Also check the job's
  labels actually fit the kind's label set (every job label must be among
  the slot's labels).
- **Slot log says "no job within the idle deadline; retiring runner"** —
  normal for scheduled/ondemand slots: the warm window closed, or a
  demand-booted runner's queued job was taken by another host or cancelled.
  The cycle exits with status 97 and the dispatcher starts the next one
  when there is demand again.
- **Slot log says "could not mint JIT runner config"** — PAT is wrong/expired,
  lacks the org _Self-hosted runners: write_ permission, `GH_ORG` is wrong, or
  the org restricts fine-grained PATs. The supervisor retries every ~75s.
- **`container` commands fail from the daemon (XPC/connection errors)** —
  apple/container's services run in a per-user launchd domain; the supervisor
  uses `launchctl asuser` to reach them headlessly. If it still fails, SSH in
  and run `sudo -u _ghcontainer -H container system start` once from a login
  session, then `sudo launchctl kickstart -k system/com.ghrunner.linux-1`.
- **Two `container` installs (the pkg plus `brew install container`)** —
  the slots use only the pkg's `/usr/local/bin/container`. Mixing installs in
  one user's launchd domain leaves a client of one version talking to an
  apiserver of another, and every call fails. The bootstrap stops when
  `_ghcontainer` runs a non-pkg apiserver, warns about other users' installs,
  and restarts `_ghcontainer`'s services when the apiserver version differs
  from `CONTAINER_VERSION`.
- **First Linux job is slow** — first `container system start` downloads a
  Linux kernel, and the image build pulls Ubuntu. One-time cost.
- **linuxvm slot fails with "machine create failed"** — the machine image
  `ghrunner-linuxvm:<version>` is missing: re-provision with
  `LINUXVM_RUNNERS` set so the bootstrap builds it. If the log instead shows
  an unknown `machine` subcommand, the installed container CLI predates
  1.1.0 — set `CONTAINER_VERSION` to 1.1.0+ and re-provision (the bootstrap
  reinstalls whenever the pkg differs from `CONTAINER_VERSION`). Each linuxvm job pays ~20-30s of machine
  create/boot/teardown overhead; that's the cost of the fresh-VM-per-job
  isolation.
- **`container build` hangs at "Unpacking built image"** — known upstream
  bug ([apple/container #68](https://github.com/apple/container/issues/68)
  class): the import completes server-side but the client never returns.
  The bootstrap detects the imported image, kills the hung client, and
  continues — expect a "build client hung ... continuing" note rather than
  a freeze.
- **First macvm provision is slow** — `tart pull` downloads a 40GB+ macOS
  image. Budget ~100GB free disk. Per-job clones are copy-on-write and take
  seconds. Provision with `-b` so the download doesn't depend on your SSH
  session staying alive (see Quick start).
- **VM dies instantly with `VZErrorDomain -9` "security error" / "Failed to
  get current host key"** — macOS 15+ Virtualization requires an existing,
  _unlocked_ login keychain for the user running a macOS guest ([Tart
  FAQ](https://tart.run/faq/)); GUI logins get one automatically, headless
  service users don't. The bootstrap creates and unlocks one for `_ghtart`
  using Tart's documented empty-password automation, registers it with
  `security login-keychain`, and each slot cycle re-unlocks it. `_ghtart` is
  hidden and unprivileged and its home is mode 700; do not use its keychain
  for registry or other credentials. If this error appears anyway,
  re-provision so bootstrap recreates and re-registers the keychain.
  The slot's `tart run` output is kept in
  `/var/ghrunner/log/macvm-N.tart.log`.
- **`tart` fails from the daemon (other Virtualization framework errors)** —
  running VMs from a headless launchd daemon context is the least-trodden
  path; Cirrus's own CI hosts historically ran Tart from a LaunchAgent under
  an auto-logged-in user. If macvm slots fail while `sudo -u _ghtart -H tart
run ...` works from an SSH session, that auto-login + LaunchAgent setup is
  the fallback — file an issue on this repo's toolkit and switch the macvm
  daemons over.
- **Tart maintenance** — Tart moved to [openai/tart](https://github.com/openai/tart)
  in 2026 (permissive license, no more Fair Source fees), but the original
  team no longer drives it; watch whether `ghcr.io/cirruslabs/*` images keep
  tracking new macOS releases.
- **macOS job can't find `git`** — set `INSTALL_XCODE_CLT=true` (default) and
  re-provision; full Xcode installs are out of scope (install manually and
  `sudo xcode-select -s`). In macvm slots, use an `-xcode` image variant
  instead (`MACVM_IMAGE`).
