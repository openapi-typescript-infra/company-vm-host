#!/usr/bin/env bash
# Smoke-test a baked macvm image on a runner host WITHOUT registering a
# runner: clone it to a throwaway VM, boot it, verify the tooling and env the
# way a job sees them (non-interactive ssh -> zsh -c -> /etc/zshenv), then
# tear it down.
#
#   ./verify-macvm.sh [-c runner.env] user@host [image]
#   ./verify-macvm.sh [-c runner.env] --local     [image]
#
# The image name defaults to MACVM_IMAGE from the config; pass one to override
# (handy to test a freshly baked image before editing runner.env). Pauses the
# macvm slot(s) for the ~2-3 min it runs (macOS 2-VM limit).
set -euo pipefail

usage() { echo "usage: $0 [-c config.env] user@host [image] | --local [image]" >&2; exit 2; }

CONFIG=runner.env
while getopts c: opt; do
  case "$opt" in
    c) CONFIG="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
TARGET="${1:-}"
IMAGE="${2:-}"
[[ -n "$TARGET" ]] || usage
[[ -f "$CONFIG" ]] || { echo "config not found: $CONFIG" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "$TARGET" == "--local" || "$TARGET" == "local" ]]; then
  echo "Verifying on this machine."
  run()    { /bin/bash -c "$1"; }
  runtty() { /bin/bash -c "$1"; }
else
  CM_PATH="${TMPDIR:-/tmp}/ghrunner-cm-$$"
  SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$CM_PATH" -o ControlPersist=2m)
  run()    { ssh "${SSH_OPTS[@]}" "$TARGET" "$1"; }
  runtty() { ssh "${SSH_OPTS[@]}" -t "$TARGET" "$1"; }
  cleanup() { ssh -o "ControlPath=$CM_PATH" -O exit "$TARGET" 2>/dev/null || true; }
  trap cleanup EXIT
  echo "Connecting to $TARGET ..."
  run true
fi

REMOTE_DIR="$(run 'mktemp -d /tmp/ghrunner-verify.XXXXXX')"
echo "Staging in $REMOTE_DIR ..."
run "cat > '$REMOTE_DIR/verify-macvm.sh'" < "$HERE/remote/verify-macvm.sh"
run "cat > '$REMOTE_DIR/config.env'"     < "$CONFIG"

echo "Running verification (you may be prompted for the sudo password)..."
runtty "sudo /bin/bash '$REMOTE_DIR/verify-macvm.sh' '$REMOTE_DIR/config.env' '$IMAGE'; rc=\$?; rm -rf '$REMOTE_DIR'; exit \$rc"
