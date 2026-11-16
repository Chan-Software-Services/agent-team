#!/usr/bin/env bats
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the quota model line, whether team-quota status holds a fresh model window, read
# from a fake team-quota in the test's own code checkout printing a status object.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
  only_checks 246-quota.sh
}

FIX="on the lease holder, run team-quota usage and fix what it names; its heartbeat reads every 10 minutes"
FALLS_BACK="a rule on a model's week falls back to seven_day"

# The doctor's team-quota prints <status> (a JSON text) on status --json: fake_status <status>
fake_status() {
  printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/status.json"
  fake_quota <<EOF
[[ \$* == 'status --json' ]] || { echo "team-quota stub: unplanned call: \$*" >&2; exit 2; }
cat "$BATS_TEST_TMPDIR/status.json"
EOF
}

# The doctor's team-quota is the script on stdin: fake_quota <<'EOF' ... EOF
fake_quota() {
  rm "$CODE_CHECKOUT/bin/team-quota"
  { echo '#!/usr/bin/env bash'; cat; } >"$CODE_CHECKOUT/bin/team-quota"
  chmod +x "$CODE_CHECKOUT/bin/team-quota"
}

# A status object as team-quota status --json prints it, the week's reading 2 minutes old, with
# the model reading of <machine> <age> minutes old holding <models> (a JSON array of
# {name, used}), fresh at 30 minutes or less, and the note team-quota gives it:
# status_of <machine> <age> <models> [<problem>]
status_of() {
  jq -cn --arg machine "$1" --argjson age "$2" --argjson models "$3" --arg problem "${4:-}" '
    "2036-01-07T14:00:00Z" as $resets
    | ($age <= 30) as $fresh
    | (if $problem == "" then null else $problem end) as $problem
    | (if $machine == "" then null else $machine end) as $machine
    | ($machine // "an unnamed machine") as $where
    | {name: "seven_day", used: 77, resets_at: $resets, reset: false, reset_text: "resets Mon 14:00", crossed: [70]} as $week
    | (if $fresh then $models | map({name: "model:\(.name)", used, resets_at: $resets, reset: false,
        reset_text: "resets Mon 14:00", crossed: []}) else [] end) as $shown
    | (if $fresh | not then "model windows: none fresh, the last read \($age) min ago on \($where)"
       elif $shown == [] then "model windows: none, Claude Code'"'"'s usage read \($age) min ago on \($where) gives no model'"'"'s own week"
       else null end) as $note
    | {schema: "team-quota/1",
       reading: {at: "2036-01-01T00:00:00Z", machine: "home-pc", windows: {seven_day: {used: 77, resets_at: $resets}}, models: []},
       age_minutes: 2, fresh: true, windows: ([$week] + $shown),
       model_reading: {at: "2036-01-01T00:00:00Z", machine: $machine, source: "usage", windows: {},
         models: ($models | map(. + {resets_at: $resets}))},
       model_age_minutes: $age, model_fresh: $fresh, model_problem: $problem,
       model_note: (if $note == null then null else $note + "; a rule on a model'"'"'s week falls back to seven_day"
         + (if $problem == null then "" else "; the last read here failed: \($problem)" end) end)}'
}

@test "the quota model line passes with each fresh model window, its use and the reading's age and machine" {
  fake_status "$(status_of home-pc 4 '[{"name": "Fable", "used": 96.4}]')"
  run_bin -0 team-doctor
  assert_equal "$output" "PASS quota model: Fable's week 96%, read 4 min ago on home-pc"

  # Two models, from one reading of an unnamed machine.
  fake_status "$(status_of '' 0 '[{"name": "Fable", "used": 96}, {"name": "Opus", "used": 12}]')"
  run_bin -0 team-doctor
  assert_equal "$output" "PASS quota model: Fable's week 96%, Opus's week 12%, read 0 min ago on an unnamed machine"
}

@test "the quota model line passes on a fresh reading whose answer gives no model's own week" {
  fake_status "$(status_of home-pc 4 '[]')"
  run_bin -0 team-doctor
  assert_equal "$output" "PASS quota model: Claude Code's usage read 4 min ago on home-pc gives no model's own week"
}

@test "the quota model line warns with the status's note on a stale model reading, and with the last read's failure" {
  fake_status "$(status_of home-pc 40 '[{"name": "Fable", "used": 96}]')"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: none fresh, the last read 40 min ago on home-pc; $FALLS_BACK; fix: $FIX"

  fake_status "$(status_of home-pc 40 '[{"name": "Fable", "used": 96}]' "Claude Code gave no get_usage answer within 45 s")"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: none fresh, the last read 40 min ago on home-pc; $FALLS_BACK; the last read here failed: Claude Code gave no get_usage answer within 45 s; fix: $FIX"
}

@test "the quota model line warns with the status's note when no model reading was ever taken, and with no reading at all" {
  local none="none read yet (team-quota usage reads them from Claude Code, every 10 minutes on the heartbeat); $FALLS_BACK"
  local why="Claude Code's answer holds no model_scoped, so it could not tell the model windows"
  fake_status "$(status_of home-pc 0 '[]' | jq -c --arg none "model windows: $none" \
    '.model_reading = null | .model_age_minutes = null | .model_fresh = false | .model_note = $none')"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: $none; fix: $FIX"

  # The status a machine with no reading at all prints (as team-quota.bats holds it), with no
  # problem and with this machine's last read failed.
  local empty='{"schema": "team-quota/1", "reading": null, "age_minutes": null, "fresh": false, "windows": [],
    "model_reading": null, "model_age_minutes": null, "model_fresh": false, "model_problem": null, "model_note": null}'
  fake_status "$empty"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: no quota reading yet; fix: $FIX"
  fake_status "$(jq -c --arg why "$why" --arg note "model windows: $none; the last read here failed: $why" \
    '.model_problem = $why | .model_note = $note' <<<"$empty")"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: $none; the last read here failed: $why; fix: $FIX"
}

@test "the quota model line warns, never fails, when team-quota status fails or prints no status" {
  local fix="fix what team-quota names, then run team-doctor again"
  fake_quota <<'EOF'
printf '%s\n' "team-quota: the team home cannot be read" "a second line" >&2
exit 1
EOF
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: team-quota status failed: the team home cannot be read; fix: $fix"

  # Exit 0, but no team-quota/1 object: not JSON, another schema, or nothing.
  fake_status "not json"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: team-quota status failed: it printed no team-quota/1 status; fix: $fix"
  fake_status '{"schema": "team-quota/2", "model_fresh": true}'
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: team-quota status failed: it printed no team-quota/1 status; fix: $fix"
  fake_quota <<'EOF'
echo "team-quota: a warning on stderr" >&2
EOF
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: team-quota status failed: a warning on stderr; fix: $fix"
}

@test "team-doctor --json carries the quota model line, and --help lists the check" {
  fake_status "$(status_of home-pc 4 '[{"name": "Fable", "used": 96}]')"
  run_bin -0 --separate-stderr team-doctor --json
  assert_equal "$(jq -c '.' <<<"$output")" \
    '[{"check":"quota model","verdict":"PASS","reason":"Fable'"'"'s week 96%, read 4 min ago on home-pc","fix":""}]'
  fake_status "$(status_of home-pc 40 '[]')"
  run_bin -0 --separate-stderr team-doctor --json
  assert_equal "$(jq -c '.[] | [.check, .verdict, .fix]' <<<"$output")" "[\"quota model\",\"WARN\",\"$FIX\"]"

  run_bin -0 team-doctor --help
  assert_contains "$output" "
  quota model   team-quota status --json: passes while a model window is fresh; warns when none is read, fresh or readable, with why.
"
}

@test "the quota model line reads the real team-quota status, which starts no Claude Code" {
  # This checkout's own team-quota, on doctor_machine's good usage read.
  run_bin -0 team-doctor
  grep -xE "PASS quota model: Fable's week 40%, read [01] min ago on home-pc" <<<"$output"

  # With no reading on this machine or in the team home; the setup's team-config apply asked
  # claude for its plugins, so its calls so far are left out.
  rm "$HOME/.local/state/agent-team/quota-usage.json" "$STUB_CALLS/claude.log"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN quota model: no quota reading yet; fix: $FIX"
  assert_equal "$(stub_calls claude)" ""

  # A usage reading in the team home's day file, 3 minutes old.
  local at
  at=$(date -u -d '-3 minutes' +%FT%TZ)
  mkdir -p "$TEAM_HOME/usage/home-pc/quota"
  jq -cn --arg at "$at" '{at: $at, machine: "home-pc", source: "usage",
    windows: {seven_day: {used: 77, resets_at: "2036-01-07T14:00:00Z"}},
    models: [{name: "Fable", used: 96, resets_at: "2036-01-07T14:00:00Z"}]}' \
    >"$TEAM_HOME/usage/home-pc/quota/${at%%T*}.jsonl"
  run_bin -0 team-doctor
  assert_equal "$output" "PASS quota model: Fable's week 96%, read 3 min ago on home-pc"
  assert_equal "$(stub_calls claude)" ""
}
