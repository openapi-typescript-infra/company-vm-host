#!/bin/bash
# Removes everything bootstrap.sh installed: slot daemons, service users,
# runner installs, config, the PAT, and the bootstrap/bake logs (a bake log
# can contain secrets forwarded as BAKE_PRIME_*). apple/container itself and
# Xcode Command Line Tools are left in place.
#
# WARNING: deleting _ghtart takes its home (/var/ghrunner/tart) with it, and
# that is where tart's image store lives - every pulled AND locally baked
# macOS image goes with it. After an uninstall you must re-provision against
# a registry image before you can re-bake (bake.sh needs _ghtart to exist).
# The persistent macvm caches (/var/ghrunner/cache, MACVM_KEEP_CACHES) go too.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "uninstall: must run as root" >&2; exit 1; }

for plist in /Library/LaunchDaemons/com.ghrunner.*.plist; do
  [[ -e "$plist" ]] || continue
  label="$(basename "$plist" .plist)"
  launchctl bootout "system/${label}" 2>/dev/null || true
  rm -f "$plist"
  echo "removed daemon ${label}"
done

# Stop the container services properly first - this removes their launchd
# registration, so nothing respawns after the user's processes are killed.
if [[ -x /usr/local/bin/container ]] && id -u _ghcontainer >/dev/null 2>&1; then
  launchctl asuser "$(id -u _ghcontainer)" sudo -u _ghcontainer -H \
    /usr/local/bin/container system stop 2>/dev/null || true
fi

for user in $(dscl . -list /Users | grep -E '^_gh(runner[0-9]+|container|tart|lima)$' || true); do
  pkill -9 -u "$user" 2>/dev/null || true
  sysadminctl -deleteUser "$user" 2>/dev/null || dscl . -delete "/Users/${user}"
  echo "removed user ${user}"
done

rm -rf /var/ghrunner /opt/ghrunner /etc/ghrunner /etc/newsyslog.d/ghrunner.conf \
  /var/log/ghrunner-bootstrap.log /var/log/ghrunner-bootstrap.status \
  /var/run/ghrunner-bootstrap.pid \
  /var/log/ghrunner-bake.log /var/log/ghrunner-bake.status \
  /var/run/ghrunner-bake.pid

echo "done. apple/container, tart, and lima were left installed; remove with"
echo "  /usr/local/bin/uninstall-container.sh   (apple/container)"
echo "  rm -rf /usr/local/tart /usr/local/bin/tart   (tart)"
echo "  rm -rf /usr/local/lima   (lima)"
