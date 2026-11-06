#!/bin/bash
# Bakes a custom Tart macOS image on this host: clones a base image, boots
# it headless, runs the payload's scripts/*.sh inside the guest over SSH
# (in lexical order), shuts the guest down cleanly, and saves the result
# under BAKE_IMAGE_NAME for use as MACVM_IMAGE.
#
# Runs as root; invoked by bake-image.sh with the uploaded payload dir.
# Any macvm slot daemons are paused for the duration (macOS allows only two
# concurrent macOS VMs) and resumed afterwards, even on failure.
set -euo pipefail
if [[ -e /etc/company-vm-host/managed ]]; then
  echo "bake: drain and stop company-vm-host, then remove its managed marker for a maintenance bake" >&2
  exit 1
fi

PAYLOAD="${1:?usage: bake.sh <payload-dir>}"
die() { echo "bake: error: $*" >&2; exit 1; }
log() { printf '%s [bake] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[[ $EUID -eq 0 ]] || die "must run as root"
TART_BIN=/usr/local/bin/tart
[[ -x "$TART_BIN" ]] || die "tart is not installed; provision with MACVM_RUNNERS > 0 once, or install tart"
id -u _ghtart >/dev/null 2>&1 || die "service user _ghtart missing; provision with MACVM_RUNNERS > 0 once"

source "$PAYLOAD/bake.env"
BAKE_BASE_IMAGE="${BAKE_BASE_IMAGE:?BAKE_BASE_IMAGE must be set in bake.env}"
BAKE_IMAGE_NAME="${BAKE_IMAGE_NAME:?BAKE_IMAGE_NAME must be set in bake.env}"
[[ "$BAKE_IMAGE_NAME" != */* ]] || die "BAKE_IMAGE_NAME must be a plain local name (no '/')"
BAKE_CPUS="${BAKE_CPUS:-4}"
BAKE_MEMORY_MB="${BAKE_MEMORY_MB:-8192}"
BAKE_SCRIPT_TIMEOUT_MIN="${BAKE_SCRIPT_TIMEOUT_MIN:-120}"
[[ "$BAKE_SCRIPT_TIMEOUT_MIN" =~ ^[1-9][0-9]*$ ]] \
  || die "BAKE_SCRIPT_TIMEOUT_MIN must be a positive integer"
BAKE_DISK_SIZE_GB="${BAKE_DISK_SIZE_GB:-}"
[[ -z "$BAKE_DISK_SIZE_GB" || "$BAKE_DISK_SIZE_GB" =~ ^[1-9][0-9]*$ ]] \
  || die "BAKE_DISK_SIZE_GB must be a positive integer (GB) or unset"
GUEST_USER="${BAKE_SSH_USER:-admin}"
export MACVM_SSH_PASSWORD="${BAKE_SSH_PASSWORD:-admin}"

shopt -s nullglob
SCRIPTS=("$PAYLOAD"/scripts/*.sh)
(( ${#SCRIPTS[@]} > 0 )) || die "no scripts/*.sh in the bake payload"

TUID="$(id -u _ghtart)"
as_tart() { launchctl asuser "$TUID" sudo -u _ghtart -H "$TART_BIN" "$@"; }

# SSH_ASKPASS helper (may not exist yet if no macvm slot was provisioned).
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
vmscp() {
  env SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
    scp "${GUEST_SSH_OPTS[@]}" "$@"
}

WORK_VM="ghrunner-bake-tmp"
RUN_PID=""
PAUSED_DAEMONS=()

cleanup() {
  as_tart stop "$WORK_VM" 2>/dev/null || true
  sleep 3
  if [[ -n "$RUN_PID" ]]; then kill -9 "$RUN_PID" 2>/dev/null || true; fi
  as_tart delete "$WORK_VM" 2>/dev/null || true
  if (( ${#PAUSED_DAEMONS[@]} > 0 )); then
    local label
    for label in "${PAUSED_DAEMONS[@]}"; do
      launchctl bootstrap system "/Library/LaunchDaemons/${label}.plist" 2>/dev/null || true
      log "resumed ${label}"
    done
  fi
}
trap cleanup EXIT

for plist in /Library/LaunchDaemons/com.ghrunner.macvm-*.plist; do
  [[ -e "$plist" ]] || continue
  label="$(basename "$plist" .plist)"
  log "pausing ${label} for the bake (macOS 2-VM limit; interrupts a running job)"
  launchctl bootout "system/${label}" 2>/dev/null || true
  PAUSED_DAEMONS+=("$label")
done

if [[ "$BAKE_BASE_IMAGE" == */* ]]; then
  log "pulling base image ${BAKE_BASE_IMAGE} (cached after first pull)"
  as_tart pull "$BAKE_BASE_IMAGE"
fi

as_tart delete "$WORK_VM" 2>/dev/null || true
log "cloning ${BAKE_BASE_IMAGE} -> ${WORK_VM}"
as_tart clone "$BAKE_BASE_IMAGE" "$WORK_VM"
as_tart set "$WORK_VM" --cpu "$BAKE_CPUS" --memory "$BAKE_MEMORY_MB"

# Grow the disk before first boot; the guest expands its APFS container into
# the new space (see wait_for_guest_disk). Tart only grows (and the disk is
# sparse, so the host pays only for blocks a VM writes); asking for less than
# the base image has is a config mistake, not something to silently ignore.
GROW_DISK=""
if [[ -n "$BAKE_DISK_SIZE_GB" ]]; then
  base_disk_gb="$(as_tart get "$WORK_VM" --format json | plutil -extract Disk raw -o - -)"
  [[ "$base_disk_gb" =~ ^[0-9]+$ ]] || die "could not read the disk size of ${WORK_VM}"
  if (( BAKE_DISK_SIZE_GB < base_disk_gb )); then
    die "BAKE_DISK_SIZE_GB=${BAKE_DISK_SIZE_GB} is smaller than the base image's ${base_disk_gb} GB disk; tart cannot shrink"
  elif (( BAKE_DISK_SIZE_GB > base_disk_gb )); then
    log "growing the disk from ${base_disk_gb} GB to ${BAKE_DISK_SIZE_GB} GB"
    as_tart set "$WORK_VM" --disk-size "$BAKE_DISK_SIZE_GB"
    GROW_DISK=1
  fi
fi

as_tart run "$WORK_VM" --no-graphics >/dev/null 2>&1 &
RUN_PID=$!

IP=""
for _ in $(seq 1 60); do
  kill -0 "$RUN_PID" 2>/dev/null || break
  if IP="$(as_tart ip "$WORK_VM" 2>/dev/null)" && [[ -n "$IP" ]]; then break; fi
  IP=""
  sleep 3
done
[[ -n "$IP" ]] || die "bake VM did not get an IP within 3 minutes"

ssh_up=""
for _ in $(seq 1 60); do
  if vmssh "$IP" true 2>/dev/null; then ssh_up=1; break; fi
  sleep 3
done
[[ -n "$ssh_up" ]] || die "could not reach bake VM at ${IP} over SSH"

# The guest claims the space tart added on its own: the cirruslabs images run
# tart-guest-agent at every boot, which grows the boot APFS container into any
# free space at the end of the disk. Wait for its verdict and check the result
# rather than resizing from here: a second resize while the agent's is in
# flight makes both fail (APFS error 49189). Growing live only works when the
# container is the last partition, as in the cirruslabs Tahoe images; see
# https://tart.run/faq/#disk-resizing for images with a recovery partition
# after it. Prints the container size in bytes as its last line.
wait_for_guest_disk() { # <guest-ip>
  vmssh "$1" /bin/bash -s <<'GUEST'
set -uo pipefail
agent_log=/tmp/tart-guest-daemon.log
for _ in $(seq 1 60); do
  grep -qE 'successfully resized|failed to resize|skipping disk resizing' "$agent_log" 2>/dev/null && break
  sleep 3
done
grep -E 'resiz' "$agent_log" >&2 || echo "tart-guest-agent reported nothing about the disk" >&2
df -h / >&2
store="$(diskutil info / | awk -F': *' '/APFS Physical Store/ {print $2; exit}')"
diskutil info -plist "$store" | plutil -extract Size raw -o - -
GUEST
}

if [[ -n "$GROW_DISK" ]]; then
  log "waiting for the guest's APFS container to grow"
  container_bytes="$(wait_for_guest_disk "$IP" | tail -n 1)" || die "could not read the guest's APFS container size"
  # The disk also holds the ~0.5 GB APFS_ISC partition; allow 2 GB for it.
  [[ "$container_bytes" =~ ^[0-9]+$ ]] \
    && (( container_bytes >= (BAKE_DISK_SIZE_GB - 2) * 1000000000 )) \
    || die "guest APFS container is ${container_bytes} bytes; expected about ${BAKE_DISK_SIZE_GB} GB (did tart-guest-agent grow it?)"
  log "guest APFS container is now $(( container_bytes / 1000000000 )) GB"
fi

# Forward any BAKE_PRIME_* and BAKE_WITH_* variable from bake.env into the
# guest scripts: PRIME for optional cache priming (a token + repo ref), WITH
# for feature toggles that let two bake dirs share one set of scripts (e.g.
# BAKE_WITH_ANDROID=0 in ios-bake). Values are streamed as a small Bash wrapper
# over SSH stdin. They never appear in the host's ssh argv (and therefore its
# process list), and nothing secret is written to guest disk or the image.
#
# Deliberately not every BAKE_* var: BAKE_SSH_PASSWORD is one, and the rest
# configure the bake host-side and mean nothing in the guest.
FORWARD_ENV_NAMES=()
for name in $(compgen -v | grep -E '^BAKE_(PRIME|WITH)_' || true); do
  FORWARD_ENV_NAMES+=("$name")
done

# Run one guest script with a controller-side deadline. ConnectTimeout only
# bounds SSH setup; without this watchdog a live channel held open by an
# orphaned guest child can pause every runner slot on the host indefinitely.
# On timeout bake.sh fails, its EXIT trap stops/deletes the VM, and the paused
# slot daemons are restored.
run_guest_script() { # <guest-ip> <script-basename>
  local host="$1" base="$2" ssh_pid watchdog_pid rc=0 name
  local marker="$PAYLOAD/.guest-timeout-${base}"
  rm -f "$marker"

  {
    for name in ${FORWARD_ENV_NAMES[@]+"${FORWARD_ENV_NAMES[@]}"}; do
      printf 'export %s=%q\n' "$name" "${!name}"
    done
    printf 'exec /bin/bash %q\n' "/tmp/${base}"
  } | env SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
      ssh "${GUEST_SSH_OPTS[@]}" "${GUEST_USER}@${host}" /bin/bash -s &
  ssh_pid=$!

  ( sleep "$(( BAKE_SCRIPT_TIMEOUT_MIN * 60 ))" && {
      touch "$marker"
      kill "$ssh_pid" 2>/dev/null || true
      sleep 10
      kill -9 "$ssh_pid" 2>/dev/null || true
    }
  ) </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!

  wait "$ssh_pid" || rc=$?
  kill "$watchdog_pid" 2>/dev/null || true
  pkill -P "$watchdog_pid" 2>/dev/null || true

  if [[ -e "$marker" ]]; then
    die "guest script ${base} exceeded ${BAKE_SCRIPT_TIMEOUT_MIN} minutes"
  fi
  return "$rc"
}

# The repo's versions.env (shipped by bake-image.sh) lands next to the scripts
# so they can `source "$(dirname "$0")/versions.env"`. Plain data, no secrets;
# it may stay on the guest's /tmp.
if [[ -f "$PAYLOAD/versions.env" ]]; then
  vmscp "$PAYLOAD/versions.env" "${GUEST_USER}@${IP}:/tmp/versions.env" || die "could not copy versions.env into the guest"
fi

for s in "${SCRIPTS[@]}"; do
  base="$(basename "$s")"
  log "running ${base} in the guest"
  vmscp "$s" "${GUEST_USER}@${IP}:/tmp/${base}" || die "could not copy ${base} into the guest"
  run_guest_script "$IP" "$base" || die "bake script ${base} failed"
done

log "shutting the guest down"
vmssh "$IP" "sudo shutdown -h now" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$RUN_PID" 2>/dev/null || break
  sleep 3
done
if kill -0 "$RUN_PID" 2>/dev/null; then
  log "guest did not halt on its own; stopping via tart"
  as_tart stop "$WORK_VM" 2>/dev/null || true
  sleep 5
fi
RUN_PID=""

as_tart delete "$BAKE_IMAGE_NAME" 2>/dev/null || true
as_tart clone "$WORK_VM" "$BAKE_IMAGE_NAME"
as_tart delete "$WORK_VM" 2>/dev/null || true

log "baked image '${BAKE_IMAGE_NAME}'"
echo
echo "Next: set MACVM_IMAGE=${BAKE_IMAGE_NAME} in runner.env and re-run ./provision.sh"
