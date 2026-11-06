#!/usr/bin/env bash
# Bake a custom Tart macOS image on a runner host.
#
#   ./bake-image.sh [-d bake-dir] [-b] user@host    # over SSH
#   ./bake-image.sh [-d bake-dir] [-b] --local      # on this Mac
#
# The bake dir contains bake.env (base image, output name, resources) and
# scripts/*.sh, which run inside the guest in lexical order. See
# examples/macos-tooling. The result is a local tart image usable as
# MACVM_IMAGE. Note: pauses macvm slots for the duration of the bake.
#
# -b detaches the bake on the target and returns immediately, so a slow bake
# (e.g. a first base-image pull) survives SSH drops and this machine
# sleeping. Follow progress in /var/log/ghrunner-bake.log on the target; the
# exit code lands in /var/log/ghrunner-bake.status.
set -euo pipefail

usage() { echo "usage: $0 [-d bake-dir] [-b] user@host | --local" >&2; exit 2; }

BAKE_DIR=bake
DETACH=no
while getopts bd: opt; do
  case "$opt" in
    b) DETACH=yes ;;
    d) BAKE_DIR="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
TARGET="${1:-}"
[[ -n "$TARGET" ]] || usage
[[ -f "$BAKE_DIR/bake.env" ]] || { echo "no bake.env in '$BAKE_DIR' (see examples/macos-tooling)" >&2; exit 1; }
[[ -d "$BAKE_DIR/scripts" ]] || { echo "no scripts/ dir in '$BAKE_DIR'" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "$TARGET" == "--local" || "$TARGET" == "local" ]]; then
  echo "Baking on this machine."
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

REMOTE_DIR="$(run 'mktemp -d /tmp/ghrunner-bake.XXXXXX')"
echo "Staging bake payload in $REMOTE_DIR ..."
# -h dereferences symlinks so a bake dir can symlink a script from another one
# (e.g. a layer bake reusing scripts/ wholesale) instead of duplicating it.
tar -C "$BAKE_DIR" -czh . | run "tar -xz -C '$REMOTE_DIR'"
run "cat > '$REMOTE_DIR/bake.sh'" < "$HERE/remote/bake.sh"
run "cat > '$REMOTE_DIR/bake-detach.sh'" < "$HERE/remote/bake-detach.sh"
# The toolchain pins ride along with every bake; bake.sh puts them next to the
# scripts in the guest, and the mobile-bake scripts source them from there.
run "cat > '$REMOTE_DIR/versions.env'" < "$HERE/versions.env"

# Inject any BAKE_PRIME_* / BAKE_WITH_* var from this shell's environment into
# the shipped bake.env (it lives only in the target's temp payload, which is
# removed after the bake) so credentials need not be committed. bake.sh
# forwards both prefixes into the guest scripts.
#
# Not just the GitHub token: priming the iOS pod cache also needs GCP
# Artifact Registry auth for the private @your-company packages, since a failed
# `yarn install` leaves no node_modules for CocoaPods to autolink against and
# the whole prime stops there. Pass both, e.g.
#   BAKE_PRIME_TOKEN=$(gh auth token) \
#   BAKE_PRIME_GCP_TOKEN=$(gcloud auth print-access-token) \
#     ./bake-image.sh -d mobile-bake -b runner.example.com
#
# BAKE_WITH_* are feature toggles a bake dir normally sets in its own bake.env
# (ios-bake pins BAKE_WITH_ANDROID=0). Injecting them here too means a one-off
# variant needs no new dir - the appended line is sourced last, so the shell
# wins over the file:
#   BAKE_WITH_ANDROID=0 ./bake-image.sh -d mobile-bake -b runner.example.com
# Bake.env's BAKE_IMAGE_NAME does NOT change with it, so override that as well
# or you will overwrite the image the dir normally produces.
injected=()
for name in $(compgen -v | grep -E '^BAKE_(PRIME|WITH)_' || true); do
  [[ -n "${!name:-}" ]] || continue
  printf '\n%s=%q\n' "$name" "${!name}" \
    | run "umask 077; cat >> '$REMOTE_DIR/bake.env'"
  injected+=("$name")
done
if (( ${#injected[@]} )); then
  echo "Injecting ${injected[*]} into the bake..."
fi

if [[ "$DETACH" == yes ]]; then
  echo "Launching bake in the background (you may be prompted for the sudo password)..."
  # On refusal (a bake is already running) nothing will consume the payload,
  # so remove it rather than leave it sitting in /tmp.
  runtty "sudo /bin/bash '$REMOTE_DIR/bake-detach.sh' '$REMOTE_DIR' || { rc=\$?; rm -rf '$REMOTE_DIR'; exit \$rc; }"
  echo
  echo "The bake continues on the target; it is now safe to disconnect or sleep."
  if [[ "$TARGET" == "--local" || "$TARGET" == "local" ]]; then
    echo "  follow:  tail -f /var/log/ghrunner-bake.log"
    echo "  result:  cat /var/log/ghrunner-bake.status   (exit code; absent while running)"
  else
    echo "  follow:  ssh $TARGET tail -f /var/log/ghrunner-bake.log"
    echo "  result:  ssh $TARGET cat /var/log/ghrunner-bake.status   (exit code; absent while running)"
  fi
else
  echo "Running bake (you may be prompted for the sudo password; this can take a while)..."
  runtty "sudo /bin/bash '$REMOTE_DIR/bake.sh' '$REMOTE_DIR'; rc=\$?; rm -rf '$REMOTE_DIR'; exit \$rc"
fi
