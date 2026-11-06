# Company VM host — API v1

This is the shared Mac infrastructure package in the shared host project, released
independently of every company agent. It has zero npm dependencies and requires
Node 22+, Apple Silicon macOS, Tart, Softnet and prepared SSH-enabled images.
It does not import NanoClaw, company workflows, or their model credentials.

Each company runs its own persistent Linux VM, with its own checkout, agent
image version, gateway, subscriptions, databases and backups. Those guests and
the disposable macOS workers are siblings. The host service controls shared
worker capacity; company services communicate only through HTTP `/v1`.

## Setup

1. Copy `examples/host.example.json` to `host.local.json`. Set absolute Tart and
   state paths, company quotas, image names, host-owned SSH key paths and recipes.
   Capacity is the budget **remaining after** reserving CPU/RAM for persistent
   company Linux guests and macOS itself. Set the macOS guest limit appropriately
   (the existing runner deployment uses two).
2. Generate a distinct random token of at least 32 characters per company in a
   mode-0600 file. Set `tokenFile`; share that company's token only with its own
   gateway vault. Tokens select the company server-side: requests cannot name a
   different company. Do not reuse tokens across companies.
3. Prepare company-specific VM images and SSH keys in each company's Tart store:
   `TART_HOME=<stateDir>/companies/<company>/tart`. Images contain tools and public
   SSH authorization, not model logins, host API tokens or long-lived GitHub PATs.
   The guest SSH user/key is company-specific. No host directories are mounted.
4. Install Softnet for the host service user, unlock its login keychain as required
   by Tart, then run `node src/main.mjs /absolute/host.local.json`. The API binds
   only to loopback. Use the per-company reverse tunnel described below and an HTTPS reverse proxy inside each company VM, with request
   timeouts long enough for recipes. Do not expose it to the public internet.
5. Update the installed legacy run-slot.sh and bake.sh to this revision, drain
   and disable old macvm daemons, then create `/etc/company-vm-host/managed`. The
   host service requires this marker; the updated legacy scripts refuse direct
   Tart jobs while it exists. Stop the broker and remove the marker only for
   an explicit maintenance bake.
6. On each company deployment configure `workers.mobile.url`, `hostProfile` and
   recipe names. Register that company's host token for the exact HTTPS hostname
   in that company's gateway. Credential injection and TLS are live setup checks.

Company agent upgrades do not restart the host service or another company's VM.
Host API v1 must stay compatible across host and client releases. Changing an
existing lease's profile definition while it runs is unsupported: drain leases
before changing profiles/images/credentials or upgrading the host service.

## Persistent company Linux guests

Copy `examples/machine.example.json` once per company. Use separate Tart homes,
Linux images and launchd jobs. Run `node src/machine.mjs <company-machine.json>`
under its own supervisor: it clones only on first start, then reuses the same disk
across reboots. It never deletes the persistent VM. Software and credentials
inside that VM are provisioned by the company's own release/setup process, not
by this host package. The host operator can replace its Linux image only through
an explicit backup/migration procedure. Reserve these guests' resources before
setting the worker capacity above.

`examples/service.plist` illustrates independent launchd supervision. Create one
job for the shared service and one machine job per company, with distinct labels,
arguments, logs, and private configuration paths. Run the host service as a
trusted dedicated host account with access to its own Tart/keychain context.
For a company VM to reach the broker while Softnet blocks private host access,
add `brokerTunnel` to its machine config:

```json
{
  "sshUser": "operator",
  "sshKeyFile": "/private/corporation-a-linux.ssh",
  "hostPort": 8790,
  "guestPort": 8790
}
```

The host opens SSH into that persistent guest and reverse-forwards only the
broker to guest loopback. The company provisions its own TLS proxy pointing at
`127.0.0.1:8790` inside the guest. Its gateway uses that HTTPS origin. SSH remote
forwarding must be enabled on the guest, with GatewayPorts disabled. No general
private-network allowance is added to worker guests. The physical host and its
administrator remain trusted across companies.

## Agent and CI jobs

Both request leases from the same scheduler. Each lease owns a fresh clone of a
host-approved profile in its company's Tart home. Names, images, argv, and keys
are selected by the host; the API accepts no shell, mount paths, credentials,
resource overrides or guest network settings.

`src/client.mjs` is a CLI for a bounded CI cycle:

```
COMPANY_HOST_URL=https://host.private.example \
COMPANY_HOST_TOKEN_FILE=/private/company-host.token \
node src/client.mjs ios github-runner
```

Add a `github-runner` recipe to that company's profile:

```json
{
  "github-runner": {
    "timeoutSeconds": 3600,
    "github": {
      "org": "your-company",
      "tokenFile": "/private/github-runner.pat",
      "runnerDir": "/opt/actions-runner",
      "labels": ["self-hosted", "macos", "arm64", "vm"],
      "runnerGroupId": 1
    }
  }
}
```

The VM image must have that GitHub runner version installed. The host mints a
single-use JIT configuration and sends it over SSH stdin to `run.sh`; the PAT
stays on the host. The VM is destroyed afterward. Run the CLI under a scheduled,
ondemand, or always-on supervisor as desired. Its token is scoped to the company.
A public/untrusted repository must not be allowed to request a company profile.

**Migration:** drain/disable legacy `macvm` slot daemons before enabling this
service on the same box. Replace their cycles with this CLI, preserving the
labels/group/image in the host profile. Legacy `run-slot.sh` and image baking
still launch Tart directly and bypass this allocator. Do not run them concurrently
with this service; perform bakes during an explicit maintenance window. Existing
Linux/native runner kinds remain separate and must fit the reserved host budget.
This package reuses the repository's baked images and JIT runner model, while
providing a single allocator for both CI and agent clones.

## HTTP contract

Bearer authentication, JSON, max 4 KiB requests. Responses include
`X-Company-Host-Api: 1`. No guest IP or SSH material is returned to companies.

- `GET /v1/capabilities`: `{apiVersion:1, company, profiles:[...]}`.
- `POST /v1/leases`: `{requestId,profile,kind:"agent"|"ci",ttlSeconds}`; returns
  a lease with HTTP 202. Request IDs are idempotent within a company and may not
  be reused for different inputs. TTL is 30–14400 seconds, including queue time.
- `GET /v1/leases` and `GET /v1/leases/<id>`: only the authenticated company's jobs.
- `POST /v1/leases/<id>/renew`: `{}` extends TTL by the original duration.
- `POST /v1/leases/<id>/run`: `{recipe}`; fixed host-controlled command inside the
  leased guest. Returns `{exitCode,output,stderr,timedOut?}`. Calls serialize per
  VM. The remaining lease must cover the recipe's timeout. Output is bounded to
  1 MiB per stream; collect larger artifacts through a company-specific recipe
  and artifact store. The host API is not a general file server.
- `DELETE /v1/leases/<id>`: cancel queued work or stop/delete an idle guest. A busy
  lease returns 409; retry after the bounded operation completes. TTL is a backstop.

The service persists queues and leases atomically. Restart recovery destroys
previous active job VMs and marks them interrupted; queued work survives.
Cleanup failures retain capacity and require retry/inspection rather than allowing
oversubscription. One service process owns the state directory. Per-company
leases/CPU/RAM quotas and host CPU/RAM/macOS limits apply to both CI and agent jobs.
Admission is FIFO within each company and at most one admission per company per
sweep; the least recently served company is considered first. Completed request
records are retained for idempotency; archive state during maintenance as needed.

Guests always use `--net-softnet`, with no private network allow overrides,
bridged networking or host mounts. Public egress remains available. Verify
Softnet's installed privileges and cross-guest isolation on the target host;
private VPN access requires a separately reviewed host policy extension. Default
NAT alone is insufficient for a shared-company deployment.

## Verification

`npm test` uses injected VM drivers and loopback HTTP servers; no model requests,
GitHub writes, Tart VMs, or host service installation occur. Actual Tart boot,
Softnet isolation, guest SSH, CI registration and simulator tests require a
prepared Mac. Tart is not installed in the development environment used here.
