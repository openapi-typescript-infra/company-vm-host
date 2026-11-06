# Shared helpers for the admin tasks in this directory.
#
# Deliberately NOT executable: mise treats every executable file under
# mise-tasks/ as a task, so a chmod +x here would create a broken "_lib.sh"
# task.
#
# Which host the tasks talk to comes from the environment, so a second
# runner host needs no new tasks:
#   GHRUNNER_ENV   name under envs/ (default example) - picks the config file
#   GHRUNNER_HOST  ssh hostname     (default runner.example.com)
#   GHRUNNER_USER  ssh user         (default example)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

GHRUNNER_ENV="${GHRUNNER_ENV:-example}"
CONFIG="envs/${GHRUNNER_ENV}.env"
if [[ ! -f "${REPO_ROOT}/${CONFIG}" ]]; then
  echo "no config at ${CONFIG}; GHRUNNER_ENV must be one of:" >&2
  ls "${REPO_ROOT}/envs" | sed 's/\.env$/  /' >&2
  exit 1
fi

GHRUNNER_HOST="${GHRUNNER_HOST:-runner.example.com}"
GHRUNNER_USER="${GHRUNNER_USER:-runner}"
TARGET="${GHRUNNER_USER}@${GHRUNNER_HOST}"

# Only ask for a remote tty when we have one, so piping a task into
# something else doesn't emit "Pseudo-terminal will not be allocated".
TTY_FLAG=()
[[ -t 1 ]] && TTY_FLAG=(-t)

# Wrap each argument in single quotes so it survives the remote login shell
# (zsh on the host) exactly as typed - flags, globs, spaces and all.
shq() {
  local a out=""
  for a in "$@"; do out+=" '${a//\'/\'\\\'\'}'"; done
  printf '%s' "$out"
}

# ${a[@]+"${a[@]}"} rather than "${a[@]}": macOS ships bash 3.2, where
# expanding an empty array under `set -u` is an unbound-variable error.
rsh() {
  ssh ${TTY_FLAG[@]+"${TTY_FLAG[@]}"} -o ConnectTimeout=10 "$TARGET" "$@"
}

# container/tart/limactl authorize clients by launchd session, so a plain
# `sudo -u` gets "unauthorized request" - going through `launchctl asuser`
# is what makes them work headlessly. This is the wrapper the README
# documents by hand.
as_service_user() { # <service-user> <binary> [args...]
  local svc="$1" bin="$2"
  shift 2
  rsh "sudo launchctl asuser \"\$(id -u ${svc})\" sudo -u ${svc} -H ${bin}$(shq "$@")"
}

# Read one value out of the selected env config.
cfg() { grep -E "^${1}=" "${REPO_ROOT}/${CONFIG}" | tail -1 | cut -d= -f2-; }
