#!/bin/bash
# Runs inside the guest as the admin user (passwordless sudo available).
set -euxo pipefail

brew update
brew install fastlane cocoapods

# Pre-accept the Xcode license so jobs don't trip over it.
sudo xcodebuild -license accept || true

# Android SDK, for React Native / cross-platform builds - uncomment:
#brew install --cask temurin
#brew install --cask android-commandlinetools
#yes | sdkmanager --licenses

# Warm caches that survive into every job (e.g. CocoaPods specs):
#pod repo update || true
