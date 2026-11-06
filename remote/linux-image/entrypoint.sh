#!/bin/bash
# Runs one GitHub Actions job from the single-use JIT config passed in by
# the host-side slot supervisor, then exits (the container is --rm'd).
set -euo pipefail

if [[ -z "${GH_JIT_CONFIG:-}" ]]; then
  echo "entrypoint: GH_JIT_CONFIG not set" >&2
  exit 1
fi

cd /home/runner/runner
exec ./run.sh --jitconfig "$GH_JIT_CONFIG"
