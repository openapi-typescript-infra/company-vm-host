#!/usr/bin/env bash
# Compare the host tool pins with the latest upstream releases, and optionally
# rewrite every copy of them in the repo.
#
#   ./check-pins.sh           print a table; exit 1 when any copy is behind
#   ./check-pins.sh --apply   rewrite the stale copies, print what changed
#
# These pins live in env files and shell defaults, outside any ecosystem
# Dependabot understands, so .github/workflows/pin-bumps.yml runs this weekly
# and opens a PR from the result. The copies kept in sync:
#   envs/*.env, runner.env.example     KEY=value lines
#   remote/bootstrap.sh, run-slot.sh   KEY="${KEY:-value}" fallbacks
#   */Dockerfile                       ARG RUNNER_VERSION=value defaults
# Needs `gh` (logged in) or GH_TOKEN for the releases API.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

# KEY  upstream repo. The latest *release* (not tag), so pre-releases and
# release candidates never land here.
PINS=(
  "RUNNER_VERSION    actions/runner"
  "CONTAINER_VERSION apple/container"
  "TART_VERSION      openai/tart"
  "LIMA_VERSION      lima-vm/lima"
)

latest_release() { # <owner/repo> -> version without a leading v
  local tag
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    tag="$(gh api "repos/$1/releases/latest" --jq .tag_name)"
  else
    [[ -n "${GH_TOKEN:-}" ]] || { echo "need gh (logged in) or GH_TOKEN" >&2; exit 2; }
    tag="$(curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$1/releases/latest" \
      | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p')"
  fi
  [[ -n "$tag" ]] || { echo "no release found for $1" >&2; exit 2; }
  printf '%s' "${tag#v}"
}

# Files holding a copy of <KEY>, one per line, each followed by a sed -E
# expression that rewrites its value to NEW (substituted below).
copies() { # <KEY>
  local key="$1" f
  for f in envs/*.env runner.env.example; do
    [[ -f "$f" ]] && printf '%s\t%s\n' "$f" "s|^(${key}=)[^ #]*|\\1NEW|"
  done
  for f in remote/bootstrap.sh remote/run-slot.sh; do
    grep -q "^${key}=\"\${${key}:-" "$f" 2>/dev/null \
      && printf '%s\t%s\n' "$f" "s|^(${key}=\"\\$\\{${key}:-)[^}]*|\\1NEW|"
  done
  if [[ "$key" == RUNNER_VERSION ]]; then
    while IFS= read -r f; do
      printf '%s\t%s\n' "$f" "s|^(ARG ${key}=)[^ ]*|\\1NEW|"
    done < <(find . -name Dockerfile -not -path '*/node_modules/*' -exec grep -l "^ARG ${key}=" {} + | sort)
  fi
}

current_value() { # <file> <KEY>
  case "$1" in
    *.env|*.example) sed -n "s/^$2=\([^ #]*\).*/\1/p" "$1" | tail -1 ;;
    *.sh)            sed -n "s/^$2=\"\${$2:-\([^}]*\)}\".*/\1/p" "$1" | tail -1 ;;
    *Dockerfile)     sed -n "s/^ARG $2=\([^ ]*\).*/\1/p" "$1" | tail -1 ;;
  esac
}

rewrite() { # <file> <sed expr>   (no sed -i: GNU and BSD disagree on its syntax)
  local tmp
  tmp="$(mktemp)"
  sed -E "$2" "$1" > "$tmp"
  cat "$tmp" > "$1"
  rm -f "$tmp"
}

drift=0
printf '%-18s %-10s %-10s %s\n' KEY latest current file
for entry in "${PINS[@]}"; do
  read -r key repo <<<"$entry"
  new="$(latest_release "$repo")"
  while IFS=$'\t' read -r file expr; do
    cur="$(current_value "$file" "$key")"
    if [[ "$cur" == "$new" ]]; then
      printf '%-18s %-10s %-10s %s\n' "$key" "$new" "$cur" "$file"
      continue
    fi
    if (( APPLY )); then
      rewrite "$file" "${expr//NEW/$new}"
      printf '%-18s %-10s %-10s %s  <- updated\n' "$key" "$new" "${cur:-?}" "$file"
    else
      printf '%-18s %-10s %-10s %s  <- BEHIND\n' "$key" "$new" "${cur:-?}" "$file"
    fi
    drift=1
  done < <(copies "$key")
done

if (( drift && !APPLY )); then
  echo "pins are behind upstream; run $0 --apply" >&2
  exit 1
fi
