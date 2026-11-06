#!/bin/bash
# Launches bake.sh detached from the invoking SSH session so a long bake
# (e.g. a first base-image pull plus a full toolchain install) survives
# disconnects and the operator's machine going to sleep. Runs as root;
# invoked by bake-image.sh -b with the uploaded payload directory.
#
# Progress goes to $LOG; the bake exit code lands in $STATUS (absent while
# still running). The payload dir is removed when the bake finishes.
set -euo pipefail

PAYLOAD="${1:?usage: bake-detach.sh <payload-dir>}"

LOG=/var/log/ghrunner-bake.log
STATUS=/var/log/ghrunner-bake.status
PIDFILE=/var/run/ghrunner-bake.pid

[[ $EUID -eq 0 ]] || { echo "bake-detach.sh: must run as root" >&2; exit 1; }

if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "bake-detach.sh: a bake is already running (pid $(cat "$PIDFILE"));" \
       "follow it with: tail -f $LOG" >&2
  exit 1
fi

rm -f "$STATUS"
: > "$LOG"
chmod 644 "$LOG"

nohup /bin/bash -c '
  payload="$1" status="$2" pidfile="$3"
  echo "=== bake started $(date) (pid $$) ==="
  rc=0
  /bin/bash "$payload/bake.sh" "$payload" || rc=$?
  echo "=== bake finished $(date) exit=$rc ==="
  echo "$rc" > "$status"
  chmod 644 "$status"
  rm -rf "$payload"
  rm -f "$pidfile"
' bake "$PAYLOAD" "$STATUS" "$PIDFILE" >> "$LOG" 2>&1 < /dev/null &

echo "$!" > "$PIDFILE"
echo "bake detached (pid $(cat "$PIDFILE")); it keeps running if this session drops"
