# team-janitor disk: clears what nothing reads again from the home directory's caches, sourced
# after team.sh and tmp.sh by team-janitor (whose header is its usage) and by team-close:
#
#   # shellcheck source=bin/lib/tmp.sh
#   source "$TEAM_LIB/tmp.sh"
#   # shellcheck source=bin/lib/disk.sh
#   source "$TEAM_LIB/disk.sh"
#
# It provides disk_main [--dry-run | status [--json]], the whole run, which ends the script with
# the run's exit code, and disk_clear_job_tmp <job dir> <why> [<who>], the one clearing of a job
# tmp, which the run and team-close's fallback both call.
# The job part empties the tmp of each planner, builder or reviewer session (a launch of the
# ledger names its job) that nothing will wake again or that has been quiet for a day: its task is
# closed, Claude Code no longer lists it, it is stopped, or it is done or failed and unchanged for
# 24 hours; never one with a process. The tmp directory itself is kept.
# It reuses tmp.sh's process reader (tmp_read_processes, tmp_live) and its sizes and ages
# (tmp_size, tmp_age), never a copy of them.
# Test seams: TEAM_DISK_JOB_IDLE_MINUTES for the 24 hours (1440) a done or failed session must
# have been unchanged.
# shellcheck shell=bash

# Set when the run ends with exit 1.
DISK_FAILED=''
# The run's totals: the job tmps cleared and their kilobytes.
DISK_CLEARED=0 DISK_CLEARED_KB=0
# The size, in kilobytes, of the last tmp disk_clear_job_tmp cleared, and its line.
DISK_KB=0 DISK_LINE=''

# The state directory, the day's file and the record of the last run.
disk_paths() {
  disk_state=$HOME/.local/state/agent-team
  disk_dir=$disk_state/janitor
  disk_record_file=$disk_dir/disk.json
}

# <path>'s size in kilobytes (du -sk), 0 when du reads nothing.
disk_du() {
  local disk_out
  disk_out=$(du -sk -- "$1" 2>/dev/null) || true
  disk_out=${disk_out%%[!0-9]*}
  echo "${disk_out:-0}"
}

# Whether <path> is a real directory of this user's, never a link (lstat).
disk_own_dir() {
  [[ $(stat -c '%F|%u' -- "$1" 2>/dev/null) == "directory|$(id -u)" ]]
}

# Whether the directory <dir> holds at least one entry.
disk_has_entries() {
  [[ -n $(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]
}

# Append <line> to the day's file, made with its title at the day's first line.
disk_record() {
  local disk_state disk_dir disk_record_file disk_day disk_file disk_machine
  disk_paths
  disk_day=$(date +%F)
  disk_file=$disk_dir/disk-$disk_day.md
  disk_machine=$(machine_name 2>/dev/null || hostname -s 2>/dev/null || echo "this machine")
  if ! {
    mkdir -p "$disk_dir" &&
      { [[ -s $disk_file ]] || printf '# Disk cleared on %s, %s\n\n' "$disk_machine" "$disk_day" >"$disk_file"; } &&
      printf -- '- %s %s\n' "$(date +%H:%M)" "$1" >>"$disk_file"
  } 2>/dev/null; then
    echo "${0##*/}: could not write $disk_file" >&2
    DISK_FAILED=1
  fi
}

# Empty the job tmp <job dir>/tmp, keeping the directory and its mode, each entry removed by its
# own path; <why> and <who> (the job's id unless given) make its line, "cleared the job tmp of
# <who> (<size>; <why>)", which goes in the day's file and in DISK_LINE, its size in DISK_KB.
# Exit 0 cleared, 1 a removal failed (said on stderr), 2 nothing to clear: the job directory or
# its tmp is not a real directory of this user's, or the tmp is empty.
# disk_clear_job_tmp <job dir> <why> [<who>]
disk_clear_job_tmp() {
  local disk_job=$1 disk_why=$2 disk_who=${3:-${1##*/}} disk_tmp=$1/tmp disk_entry disk_err
  DISK_KB=0 DISK_LINE=''
  # Checked again just before the removal, so nothing is reached through a link put in its place.
  if ! disk_own_dir "$disk_job" || ! disk_own_dir "$disk_tmp"; then return 2; fi
  disk_has_entries "$disk_tmp" || return 2
  DISK_KB=$(disk_du "$disk_tmp")
  if ! disk_err=$(team_mktemp); then
    echo "${0##*/}: could not clear $disk_tmp: no temporary file for rm's errors could be made" >&2
    return 1
  fi
  while IFS= read -r -d '' disk_entry; do
    if [[ $(stat -c %F -- "$disk_entry" 2>/dev/null) == directory ]]; then
      # A read-only tree, a Go module cache say, is made writable first; chmod changes no link.
      chmod -R u+rwX -- "$disk_entry" 2>/dev/null || true
      rm -rf --one-file-system -- "$disk_entry" 2>>"$disk_err" || true
    else
      rm -f -- "$disk_entry" 2>>"$disk_err" || true
    fi
  done < <(find "$disk_tmp" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  if disk_has_entries "$disk_tmp"; then
    echo "${0##*/}: could not clear $disk_tmp: $(tmp_last_line "$disk_err")" >&2
    return 1
  fi
  DISK_LINE="cleared the job tmp of $disk_who ($(tmp_size "$DISK_KB"); $disk_why)"
  disk_record "$DISK_LINE"
}

# The team's sessions by job id, from the ledger's launches of a planner, builder or reviewer:
# DISK_TASKS[<id>] its task, DISK_ROLES[<id>] its role, DISK_CLOSED[<id>] 1 when its task is not
# open. Fails, saying why on stderr, when the ledger cannot be read.
declare -gA DISK_TASKS=() DISK_ROLES=() DISK_CLOSED=()
disk_read_ledger() {
  local disk_file=$TEAM_HOME/ledger.jsonl disk_lines disk_id disk_task disk_role disk_open
  if [[ ! -r $disk_file ]] || ! disk_lines=$(ledger_jq 'ledger_events | (by_task | map_values(is_open)) as $open
      | .[] | select(.event == "launch" and (.role | IN("planner", "builder", "reviewer"))
        and ((.session // "") | type == "string" and test("^[0-9a-f]{8}$")))
      | "\(.session) \(.task) \(.role) \(if $open[.task] then "open" else "closed" end)"' -nRr "$disk_file" 2>/dev/null); then
    echo "could not read the ledger, $disk_file" >&2
    return 1
  fi
  while read -r disk_id disk_task disk_role disk_open; do
    [[ -n $disk_id ]] || continue
    DISK_TASKS[$disk_id]=$disk_task DISK_ROLES[$disk_id]=$disk_role
    if [[ $disk_open == closed ]]; then DISK_CLOSED[$disk_id]=1; else unset 'DISK_CLOSED[$disk_id]'; fi
  done <<<"$disk_lines"
}

# The sessions Claude Code keeps, from claude agents --json --all: DISK_LISTED[<id>] its state,
# DISK_PIDS[<id>] its pid when it has one. Fails, saying why on stderr, when the list cannot be
# read.
declare -gA DISK_LISTED=() DISK_PIDS=()
disk_read_sessions() {
  local disk_json disk_lines disk_id disk_state disk_pid
  if ! disk_json=$(bounded 30 claude agents --json --all 2>"$TMP_WORK/agents.err"); then
    echo "claude agents --json --all failed: $(tmp_last_line "$TMP_WORK/agents.err")" >&2
    return 1
  fi
  if ! disk_lines=$(jq -r 'if type == "array" then .[] else error("not a list") end
      | select((.id | type) == "string") | "\(.id) \(.state // "unknown" | tostring) \(.pid // "" | tostring)"' \
    <<<"$disk_json" 2>/dev/null); then
    echo "claude agents --json --all printed no list of sessions" >&2
    return 1
  fi
  while read -r disk_id disk_state disk_pid; do
    [[ -n $disk_id ]] || continue
    DISK_LISTED[$disk_id]=$disk_state
    [[ -z $disk_pid ]] || DISK_PIDS[$disk_id]=$disk_pid
  done <<<"$disk_lines"
}

# The epoch second of the job <job dir>'s last change: its state.json's updatedAt, or that file's
# mtime when it has none or it does not parse; fails when there is no readable state.json.
disk_job_changed() {
  local disk_file=$1/state.json disk_at disk_epoch
  [[ -f $disk_file && -r $disk_file && ! -L $disk_file ]] || return 1
  disk_at=$(jq -r '.updatedAt // empty | strings' "$disk_file" 2>/dev/null) || disk_at=''
  if [[ -n $disk_at ]] && disk_epoch=$(date -d "$disk_at" +%s 2>/dev/null); then
    echo "$disk_epoch"
    return 0
  fi
  stat -c %Y -- "$disk_file" 2>/dev/null
}

# Why the team session of job <id> under <root> is to have its tmp cleared, by the rules in order,
# into disk_why; fails when it is kept.
disk_job_why() {
  local disk_id=$1 disk_job=$2/$1 disk_changed disk_state disk_idle
  disk_changed=$(disk_job_changed "$disk_job") || return 1
  [[ -z ${DISK_PIDS[$disk_id]:-} ]] || return 1
  if [[ -n ${DISK_CLOSED[$disk_id]:-} ]]; then
    disk_why="${DISK_TASKS[$disk_id]} is closed"
    return 0
  fi
  if [[ -z ${DISK_LISTED[$disk_id]+set} ]]; then
    disk_why='not listed by Claude Code'
    return 0
  fi
  disk_state=${DISK_LISTED[$disk_id]}
  case $disk_state in
    stopped)
      disk_why=stopped
      return 0
      ;;
    done | failed)
      disk_idle=$((disk_now - disk_changed))
      if ((disk_idle > disk_idle_minutes * 60)); then
        disk_why="$disk_state and idle $(tmp_age "$disk_idle")"
        return 0
      fi
      ;;
  esac
  return 1
}

# The job part: clear each team session's tmp the rules name, or on a dry run say it would.
disk_jobs() {
  local disk_root=$HOME/.claude/jobs disk_real disk_line disk_type disk_owner disk_id disk_why disk_reason
  local disk_ids=() disk_whys=() disk_i disk_job disk_kb disk_who disk_rc disk_uid
  [[ -d $disk_root ]] || return 0
  disk_real=$(realpath -- "$disk_root") || return 0
  disk_uid=$(id -u)
  # The candidates: real directories of this user's named as a job is, holding a tmp with entries.
  while IFS= read -r -d '' disk_line; do
    disk_type=${disk_line%% *} disk_line=${disk_line#* }
    disk_owner=${disk_line%% *} disk_id=${disk_line#* }
    [[ $disk_type == d && $disk_owner == "$disk_uid" && $disk_id =~ ^[0-9a-f]{8}$ ]] || continue
    disk_own_dir "$disk_real/$disk_id/tmp" || continue
    disk_has_entries "$disk_real/$disk_id/tmp" || continue
    disk_ids+=("$disk_id")
  done < <(find "$disk_real" -mindepth 1 -maxdepth 1 -printf '%y %U %f\0' 2>/dev/null | LC_ALL=C sort -z)

  # Nothing is cleared on a guess of whose a job is or whether it may be woken.
  if ! disk_read_ledger 2>"$TMP_WORK/ledger.err"; then
    echo "${0##*/}: $(tmp_last_line "$TMP_WORK/ledger.err"), so no job tmp was cleared" >&2
    DISK_FAILED=1
    return 0
  fi
  if ! disk_read_sessions 2>"$TMP_WORK/sessions.err"; then
    echo "${0##*/}: $(tmp_last_line "$TMP_WORK/sessions.err"), so no job tmp was cleared" >&2
    DISK_FAILED=1
    return 0
  fi
  local disk_candidates=()
  for disk_id in "${disk_ids[@]}"; do
    [[ -n ${DISK_TASKS[$disk_id]:-} ]] || continue
    disk_job_why "$disk_id" "$disk_real" || continue
    disk_candidates+=("$disk_id")
    disk_whys+=("$disk_why")
  done
  ((${#disk_candidates[@]})) || return 0

  TMP_ROOTS=("$disk_real")
  [[ $disk_root == "$disk_real" ]] || TMP_ROOTS+=("$disk_root")
  if ! disk_reason=$(tmp_read_processes 2>&1); then
    echo "${0##*/}: could not read this user's processes, so no job tmp was cleared: $disk_reason" >&2
    DISK_FAILED=1
    return 0
  fi
  for disk_i in "${!disk_candidates[@]}"; do
    disk_id=${disk_candidates[disk_i]}
    disk_job=$disk_real/$disk_id
    # A process may name the tmp under the jobs root as resolved or as named.
    tmp_live "$disk_job/tmp" "$disk_root/$disk_id/tmp" && continue
    disk_who="${DISK_TASKS[$disk_id]}'s ${DISK_ROLES[$disk_id]} $disk_id"
    if [[ -n $disk_dry ]]; then
      if ! disk_own_dir "$disk_job" || ! disk_own_dir "$disk_job/tmp"; then continue; fi
      disk_kb=$(disk_du "$disk_job/tmp")
      echo "would clear the job tmp of $disk_who ($(tmp_size "$disk_kb"); ${disk_whys[disk_i]})"
      continue
    fi
    disk_rc=0
    disk_clear_job_tmp "$disk_job" "${disk_whys[disk_i]}" "$disk_who" || disk_rc=$?
    case $disk_rc in
      0)
        echo "$DISK_LINE"
        DISK_CLEARED=$((DISK_CLEARED + 1)) DISK_CLEARED_KB=$((DISK_CLEARED_KB + DISK_KB))
        ;;
      1) DISK_FAILED=1 ;;
    esac
  done
}

# Today's totals from the record of the last run, all zero when it is missing or of an earlier
# local date: sets disk_today_count, disk_today_kb and disk_last_at (empty with no record).
disk_today() {
  local disk_state disk_dir disk_record_file disk_fields disk_day
  disk_paths
  disk_today_count=0 disk_today_kb=0 disk_last_at=''
  disk_fields=$(jq -r 'select(.schema == "team-disk/1") | "\(.at) \(.jobs.cleared_today.count // 0) \(.jobs.cleared_today.kb // 0)"' \
    "$disk_record_file" 2>/dev/null) || return 0
  [[ -n $disk_fields ]] || return 0
  read -r disk_last_at disk_today_count disk_today_kb <<<"$disk_fields"
  disk_day=$(date -d "$disk_last_at" +%F 2>/dev/null) || disk_day=''
  if [[ $disk_day != "$(date +%F)" ]]; then disk_today_count=0 disk_today_kb=0; fi
}

# Write the record of this run, whole through a temporary file and a rename.
disk_write_record() {
  local disk_state disk_dir disk_record_file disk_today_count disk_today_kb disk_last_at disk_new
  disk_paths
  disk_today
  disk_new=$disk_record_file.new.$$
  if ! {
    mkdir -p "$disk_dir" &&
      jq -n --arg at "$(date -u +%FT%TZ)" --argjson ok "$([[ -z $DISK_FAILED ]] && echo true || echo false)" \
        --argjson count $((disk_today_count + DISK_CLEARED)) --argjson kb $((disk_today_kb + DISK_CLEARED_KB)) \
        '{schema: "team-disk/1", at: $at, ok: $ok,
          go: {path: null, kb: null, cap_kb: null, trimmed_today: null},
          jobs: {cleared_today: {count: $count, kb: $kb}}}' >"$disk_new" &&
      mv -f -- "$disk_new" "$disk_record_file"
  } 2>/dev/null; then
    rm -f -- "$disk_new"
    echo "${0##*/}: could not write $disk_record_file" >&2
    DISK_FAILED=1
  fi
}

# The reading, read only: disk_status <usage> [--json]
disk_status() {
  local disk_usage=$1 disk_json='' disk_today_count disk_today_kb disk_last_at disk_noun
  shift
  case $* in
    '') ;;
    --json) disk_json=1 ;;
    *) usage_error "$disk_usage" ;;
  esac
  disk_today
  if [[ -n $disk_json ]]; then
    jq -n --argjson count "$disk_today_count" --argjson kb "$disk_today_kb" --arg last "$disk_last_at" \
      '{schema: "team-disk-status/1",
        go: {path: null, kb: null, cap_kb: null, over_cap: null, trimmed_today: null},
        jobs: {cleared_today: {count: $count, kb: $kb}},
        last_run: (if $last == "" then null else $last end)}'
    return 0
  fi
  disk_noun='job tmps'
  ((disk_today_count != 1)) || disk_noun='job tmp'
  echo "$disk_today_count $disk_noun cleared today ($(tmp_size "$disk_today_kb"))"
}

# The run: disk_main [--dry-run | status [--json]]
disk_main() {
  local disk_usage="usage: team-janitor disk [--dry-run] | team-janitor disk status [--json]" disk_arg disk_dry=''
  local disk_state disk_dir disk_record_file disk_lock disk_now disk_idle_minutes
  if [[ ${1:-} == status ]]; then
    disk_status "$disk_usage" "${@:2}"
    exit 0
  fi
  for disk_arg in "$@"; do
    case $disk_arg in
      --dry-run) disk_dry=1 ;;
      *) usage_error "$disk_usage" ;;
    esac
  done
  disk_idle_minutes=${TEAM_DISK_JOB_IDLE_MINUTES:-1440}
  [[ $disk_idle_minutes =~ ^[0-9]+$ ]] ||
    die "TEAM_DISK_JOB_IDLE_MINUTES is '$disk_idle_minutes', not a whole number of minutes"
  disk_now=$(date +%s)
  disk_paths

  # One run at a time; a dry run only reads, so it takes no lock and writes none.
  if [[ -z $disk_dry ]]; then
    mkdir -p "$disk_state" || die "could not make $disk_state"
    exec {disk_lock}>"$disk_state/disk.lock" || die "could not open $disk_state/disk.lock"
    if ! flock -n "$disk_lock"; then
      echo "another team-janitor disk is running; skipped"
      exit 0
    fi
  fi

  TMP_WORK=$(team_mktemp -d)
  disk_jobs
  [[ -n $disk_dry ]] || disk_write_record
  [[ -z $DISK_FAILED ]] || exit 1
  exit 0
}
