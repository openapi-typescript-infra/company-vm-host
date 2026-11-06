#!/bin/bash
# Launches bootstrap.sh detached from the invoking SSH session so a long
# provision (e.g. a first macvm image pull) survives disconnects and the
# operator's machine going to sleep. Runs as root; invoked by provision.sh -b
# with the uploaded payload directory.
#
# Progress goes to $LOG; the bootstrap exit code lands in $STATUS (absent
# while still running). The payload dir is removed when bootstrap finishes.
set -euo pipefail

PAYLOAD="${1:?usage: detach.sh <payload-dir>}"

LOG=/var/log/ghrunner-bootstrap.log
STATUS=/var/log/ghrunner-bootstrap.status
PIDFILE=/var/run/ghrunner-bootstrap.pid

[[ $EUID -eq 0 ]] || { echo "detach.sh: must run as root" >&2; exit 1; }

if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "detach.sh: a bootstrap is already running (pid $(cat "$PIDFILE"));" \
       "follow it with: tail -f $LOG" >&2
  exit 1
fi

rm -f "$STATUS"
: > "$LOG"
chmod 644 "$LOG"

nohup /bin/bash -c '
  payload="$1" status="$2" pidfile="$3"
  echo "=== bootstrap started $(date) (pid $$) ==="
  rc=0
  /bin/bash "$payload/remote/bootstrap.sh" "$payload" || rc=$?
  echo "=== bootstrap finished $(date) exit=$rc ==="
  echo "$rc" > "$status"
  chmod 644 "$status"
  rm -rf "$payload"
  rm -f "$pidfile"
' bootstrap "$PAYLOAD" "$STATUS" "$PIDFILE" >> "$LOG" 2>&1 < /dev/null &

echo "$!" > "$PIDFILE"
echo "bootstrap detached (pid $(cat "$PIDFILE")); it keeps running if this session drops"
