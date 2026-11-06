#!/bin/bash
# Network-free image smoke test. Run during the image build and directly via
# an overridden entrypoint before routing a real Actions job to the flavor.
#
# Expected versions come from /etc/ghrunner-versions.env, which the Dockerfile
# writes from the --build-args it was given (the repo's versions.env), so this
# script checks the image against the pins it was built with rather than a
# second copy of them.
set -euo pipefail

fail() { echo "verify-android-toolchain: $*" >&2; exit 1; }

skip_x86_tools=false
if [[ "${1:-}" == --skip-x86-tools ]]; then
  skip_x86_tools=true
elif [[ $# -ne 0 ]]; then
  fail "usage: verify-android-toolchain [--skip-x86-tools]"
fi

PINS=/etc/ghrunner-versions.env
[[ -r "$PINS" ]] || fail "$PINS missing; the image was not built by this Dockerfile"
# shellcheck source=/dev/null
source "$PINS"
for v in NODE_VERSION YARN_VERSION JAVA_VERSION ANDROID_COMPILE_SDK ANDROID_LEGACY_PLATFORM \
         ANDROID_BUILD_TOOLS ANDROID_LEGACY_BUILD_TOOLS ANDROID_NDK ANDROID_EXPO_NDK ANDROID_CMAKE \
         WARP_VERSION; do
  [[ -n "${!v:-}" ]] || fail "$PINS does not set $v"
done

[[ "$(node --version)" == "v${NODE_VERSION}" ]] || fail "Node ${NODE_VERSION} is not active ($(node --version))"
[[ "$(yarn --version)" == "$YARN_VERSION" ]] || fail "Yarn ${YARN_VERSION} is not active ($(yarn --version))"
java -version 2>&1 | grep -q "version \"${JAVA_VERSION}\." || fail "Java ${JAVA_VERSION} is not active"
eas --version >/dev/null || fail "EAS CLI is unavailable"
gcloud --version >/dev/null || fail "gcloud is unavailable"
sdkmanager --version >/dev/null || fail "sdkmanager is unavailable"
[[ "$(warp-cli --version)" == "warp-cli ${WARP_VERSION}" ]] \
  || fail "Cloudflare WARP ${WARP_VERSION} is unavailable ($(warp-cli --version))"
if ldd /usr/local/bin/warp-svc | grep -q 'not found'; then
  fail "warp-svc has unresolved shared libraries"
fi

x86_tools=(
  "$ANDROID_SDK_ROOT/build-tools/${ANDROID_LEGACY_BUILD_TOOLS}/aapt2"
  "$ANDROID_SDK_ROOT/build-tools/${ANDROID_BUILD_TOOLS}/aapt2"
  "$ANDROID_SDK_ROOT/ndk/${ANDROID_EXPO_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
  "$ANDROID_SDK_ROOT/ndk/${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
  "$ANDROID_SDK_ROOT/cmake/${ANDROID_CMAKE}/bin/cmake"
)
for path in \
  "$ANDROID_SDK_ROOT/platform-tools/adb" \
  "$ANDROID_SDK_ROOT/platforms/android-${ANDROID_LEGACY_PLATFORM}/android.jar" \
  "$ANDROID_SDK_ROOT/platforms/android-${ANDROID_COMPILE_SDK}/android.jar" \
  "${x86_tools[@]}" \
  /opt/hermes/build/bin/hermesc \
  /home/runner/runner/run.sh; do
  [[ -e "$path" ]] || fail "missing $path"
done

if [[ "$skip_x86_tools" == false ]]; then
  for tool in "${x86_tools[@]}"; do
    case "$tool" in
      */aapt2) "$tool" version >/dev/null ;;
      *)       "$tool" --version >/dev/null ;;
    esac || fail "$tool does not run"
  done
fi

echo "verify-android-toolchain: ok"
