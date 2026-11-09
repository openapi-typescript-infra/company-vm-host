#!/bin/bash
# Provisions this Mac as a fleet of ephemeral GitHub Actions runner slots.
# Runs as root on the target; invoked by provision.sh with the uploaded
# payload directory. Safe to re-run: it upgrades scripts in place and adds
# or removes slots to match runner.env (restarting slots interrupts any
# job currently running on them).
set -euo pipefail

PAYLOAD="${1:?usage: bootstrap.sh <payload-dir>}"

die() { echo "bootstrap: error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"
[[ "$(uname -m)" == "arm64" ]] || die "Apple silicon required"

# Non-interactive SSH sessions get a minimal PATH without /usr/local/bin,
# and sudo can reset PATH (secure_path); reference the tool binaries by
# absolute path so neither matters. Homebrew's bindir is included so QEMU
# (needed by amd64 linuxvm slots) can be discovered.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
CONTAINER_BIN=/usr/local/bin/container
TART_BIN=/usr/local/bin/tart
LIMACTL_BIN=/usr/local/lima/bin/limactl

source "$PAYLOAD/runner.env"
GH_ORG="${GH_ORG:?GH_ORG must be set in runner.env}"
MAC_RUNNERS="${MAC_RUNNERS:-0}"
LINUX_RUNNERS="${LINUX_RUNNERS:-0}"
LINUX_AMD64_RUNNERS="${LINUX_AMD64_RUNNERS:-0}"
MACVM_RUNNERS="${MACVM_RUNNERS:-0}"
LINUXVM_RUNNERS="${LINUXVM_RUNNERS:-0}"
LINUXVM_AMD64_RUNNERS="${LINUXVM_AMD64_RUNNERS:-0}"
RUNNER_VERSION="${RUNNER_VERSION:-2.338.2}"
CONTAINER_VERSION="${CONTAINER_VERSION:-1.7.1}"
TART_VERSION="${TART_VERSION:-2.41.1}"
LIMA_VERSION="${LIMA_VERSION:-2.3.0}"
MACVM_IMAGE="${MACVM_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
INSTALL_XCODE_CLT="${INSTALL_XCODE_CLT:-true}"
LINUX_BUILD_CPUS="${LINUX_BUILD_CPUS:-4}"
LINUX_BUILD_MEMORY="${LINUX_BUILD_MEMORY:-8G}"
LINUX_IMAGE_BUILD_TIMEOUT="${LINUX_IMAGE_BUILD_TIMEOUT:-3600}"
[[ "$LINUX_BUILD_CPUS" =~ ^[1-9][0-9]*$ ]] || die "LINUX_BUILD_CPUS must be a positive integer"
[[ "$LINUX_BUILD_MEMORY" =~ ^[1-9][0-9]*[KMGTP]?$ ]] || die "invalid LINUX_BUILD_MEMORY '$LINUX_BUILD_MEMORY'"
[[ "$LINUX_IMAGE_BUILD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "LINUX_IMAGE_BUILD_TIMEOUT must be a positive integer (seconds)"

# Linux image flavors: validate names (they become env-var fragments, slot
# names, and launchd labels) and arch, count their slots, and note whether
# the bundled amd64 base image is needed (amd64 slots, or a shipped-context
# amd64 flavor whose Dockerfile may build FROM it).
LINUX_FLAVORS="${LINUX_FLAVORS:-}"
LINUX_TOTAL="$LINUX_RUNNERS"
AMD64_BASE_NEEDED=no
(( LINUX_AMD64_RUNNERS > 0 )) && AMD64_BASE_NEEDED=yes
for f in $LINUX_FLAVORS; do
  [[ "$f" =~ ^[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*$ ]] \
    || die "invalid flavor name '$f' (alphanumeric, at least one letter)"
  rv="LINUX_FLAVOR_${f}_RUNNERS"
  LINUX_TOTAL=$(( LINUX_TOTAL + ${!rv:-0} ))
  av="LINUX_FLAVOR_${f}_ARCH"
  case "${!av:-arm64}" in
    arm64) ;;
    amd64) [[ -d "$PAYLOAD/images/$f" ]] && AMD64_BASE_NEEDED=yes ;;
    *) die "flavor '$f': ${av} must be arm64 or amd64 (got '${!av}')" ;;
  esac
  rosetta_v="LINUX_FLAVOR_${f}_ROSETTA"
  case "${!rosetta_v:-false}" in
    false|true) ;;
    *) die "flavor '$f': ${rosetta_v} must be true or false (got '${!rosetta_v}')" ;;
  esac
  if [[ "${!rosetta_v:-false}" == true && "${!av:-arm64}" != arm64 ]]; then
    die "flavor '$f': ${rosetta_v}=true requires ${av}=arm64"
  fi
  dv="LINUX_FLAVOR_${f}_DISK"
  [[ -z "${!dv:-}" || "${!dv}" =~ ^[1-9][0-9]*[KMGTP]?$ ]] \
    || die "flavor '$f': ${dv} must be a positive size such as 80G (got '${!dv}')"
done
# amd64 container slots share the apple/container subsystem (kernel, image
# store, Rosetta), so they count toward the same total that gates it.
LINUX_TOTAL=$(( LINUX_TOTAL + LINUX_AMD64_RUNNERS ))

# Slot scheduling policies (kind resolution shared with run-slot.sh and
# dispatch.sh via slot-lib.sh). Validate everything here: a policy typo or a
# malformed warm schedule must fail the provision, not surface days later as
# a slot that never warms or a dispatcher that never boots it.
source "$PAYLOAD/remote/slot-lib.sh"
MANAGED_SLOTS=0
for kind in $(all_kinds); do
  policy="$(slot_policy "$kind")"
  case "$policy" in
    always) ;;
    scheduled|ondemand)
      if [[ "$policy" == "scheduled" ]]; then
        validate_schedule "$(slot_schedule "$kind")" \
          || die "invalid warm schedule for ${kind} slots: '$(slot_schedule "$kind")' (expected e.g. 'Mon-Fri 08:00-19:00')"
      fi
      MANAGED_SLOTS=$(( MANAGED_SLOTS + $(kind_count "$kind") ))
      ;;
    *) die "invalid policy '$policy' for ${kind} slots (always, scheduled, or ondemand)" ;;
  esac
done
[[ "${DISPATCH_INTERVAL:-60}" =~ ^[1-9][0-9]*$ ]] || die "DISPATCH_INTERVAL must be a positive integer (seconds)"
[[ "${DISPATCH_IDLE_TIMEOUT:-600}" =~ ^[1-9][0-9]*$ ]] || die "DISPATCH_IDLE_TIMEOUT must be a positive integer (seconds)"
[[ "${DISPATCH_MIN_QUEUE_AGE:-30}" =~ ^[0-9]+$ ]] || die "DISPATCH_MIN_QUEUE_AGE must be a non-negative integer (seconds)"
[[ "${DISPATCH_REPO_LIMIT:-15}" =~ ^[1-9][0-9]*$ ]] || die "DISPATCH_REPO_LIMIT must be a positive integer"

# An all-zero config is a valid state meaning "disable this host": the
# prune_slots calls below unload every slot daemon and tear down its backing
# container/VM, while leaving the installed tooling, service users, slot
# homes, and tart's image store alone. Unlike uninstall.sh this is
# reversible - restore non-zero counts and provision again.
SLOT_TOTAL=$(( MAC_RUNNERS + LINUX_TOTAL + MACVM_RUNNERS + LINUXVM_RUNNERS + LINUXVM_AMD64_RUNNERS ))
(( SLOT_TOTAL > 0 )) || echo "no runner slots configured: disabling all slots on this host"

# Apple's Virtualization framework (and the macOS EULA) allow at most two
# concurrent macOS VMs per host.
(( MACVM_RUNNERS <= 2 )) || die "MACVM_RUNNERS must be 0-2 (macOS VM limit)"
[[ "${MACVM_KEEP_CACHES:-false}" =~ ^(true|false)$ ]] || die "MACVM_KEEP_CACHES must be true or false"

# Tart gives every clone a new random MAC by default. That is undesirable for
# bridged, ephemeral slots: it churns LAN DHCP leases and prevents a stable
# reservation for Screen Sharing. Optional per-slot addresses must be
# locally-administered unicast MACs so they cannot collide with a vendor's
# globally assigned range or represent multicast traffic.
validate_macvm_mac() {
  local var="MACVM_MAC_$1" mac first
  mac="${!var:-}"
  [[ -z "$mac" ]] && return
  [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] \
    || die "$var must be a colon-separated MAC address (got '$mac')"
  first="${mac%%:*}"
  (( (16#$first & 3) == 2 )) \
    || die "$var must be a locally-administered unicast address (first octet 02, 06, 0a, ...; got '$mac')"
}
validate_macvm_mac 1
validate_macvm_mac 2
if [[ -n "${MACVM_MAC_1:-}" && -n "${MACVM_MAC_2:-}" ]]; then
  [[ "$(printf '%s' "$MACVM_MAC_1" | tr '[:upper:]' '[:lower:]')" != \
     "$(printf '%s' "$MACVM_MAC_2" | tr '[:upper:]' '[:lower:]')" ]] \
    || die "MACVM_MAC_1 and MACVM_MAC_2 must be different"
fi

# arm64 linuxvm slots run on apple/container machines, so they share the
# container subsystem (install, service user, apiserver, image store).
CONTAINER_NEEDED=$(( LINUX_TOTAL + LINUXVM_RUNNERS ))

OS_VERSION="$(sw_vers -productVersion)"
if (( CONTAINER_NEEDED > 0 )) && (( ${OS_VERSION%%.*} < 26 )); then
  die "apple/container requires macOS 26+; this host runs $OS_VERSION"
fi

BASE=/var/ghrunner
install -d -m 755 /opt/ghrunner /opt/ghrunner/bin /opt/ghrunner/cache "$BASE" "$BASE/slots" "$BASE/log"
install -d -m 700 /etc/ghrunner
install -m 600 "$PAYLOAD/runner.env" /etc/ghrunner/config.env
if [[ -s "$PAYLOAD/github.pat" ]]; then
  install -m 600 "$PAYLOAD/github.pat" /etc/ghrunner/github.pat
fi
# Cloudflare WARP service token for macvm slots and opted-in Linux flavors
# (optional). Kept on the host rather than baked into images so rotating it is
# a re-provision, not a re-bake; run-slot.sh reads it to enroll each guest.
if [[ -s "$PAYLOAD/warp.env" ]]; then
  install -m 600 "$PAYLOAD/warp.env" /etc/ghrunner/warp.env
fi
# Slots need the PAT to mint runner registration tokens; a zero-slot
# (disable) run only tears daemons down, so it does not.
if (( SLOT_TOTAL > 0 )); then
  [[ -s /etc/ghrunner/github.pat ]] || die "no PAT uploaded and none already installed at /etc/ghrunner/github.pat"
fi
install -m 755 "$PAYLOAD/remote/run-slot.sh" /opt/ghrunner/bin/run-slot.sh
install -m 755 "$PAYLOAD/remote/dispatch.sh" /opt/ghrunner/bin/dispatch.sh
install -m 644 "$PAYLOAD/remote/slot-lib.sh" /opt/ghrunner/bin/slot-lib.sh
install -m 755 "$PAYLOAD/remote/uninstall.sh" /opt/ghrunner/bin/uninstall.sh

# A CI host must not sleep, and should come back after power loss.
pmset -a sleep 0 disksleep 0 autorestart 1 2>/dev/null || true

# Rotate slot logs so they don't grow without bound.
cat > /etc/newsyslog.d/ghrunner.conf <<'EOF'
# logfilename              [owner:group] mode count size(KB) when flags
/var/ghrunner/log/*.log                  644  5     10240    *    GJ
EOF

next_free_uid() {
  local used uid
  used="$(dscl . -list /Users UniqueID | awk '{print $2}')"
  for ((uid = 601; uid < 700; uid++)); do
    grep -qx "$uid" <<<"$used" || { echo "$uid"; return 0; }
  done
  die "no free UID in 601-699"
}

# Hidden, unprivileged service account with a random throwaway password
# (no interactive login, no admin, hidden from the login window).
create_service_user() { # <name> <home>
  local name="$1" home="$2" uid
  if ! dscl . -read "/Users/$name" UniqueID >/dev/null 2>&1; then
    uid="$(next_free_uid)"
    echo "creating service user $name (uid $uid)"
    sysadminctl -addUser "$name" -UID "$uid" -fullName "GitHub Runner ($name)" \
      -home "$home" -shell /bin/zsh -password "$(openssl rand -base64 24)" 2>/dev/null
    dscl . -create "/Users/$name" IsHidden 1
  fi
  # 700: service users must not be able to read each other's homes.
  install -d -m 700 -o "$name" -g staff "$home"
}

# Replace a loaded daemon with the plist on disk. launchd can still be
# tearing the old instance down when the bootstrap lands and answers
# "Input/output error" (seen 2026-09-14: it left one macvm slot unloaded and
# the rest of the provision skipped), so the bootstrap is retried briefly.
reload_daemon() { # <label> <plist>
  local label="$1" plist="$2" try
  launchctl bootout "system/${label}" 2>/dev/null || true
  for try in 1 2 3 4 5; do
    launchctl bootstrap system "$plist" 2>/dev/null && return 0
    (( try < 5 )) || die "could not bootstrap ${label} after ${try} attempts"
    sleep 2
  done
}

deploy_daemon() { # <kind> <index>
  local kind="$1" idx="$2"
  local label="com.ghrunner.${kind}-${idx}"
  local plist="/Library/LaunchDaemons/${label}.plist"
  # Slots under a warm-schedule policy don't loop on KeepAlive: dispatch.sh
  # decides when a cycle starts (warm window, or a matching queued job) and
  # run-slot.sh retires the runner when its idle deadline passes.
  local autorun=true
  [[ "$(slot_policy "$kind")" == "always" ]] || autorun=false
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/ghrunner/bin/run-slot.sh</string>
        <string>${kind}</string>
        <string>${idx}</string>
    </array>
    <key>RunAtLoad</key><${autorun}/>
    <key>KeepAlive</key><${autorun}/>
    <key>ThrottleInterval</key><integer>15</integer>
    <key>StandardOutPath</key><string>/var/ghrunner/log/${kind}-${idx}.log</string>
    <key>StandardErrorPath</key><string>/var/ghrunner/log/${kind}-${idx}.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF
  chown root:wheel "$plist"
  chmod 644 "$plist"
  reload_daemon "$label" "$plist"
  if [[ "$autorun" == "true" ]]; then
    echo "slot ${kind}-${idx}: daemon ${label} running"
  else
    echo "slot ${kind}-${idx}: daemon ${label} loaded (dispatcher-managed, policy $(slot_policy "$kind"))"
  fi
}

# Removing a slot's daemon does not stop its VM/container - those belong to
# the service users' agents, not to the supervisor's process tree. Tear the
# backing resource down explicitly when a slot is decommissioned.
cleanup_slot_resources() { # <kind> <idx>
  local kind="$1" idx="$2" tag
  case "$kind" in
    linux|linux.*|linuxamd64)
      tag="ghrunner-$(printf '%s-%s' "$kind" "$idx" | tr '.' '-')"
      if [[ -x "$CONTAINER_BIN" ]] && id -u _ghcontainer >/dev/null 2>&1; then
        launchctl asuser "$(id -u _ghcontainer)" sudo -u _ghcontainer -H \
          "$CONTAINER_BIN" delete --force "$tag" >/dev/null 2>&1 || true
        launchctl asuser "$(id -u _ghcontainer)" sudo -u _ghcontainer -H \
          "$CONTAINER_BIN" volume delete "${tag}-scratch" >/dev/null 2>&1 || true
      fi
      ;;
    linuxvm)
      # Machines are ephemeral (created per job by run-slot.sh); remove
      # whatever this slot's cycle may have left running.
      if [[ -x "$CONTAINER_BIN" ]] && id -u _ghcontainer >/dev/null 2>&1; then
        launchctl asuser "$(id -u _ghcontainer)" sudo -u _ghcontainer -H \
          "$CONTAINER_BIN" machine stop "ghrunner-${kind}-${idx}" >/dev/null 2>&1 || true
        launchctl asuser "$(id -u _ghcontainer)" sudo -u _ghcontainer -H \
          "$CONTAINER_BIN" machine delete "ghrunner-${kind}-${idx}" >/dev/null 2>&1 || true
      fi
      # Legacy: this kind was Lima-backed before the machine backend.
      if [[ -x "$LIMACTL_BIN" ]] && id -u _ghlima >/dev/null 2>&1; then
        launchctl asuser "$(id -u _ghlima)" sudo -u _ghlima -H \
          "$LIMACTL_BIN" delete --force "ghrunner-${kind}-${idx}" >/dev/null 2>&1 || true
      fi
      rm -f "$BASE/lima/.ghrunner-${kind}-${idx}.tplhash"
      ;;
    linuxvmamd64)
      if [[ -x "$LIMACTL_BIN" ]] && id -u _ghlima >/dev/null 2>&1; then
        launchctl asuser "$(id -u _ghlima)" sudo -u _ghlima -H \
          "$LIMACTL_BIN" delete --force "ghrunner-${kind}-${idx}" >/dev/null 2>&1 || true
      fi
      rm -f "$BASE/lima/.ghrunner-${kind}-${idx}.tplhash"
      ;;
    macvm)
      if [[ -x "$TART_BIN" ]] && id -u _ghtart >/dev/null 2>&1; then
        launchctl asuser "$(id -u _ghtart)" sudo -u _ghtart -H \
          "$TART_BIN" delete "ghrunner-vm-${idx}" >/dev/null 2>&1 || true
      fi
      # The bootout above killed the cycle before it could promote or
      # discard, so its work/ clone would otherwise sit there for good; prev/
      # is a rollback point for a slot that no longer runs. canonical/ stays
      # (see the cache dir note below): warm is cheap to keep, slow to rebuild.
      rm -rf "$BASE/cache/macvm-${idx}/work" "$BASE/cache/macvm-${idx}/prev"
      ;;
    mac) : ;;  # daemon bootout kills the runner; the slot home stays for reuse
  esac
}

# Unload slots beyond the configured count and tear down their backing
# resources (users and homes are left in place; uninstall.sh removes
# everything).
prune_slots() { # <kind> <count>
  local kind="$1" count="$2" plist label idx
  for plist in /Library/LaunchDaemons/com.ghrunner.${kind}-*.plist; do
    [[ -e "$plist" ]] || continue
    label="$(basename "$plist" .plist)"
    idx="${label##*-}"
    if (( idx > count )); then
      launchctl bootout "system/${label}" 2>/dev/null || true
      rm -f "$plist"
      cleanup_slot_resources "$kind" "$idx"
      echo "slot ${kind}-${idx}: removed (count reduced)"
    fi
  done
}

# Rosetta 2 provides x86_64 translation. Needed by apple/container's builder
# VM and by amd64 container slots (userspace translation of the x64 runner).
ensure_rosetta() {
  /usr/bin/pgrep -q oahd && return 0
  echo "installing Rosetta 2 (required for x86_64 emulation)..."
  softwareupdate --install-rosetta --agree-to-license
}

ensure_xcode_clt() {
  xcode-select -p >/dev/null 2>&1 && return 0
  echo "installing Xcode Command Line Tools (this can take a while)..."
  local marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  touch "$marker"
  local label
  label="$(softwareupdate -l 2>/dev/null \
    | sed -n 's/^[* ]*Label: \(Command Line Tools for Xcode-.*\)$/\1/p' \
    | sort -V | tail -1)"
  [[ -n "$label" ]] || { rm -f "$marker"; die "Command Line Tools not found in softwareupdate catalog"; }
  softwareupdate -i "$label"
  rm -f "$marker"
  xcode-select -p >/dev/null 2>&1 || die "Command Line Tools install did not take effect"
}

# The macOS runner tarball is used by mac slots (installed on the host)
# and macvm slots (copied into each VM).
TARBALL="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
CACHE="/opt/ghrunner/cache/${TARBALL}"
if (( MAC_RUNNERS + MACVM_RUNNERS > 0 )) && [[ ! -f "$CACHE" ]]; then
  echo "downloading actions runner ${RUNNER_VERSION} (macOS arm64)..."
  curl -fL --retry 3 -o "${CACHE}.tmp" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
  mv "${CACHE}.tmp" "$CACHE"
fi

# ---- macOS runner slots ----------------------------------------------------

if (( MAC_RUNNERS > 0 )); then
  [[ "$INSTALL_XCODE_CLT" == "true" ]] && ensure_xcode_clt

  for ((i = 1; i <= MAC_RUNNERS; i++)); do
    name="_ghrunner${i}"
    home="$BASE/slots/mac-${i}"
    create_service_user "$name" "$home"
    rdir="$home/runner"
    if [[ ! -f "$rdir/.installed-version" || "$(cat "$rdir/.installed-version")" != "$RUNNER_VERSION" ]]; then
      echo "slot mac-${i}: installing runner ${RUNNER_VERSION}"
      rm -rf "$rdir"
      install -d -m 750 -o "$name" -g staff "$rdir"
      tar -xzf "$CACHE" -C "$rdir"
      echo "$RUNNER_VERSION" > "$rdir/.installed-version"
      chown -R "$name:staff" "$rdir"
    fi

    # Expose machine-wide tooling to jobs: the runner loads .path (PATH
    # override) and .env (extra env vars) from its root dir at startup.
    if [[ -n "${MAC_EXTRA_PATH:-}" ]]; then
      printf '%s\n' "${MAC_EXTRA_PATH}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" > "$rdir/.path"
      chown "$name:staff" "$rdir/.path"
    else
      rm -f "$rdir/.path"
    fi
    rm -f "$rdir/.env"
    for v in $(compgen -A variable MAC_ENV_ || true); do
      printf '%s=%s\n' "${v#MAC_ENV_}" "${!v}" >> "$rdir/.env"
    done
    if [[ -f "$rdir/.env" ]]; then chown "$name:staff" "$rdir/.env"; fi

    deploy_daemon mac "$i"
  done
fi
prune_slots mac "$MAC_RUNNERS"

# ---- Linux runner slots (apple/container) ----------------------------------

if (( CONTAINER_NEEDED > 0 )); then
  # container's BuildKit VM requires Rosetta 2 (x86 emulation support), as do
  # the amd64 container slots for translating the x64 runner and job.
  ensure_rosetta

  install_container() {
    local pkg="/opt/ghrunner/cache/container-${CONTAINER_VERSION}.pkg"
    echo "installing apple/container ${CONTAINER_VERSION}..."
    curl -fL --retry 3 -o "$pkg" \
      "https://github.com/apple/container/releases/download/${CONTAINER_VERSION}/container-${CONTAINER_VERSION}-installer-signed.pkg"
    installer -pkg "$pkg" -target /
  }
  container_version() { # <bin>: the CLI's x.y.z, empty if it cannot say
    "$1" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
  }
  # "<uid> <path>" for every running apiserver that the pkg did not install
  # (the pkg lives under /usr/local; Homebrew's formula under /opt/homebrew).
  foreign_apiservers() {
    ps -axo uid=,command= | awk '$2 ~ /\/container-apiserver$/ && $2 !~ /^\/usr\/local\// {print $1, $2}'
  }

  # The slots only ever run the pkg's /usr/local/bin/container, but a second
  # install (typically 'brew install container') has bitten this host: a
  # user upgrading one install ended up with a 1.4.1 client talking to a
  # 1.0.0 apiserver that the other install had registered, and every call
  # failed. Refuse an apiserver from another install in _ghcontainer's own
  # launchd domain (the slots would be talking to it); for other users it is
  # their own business, but say so - both installs share the host's vmnet
  # networking, so if Linux slots misbehave that is the first suspect.
  while read -r uid path; do
    [[ -n "$uid" ]] || continue
    owner="$(id -nu "$uid" 2>/dev/null || echo "uid $uid")"
    if [[ "$owner" == _ghcontainer ]]; then
      die "_ghcontainer is running a container-apiserver from another install ($path); stop it with 'sudo launchctl asuser $uid sudo -u _ghcontainer -H ${path%/libexec/*}/bin/container system stop' and re-provision"
    fi
    echo "warning: $owner runs a second apple/container install ($path); ghrunner slots use only $CONTAINER_BIN, so keep that install away from _ghcontainer" >&2
  done < <(foreign_apiservers)
  if [[ -x /opt/homebrew/bin/container ]]; then
    echo "warning: Homebrew's container $(container_version /opt/homebrew/bin/container) is installed alongside the pkg; the slots ignore it, but never run it as _ghcontainer" >&2
  fi

  # Pin the pkg to CONTAINER_VERSION in both directions. A mismatch is an
  # upgrade (or a rollback); stop the services with the old client first,
  # since a new client cannot reliably stop an old apiserver.
  INSTALLED_CONTAINER="$( [[ -x "$CONTAINER_BIN" ]] && container_version "$CONTAINER_BIN" || true)"
  if [[ ! -x "$CONTAINER_BIN" ]]; then
    install_container
  elif [[ "$INSTALLED_CONTAINER" != "$CONTAINER_VERSION" ]]; then
    echo "installed apple/container is ${INSTALLED_CONTAINER:-unknown}; switching to ${CONTAINER_VERSION} (restarts the container services)..."
    if id -u _ghcontainer >/dev/null 2>&1; then
      launchctl asuser "$(id -u _ghcontainer)" sudo -u _ghcontainer -H \
        "$CONTAINER_BIN" system stop 2>/dev/null || true
    fi
    install_container
  fi
  INSTALLED_CONTAINER="$(container_version "$CONTAINER_BIN")"
  [[ "$INSTALLED_CONTAINER" == "$CONTAINER_VERSION" ]] \
    || die "$CONTAINER_BIN reports version '${INSTALLED_CONTAINER}' after installing ${CONTAINER_VERSION}"
  if (( LINUXVM_RUNNERS > 0 )) && ! "$CONTAINER_BIN" machine --help >/dev/null 2>&1; then
    die "container ${CONTAINER_VERSION} lacks 'machine' (needed by linuxvm slots); set CONTAINER_VERSION to 1.1.0 or later in runner.env"
  fi

  create_service_user _ghcontainer "$BASE/container"
  CUID="$(id -u _ghcontainer)"
  # launchctl asuser gives the command the user's Mach bootstrap context,
  # which the container CLI needs to reach its XPC services headlessly.
  as_cuser() { launchctl asuser "$CUID" sudo -u _ghcontainer -H "$@"; }
  # Empty when the services are down or the apiserver predates the field.
  server_version() {
    as_cuser "$CONTAINER_BIN" system status 2>/dev/null | awk '$1 == "server.version" {print $2}' || true
  }

  if ! as_cuser "$CONTAINER_BIN" system status >/dev/null 2>&1; then
    # An apiserver that is running but will not answer is usually an older
    # one left behind by an out-of-band upgrade; 'system start' would find
    # its launchd job still loaded, so clear it first.
    if [[ -n "$(ps -U _ghcontainer -o command= | awk '$1 ~ /\/container-apiserver$/')" ]]; then
      echo "container apiserver is running but not answering (client/server version skew?); restarting it..."
      as_cuser "$CONTAINER_BIN" system stop 2>/dev/null || true
    fi
    echo "starting container system services..."
    as_cuser "$CONTAINER_BIN" system start --enable-kernel-install
  elif [[ -n "$(server_version)" && "$(server_version)" != "$CONTAINER_VERSION" ]]; then
    echo "container apiserver is $(server_version), client is ${CONTAINER_VERSION}; restarting the services..."
    as_cuser "$CONTAINER_BIN" system stop
    as_cuser "$CONTAINER_BIN" system start --enable-kernel-install
  fi
  SERVER_CONTAINER="$(server_version)"
  [[ -z "$SERVER_CONTAINER" || "$SERVER_CONTAINER" == "$CONTAINER_VERSION" ]] \
    || die "container apiserver still reports ${SERVER_CONTAINER} after a restart; expected ${CONTAINER_VERSION}"
  # A running apiserver does not imply a configured kernel: an uninstall
  # wipes the user data (kernel included) while launchd can keep the
  # service alive. 'kernel set' is not idempotent (fails on an existing
  # kernel file), so only run it when no kernel is installed yet.
  KERNEL_DIR="$BASE/container/Library/Application Support/com.apple.container/kernels"
  if [[ -z "$(find "$KERNEL_DIR" -type f 2>/dev/null | head -1)" ]]; then
    as_cuser "$CONTAINER_BIN" system kernel set --recommended
  fi

  # The 'container build' client can hang at "Unpacking built image" even
  # though the server-side import completes (apple/container #68 class
  # bug). Build against a fresh tag, poll the image store for the result,
  # and put the client out of its misery if it outlives the import.
  build_image() { # <tag> <context-dir> [arch] [pins-file]
    local tag="$1" dir="$2" arch="${3:-arm64}" pins="${4:-}" pid waited=0 line
    local extra=(--build-arg "RUNNER_ARCH=arm64" --build-arg "IMAGE_ARCH=arm64")
    # amd64 images are built (and later run) under Rosetta translation; the
    # runner tarball for amd64 is the linux-x64 build.
    if [[ "$arch" == "amd64" ]]; then
      extra=(--arch amd64 --build-arg "RUNNER_ARCH=x64" --build-arg "IMAGE_ARCH=amd64")
    fi
    # apple/container caps a Dockerfile at 16384 bytes (apple/container#735)
    # and from ~14KB up the client only says "Stream unexpectedly closed", so
    # name the real cause before the build client ever gets to see it.
    if [[ -f "$dir/Dockerfile" ]] && (( $(wc -c < "$dir/Dockerfile") > 14000 )); then
      die "$dir/Dockerfile is $(wc -c < "$dir/Dockerfile") bytes; container build breaks past ~14KB (16384 hard cap) - move prose to the README"
    fi
    # Toolchain pins (the repo's versions.env, shipped by provision.sh) become
    # one --build-arg each. android-image declares every pin as a default-less
    # ARG and refuses to build without them, so the Dockerfile cannot carry a
    # second copy of the versions the macOS bake installs.
    if [[ -n "$pins" && -f "$pins" ]]; then
      while IFS= read -r line; do
        [[ "$line" =~ ^[A-Z0-9_]+=.*$ ]] && extra+=(--build-arg "$line")
      done < "$pins"
    fi
    # ensure a fresh tag so 'image inspect' succeeding means THIS build
    as_cuser "$CONTAINER_BIN" image delete "$tag" >/dev/null 2>&1 \
      || as_cuser "$CONTAINER_BIN" image rm "$tag" >/dev/null 2>&1 || true
    echo "building Linux runner image ${tag} (${arch})..."
    as_cuser "$CONTAINER_BIN" build --tag "$tag" \
      --cpus "$LINUX_BUILD_CPUS" --memory "$LINUX_BUILD_MEMORY" \
      --build-arg "RUNNER_VERSION=${RUNNER_VERSION}" ${extra[@]+"${extra[@]}"} "$dir" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      if as_cuser "$CONTAINER_BIN" image inspect "$tag" >/dev/null 2>&1; then
        sleep 10   # grace period for the client to exit on its own
        if kill -0 "$pid" 2>/dev/null; then
          echo "note: build client hung after the image import completed; continuing"
          kill "$pid" 2>/dev/null || true
          sleep 2
          kill -9 "$pid" 2>/dev/null || true
        fi
        break
      fi
      sleep 10
      waited=$(( waited + 10 ))
      if (( waited >= LINUX_IMAGE_BUILD_TIMEOUT )); then
        kill "$pid" 2>/dev/null || true
        die "image build timed out after ${LINUX_IMAGE_BUILD_TIMEOUT}s: $tag"
      fi
    done
    wait "$pid" 2>/dev/null || true
    as_cuser "$CONTAINER_BIN" image inspect "$tag" >/dev/null 2>&1 \
      || die "image build failed: $tag"
  }

  # The bundled base image is built even when only flavors are configured:
  # flavor Dockerfiles may build FROM it. (Skipped when only linuxvm slots
  # need the container subsystem.)
  IMG_DIR=/opt/ghrunner/linux-image
  rm -rf "$IMG_DIR"
  cp -R "$PAYLOAD/remote/linux-image" "$IMG_DIR"
  chown -R _ghcontainer:staff "$IMG_DIR"
  IMAGE="ghrunner-linux:${RUNNER_VERSION}"
  if (( LINUX_TOTAL > 0 )) && ! as_cuser "$CONTAINER_BIN" image inspect "$IMAGE" >/dev/null 2>&1; then
    build_image "$IMAGE" "$IMG_DIR"
  fi

  for ((i = 1; i <= LINUX_RUNNERS; i++)); do
    deploy_daemon linux "$i"
  done

  # amd64 base: same context/Dockerfile, built for x86_64 and run under
  # Rosetta translation. Reports as an x64 runner; ~2-5x slower than native.
  # AMD64_BASE_NEEDED (computed with the flavor validation above) also
  # covers shipped-context amd64 flavors that may build FROM this image.
  if [[ "$AMD64_BASE_NEEDED" == "yes" ]]; then
    IMAGE_AMD64="ghrunner-linux-amd64:${RUNNER_VERSION}"
    if ! as_cuser "$CONTAINER_BIN" image inspect "$IMAGE_AMD64" >/dev/null 2>&1; then
      build_image "$IMAGE_AMD64" "$IMG_DIR" amd64
    fi
  fi
  for ((i = 1; i <= LINUX_AMD64_RUNNERS; i++)); do
    deploy_daemon linuxamd64 "$i"
  done

  # Flavors: build from a shipped context (rebuilt every provision; layer
  # caching keeps unchanged builds fast) or pull a registry image.
  for f in $LINUX_FLAVORS; do
    rv="LINUX_FLAVOR_${f}_RUNNERS"; fcount="${!rv:-0}"
    iv="LINUX_FLAVOR_${f}_IMAGE";   fimg="${!iv:-}"
    av="LINUX_FLAVOR_${f}_ARCH";    farch="${!av:-arm64}"
    if [[ -d "$PAYLOAD/images/$f" ]]; then
      fdest="/opt/ghrunner/linux-image-$f"
      rm -rf "$fdest"
      cp -R "$PAYLOAD/images/$f" "$fdest"
      chown -R _ghcontainer:staff "$fdest"
      fimg="ghrunner-linux-${f}:${RUNNER_VERSION}"
      build_image "$fimg" "$fdest" "$farch" "$PAYLOAD/versions.env"
    elif [[ -n "$fimg" ]]; then
      # Pin the platform so the pull fetches the variant the slot will run
      # (a bare pull may only fetch the host-default arch).
      echo "pulling ${fimg} (flavor ${f}, ${farch})..."
      as_cuser "$CONTAINER_BIN" image pull --platform "linux/${farch}" "$fimg"
    else
      die "flavor '$f': no build context shipped and no LINUX_FLAVOR_${f}_IMAGE set"
    fi
    for ((i = 1; i <= fcount; i++)); do
      deploy_daemon "linux.${f}" "$i"
    done
  done

  # ---- docker-capable arm64 slots: one ephemeral machine per job ------------
  # run-slot.sh creates a fresh `container machine` from this image for every
  # job and deletes it afterward; bootstrap only maintains the image (rebuilt
  # each provision - layer caching keeps unchanged builds fast) and daemons.
  if (( LINUXVM_RUNNERS > 0 )); then
    VMIMG_DIR=/opt/ghrunner/linuxvm-image
    rm -rf "$VMIMG_DIR"
    cp -R "$PAYLOAD/remote/linuxvm-image" "$VMIMG_DIR"
    chown -R _ghcontainer:staff "$VMIMG_DIR"
    build_image "ghrunner-linuxvm:${RUNNER_VERSION}" "$VMIMG_DIR"

    # One-time migration from the Lima backend: any ghrunner-linuxvm-* Lima
    # VMs are orphans of the old persistent-VM model.
    if [[ -x "$LIMACTL_BIN" ]] && id -u _ghlima >/dev/null 2>&1; then
      while IFS= read -r vm; do
        [[ "$vm" =~ ^ghrunner-linuxvm-[0-9]+$ ]] || continue
        echo "slot ${vm#ghrunner-}: deleting legacy Lima VM (backend is now apple/container machine)"
        launchctl asuser "$(id -u _ghlima)" sudo -u _ghlima -H \
          "$LIMACTL_BIN" delete --force "$vm" >/dev/null 2>&1 || true
        rm -f "$BASE/lima/.${vm}.tplhash"
      done < <(launchctl asuser "$(id -u _ghlima)" sudo -u _ghlima -H \
                 "$LIMACTL_BIN" list --format '{{.Name}}' 2>/dev/null || true)
    fi

    for ((i = 1; i <= LINUXVM_RUNNERS; i++)); do
      deploy_daemon linuxvm "$i"
    done
  fi
fi
prune_slots linux "$LINUX_RUNNERS"
prune_slots linuxamd64 "$LINUX_AMD64_RUNNERS"
for f in $LINUX_FLAVORS; do
  rv="LINUX_FLAVOR_${f}_RUNNERS"
  prune_slots "linux.${f}" "${!rv:-0}"
done
# Remove daemons for flavors dropped from LINUX_FLAVORS entirely.
for plist in /Library/LaunchDaemons/com.ghrunner.linux.*.plist; do
  [[ -e "$plist" ]] || continue
  label="$(basename "$plist" .plist)"
  flavor="${label#com.ghrunner.linux.}"
  flavor="${flavor%-*}"
  keep=no
  for f in $LINUX_FLAVORS; do [[ "$f" == "$flavor" ]] && keep=yes; done
  if [[ "$keep" == "no" ]]; then
    launchctl bootout "system/${label}" 2>/dev/null || true
    rm -f "$plist"
    cleanup_slot_resources "linux.${flavor}" "${label##*-}"
    echo "slot ${label#com.ghrunner.}: removed (flavor no longer configured)"
  fi
done

# Runner images are deliberately large (Android SDK/NDK images are several
# GiB), and image tags accumulate whenever a flavor is retired or
# RUNNER_VERSION changes. After all current slots have been deployed and old
# slots pruned, remove only retired images in our own namespace. Do not use
# `container image prune --all` here: this service account can also hold
# unrelated user images, which this supervisor must not manage.
gc_retired_linux_images() {
  local keep_images="" image f rv iv fcount fimage free_gb warn_gb
  [[ "${LINUX_IMAGE_GC:-true}" == "true" ]] || return 0

  keep_image() { keep_images+="$1"$'\n'; }
  # Flavor Dockerfiles can inherit from the bundled base even when there are
  # no plain linux slots, so retain it whenever any container runner exists.
  (( LINUX_TOTAL > 0 )) && keep_image "ghrunner-linux:${RUNNER_VERSION}"
  (( LINUX_AMD64_RUNNERS > 0 )) && keep_image "ghrunner-linux-amd64:${RUNNER_VERSION}"
  (( LINUXVM_RUNNERS > 0 )) && keep_image "ghrunner-linuxvm:${RUNNER_VERSION}"
  for f in $LINUX_FLAVORS; do
    rv="LINUX_FLAVOR_${f}_RUNNERS"; fcount="${!rv:-0}"
    (( fcount > 0 )) || continue
    iv="LINUX_FLAVOR_${f}_IMAGE"; fimage="${!iv:-ghrunner-linux-${f}:${RUNNER_VERSION}}"
    [[ "$fimage" == ghrunner-linux* ]] && keep_image "$fimage"
  done

  while IFS= read -r image; do
    [[ "$image" == ghrunner-linux* ]] || continue
    grep -Fqx "$image" <<<"$keep_images" && continue
    echo "image gc: deleting retired runner image $image"
    as_cuser "$CONTAINER_BIN" image delete "$image" \
      || echo "WARNING: could not delete retired runner image $image"
  done < <(as_cuser "$CONTAINER_BIN" image list --quiet 2>/dev/null || true)

  warn_gb="${LINUX_IMAGE_MIN_FREE_GB:-80}"
  [[ "$warn_gb" =~ ^[0-9]+$ ]] || die "LINUX_IMAGE_MIN_FREE_GB must be a non-negative integer"
  free_gb="$(df -g / | awk 'NR==2 {print $4}')"
  if (( free_gb < warn_gb )); then
    echo "WARNING: only ${free_gb}GiB free on / after runner image cleanup (threshold: ${warn_gb}GiB)"
  fi
}
if (( CONTAINER_NEEDED > 0 )); then
  gc_retired_linux_images
fi

# ---- amd64 Linux VM slots (Lima + QEMU, persistent, docker-capable) --------
# A full x86_64 guest under QEMU whole-system emulation: a true amd64 kernel,
# dockerd, and runner. apple/container has no equivalent (Virtualization
# framework guests are arm64-only), so these slots stay on Lima. The arm64
# docker-capable slots (linuxvm) run on apple/container machines above.

if (( LINUXVM_AMD64_RUNNERS > 0 )); then
  if [[ ! -x "$LIMACTL_BIN" ]]; then
    echo "installing lima ${LIMA_VERSION}..."
    LIMA_TGZ="/opt/ghrunner/cache/lima-${LIMA_VERSION}.tar.gz"
    curl -fL --retry 3 -o "$LIMA_TGZ" \
      "https://github.com/lima-vm/lima/releases/download/v${LIMA_VERSION}/lima-${LIMA_VERSION}-Darwin-arm64.tar.gz"
    rm -rf /usr/local/lima
    install -d -m 755 /usr/local/lima
    tar -xzf "$LIMA_TGZ" -C /usr/local/lima
  fi

  create_service_user _ghlima "$BASE/lima"
  LUID="$(id -u _ghlima)"
  # env PATH="$PATH" carries the daemon PATH (which includes Homebrew) past
  # sudo's secure_path so limactl can find qemu-system-x86_64.
  as_lima() { launchctl asuser "$LUID" sudo -u _ghlima -H env PATH="$PATH" "$LIMACTL_BIN" "$@"; }

  # One persistent VM per slot: dockerd + the runner install, no host
  # mounts, provisioned once (guarded by the marker file).
  write_linuxvmamd64_template() { # <file>
    local file="$1" runnerarch=x64
    local cpus="${LINUXVM_AMD64_CPUS:-${LINUXVM_CPUS:-4}}"
    local mem="${LINUXVM_AMD64_MEMORY:-${LINUXVM_MEMORY:-8}}"
    local disk="${LINUXVM_AMD64_DISK:-${LINUXVM_DISK:-60}}"
    cat > "$file" <<EOF
# reset-token: ${LINUXVM_RESET:-0}
vmType: qemu
os: Linux
arch: x86_64
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
cpus: ${cpus}
memory: "${mem}GiB"
disk: "${disk}GiB"
mounts: []
containerd:
  system: false
  user: false
provision:
  - mode: system
    script: |
      #!/bin/bash
      set -eu
      [ -f /etc/ghrunner-provisioned ] && exit 0
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends ca-certificates curl git jq docker.io
      systemctl enable --now docker
      useradd -m runner
      usermod -aG docker runner
      echo 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/runner
      chmod 440 /etc/sudoers.d/runner
      curl -fsSL -o /home/runner/runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runnerarch}-${RUNNER_VERSION}.tar.gz"
      mkdir -p /home/runner/runner
      tar -xzf /home/runner/runner.tar.gz -C /home/runner/runner
      rm /home/runner/runner.tar.gz
      /home/runner/runner/bin/installdependencies.sh
      chown -R runner:runner /home/runner
      touch /etc/ghrunner-provisioned
EOF
    chown _ghlima:staff "$file"
  }

  # Creates/recreates the persistent VMs for one slot kind and deploys their
  # daemons. VMs are recreated whenever the template hash changes.
  ensure_linuxvm_slots() { # <kind> <count> <template>
    local kind="$1" count="$2" tpl="$3" tpl_hash vm stamp vm_exists i
    tpl_hash="$(shasum -a 256 "$tpl" | awk '{print $1}')"
    for ((i = 1; i <= count; i++)); do
      vm="ghrunner-${kind}-${i}"
      stamp="$BASE/lima/.${vm}.tplhash"
      vm_exists=no
      as_lima list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm" && vm_exists=yes
      if [[ "$vm_exists" == "yes" && ( ! -f "$stamp" || "$(cat "$stamp")" != "$tpl_hash" ) ]]; then
        echo "slot ${kind}-${i}: template changed, recreating VM ${vm}"
        launchctl bootout "system/com.ghrunner.${kind}-${i}" 2>/dev/null || true
        as_lima delete --force "$vm"
        vm_exists=no
      fi
      if [[ "$vm_exists" == "no" ]]; then
        echo "slot ${kind}-${i}: creating VM ${vm} (first boot downloads Ubuntu + docker)..."
        # First boot runs apt + the runner install inside the guest; under
        # QEMU emulation (amd64) that can far exceed lima's default 10m
        # startup timeout, and a timed-out create dies here and recreates
        # from scratch on the next provision.
        as_lima start --name="$vm" --tty=false --timeout 40m "$tpl"
        echo "$tpl_hash" > "$stamp"
      fi
      deploy_daemon "$kind" "$i"
    done
  }

  # QEMU full-system emulation requires qemu-system-x86_64 on the host;
  # Lima does not bundle it. The daemon PATH includes Homebrew's bindir.
  command -v qemu-system-x86_64 >/dev/null 2>&1 \
    || die "linuxvmamd64 slots need QEMU: install it (e.g. 'brew install qemu') and re-provision"
  write_linuxvmamd64_template "$BASE/lima/ghrunner-linuxvmamd64.yaml"
  ensure_linuxvm_slots linuxvmamd64 "$LINUXVM_AMD64_RUNNERS" "$BASE/lima/ghrunner-linuxvmamd64.yaml"
fi
# prune_slots tears down the VMs of decommissioned slots via
# cleanup_slot_resources, including when a count drops to 0.
prune_slots linuxvm "$LINUXVM_RUNNERS"
prune_slots linuxvmamd64 "$LINUXVM_AMD64_RUNNERS"

# ---- macOS VM runner slots (Tart) -------------------------------------------

if (( MACVM_RUNNERS > 0 )); then
  tart_version() { "$1" --version 2>/dev/null | head -1 | tr -d '[:space:]'; }
  install_tart() {
    local tgz="/opt/ghrunner/cache/tart-${TART_VERSION}.tar.gz"
    echo "installing tart ${TART_VERSION}..."
    if [[ ! -s "$tgz" ]]; then
      curl -fL --retry 3 -o "${tgz}.part" \
        "https://github.com/openai/tart/releases/download/${TART_VERSION}/tart.tar.gz"
      mv "${tgz}.part" "$tgz"
    fi
    # The app bundle must stay intact (code signature + virtualization
    # entitlements); only the inner binary gets symlinked onto PATH.
    rm -rf /usr/local/tart
    install -d -m 755 /usr/local/tart
    tar -xzf "$tgz" -C /usr/local/tart
    ln -sf /usr/local/tart/tart.app/Contents/MacOS/tart /usr/local/bin/tart
  }

  # Pin tart to TART_VERSION in both directions, like the container pkg. A
  # mismatch is an upgrade (or a rollback) and replaces the app bundle, so
  # it is refused while any tart process is alive: a slot mid-job or a bake
  # would lose its VM. Re-run once the slots are idle (a scheduled slot is
  # torn down when its warm window closes), and the swap goes through.
  INSTALLED_TART="$( [[ -x "$TART_BIN" ]] && tart_version "$TART_BIN" || true)"
  if [[ ! -x "$TART_BIN" ]]; then
    install_tart
  elif [[ "$INSTALLED_TART" != "$TART_VERSION" ]]; then
    tart_pids="$(pgrep -x tart 2>/dev/null || true)"
    if [[ -n "$tart_pids" ]]; then
      echo "tart ${INSTALLED_TART:-unknown} is running (a job or bake in flight); not switching to ${TART_VERSION} under it:" >&2
      ps -o user=,pid=,lstart=,command= -p "$(printf '%s' "$tart_pids" | tr '\n' ',')" >&2 || true
      die "re-run the provision when the macOS VM slots are idle to install tart ${TART_VERSION}"
    fi
    echo "installed tart is ${INSTALLED_TART:-unknown}; switching to ${TART_VERSION}..."
    install_tart
  fi
  INSTALLED_TART="$(tart_version "$TART_BIN")"
  [[ "$INSTALLED_TART" == "$TART_VERSION" ]] \
    || die "$TART_BIN reports version '${INSTALLED_TART}' after installing ${TART_VERSION}"

  # SSH_ASKPASS helper for non-interactive password auth into guest VMs.
  cat > /opt/ghrunner/bin/vm-askpass.sh <<'EOF'
#!/bin/sh
printf '%s' "${MACVM_SSH_PASSWORD:-admin}"
EOF
  chmod 755 /opt/ghrunner/bin/vm-askpass.sh

  create_service_user _ghtart "$BASE/tart"
  TUID="$(id -u _ghtart)"
  as_tart() { launchctl asuser "$TUID" sudo -u _ghtart -H "$@"; }

  # macOS 15+ Virtualization framework requires an existing, UNLOCKED login
  # keychain in the session of the user running a macOS guest (undocumented;
  # without it VMs die instantly with VZErrorDomain -9 "security error" /
  # "Failed to get current host key"). _ghtart never logs in, so create its
  # keychain by hand. Tart documents an empty-password login keychain as the
  # fully automated workaround for headless hosts. This service account is
  # hidden and unprivileged, its home is mode 700, and this keychain is only
  # for Virtualization's host key; do not store registry credentials in it.
  # run-slot.sh re-unlocks it each cycle because reboots lock keychains.
  if ! as_tart security unlock-keychain -p '' login.keychain 2>/dev/null; then
    echo "creating login keychain for _ghtart (Virtualization host-key requirement)"
    as_tart security delete-keychain login.keychain 2>/dev/null || true
    rm -f "$BASE/tart/Library/Keychains/login.keychain-db"
    as_tart security create-keychain -p '' login.keychain
    as_tart security unlock-keychain -p '' login.keychain
  fi
  # Fresh headless users already get this file registered as their login
  # keychain. On macOS 26, `security login-keychain -s` can nevertheless
  # return 1 with no diagnostic, so verify the effective path rather than
  # failing on that misleading status.
  as_tart security login-keychain -s login.keychain 2>/dev/null || true
  LOGIN_KEYCHAIN="$(as_tart security login-keychain 2>/dev/null || true)"
  [[ "$LOGIN_KEYCHAIN" == *"$BASE/tart/Library/Keychains/login.keychain-db"* ]] \
    || die "_ghtart login keychain is not registered (got: ${LOGIN_KEYCHAIN:-none})"
  # Drop the default lock-on-timeout/sleep so it stays unlocked for jobs.
  as_tart security set-keychain-settings login.keychain
  # Migration cleanup from the older password-managed implementation.
  rm -f /etc/ghrunner/tart-keychain.pw

  free_gb="$(df -g / | awk 'NR==2 {print $4}')"
  if (( free_gb < 80 )); then
    echo "WARNING: only ${free_gb}GB free on /; macOS VM images typically need 40-100GB" >&2
  fi

  if [[ "$MACVM_IMAGE" == */* ]]; then
    echo "pulling ${MACVM_IMAGE} (tens of GB on first pull; may take a long time)..."
    as_tart "$TART_BIN" pull "$MACVM_IMAGE"
  elif ! as_tart "$TART_BIN" list 2>/dev/null | grep -q "$MACVM_IMAGE"; then
    die "local image '${MACVM_IMAGE}' not found on this host - bake it first: ./bake-image.sh"
  fi

  # Per-slot persistent cache dirs (MACVM_KEEP_CACHES); run-slot.sh shares a
  # per-cycle clone of macvm-<n>/canonical into guest n and promotes it back
  # once the job completes. Created here so a first cycle never races the
  # directory into place. canonical/ is left alone when the setting is off or
  # a slot is pruned (a warm cache is cheap to keep and slow to rebuild; the
  # prune drops only the slot's work/ and prev/). Undo the last
  # promotion with `mise run runner:caches rollback <n>`, or wipe a slot's
  # with `runner:caches clear <n>`.
  if [[ "${MACVM_KEEP_CACHES:-false}" == "true" ]]; then
    install -d -m 755 "$BASE/cache"
    for ((i = 1; i <= MACVM_RUNNERS; i++)); do
      install -d -m 700 -o _ghtart -g staff "$BASE/cache/macvm-${i}"
    done
  fi

  for ((i = 1; i <= MACVM_RUNNERS; i++)); do
    deploy_daemon macvm "$i"
  done
fi
prune_slots macvm "$MACVM_RUNNERS"

# ---- dispatcher (warm schedules / on-demand slots) ---------------------------
# One root daemon that starts dispatcher-managed slot cycles: keeps them
# looping inside their warm windows and boots them for queued jobs outside.
# Deployed only when some slot kind opts in via a POLICY; run-slot.sh
# provides the other half (retiring an idle runner at the window close or
# the idle timeout).

DISPATCHER_LABEL=com.ghrunner.dispatcher
DISPATCHER_PLIST="/Library/LaunchDaemons/${DISPATCHER_LABEL}.plist"
if (( MANAGED_SLOTS > 0 )); then
  # Demand dispatch reads queued workflow jobs, which needs repo
  # "Actions: read" on the watched repos - more than the org runners write
  # the slots themselves need. Probe one repo and warn (not die: warm
  # windows still work without it) so the gap shows up at provision time
  # rather than as a weekend job nobody picks up.
  if [[ -n "${DISPATCH_REPOS:-}" ]]; then
    probe_repo="${DISPATCH_REPOS%% *}"
    [[ "$probe_repo" == */* ]] || probe_repo="${GH_ORG}/${probe_repo}"
    if ! curl -sS --fail --max-time 30 \
        -H "Authorization: Bearer $(cat /etc/ghrunner/github.pat)" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -o /dev/null \
        "https://api.github.com/repos/${probe_repo}/actions/runs?per_page=1"; then
      echo "WARNING: the PAT cannot list workflow runs for ${probe_repo}; cold slots will"
      echo "         never see queued jobs (grant the PAT repo 'Actions: read' there)."
    fi
  fi
  cat > "$DISPATCHER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${DISPATCHER_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/ghrunner/bin/dispatch.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>15</integer>
    <key>StandardOutPath</key><string>/var/ghrunner/log/dispatcher.log</string>
    <key>StandardErrorPath</key><string>/var/ghrunner/log/dispatcher.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF
  chown root:wheel "$DISPATCHER_PLIST"
  chmod 644 "$DISPATCHER_PLIST"
  reload_daemon "$DISPATCHER_LABEL" "$DISPATCHER_PLIST"
  echo "dispatcher: managing ${MANAGED_SLOTS} scheduled/on-demand slot(s)"
else
  launchctl bootout "system/${DISPATCHER_LABEL}" 2>/dev/null || true
  rm -f "$DISPATCHER_PLIST"
fi

echo
if (( SLOT_TOTAL == 0 )); then
  echo "disabled: no runner slots remain on this host (org '$GH_ORG')"
  echo "tooling, service users, slot homes, and tart images were left in place;"
  echo "re-enable by restoring non-zero counts in runner.env and provisioning again."
  echo "to remove everything instead: sudo /opt/ghrunner/bin/uninstall.sh"
else
  echo "provisioned: $MAC_RUNNERS macOS slot(s), $LINUX_TOTAL Linux slot(s) ($LINUX_RUNNERS arm64 + $LINUX_AMD64_RUNNERS amd64${LINUX_FLAVORS:+ + flavors: $LINUX_FLAVORS}), $LINUXVM_RUNNERS Linux VM slot(s) + $LINUXVM_AMD64_RUNNERS amd64, $MACVM_RUNNERS macOS VM slot(s) for org '$GH_ORG'"
  echo "runners appear at https://github.com/organizations/${GH_ORG}/settings/actions/runners while idle-waiting or running a job"
  if (( MACVM_RUNNERS > 0 )) && [[ -n "${MACVM_BRIDGE_IFACE:-}" ]]; then
    echo "macOS VMs bridge onto ${MACVM_BRIDGE_IFACE} and name themselves, for screen sharing while a job runs:"
    for ((i = 1; i <= MACVM_RUNNERS; i++)); do
      echo "  ${RUNNER_NAME_PREFIX:-$(hostname -s | tr '[:upper:]' '[:lower:]')}-vm-${i}"
    done
  fi
  if (( MACVM_RUNNERS > 0 )) && [[ "${MACVM_KEEP_CACHES:-false}" == "true" ]]; then
    echo "macOS VM caches persist under $BASE/cache/macvm-<n> (MACVM_KEEP_CACHES=true)"
  fi
  echo "slot logs: /var/ghrunner/log/  |  uninstall: sudo /opt/ghrunner/bin/uninstall.sh"
fi
