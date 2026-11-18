# team-janitor tmp: the sweep of the team's stale leftovers in /tmp and /var/tmp, sourced after
# team.sh by team-janitor, whose header is its usage:
#
#   # shellcheck source=bin/lib/tmp.sh
#   source "$TEAM_LIB/tmp.sh"
#
# It provides tmp_main [--dry-run | status [--json]], the whole run, which ends the script with the
# run's exit code.
# The names it may remove are the lines of bin/lib/tmp-leftovers, read from this checkout, a
# task's session tmp and scratch once the ledger says the task is not open, and a gate session's
# tmp a day old; inside a session tmp under /tmp, only the list's. A run's list of its temporary
# paths (team-temp.<pid>.<random>, a line of the list) goes alone, as a regular file whose pid is
# no live process of this user's, never the paths it names.
# After the sweep, a run reads the /tmp root's file system and judges the notice of the tmp source
# (bin/lib/notice.jq, through bin/lib/notices.sh, which team-janitor sources first): wanted while a
# memory file system is at least 50% full, or 45% once it stands, posted to #coordinator, reminded
# every 240 minutes, closed with no post.
# Test seams: TEAM_SYSTEM_ROOT stands for / in both roots, as in the library's tool_dirs;
# TEAM_TMP_UID for the uid whose entries are the sweep's to judge (id -u), so a test shows another
# owner's entry left alone; TEAM_TMP_AGE_MINUTES for the minutes an entry must have gone
# unmodified (60); TEAM_TMP_DF names a file whose one line, "<type> <size bytes> <used bytes>
# <options>", is read in place of findmnt and df.
# shellcheck shell=bash

# The run's scratch, removed when the script ends, and the lists the run fills: the list's makers
# and expressions, and the candidates, each a path, the same path under the root as named before
# it was resolved (on macOS /tmp is a link to /private/tmp, and a process may name either), and
# the last part of its line, and the session tmp it is inside, empty for an entry of a root.
TMP_WORK=''
TMP_MAKERS=() TMP_NAMES=()
TMP_PATHS=() TMP_ALIASES=() TMP_WHYS=() TMP_PARENTS=()
# The session tmps directly under the /tmp root, by name, whose entries are read too; and the
# directories removed (or, on a dry run, that would be), whose entries go with them.
TMP_SESSIONS=() TMP_GONE=()
# The roots, each as resolved and as named, the only paths the process text keeps lines of.
TMP_ROOTS=()
# The ledger's tasks, each "open" or "closed", read at the first stale entry named for a task:
# TMP_LEDGER is empty until then, then "read", or "none" when it could not be read.
declare -gA TMP_TASKS=()
TMP_LEDGER=''
# Set when the run ends with exit 1.
TMP_FAILED=''

# Read the list into TMP_MAKERS and TMP_NAMES, refusing a line that is not <maker> <expression>,
# or whose expression holds a |.
tmp_read_list() {
  local tmp_list=$TEAM_LIB/tmp-leftovers tmp_line
  [[ -r $tmp_list ]] || die "cannot read the list of leftovers, $tmp_list"
  while IFS= read -r tmp_line || [[ -n $tmp_line ]]; do
    [[ -n $tmp_line && $tmp_line != '#'* ]] || continue
    [[ $tmp_line =~ ^([A-Za-z0-9][A-Za-z0-9_-]*)\ ([^[:space:]]+)$ ]] ||
      die "$tmp_list: '$tmp_line' is not <maker> <expression>"
    # An alternation would match past the literal the line begins with.
    [[ $tmp_line != *'|'* ]] || die "$tmp_list: '$tmp_line' holds a |, which would widen the names it removes"
    TMP_MAKERS+=("${BASH_REMATCH[1]}")
    TMP_NAMES+=("${BASH_REMATCH[2]}")
  done <"$tmp_list"
}

# Whether a rule names the entry <name>: sets tmp_why, the last part of its line, tmp_minutes,
# the minutes it must have gone unmodified, and tmp_task, the task whose closing it waits on
# (empty for the list's and the gate's). Inside a session tmp only the list names an entry:
# tmp_named <name> [inside]
tmp_named() {
  local tmp_i
  tmp_minutes=${TEAM_TMP_AGE_MINUTES:-60} tmp_task=''
  for tmp_i in "${!TMP_NAMES[@]}"; do
    if [[ $1 =~ ^(${TMP_NAMES[tmp_i]})$ ]]; then
      tmp_why=${TMP_MAKERS[tmp_i]}
      return 0
    fi
  done
  [[ -z ${2:-} ]] || return 1
  # The task rule: a session tmp, or a worker's scratch named for its task.
  if [[ $1 =~ ^agent-team-T([0-9]+)$ || $1 =~ ^[tT]([0-9]+)[-._]. ]]; then
    tmp_task=T${BASH_REMATCH[1]}
    tmp_why="$tmp_task is closed"
    return 0
  fi
  # The gate rule: a gate session's tmp, a day old.
  if [[ $1 =~ ^agent-team-gate-[A-Za-z0-9-]{8}$ ]]; then
    tmp_minutes=1440
    tmp_why="a gate session's tmp"
    return 0
  fi
  return 1
}

# Whether the ledger knows <task> and it is not open; the ledger is read once, at the first call,
# and when it cannot be read no task is, which the run says once: tmp_task_closed <task>
tmp_task_closed() {
  local tmp_file=$TEAM_HOME/ledger.jsonl tmp_states tmp_id tmp_state
  if [[ -z $TMP_LEDGER ]]; then
    TMP_LEDGER=none
    if [[ -r $tmp_file ]] && tmp_states=$(ledger_jq 'ledger_events | by_task | to_entries[]
        | "\(.key) \(if .value | is_open then "open" else "closed" end)"' -nRr "$tmp_file" 2>/dev/null); then
      TMP_LEDGER='read'
      while read -r tmp_id tmp_state; do
        [[ -z $tmp_id ]] || TMP_TASKS[$tmp_id]=$tmp_state
      done <<<"$tmp_states"
    else
      echo "${0##*/}: could not read the ledger, $tmp_file, so no entry named for a task was removed" >&2
    fi
  fi
  [[ $TMP_LEDGER == read && ${TMP_TASKS[$1]:-} == closed ]]
}

# Whether an entry of <type> (find's %y, or stat's %F), <owner> and <modified> (epoch seconds)
# may be removed after <minutes> unmodified: a real directory or a regular file, this user's, and
# stale: tmp_removable <type> <owner> <modified> <minutes>
tmp_removable() {
  case $1 in
    d | f | directory | 'regular file' | 'regular empty file') ;;
    *) return 1 ;;
  esac
  [[ $2 == "$tmp_uid" ]] || return 1
  ((tmp_now - $3 >= $4 * 60))
}

# Add the candidates directly under <dir>, each entry there that passes every rule but the live
# one; <named> is <dir> as named before it was resolved. With "sessions", the /tmp root's scan, it
# notes each session tmp there, a real directory of this user's, in TMP_SESSIONS; with "inside",
# <dir> is a session tmp, whose entries only the list names:
# tmp_scan <dir> <named> [sessions | inside]
tmp_scan() {
  local tmp_dir=$1 tmp_named_dir=$2 tmp_mode=${3:-} tmp_record tmp_type tmp_owner tmp_modified tmp_name
  local tmp_why tmp_minutes tmp_task tmp_parent=''
  [[ $tmp_mode != inside ]] || tmp_parent=$tmp_dir
  if ! find "$tmp_dir" -mindepth 1 -maxdepth 1 -printf '%y %U %T@ %f\0' 2>"$TMP_WORK/find.err" |
    LC_ALL=C sort -z -t ' ' -k 4 >"$TMP_WORK/entries"; then
    echo "${0##*/}: could not list $tmp_dir: $(tmp_last_line "$TMP_WORK/find.err")" >&2
    TMP_FAILED=1
    return 0
  fi
  while IFS= read -r -d '' tmp_record; do
    # The name is the rest of the record, its blanks kept.
    tmp_type=${tmp_record%% *} tmp_record=${tmp_record#* }
    tmp_owner=${tmp_record%% *} tmp_record=${tmp_record#* }
    tmp_modified=${tmp_record%% *} tmp_name=${tmp_record#* }
    # A name with a line break is no one's the rules know, and the process text is read by line.
    [[ $tmp_name != *$'\n'* ]] || continue
    if [[ $tmp_mode == sessions && $tmp_type == d && $tmp_owner == "$tmp_uid" &&
      $tmp_name =~ ^agent-team-(T[0-9]+|gate-[A-Za-z0-9-]{8})$ ]]; then
      TMP_SESSIONS+=("$tmp_name")
    fi
    tmp_named "$tmp_name" ${tmp_parent:+inside} || continue
    tmp_removable "$tmp_type" "$tmp_owner" "${tmp_modified%%.*}" "$tmp_minutes" || continue
    if [[ -n $tmp_task ]]; then tmp_task_closed "$tmp_task" || continue; fi
    TMP_PATHS+=("$tmp_dir/$tmp_name")
    TMP_ALIASES+=("$tmp_named_dir/$tmp_name")
    TMP_WHYS+=("$tmp_minutes $tmp_why")
    TMP_PARENTS+=("$tmp_parent")
  done <"$TMP_WORK/entries"
}

# The last line of <file> that has text, or "no reason given".
tmp_last_line() {
  grep . "$1" 2>/dev/null | tail -n 1 | grep . || echo "no reason given"
}

# The lines of stdin that name a path under one of TMP_ROOTS, so no other text of a process (an
# environment's tokens) is kept; exits 97 when stdin held no line at all.
tmp_rooted() {
  TMP_ROOTS_TEXT=$(printf '%s\n' "${TMP_ROOTS[@]}") LC_ALL=C awk '
    BEGIN { n = split(ENVIRON["TMP_ROOTS_TEXT"], roots, "\n") }
    { read = 1; for (i = 1; i <= n; i++) if (roots[i] != "" && index($0, roots[i] "/")) { print; next } }
    END { exit read ? 0 : 97 }'
}

# Write the process text, what this user's processes name under a root, to $TMP_WORK/processes,
# one name per line: each process's working directory, open files, command line and environment,
# but for this run's own process and its children, and only the lines that name a path under a
# root; and the pids of this user's processes, this run's own among them, to $TMP_WORK/pids, one per
# line. It fails, saying why on stderr, when they cannot be read.
tmp_read_processes() {
  local tmp_out=$TMP_WORK/processes tmp_failed=$TMP_WORK/processes.failed tmp_self=$$ tmp_rc=0
  local tmp_pids=$TMP_WORK/pids
  if [[ ${TEAM_KERNEL:-$(uname -s)} == Darwin ]]; then
    # lsof prints p<pid>, then f<descriptor> and n<name>, per open file, the working directory
    # among them; ps one process per line, its command line then its whole environment, which is
    # cut at the start of each " <NAME>=" word, so the root filter keeps one variable, never the
    # line's other values.
    {
      lsof -u "$(id -u)" -Fpn 2>"$TMP_WORK/processes.err" |
        awk -v self="$tmp_self" '/^p/ { skip = ($0 == "p" self) } /^n/ && !skip { print substr($0, 2) }' ||
        echo "lsof failed: $(tmp_last_line "$TMP_WORK/processes.err")" >"$tmp_failed"
      ps -x -E -ww -o pid=,ppid=,command= 2>"$TMP_WORK/processes.err" |
        awk -v self="$tmp_self" -v pids="$tmp_pids" '{ print $1 >pids } $1 != self && $2 != self {
          line = $0
          while (match(substr(line, 2), / [A-Za-z_][A-Za-z0-9_]*=/)) {
            print substr(line, 1, RSTART)
            line = substr(line, RSTART + 2)
          }
          print line
        }' ||
        echo "ps failed: $(tmp_last_line "$TMP_WORK/processes.err")" >"$tmp_failed"
    } | tmp_rooted >"$tmp_out" || tmp_rc=$?
  else
    local tmp_proc tmp_pid tmp_stat tmp_links=() tmp_files=() tmp_live_pids=()
    if [[ ! -r /proc/$tmp_self/cmdline ]]; then
      echo "/proc holds no readable processes" >&2
      return 1
    fi
    for tmp_proc in /proc/[0-9]*; do
      tmp_pid=${tmp_proc#/proc/}
      [[ -O $tmp_proc ]] || continue
      tmp_live_pids+=("$tmp_pid")
      [[ $tmp_pid != "$tmp_self" ]] || continue
      # The parent is the second field after the command's name, which may itself hold a ")".
      tmp_stat=''
      { IFS= read -r -d '' tmp_stat <"$tmp_proc/stat" || true; } 2>/dev/null
      tmp_stat=${tmp_stat##*) }
      tmp_stat=${tmp_stat#* }
      [[ ${tmp_stat%% *} != "$tmp_self" ]] || continue
      # Its working directory and each file it holds open, a lock or a pid file say.
      tmp_links+=("$tmp_proc/cwd" "$tmp_proc"/fd/*)
      tmp_files+=("$tmp_proc/cmdline" "$tmp_proc/environ")
    done
    printf '%s\n' "${tmp_live_pids[@]}" >"$tmp_pids"
    {
      if ((${#tmp_links[@]})); then
        # A process or file that ended since is a missing link, which fails no read.
        printf '%s\0' "${tmp_links[@]}" | xargs -0 readlink -- 2>/dev/null || true
        # grep ends each file's text with a line break, so no name runs into the next file's.
        { grep -ash '' -- "${tmp_files[@]}" || true; } | tr '\0' '\n' ||
          echo "the processes' command lines and environments could not be read" >"$tmp_failed"
      fi
    } | tmp_rooted >"$tmp_out" || tmp_rc=$?
  fi
  if [[ -s $tmp_failed ]]; then
    cat "$tmp_failed" >&2
    return 1
  fi
  if ((tmp_rc == 97)); then
    echo "no process of this user could be read" >&2
    return 1
  fi
  if ((tmp_rc)); then
    echo "the processes could not be read" >&2
    return 1
  fi
}

# Whether a process names one of <path>...: the path, then a /, a space, a : or the end of the
# name: tmp_live <path>...
tmp_live() {
  local tmp_path tmp_line tmp_after
  for tmp_path in "$@"; do
    while IFS= read -r tmp_line; do
      while [[ $tmp_line == *"$tmp_path"* ]]; do
        tmp_line=${tmp_line#*"$tmp_path"}
        tmp_after=${tmp_line:0:1}
        if [[ -z $tmp_after || $tmp_after == / || $tmp_after == ' ' || $tmp_after == : ]]; then return 0; fi
      done
    done < <(grep -aF -- "$tmp_path" "$TMP_WORK/processes" || true)
  done
  return 1
}

# <kilobytes> as a size: in MB below 1024 MB, in GiB with one decimal from there.
tmp_size() {
  local tmp_mb=$((($1 + 512) / 1024)) tmp_tenths
  if ((tmp_mb < 1024)); then
    echo "$tmp_mb MB"
  else
    tmp_tenths=$((($1 * 10 + 524288) / 1048576))
    echo "$((tmp_tenths / 10)).$((tmp_tenths % 10)) GiB"
  fi
}

# <seconds> as an age: in minutes below 120, in whole hours from there.
tmp_age() {
  local tmp_min=$(($1 / 60))
  if ((tmp_min < 120)); then echo "$tmp_min min"; else echo "$((tmp_min / 60)) h"; fi
}

# Append a removal's <line> to the day's file, made with its title for the day's first.
tmp_record() {
  local tmp_dir=$HOME/.local/state/agent-team/janitor tmp_day tmp_file
  tmp_day=$(date +%F)
  tmp_file=$tmp_dir/tmp-$tmp_day.md
  if ! {
    mkdir -p "$tmp_dir" &&
      { [[ -s $tmp_file ]] || printf '# Temp files removed on %s, %s\n\n' "$tmp_machine" "$tmp_day" >"$tmp_file"; } &&
      printf -- '- %s %s\n' "$(date +%H:%M)" "$1" >>"$tmp_file"
  } 2>/dev/null; then
    echo "${0##*/}: could not write $tmp_file" >&2
    TMP_FAILED=1
  fi
}

# Whether <path>, of <type> (stat's %F), is a run's list of its temporary paths to keep: a name of
# bin/lib/temp-files.sh's, team-temp.<pid>.<random>, that is not a regular file, or whose pid is not
# a number as $$ is, or is one of this user's processes. A dead run's list is removed alone, never
# the paths it names, since a list in a shared TMPDIR is anyone's to write: tmp_list_kept <path> <type>
tmp_list_kept() {
  local tmp_name=${1##*/} tmp_pid
  [[ $tmp_name == team-temp.* ]] || return 1
  [[ $2 == 'regular file' || $2 == 'regular empty file' ]] || return 0
  tmp_pid=${tmp_name#team-temp.}
  tmp_pid=${tmp_pid%%.*}
  [[ $tmp_pid =~ ^[1-9][0-9]*$ && -s $TMP_WORK/pids ]] || return 0
  grep -Fxq -- "$tmp_pid" "$TMP_WORK/pids"
}

# Remove the candidate <path> unless a process names it or <alias>, or it no longer passes the
# rules, or it is a run's list to keep, or it went with a directory removed before it, and say so;
# <parent> is the session tmp it is inside, empty for an entry of a root:
# tmp_remove <path> <alias> <minutes> <why> <parent>
tmp_remove() {
  local tmp_path=$1 tmp_minutes=$3 tmp_why=$4 tmp_parent=$5 tmp_stat tmp_type tmp_owner tmp_modified tmp_kb
  local tmp_line tmp_gone
  for tmp_gone in "${TMP_GONE[@]}"; do
    [[ $tmp_path != "$tmp_gone"/* ]] || return 0
  done
  if [[ $1 == "$2" ]]; then tmp_live "$1" && return 0; else tmp_live "$1" "$2" && return 0; fi
  # The session tmp it is inside is still a real directory of this user's, so nothing is reached
  # through a link put in its place.
  if [[ -n $tmp_parent && $(stat -c '%F|%u' -- "$tmp_parent" 2>/dev/null) != "directory|$tmp_uid" ]]; then
    return 0
  fi
  # Each rule again, on the entry as it is now and never through a link.
  tmp_stat=$(stat -c '%F|%u|%Y' -- "$tmp_path" 2>/dev/null) || return 0
  IFS='|' read -r tmp_type tmp_owner tmp_modified <<<"$tmp_stat"
  tmp_removable "$tmp_type" "$tmp_owner" "$tmp_modified" "$tmp_minutes" || return 0
  ! tmp_list_kept "$tmp_path" "$tmp_type" || return 0
  tmp_kb=$(du -sk -- "$tmp_path" 2>/dev/null) || true
  tmp_kb=${tmp_kb%%[!0-9]*}
  tmp_line="$tmp_path ($(tmp_size "${tmp_kb:-0}"), untouched $(tmp_age $((tmp_now - tmp_modified))); $tmp_why)"
  if [[ -n $tmp_dry ]]; then
    [[ $tmp_type != directory ]] || TMP_GONE+=("$tmp_path")
    echo "would remove $tmp_line"
    return 0
  fi
  if [[ $tmp_type == directory ]]; then
    # A read-only tree, a Go module cache say, is made writable first; chmod changes no link.
    chmod -R u+rwX -- "$tmp_path" 2>/dev/null || true
    rm -rf --one-file-system -- "$tmp_path" 2>"$TMP_WORK/rm.err" || true
  else
    rm -f -- "$tmp_path" 2>"$TMP_WORK/rm.err" || true
  fi
  if [[ -e $tmp_path || -L $tmp_path ]]; then
    echo "${0##*/}: could not remove $tmp_path: $(tmp_last_line "$TMP_WORK/rm.err")" >&2
    TMP_FAILED=1
    return 0
  fi
  [[ $tmp_type != directory ]] || TMP_GONE+=("$tmp_path")
  echo "removed $tmp_line"
  tmp_record "removed $tmp_line"
}

# The share of a memory /tmp past which the notice is wanted, and the share it stands at once
# posted, so a reading that hovers at the threshold posts once; the minutes between reminders; the
# most one Discord post may take, as team-timers posts.
TMP_WARN_PERCENT=50
TMP_KEEP_PERCENT=45
TMP_REMIND_MINUTES=240
TMP_POST_TIMEOUT=20
# The reading of the /tmp root's file system, which tmp_reading sets: the root as resolved, its
# type, size and used bytes, mount options, used share in whole percent (rounded down), whether it
# is judged (a tmpfs, never on macOS) and whether its options hold usrquota (1 or empty).
TMP_FS_ROOT='' TMP_FS_TYPE='' TMP_FS_SIZE='' TMP_FS_USED='' TMP_FS_OPTIONS='' TMP_FS_PERCENT=''
TMP_FS_JUDGED='' TMP_FS_QUOTA='' TMP_FS_ERROR=''

# Read the /tmp root's file system into the TMP_FS_ variables; fails with the reason in
# TMP_FS_ERROR, with exit 2 when there is no /tmp root.
tmp_reading() {
  local tmp_named_root=${TEAM_SYSTEM_ROOT:-}/tmp tmp_kernel=${TEAM_KERNEL:-$(uname -s)} tmp_df
  if ! TMP_FS_ROOT=$(realpath -e -- "$tmp_named_root" 2>/dev/null) || [[ ! -d $TMP_FS_ROOT ]]; then
    TMP_FS_ERROR="$tmp_named_root does not exist"
    return 2
  fi
  if [[ -n ${TEAM_TMP_DF:-} ]]; then
    read -r TMP_FS_TYPE TMP_FS_SIZE TMP_FS_USED TMP_FS_OPTIONS <"$TEAM_TMP_DF" 2>/dev/null || true
  else
    if [[ $tmp_kernel == Darwin ]]; then
      TMP_FS_TYPE=$(stat -f -c %T -- "$TMP_FS_ROOT" 2>/dev/null) || TMP_FS_TYPE=''
      TMP_FS_OPTIONS=''
    elif ! read -r TMP_FS_TYPE TMP_FS_OPTIONS < <(findmnt -n -o FSTYPE,OPTIONS -T "$TMP_FS_ROOT" 2>/dev/null); then
      TMP_FS_ERROR="findmnt could not read the file system of $TMP_FS_ROOT"
      return 1
    fi
    if ! tmp_df=$(df -Pk -- "$TMP_FS_ROOT" 2>/dev/null | awk 'NR == 2 { print $2 * 1024, $3 * 1024 }') ||
      ! read -r TMP_FS_SIZE TMP_FS_USED <<<"$tmp_df"; then
      TMP_FS_ERROR="df could not read the size of $TMP_FS_ROOT"
      return 1
    fi
  fi
  if [[ -z $TMP_FS_TYPE || ! $TMP_FS_SIZE =~ ^[0-9]+$ || ! $TMP_FS_USED =~ ^[0-9]+$ ]] || ((TMP_FS_SIZE == 0)); then
    TMP_FS_ERROR="the file system of $TMP_FS_ROOT gave no type, size and use"
    return 1
  fi
  TMP_FS_PERCENT=$((TMP_FS_USED * 100 / TMP_FS_SIZE))
  TMP_FS_JUDGED='' TMP_FS_QUOTA='' TMP_FS_ERROR=''
  [[ $TMP_FS_TYPE != tmpfs || $tmp_kernel == Darwin ]] || TMP_FS_JUDGED=1
  [[ ,$TMP_FS_OPTIONS, != *,usrquota,* ]] || TMP_FS_QUOTA=1
}

# The reading as its status line, the post's words after "/tmp on <machine>" aside.
tmp_reading_line() {
  if [[ -z $TMP_FS_JUDGED ]]; then
    echo "/tmp is on $TMP_FS_TYPE, not a memory file system, so it is not judged"
    return 0
  fi
  printf '/tmp is %s\n' "$(tmp_fullness)"
}

# "<n>% full (<used> of <size>)", with ", past 50%" when it is: tmp_fullness
tmp_fullness() {
  local tmp_past=''
  ((TMP_FS_PERCENT < TMP_WARN_PERCENT)) || tmp_past=", past $TMP_WARN_PERCENT%"
  echo "$TMP_FS_PERCENT% full ($(tmp_size $((TMP_FS_USED / 1024))) of $(tmp_size $((TMP_FS_SIZE / 1024))))$tmp_past"
}

# The five largest entries of this user's directly under the /tmp root, by du, largest first, one
# "<kilobytes> <name>" per line; an entry du cannot read in full counts what it read.
tmp_largest() {
  { find "$TMP_FS_ROOT" -mindepth 1 -maxdepth 1 -uid "$tmp_uid" -print0 2>/dev/null |
    xargs -0 -r du -sk -x -- 2>/dev/null || true; } |
    awk -F '\t' '$1 ~ /^[0-9]+$/ { n = $2; sub(/.*\//, "", n); print $1 " " n }' | LC_ALL=C sort -k1,1nr -k2 | head -n 5
}

# The day's file of removals, and its count of them: sets tmp_report (empty with none) and
# tmp_removed.
tmp_today() {
  tmp_report=$HOME/.local/state/agent-team/janitor/tmp-$(date +%F).md
  tmp_removed=0
  if [[ -f $tmp_report ]]; then
    tmp_removed=$(grep -c '^- ' "$tmp_report" 2>/dev/null) || tmp_removed=0
  else
    tmp_report=''
  fi
}

# <path> with the home directory as ~.
tmp_short() {
  if [[ $1 == "$HOME"/* ]]; then echo "~${1#"$HOME"}"; else echo "$1"; fi
}

# The reading, the largest entries and the day's removals, read only: tmp_status [--json]
tmp_status() {
  local tmp_usage=$1 tmp_json='' tmp_uid tmp_record tmp_report tmp_removed tmp_largest_lines tmp_kb tmp_name
  shift
  case $* in
    '') ;;
    --json) tmp_json=1 ;;
    *) usage_error "$tmp_usage" ;;
  esac
  tmp_uid=${TEAM_TMP_UID:-$(id -u)}
  tmp_reading || die "could not read the file system of /tmp: $TMP_FS_ERROR"
  tmp_record=$(notices_read 2>/dev/null) || die "$NOTICES is not a team-notices/1 record"
  tmp_largest_lines=$(tmp_largest)
  tmp_today
  if [[ -n $tmp_json ]]; then
    jq -n --arg root "$TMP_FS_ROOT" --arg type "$TMP_FS_TYPE" --argjson judged "$([[ -n $TMP_FS_JUDGED ]] && echo true || echo false)" \
      --argjson size "$TMP_FS_SIZE" --argjson used "$TMP_FS_USED" --argjson percent "$TMP_FS_PERCENT" \
      --argjson quota "$([[ -n $TMP_FS_QUOTA ]] && echo true || echo false)" --argjson record "$tmp_record" \
      --arg largest "$tmp_largest_lines" --argjson removed "$tmp_removed" --arg report "$tmp_report" \
      '{schema: "team-tmp/1", root: $root, type: $type, judged: $judged, size: $size, used: $used,
        percent: $percent, quota: $quota, warning: ($record.notices.tmp != null),
        largest: [$largest | splits("\n") | select(. != "") | capture("^(?<kb>[0-9]+) (?<name>.*)$")
          | {name, bytes: ((.kb | tonumber) * 1024)}],
        removed_today: $removed, report: (if $report == "" then null else $report end)}'
    return 0
  fi
  tmp_reading_line
  while read -r tmp_kb tmp_name; do
    [[ -z $tmp_kb ]] || echo "largest: $tmp_name $(tmp_size "$tmp_kb")"
  done <<<"$tmp_largest_lines"
  if [[ -n $tmp_report ]]; then
    echo "removed today: $tmp_removed ($(tmp_short "$tmp_report"))"
  else
    echo "removed today: 0"
  fi
}

# The warning's post, a reminder's when <still> is given: tmp_post_text [still]
tmp_post_text() {
  local tmp_kb tmp_name tmp_list='' tmp_report tmp_removed tmp_text
  while read -r tmp_kb tmp_name; do
    [[ -z $tmp_kb ]] || tmp_list+="${tmp_list:+, }$tmp_name $(tmp_size "$tmp_kb")"
  done < <(tmp_largest)
  tmp_today
  tmp_text="/tmp on $tmp_machine is ${1:+still }$(tmp_fullness)"
  [[ -z $TMP_FS_QUOTA ]] || tmp_text+="; systemd holds each user to 80% of it"
  tmp_text+=". Largest of yours: ${tmp_list:-none}. \`team-janitor tmp status\` lists them; today's removals: "
  tmp_text+="$(if [[ -n $tmp_report ]]; then tmp_short "$tmp_report"; else echo none; fi)."
  printf '%s\n' "${tmp_text:0:2000}"
}

# Post <text> to #coordinator, mentioning no one; the new message's id in tmp_message (empty when
# Discord gave none), or fails with the reason in tmp_post_error.
tmp_post() {
  local tmp_body tmp_reply
  tmp_message=''
  tmp_body=$(jq -cn --arg content "$1" '{content: $content, allowed_mentions: {parse: []}}')
  if tmp_reply=$(discord_api "channels/$COORDINATOR_CHANNEL/messages" -X POST -H "Content-Type: application/json" \
    --max-time "$TMP_POST_TIMEOUT" -d "$tmp_body" 2>"$TMP_WORK/post.err"); then
    tmp_message=$(jq -r '.id // empty | strings' <<<"$tmp_reply" 2>/dev/null) || tmp_message=''
    return 0
  fi
  tmp_post_error=$(tmp_last_line "$TMP_WORK/post.err")
  return 1
}

# Say each line the notice record's I/O said on stderr (a record set aside), failing the run.
tmp_notices_said() {
  local tmp_line
  while IFS= read -r tmp_line; do
    [[ -z $tmp_line ]] || { echo "${0##*/}: $tmp_line" >&2; TMP_FAILED=1; }
  done <"$TMP_WORK/notices.err"
}

# Judge the tmp notice at this run's reading, and post or remind as it says.
# shellcheck disable=SC2016 # jq's variables
tmp_warn() {
  local tmp_plan tmp_action tmp_text tmp_message tmp_post_error tmp_ok tmp_rc=0
  tmp_reading || tmp_rc=$?
  # With no /tmp root, as the sweep skips it, there is nothing to judge.
  ((tmp_rc != 2)) || return 0
  if ((tmp_rc)); then
    echo "${0##*/}: could not read the file system of /tmp, so its fill was not judged: $TMP_FS_ERROR" >&2
    TMP_FAILED=1
    return 0
  fi
  if ! tmp_plan=$(notices_update notice '
      (.notices.tmp != null) as $stands
      | (if $judged and ($percent >= $warn or ($stands and $percent >= $keep))
         then [{key: "tmp", since: null, text: null, detail: {percent: $percent, size: $size, used: $used}}]
         else [] end) as $wanted
      | notice_plan("tmp"; $wanted; $taken_at; now; $remind)' \
    --argjson judged "$([[ -n $TMP_FS_JUDGED ]] && echo true || echo false)" --argjson percent "$TMP_FS_PERCENT" \
    --argjson size "$TMP_FS_SIZE" --argjson used "$TMP_FS_USED" --argjson warn "$TMP_WARN_PERCENT" \
    --argjson keep "$TMP_KEEP_PERCENT" --argjson remind "$TMP_REMIND_MINUTES" \
    --argjson taken_at "$(notices_taken_at)" 2>"$TMP_WORK/notices.err"); then
    echo "${0##*/}: cannot write $NOTICES: $(tmp_last_line "$TMP_WORK/notices.err")" >&2
    TMP_FAILED=1
    return 0
  fi
  tmp_notices_said
  # One notice, so at most one action: its post, or its reminder.
  tmp_action=$(jq -r '[.actions[] | select(.do == "post" or .do == "remind") | .do][0] // empty' <<<"$tmp_plan")
  [[ -n $tmp_action ]] || return 0
  tmp_text=$(tmp_post_text "$([[ $tmp_action == remind ]] && echo still)")
  if tmp_post "$tmp_text"; then
    tmp_ok=true
    echo "posted to #coordinator (message ${tmp_message:-none}): /tmp is $([[ $tmp_action == remind ]] && echo 'still ')$TMP_FS_PERCENT% full"
  else
    tmp_ok=false
    echo "${0##*/}: the post to #coordinator failed ($tmp_post_error); it is tried again next run" >&2
    TMP_FAILED=1
  fi
  if notices_update notice 'notice_done("tmp"; $action; $ok; $message; $at) | {record: .}' \
    --arg action "$tmp_action" --argjson ok "$tmp_ok" --arg at "$(date -u +%FT%TZ)" \
    --argjson message "$(jq -cn --arg m "$tmp_message" 'if $m == "" then null else $m end')" \
    >/dev/null 2>"$TMP_WORK/notices.err"; then
    tmp_notices_said
  else
    echo "${0##*/}: cannot write $NOTICES: $(tmp_last_line "$TMP_WORK/notices.err")" >&2
    TMP_FAILED=1
  fi
}

# The run: tmp_main [--dry-run | status [--json]]
tmp_main() {
  local tmp_usage="usage: team-janitor tmp [--dry-run] | team-janitor tmp status [--json]" tmp_arg tmp_dry=''
  local tmp_uid tmp_now tmp_machine
  local tmp_state=$HOME/.local/state/agent-team tmp_lock tmp_root tmp_named_root tmp_session tmp_i tmp_reason
  if [[ ${1:-} == status ]]; then
    tmp_status "$tmp_usage" "${@:2}"
    exit 0
  fi
  for tmp_arg in "$@"; do
    case $tmp_arg in
      --dry-run) tmp_dry=1 ;;
      *) usage_error "$tmp_usage" ;;
    esac
  done
  [[ ${TEAM_TMP_AGE_MINUTES:-60} =~ ^[0-9]+$ ]] || die "TEAM_TMP_AGE_MINUTES is '$TEAM_TMP_AGE_MINUTES', not a whole number of minutes"
  tmp_uid=${TEAM_TMP_UID:-$(id -u)}
  tmp_now=$(date +%s)
  tmp_machine=$(machine_name 2>/dev/null || hostname -s 2>/dev/null || echo "this machine")
  tmp_read_list

  # One run at a time; a dry run only reads, so it takes no lock and writes none.
  if [[ -z $tmp_dry ]]; then
    mkdir -p "$tmp_state" || die "could not make $tmp_state"
    exec {tmp_lock}>"$tmp_state/tmp.lock" || die "could not open $tmp_state/tmp.lock"
    if ! flock -n "$tmp_lock"; then
      echo "another team-janitor tmp is running; skipped"
      exit 0
    fi
  fi

  TMP_WORK=$(team_mktemp -d)

  for tmp_named_root in "${TEAM_SYSTEM_ROOT:-}/tmp" "${TEAM_SYSTEM_ROOT:-}/var/tmp"; do
    [[ -d $tmp_named_root ]] || continue
    tmp_root=$(realpath -- "$tmp_named_root") || continue
    TMP_ROOTS+=("$tmp_root" "$tmp_named_root")
    if [[ $tmp_named_root == */var/tmp ]]; then
      tmp_scan "$tmp_root" "$tmp_named_root"
      continue
    fi
    # A session tmp's entries come after it, so one removed whole takes them with it.
    tmp_scan "$tmp_root" "$tmp_named_root" sessions
    for tmp_session in "${TMP_SESSIONS[@]}"; do
      tmp_scan "$tmp_root/$tmp_session" "$tmp_named_root/$tmp_session" inside
    done
  done

  if ((${#TMP_PATHS[@]})); then
    # Nothing is removed on a guess of what is live.
    if tmp_reason=$(tmp_read_processes 2>&1); then
      for tmp_i in "${!TMP_PATHS[@]}"; do
        tmp_remove "${TMP_PATHS[tmp_i]}" "${TMP_ALIASES[tmp_i]}" "${TMP_WHYS[tmp_i]%% *}" "${TMP_WHYS[tmp_i]#* }" \
          "${TMP_PARENTS[tmp_i]}"
      done
    else
      # The warning is still judged.
      echo "${0##*/}: could not read this user's processes, so nothing was removed: $tmp_reason" >&2
      TMP_FAILED=1
    fi
  fi
  # The fill is read after the removals, which may have brought it down; a dry run judges nothing.
  [[ -n $tmp_dry ]] || tmp_warn
  [[ -z $TMP_FAILED ]] || exit 1
  exit 0
}
