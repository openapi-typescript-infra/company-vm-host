#!/usr/bin/env bash
# Print the "synced from your-org/your-app" block of versions.env as the
# app repo currently declares it, plus the minimums it states for tools this
# repo pins on its own cadence. `mise run runner:pins` diffs the output against
# versions.env; nothing here writes to that file.
#
#   ./derive-versions.sh [--offline] [path/to/mobile-apps]
#
# The checkout defaults to ../../mobile-apps next to this repo (or
# $MOBILE_APPS). Two values live inside npm packages rather than the repo:
# React Native's Android toolchain catalog and the Gradle wrapper in Expo's
# prebuild template. They are read from node_modules when the checkout has
# one, otherwise from the registry tarballs of the versions yarn.lock resolves
# (cached under ~/.cache/ghrunner-pins). --offline skips that fetch and
# reports those keys UNRESOLVED instead.
#
# Bash 3.2-compatible: this runs on the admin's Mac, not on a runner host.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OFFLINE=no
APP=""
for arg in "$@"; do
  case "$arg" in
    --offline) OFFLINE=yes ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) APP="$arg" ;;
  esac
done
APP="${APP:-${MOBILE_APPS:-$HERE/../../mobile-apps}}"
[[ -f "$APP/package.json" && -f "$APP/yarn.lock" ]] \
  || { echo "derive-versions: no mobile-apps checkout at $APP (pass the path or set MOBILE_APPS)" >&2; exit 1; }
APP="$(cd "$APP" && pwd)"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ghrunner-pins"
UNRESOLVED=()
note() { echo "derive-versions: $*" >&2; }

# Every reader returns "" when its anchor is missing; emit() turns that into
# UNRESOLVED so the diff shows the parser drifted rather than a wrong pin.
emit() { # <key> <value> <source-comment>
  local key="$1" val="$2" src="$3"
  if [[ -z "$val" ]]; then
    val=UNRESOLVED
    UNRESOLVED+=("$key")
  fi
  printf '# %s\n%s=%s\n' "$src" "$key" "$val"
}

# yarn.lock: the resolved version of a package, from its npm locator header
# (a "pkg@patch:..." header for the same package is skipped by anchoring on
# @npm:).
lock_version() { # <package>
  awk -v h="\"$1@npm:" 'index($0, h) == 1 { f = 1 } f && /^  version:/ { print $2; exit }' "$APP/yarn.lock"
}

# A registry tarball member, via node_modules when present. Prints nothing
# when offline and uncached.
package_file() { # <package> <version> <member-path-inside-package>
  local pkg="$1" ver="$2" member="$3" tgz
  if [[ -f "$APP/node_modules/$pkg/$member" ]]; then
    cat "$APP/node_modules/$pkg/$member"
    return
  fi
  tgz="$CACHE/${pkg//\//_}-$ver.tgz"
  if [[ ! -s "$tgz" ]]; then
    [[ "$OFFLINE" == no ]] || return 0
    mkdir -p "$CACHE"
    # Scoped packages publish under the bare name: @scope/name -> name-<ver>.tgz
    local url="https://registry.npmjs.org/$pkg/-/${pkg##*/}-$ver.tgz"
    note "fetching $pkg@$ver from the npm registry"
    curl -fsSL --retry 3 -o "$tgz.part" "$url" && mv "$tgz.part" "$tgz" || { rm -f "$tgz.part"; return 0; }
  fi
  tar -xzOf "$tgz" "package/$member" 2>/dev/null || true
}

toml_version() { # <toml-text> <key>
  printf '%s\n' "$1" | sed -n "s/^$2 *= *\"\([^\"]*\)\".*/\1/p" | head -1
}

# --- read everything -------------------------------------------------------
INSTALL_ACTION=.github/local-actions/install-build/action.yaml
EAS_ACTION=.github/local-actions/eas-build-ship/action.yaml

node_version="$(sed -n "s/.*node-version: *['\"]\{0,1\}\([0-9][0-9.]*\).*/\1/p" "$APP/$INSTALL_ACTION" 2>/dev/null | head -1)"
yarn_version="$(sed -n 's/.*"packageManager": *"yarn@\([^"+]*\).*/\1/p' "$APP/package.json" | head -1)"
java_version="$(sed -n 's/.*java-version: *"\{0,1\}\([0-9][0-9]*\).*/\1/p' "$APP/$EAS_ACTION" 2>/dev/null | head -1)"
expo_version="$(lock_version expo)"
rn_version="$(lock_version react-native)"
compile_sdk="$(awk '/compileSdkVersion:/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$APP/app.config.ts")"

toml=""
[[ -n "$rn_version" ]] && toml="$(package_file react-native "$rn_version" gradle/libs.versions.toml)"
toml_build_tools="$(toml_version "$toml" buildTools)"
toml_ndk="$(toml_version "$toml" ndkVersion)"
toml_compile_sdk="$(toml_version "$toml" compileSdk)"

wrapper=""
if [[ -n "$expo_version" ]]; then
  # template.tgz is a tarball inside the expo package; a second tar pass reads
  # the wrapper properties out of it.
  wrapper="$(package_file expo "$expo_version" template.tgz \
    | tar -xzOf - package/android/gradle/wrapper/gradle-wrapper.properties 2>/dev/null \
    | sed -n 's#.*distributions/gradle-\([0-9][0-9.]*\)-\([a-z]*\)\.zip.*#\1 \2#p' | head -1)"
fi
gradle_version="${wrapper%% *}"
gradle_dist="${wrapper#* }"
[[ "$wrapper" == *" "* ]] || gradle_dist=""

doctor_min() { sed -n "s/^REQUIRED_$1=\"\{0,1\}\([0-9][0-9.]*\).*/\1/p" "$APP/scripts/doctor.sh" 2>/dev/null | head -1; }
maestro_min="$(doctor_min MAESTRO)"
gcloud_min="$(doctor_min GCLOUD)"
eas_min="$(sed -n 's/.*"version": *">= *\([0-9][0-9.]*\)".*/\1/p' "$APP/patient-app/app/eas.json" 2>/dev/null | head -1)"

# --- report ----------------------------------------------------------------
echo "# derived from your-org/your-app @ $(git -C "$APP" rev-parse --short HEAD 2>/dev/null || echo '?') ($(git -C "$APP" log -1 --format=%cs 2>/dev/null || echo '?')), $(date +%Y-%m-%d)"
emit NODE_VERSION          "$node_version"    "$INSTALL_ACTION node-version"
emit YARN_VERSION          "$yarn_version"    "package.json packageManager"
emit JAVA_VERSION          "$java_version"    "$EAS_ACTION java-version"
emit EXPO_SDK              "${expo_version%%.*}" "yarn.lock expo ${expo_version:-?} (major)"
emit REACT_NATIVE_VERSION  "$rn_version"      "yarn.lock react-native"
emit ANDROID_COMPILE_SDK   "$compile_sdk"     "app.config.ts compileSdkVersion (react-native catalog says ${toml_compile_sdk:-?})"
emit ANDROID_BUILD_TOOLS   "$toml_build_tools" "react-native@${rn_version:-?} gradle/libs.versions.toml buildTools"
emit ANDROID_NDK           "$toml_ndk"        "react-native@${rn_version:-?} gradle/libs.versions.toml ndkVersion"
emit GRADLE_VERSION        "$gradle_version"  "expo@${expo_version:-?} template.tgz android/gradle/wrapper/gradle-wrapper.properties"
emit GRADLE_DIST_TYPE      "$gradle_dist"     "same file, dist type"
echo "# minimums mobile-apps states for tools this repo pins itself (checked as pin >= minimum)"
emit MAESTRO_MIN_VERSION   "$maestro_min"     "scripts/doctor.sh REQUIRED_MAESTRO"
emit GCLOUD_MIN_VERSION    "$gcloud_min"      "scripts/doctor.sh REQUIRED_GCLOUD"
emit EAS_CLI_MIN_VERSION   "$eas_min"         "patient-app/app/eas.json cli.version"

if [[ -n "$toml_compile_sdk" && -n "$compile_sdk" && "$toml_compile_sdk" != "$compile_sdk" ]]; then
  note "WARNING: app.config.ts compileSdkVersion $compile_sdk differs from react-native's catalog ($toml_compile_sdk); the app's value wins"
fi
if (( ${#UNRESOLVED[@]} )); then
  note "UNRESOLVED: ${UNRESOLVED[*]}"
  [[ "$OFFLINE" == no ]] || note "(--offline: package-sourced keys need node_modules or a registry fetch)"
fi
