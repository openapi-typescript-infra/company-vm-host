#!/bin/bash
# Starts the slot cycles of dispatcher-managed kinds (POLICY=scheduled or
# ondemand - see runner.env.example "Warm schedules and on-demand slots").
# Those slots are deployed without KeepAlive, so nothing loops them; this
# daemon decides when a cycle runs instead:
#   - inside a kind's warm schedule, every slot is kept running - the same
#     always-listening behavior KeepAlive used to provide. run-slot.sh
#     retires the runner when the window closes and this loop simply stops
#     restarting it, which is what shuts the VM down for the night;
#   - outside the window (and for ondemand kinds), it polls GitHub for
#     queued workflow jobs whose labels fit a cold kind and kickstarts just
#     enough slots to cover them. A booted runner that never gets its job
#     (another host took it, the run was cancelled) retires itself after
#     DISPATCH_IDLE_TIMEOUT - see run-slot.sh.
# Reading queued jobs needs the PAT to carry repo "Actions: read" on the
# watched repos, beyond the org self-hosted-runners write the slots need;
# bootstrap.sh probes for that and warns.
# One instance per host: the com.ghrunner.dispatcher LaunchDaemon, as root.
#
# Deliberately no set -e: a GitHub hiccup must degrade one pass, not
# crash-loop the daemon, so every fallible call is handled explicitly.
set -uo pipefail

source /etc/ghrunner/config.env
source /opt/ghrunner/bin/slot-lib.sh
PAT="$(cat /etc/ghrunner/github.pat)"
GH_ORG="${GH_ORG:?GH_ORG must be set in /etc/ghrunner/config.env}"

INTERVAL="${DISPATCH_INTERVAL:-60}"
MIN_QUEUE_AGE="${DISPATCH_MIN_QUEUE_AGE:-30}"
REPO_LIMIT="${DISPATCH_REPO_LIMIT:-15}"
NAME_PREFIX="$(runner_name_prefix)"

log() { printf '%s [dispatch] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

gh_api() { # <path-and-query> <outfile>
  curl -sS --fail --max-time 30 \
    -H "Authorization: Bearer $PAT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -o "$2" "https://api.github.com$1"
}

slot_daemon_running() { # <kind> <idx>
  launchctl print "system/com.ghrunner.${1}-${2}" 2>/dev/null \
    | grep -q '[[:space:]]pid = '
}

kickstart_slot() { # <kind> <idx> <why>
  if launchctl kickstart "system/com.ghrunner.${1}-${2}" 2>/dev/null; then
    log "started slot ${1}-${2} (${3})"
  else
    log "WARNING: could not kickstart slot ${1}-${2} (not provisioned?)"
  fi
}

# Repos watched for queued jobs, one owner/name per line: DISPATCH_REPOS
# (bare names get the org prepended), or - discovery fallback - the org's
# most recently pushed repos. Set DISPATCH_REPOS where you can: discovery
# costs an extra API call per pass and misses a rarely-pushed repo beyond
# the limit.
watched_repos() {
  local r resp i name archived
  if [[ -n "${DISPATCH_REPOS:-}" ]]; then
    for r in $DISPATCH_REPOS; do
      case "$r" in
        */*) echo "$r" ;;
        *)   echo "${GH_ORG}/${r}" ;;
      esac
    done
    return 0
  fi
  resp="$(mktemp)"
  if ! gh_api "/orgs/${GH_ORG}/repos?sort=pushed&direction=desc&per_page=${REPO_LIMIT}" "$resp"; then
    rm -f "$resp"
    log "WARNING: could not list org repos; set DISPATCH_REPOS, or give the PAT repo metadata read"
    return 1
  fi
  i=0
  while name="$(plutil -extract "${i}.full_name" raw -o - "$resp" 2>/dev/null)"; do
    archived="$(plutil -extract "${i}.archived" raw -o - "$resp" 2>/dev/null || echo false)"
    [[ "$archived" == "true" ]] || echo "$name"
    i=$((i + 1))
  done
  rm -f "$resp"
}

# Queued workflow jobs across the watched repos, one line per job in $1:
# the job's labels, comma-joined and lowercased. Jobs younger than
# DISPATCH_MIN_QUEUE_AGE are skipped - an already-listening runner anywhere
# in the org claims a matching job within seconds, so a job still queued
# after the grace period genuinely has nobody serving it. Queued jobs hide
# in queued, pending AND in_progress runs, so all three run states are
# scanned: in_progress for matrix/dependent jobs; pending for a run that was
# held by its concurrency group when created (GitHub leaves the run at
# "pending" even after the hold lifts and its job goes to "queued", so a
# queued-only scan never sees it - a mobile-apps E2E job sat unserved for
# 10 minutes that way on 2026-09-02 after a re-dispatch during a cancel).
collect_queued_jobs() { # <outfile>
  local out="$1" now repo run_status resp jresp rid i j k m n
  local jstatus created epoch labels lab
  : > "$out"
  now="$(date +%s)"
  while IFS= read -r repo; do
    for run_status in queued pending in_progress; do
      resp="$(mktemp)"
      if ! gh_api "/repos/${repo}/actions/runs?status=${run_status}&per_page=10" "$resp"; then
        log "WARNING: cannot list ${run_status} runs in ${repo} (PAT lacks repo Actions: read?)"
        rm -f "$resp"
        continue
      fi
      i=0
      while rid="$(plutil -extract "workflow_runs.${i}.id" raw -o - "$resp" 2>/dev/null)"; do
        i=$((i + 1))
        jresp="$(mktemp)"
        if ! gh_api "/repos/${repo}/actions/runs/${rid}/jobs?filter=latest&per_page=100" "$jresp"; then
          rm -f "$jresp"
          continue
        fi
        j=0
        while jstatus="$(plutil -extract "jobs.${j}.status" raw -o - "$jresp" 2>/dev/null)"; do
          k=$j
          j=$((j + 1))
          [[ "$jstatus" == "queued" ]] || continue
          created="$(plutil -extract "jobs.${k}.created_at" raw -o - "$jresp" 2>/dev/null || echo '')"
          # An unparseable timestamp counts as old: better one spurious boot
          # (it retires itself) than a queued job nobody picks up.
          epoch="$(date -ju -f '%Y-%m-%dT%H:%M:%SZ' "$created" +%s 2>/dev/null || echo 0)"
          (( now - epoch >= MIN_QUEUE_AGE )) || continue
          n="$(plutil -extract "jobs.${k}.labels" raw -o - "$jresp" 2>/dev/null || echo 0)"
          labels=""
          for ((m = 0; m < n; m++)); do
            lab="$(plutil -extract "jobs.${k}.labels.${m}" raw -o - "$jresp" 2>/dev/null || true)"
            [[ -n "$lab" ]] && labels+="${lab},"
          done
          [[ -n "$labels" ]] || continue
          printf '%s\n' "${labels%,}" | tr '[:upper:]' '[:lower:]' >> "$out"
        done
        rm -f "$jresp"
      done
      rm -f "$resp"
    done
  done < <(watched_repos)
  return 0
}

# This host's busy runners of one kind, counted from a fetched org-runners
# response via the slot naming scheme <prefix>-<kind-tag>-<idx>-<hex> (see
# run-slot.sh). Only the first 100 org runners are considered - the same
# assumption run-slot.sh's scavenger makes.
count_busy_runners() { # <runners-file> <kind>
  local file="$1" tag="${2//./-}" i=0 n=0 name status busy
  while name="$(plutil -extract "runners.${i}.name" raw -o - "$file" 2>/dev/null)"; do
    status="$(plutil -extract "runners.${i}.status" raw -o - "$file" 2>/dev/null || echo offline)"
    busy="$(plutil -extract "runners.${i}.busy" raw -o - "$file" 2>/dev/null || echo false)"
    i=$((i + 1))
    [[ "$status" == "online" && "$busy" == "true" ]] || continue
    if [[ "$name" =~ ^${NAME_PREFIX}-${tag}-[0-9]+-[0-9a-f]+$ ]]; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

# GitHub schedules a job onto a runner iff every job label is among the
# runner's labels; test a queued job's labels against a kind's label set
# (both comma-joined, lowercased).
job_fits() { # <job-labels> <kind-labels>
  local jl kl=",$2,"
  [[ -n "$1" ]] || return 1
  local IFS=','
  for jl in $1; do
    [[ "$kl" == *",${jl},"* ]] || return 1
  done
}

run_pass() {
  local kind policy count idx k
  local cold_kinds=() cold_counts=() cold_labels=()
  local jobs_file runners_file

  while IFS= read -r kind; do
    count="$(kind_count "$kind")"
    (( count > 0 )) || continue
    policy="$(slot_policy "$kind")"
    [[ "$policy" == "always" ]] && continue
    if [[ "$policy" == "scheduled" ]] && schedule_remaining "$(slot_schedule "$kind")" >/dev/null; then
      # Warm window: keep every slot of the kind running - KeepAlive's job,
      # done here so the window's close can stop the looping.
      for ((idx = 1; idx <= count; idx++)); do
        slot_daemon_running "$kind" "$idx" \
          || kickstart_slot "$kind" "$idx" "warm window"
      done
      continue
    fi
    resolve_slot_labels "$kind" || continue
    cold_kinds+=("$kind")
    cold_counts+=("$count")
    cold_labels+=("$(printf '%s\n' "$LABELS" | tr '[:upper:]' '[:lower:]')")
  done < <(all_kinds)

  (( ${#cold_kinds[@]} > 0 )) || return 0

  jobs_file="$(mktemp)"
  collect_queued_jobs "$jobs_file"
  if [[ ! -s "$jobs_file" ]]; then
    rm -f "$jobs_file"
    return 0
  fi

  # Supply per cold kind: a running cycle whose runner is not busy is either
  # still booting or already listening - it will absorb one queued job
  # without help. Busy runners come from the org runners API; running cycles
  # from launchd.
  runners_file="$(mktemp)"
  if ! gh_api "/orgs/${GH_ORG}/actions/runners?per_page=100" "$runners_file"; then
    log "WARNING: could not list org runners; skipping this pass"
    rm -f "$jobs_file" "$runners_file"
    return 1
  fi
  local supply=() free=() busy running
  for k in "${!cold_kinds[@]}"; do
    kind="${cold_kinds[$k]}"
    running=0
    free[$k]=""
    for ((idx = 1; idx <= ${cold_counts[$k]}; idx++)); do
      if slot_daemon_running "$kind" "$idx"; then
        running=$((running + 1))
      else
        free[$k]="${free[$k]} ${idx}"
      fi
    done
    busy="$(count_busy_runners "$runners_file" "$kind")"
    supply[$k]=$(( running - busy ))
    (( supply[$k] >= 0 )) || supply[$k]=0
  done
  rm -f "$runners_file"

  # Hand each queued job to the first cold kind that fits and still has a
  # waiting cycle (consumes supply) or a free slot (schedules a boot);
  # spill to the next fitting kind when one is exhausted.
  local jl boot=()
  for k in "${!cold_kinds[@]}"; do boot[$k]=0; done
  while IFS= read -r jl; do
    for k in "${!cold_kinds[@]}"; do
      job_fits "$jl" "${cold_labels[$k]}" || continue
      if (( supply[$k] > 0 )); then
        supply[$k]=$(( supply[$k] - 1 ))
        break
      fi
      set -- ${free[$k]}
      if (( $# > boot[$k] )); then
        boot[$k]=$(( boot[$k] + 1 ))
        break
      fi
    done
  done < "$jobs_file"
  rm -f "$jobs_file"

  for k in "${!cold_kinds[@]}"; do
    (( boot[$k] > 0 )) || continue
    kind="${cold_kinds[$k]}"
    log "${boot[$k]} queued job(s) fit cold kind ${kind}"
    set -- ${free[$k]}
    for ((idx = 0; idx < boot[$k]; idx++)); do
      kickstart_slot "$kind" "$1" "queued job"
      shift
    done
  done
  return 0
}

log "dispatcher started: interval ${INTERVAL}s, runner prefix '${NAME_PREFIX}'"
while :; do
  run_pass || log "WARNING: dispatch pass failed; retrying in ${INTERVAL}s"
  sleep "$INTERVAL"
done
