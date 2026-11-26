# disk          `team-janitor disk status --json`: what the Go build cache holds against its cap
#               and how many job tmps team-janitor disk cleared today. Passes with the status' line
#               ("Go build cache 3.2 GiB of its 10.0 GiB cap at ~/.cache/go-build; 4 job tmps
#               cleared today (2.1 GiB)", or "no Go build cache (GOCACHE is off)" and the like in
#               the Go part's place); warns when the cache is over its cap, with its fix
#               (team-janitor disk trims it; team-janitor disk status names it), and when the
#               status does not answer, naming its first error; never fails, since the heartbeat's
#               disk step trims the cache and a full disk fails the runs that write to it, not the
#               team.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's

# The status' line, in the words of bin/lib/disk.sh's status, from its JSON, the home directory as ~.
# shellcheck source=bin/lib/tmp.sh
source "$TEAM_LIB/tmp.sh"
# shellcheck source=bin/lib/disk.sh
source "$TEAM_LIB/disk.sh"
disk_line_status=$(TEAM_HOME=$TEAM_HOME "$bin/team-janitor" disk status --json 2>"$err" </dev/null) && disk_line_rc=0 || disk_line_rc=$?
disk_line_schema='' disk_line_path='' disk_line_kb='' disk_line_cap='' disk_line_over='' disk_line_none=''
disk_line_count='' disk_line_cleared=''
if ((disk_line_rc == 0)) &&
  json_vars disk_line_schema='.schema | strings' disk_line_path='.go.path | strings' disk_line_kb='.go.kb | numbers' \
    disk_line_cap='.go.cap_kb | numbers' disk_line_over='.go.over_cap | booleans' disk_line_none='.go.none | strings' \
    disk_line_count='.jobs.cleared_today.count | numbers' disk_line_cleared='.jobs.cleared_today.kb | numbers' \
    <<<"$disk_line_status" 2>/dev/null &&
  [[ $disk_line_schema == team-disk-status/1 && -n $disk_line_cap && -n $disk_line_over ]] &&
  [[ -n $disk_line_count && -n $disk_line_cleared ]] &&
  [[ (-n $disk_line_path && -n $disk_line_kb) || (-z $disk_line_path && -n $disk_line_none) ]]; then
  disk_line_go=$(disk_go_words "$(tilde "$disk_line_path")" "$disk_line_kb" "$disk_line_cap" \
    "${disk_line_none//"$HOME/"/"~/"}")
  disk_line_jobs=$(disk_jobs_words "$disk_line_count" "$disk_line_cleared")
  if [[ $disk_line_over == true ]]; then
    report disk WARN "$disk_line_go, over its cap; $disk_line_jobs" \
      "team-janitor disk trims it; team-janitor disk status names it"
  else
    report disk PASS "$disk_line_go; $disk_line_jobs"
  fi
else
  if ((disk_line_rc == 0)); then
    echo "it printed no team-disk-status/1 reading" >"$err"
  elif ! grep -q . "$err"; then
    echo "it exited $disk_line_rc, naming no error" >"$err"
  fi
  report disk WARN "\`team-janitor disk status\` did not answer: $(first_error)" "fix what it names, then run team-doctor again"
fi
