#!/bin/bash
# Smoke-test a baked macvm image: clone it to a throwaway VM, boot it, run a
# tooling/env check over SSH exactly the way a job does (a non-interactive
# `ssh ... ` runs the guest's login shell as `zsh -c`, which sources
# /etc/zshenv - so this proves the env actually reaches jobs), then tear the
# VM down. Runs as root; invoked by verify-macvm.sh with the uploaded config.
#
# Pauses macvm slot daemons for the ~2-3 min it runs (macOS 2-VM limit) and
# resumes them afterwards, even on failure.
set -euo pipefail

CONFIG="${1:?usage: verify-macvm.sh <config.env> [image]}"
IMAGE_OVERRIDE="${2:-}"

die() { echo "verify: error: $*" >&2; exit 1; }
log() { printf '%s [verify] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[[ $EUID -eq 0 ]] || die "must run as root"
TART_BIN=/usr/local/bin/tart
[[ -x "$TART_BIN" ]] || die "tart not installed; provision with MACVM_RUNNERS > 0 first"
id -u _ghtart >/dev/null 2>&1 || die "service user _ghtart missing; provision with MACVM_RUNNERS > 0 first"

# shellcheck disable=SC1090
source "$CONFIG"
IMAGE="${IMAGE_OVERRIDE:-${MACVM_IMAGE:?set MACVM_IMAGE in the config or pass an image name}}"
GUEST_USER="${MACVM_SSH_USER:-admin}"
export MACVM_SSH_PASSWORD="${MACVM_SSH_PASSWORD:-admin}"
CPUS="${MACVM_CPUS:-4}"
MEM="${MACVM_MEMORY_MB:-8192}"

TUID="$(id -u _ghtart)"
as_tuser() { launchctl asuser "$TUID" sudo -u _ghtart -H "$@"; }
as_tart()  { as_tuser "$TART_BIN" "$@"; }

# SSH_ASKPASS helper for password auth into the guest without a tty (matches
# run-slot.sh / bake.sh). Created by a macvm provision; recreate if missing.
ASKPASS=/opt/ghrunner/bin/vm-askpass.sh
if [[ ! -x "$ASKPASS" ]]; then
  install -d -m 755 /opt/ghrunner /opt/ghrunner/bin
  printf '#!/bin/sh\nprintf %%s "${MACVM_SSH_PASSWORD:-admin}"\n' > "$ASKPASS"
  chmod 755 "$ASKPASS"
fi
GUEST_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                -o LogLevel=ERROR -o ConnectTimeout=10)
vmssh() {
  local host="$1"; shift
  env SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
    ssh "${GUEST_SSH_OPTS[@]}" "${GUEST_USER}@${host}" "$@"
}

VM="ghrunner-verify-tmp"
RUN_PID=""
PAUSED_DAEMONS=()

cleanup() {
  as_tart stop "$VM" 2>/dev/null || true
  sleep 3
  if [[ -n "$RUN_PID" ]]; then kill -9 "$RUN_PID" 2>/dev/null || true; fi
  as_tart delete "$VM" 2>/dev/null || true
  if (( ${#PAUSED_DAEMONS[@]} > 0 )); then
    local label
    for label in "${PAUSED_DAEMONS[@]}"; do
      launchctl bootstrap system "/Library/LaunchDaemons/${label}.plist" 2>/dev/null || true
      log "resumed ${label}"
    done
  fi
}
trap cleanup EXIT

# Free a VM slot (Apple allows only two concurrent macOS VMs).
for plist in /Library/LaunchDaemons/com.ghrunner.macvm-*.plist; do
  [[ -e "$plist" ]] || continue
  label="$(basename "$plist" .plist)"
  log "pausing ${label} for the check (macOS 2-VM limit; interrupts a running job)"
  launchctl bootout "system/${label}" 2>/dev/null || true
  PAUSED_DAEMONS+=("$label")
done

# Unlock _ghtart's empty-password login keychain (Virtualization host-key
# requirement; bootstrap.sh creates it using Tart's headless-host recipe).
as_tuser security unlock-keychain -p '' login.keychain \
  || log "WARNING: could not unlock _ghtart keychain; expect a VM security error"

as_tart list | grep -q "$IMAGE" \
  || die "image '${IMAGE}' not found in tart (as _ghtart); did the bake finish?"

as_tart delete "$VM" 2>/dev/null || true
log "cloning ${IMAGE} -> ${VM}"
as_tart clone "$IMAGE" "$VM" || die "clone failed"
as_tart set "$VM" --cpu "$CPUS" --memory "$MEM" || die "set failed"

log "booting ${VM}"
as_tart run "$VM" --no-graphics >/dev/null 2>&1 &
RUN_PID=$!

IP=""
for _ in $(seq 1 60); do
  kill -0 "$RUN_PID" 2>/dev/null || die "tart run exited before the VM got an IP"
  if IP="$(as_tart ip "$VM" 2>/dev/null)" && [[ -n "$IP" ]]; then break; fi
  IP=""; sleep 3
done
[[ -n "$IP" ]] || die "VM did not get an IP within 3 minutes"

for _ in $(seq 1 60); do
  if vmssh "$IP" true 2>/dev/null; then break; fi
  sleep 3
done

log "VM up at ${IP}; running checks (non-interactive ssh == the zsh -c a job gets)"
echo "-------------------------------------------------------------------"
set +e
vmssh "$IP" 'bash -s' <<'CHECKS'
row() { printf "  %-14s %s\n" "$1" "$2"; }
echo "tools on PATH (all must resolve; PATH itself comes from /etc/zshenv):"
missing_tools=()
for t in node java jq watchman xcpretty fastlane pod maestro gcloud warp-cli ccache; do
  p="$(command -v "$t" 2>/dev/null)"
  row "$t" "${p:-<MISSING>}"
  [[ -n "$p" ]] || missing_tools+=("$t")
done
row "node"       "$(node --version 2>/dev/null)"
echo
# Everything below is <MISSING>/empty by design on an image baked from
# ios-bake (BAKE_WITH_ANDROID=0), and a real failure on one baked from
# mobile-bake. The image name printed above tells you which you are looking at.
echo "android (expected absent on an iOS-only image):"
row "ANDROID_HOME"     "${ANDROID_HOME:-<MISSING>}"
row "ANDROID_SDK_ROOT" "${ANDROID_SDK_ROOT:-<MISSING>}"
row "ANDROID_NDK_HOME" "${ANDROID_NDK_HOME:-<MISSING>}"
for t in adb sdkmanager; do
  p="$(command -v "$t" 2>/dev/null)"
  row "$t" "${p:-<MISSING>}"
done
row "ndk"        "$(ls "${ANDROID_HOME:-/nonexistent}/ndk" 2>/dev/null | tr '\n' ' ')"
row "build-tools" "$(ls "${ANDROID_HOME:-/nonexistent}/build-tools" 2>/dev/null | tr '\n' ' ')"
row "platforms"  "$(ls "${ANDROID_HOME:-/nonexistent}/platforms" 2>/dev/null | tr '\n' ' ')"
row "gradle dist" "$(ls "$HOME/.gradle/wrapper/dists" 2>/dev/null | tr '\n' ' ')"
echo
echo "pod caches (warm = the deep prime landed):"
for d in "$HOME/.cocoapods" "$HOME/Library/Caches/CocoaPods"; do
  if [ -d "$d" ]; then row "$(basename "$d")" "$(du -sh "$d" 2>/dev/null | cut -f1)"
  else row "$(basename "$d")" "<MISSING>"; fi
done
echo
echo "iOS simulator runtimes:"
xcrun simctl list runtimes 2>/dev/null | grep -i ios | sed 's/^/  /'
if (( ${#missing_tools[@]} > 0 )); then
  printf 'required tools missing from PATH: %s\n' "${missing_tools[*]}" >&2
  exit 1
fi
CHECKS
rc=$?
set -e
echo "-------------------------------------------------------------------"
if [[ $rc -eq 0 ]]; then
  log "checks completed (review output above)"
else
  log "checks exited with status $rc"
fi
log "tearing down ${VM}"
exit "$rc"
