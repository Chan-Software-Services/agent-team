# tmp           `team-janitor tmp status --json`: how full /tmp is and how many of the team's
#               stale leftovers team-janitor tmp removed today. Passes under 50% ("/tmp is 12%
#               full (1.9 GiB of 16.0 GiB); 3 leftovers removed today"), and on a file system that
#               is not tmpfs, or on macOS, which it does not judge ("/tmp is on ext4, not a memory
#               file system, so it is not judged"); warns at 50% and over, with the status' first
#               line and its fix (team-janitor tmp status names the largest entries; team-janitor
#               tmp removes the team's stale leftovers), and when the status does not answer, naming
#               its first error; never fails, since a full /tmp fails the runs that write to it,
#               not the team.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's

# The status' first line, in the words of bin/lib/tmp.sh's reading line, from its JSON.
# shellcheck source=bin/lib/tmp.sh
source "$TEAM_LIB/tmp.sh"
tmp_line_status=$(TEAM_HOME=$TEAM_HOME "$bin/team-janitor" tmp status --json 2>"$err" </dev/null) && tmp_line_rc=0 || tmp_line_rc=$?
tmp_line_judged='' tmp_line_removed=''
if ((tmp_line_rc == 0)) &&
  json_vars TMP_FS_TYPE='.type | strings' TMP_FS_SIZE='.size | numbers' TMP_FS_USED='.used | numbers' \
    TMP_FS_PERCENT='.percent | numbers' tmp_line_judged='.judged | booleans' \
    tmp_line_removed='.removed_today | numbers' <<<"$tmp_line_status" 2>/dev/null &&
  [[ -n $TMP_FS_TYPE && -n $TMP_FS_SIZE && -n $TMP_FS_USED && -n $TMP_FS_PERCENT && -n $tmp_line_judged && -n $tmp_line_removed ]]; then
  TMP_FS_JUDGED=''
  [[ $tmp_line_judged != true ]] || TMP_FS_JUDGED=1
  tmp_line_first=$(tmp_reading_line)
  if [[ -n $TMP_FS_JUDGED ]] && ((TMP_FS_PERCENT >= TMP_WARN_PERCENT)); then
    report tmp WARN "$tmp_line_first" \
      "team-janitor tmp status names the largest entries; team-janitor tmp removes the team's stale leftovers"
  elif [[ -n $TMP_FS_JUDGED ]]; then
    report tmp PASS "$tmp_line_first; $tmp_line_removed leftover$([[ $tmp_line_removed == 1 ]] || echo s) removed today"
  else
    report tmp PASS "$tmp_line_first"
  fi
else
  ((tmp_line_rc)) || echo "it printed no team-tmp/1 reading" >"$err"
  report tmp WARN "\`team-janitor tmp status\` did not answer: $(first_error)" "fix what it names, then run team-doctor again"
fi
