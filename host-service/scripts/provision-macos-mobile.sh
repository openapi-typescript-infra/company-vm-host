#!/bin/bash
# Run as the macOS worker user during image preparation.
set -euo pipefail
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]]
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
# Copy the operator's already-accepted SDK licenses into this directory before baking.
[[ -d "$ANDROID_HOME/licenses" ]] || { echo 'Android SDK license acceptance is required before baking.' >&2; exit 1; }
HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask android-commandlinetools
sdkmanager=/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager
[[ -x "$sdkmanager" ]]
"$sdkmanager" --sdk_root="$ANDROID_HOME" 'platform-tools' 'platforms;android-37' 'build-tools;37.0.0' 'ndk;27.1.12297006' </dev/null
# Keep the SDK visible in non-login shells and JIT runner sessions.
sudo ln -sfn "$sdkmanager" /usr/local/bin/sdkmanager
printf '%s\n' 'export ANDROID_HOME=/opt/android-sdk' 'export ANDROID_SDK_ROOT=/opt/android-sdk'   'export ANDROID_NDK_HOME=/opt/android-sdk/ndk/27.1.12297006' |
  sudo tee /etc/profile.d-parktab-android >/dev/null
if ! grep -q 'profile.d-parktab-android' /etc/zshenv; then
  echo '. /etc/profile.d-parktab-android' | sudo tee -a /etc/zshenv >/dev/null
fi
# Apple documents G3 as the issuer for iOS Distribution signing certificates.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --proto '=https' -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$work/wwdr.cer"
openssl x509 -inform DER -in "$work/wwdr.cer" -noout -subject -issuer -dates
security import "$work/wwdr.cer" -k "$HOME/Library/Keychains/login.keychain-db"
security find-certificate -c 'Apple Worldwide Developer Relations Certification Authority' "$HOME/Library/Keychains/login.keychain-db" >/dev/null
"$ANDROID_HOME/build-tools/37.0.0/aapt2" version
"$ANDROID_HOME/ndk/27.1.12297006/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang" --version
java -version
echo 'macOS Android tools and Apple signing intermediate verified'
