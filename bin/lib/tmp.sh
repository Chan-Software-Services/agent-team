# team-janitor tmp: the sweep of the team's stale leftovers in /tmp and /var/tmp, sourced after
# team.sh by team-janitor, whose header is its usage:
#
#   # shellcheck source=bin/lib/tmp.sh
#   source "$TEAM_LIB/tmp.sh"
#
# It provides tmp_main [--dry-run], the whole run, which ends the script with the run's exit code.
# The names it may remove are the lines of bin/lib/tmp-leftovers, read from this checkout.
# Test seams: TEAM_SYSTEM_ROOT stands for / in both roots, as in the library's tool_dirs;
# TEAM_TMP_UID for the uid whose entries are the sweep's to judge (id -u), so a test shows another
# owner's entry left alone; TEAM_TMP_AGE_MINUTES for the minutes an entry must have gone
# unmodified (60).
# shellcheck shell=bash

# The run's scratch, removed when the script ends, and the lists the run fills: the list's makers
# and expressions, and the candidates, each a path, the same path under the root as named before
# it was resolved (on macOS /tmp is a link to /private/tmp, and a process may name either), and
# the last part of its line.
TMP_WORK=''
TMP_MAKERS=() TMP_NAMES=()
TMP_PATHS=() TMP_ALIASES=() TMP_WHYS=()
# Set when the run ends with exit 1.
TMP_FAILED=''

# Read the list into TMP_MAKERS and TMP_NAMES, refusing a line that is not <maker> <expression>.
tmp_read_list() {
  local tmp_list=$TEAM_LIB/tmp-leftovers tmp_line
  [[ -r $tmp_list ]] || die "cannot read the list of leftovers, $tmp_list"
  while IFS= read -r tmp_line || [[ -n $tmp_line ]]; do
    [[ -n $tmp_line && $tmp_line != '#'* ]] || continue
    [[ $tmp_line =~ ^([A-Za-z0-9][A-Za-z0-9_-]*)\ ([^[:space:]]+)$ ]] ||
      die "$tmp_list: '$tmp_line' is not <maker> <expression>"
    TMP_MAKERS+=("${BASH_REMATCH[1]}")
    TMP_NAMES+=("${BASH_REMATCH[2]}")
  done <"$tmp_list"
}

# Whether a rule names the entry <name>: sets tmp_why, the last part of its line, and
# tmp_minutes, the minutes it must have gone unmodified: tmp_named <name>
tmp_named() {
  local tmp_i
  tmp_minutes=${TEAM_TMP_AGE_MINUTES:-60}
  for tmp_i in "${!TMP_NAMES[@]}"; do
    if [[ $1 =~ ^(${TMP_NAMES[tmp_i]})$ ]]; then
      tmp_why=${TMP_MAKERS[tmp_i]}
      return 0
    fi
  done
  return 1
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
# one; <named> is <dir> as named before it was resolved: tmp_scan <dir> <named>
tmp_scan() {
  local tmp_dir=$1 tmp_named_dir=$2 tmp_record tmp_type tmp_owner tmp_modified tmp_name tmp_why tmp_minutes
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
    tmp_named "$tmp_name" || continue
    tmp_removable "$tmp_type" "$tmp_owner" "${tmp_modified%%.*}" "$tmp_minutes" || continue
    TMP_PATHS+=("$tmp_dir/$tmp_name")
    TMP_ALIASES+=("$tmp_named_dir/$tmp_name")
    TMP_WHYS+=("$tmp_minutes $tmp_why")
  done <"$TMP_WORK/entries"
}

# The last line of <file> that has text, or "no reason given".
tmp_last_line() {
  grep . "$1" 2>/dev/null | tail -n 1 | grep . || echo "no reason given"
}

# Write the process text, what this user's processes name, to $TMP_WORK/processes, one name per
# line: each process's working directory, command line and environment, but for this run's own
# process and its children. It fails, saying why on stderr, when they cannot be read.
tmp_read_processes() {
  local tmp_out=$TMP_WORK/processes tmp_self=$$
  if [[ ${TEAM_KERNEL:-$(uname -s)} == Darwin ]]; then
    # lsof prints p<pid>, then fcwd and n<directory>, per process; ps one process per line.
    if ! lsof -a -u "$(id -u)" -d cwd -Fpn 2>"$TMP_WORK/processes.err" |
      awk -v self="$tmp_self" '/^p/ { skip = ($0 == "p" self) } /^n/ && !skip { print substr($0, 2) }' >"$tmp_out"; then
      echo "lsof failed: $(tmp_last_line "$TMP_WORK/processes.err")" >&2
      return 1
    fi
    if ! ps -x -E -ww -o pid=,ppid=,command= 2>"$TMP_WORK/processes.err" |
      awk -v self="$tmp_self" '$1 != self && $2 != self' >>"$tmp_out"; then
      echo "ps failed: $(tmp_last_line "$TMP_WORK/processes.err")" >&2
      return 1
    fi
  else
    local tmp_proc tmp_pid tmp_stat tmp_links=() tmp_files=()
    if [[ ! -r /proc/$tmp_self/cmdline ]]; then
      echo "/proc holds no readable processes" >&2
      return 1
    fi
    for tmp_proc in /proc/[0-9]*; do
      tmp_pid=${tmp_proc#/proc/}
      [[ -O $tmp_proc && $tmp_pid != "$tmp_self" ]] || continue
      # The parent is the second field after the command's name, which may itself hold a ")".
      tmp_stat=''
      { IFS= read -r -d '' tmp_stat <"$tmp_proc/stat" || true; } 2>/dev/null
      tmp_stat=${tmp_stat##*) }
      tmp_stat=${tmp_stat#* }
      [[ ${tmp_stat%% *} != "$tmp_self" ]] || continue
      tmp_links+=("$tmp_proc/cwd")
      tmp_files+=("$tmp_proc/cmdline" "$tmp_proc/environ")
    done
    : >"$tmp_out"
    if ((${#tmp_links[@]})); then
      # A process that ended since is a missing file, which fails neither read.
      readlink -- "${tmp_links[@]}" >>"$tmp_out" 2>/dev/null || true
      # grep ends each file's text with a line break, so no name runs into the next file's.
      if ! { grep -ash '' -- "${tmp_files[@]}" || true; } | tr '\0' '\n' >>"$tmp_out"; then
        echo "the processes' command lines and environments could not be read" >&2
        return 1
      fi
    fi
  fi
  if [[ ! -s $tmp_out ]]; then
    echo "no process of this user could be read" >&2
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

# Remove the candidate <path> unless a process names it or <alias>, or it no longer passes the
# rules, and say so: tmp_remove <path> <alias> <minutes> <why>
tmp_remove() {
  local tmp_path=$1 tmp_minutes=$3 tmp_why=$4 tmp_stat tmp_type tmp_owner tmp_modified tmp_kb tmp_line
  if [[ $1 == "$2" ]]; then tmp_live "$1" && return 0; else tmp_live "$1" "$2" && return 0; fi
  # Each rule again, on the entry as it is now and never through a link.
  tmp_stat=$(stat -c '%F|%u|%Y' -- "$tmp_path" 2>/dev/null) || return 0
  IFS='|' read -r tmp_type tmp_owner tmp_modified <<<"$tmp_stat"
  tmp_removable "$tmp_type" "$tmp_owner" "$tmp_modified" "$tmp_minutes" || return 0
  tmp_kb=$(du -sk -- "$tmp_path" 2>/dev/null) || true
  tmp_kb=${tmp_kb%%[!0-9]*}
  tmp_line="$tmp_path ($(tmp_size "${tmp_kb:-0}"), untouched $(tmp_age $((tmp_now - tmp_modified))); $tmp_why)"
  if [[ -n $tmp_dry ]]; then
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
  echo "removed $tmp_line"
  tmp_record "removed $tmp_line"
}

# The run: tmp_main [--dry-run]
tmp_main() {
  local tmp_usage="usage: team-janitor tmp [--dry-run]" tmp_arg tmp_dry='' tmp_uid tmp_now tmp_machine
  local tmp_state=$HOME/.local/state/agent-team tmp_lock tmp_root tmp_named_root tmp_i tmp_reason
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

  TMP_WORK=$(mktemp -d)
  trap 'rm -rf "$TMP_WORK"' EXIT

  for tmp_named_root in "${TEAM_SYSTEM_ROOT:-}/tmp" "${TEAM_SYSTEM_ROOT:-}/var/tmp"; do
    [[ -d $tmp_named_root ]] || continue
    tmp_root=$(realpath -- "$tmp_named_root") || continue
    tmp_scan "$tmp_root" "$tmp_named_root"
  done

  if ((${#TMP_PATHS[@]})); then
    # Nothing is removed on a guess of what is live.
    tmp_reason=$(tmp_read_processes 2>&1) ||
      die "could not read this user's processes, so nothing was removed: $tmp_reason"
    for tmp_i in "${!TMP_PATHS[@]}"; do
      tmp_remove "${TMP_PATHS[tmp_i]}" "${TMP_ALIASES[tmp_i]}" "${TMP_WHYS[tmp_i]%% *}" "${TMP_WHYS[tmp_i]#* }"
    done
  fi
  [[ -z $TMP_FAILED ]] || exit 1
  exit 0
}
