#!/bin/bash
# Runs inside the guest as the admin user (passwordless sudo available).
# Keep steps idempotent - a re-bake replays this from the base image.
#
# Targets github.com/your-org/your-app (Expo SDK / RN / compileSdk per
# versions.env), New Architecture enabled, EAS local iOS+Android builds, and a
# Maestro e2e job. Bump BAKE_IMAGE_NAME when you change this or versions.env.
set -euxo pipefail

# This script backs two bake dirs (ios-bake/scripts symlinks it), so the two
# images cannot drift. BAKE_WITH_ANDROID=0 in bake.env drops the Android SDK
# layer - cmdline-tools, the platforms, build-tools, NDK and CMake, plus their
# env exports and checks - for a host that only builds iOS. Default 1: with it
# unset this script produces the full mobile image used by the runner host.
#
# The JDK and Maestro stay on both images. Maestro is a JVM tool and its e2e
# job drives an iOS simulator, so neither is Android-only.
WITH_ANDROID="${BAKE_WITH_ANDROID:-1}"

# Versions come from the repo's versions.env, which bake.sh copies next to
# this script in the guest. Nothing is pinned here: that file explains each
# pin and `mise run runner:pins` diffs it against what mobile-apps declares.
# Missing file = a bake.sh older than this script; fail rather than install
# whatever floats.
# shellcheck source=../../versions.env
source "$(dirname "${BASH_SOURCE[0]}")/versions.env"
: "${NODE_VERSION:?versions.env}" "${JAVA_VERSION:?versions.env}" "${MAESTRO_VERSION:?versions.env}" \
  "${ANDROID_COMPILE_SDK:?versions.env}" "${ANDROID_LEGACY_PLATFORM:?versions.env}" \
  "${ANDROID_BUILD_TOOLS:?versions.env}" "${ANDROID_NDK:?versions.env}" "${ANDROID_CMAKE:?versions.env}"

# Homebrew tracks Node by major only; setup-node installs the exact
# NODE_VERSION inside the job, so the image copy is there to make that a
# cache hit, not to be the build's Node.
NODE_FORMULA="node@${NODE_VERSION%%.*}"

# app.config.ts sets targetSdkVersion as well. It gets no pin because targetSdk
# is a manifest value, not a build input - only compileSdk needs its platform
# installed. The earlier ANDROID_TARGET_SDK=35 was really just installing a
# second platform, and had drifted from the app besides; ANDROID_LEGACY_PLATFORM
# in versions.env is that second platform, kept on purpose.

# Homebrew is not on PATH for a non-interactive SSH shell (the login profile
# that runs `brew shellenv` is not sourced), so load it ourselves. Covers
# both Apple Silicon (/opt/homebrew) and Intel (/usr/local) images.
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
else
  echo "brew not found at /opt/homebrew or /usr/local; base image has no Homebrew" >&2
  exit 1
fi

brew update

# Homebrew's CA store (Mozilla's roots plus the system keychain's). Homebrew's
# OpenSSL symlinks its cert.pem to this one, so brewed Ruby (fastlane,
# CocoaPods) and Python trust what it trusts, and gcloud is pointed at it
# below. From 2026-09-25_1 it leaves out the roots behind the eMudhra
# intermediate key compromise (Oct 2026); install also upgrades an older copy
# left by the base image. The sanity checks confirm both roots are gone.
brew install ca-certificates
CA_BUNDLE="$(brew --prefix)/etc/ca-certificates/cert.pem"

# --- iOS / native tooling -------------------------------------------------
# Keep this CI contract explicit instead of installing mobile-apps/Brewfile:
# that file also describes a developer workstation and intentionally overlaps
# with runner-pinned Node, Java, gcloud, Android SDK, and Maestro installs.
brew install fastlane cocoapods jq watchman

# ccache: React Native's Podfile routes CC/CXX/LD through it when the job sets
# USE_CCACHE=1 (Expo's SDK 55 and 57 templates honour the same variable), and it
# only pays off with a cache that outlives the VM - which MACVM_KEEP_CACHES
# provides (CCACHE_DIR lands on the shared dir). xcodebuild was ~15 of a 21
# minute iOS build on the runner host, so this is the largest single lever. Without
# the binary RN just warns and builds without it.
brew install ccache

# The gcloud CLI is NOT optional: the app's private @your-company packages come
# from GCP Artifact Registry, and the yarn gcp-auth plugin authenticates by
# spawning `gcloud auth print-access-token`. Without the binary every private
# package fails to fetch with "Process gcloud failed to spawn / spawn gcloud
# ENOENT" and `yarn install` dies. The credentials themselves come from the
# job (google-github-actions/auth@v2 exports
# CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE), so only the CLI is baked here.
#
# NOT the Homebrew cask. `brew install --cask google-cloud-sdk` was renamed to
# gcloud-cli and its post-install now runs `gcloud config virtualenv create`,
# which pip-downloads a cryptography wheel from github.com; when that fetch
# fails brew unlinks and *purges* the cask, leaving no gcloud at all. Google's
# own tarball has no github.com hop and no virtualenv step.
#
# The darwin-arm tarball ships no bundled interpreter (only the x86_64 build
# does), so gcloud picks python3.9-3.14 off PATH. Leaving that to whatever
# python3 the base image happens to carry is how the cask broke us, so pin one
# and name it explicitly via CLOUDSDK_PYTHON.
brew install python@3.13
CLOUDSDK_PYTHON="$(brew --prefix python@3.13)/bin/python3.13"
export CLOUDSDK_PYTHON
"$CLOUDSDK_PYTHON" --version

# gcloud trusts the certifi bundle it vendors, which still has the eMudhra
# roots (587.0.0 does, and no release has dropped them yet). Its
# core/custom_ca_certs_file property replaces that bundle for every request,
# token refresh included, so name Homebrew's store, which is current.
export CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="$CA_BUNDLE"

# Machine-wide so every job user sees the same CLI, not one user's home.
GCLOUD_ROOT=/opt/google-cloud-sdk
sudo rm -rf "$GCLOUD_ROOT"
sudo mkdir -p "$(dirname "$GCLOUD_ROOT")"
curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-darwin-arm.tar.gz \
  | sudo tar -xz -C "$(dirname "$GCLOUD_ROOT")"

# Bootstrap now (compiles bytecode, writes .install state) so jobs don't pay
# for it, and so a broken download fails the bake here rather than mid-job.
# --install-python=false is the whole point: true is what runs `gcloud config
# virtualenv create` and pip-installs cryptography from github.com, i.e. the
# cask's failure mode. `sudo env` rather than `sudo -E`, which default sudoers
# (env_reset, no SETENV) refuses.
#
# -H matters: macOS sudo leaves HOME alone, so without it the root-run
# installer creates ~admin/.config/gcloud owned by root. Every later gcloud run
# as the job user then prints "WARNING: Could not setup log file ...
# PermissionError" on stdout, the yarn gcp-auth plugin parses that warning as
# the access token ("TypeError: Cannot create property 'message' on string
# 'WARNING: ...'"), and `yarn install` dies with no node_modules - which stops
# the pod prime dead. `gcloud --version` still exits 0 through all of that, so
# the probe further down is what actually catches it.
sudo -H env CLOUDSDK_PYTHON="$CLOUDSDK_PYTHON" "$GCLOUD_ROOT/install.sh" --quiet \
  --usage-reporting=false \
  --path-update=false \
  --command-completion=false \
  --install-python=false

# Belt and braces for the above, and makes a re-bake idempotent regardless of
# how the local sudoers treats HOME: this dir is regenerated on demand.
sudo rm -rf "$HOME/.config/gcloud"

# /usr/local/bin is already forced onto the job PATH below (for warp-cli), so
# symlinking there is what puts gcloud in front of the yarn gcp-auth plugin.
sudo mkdir -p /usr/local/bin
for gcloud_bin in gcloud gsutil bq; do
  sudo ln -sf "$GCLOUD_ROOT/bin/$gcloud_bin" "/usr/local/bin/$gcloud_bin"
done
export PATH="/usr/local/bin:$PATH"

# xcpretty formats xcodebuild output in the Maestro job.
sudo gem install --no-document xcpretty || gem install --no-document xcpretty

# System Ruby's gem executable dir is /usr/local/bin, which is NOT on a
# non-interactive shell's PATH (path_helper never runs over SSH), so the
# freshly installed xcpretty is invisible to the sanity check below and to
# jobs. Resolve the gem bindir(s) and put them on PATH now; they are also
# added to /etc/zshenv further down so jobs inherit them.
GEM_BIN="$(ruby -e 'print Gem.bindir' 2>/dev/null || true)"
GEM_USER_BIN="$(ruby -e 'print Gem.user_dir' 2>/dev/null || true)/bin"
export PATH="$PATH${GEM_BIN:+:$GEM_BIN}${GEM_USER_BIN:+:$GEM_USER_BIN}"

# Pre-accept the Xcode license so jobs don't trip over it.
sudo xcodebuild -license accept || true

# Warm the CocoaPods spec repo so the first job doesn't clone it cold.
pod repo update || true

# iOS 18 simulator runtime: the Maestro job boots an iPhone 16 on iOS ^18,
# but the Tahoe/Xcode base ships only the newest (iOS 26) runtime. Pre-fetch
# 18 so a fresh VM doesn't download it per job. Best-effort: adjust the
# point release to one Xcode offers if this errors.
sudo xcodebuild -downloadPlatform iOS -buildVersion 18.5 || \
  echo "WARNING: could not prefetch iOS 18 simulator runtime; simulator-action will download it per job"

# --- Node + Expo/EAS ------------------------------------------------------
# The workflow installs Node (setup-node) and EAS/Expo CLIs (expo-github-
# action) itself; we keep a matching Node on the image for convenience and
# to avoid a cold re-download. Pin the major to the app's engines field.
brew install "$NODE_FORMULA"
brew link --overwrite --force "$NODE_FORMULA"

# --- JDK ------------------------------------------------------------------
# The JDK the app's eas-build-ship action sets up (setup-java) is what the
# Gradle build expects, and it is also what the Maestro CLI runs on - so it is
# installed on the iOS-only image too, where nothing Gradle remains.
brew install --cask "temurin@${JAVA_VERSION}"

# --- Android SDK ----------------------------------------------------------
if [[ "$WITH_ANDROID" == 1 ]]; then
  brew install --cask android-commandlinetools

  # The cask installs the SDK under the Homebrew prefix and puts sdkmanager on
  # PATH. Install packages into that same root.
  ANDROID_SDK_ROOT="$(brew --prefix)/share/android-commandlinetools"
  export ANDROID_SDK_ROOT ANDROID_HOME="$ANDROID_SDK_ROOT"

  yes | sdkmanager --licenses >/dev/null || true
  sdkmanager --install \
    "platform-tools" \
    "platforms;android-${ANDROID_COMPILE_SDK}" \
    "platforms;android-${ANDROID_LEGACY_PLATFORM}" \
    "build-tools;${ANDROID_BUILD_TOOLS}" \
    "ndk;${ANDROID_NDK}" \
    "cmake;${ANDROID_CMAKE}"
else
  echo "10-mobile-tooling: BAKE_WITH_ANDROID=0; skipping the Android SDK layer"
fi

# --- Maestro CLI ----------------------------------------------------------
# Installs into ~/.maestro (persists in the image, admin's home). Needs a
# JDK, installed above. Pinned: the installer takes whatever is newest
# otherwise, which made the v5 image unreproducible.
curl -fsSL "https://get.maestro.mobile.dev" | MAESTRO_VERSION="$MAESTRO_VERSION" bash

# --- Cloudflare WARP ------------------------------------------------------
# GraphQL codegen (`yarn build`) introspects api.internal.example.com, which
# resolves to a private 10.42.0.0/16 address reachable only over the VPN. The
# public exposed.dev host is not a substitute: it proxies the internal API but answers
# introspection with "403 GraphQL introspection is disabled".
#
# Only the client is installed here - the image must stay UNREGISTERED. A
# registration identifies one device, so baking one in would make every VM
# cloned from this image share (and fight over) it, and deleting that device
# in the dashboard would strand every clone on "Registration Missing due to:
# Does not exist in API". run-slot.sh enrolls each VM at boot instead, using
# a service token kept on the host.
brew install --cask cloudflare-warp

# Persist env into every job. The runner is launched over SSH as `zsh -c`,
# which always sources /etc/zshenv (login profiles are not read for
# non-interactive commands), so this is the reliable hook.
#
# The Android exports and PATH entries are folded in as variables rather than
# written unconditionally: with BAKE_WITH_ANDROID=0 there is no SDK for them to
# point at, and an ANDROID_HOME aimed at a missing dir is worse than none - a
# Gradle build would get further before failing, and less legibly.
if [[ "$WITH_ANDROID" == 1 ]]; then
  ZSHENV_TITLE="Android SDK + NDK + Maestro"
  ANDROID_ENV_BLOCK="export ANDROID_HOME=\"${ANDROID_SDK_ROOT}\"
export ANDROID_SDK_ROOT=\"${ANDROID_SDK_ROOT}\"
export ANDROID_NDK_HOME=\"${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK}\""
  ANDROID_PATH_TAIL=":${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin"
else
  ZSHENV_TITLE="iOS toolchain + Maestro (no Android SDK)"
  ANDROID_ENV_BLOCK="# Baked with BAKE_WITH_ANDROID=0: no Android SDK on this image, so no
# ANDROID_HOME / ANDROID_SDK_ROOT / ANDROID_NDK_HOME are exported."
  ANDROID_PATH_TAIL=""
fi

sudo tee -a /etc/zshenv >/dev/null <<EOF

# --- ghrunner mobile bake: ${ZSHENV_TITLE} ---
${ANDROID_ENV_BLOCK}
# Homebrew's bin and the gem bindir are not on a job's non-interactive
# zsh PATH by default (path_helper does not run), so fastlane/pod/node/
# xcpretty would be invisible. /usr/local/bin is missing for the same reason,
# which hides warp-cli (the cask symlinks it there) and gcloud (symlinked there
# from /opt/google-cloud-sdk above). Prepend them alongside the Maestro dir -
# and the Android SDK dirs, on an image baked with them - so a job inherits the
# full baked toolchain.
export PATH="${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin:${GEM_BIN}:/usr/local/bin:\$PATH${ANDROID_PATH_TAIL}:\$HOME/.maestro/bin"
# gcloud is Google's tarball, which on darwin-arm bundles no interpreter and
# would otherwise pick the first python3.9-3.14 on PATH. Name the pinned one so
# a brew python bump cannot silently retarget the CLI the gcp-auth yarn plugin
# spawns.
export CLOUDSDK_PYTHON="${CLOUDSDK_PYTHON}"
# Homebrew's CA store instead of the certifi copy gcloud vendors, which still
# trusts the eMudhra-compromise roots.
export CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="${CA_BUNDLE}"
EOF

# --- Sanity checks (fail the bake early if anything did not resolve) -------
fastlane --version
pod --version
jq --version
watchman --version
xcpretty --version
gcloud --version
# `gcloud --version` exits 0 even when gcloud cannot write its own config dir,
# so probe the exact command the yarn gcp-auth plugin spawns, as the job user.
# With no credentials in a bake guest it legitimately fails with "You do not
# currently have an active account" - that is fine and expected. A
# PermissionError here is not: it means gcloud will emit a warning where the
# plugin expects a token, and `yarn install` will fail for every private
# @your-company package.
gcloud_probe="$(gcloud auth print-access-token 2>&1 || true)"
case "$gcloud_probe" in
  *"Could not setup log file"*|*PermissionError*)
    echo "gcloud cannot write its config dir as $(id -un): $gcloud_probe" >&2
    exit 1 ;;
esac
[[ "$(gcloud config get core/custom_ca_certs_file 2>/dev/null)" == "$CA_BUNDLE" ]] \
  || { echo "gcloud does not see core/custom_ca_certs_file=${CA_BUNDLE}"; exit 1; }
# 05-distrust-emudhra.sh patched the system bundle; this covers the stores set
# up here too. Homebrew's OpenSSL reads its own cert.pem, normally a symlink to
# CA_BUNDLE.
bash "$(dirname "${BASH_SOURCE[0]}")/05-distrust-emudhra.sh" --check \
  /etc/ssl/cert.pem "$CA_BUNDLE" "$(brew --prefix)/etc/openssl@3/cert.pem"
/usr/local/bin/warp-cli --version
# Major only for Node (Homebrew formula) - see NODE_FORMULA above.
[[ "$(node --version)" == "v${NODE_VERSION%%.*}."* ]] \
  || { echo "node is $(node --version), not ${NODE_VERSION%%.*}.x (versions.env NODE_VERSION=${NODE_VERSION})"; exit 1; }
java -version 2>&1 | grep -q "version \"${JAVA_VERSION}\." \
  || { echo "java is not ${JAVA_VERSION}: $(java -version 2>&1 | head -1)"; exit 1; }
if [[ "$WITH_ANDROID" == 1 ]]; then
  sdkmanager --version
  "${ANDROID_SDK_ROOT}/platform-tools/adb" --version
  for d in "platforms/android-${ANDROID_COMPILE_SDK}" "platforms/android-${ANDROID_LEGACY_PLATFORM}" \
           "build-tools/${ANDROID_BUILD_TOOLS}" "ndk/${ANDROID_NDK}" "cmake/${ANDROID_CMAKE}"; do
    test -d "${ANDROID_SDK_ROOT}/$d" || { echo "Android SDK package missing: $d"; exit 1; }
  done
fi
ccache --version
[[ "$("$HOME/.maestro/bin/maestro" --version 2>/dev/null | tail -1)" == "$MAESTRO_VERSION" ]] \
  || { echo "Maestro is not ${MAESTRO_VERSION}: $("$HOME/.maestro/bin/maestro" --version 2>&1)"; exit 1; }
