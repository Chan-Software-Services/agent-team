# quota model   team-quota status --json: passes while the model reading is fresh; warns when none is read, fresh or readable, with why.
#               Passes naming each fresh model window and the reading's age and machine
#               ("Fable's week 96%, read 4 min ago on home-pc"), or saying the fresh reading gives
#               no model's own week; warns otherwise with the status's model note (no model
#               reading, a stale one, this machine's last read failed, or no reading at all), and
#               warns when team-quota status fails or prints no status. Never fails, and never runs
#               team-quota usage, so it starts no Claude Code.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's

rc=0
quota=$(TEAM_HOME=$TEAM_HOME bounded 30 "$bin/team-quota" status --json 2>"$err" </dev/null) || rc=$?
quota=$(jq -c 'select(type == "object" and .schema == "team-quota/1")' <<<"$quota" 2>/dev/null) || quota=''
if ((rc)) || [[ -z $quota ]]; then
  quota_why=$(first_error)
  ((rc != 124)) || quota_why="it did not answer in 30 s"
  report "quota model" WARN "team-quota status failed: ${quota_why:-it printed no team-quota/1 status}" \
    "fix what team-quota names, then run team-doctor again"
else
  verdict='' reason=''
  json_vars verdict='if .model_fresh == true then "PASS" else "WARN" end' reason='
      (.model_reading.machine // "an unnamed machine") as $where
      | if .model_fresh == true then
          [.windows[]? | select(.name | startswith("model:"))
            | "\(.name | ltrimstr("model:"))'"'"'s week \(.used | floor)%"] as $models
          | if $models == [] then "Claude Code'"'"'s usage read \(.model_age_minutes) min ago on \($where) gives no model'"'"'s own week"
            else "\($models | join(", ")), read \(.model_age_minutes) min ago on \($where)" end
        elif .model_note == null then "no quota reading yet"
        else .model_note | ltrimstr("model windows: ") end' <<<"$quota" 2>/dev/null ||
    verdict=''
  if [[ -z $verdict ]]; then
    report "quota model" WARN "team-quota status failed: it printed a status the doctor cannot read" \
      "fix what team-quota names, then run team-doctor again"
  elif [[ $verdict == PASS ]]; then
    report "quota model" PASS "$reason"
  else
    report "quota model" WARN "$reason" \
      "on the lease holder, run team-quota usage and fix what it names; its heartbeat then reads them on its schedule"
  fi
fi
