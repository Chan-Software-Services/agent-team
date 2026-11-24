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
# The Go part holds Go's build cache (TEAM_GO_CACHE, else go env GOCACHE, else Go's default) to
# its cap: once it passes 10 GiB, a run removes its least recently used entries (<hash>-a and
# <hash>-d under its two-hex directories) down to 8 GiB, never one used in the last 2 hours, and
# only in a directory whose README is Go's.
# It reuses tmp.sh's process reader (tmp_read_processes, tmp_live) and its sizes and ages
# (tmp_size, tmp_age), never a copy of them.
# Test seams: TEAM_DISK_JOB_IDLE_MINUTES for the 24 hours (1440) a done or failed session must
# have been unchanged; TEAM_GO_CACHE for the cache's path, TEAM_GO_CACHE_CAP_KB for its cap
# (10485760, 10 GiB; the trim goes down to 80% of it) and TEAM_GO_CACHE_KEEP_MINUTES for the 2
# hours (120) an entry used since is kept.
# shellcheck shell=bash

# Set when the run ends with exit 1.
DISK_FAILED=''
# The run's totals: the job tmps cleared and their kilobytes.
DISK_CLEARED=0 DISK_CLEARED_KB=0
# The size, in kilobytes, of the last tmp disk_clear_job_tmp cleared, and its line.
DISK_KB=0 DISK_LINE=''
# The Go build cache's path and size after the run (empty with none), the entries the run trimmed
# and their kilobytes, and the local date the over-cap line was last said (empty if never).
DISK_GO_PATH='' DISK_GO_KB='' DISK_TRIMMED=0 DISK_TRIMMED_KB=0 DISK_GO_SAID=''
# The first line of Go's README, by which a directory is known as its build cache.
DISK_GO_README='This directory holds cached build artifacts from the Go build system.'

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

# The Go cap and keep window, checked whole numbers: sets disk_go_cap (kilobytes) and
# disk_go_keep (minutes).
disk_go_settings() {
  disk_go_cap=${TEAM_GO_CACHE_CAP_KB:-10485760}
  [[ $disk_go_cap =~ ^[0-9]+$ ]] ||
    die "TEAM_GO_CACHE_CAP_KB is '$disk_go_cap', not a whole number of kilobytes"
  disk_go_keep=${TEAM_GO_CACHE_KEEP_MINUTES:-120}
  [[ $disk_go_keep =~ ^[0-9]+$ ]] ||
    die "TEAM_GO_CACHE_KEEP_MINUTES is '$disk_go_keep', not a whole number of minutes"
}

# Where Go keeps its build cache: TEAM_GO_CACHE when set, else go env GOCACHE (given 20 s) when go
# is on the PATH and answers, else Go's own default, GOCACHE from the environment or the user
# cache directory's go-build. Sets disk_go to the cache's real path, or leaves it empty and sets
# disk_go_none to why there is none: GOCACHE off or empty, no directory there, or a directory
# that holds no Go README.
disk_go_locate() {
  local disk_raw=''
  disk_go='' disk_go_none=''
  if [[ -n ${TEAM_GO_CACHE+set} ]]; then
    disk_raw=$TEAM_GO_CACHE
  elif command -v go >/dev/null 2>&1 && disk_raw=$(bounded 20 go env GOCACHE 2>/dev/null); then
    :
  elif [[ -n ${GOCACHE:-} ]]; then
    disk_raw=$GOCACHE
  elif [[ ${TEAM_KERNEL:-$(uname -s)} == Darwin ]]; then
    disk_raw=$HOME/Library/Caches/go-build
  else
    disk_raw=${XDG_CACHE_HOME:-$HOME/.cache}/go-build
  fi
  if [[ -z $disk_raw || $disk_raw == off ]]; then
    disk_go_none='no Go build cache (GOCACHE is off)'
    return 0
  fi
  if [[ ! -d $disk_raw ]] || ! disk_go=$(realpath -- "$disk_raw" 2>/dev/null); then
    disk_go='' disk_go_none="no Go build cache at $disk_raw"
    return 0
  fi
  if ! disk_own_dir "$disk_go" || ! disk_go_readme "$disk_go"; then
    disk_go_none="no Go build cache at $disk_go (no Go README)"
    disk_go_bad=$disk_go disk_go=''
  fi
}

# Whether <dir>'s README, a regular file and never a link, begins with Go's first line.
disk_go_readme() {
  local disk_first=''
  [[ -f $1/README && ! -L $1/README ]] || return 1
  IFS= read -r disk_first <"$1/README" 2>/dev/null || [[ -n $disk_first ]] || return 1
  [[ $disk_first == "$DISK_GO_README" ]]
}

# The Go part: trim the Go build cache to 80% of its cap once it is over the cap, the least
# recently used entries first, never one used within the keep window, or on a dry run say it
# would.
disk_go_trim() {
  local disk_go disk_go_none disk_go_bad='' disk_kb disk_target disk_cutoff disk_summary
  local disk_n disk_got disk_last disk_after disk_since='' disk_type disk_entry disk_err disk_today_day disk_line
  disk_go_locate
  if [[ -n $disk_go_bad ]]; then
    echo "${0##*/}: $disk_go_bad is not a Go build cache (no Go README); not trimmed" >&2
    DISK_FAILED=1
    return 0
  fi
  [[ -n $disk_go ]] || return 0
  DISK_GO_PATH=$disk_go
  disk_kb=$(disk_du "$disk_go")
  DISK_GO_KB=$disk_kb
  ((disk_kb > disk_go_cap)) || return 0

  disk_target=$((disk_go_cap * 80 / 100))
  disk_cutoff=$((disk_now - disk_go_keep * 60))
  # The entries, a real file or directory named <hex>-a or <hex>-d directly in a real two-hex
  # directory (find follows no link, and the names hold no line break), oldest first; then the
  # oldest of those used before the cutoff until enough kilobytes are picked, a directory measured
  # with du. The summary is the count, the kilobytes and the newest pick's mtime.
  if ! disk_summary=$(cd "$disk_go" &&
    find . -mindepth 2 -maxdepth 2 -regextype posix-extended -regex '\./[0-9a-f]{2}/[0-9a-f]+-[ad]' \
      \( -type f -o -type d \) -printf '%T@ %y %k %P\n' 2>"$TMP_WORK/go-find.err" |
    LC_ALL=C sort -n -k 1,1 |
    awk -v cutoff="$disk_cutoff" -v need=$((disk_kb - disk_target)) -v picked="$TMP_WORK/go-picked" '
      stop || $1 + 0 > cutoff { stop = 1; next }
      {
        kb = $3 + 0
        if ($2 == "d") { cmd = "du -sk -- " $4; if ((cmd | getline line) > 0) { split(line, f, " "); kb = f[1] + 0 }; close(cmd) }
        print $2 " " $4 > picked
        n++; got += kb; last = $1
        if (got >= need) stop = 1
      }
      END { printf "%d %d %d\n", n, got, last }'); then
    echo "${0##*/}: could not list the Go build cache $disk_go" >&2
    DISK_FAILED=1
    return 0
  fi
  if [[ -s $TMP_WORK/go-find.err ]]; then
    echo "${0##*/}: could not list all of the Go build cache $disk_go: $(tmp_last_line "$TMP_WORK/go-find.err")" >&2
    DISK_FAILED=1
  fi
  read -r disk_n disk_got disk_last <<<"$disk_summary"
  if ((disk_n > 0)); then disk_since=$(date -u -d "@$disk_last" +%FT%H:%MZ); fi

  if [[ -n $disk_dry ]]; then
    disk_after=$((disk_kb - disk_got))
    ((disk_n == 0)) ||
      echo "would trim the Go build cache $disk_go from $(tmp_size "$disk_kb") to $(tmp_size "$disk_after"): $disk_n entries unused since $disk_since"
  elif ((disk_n > 0)); then
    disk_err=$TMP_WORK/go-rm.err
    : >"$disk_err"
    # Checked again just before the removal, so nothing is reached through a link put in its place.
    if ! disk_own_dir "$disk_go"; then
      echo "${0##*/}: $disk_go is no longer a directory of this user's; not trimmed" >&2
      DISK_FAILED=1
      return 0
    fi
    (
      cd "$disk_go" || exit 1
      awk '$1 == "f" { print $2 }' "$TMP_WORK/go-picked" | tr '\n' '\0' | xargs -0 -r rm -f -- 2>>"$disk_err"
      while read -r disk_type disk_entry; do
        [[ $disk_type == d && $(stat -c %F -- "$disk_entry" 2>/dev/null) == directory ]] || continue
        chmod -R u+rwX -- "$disk_entry" 2>/dev/null || true
        rm -rf --one-file-system -- "$disk_entry" 2>>"$disk_err" || true
      done <"$TMP_WORK/go-picked"
    ) || echo "could not enter $disk_go" >>"$disk_err"
    if [[ -s $disk_err ]]; then
      echo "${0##*/}: could not trim the Go build cache $disk_go: $(tmp_last_line "$disk_err")" >&2
      DISK_FAILED=1
    fi
    disk_after=$(disk_du "$disk_go")
    DISK_GO_KB=$disk_after
    DISK_TRIMMED=$disk_n
    ((disk_kb <= disk_after)) || DISK_TRIMMED_KB=$((disk_kb - disk_after))
    disk_line="trimmed the Go build cache $disk_go from $(tmp_size "$disk_kb") to $(tmp_size "$disk_after"): $disk_n entries unused since $disk_since"
    echo "$disk_line"
    disk_record "$disk_line"
  else
    disk_after=$disk_kb
  fi

  # What is left over the cap was used within the keep window: said once a local day.
  ((disk_after > disk_go_cap)) || return 0
  disk_today_day=$(date +%F)
  [[ $DISK_GO_SAID != "$disk_today_day" ]] || return 0
  disk_line="the Go build cache $disk_go holds $(tmp_size "$disk_after"), over its $(tmp_size "$disk_go_cap") cap, the rest used in the last $(tmp_age $((disk_go_keep * 60))); kept"
  echo "$disk_line"
  [[ -n $disk_dry ]] && return 0
  disk_record "$disk_line"
  DISK_GO_SAID=$disk_today_day
}

# Today's totals from the record of the last run, all zero when it is missing or of an earlier
# local date: sets disk_today_count and disk_today_kb (the job tmps cleared), disk_today_entries
# and disk_today_trimmed_kb (the Go entries trimmed), disk_last_at (empty with no record) and
# DISK_GO_SAID (the local date the over-cap line was last said, empty if never).
disk_today() {
  local disk_state disk_dir disk_record_file disk_fields disk_day
  disk_paths
  disk_today_count=0 disk_today_kb=0 disk_today_entries=0 disk_today_trimmed_kb=0 disk_last_at='' DISK_GO_SAID=''
  disk_fields=$(jq -r 'select(.schema == "team-disk/1") | [.at, (.jobs.cleared_today.count // 0),
      (.jobs.cleared_today.kb // 0), (.go.trimmed_today.entries // 0), (.go.trimmed_today.kb // 0),
      (.go.over_cap_said // "-" | strings)] | map(tostring) | join(" ")' "$disk_record_file" 2>/dev/null) || return 0
  [[ -n $disk_fields ]] || return 0
  read -r disk_last_at disk_today_count disk_today_kb disk_today_entries disk_today_trimmed_kb DISK_GO_SAID <<<"$disk_fields"
  [[ $DISK_GO_SAID != - ]] || DISK_GO_SAID=''
  disk_day=$(date -d "$disk_last_at" +%F 2>/dev/null) || disk_day=''
  if [[ $disk_day != "$(date +%F)" ]]; then
    disk_today_count=0 disk_today_kb=0 disk_today_entries=0 disk_today_trimmed_kb=0
  fi
}

# Write the record of this run, whole through a temporary file and a rename.
disk_write_record() {
  local disk_state disk_dir disk_record_file disk_today_count disk_today_kb disk_today_entries
  local disk_today_trimmed_kb disk_last_at disk_new disk_said=$DISK_GO_SAID
  disk_paths
  # The day the over-cap line was said is this run's when it said it, else the last record's.
  disk_today
  [[ -z $disk_said ]] || DISK_GO_SAID=$disk_said
  disk_new=$disk_record_file.new.$$
  if ! {
    mkdir -p "$disk_dir" &&
      jq -n --arg at "$(date -u +%FT%TZ)" --argjson ok "$([[ -z $DISK_FAILED ]] && echo true || echo false)" \
        --argjson count $((disk_today_count + DISK_CLEARED)) --argjson kb $((disk_today_kb + DISK_CLEARED_KB)) \
        --arg go "$DISK_GO_PATH" --arg go_kb "$DISK_GO_KB" --argjson cap "$disk_go_cap" \
        --argjson entries $((disk_today_entries + DISK_TRIMMED)) --argjson trimmed $((disk_today_trimmed_kb + DISK_TRIMMED_KB)) \
        --arg said "$DISK_GO_SAID" \
        '{schema: "team-disk/1", at: $at, ok: $ok,
          go: {path: (if $go == "" then null else $go end), kb: (if $go_kb == "" then null else ($go_kb | tonumber) end),
            cap_kb: $cap, trimmed_today: {entries: $entries, kb: $trimmed},
            over_cap_said: (if $said == "" then null else $said end)},
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
  local disk_usage=$1 disk_json='' disk_today_count disk_today_kb disk_today_entries disk_today_trimmed_kb
  local disk_last_at disk_noun disk_go_cap disk_go_keep disk_go disk_go_none disk_go_bad='' disk_kb='' disk_go_part
  shift
  case $* in
    '') ;;
    --json) disk_json=1 ;;
    *) usage_error "$disk_usage" ;;
  esac
  disk_go_settings
  disk_go_locate
  [[ -z $disk_go ]] || disk_kb=$(disk_du "$disk_go")
  disk_today
  if [[ -n $disk_json ]]; then
    jq -n --argjson count "$disk_today_count" --argjson kb "$disk_today_kb" --arg last "$disk_last_at" \
      --arg go "$disk_go" --arg go_kb "$disk_kb" --argjson cap "$disk_go_cap" --arg none "$disk_go_none" \
      --argjson entries "$disk_today_entries" --argjson trimmed "$disk_today_trimmed_kb" \
      '{schema: "team-disk-status/1",
        go: {path: (if $go == "" then null else $go end), kb: (if $go_kb == "" then null else ($go_kb | tonumber) end),
          cap_kb: $cap, over_cap: ($go_kb != "" and ($go_kb | tonumber) > $cap),
          trimmed_today: {entries: $entries, kb: $trimmed}, none: (if $none == "" then null else $none end)},
        jobs: {cleared_today: {count: $count, kb: $kb}},
        last_run: (if $last == "" then null else $last end)}'
    return 0
  fi
  if [[ -n $disk_go ]]; then
    disk_go_part="Go build cache $(tmp_size "$disk_kb") of its $(tmp_size "$disk_go_cap") cap at $disk_go"
  else
    disk_go_part=$disk_go_none
  fi
  disk_noun='job tmps'
  ((disk_today_count != 1)) || disk_noun='job tmp'
  echo "$disk_go_part; $disk_today_count $disk_noun cleared today ($(tmp_size "$disk_today_kb"))"
}

# The run: disk_main [--dry-run | status [--json]]
disk_main() {
  local disk_usage="usage: team-janitor disk [--dry-run] | team-janitor disk status [--json]" disk_arg disk_dry=''
  local disk_state disk_dir disk_record_file disk_lock disk_now disk_idle_minutes disk_go_cap disk_go_keep
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
  disk_go_settings
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
  # The day the over-cap line was last said, so it is said once a day; then the Go part, which
  # runs whatever the job part did.
  local disk_today_count disk_today_kb disk_today_entries disk_today_trimmed_kb disk_last_at
  disk_today
  disk_go_trim
  [[ -n $disk_dry ]] || disk_write_record
  [[ -z $DISK_FAILED ]] || exit 1
  exit 0
}
