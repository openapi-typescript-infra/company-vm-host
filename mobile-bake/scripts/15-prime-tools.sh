#!/bin/bash
# No-auth cache warming: pre-fetch the Gradle wrapper distribution so a fresh
# VM's first Android build skips the ~150MB download. Needs no repo checkout
# and no secrets. If 20-prime-repo.sh runs, it will fetch the exact version
# the app pins anyway; this is the fallback for when that step is skipped.
#
# The version must match android/gradle/wrapper/gradle-wrapper.properties
# after `expo prebuild`, which is the wrapper inside Expo's prebuild template:
# versions.env GRADLE_VERSION / GRADLE_DIST_TYPE, derived from that template
# by `mise run runner:pins`. A wrong value wastes this download and ~700MB of
# image (v6 shipped a stale 8.14.3-all next to the 9.0.0-bin the app fetched
# itself), but never breaks a job.
#
# Skipped when 20-prime-repo.sh will run: that step fetches whatever version
# the app pins and prunes every other dist, so a guess here is at best
# redundant and at worst pruned again.
#
# Android-only, so the whole script self-skips under BAKE_WITH_ANDROID=0
# (ios-bake): with no SDK on the image nothing will ever run the wrapper, and
# the dist is ~150MB of image for nothing.
# xtrace goes on only AFTER the token test: bash traces the expanded operands
# of [[ ]], and bake.sh relays guest stderr into the world-readable
# /var/log/ghrunner-bake.log, so `set -x` here wrote the GitHub token into it.
set -euo pipefail

if [[ "${BAKE_WITH_ANDROID:-1}" != 1 ]]; then
  echo "15-prime-tools: BAKE_WITH_ANDROID=0; skipping the Gradle wrapper prefetch"
  exit 0
fi
if [[ -n "${BAKE_PRIME_TOKEN:-}" ]]; then
  echo "15-prime-tools: deep prime enabled; 20-prime-repo.sh fetches the app's exact Gradle, skipping the guess"
  exit 0
fi
set -x

# shellcheck source=../../versions.env
source "$(dirname "${BASH_SOURCE[0]}")/versions.env"
: "${GRADLE_VERSION:?versions.env}" "${GRADLE_DIST_TYPE:?versions.env}"
DIST_TYPE="$GRADLE_DIST_TYPE"

URL="https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-${DIST_TYPE}.zip"
ZIP="gradle-${GRADLE_VERSION}-${DIST_TYPE}.zip"

# Gradle stores each distribution under a dir named for the base36-encoded
# MD5 of the distribution URL (org.gradle.wrapper.PathAssembler). Reproduce
# that so the wrapper recognises the pre-placed dist instead of re-downloading.
HASH="$(python3 - "$URL" <<'PY'
import hashlib, sys
digest = hashlib.md5(sys.argv[1].encode()).digest()
n = int.from_bytes(digest, "big")
alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
out = ""
while n:
    n, r = divmod(n, 36)
    out = alphabet[r] + out
print(out or "0")
PY
)"

DEST="$HOME/.gradle/wrapper/dists/gradle-${GRADLE_VERSION}-${DIST_TYPE}/${HASH}"

if [[ -d "$DEST/gradle-${GRADLE_VERSION}" ]]; then
  echo "Gradle ${GRADLE_VERSION} already primed"
  exit 0
fi

mkdir -p "$DEST"
if ! curl -fL --retry 3 -o "$DEST/$ZIP" "$URL"; then
  echo "WARNING: could not pre-fetch Gradle ${GRADLE_VERSION}; jobs will download it on first build"
  rm -rf "$DEST"
  exit 0
fi

( cd "$DEST" && unzip -q -o "$ZIP" )
# The wrapper trusts a pre-extracted dist only when this marker file exists.
touch "$DEST/${ZIP}.ok"
echo "primed Gradle ${GRADLE_VERSION} at ${DEST}"
