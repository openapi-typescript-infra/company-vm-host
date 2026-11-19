#!/bin/bash
# Install the Google Cloud CLI in a worker image without signing in.
set -euo pipefail
case "$(uname -s)" in
  Linux)
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    curl --proto '=https' -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg > "$work/key"
    gpg --batch --dearmor --output "$work/cloud.google.gpg" "$work/key"
    sudo install -m 644 "$work/cloud.google.gpg" /usr/share/keyrings/cloud.google.gpg
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' |
      sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin
    ;;
  Darwin)
    export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
    HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask gcloud-cli
    ;;
  *) echo 'Unsupported worker OS' >&2; exit 1 ;;
esac
gcloud version
if [[ -n "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ]]; then
  echo 'Worker image contains an active gcloud login. Inspect before publishing.' >&2
  exit 1
fi
