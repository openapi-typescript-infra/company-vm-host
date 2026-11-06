# shellcheck shell=bash
# Shared slot-kind helpers for bootstrap.sh, run-slot.sh and dispatch.sh:
# kind enumeration, label/policy/warm-schedule resolution, and schedule
# evaluation. Sourced (never executed) after the slot config
# (runner.env / /etc/ghrunner/config.env). macOS ships bash 3.2 - no
# associative arrays, and mind the ${a[@]+"${a[@]}"} empty-array idiom.

# Every slot kind this config can deploy, one per line (flavors included).
all_kinds() {
  local f
  echo mac
  echo linux
  echo linuxamd64
  for f in ${LINUX_FLAVORS:-}; do echo "linux.${f}"; done
  echo linuxvm
  echo linuxvmamd64
  echo macvm
}

# Configured slot count for a kind.
kind_count() {
  local n
  case "$1" in
    mac)          echo "${MAC_RUNNERS:-0}" ;;
    linux)        echo "${LINUX_RUNNERS:-0}" ;;
    linuxamd64)   echo "${LINUX_AMD64_RUNNERS:-0}" ;;
    linux.*)      n="LINUX_FLAVOR_${1#linux.}_RUNNERS"; echo "${!n:-0}" ;;
    linuxvm)      echo "${LINUXVM_RUNNERS:-0}" ;;
    linuxvmamd64) echo "${LINUXVM_AMD64_RUNNERS:-0}" ;;
    macvm)        echo "${MACVM_RUNNERS:-0}" ;;
    *)            echo 0 ;;
  esac
}

# Flavored linux slots (kind "linux.<flavor>") read their settings from
# LINUX_FLAVOR_<flavor>_* config vars, falling back to the LINUX_* defaults.
LINUX_FLAVOR=""
fvar() { local n="LINUX_FLAVOR_${LINUX_FLAVOR}_$1"; printf '%s' "${!n:-}"; }

# Resolves a kind into LABELS plus - for the container-linux kinds - the
# LINUX_FLAVOR/LINUX_ARCH that drive image/resource/flag selection in
# run-slot.sh. Returns 1 on an unknown kind.
resolve_slot_labels() {
  local kind="$1"
  LINUX_FLAVOR=""
  LINUX_ARCH=arm64
  case "$kind" in
    mac)          LABELS="${MAC_LABELS:-self-hosted,macos,arm64}" ;;
    macvm)        LABELS="${MACVM_LABELS:-self-hosted,macos,arm64,vm}" ;;
    linuxvm)      LABELS="${LINUXVM_LABELS:-self-hosted,linux,arm64,docker}" ;;
    linuxvmamd64) LABELS="${LINUXVM_AMD64_LABELS:-self-hosted,linux,x64,docker}" ;;
    linux|linux.*|linuxamd64)
      [[ "$kind" == linux.* ]] && LINUX_FLAVOR="${kind#linux.}"
      if [[ "$kind" == "linuxamd64" || "$(fvar ARCH)" == "amd64" ]]; then
        LINUX_ARCH=amd64
      fi
      LABELS="$(fvar LABELS)"
      if [[ -z "$LABELS" ]]; then
        # Unlabeled slots default to the label set matching their arch.
        if [[ "$LINUX_ARCH" == "amd64" ]]; then
          LABELS="${LINUX_AMD64_LABELS:-self-hosted,linux,x64}"
        else
          LABELS="${LINUX_LABELS:-self-hosted,linux,arm64}"
        fi
      fi
      ;;
    *) return 1 ;;
  esac
}

# Scheduling policy for a kind: always (default, KeepAlive loop), scheduled
# (warm inside the kind's schedule, on-demand outside), or ondemand (only
# ever booted by dispatch.sh for a queued job).
slot_policy() {
  local v n
  case "$1" in
    mac)          v="${MAC_POLICY:-}" ;;
    linux)        v="${LINUX_POLICY:-}" ;;
    linuxamd64)   v="${LINUX_AMD64_POLICY:-}" ;;
    linux.*)      n="LINUX_FLAVOR_${1#linux.}_POLICY"; v="${!n:-}" ;;
    linuxvm)      v="${LINUXVM_POLICY:-}" ;;
    linuxvmamd64) v="${LINUXVM_AMD64_POLICY:-}" ;;
    macvm)        v="${MACVM_POLICY:-}" ;;
    *)            v="" ;;
  esac
  printf '%s\n' "${v:-always}"
}

# Warm schedule for a kind: the per-kind <KIND>_WARM_SCHEDULE, else the
# global WARM_SCHEDULE, else weekday office hours.
slot_schedule() {
  local v n
  case "$1" in
    mac)          v="${MAC_WARM_SCHEDULE:-}" ;;
    linux)        v="${LINUX_WARM_SCHEDULE:-}" ;;
    linuxamd64)   v="${LINUX_AMD64_WARM_SCHEDULE:-}" ;;
    linux.*)      n="LINUX_FLAVOR_${1#linux.}_WARM_SCHEDULE"; v="${!n:-}" ;;
    linuxvm)      v="${LINUXVM_WARM_SCHEDULE:-}" ;;
    linuxvmamd64) v="${LINUXVM_AMD64_WARM_SCHEDULE:-}" ;;
    macvm)        v="${MACVM_WARM_SCHEDULE:-}" ;;
    *)            v="" ;;
  esac
  printf '%s\n' "${v:-${WARM_SCHEDULE:-Mon-Fri 08:00-19:00}}"
}

# Runner-name prefix shared by every slot on this host (run-slot.sh appends
# -<kind-tag>-<idx>-<hex>); dispatch.sh uses it to attribute registered
# runners back to slots.
runner_name_prefix() {
  printf '%s\n' "${RUNNER_NAME_PREFIX:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
}

_day_num() { # Mon -> 1 ... Sun -> 7 (ISO, matching date +%u)
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    mon) echo 1 ;; tue) echo 2 ;; wed) echo 3 ;; thu) echo 4 ;;
    fri) echo 5 ;; sat) echo 6 ;; sun) echo 7 ;;
    *) return 1 ;;
  esac
}

_hm_to_min() { # "HH:MM" -> minutes since midnight; 24:00 = end of day
  local h m
  [[ "$1" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  (( m <= 59 )) || return 1
  (( h < 24 || (h == 24 && m == 0) )) || return 1
  echo $(( h * 60 + m ))
}

# Parses one warm-schedule entry ("Mon-Fri 08:00-19:00") into the globals
# SCHED_D1/SCHED_D2 (ISO weekdays; the range may wrap past Sunday, as in
# "Fri-Mon") and SCHED_T1/SCHED_T2 (minutes since midnight, T1 < T2).
_parse_schedule_entry() {
  [[ "$1" =~ ^[[:space:]]*([A-Za-z]{3})(-([A-Za-z]{3}))?[[:space:]]+([0-9]{1,2}:[0-9]{2})-([0-9]{1,2}:[0-9]{2})[[:space:]]*$ ]] \
    || return 1
  local d2="${BASH_REMATCH[3]}" t1="${BASH_REMATCH[4]}" t2="${BASH_REMATCH[5]}"
  SCHED_D1="$(_day_num "${BASH_REMATCH[1]}")" || return 1
  if [[ -n "$d2" ]]; then
    SCHED_D2="$(_day_num "$d2")" || return 1
  else
    SCHED_D2="$SCHED_D1"
  fi
  SCHED_T1="$(_hm_to_min "$t1")" || return 1
  SCHED_T2="$(_hm_to_min "$t2")" || return 1
  (( SCHED_T1 < SCHED_T2 ))
}

# Evaluates a schedule (comma-separated "Days HH:MM-HH:MM" entries) against
# the current host-local time. Inside a window: prints the seconds until the
# widest enclosing window closes and returns 0. Outside every window (or on
# a malformed schedule, which validate_schedule catches at provision time):
# prints nothing and returns 1.
schedule_remaining() {
  local entry now_dow now_min best=-1
  now_dow="$(date +%u)"
  now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  while IFS= read -r entry; do
    [[ -n "${entry//[[:space:]]/}" ]] || continue
    _parse_schedule_entry "$entry" || continue
    if (( SCHED_D1 <= SCHED_D2 )); then
      (( now_dow >= SCHED_D1 && now_dow <= SCHED_D2 )) || continue
    else
      (( now_dow >= SCHED_D1 || now_dow <= SCHED_D2 )) || continue
    fi
    (( now_min >= SCHED_T1 && now_min < SCHED_T2 )) || continue
    (( (SCHED_T2 - now_min) * 60 > best )) && best=$(( (SCHED_T2 - now_min) * 60 ))
  done < <(printf '%s\n' "$1" | tr ',' '\n')
  (( best >= 0 )) || return 1
  echo "$best"
}

# Returns 0 iff every entry of the schedule parses (and there is at least
# one). Bootstrap dies on this so a typo fails the provision instead of
# surfacing as a slot that never warms.
validate_schedule() {
  local entry any=no
  while IFS= read -r entry; do
    [[ -n "${entry//[[:space:]]/}" ]] || continue
    _parse_schedule_entry "$entry" || return 1
    any=yes
  done < <(printf '%s\n' "$1" | tr ',' '\n')
  [[ "$any" == yes ]]
}
