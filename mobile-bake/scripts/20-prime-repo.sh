#!/bin/bash
# Optional deep cache warming: clone the app, install deps, prebuild, run a
# real Android build and `pod install`, so a fresh VM inherits warm *global*
# caches (~/.gradle for Android, ~/.cocoapods + ~/Library/Caches/CocoaPods for
# iOS).
# The checkout itself - and the token - are deleted before the image is
# snapshotted; only the home-dir caches persist.
#
# Enabled only when BAKE_PRIME_TOKEN is forwarded from bake.env. Every step
# is best-effort: a failure (optional VPN codegen, no GCP auth for the private
# npm registry, a version skew) logs a warning and leaves whatever was already
# warmed, rather than failing the bake.
#
# NOTE: this repo uses Yarn's default per-project cache, so the JS package
# cache cannot be warmed into the image (it lives in the deleted checkout).
# Enabling Yarn's global cache in the app repo (enableGlobalCache, or
# YARN_ENABLE_GLOBAL_CACHE=true in the workflow) would let us warm that too,
# and would let MACVM_KEEP_CACHES persist it across jobs (~/.yarn/berry/cache
# is one of the redirected paths).
# NOTE: with MACVM_KEEP_CACHES the pod caches and Gradle's content-addressed
# stores (dependency cache, build cache, wrapper) are copied onto the host's
# persistent share by the first job on a fresh host and grow from there; this
# prime is the floor, not the ceiling. Gradle's per-version state - the
# artifact transforms above all - is NOT mirrored (run-slot.sh explains why),
# so for that part the image is the ceiling: what the build below warms is
# exactly what every job starts with.
# NOTE: xtrace is deliberately OFF for the token handling below and switched
# on only afterwards. bake.sh relays guest stderr into
# /var/log/ghrunner-bake.log on the host (mode 644), so tracing the
# assignments would write the token - and the reversible base64 of it - to a
# world-readable file that outlives the runner install.
set -uo pipefail   # deliberately NOT -e: keep going past best-effort failures

# Pins to confirm against the real build below (see the pin check at the end).
# shellcheck source=../../versions.env
source "$(dirname "${BASH_SOURCE[0]}")/versions.env" || exit 1

REPO="${BAKE_PRIME_REPO:-}"
REF="${BAKE_PRIME_REF:-main}"
TOKEN="${BAKE_PRIME_TOKEN:-}"
unset BAKE_PRIME_TOKEN

# Under BAKE_WITH_ANDROID=0 (ios-bake) the image has no Android SDK, so the
# Gradle warm below is skipped and only the pod caches are reported.
WITH_ANDROID="${BAKE_WITH_ANDROID:-1}"
# A bake guest is deliberately not enrolled in WARP, so private GraphQL
# codegen is skipped unless the operator explicitly knows the guest has a
# private route. Native prebuild and dependency/cache warming do not need it.
WITH_CODEGEN="${BAKE_PRIME_WITH_CODEGEN:-0}"
unset BAKE_PRIME_WITH_CODEGEN

if [[ -z "$TOKEN" ]]; then
  echo "20-prime-repo: BAKE_PRIME_TOKEN not set; skipping deep prime"
  echo "  (set BAKE_PRIME_TOKEN and BAKE_PRIME_REPO; optionally BAKE_PRIME_REF in bake.env to enable)"
  exit 0
fi

: "${REPO:?Set BAKE_PRIME_REPO to the repository to prime}"

warn() { echo "20-prime-repo: WARNING: $*"; }

WORK="$(mktemp -d /tmp/prime.XXXXXX)"
WATCHDOG_PID=""

# The Gradle wrapper starts a single-use daemon, and the pipeline below adds a
# shell plus tee between the PID Bash gives us and those Java processes. A
# deadlocked daemon can ignore TERM and outlive that pipeline while retaining
# its SSH stdout pipe. Discover the actual Java processes, give them a short
# grace period, then force survivors down. This VM is dedicated to the bake,
# so no unrelated Gradle job can exist here.
gradle_pids() {
  {
    pgrep -f "${WORK}/.*/gradle-wrapper[.]jar" 2>/dev/null || true
    pgrep -f 'org[.]gradle[.]launcher[.]daemon[.]bootstrap[.]GradleDaemon' 2>/dev/null || true
  } | sort -u
}

stop_gradle() {
  local pids remaining pid
  pids="$(gradle_pids)"
  [[ -n "$pids" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done <<< "$pids"
  for _ in $(seq 1 10); do
    remaining="$(gradle_pids)"
    [[ -z "$remaining" ]] && return 0
    sleep 1
  done
  remaining="$(gradle_pids)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
  done <<< "$remaining"
}

cleanup() {
  set +e
  if [[ -n "$WATCHDOG_PID" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null
    pkill -P "$WATCHDOG_PID" 2>/dev/null
  fi
  stop_gradle
  cd /
  rm -rf "$WORK"   # drop checkout + token, keep home caches
}
trap cleanup EXIT

# Clone via an inline auth header so the token is never written to .git/config.
# Still untraced: the header carries the token base64-encoded.
echo "20-prime-repo: cloning ${REPO}@${REF} (depth 1)"
AUTH="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
if ! git -c "http.extraheader=Authorization: Basic ${AUTH}" \
        clone --depth=1 --branch "$REF" "https://github.com/${REPO}.git" "$WORK"; then
  warn "clone failed; skipping deep prime"; exit 0
fi
unset AUTH
cd "$WORK" || exit 1

# Deps. The ~150 private @your-company packages come from GCP Artifact Registry
# via yarn-plugin-gcp-auth, which authenticates by *spawning the gcloud
# binary*. There is no ADC in a bake guest, but `gcloud auth
# print-access-token` simply echoes CLOUDSDK_AUTH_ACCESS_TOKEN back when it is
# set, so forwarding a short-lived token from the host satisfies the plugin.
# Without it `yarn install` dies with "Process gcloud failed to spawn" or a
# 401, no node_modules exist for CocoaPods to autolink against, and the whole
# prime stops here. This was one of TWO independent faults that left
# ghrunner-mobile-v2 with a cold pod cache; the other was the relative $YARN
# path below. Fixing either alone would still have produced no pods.
#
# Still untraced: this export used to sit below `set -x`, which wrote the
# ya29 token into the bake log.
if [[ -n "${BAKE_PRIME_GCP_TOKEN:-}" ]]; then
  export CLOUDSDK_AUTH_ACCESS_TOKEN="$BAKE_PRIME_GCP_TOKEN"
  unset BAKE_PRIME_GCP_TOKEN
  echo "20-prime-repo: using forwarded GCP access token for Artifact Registry"
else
  warn "BAKE_PRIME_GCP_TOKEN not set; private npm will fail and the pod cache will NOT be warmed"
fi

# Past the secret handling: trace the rest, which is what you actually want to
# read in the bake log when a warm step fails.
set -x

# Absolute: the per-app loop below cds into <app>/app, where a path relative
# to the repo root no longer resolves. Getting this wrong fails prebuild with
# a bare MODULE_NOT_FOUND, so no ios/ is generated and `pod install` never
# runs - the pod cache then silently stays cold while the bake reports success.
# The release file is whatever .yarnrc.yml names (the checkout's own truth),
# falling back to the version versions.env expects.
YARN_PATH="$(sed -n 's/^yarnPath: *//p' .yarnrc.yml 2>/dev/null | head -1)"
YARN="node ${WORK}/${YARN_PATH:-.yarn/releases/yarn-${YARN_VERSION}.cjs}"

# Pin check, filled in as the build reveals each value and printed with the
# cache summary. "Not independently confirmed" is what this replaces: the
# values versions.env carries are compared with what this checkout and this
# build actually used. Drift warns loudly rather than failing - the image is
# still usable, just carrying a stale pin - and the fix is versions.env.
PIN_REPORT=()
PIN_DRIFT=0
pin_check() { # <key> <expected> <actual> <where actual came from>
  local key="$1" want="$2" got="$3" src="$4" status
  if [[ -z "$got" ]]; then status="UNKNOWN (not observed)"
  elif [[ "$got" == "$want" ]]; then status="ok"
  else status="DRIFT"; PIN_DRIFT=1; fi
  PIN_REPORT+=("$(printf '  %-22s %-16s %-16s %-6s %s' "$key" "$want" "${got:--}" "$status" "$src")")
}

# What the installed react-native declares, i.e. what derive-versions.sh reads
# on the admin's machine - here confirmed against the checkout the bake used.
RN_TOML="$WORK/node_modules/react-native/gradle/libs.versions.toml"
toml_version() { sed -n "s/^$1 *= *\"\([^\"]*\)\".*/\1/p" "$RN_TOML" 2>/dev/null | head -1; }

# Deps (GCP auth for the private registry was exported above, before xtrace).
if ! $YARN install --immutable; then
  unset CLOUDSDK_AUTH_ACCESS_TOKEN
  warn "yarn install failed (GCP auth / registry?); stopping prime"
  exit 0
fi
# Nothing after dependency installation needs the short-lived registry token;
# in particular, do not let a later orphaned Gradle process retain it.
unset CLOUDSDK_AUTH_ACCESS_TOKEN

pin_check REACT_NATIVE_VERSION "$REACT_NATIVE_VERSION" \
  "$(node -p "require('$WORK/node_modules/react-native/package.json').version" 2>/dev/null)" "node_modules/react-native"
pin_check EXPO_SDK "$EXPO_SDK" \
  "$(node -p "require('$WORK/node_modules/expo/package.json').version.split('.')[0]" 2>/dev/null)" "node_modules/expo (major)"
pin_check YARN_VERSION "$YARN_VERSION" "$($YARN --version 2>/dev/null)" "yarnPath release"
if [[ "$WITH_ANDROID" == 1 ]]; then
  pin_check ANDROID_COMPILE_SDK "$ANDROID_COMPILE_SDK" "$(toml_version compileSdk)" "react-native libs.versions.toml"
  pin_check ANDROID_BUILD_TOOLS "$ANDROID_BUILD_TOOLS" "$(toml_version buildTools)" "react-native libs.versions.toml"
  pin_check ANDROID_NDK "$ANDROID_NDK" "$(toml_version ndkVersion)" "react-native libs.versions.toml"
fi

# Codegen reaches VPN-only api.internal.example.com. Normal runner VMs enroll in
# WARP at boot, but bake VMs intentionally do not share a registration. Avoid
# a noisy known failure by default; an operator with a private route can opt in.
if [[ "$WITH_CODEGEN" == 1 ]]; then
  $YARN build || warn "yarn build (codegen) failed; native prebuild may be incomplete"
else
  echo "20-prime-repo: skipping VPN-only GraphQL codegen (set BAKE_PRIME_WITH_CODEGEN=1 to enable)"
fi

# Gradle's local build cache: on for the warm build below so its outputs seed
# the persistent share's build cache on a fresh host. run-slot.sh writes the
# same line at boot, so jobs do not depend on this.
if [[ "$WITH_ANDROID" == 1 ]]; then
  mkdir -p ~/.gradle
  grep -qs '^org\.gradle\.caching=' ~/.gradle/gradle.properties \
    || echo 'org.gradle.caching=true' >> ~/.gradle/gradle.properties
fi

# Which apps to warm. Default: the patient app only - provider-app is not built
# on these runners today, and the Android warm is a full build per app.
for app in ${BAKE_PRIME_APPS:-patient-app}; do
  APPDIR="$WORK/$app/app"
  [[ -d "$APPDIR" ]] || { warn "no $APPDIR; skipping"; continue; }
  ( cd "$APPDIR" && $YARN expo prebuild --no-install ) || { warn "$app prebuild failed"; continue; }

  # Android: a real release build, the same Gradle task `eas build --local`
  # runs. `:app:dependencies` (what earlier bakes ran) only resolves the
  # libraries the app declares: the first job on ghrunner-mobile-v6 still
  # fetched ~700MB of compile toolchain (Android Gradle Plugin, Kotlin
  # compiler, KSP, lint) and re-ran every artifact transform (AAR extraction,
  # library dexing), and only a build populates those. Two tasks are excluded
  # because they need the codegen output `yarn build` cannot produce here
  # (VPN-only API): the JS bundle, and expo-updates' createReleaseUpdatesResources,
  # which runs Metro to resolve the app's assets and dies on the missing
  # generated/ modules the same way. --continue keeps compiling everything that
  # does not depend on them. Expect the invocation to end in a failure and a
  # warning - the caches it leaves behind are the point.
  # `expo prebuild` generates android/ on any platform, so the WITH_ANDROID
  # test is what actually skips this on an iOS-only bake - without it the warm
  # would run with no SDK, spend minutes failing, and warn on every app.
  if [[ "$WITH_ANDROID" == 1 && -d "$APPDIR/android" ]]; then
    # The log is kept for the pin check: Expo's root Gradle plugin prints the
    # NDK it configured ("- ndk: <version>") while configuring.
    GRADLE_LOG="$WORK/gradle-warm-$app.log"
    # Bounded by a watchdog. The v7 bake hung for ten hours in this command
    # with the macvm slot paused: after FAILED CMake tasks under --continue,
    # Gradle's scheduler deadlocked - every execution worker idle in
    # getNextItem, no compiler children, log frozen - and nothing here would
    # ever have given up. macOS ships no `timeout`, hence the sleeper. It is
    # detached from stdio so it cannot hold the bake's SSH channel open, and
    # reports through a marker file instead. The cold warm build took ~11 min
    # at BAKE_CPUS=4 in v7; v9's was still compiling when it hung ~13 min in.
    # 25 min covers a healthy build with room to spare without paying 45 for
    # every hang; BAKE_PRIME_GRADLE_TIMEOUT_MIN (bake.env) overrides.
    GRADLE_TIMEOUT_MIN="${BAKE_PRIME_GRADLE_TIMEOUT_MIN:-25}"
    GRADLE_TIMED_OUT="$WORK/gradle-warm-$app.timed-out"
    ( cd "$APPDIR/android" \
      && ./gradlew --no-daemon --continue :app:bundleRelease \
           -x createBundleReleaseJsAndAssets -x createReleaseUpdatesResources 2>&1 \
         | tee "$GRADLE_LOG"; exit "${PIPESTATUS[0]}" ) &
    GRADLE_PID=$!
    # `&&` matters: when the build finishes first the sleep is killed, and a
    # killed sleep must not fall through to the marker and the cleanup.
    ( sleep "$(( GRADLE_TIMEOUT_MIN * 60 ))" && {
        touch "$GRADLE_TIMED_OUT"
        stop_gradle
      }
    ) </dev/null >/dev/null 2>&1 &
    WATCHDOG_PID=$!
    wait "$GRADLE_PID"; GRADLE_RC=$?
    kill "$WATCHDOG_PID" 2>/dev/null; pkill -P "$WATCHDOG_PID" 2>/dev/null
    WATCHDOG_PID=""
    # The pipeline may return while its Java descendants survive (the v8 bake
    # did exactly this). Always close out any wrapper/daemon before moving on,
    # even when the watchdog marker was already written.
    stop_gradle
    if [[ -e "$GRADLE_TIMED_OUT" ]]; then
      warn "$app gradle warm build hung past ${GRADLE_TIMEOUT_MIN}m and was killed (Gradle --continue deadlock, as in the v7 bake); keeping what it fetched"
    elif (( GRADLE_RC != 0 )); then
      warn "$app gradle warm build did not complete (expected without codegen); keeping what it fetched"
    fi
    # Keep only the wrapper distribution the generated project pins. Anything
    # else in dists/ is a stale guess (v6 carried a 700MB gradle-8.14.3-all
    # from 15-prime-tools.sh next to the 9.0.0-bin the app actually uses).
    WRAPPER_DIST="$(sed -n 's#.*distributions/\(gradle-[^/]*\)\.zip.*#\1#p' \
      "$APPDIR/android/gradle/wrapper/gradle-wrapper.properties" 2>/dev/null | head -1)"
    # What `expo prebuild` wrote, what the build configured, and which CMake
    # AGP actually ran (its binary path is recorded in the generated
    # project's .cxx/ build files; the build itself never logs the version).
    pin_check GRADLE_VERSION "${GRADLE_VERSION}-${GRADLE_DIST_TYPE}" "${WRAPPER_DIST#gradle-}" "$app gradle-wrapper.properties"
    # (BSD sed has no \x1b, hence the printf'd ESC for the colour codes.)
    pin_check ANDROID_NDK "$ANDROID_NDK" \
      "$(sed "s/$(printf '\033')\[[0-9;]*m//g" "$GRADLE_LOG" 2>/dev/null | sed -n 's/.*- ndk: *\([0-9][0-9.]*\).*/\1/p' | head -1)" \
      "$app gradle configure log"
    pin_check ANDROID_CMAKE "$ANDROID_CMAKE" \
      "$(grep -rhoE 'cmake/[0-9][0-9.]*/bin/cmake' "$APPDIR/android/app/.cxx" 2>/dev/null | head -1 | cut -d/ -f2)" \
      "$app android/app/.cxx"
    if [[ -n "$WRAPPER_DIST" ]]; then
      for d in ~/.gradle/wrapper/dists/gradle-*; do
        [[ -d "$d" && "$(basename "$d")" != "$WRAPPER_DIST" ]] || continue
        echo "20-prime-repo: pruning stale Gradle distribution $(basename "$d") (app pins $WRAPPER_DIST)"
        rm -rf "$d"
      done
    fi
    # Transient state that must not ship in the image.
    rm -rf ~/.gradle/.tmp ~/.gradle/daemon ~/.gradle/notifications ~/.gradle/workers
  fi

  # iOS: populates ~/.cocoapods + ~/Library/Caches/CocoaPods.
  if [[ -d "$APPDIR/ios" ]]; then
    ( cd "$APPDIR/ios" && pod install ) || warn "$app pod install failed"
  fi
done

echo "20-prime-repo: done (warmed whatever succeeded above)"

# Report what actually landed. Every step above is best-effort, so without
# this the bake looks identical whether the caches warmed or silently did
# not - which is how ghrunner-mobile-v2 shipped with a cold pod cache and
# spent ~7m22s per job re-downloading 171 pods.
set +x
echo "20-prime-repo: cache summary (empty/missing = NOT warmed)"
CACHE_DIRS=(~/.cocoapods ~/Library/Caches/CocoaPods)
if [[ "$WITH_ANDROID" == 1 ]]; then
  # modules-2 = dependencies, build-cache-1 = task outputs (both mirrored onto
  # the share by run-slot.sh); caches/<ver>/transforms = artifact transforms,
  # which only the image can warm. A small transforms dir means the build
  # above did not get past dependency resolution.
  CACHE_DIRS+=(~/.gradle/wrapper/dists ~/.gradle/caches/modules-2
               ~/.gradle/caches/build-cache-1 ~/.gradle/caches/*/transforms)
fi
for d in "${CACHE_DIRS[@]}"; do
  if [[ -d "$d" ]]; then
    printf '  %-32s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
  else
    printf '  %-32s MISSING\n' "$d"
  fi
done

# versions.env against this checkout and this build. UNKNOWN means the step
# that would have revealed the value did not run (no Android build, prebuild
# failed); DRIFT means versions.env is stale - fix it there, and expect
# `mise run runner:pins` to say the same.
echo "20-prime-repo: pin check (versions.env vs. this bake)"
printf '  %-22s %-16s %-16s %-6s %s\n' KEY versions.env observed STATUS source
printf '%s\n' ${PIN_REPORT[@]+"${PIN_REPORT[@]}"}   # bash 3.2 + set -u: empty-array-safe
if (( PIN_DRIFT )); then
  warn "versions.env disagrees with what this bake built against (DRIFT above); the image works but carries a stale pin"
fi
