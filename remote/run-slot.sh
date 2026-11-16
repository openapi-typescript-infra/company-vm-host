#!/bin/bash
# Supervises one ephemeral GitHub Actions runner slot for exactly one job:
# mints a single-use just-in-time runner config, runs the runner (which
# exits after one job), scrubs the slot, then exits so launchd starts the
# next cycle. Invoked as root by the com.ghrunner.<kind>-<n> LaunchDaemon.
#
# Slot kinds:
#   mac            - job runs natively as a dedicated unprivileged user
#   linux          - job runs inside a fresh apple/container Linux VM (arm64)
#   linuxamd64     - like linux, but an amd64 image run with --arch amd64
#                    (Rosetta-translated x64 runner)
#   linux.<flavor> - like linux, but with a custom image/labels/resources/
#                    arch from the LINUX_FLAVOR_<flavor>_* config vars
#   linuxvm        - job runs inside a fresh arm64 apple/container machine
#                    with dockerd (for jobs that need docker); created per
#                    job and deleted afterward
#   linuxvmamd64   - docker-capable like linuxvm, but a persistent x86_64
#                    QEMU-emulated Lima VM (a true amd64 kernel/docker/
#                    runner; slow), scrubbed between jobs
#   macvm          - job runs inside a fresh Tart macOS VM
#
# The PAT never leaves this root process; runner users, containers, and VMs
# only ever see the single-use JIT config.
set -euo pipefail

KIND="${1:?usage: run-slot.sh <kind> <index> (kinds listed in the header comment)}"
IDX="${2:?usage: run-slot.sh <kind> <index> (kinds listed in the header comment)}"
SLOT="${KIND}-${IDX}"
if [[ "$KIND" == "macvm" && -e /etc/company-vm-host/managed ]]; then
  echo "macvm slots are managed by company-vm-host; replace this slot with its scoped CI client" >&2
  exit 1
fi
# Dot-free form for names that leave this script (runner names, container
# names); the scavenger matches on it, so keep them consistent.
SLOT_TAG="${SLOT//./-}"

log()  { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SLOT" "$*"; }
# Sleep before exiting on failure so launchd doesn't spin against a
# persistent problem (bad PAT, no network, broken image, ...).
fail() { log "ERROR: $*"; sleep 60; exit 1; }

source /etc/ghrunner/config.env
PAT="$(cat /etc/ghrunner/github.pat)"
RUNNER_VERSION="${RUNNER_VERSION:-2.338.2}"
RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-1}"

# Shared kind/label/policy/schedule helpers (fvar, resolve_slot_labels,
# slot_policy, slot_schedule, schedule_remaining, ...).
source /opt/ghrunner/bin/slot-lib.sh

# Resolve the slot's labels and, for container-linux kinds, the arch that
# drives the image/resource/flag selection in the run phase below.
resolve_slot_labels "$KIND" || fail "unknown slot kind '$KIND'"

NAME_PREFIX="${RUNNER_NAME_PREFIX:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
RUNNER_NAME="${NAME_PREFIX}-${SLOT_TAG}-$(openssl rand -hex 3)"

labels_json=""
IFS=',' read -ra labels_arr <<<"$LABELS"
for l in "${labels_arr[@]}"; do labels_json+="\"${l}\","; done
labels_json="[${labels_json%,}]"

# A JIT runner killed before it takes a job (re-provision bootout, reboot,
# crash) leaves a stale offline registration behind. Scavenge this slot's
# own leftovers each cycle so they never accumulate.
scavenge_stale() {
  local resp count i name status rid
  resp="$(mktemp)"
  if curl -sS --fail --max-time 30 \
      -H "Authorization: Bearer $PAT" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -o "$resp" \
      "https://api.github.com/orgs/${GH_ORG}/actions/runners?per_page=100"; then
    count="$(plutil -extract runners raw -o - "$resp" 2>/dev/null || echo 0)"
    for ((i = 0; i < count; i++)); do
      name="$(plutil -extract "runners.${i}.name" raw -o - "$resp")"
      status="$(plutil -extract "runners.${i}.status" raw -o - "$resp")"
      rid="$(plutil -extract "runners.${i}.id" raw -o - "$resp")"
      if [[ "$name" == "${NAME_PREFIX}-${SLOT_TAG}-"* && "$status" == "offline" ]]; then
        log "removing stale runner registration ${name} (id ${rid})"
        curl -sS --fail --max-time 30 -X DELETE \
          -H "Authorization: Bearer $PAT" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "https://api.github.com/orgs/${GH_ORG}/actions/runners/${rid}" || true
      fi
    done
  fi
  rm -f "$resp"
}

# Mints a single-use JIT runner config into $JIT. Called as late as
# possible so a failed slot setup doesn't leave an unused registration.
JIT=""
mint_jit() {
  local resp
  resp="$(mktemp)"
  if ! curl -sS --fail-with-body --max-time 30 --retry 3 \
      -H "Authorization: Bearer $PAT" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "{\"name\":\"${RUNNER_NAME}\",\"runner_group_id\":${RUNNER_GROUP_ID},\"labels\":${labels_json},\"work_folder\":\"_work\"}" \
      -o "$resp" \
      "https://api.github.com/orgs/${GH_ORG}/actions/runners/generate-jitconfig"; then
    log "ERROR: could not mint JIT runner config (check PAT, GH_ORG, network): $(cat "$resp" 2>/dev/null || true)"
    rm -f "$resp"
    return 1
  fi
  if ! JIT="$(plutil -extract encoded_jit_config raw -o - "$resp")"; then
    log "ERROR: unexpected API response: $(cat "$resp")"
    rm -f "$resp"
    return 1
  fi
  rm -f "$resp"
}

# How long this cycle's runner may wait for a job before being retired:
# empty = forever (the default 'always' policy, where launchd loops us).
# A warm cycle (scheduled policy, inside the window) listens until the
# window closes - never less than the idle timeout, so a cycle started near
# the close still gets a useful listen. Retiring at the close is exactly
# what shuts the slot down for the night: launchd no longer respawns it (no
# KeepAlive on managed slots) and dispatch.sh only starts it again on
# demand or at the next window. A cold cycle (demand-booted, or an ondemand
# slot) gets the idle timeout, which covers the queued job it was booted
# for having been taken by another host or cancelled.
idle_deadline() {
  local policy rem timeout="${DISPATCH_IDLE_TIMEOUT:-600}"
  policy="$(slot_policy "$KIND")"
  [[ "$policy" == "always" ]] && return 0
  if [[ "$policy" == "scheduled" ]] && rem="$(schedule_remaining "$(slot_schedule "$KIND")")"; then
    (( rem > timeout )) || rem="$timeout"
    printf '%s\n' "$rem"
  else
    printf '%s\n' "$timeout"
  fi
}

# Whether GitHub currently reports this cycle's runner as running a job:
# 0 = busy, 1 = idle or not registered, 2 = could not tell (API failure).
runner_busy_state() {
  local resp page count i name busy
  resp="$(mktemp)"
  for page in 1 2 3; do
    if ! curl -sS --fail --max-time 30 \
        -H "Authorization: Bearer $PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -o "$resp" \
        "https://api.github.com/orgs/${GH_ORG}/actions/runners?per_page=100&page=${page}"; then
      rm -f "$resp"
      return 2
    fi
    count="$(plutil -extract runners raw -o - "$resp" 2>/dev/null || echo 0)"
    for ((i = 0; i < count; i++)); do
      name="$(plutil -extract "runners.${i}.name" raw -o - "$resp")"
      [[ "$name" == "$RUNNER_NAME" ]] || continue
      busy="$(plutil -extract "runners.${i}.busy" raw -o - "$resp")"
      rm -f "$resp"
      [[ "$busy" == "true" ]] && return 0
      return 1
    done
    (( count < 100 )) && break
  done
  rm -f "$resp"
  return 1
}

RC_IDLE_EXPIRED=97
# Runs a slot's foreground runner command, enforcing IDLE_DEADLINE if set:
# a runner still waiting for a job at the deadline is killed and the cycle
# returns RC_IDLE_EXPIRED (callers fall through to their normal teardown).
# Only a confirmed-idle runner is ever killed - one the API reports busy
# rides out the deadline unbounded, and an unreachable API extends the wait
# rather than risking a kill mid-job.
run_runner() {
  local pid deadline rc
  if [[ -z "$IDLE_DEADLINE" ]]; then
    "$@"
    return
  fi
  "$@" &
  pid=$!
  deadline=$(( $(date +%s) + IDLE_DEADLINE ))
  while kill -0 "$pid" 2>/dev/null; do
    if (( $(date +%s) >= deadline )); then
      runner_busy_state
      rc=$?
      if (( rc == 0 )); then
        log "idle deadline passed mid-job; letting '${RUNNER_NAME}' finish"
        wait "$pid"
        return
      elif (( rc == 2 )); then
        log "idle deadline passed but the runner API is unreachable; retrying in 60s"
        deadline=$(( $(date +%s) + 60 ))
      else
        log "no job within the idle deadline; retiring runner '${RUNNER_NAME}'"
        kill "$pid" 2>/dev/null || true
        sleep 5
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return "$RC_IDLE_EXPIRED"
      fi
    fi
    sleep 15
  done
  wait "$pid"
}

# Runs a command, killing it if it is still going after <secs>. Returns the
# command's status, or 124 on timeout (coreutils' convention; macOS ships no
# timeout(1)). The command may be a function such as vmssh, which runs in a
# background subshell whose ssh child would outlive a kill of the subshell
# alone, so its children are signalled first.
with_timeout() { # <secs> <command> [args...]
  local secs="$1" pid deadline
  shift
  "$@" &
  pid=$!
  deadline=$(( $(date +%s) + secs ))
  while kill -0 "$pid" 2>/dev/null; do
    if (( $(date +%s) >= deadline )); then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      sleep 2
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 2
  done
  wait "$pid"
}

scavenge_stale

IDLE_DEADLINE="$(idle_deadline)"
[[ -z "$IDLE_DEADLINE" ]] || log "policy $(slot_policy "$KIND"): runner retires after ${IDLE_DEADLINE}s without a job"

case "$KIND" in
mac)
  RUN_USER="_ghrunner${IDX}"
  SLOT_HOME="/var/ghrunner/slots/mac-${IDX}"
  RUNNER_DIR="${SLOT_HOME}/runner"

  # Kill anything the previous job left behind and reset scratch space, so
  # no state or background process survives into the next job.
  scrub() {
    pkill -9 -u "$RUN_USER" 2>/dev/null || true
    sleep 1
    rm -rf "${RUNNER_DIR}/_work" "${SLOT_HOME}/tmp"
    # MAC_KEEP_CACHES=true preserves ~/Library/Caches (CocoaPods, gems,
    # DerivedData) across jobs: faster, slightly less job-to-job isolation.
    [[ "${MAC_KEEP_CACHES:-false}" == "true" ]] || rm -rf "${SLOT_HOME}/Library/Caches"
    install -d -m 700 -o "$RUN_USER" -g staff "${SLOT_HOME}/tmp"
    find "${RUNNER_DIR}/_diag" -type f -mtime +7 -delete 2>/dev/null || true
  }

  scrub
  mint_jit || fail "JIT mint failed"
  log "starting macOS runner '${RUNNER_NAME}'"
  set +e
  run_runner sudo -u "$RUN_USER" -H env TMPDIR="${SLOT_HOME}/tmp" \
    bash -c "cd '${RUNNER_DIR}' && exec ./run.sh --jitconfig '${JIT}'"
  rc=$?
  set -e
  log "runner exited with status ${rc}; scrubbing slot"
  scrub
  ;;

linux|linux.*|linuxamd64)
  CONTAINER_BIN=/usr/local/bin/container
  CUID="$(id -u _ghcontainer)"
  # launchctl asuser gives the command the user's Mach bootstrap context,
  # which the container CLI needs to reach its XPC services headlessly.
  as_cuser() { launchctl asuser "$CUID" sudo -u _ghcontainer -H "$@"; }

  if ! as_cuser "$CONTAINER_BIN" system status >/dev/null 2>&1; then
    log "starting container system services"
    as_cuser "$CONTAINER_BIN" system start --enable-kernel-install || fail "could not start container system"
  fi

  # Select base image and resources by arch (amd64 images run under Rosetta
  # via --arch, and prefer LINUX_AMD64_* resource values), then let flavors
  # override any of it.
  ARCH_FLAG=()
  ROSETTA_FLAG=()
  IMAGE="ghrunner-linux:${RUNNER_VERSION}"
  CPUS="${LINUX_CPUS:-4}"
  MEMORY="${LINUX_MEMORY:-8G}"
  if [[ "$LINUX_ARCH" == "amd64" ]]; then
    IMAGE="ghrunner-linux-amd64:${RUNNER_VERSION}"
    CPUS="${LINUX_AMD64_CPUS:-$CPUS}"
    MEMORY="${LINUX_AMD64_MEMORY:-$MEMORY}"
    ARCH_FLAG=(--arch amd64)
  fi
  if [[ -n "$LINUX_FLAVOR" ]]; then
    IMAGE="$(fvar IMAGE)"
    [[ -n "$IMAGE" ]] || IMAGE="ghrunner-linux-${LINUX_FLAVOR}:${RUNNER_VERSION}"
    [[ -n "$(fvar CPUS)" ]] && CPUS="$(fvar CPUS)"
    [[ -n "$(fvar MEMORY)" ]] && MEMORY="$(fvar MEMORY)"
    if [[ "$(fvar ROSETTA)" == "true" ]]; then
      [[ "$LINUX_ARCH" == "arm64" ]] \
        || fail "flavor ${LINUX_FLAVOR}: ROSETTA=true requires ARCH=arm64"
      ROSETTA_FLAG=(--rosetta)
    fi
  fi

  # A previous cycle's container survives if the supervisor was killed
  # (re-provision, reboot) - the VM belongs to the apiserver, not to our
  # dead 'container run' client. Remove it before recreating any volume it
  # may still have mounted.
  as_cuser "$CONTAINER_BIN" delete --force "ghrunner-${SLOT_TAG}" >/dev/null 2>&1 || true

  # Heavy flavors can request a fresh, sized scratch volume. The image decides
  # which paths to place under /ghrunner-scratch; the Android image puts its
  # checkout, EAS staging dir, Gradle state, tool cache and TMPDIR there. The
  # volume is deleted after the job, preserving the same job-to-job isolation
  # as the disposable container while avoiding its small root filesystem.
  SCRATCH_VOLUME=""
  VOLUME_FLAG=()
  SCRATCH_DISK="$(fvar DISK)"
  WARP_ENV_FILE=""
  WARP_FLAGS=()
  cleanup_scratch() {
    [[ -n "$SCRATCH_VOLUME" ]] || return 0
    as_cuser "$CONTAINER_BIN" volume delete "$SCRATCH_VOLUME" >/dev/null 2>&1 || true
  }
  cleanup_warp_env() {
    [[ -z "$WARP_ENV_FILE" ]] || rm -f "$WARP_ENV_FILE"
  }
  cleanup_linux() {
    cleanup_scratch
    cleanup_warp_env
  }
  if [[ -n "$SCRATCH_DISK" ]]; then
    [[ "$SCRATCH_DISK" =~ ^[1-9][0-9]*[KMGTP]?$ ]] \
      || fail "invalid scratch disk size '$SCRATCH_DISK' for flavor ${LINUX_FLAVOR}"
    SCRATCH_VOLUME="ghrunner-${SLOT_TAG}-scratch"
    cleanup_scratch
    as_cuser "$CONTAINER_BIN" volume create -s "$SCRATCH_DISK" "$SCRATCH_VOLUME" >/dev/null \
      || fail "could not create ${SCRATCH_DISK} scratch volume for flavor ${LINUX_FLAVOR}"
    VOLUME_FLAG=(--volume "${SCRATCH_VOLUME}:/ghrunner-scratch")
  fi

  # A flavor can opt into a per-container Cloudflare WARP connection. The
  # image entrypoint consumes this env file before starting the job and the
  # runtime grants only the capability needed to manage its private tunnel.
  # The file is visible to the trusted container service account, not mounted
  # into the VM, and is removed as soon as the disposable container exits.
  WARP_ORG="$(fvar WARP_ORG)"
  if [[ -n "$WARP_ORG" ]]; then
    [[ "$WARP_ORG" =~ ^[A-Za-z0-9._-]+$ ]] \
      || { cleanup_linux; fail "invalid WARP org for flavor ${LINUX_FLAVOR}"; }
    [[ -s /etc/ghrunner/warp.env ]] \
      || { cleanup_linux; fail "flavor ${LINUX_FLAVOR} needs WARP but /etc/ghrunner/warp.env is missing"; }
    # shellcheck disable=SC1091
    . /etc/ghrunner/warp.env
    [[ "${WARP_AUTH_CLIENT_ID:-}" =~ ^[A-Za-z0-9._-]+$ \
       && "${WARP_AUTH_CLIENT_SECRET:-}" =~ ^[A-Za-z0-9._-]+$ ]] \
      || { cleanup_linux; fail "invalid or missing WARP service token"; }
    WARP_ENV_FILE="/var/ghrunner/warp-${SLOT_TAG}.env"
    umask 077
    printf 'WARP_ORG=%s\nWARP_AUTH_CLIENT_ID=%s\nWARP_AUTH_CLIENT_SECRET=%s\n' \
      "$WARP_ORG" "$WARP_AUTH_CLIENT_ID" "$WARP_AUTH_CLIENT_SECRET" \
      > "$WARP_ENV_FILE"
    chown _ghcontainer:staff "$WARP_ENV_FILE"
    WARP_FLAGS=(--cap-add CAP_NET_ADMIN --env-file "$WARP_ENV_FILE")
  fi

  mint_jit || { cleanup_linux; fail "JIT mint failed"; }
  log "starting Linux runner '${RUNNER_NAME}' (image ${IMAGE})"
  set +e
  run_runner as_cuser "$CONTAINER_BIN" run --rm \
    ${ARCH_FLAG[@]+"${ARCH_FLAG[@]}"} \
    ${ROSETTA_FLAG[@]+"${ROSETTA_FLAG[@]}"} \
    ${VOLUME_FLAG[@]+"${VOLUME_FLAG[@]}"} \
    ${WARP_FLAGS[@]+"${WARP_FLAGS[@]}"} \
    --name "ghrunner-${SLOT_TAG}" \
    --cpus "$CPUS" \
    --memory "$MEMORY" \
    --env "GH_JIT_CONFIG=${JIT}" \
    "$IMAGE"
  rc=$?
  set -e
  # 'container run --rm' only cleans up when the client exits on its own; a
  # retired-idle cycle killed the client, so remove the container explicitly.
  if (( rc == RC_IDLE_EXPIRED )); then
    as_cuser "$CONTAINER_BIN" delete --force "ghrunner-${SLOT_TAG}" >/dev/null 2>&1 || true
  fi
  cleanup_linux
  log "container exited with status ${rc}"
  ;;

linuxvm)
  CONTAINER_BIN=/usr/local/bin/container
  CUID="$(id -u _ghcontainer)"
  # launchctl asuser gives the command the user's Mach bootstrap context,
  # which the container CLI needs to reach its XPC services headlessly.
  as_cuser() { launchctl asuser "$CUID" sudo -u _ghcontainer -H "$@"; }

  if ! as_cuser "$CONTAINER_BIN" system status >/dev/null 2>&1; then
    log "starting container system services"
    as_cuser "$CONTAINER_BIN" system start --enable-kernel-install || fail "could not start container system"
  fi

  VM="ghrunner-${SLOT_TAG}"
  IMAGE="ghrunner-linuxvm:${RUNNER_VERSION}"

  machine_teardown() {
    as_cuser "$CONTAINER_BIN" machine stop "$VM" >/dev/null 2>&1 || true
    as_cuser "$CONTAINER_BIN" machine delete "$VM" >/dev/null 2>&1 || true
  }

  # Remove leftovers from a previously crashed cycle - the machine belongs
  # to the apiserver, not to our dead client process.
  machine_teardown

  log "creating machine ${VM} (image ${IMAGE})"
  as_cuser "$CONTAINER_BIN" machine create "$IMAGE" --name "$VM" \
    --home-mount none \
    --cpus "${LINUXVM_CPUS:-4}" --memory "${LINUXVM_MEMORY:-8}G" \
    || fail "machine create failed (was this slot provisioned?)"

  # Piped (non-interactive) execs fail against the boot left behind by
  # 'machine create' - and stop the machine - while a boot started by
  # 'machine run' accepts them fine (container 1.1.0). Clear the create-time
  # boot so the first poll below re-boots the machine itself. (--no-boot is
  # no alternative: a never-booted machine can't be booted by 'machine run'.)
  as_cuser "$CONTAINER_BIN" machine stop "$VM" >/dev/null 2>&1 || true

  # The first run boots the machine's systemd; wait for dockerd so docker
  # is usable the moment the runner picks up a job (~15s typically).
  ready=""
  for _ in $(seq 1 60); do
    if as_cuser "$CONTAINER_BIN" machine run -n "$VM" --root -- 'docker info >/dev/null 2>&1' 2>/dev/null; then
      ready=1; break
    fi
    sleep 2
  done
  [[ -n "$ready" ]] || { machine_teardown; fail "dockerd in ${VM} never became ready"; }

  mint_jit || { machine_teardown; fail "JIT mint failed"; }
  log "starting Linux VM runner '${RUNNER_NAME}' in ${VM}"
  set +e
  # 'machine run' joins its arguments into one string executed via the guest
  # shell's -c, so hand it exactly one self-contained command string. Note
  # execs get HOME=/home/<user> regardless of passwd - correct for 'runner'.
  run_runner as_cuser "$CONTAINER_BIN" machine run -n "$VM" -u runner -- \
    "cd /home/runner/runner && TMPDIR=/home/runner/tmp ./run.sh --jitconfig '${JIT}'"
  rc=$?
  set -e
  log "VM runner exited with status ${rc}; deleting machine"
  machine_teardown
  ;;

linuxvmamd64)
  LIMACTL_BIN=/usr/local/lima/bin/limactl
  LUID="$(id -u _ghlima)"
  # env PATH="$PATH" carries the daemon PATH (with Homebrew's bindir) past
  # sudo's secure_path so limactl can find qemu.
  as_lima() { launchctl asuser "$LUID" sudo -u _ghlima -H env PATH="$PATH" "$LIMACTL_BIN" "$@"; }
  VM="ghrunner-${SLOT}"

  # A QEMU-emulated guest boots much slower than a vz one; give it longer
  # than lima's default 10m before declaring the start failed.
  START_TIMEOUT=30m
  if ! as_lima list --format '{{.Status}}' "$VM" 2>/dev/null | grep -qx "Running"; then
    log "starting VM ${VM}"
    as_lima start --tty=false --timeout "$START_TIMEOUT" "$VM" || fail "could not start VM ${VM} (was this slot provisioned?)"
  fi

  # First boot only: wait for the in-VM provision script (docker + runner
  # install) to finish before dispatching work.
  ready=""
  for _ in $(seq 1 60); do
    if as_lima shell "$VM" test -f /etc/ghrunner-provisioned 2>/dev/null; then ready=1; break; fi
    sleep 5
  done
  [[ -n "$ready" ]] || fail "VM ${VM} never finished provisioning"

  # Jobs in this slot share a persistent VM and its docker daemon, so
  # between-job hygiene is a scrub, not a rebuild (see README for the
  # isolation tradeoff): kill leftover processes, purge ALL docker state,
  # reset the work and temp dirs.
  scrub_vm() {
    as_lima shell "$VM" sudo bash -c '
      pkill -9 -u runner 2>/dev/null || true
      sleep 1
      docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1 || true
      docker system prune -af --volumes >/dev/null 2>&1 || true
      rm -rf /home/runner/runner/_work /home/runner/tmp
      install -d -o runner -g runner /home/runner/tmp
    ' || log "WARNING: scrub reported errors"
  }

  scrub_vm
  mint_jit || fail "JIT mint failed"
  log "starting Linux VM runner '${RUNNER_NAME}' in ${VM}"
  set +e
  run_runner as_lima shell "$VM" sudo -iu runner \
    bash -c "cd /home/runner/runner && TMPDIR=/home/runner/tmp ./run.sh --jitconfig '${JIT}'"
  rc=$?
  set -e
  log "VM runner exited with status ${rc}; scrubbing"
  scrub_vm
  # Retiring this slot only pays off if the persistent VM's memory is
  # actually released: stop the VM too. The next cycle's start boots it
  # again (slow - QEMU whole-system emulation).
  if (( rc == RC_IDLE_EXPIRED )); then
    log "stopping VM ${VM} until next demand"
    as_lima stop "$VM" >/dev/null 2>&1 || true
  fi
  ;;

macvm)
  TART_BIN=/usr/local/bin/tart
  TUID="$(id -u _ghtart)"
  as_tuser() { launchctl asuser "$TUID" sudo -u _ghtart -H "$@"; }
  as_tart() { as_tuser "$TART_BIN" "$@"; }

  # macOS guests need _ghtart's login keychain unlocked (Virtualization
  # host-key requirement, macOS 15+; see bootstrap.sh). Keychains lock on
  # reboot, so unlock every cycle.
  as_tuser security unlock-keychain -p '' login.keychain \
    || log "WARNING: could not unlock _ghtart keychain; expect a VM security error (re-provision to fix)"

  VM="ghrunner-vm-${IDX}"
  MACVM_IMAGE="${MACVM_IMAGE:?MACVM_IMAGE must be set in config}"
  GUEST_USER="${MACVM_SSH_USER:-admin}"
  export MACVM_SSH_PASSWORD="${MACVM_SSH_PASSWORD:-admin}"

  # Password auth into the guest without a tty, via the SSH_ASKPASS helper
  # (reads MACVM_SSH_PASSWORD). Host keys change with every clone.
  GUEST_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                  -o LogLevel=ERROR -o ConnectTimeout=10)
  vmssh() {
    local host="$1"; shift
    env SSH_ASKPASS=/opt/ghrunner/bin/vm-askpass.sh SSH_ASKPASS_REQUIRE=force \
      ssh "${GUEST_SSH_OPTS[@]}" "${GUEST_USER}@${host}" "$@"
  }
  vmscp() {
    env SSH_ASKPASS=/opt/ghrunner/bin/vm-askpass.sh SSH_ASKPASS_REQUIRE=force \
      scp "${GUEST_SSH_OPTS[@]}" "$@"
  }

  RUN_PID=""
  vm_teardown() {
    as_tart stop "$VM" 2>/dev/null || true
    sleep 3
    if [[ -n "$RUN_PID" ]]; then kill -9 "$RUN_PID" 2>/dev/null || true; fi
    # If delete fails (VM still winding down), the pre-clean of the next
    # cycle retries it.
    as_tart delete "$VM" 2>/dev/null || true
  }

  # Remove leftovers from a previously crashed cycle.
  as_tart delete "$VM" 2>/dev/null || true

  log "cloning ${MACVM_IMAGE} -> ${VM}"
  as_tart clone "$MACVM_IMAGE" "$VM" || fail "tart clone failed (image not pulled? disk full?)"
  as_tart set "$VM" --cpu "${MACVM_CPUS:-4}" --memory "${MACVM_MEMORY_MB:-8192}" \
    || { vm_teardown; fail "tart set failed"; }

  # A bridged slot should keep one network identity across ephemeral clones.
  # Tart deliberately randomizes clone MACs, which otherwise consumes a new
  # DHCP lease per cycle and makes DHCP reservations impossible. bootstrap.sh
  # validates this as a locally-administered unicast address.
  MAC_VAR="MACVM_MAC_${IDX}"
  MACVM_MAC="${!MAC_VAR:-}"
  if [[ -n "$MACVM_MAC" ]]; then
    VM_CONFIG="/var/ghrunner/tart/.tart/vms/${VM}/config.json"
    log "pinning ${VM} network identity to ${MACVM_MAC}"
    as_tuser /usr/bin/plutil -replace macAddress -string "$MACVM_MAC" "$VM_CONFIG" \
      || { vm_teardown; fail "could not set ${MAC_VAR} in Tart VM config"; }
  fi

  # Keep tart's output: when the VM process dies early this is the only
  # place the actual error lands. The .log suffix puts it under the
  # newsyslog rotation for slot logs.
  TART_LOG="/var/ghrunner/log/${SLOT_TAG}.tart.log"
  RUN_NET=()
  [[ -n "${MACVM_BRIDGE_IFACE:-}" ]] && RUN_NET=(--net-bridged="$MACVM_BRIDGE_IFACE")
  # Audio pass-through is off by default. The guest advertises a virtual sound
  # device, but a simulator app's CoreAudio calls to it never get answered and
  # block ~30s per HAL round-trip. UIKit's per-keystroke keyboard click is
  # enough to wedge an app's main thread for minutes, which surfaces in Maestro
  # as the XCUITest driver going "unreachable" during inputText (mobile-apps,
  # Aug-Sep 2026). No CI workload here needs guest sound; set MACVM_AUDIO=1 to
  # pass it through anyway.
  RUN_AUDIO=()
  [[ "${MACVM_AUDIO:-0}" == 1 ]] || RUN_AUDIO=(--no-audio)
  # Persistent caches. Off by default: a fresh clone per job is the isolation
  # model, and whatever the bake primed is all a job gets. With
  # MACVM_KEEP_CACHES=true a per-slot host dir is shared into the guest over
  # virtiofs (tart --dir) and, once the guest is up, its CocoaPods, yarn, npm,
  # Gradle (mirrored), ccache and runner tool caches are redirected onto it (see the setup block
  # below), so they survive the VM teardown and grow across jobs and re-bakes.
  # Per slot rather than shared, so two guests never write the same CocoaPods
  # cache at once. Owned by _ghtart because virtiofs performs guest file
  # operations as the tart process's user.
  #
  # The guest never writes the kept copy directly. The slot dir holds
  #   canonical/  what the next cycle starts from
  #   work/       this cycle's APFS clone of canonical (cp -c: instant, and
  #               no extra disk until the job changes something) - the dir
  #               actually shared into the guest
  #   prev/       the canonical before the last promotion, for
  #               `mise run runner:caches rollback <n>`
  # After the runner exits, work/ is promoted to canonical/ only if the job
  # ran to completion (Succeeded or Failed both count: a red build still
  # leaves valid dependencies and ccache objects behind). A cancelled job, a
  # killed runner or a VM that died mid-job leave whatever they were writing
  # half-done on the share; their work/ is thrown away instead, which is what
  # keeps one bad cycle from poisoning the slot for every later job.
  RUN_DIR=()
  HOST_CACHE=""
  if [[ "${MACVM_KEEP_CACHES:-false}" == "true" ]]; then
    HOST_CACHE="/var/ghrunner/cache/macvm-${IDX}"
    install -d -m 755 /var/ghrunner/cache
    install -d -m 700 -o _ghtart -g staff "$HOST_CACHE"
    # A slot dir from before this layout kept the stores at its top level;
    # move them under canonical/ once.
    if [[ ! -d "$HOST_CACHE/canonical" ]]; then
      install -d -m 755 -o _ghtart -g staff "$HOST_CACHE/canonical"
      for entry in "$HOST_CACHE"/* "$HOST_CACHE"/.[!.]*; do
        [[ -e "$entry" ]] || continue
        case "$(basename "$entry")" in canonical|work|prev) continue ;; esac
        log "moving pre-existing cache store $(basename "$entry") under canonical/"
        mv "$entry" "$HOST_CACHE/canonical/"
      done
    fi
    # A work/ left by a crashed cycle was never promoted; drop it.
    rm -rf "$HOST_CACHE/work"
    # -p as root keeps _ghtart's ownership and the mtimes the guest's Gradle
    # rsync compares; -c clones instead of copying.
    cp -Rpc "$HOST_CACHE/canonical" "$HOST_CACHE/work" \
      || fail "could not clone ${HOST_CACHE}/canonical to work/"
    RUN_DIR=(--dir="cache:${HOST_CACHE}/work")
  fi
  # ${a[@]+"${a[@]}"}, not "${a[@]}": macOS ships bash 3.2, where expanding an
  # empty array under `set -u` is an unbound-variable error.
  as_tart run "$VM" --no-graphics \
    ${RUN_AUDIO[@]+"${RUN_AUDIO[@]}"} ${RUN_NET[@]+"${RUN_NET[@]}"} \
    ${RUN_DIR[@]+"${RUN_DIR[@]}"} >"$TART_LOG" 2>&1 &
  RUN_PID=$!

  # A bridged guest leases from the LAN's DHCP server, so tart's default
  # resolver — which parses the host's own NAT lease file — never sees it.
  # "agent" asks the guest directly over vsock and is always current; "arp"
  # is the fallback for images without the guest agent, and only answers
  # once the host has traffic with the guest, so it lags on a cold cache.
  if [[ -n "${MACVM_BRIDGE_IFACE:-}" ]]; then
    RESOLVERS=(agent arp)
  else
    RESOLVERS=(dhcp)
  fi
  # Resolvers print a human-readable "no IP address found ..." on failure as
  # readily as they exit non-zero, so match the shape of the answer.
  vm_ip() {
    local r out
    for r in "${RESOLVERS[@]}"; do
      out="$(as_tart ip "$VM" --resolver "$r" 2>/dev/null)" || continue
      if [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # A bridged guest that failed DHCP can self-assign 169.254/16. That
        # address is syntactically valid but unusable from the host for this
        # runner, and accepting it turns the following SSH loop into a long
        # false-positive wait instead of recycling the VM for another lease.
        [[ "$out" == 169.254.* ]] && continue
        printf '%s' "$out"; return 0
      fi
    done
    return 1
  }

  IP=""
  for _ in $(seq 1 60); do
    if ! kill -0 "$RUN_PID" 2>/dev/null; then
      vm_teardown
      fail "tart run exited before the VM got an IP: $(tail -c 500 "$TART_LOG" 2>/dev/null | tr '\n' ' ')"
    fi
    if IP="$(vm_ip)" && [[ -n "$IP" ]]; then break; fi
    IP=""
    sleep 3
  done
  [[ -n "$IP" ]] || { vm_teardown; fail "VM did not get an IP within 3 minutes"; }

  ssh_up=""
  for _ in $(seq 1 60); do
    if ! kill -0 "$RUN_PID" 2>/dev/null; then
      vm_teardown
      fail "tart run exited before SSH became ready: $(tail -c 500 "$TART_LOG" 2>/dev/null | tr '\n' ' ')"
    fi
    if vmssh "$IP" true 2>/dev/null; then ssh_up=1; break; fi
    sleep 3
  done
  [[ -n "$ssh_up" ]] || { vm_teardown; fail "could not reach VM at ${IP} over SSH"; }

  # Give a bridged guest this slot's name so it lands in DNS somewhere
  # predictable and a person can Screen Share into a running build without
  # hunting for its lease. Every clone boots with the image's baked
  # hostname, so without this both slots would register the same name and
  # the second would overwrite the first. The DHCP renew is what actually
  # re-registers it — the scutil sets alone leave the old name in DNS.
  # Non-fatal: a job running under the wrong name beats a failed job.
  VM_HOSTNAME=""
  if [[ -n "${MACVM_BRIDGE_IFACE:-}" ]]; then
    VM_HOSTNAME="${NAME_PREFIX}-vm-${IDX}"
    log "naming guest ${VM_HOSTNAME} and renewing its lease to register it"
    vmssh "$IP" "sudo scutil --set ComputerName '${VM_HOSTNAME}'; \
                 sudo scutil --set LocalHostName '${VM_HOSTNAME}'; \
                 sudo scutil --set HostName '${VM_HOSTNAME}'; \
                 sudo ipconfig set en0 DHCP" 2>/dev/null \
      || log "WARNING: could not name guest; it stays in DNS under the image's baked hostname"

    # The renew usually returns the same lease, but it can hand back a
    # different address — re-resolve before anything else uses $IP.
    NEWIP=""
    for _ in $(seq 1 20); do
      if NEWIP="$(vm_ip)" && [[ -n "$NEWIP" ]]; then break; fi
      NEWIP=""
      sleep 3
    done
    if [[ -n "$NEWIP" && "$NEWIP" != "$IP" ]]; then
      log "guest address changed over the renew: ${IP} -> ${NEWIP}"
      IP="$NEWIP"
    fi
    ssh_up=""
    for _ in $(seq 1 20); do
      if ! kill -0 "$RUN_PID" 2>/dev/null; then
        vm_teardown
        fail "tart run exited after the DHCP renew: $(tail -c 500 "$TART_LOG" 2>/dev/null | tr '\n' ' ')"
      fi
      if vmssh "$IP" true 2>/dev/null; then ssh_up=1; break; fi
      sleep 3
    done
    [[ -n "$ssh_up" ]] || { vm_teardown; fail "lost the VM at ${IP} after the DHCP renew"; }
  fi

  # Enroll the guest in Cloudflare WARP so the job can reach VPN-only hosts -
  # notably api.internal.example.com, which the mobile app's GraphQL codegen
  # introspects (the public exposed.dev host refuses introspection, so there
  # is no non-VPN path). The image ships warp-cli but deliberately no
  # registration: one registration is one device, so a baked-in one would be
  # shared by every clone and would break for all of them the moment that
  # device were removed. Each VM therefore enrolls itself here with the
  # service token kept on the host.
  #
  # Non-fatal by design, matching the guest-naming step above: failing the
  # cycle would put launchd into a 15s crash-loop on a bad token, whereas a
  # job that fails at codegen with this WARNING in the slot log is
  # diagnosable. Anything not behind the VPN still builds fine.
  if [[ -s /etc/ghrunner/warp.env ]]; then
    # shellcheck disable=SC1091
    . /etc/ghrunner/warp.env
    WARP_ORG="${MACVM_WARP_ORG:?Set MACVM_WARP_ORG when WARP credentials are configured}"
    log "enrolling guest in Cloudflare WARP (org ${WARP_ORG})"
    # The plist goes in over stdin so the token never lands in a command line
    # (it would otherwise be visible in the guest's process list).
    if printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict>' \
        "  <key>organization</key><string>${WARP_ORG}</string>" \
        "  <key>auth_client_id</key><string>${WARP_AUTH_CLIENT_ID}</string>" \
        "  <key>auth_client_secret</key><string>${WARP_AUTH_CLIENT_SECRET}</string>" \
        '  <key>service_mode</key><string>warp</string>' \
        '  <key>auto_connect</key><integer>1</integer>' \
        '</dict></plist>' \
      | vmssh "$IP" "sudo install -d -m 755 '/Library/Managed Preferences' \
          && umask 077 \
          && sudo tee '/Library/Managed Preferences/com.cloudflare.warp.plist' >/dev/null"
    then
      # The daemon only attempts service-token auth on a fresh start: started
      # before the plist existed, it caches "no registration" and later
      # `registration new` calls short-circuit without ever calling Access.
      # Restarting it after the plist is in place is what makes enrollment work.
      WARP_CLI=/usr/local/bin/warp-cli
      vmssh "$IP" "sudo launchctl kickstart -k system/com.cloudflare.1dot1dot1dot1.macos.warp.daemon" \
        >/dev/null 2>&1 || true
      sleep 12
      vmssh "$IP" "sudo ${WARP_CLI} --accept-tos registration new" >/dev/null 2>&1 || true

      # Retry `connect` every round instead of only polling: issued straight
      # after `registration new` it lands before the registration has settled
      # and leaves the client parked in "Disconnected / Manual Disconnection",
      # which no amount of polling recovers from.
      warp_state=""
      for _ in $(seq 1 20); do
        if vmssh "$IP" "${WARP_CLI} --accept-tos status" 2>/dev/null | grep -q Connected; then
          warp_state=connected; break
        fi
        vmssh "$IP" "sudo ${WARP_CLI} --accept-tos connect" >/dev/null 2>&1 || true
        sleep 3
      done
      if [[ "$warp_state" == connected ]]; then
        log "WARP connected in guest"
        # "Connected" is the registration; the tunnel then reports
        # "Network: unstable" for a while, and traffic through it during that
        # window can stall (canary runs 33820894728 and 33822965222: npm's
        # audit POST took 15 s to 3 min while status said unstable, well under
        # a second once it said healthy; every GET was fine throughout). Every
        # cold boot showed the window, healthy arriving 10 s to several
        # minutes later. Give it a bounded head start before the runner takes
        # a job; a slot that stays unstable still starts, just as before.
        warp_settle_max="${MACVM_WARP_SETTLE_MAX:-90}"
        warp_net=""
        for (( waited=0; waited < warp_settle_max; waited+=5 )); do
          warp_net="$(vmssh "$IP" "${WARP_CLI} --accept-tos status" 2>/dev/null \
            | awk -F': *' '/^Network:/{print $2}')"
          [[ "$warp_net" == healthy ]] && break
          sleep 5
        done
        if [[ "$warp_net" == healthy ]]; then
          log "WARP network healthy after ${waited}s"
        else
          log "WARNING: WARP network still '${warp_net:-unknown}' after ${warp_settle_max}s; starting anyway"
        fi
      else
        log "WARNING: WARP did not connect; VPN-only hosts (api.internal.example.com) will be unreachable and codegen will fail"
      fi
    else
      log "WARNING: could not write WARP config into guest; VPN-only hosts will be unreachable"
    fi
  fi

  # Redirect the guest's caches onto the shared dir (MACVM_KEEP_CACHES). Tart
  # auto-mounts every --dir under "/Volumes/My Shared Files/<name>"; a
  # space-free symlink ($HOME/.ghrunner-cache) fronts it so no build tool has
  # to cope with that path. Each cache path the image may have baked warm is
  # replaced by a symlink into the share; a share subdir that does not exist
  # yet is seeded from the image's copy first, so the first job on a fresh
  # host starts as warm as the image rather than colder. ccache and the runner
  # tool cache need no symlink: they follow env vars, written to the runner's
  # .env below. Non-fatal: without the share the job simply runs on the
  # image's baked caches, as it did before this existed.
  CACHE_ROOT=""
  if [[ -n "$HOST_CACHE" ]]; then
    GUEST_HOME="$(vmssh "$IP" 'printf %s "$HOME"' 2>/dev/null || true)"
    [[ -n "$GUEST_HOME" ]] || GUEST_HOME="/Users/${GUEST_USER}"
    log "redirecting guest caches onto ${HOST_CACHE}/work"
    if vmssh "$IP" 'bash -s' <<'GUEST_CACHES'
set -u
MOUNT="/Volumes/My Shared Files/cache"
# virtiofs mounts shortly after boot; SSH can be up first.
for _ in $(seq 1 20); do [ -d "$MOUNT" ] && break; sleep 3; done
[ -d "$MOUNT" ] || { echo "shared dir not mounted at $MOUNT" >&2; exit 1; }
touch "$MOUNT/.rw-probe" 2>/dev/null && rm -f "$MOUNT/.rw-probe" \
  || { echo "shared dir at $MOUNT is not writable" >&2; exit 1; }
LINK="$HOME/.ghrunner-cache"
rm -rf "$LINK" && ln -s "$MOUNT" "$LINK"
# <guest path relative to $HOME>:<subdir of the share>
for spec in "Library/Caches/CocoaPods:cocoapods" ".cocoapods/repos:cocoapods-repos" \
            ".yarn/berry/cache:yarn" ".npm:npm"; do
  src="$HOME/${spec%%:*}"; dst="$LINK/${spec##*:}"
  if [ ! -d "$dst" ]; then
    mkdir -p "$dst"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
      echo "seeding ${spec##*:} from the image ($(du -sh "$src" 2>/dev/null | cut -f1))"
      ditto "$src" "$dst" || echo "WARNING: seeding ${spec##*:} failed; continuing with a partial cache" >&2
    fi
  fi
  rm -rf "$src" && mkdir -p "$(dirname "$src")" && ln -s "$dst" "$src"
done
mkdir -p "$LINK/ccache" "$LINK/toolcache"
# Gradle's user home cannot live on the share the way the paths above do, and
# not all of it can even be mirrored:
#   - Gradle keeps binary stores it writes and re-reads with random access
#     across processes (.tmp/*.bin, the daemon registry, caches/<ver>/
#     fileHashes ...); AppleVirtIOFS handed one a short read and the daemon
#     died (run 33708207661 failed in 17s).
#   - caches/<ver>/transforms are "immutable workspaces" whose contents Gradle
#     fingerprints; rsyncing that tree between the image's copy and a previous
#     job's copy produced a workspace Gradle rejected as modified (run
#     33709969729 failed in 58s).
# ccache and CocoaPods are fine on the share because they write whole files
# once and read them back later. So ~/.gradle stays on the guest's own disk,
# and the share carries a mirror of just its content-addressed stores, where
# merging copies from different runs is safe by construction: the dependency
# cache (modules-2), the local build cache (build-cache-1), the generated jars
# (jars-9) and the wrapper distributions. Everything else stays as the image
# shipped it (mobile-bake 20-prime-repo.sh primes ~/.gradle). The mirror is
# synced in here and back by the slot after the runner exits, via the helper
# written below so both directions share one definition.
cat > "$HOME/.ghrunner-gradle-sync" <<'SYNC'
#!/bin/bash
# Written by run-slot.sh (GUEST_CACHES). Usage: .ghrunner-gradle-sync in|out
set -u
dir="${1:?in|out}"
LOCAL="$HOME/.gradle"; MIRROR="$HOME/.ghrunner-cache/gradle"
# A daemon left running after the build may still be writing; stop it first.
if [ "$dir" = out ]; then pkill -f GradleDaemon 2>/dev/null && sleep 3; fi
for sub in caches/modules-2 caches/build-cache-1 caches/jars-9 wrapper; do
  if [ "$dir" = in ]; then src="$MIRROR/$sub"; dst="$LOCAL/$sub"
  else src="$LOCAL/$sub"; dst="$MIRROR/$sub"; fi
  [ -d "$src" ] || continue
  mkdir -p "$dst"
  # Gradle's per-process *.lock markers never travel. --delete-excluded lets
  # rsync drop the receiving side's, too: without it a jars-9 entry the image
  # has but the mirror lacks keeps its lock file, and rsync logs "not empty,
  # cannot delete" for each one (~30 per boot). Nothing holds a lock here:
  # sync-in runs before the runner starts, sync-out after the daemon is gone.
  rsync -a --delete --delete-excluded --exclude='*.lock' "$src/" "$dst/" \
    || echo "WARNING: gradle sync-$dir of $sub failed" >&2
done
SYNC
chmod +x "$HOME/.ghrunner-gradle-sync"
mkdir -p "$HOME/.gradle"
if [ ! -d "$LINK/gradle/caches" ]; then
  echo "seeding gradle from the image ($(du -sh "$HOME/.gradle/caches/modules-2" 2>/dev/null | cut -f1) of dependencies)"
  "$HOME/.ghrunner-gradle-sync" out
else
  echo "syncing gradle in from the share"
  "$HOME/.ghrunner-gradle-sync" in
fi
# Gradle's local build cache is off unless a build asks for it, and the Expo
# template's gradle.properties does not. Switching it on from the user-level
# file makes every Android build on this slot reuse task outputs (compiled
# React Native library modules, codegen, resource merging) whose inputs are
# unchanged since an earlier job; Gradle keys them by content hash, so this
# is safe across commits.
GP="$HOME/.gradle/gradle.properties"
grep -qs '^org\.gradle\.caching=' "$GP" || echo 'org.gradle.caching=true' >> "$GP"
GUEST_CACHES
    then
      CACHE_ROOT="${GUEST_HOME}/.ghrunner-cache"
    else
      log "WARNING: shared cache dir unusable in guest; this job runs on the image's baked caches only"
    fi
  fi

  TARBALL="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
  vmscp "/opt/ghrunner/cache/${TARBALL}" "${GUEST_USER}@${IP}:runner.tar.gz" \
    || { vm_teardown; fail "could not copy runner into VM"; }
  vmssh "$IP" "mkdir -p runner && tar -xzf runner.tar.gz -C runner" \
    || { vm_teardown; fail "could not unpack runner in VM"; }

  # Give guest jobs the same .env/.path treatment bare mac slots get (see the
  # MAC_ENV_* block in bootstrap.sh): the runner reads both from its root dir
  # at startup. A job's shell here is non-interactive and inherits almost
  # nothing, which bites in two ways:
  #   - No locale is set, so Ruby falls back to ASCII-8BIT and CocoaPods dies
  #     in unicode_normalize. `expo prebuild` only *warns* when `pod install`
  #     fails, so the real symptom lands minutes later as a missing
  #     ios/*.xcworkspace. MACVM_ENV_LANG=en_US.UTF-8 is what avoids it.
  #   - path_helper never runs, so /usr/local/bin (warp-cli) and
  #     /opt/homebrew/bin are off PATH unless MACVM_EXTRA_PATH restores them.
  # Deliberately separate from MAC_ENV_*/MAC_EXTRA_PATH: those name paths on
  # the *host*, which do not exist inside the guest.
  guest_env=""
  # Cache locations for the tools that follow env vars rather than a fixed
  # path, only when the share is up. A MACVM_ENV_<NAME> in config wins over
  # each default. GHRUNNER_CACHE_DIR is for workflows that want to park
  # something else there (Gradle, DerivedData, ...). USE_CCACHE itself is
  # deliberately not set here: whether a build runs through ccache is the
  # job's (or the config's) call, this only makes the cache persistent.
  cache_default() { # <NAME> <value>
    local v="MACVM_ENV_$1"
    [[ -n "${!v:-}" ]] || guest_env+="$1=$2"$'\n'
  }
  if [[ -n "$CACHE_ROOT" ]]; then
    cache_default GHRUNNER_CACHE_DIR "$CACHE_ROOT"
    cache_default CCACHE_DIR "${CACHE_ROOT}/ccache"
    # ccache's 5G default is under one React Native app's object files.
    cache_default CCACHE_MAXSIZE 20G
    cache_default RUNNER_TOOL_CACHE "${CACHE_ROOT}/toolcache"
  fi
  # React Native's ccache wrappers (scripts/xcode/ccache-clang.sh) end in
  # `exec $CCACHE_BINARY clang "$@"`, and RN sets CCACHE_BINARY only as an
  # Xcode *build setting*. Xcode hands each compile task xcodebuild's
  # environment but none of the build settings (verified on Xcode 26.5 with an
  # env-dumping CC), so the wrapper sees an empty CCACHE_BINARY and execs plain
  # clang: the build passes and ccache is never called (run 33697984118:
  # 13.5 min of xcodebuild, `ccache -s` "Stats updated: never"). Export the
  # binary's path as an env var instead, which the wrapper does inherit. Only
  # when the image has ccache; harmless when nothing sets USE_CCACHE.
  GUEST_CCACHE="$(vmssh "$IP" \
    "PATH=\"${MACVM_EXTRA_PATH:+${MACVM_EXTRA_PATH}:}\$PATH\" command -v ccache" 2>/dev/null || true)"
  if [[ -n "$GUEST_CCACHE" ]]; then
    cache_default CCACHE_BINARY "$GUEST_CCACHE"
  fi
  for v in $(compgen -A variable MACVM_ENV_ || true); do
    guest_env+="${v#MACVM_ENV_}=${!v}"$'\n'
  done
  if [[ -n "$guest_env" ]]; then
    printf '%s' "$guest_env" | vmssh "$IP" "cat > runner/.env" \
      || { vm_teardown; fail "could not write runner .env in VM"; }
  fi
  if [[ -n "${MACVM_EXTRA_PATH:-}" ]]; then
    printf '%s\n' "${MACVM_EXTRA_PATH}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      | vmssh "$IP" "cat > runner/.path" \
      || { vm_teardown; fail "could not write runner .path in VM"; }
  fi

  mint_jit || { vm_teardown; fail "JIT mint failed"; }
  log "starting macOS VM runner '${RUNNER_NAME}' in ${VM} (${IP}${VM_HOSTNAME:+, screen sharing at ${VM_HOSTNAME}})"
  set +e
  # The runner's exit status says whether the runner was healthy, not how the
  # job went; the only record of that is its "Job <name> completed with
  # result: <Succeeded|Failed|Canceled>" line. Keep a copy of the output in
  # the guest so it can be read back after the fact (it also still streams
  # into the slot log as before).
  run_runner vmssh "$IP" "cd runner && set -o pipefail && ./run.sh --jitconfig '${JIT}' 2>&1 | tee runner.out"
  rc=$?
  set -e
  job_result=""
  if (( rc != RC_IDLE_EXPIRED )); then
    job_result="$(vmssh "$IP" "grep -o 'completed with result: [A-Za-z]*' runner/runner.out | tail -1 | awk '{print \$NF}'" 2>/dev/null || true)"
  fi
  # Promote or discard this cycle's cache writes (see the layout note above
  # the tart run). The Gradle mirror is synced back into work/ first when
  # promoting - the counterpart of the sync-in in GUEST_CACHES, same helper -
  # and not at all when discarding, where it would only be thrown away.
  if [[ -n "$HOST_CACHE" ]]; then
    case "$job_result" in
      Succeeded|Failed)
        if [[ -n "$CACHE_ROOT" ]]; then
          log "syncing the guest's Gradle caches back onto the share"
          # Normally 30-70 s. On 2026-10-26 one sat for ~8 h after rsync
          # warnings about files vanishing under it, holding macvm-1 and its
          # VM's disk the whole day. On a timeout the VM is stopped before
          # promoting, so a guest rsync that outlives its ssh cannot keep
          # writing into work/ as it becomes canonical/. rsync renames each
          # file into place whole, so a cut-short sync leaves a usable mirror,
          # as a failed one already does.
          sync_rc=0
          with_timeout 600 vmssh "$IP" '"$HOME/.ghrunner-gradle-sync" out' || sync_rc=$?
          if (( sync_rc == 124 )); then
            log "WARNING: Gradle sync-out still running after 600s; stopping the VM"
            as_tart stop "$VM" 2>/dev/null || true
          fi
          (( sync_rc == 0 )) \
            || log "WARNING: Gradle sync-out failed; promoting the share without this job's Gradle changes"
        fi
        log "job ${job_result}; promoting this cycle's cache to canonical (previous kept in prev/)"
        rm -rf "$HOST_CACHE/prev"
        if mv "$HOST_CACHE/canonical" "$HOST_CACHE/prev"; then
          mv "$HOST_CACHE/work" "$HOST_CACHE/canonical" \
            || { log "WARNING: could not promote work/; restoring the previous canonical"; mv "$HOST_CACHE/prev" "$HOST_CACHE/canonical" || true; }
        else
          log "WARNING: could not set aside canonical/; keeping it and discarding this cycle's cache writes"
          rm -rf "$HOST_CACHE/work"
        fi
        ;;
      *)
        if (( rc == RC_IDLE_EXPIRED )); then
          log "no job ran; discarding the untouched cache clone"
        else
          log "job result '${job_result:-unknown}' (cancelled, or the runner did not finish); discarding this cycle's cache writes"
        fi
        rm -rf "$HOST_CACHE/work"
        ;;
    esac
  fi
  log "VM runner exited with status ${rc}; deleting VM"
  vm_teardown
  ;;
esac

# A retired-idle runner leaves a registration behind that GitHub can list
# as online for a few more seconds; scavenge it now rather than waiting for
# the next cycle, which on a scheduled slot may be days away.
if (( ${rc:-0} == RC_IDLE_EXPIRED )); then
  sleep 10
  scavenge_stale
fi

exit 0
