#!/usr/bin/env bash
# Provision a Mac as a fleet of ephemeral GitHub Actions runners.
#
#   ./provision.sh [-c runner.env] [-b] user@host    # over SSH
#   ./provision.sh [-c runner.env] [-b] --local      # on this Mac
#
# Over SSH the password is only requested once (connection multiplexing);
# the sudo password is requested once by the bootstrap step.
#
# -b detaches the bootstrap on the target and returns immediately, so a slow
# provision (e.g. a first macvm image pull) survives SSH drops and this
# machine sleeping. Follow progress in /var/log/ghrunner-bootstrap.log on the
# target; the exit code lands in /var/log/ghrunner-bootstrap.status.
set -euo pipefail

usage() { echo "usage: $0 [-c config.env] [-b] user@host | --local" >&2; exit 2; }

CONFIG=runner.env
DETACH=no
while getopts bc: opt; do
  case "$opt" in
    b) DETACH=yes ;;
    c) CONFIG="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
TARGET="${1:-}"
[[ -n "$TARGET" ]] || usage
[[ -f "$CONFIG" ]] || { echo "config not found: $CONFIG (copy runner.env.example to runner.env and edit it)" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "$TARGET" == "--local" || "$TARGET" == "local" ]]; then
  echo "Provisioning this machine."
  run()    { /bin/bash -c "$1"; }
  runtty() { /bin/bash -c "$1"; }
else
  # Multiplex all SSH traffic over one authenticated connection so the
  # password is typed at most once.
  CM_PATH="${TMPDIR:-/tmp}/ghrunner-cm-$$"
  SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$CM_PATH" -o ControlPersist=2m)
  run()    { ssh "${SSH_OPTS[@]}" "$TARGET" "$1"; }
  runtty() { ssh "${SSH_OPTS[@]}" -t "$TARGET" "$1"; }
  cleanup() { ssh -o "ControlPath=$CM_PATH" -O exit "$TARGET" 2>/dev/null || true; }
  trap cleanup EXIT
  echo "Connecting to $TARGET (you may be prompted for the SSH password)..."
  run true
fi

# The PAT is piped straight into a root-readable-only file on the target;
# it is never written to disk here and never appears in a command line.
PAT="${GH_RUNNER_PAT:-}"
if [[ -z "$PAT" && -t 0 ]]; then
  read -r -s -p "GitHub PAT with org 'Self-hosted runners: write' (empty = keep token already on target): " PAT
  echo
elif [[ -z "$PAT" ]]; then
  # No tty to prompt on (CI, a pipeline, an agent): keep the token already
  # installed on the target rather than aborting. Prompting here would also
  # read the wrong thing - the SSH calls below drain stdin - and a junk value
  # overwrites /etc/ghrunner/github.pat, which 401s every slot on the host.
  echo "No tty for the PAT prompt; keeping the token already on the target."
fi

REMOTE_DIR="$(run 'mktemp -d /tmp/ghrunner-payload.XXXXXX')"
echo "Staging payload in $REMOTE_DIR ..."
tar -C "$HERE" -cz remote | run "tar -xz -C '$REMOTE_DIR'"
run "cat > '$REMOTE_DIR/runner.env'" < "$CONFIG"
# Toolchain pins for flavor image builds (bootstrap.sh passes each line as a
# --build-arg; android-image requires them).
run "cat > '$REMOTE_DIR/versions.env'" < "$HERE/versions.env"

# Ship the build context of any linux image flavor that defines one
# (paths are relative to the config file).
CONFIG_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"
flavor_dirs="$(
  set +u
  # shellcheck disable=SC1090
  source "$CONFIG"
  for f in ${LINUX_FLAVORS:-}; do
    v="LINUX_FLAVOR_${f}_BUILD_DIR"
    [[ -n "${!v:-}" ]] && printf '%s\t%s\n' "$f" "${!v}"
  done
  true
)"
if [[ -n "$flavor_dirs" ]]; then
  while IFS=$'\t' read -r f d; do
    [[ "$f" =~ ^[A-Za-z0-9]+$ ]] || { echo "invalid flavor name: $f" >&2; exit 1; }
    [[ "$d" = /* ]] || d="$CONFIG_DIR/$d"
    [[ -d "$d" ]] || { echo "flavor '$f': build dir not found: $d" >&2; exit 1; }
    echo "Shipping build context for flavor '$f' ($d)..."
    # `run` is ssh for a remote host; without this redirect its stdin would
    # consume the next line of this loop's here-string, silently skipping
    # every flavor after the first one.
    run "mkdir -p '$REMOTE_DIR/images/$f'" </dev/null
    tar -C "$d" -cz . | run "tar -xz -C '$REMOTE_DIR/images/$f'"
  done <<<"$flavor_dirs"
fi
if [[ -n "$PAT" ]]; then
  printf '%s' "$PAT" | run "umask 077; cat > '$REMOTE_DIR/github.pat'"
fi

# Cloudflare WARP service token for macvm slots and opted-in Linux flavors.
# Each VM/container enrolls itself at boot (see run-slot.sh) so its build can
# reach VPN-only hosts such as api.internal.example.com. Like the PAT, the token
# is piped into a root-only file and never appears in a command line; keep it
# out of the committed env config and export it instead:
#   WARP_AUTH_CLIENT_ID=... WARP_AUTH_CLIENT_SECRET=... ./provision.sh ...
# Leaving both empty keeps whatever is already installed on the target.
if [[ -n "${WARP_AUTH_CLIENT_ID:-}" && -n "${WARP_AUTH_CLIENT_SECRET:-}" ]]; then
  echo "Installing Cloudflare WARP service token for VM/container slots..."
  printf 'WARP_AUTH_CLIENT_ID=%s\nWARP_AUTH_CLIENT_SECRET=%s\n' \
    "$WARP_AUTH_CLIENT_ID" "$WARP_AUTH_CLIENT_SECRET" \
    | run "umask 077; cat > '$REMOTE_DIR/warp.env'"
elif [[ -n "${WARP_AUTH_CLIENT_ID:-}" || -n "${WARP_AUTH_CLIENT_SECRET:-}" ]]; then
  echo "WARP_AUTH_CLIENT_ID and WARP_AUTH_CLIENT_SECRET must be set together" >&2
  exit 1
fi

if [[ "$DETACH" == yes ]]; then
  echo "Launching bootstrap in the background (you may be prompted for the sudo password)..."
  # On refusal (a bootstrap is already running) nothing will consume the
  # payload, so remove it rather than leave a PAT sitting in /tmp.
  runtty "sudo /bin/bash '$REMOTE_DIR/remote/detach.sh' '$REMOTE_DIR' || { rc=\$?; rm -rf '$REMOTE_DIR'; exit \$rc; }"
  echo
  echo "Provisioning continues on the target; it is now safe to disconnect or sleep."
  if [[ "$TARGET" == "--local" || "$TARGET" == "local" ]]; then
    echo "  follow:  tail -f /var/log/ghrunner-bootstrap.log"
    echo "  result:  cat /var/log/ghrunner-bootstrap.status   (exit code; absent while running)"
  else
    echo "  follow:  ssh $TARGET tail -f /var/log/ghrunner-bootstrap.log"
    echo "  result:  ssh $TARGET cat /var/log/ghrunner-bootstrap.status   (exit code; absent while running)"
  fi
else
  echo "Running bootstrap (you may be prompted for the sudo password)..."
  runtty "sudo /bin/bash '$REMOTE_DIR/remote/bootstrap.sh' '$REMOTE_DIR'; rc=\$?; rm -rf '$REMOTE_DIR'; exit \$rc"
fi
