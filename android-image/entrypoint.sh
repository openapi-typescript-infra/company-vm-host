#!/bin/bash
# Run one JIT-configured GitHub Actions job. A large ephemeral volume may be
# mounted at /ghrunner-scratch by run-slot.sh; all high-churn build state is
# placed there so the image root filesystem only holds the toolchain.
set -euo pipefail

install -d -m 0755 -o runner -g runner \
  /ghrunner-scratch/cache \
  /ghrunner-scratch/eas-local-build \
  /ghrunner-scratch/gradle \
  /ghrunner-scratch/tmp \
  /ghrunner-scratch/toolcache \
  /ghrunner-scratch/work

# The runner's JIT work_folder is relative to its install dir. Symlink that
# folder, plus the home-directory caches EAS uses, onto the disposable disk.
rm -rf /home/runner/runner/_work /home/runner/.gradle /home/runner/eas-local-build
ln -s /ghrunner-scratch/work /home/runner/runner/_work
ln -s /ghrunner-scratch/gradle /home/runner/.gradle
ln -s /ghrunner-scratch/eas-local-build /home/runner/eas-local-build

# Seed Gradle's user home from the image's prewarmed copy (Dockerfile,
# GRADLE_PREWARM): wrapper distribution, dependency cache and artifact
# transforms from a build of the app's Expo template. A whole-tree copy of one
# consistent snapshot is safe; it is merging Gradle state from different runs
# that Gradle rejects (see run-slot.sh's macvm notes). Skipped for an unseeded
# image, where Gradle simply starts cold as before.
if [[ -d "${GHRUNNER_GRADLE_SEED:-/opt/ghrunner-gradle-seed}/caches" ]]; then
  cp -a "${GHRUNNER_GRADLE_SEED:-/opt/ghrunner-gradle-seed}/." /ghrunner-scratch/gradle/
  echo "entrypoint: seeded Gradle user home from the image ($(du -sh /ghrunner-scratch/gradle | cut -f1))"
fi

# The image carries the canonical Gradle settings; copy rather than symlink
# the file so an individual job can adjust its disposable copy if necessary.
cp /etc/ghrunner-gradle.properties /ghrunner-scratch/gradle/gradle.properties

# Cross-job caches, both opt-in (see README, "Company Android build image").
# Gradle remote build cache: an init script in the job's Gradle home adds the
# HTTP cache as the remote tier. The local tier is already on (gradle.properties
# above) but lives in scratch, so only the remote survives the job.
if [[ -n "${GRADLE_REMOTE_CACHE_URL:-}" ]]; then
  install -d -m 0755 /ghrunner-scratch/gradle/init.d
  cat > /ghrunner-scratch/gradle/init.d/ghrunner-remote-cache.gradle <<'GRADLE'
// Written by /entrypoint.sh from GRADLE_REMOTE_CACHE_*; applies to every build.
settingsEvaluated { settings ->
  settings.buildCache {
    remote(HttpBuildCache) {
      url = System.getenv('GRADLE_REMOTE_CACHE_URL')
      push = (System.getenv('GRADLE_REMOTE_CACHE_PUSH') ?: 'true') == 'true'
      allowInsecureProtocol = url.toString().startsWith('http://')
      def user = System.getenv('GRADLE_REMOTE_CACHE_USER')
      def pass = System.getenv('GRADLE_REMOTE_CACHE_PASSWORD')
      if (user && pass) { credentials { username = user; password = pass } }
    }
  }
}
GRADLE
  echo "entrypoint: Gradle remote build cache at ${GRADLE_REMOTE_CACHE_URL}"
fi
# ccache for the NDK C++ compile (AGP's CMake tasks are not build-cacheable).
# CMake >= 3.17 takes the compiler launcher from these env vars at configure
# time, so no app change is needed. Only worth it with somewhere to persist to:
# ccache's remote storage, or a host directory mounted at /ghrunner-cache.
CCACHE_ENV=()
if [[ -n "${CCACHE_REMOTE_STORAGE:-}" || -d /ghrunner-cache/ccache ]]; then
  ccache_dir=/ghrunner-scratch/ccache
  [[ -d /ghrunner-cache/ccache ]] && ccache_dir=/ghrunner-cache/ccache
  install -d -m 0755 -o runner -g runner "$ccache_dir"
  CCACHE_ENV=(CCACHE_DIR="$ccache_dir" CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
              CMAKE_C_COMPILER_LAUNCHER=/usr/bin/ccache CMAKE_CXX_COMPILER_LAUNCHER=/usr/bin/ccache)
  echo "entrypoint: NDK compile through ccache (dir ${ccache_dir}${CCACHE_REMOTE_STORAGE:+, remote ${CCACHE_REMOTE_STORAGE}})"
fi
chown -R runner:runner /ghrunner-scratch

# React Native 0.83's hermes-compiler package ships a Linux x86_64 compiler but
# its Gradle plugin does not recognize a Linux arm64 host. Point its documented
# source-build override at an image-owned wrapper. The wrapper resolves the
# application's locked compiler version and Rosetta translates that one x64
# process; Gradle itself remains native arm64.
REACT_NATIVE_OVERRIDE_HERMES_DIR_VALUE="${REACT_NATIVE_OVERRIDE_HERMES_DIR:-}"
if [[ "$(uname -m)" == "aarch64" ]]; then
  REACT_NATIVE_OVERRIDE_HERMES_DIR_VALUE=/opt/hermes
  echo "entrypoint: enabling application-locked x86_64 Hermes compiler via Rosetta"
fi

cd /home/runner/runner
run_as_runner() {
  setpriv --reuid=runner --regid=runner --init-groups \
    env -u WARP_ORG -u WARP_AUTH_CLIENT_ID -u WARP_AUTH_CLIENT_SECRET \
      ${CCACHE_ENV[@]+"${CCACHE_ENV[@]}"} \
      HOME=/home/runner \
      TMPDIR=/ghrunner-scratch/tmp \
      XDG_CACHE_HOME=/ghrunner-scratch/cache \
      RUNNER_TOOL_CACHE=/ghrunner-scratch/toolcache \
      AGENT_TOOLSDIRECTORY=/ghrunner-scratch/toolcache \
      REACT_NATIVE_OVERRIDE_HERMES_DIR="$REACT_NATIVE_OVERRIDE_HERMES_DIR_VALUE" \
      "$@"
}
exec_as_runner() {
  exec setpriv --reuid=runner --regid=runner --init-groups \
    env -u WARP_ORG -u WARP_AUTH_CLIENT_ID -u WARP_AUTH_CLIENT_SECRET \
      ${CCACHE_ENV[@]+"${CCACHE_ENV[@]}"} \
      HOME=/home/runner \
      TMPDIR=/ghrunner-scratch/tmp \
      XDG_CACHE_HOME=/ghrunner-scratch/cache \
      RUNNER_TOOL_CACHE=/ghrunner-scratch/toolcache \
      AGENT_TOOLSDIRECTORY=/ghrunner-scratch/toolcache \
      REACT_NATIVE_OVERRIDE_HERMES_DIR="$REACT_NATIVE_OVERRIDE_HERMES_DIR_VALUE" \
      "$@"
}

WARP_PID=""
WARP_ENABLED=""
cleanup_warp() {
  [[ -n "$WARP_ENABLED" ]] || return 0
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  [[ -z "$WARP_PID" ]] || kill "$WARP_PID" >/dev/null 2>&1 || true
}

start_warp() {
  local outer_mtu present=0 tunnel_mtu value status
  for value in "${WARP_ORG:-}" "${WARP_AUTH_CLIENT_ID:-}" "${WARP_AUTH_CLIENT_SECRET:-}"; do
    [[ -z "$value" ]] || present=$((present + 1))
  done
  (( present == 0 )) && return 0
  (( present == 3 )) \
    || { echo "entrypoint: WARP_ORG and both WARP_AUTH_* values must be set together" >&2; exit 1; }

  # These values are serialized into a tiny XML policy file. Cloudflare team
  # names, service-token IDs and secrets use this conservative character set;
  # rejecting anything else avoids surprising XML or env-file interpretation.
  for value in "$WARP_ORG" "$WARP_AUTH_CLIENT_ID" "$WARP_AUTH_CLIENT_SECRET"; do
    [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] \
      || { echo "entrypoint: invalid character in a WARP enrollment value" >&2; exit 1; }
  done

  install -d -m 0700 /var/lib/cloudflare-warp
  printf '%s\n' \
      '<dict>' \
      "  <key>organization</key><string>${WARP_ORG}</string>" \
      "  <key>auth_client_id</key><string>${WARP_AUTH_CLIENT_ID}</string>" \
      "  <key>auth_client_secret</key><string>${WARP_AUTH_CLIENT_SECRET}</string>" \
      '  <key>service_mode</key><string>warp</string>' \
      '  <key>auto_connect</key><integer>1</integer>' \
      '  <key>onboarding</key><false/>' \
      '</dict>' \
    > /var/lib/cloudflare-warp/mdm.xml
  chmod 0600 /var/lib/cloudflare-warp/mdm.xml

  echo "entrypoint: connecting Cloudflare WARP for org ${WARP_ORG}"
  warp-svc >/tmp/warp-svc.log 2>&1 &
  WARP_PID=$!
  WARP_ENABLED=yes
  trap cleanup_warp EXIT

  for _ in $(seq 1 20); do
    kill -0 "$WARP_PID" 2>/dev/null \
      || { echo "entrypoint: warp-svc exited before connecting" >&2; exit 1; }
    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || true
    status="$(warp-cli --accept-tos status 2>/dev/null || true)"
    grep -q Connected <<<"$status" && break
    sleep 3
  done
  grep -q Connected <<<"$status" \
    || { echo "entrypoint: Cloudflare WARP did not connect" >&2; exit 1; }

  # Apple container's outer eth0 is 1280 bytes. Leaving the inner WARP TUN at
  # the same MTU creates a PMTU black hole once WireGuard adds its outer
  # headers: small requests work, while full GraphQL introspection requests
  # can remain stuck awaiting a response. Reserve 80 bytes for encapsulation
  # on constrained outer links; retain WARP's default on ordinary 1500-byte
  # container networks (including typical Kubernetes nodes).
  outer_mtu="$(cat /sys/class/net/eth0/mtu)"
  if (( outer_mtu <= 1280 )); then
    tunnel_mtu=$((outer_mtu - 80))
    ip link set dev CloudflareWARP mtu "$tunnel_mtu"
    echo "entrypoint: constrained Cloudflare WARP tunnel MTU to ${tunnel_mtu} (outer eth0 ${outer_mtu})"
  fi

  # Linux WARP periodically checks that both the account and the service-auth
  # method still match its managed policy, so the root-only MDM file must stay
  # for the life of the connection. The build user has no sudo path to it; also
  # remove the credentials from the runner's child environment.
  unset WARP_ORG WARP_AUTH_CLIENT_ID WARP_AUTH_CLIENT_SECRET
  echo "entrypoint: Cloudflare WARP connected"
}

run_with_warp_cleanup() {
  local child rc
  run_as_runner "$@" &
  child=$!
  trap 'kill -TERM "$child" >/dev/null 2>&1 || true' TERM INT HUP
  set +e
  wait "$child"
  rc=$?
  set -e
  trap - TERM INT HUP
  return "$rc"
}

start_warp

# Supplying arguments turns the image into a general Android build
# environment (not a runner). This is the Kubernetes Job contract: keep the
# entrypoint, provide the build command as args, and get the same scratch
# initialization and unprivileged execution as GitHub Actions.
if (( $# > 0 )); then
  if [[ -n "$WARP_ENABLED" ]]; then
    run_with_warp_cleanup "$@"
    exit $?
  fi
  exec_as_runner "$@"
fi

if [[ -z "${GH_JIT_CONFIG:-}" ]]; then
  echo "entrypoint: GH_JIT_CONFIG not set and no build command was supplied" >&2
  exit 1
fi

if [[ -n "$WARP_ENABLED" ]]; then
  run_with_warp_cleanup ./run.sh --jitconfig "$GH_JIT_CONFIG"
  exit $?
fi
exec_as_runner ./run.sh --jitconfig "$GH_JIT_CONFIG"
