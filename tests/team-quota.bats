#!/usr/bin/env bats
# team-quota: the status line every session runs, which records Claude Code's rate_limits reading
# when it changes, and the status that reads the newest reading across machines.

load helpers/common

setup() {
  sandbox
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  fixtures=$REPO_ROOT/tests/fixtures/quota
  state=$HOME/.local/state/agent-team/quota.json
  # Times are shown in the machine's local time: UTC here, so the line is the same everywhere.
  export TZ=UTC
}

# The status line for the fixture <name>: line <name>
line() {
  run_bin -0 --separate-stderr team-quota line <"$fixtures/$1.json"
}

# The day files of <machine>'s readings, one path per line under the team home.
day_files() {
  (cd "$TEAM_HOME" && find usage -path "usage/$1/quota/*" -type f | sort)
}

# Every reading of this machine's day files, without its time, one compact line each.
readings() {
  cat "$TEAM_HOME"/usage/home-pc/quota/*.jsonl 2>/dev/null | jq -c 'del(.at)'
}

# under_seconds <seconds> <start>: less than <seconds> have passed since <start>, an EPOCHREALTIME.
under_seconds() {
  local now=$EPOCHREALTIME
  (((${now/[.,]/} - ${2/[.,]/}) < $1 * 1000000)) || { echo "started at $2, still running at $now" >&2; return 1; }
}

# ago <minutes>: the UTC time that many minutes before now.
ago() {
  date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ
}

# from_now <hours>: the UTC time that many hours after now.
from_now() {
  date -u -d "@$(($(date +%s) + $1 * 3600))" +%FT%TZ
}

# day_file <machine> <at>: the path of <machine>'s day file of the time <at>, the file team-quota
# line appends a reading taken then to, its directory made.
day_file() {
  mkdir -p "$TEAM_HOME/usage/$1/quota"
  echo "$TEAM_HOME/usage/$1/quota/${2%%T*}.jsonl"
}

# reading <machine> <at> <seven_day used> [<five_hour used> [<Fable used>]]: a reading as team-quota
# line writes one, appended to <machine>'s day file of <at>, its windows resetting in a day.
reading() {
  local file reset
  file=$(day_file "$1" "$2") reset=$(from_now 24)
  jq -cn --arg m "$1" --arg at "$2" --argjson week "$3" --arg hour "${4:-}" --arg fable "${5:-}" --arg reset "$reset" \
    '{at: $at, machine: $m, windows: ({seven_day: {used: $week, resets_at: $reset}}
      + if $hour == "" then {} else {five_hour: {used: ($hour | tonumber), resets_at: $reset}} end),
      models: (if $fable == "" then [] else [{name: "Fable", used: ($fable | tonumber), resets_at: $reset}] end)}' \
    >>"$file"
}

# usage_reading <machine> <at> [<Fable used>]: a reading as team-quota usage writes one, appended
# to <machine>'s day file of <at> (or to the file <file> when given as a fourth argument), its
# windows and its Fable window, with no Fable window when <Fable used> is empty, resetting in a day.
usage_reading() {
  local file=${4:-} reset
  [[ -n $file ]] || file=$(day_file "$1" "$2")
  reset=$(from_now 24)
  jq -cn --arg m "$1" --arg at "$2" --arg fable "${3-96}" --arg reset "$reset" \
    '{at: $at, machine: $m, source: "usage", windows: {five_hour: {used: 23, resets_at: $reset}, seven_day: {used: 77, resets_at: $reset}},
      models: (if $fable == "" then [] else [{name: "Fable", used: ($fable | tonumber), resets_at: $reset}] end)}' \
    >>"$file"
}

# claude_stub: put on PATH a claude that answers as Claude Code's stream-json control protocol does:
# it prints a line of its own and one that is not JSON, then, for each line read on stdin, answers
# an initialize with a success and a get_usage with the fixture $QUOTA_ANSWER (a control_response's
# response member) given the request's id. It records its working directory and how many entries
# that held in $STUB_CALLS/claude.cwd and claude.entries, and each stdin line in claude.stdin; the
# stub records its arguments in claude.log.
claude_stub() {
  stub_script claude <<'EOF'
pwd >"$STUB_CALLS/claude.cwd"
shopt -s nullglob dotglob
entries=(*)
echo "${#entries[@]}" >"$STUB_CALLS/claude.entries"
echo '{"type":"system","subtype":"status","status":null}'
echo 'not json'
while IFS= read -r line; do
  printf '%s\n' "$line" >>"$STUB_CALLS/claude.stdin"
  case $(jq -r .request.subtype <<<"$line") in
    initialize)
      jq -c '{type: "control_response", response: {subtype: "success", request_id, response: {commands: [], models: []}}}' <<<"$line"
      ;;
    get_usage)
      jq -c --slurpfile answer "$QUOTA_ANSWER" '{type: "control_response", response: ($answer[0] + {request_id})}' <<<"$line"
      ;;
  esac
done
EOF
}

# usage <fixture>: team-quota usage, with the stub claude answering the fixture <fixture>.
usage() {
  claude_stub
  QUOTA_ANSWER=$fixtures/$1.json run_bin --separate-stderr team-quota usage
}

@test "--help prints the header" {
  run_bin -0 team-quota --help
  assert_contains "$output" "Usage: team-quota line"
  assert_contains "$output" "team-quota usage"
  assert_contains "$output" "model_reading"
  # The status line gives no model window, so the header no longer waits for it to.
  [[ $output != *"models stays empty until"* ]]
}

@test "a malformed command line is a usage error" {
  run_bin -2 team-quota
  run_bin -2 team-quota sideways
  run_bin -2 team-quota status --yaml
  run_bin -2 team-quota usage --sideways
  [[ ! -e $STUB_CALLS/claude.log ]]
}

@test "reproduction: the status line's reading holds no model window, and team-quota usage reads Fable's own week" {
  # The status line input as Claude Code 2.1.325 gives it: the week alone, no model window.
  line week-only
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '.windows | map(.name)' <<<"$output")" '["seven_day"]'
  # Claude Code's get_usage answer, as /usage reads it, gives Fable's own week.
  usage usage-good
  assert_equal "$status" 0
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '.windows | map({name, used})' <<<"$output")" \
    '[{"name":"five_hour","used":23},{"name":"seven_day","used":77},{"name":"model:Fable","used":96}]'
}

@test "usage records a good answer's five-hour and weekly windows and its model windows, and nothing else" {
  local attempt=$HOME/.local/state/agent-team/quota-usage.json
  # The status line's state file, which usage never writes.
  line full
  local before today
  before=$(<"$state") today=$(date -u +%F)
  rm "$TEAM_HOME/usage/home-pc/quota/$today.jsonl"
  usage usage-good
  assert_equal "$status" 0
  assert_equal "$output" "model windows read: Fable 96% (resets Mon 14:00)"
  assert_equal "$stderr" ""
  # One reading, in today's day file.
  assert_equal "$(day_files home-pc)" "usage/home-pc/quota/$today.jsonl"
  assert_equal "$(readings)" '{"machine":"home-pc","source":"usage","windows":{"five_hour":{"used":23,"resets_at":"2036-11-10T14:00:00Z"},"seven_day":{"used":77,"resets_at":"2036-11-14T18:00:00Z"}},"models":[{"name":"Fable","used":96,"resets_at":"2036-11-17T14:00:00Z"}]}'
  local file=$TEAM_HOME/usage/home-pc/quota/$today.jsonl
  [[ $(jq -r .at "$file") =~ ^${today}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  assert_equal "$(jq -r 'keys_unsorted | join(" ")' "$file")" "at machine source windows models"
  # No spend figure, no other window, no account data.
  local text
  text=$(<"$file")
  for figure in 1234.5 987.65 5000 seven_day_sonnet extra_usage max; do
    [[ $text != *"$figure"* ]] || { echo "the reading holds $figure" >&2; return 1; }
  done
  # The attempt record holds the same reading.
  assert_equal "$(jq -c '{ok, why}' "$attempt")" '{"ok":true,"why":null}'
  assert_equal "$(jq -c .reading "$attempt")" "$(jq -c . "$file")"
  [[ $(jq -r .at "$attempt") =~ ^${today}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ ! -e $attempt.tmp ]]
  # The status line's state file is untouched.
  assert_equal "$(<"$state")" "$before"
}

@test "usage starts one headless Claude Code with the spec's flags, in an empty directory it removes, and asks get_usage after initialize" {
  usage usage-good
  assert_equal "$status" 0
  assert_equal "$(wc -l <"$STUB_CALLS/claude.log")" 1
  assert_equal "$(<"$STUB_CALLS/claude.log")" \
    '["-p","--input-format","stream-json","--output-format","stream-json","--verbose","--no-session-persistence","--strict-mcp-config","--settings","{\"disableAllHooks\": true}"]'
  local cwd
  cwd=$(<"$STUB_CALLS/claude.cwd")
  assert_equal "$(<"$STUB_CALLS/claude.entries")" 0
  [[ $cwd != "$PWD" && $cwd != "$HOME" ]]
  [[ ! -e $cwd ]]
  assert_equal "$(jq -c . "$STUB_CALLS/claude.stdin")" \
    "$(printf '%s\n' '{"type":"control_request","request_id":"team-quota-init","request":{"subtype":"initialize"}}' \
      '{"type":"control_request","request_id":"team-quota-usage","request":{"subtype":"get_usage","skip_behaviors":true}}')"
}

@test "usage records an answer with model_scoped empty as a reading with no model window, and status says so" {
  usage usage-no-models
  assert_equal "$status" 0
  assert_equal "$output" "model windows read: none, Claude Code's answer gives no model's own week"
  assert_equal "$(readings)" '{"machine":"home-pc","source":"usage","windows":{"seven_day":{"used":77,"resets_at":"2036-11-14T18:00:00Z"}},"models":[]}'
  local note="model windows: none, Claude Code's usage read 0 min ago on home-pc gives no model's own week; a rule on a model's week falls back to seven_day"
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{windows: (.windows | map(.name)), model_fresh, model_note}' <<<"$output")" \
    "{\"windows\":[\"seven_day\"],\"model_fresh\":true,\"model_note\":\"$note\"}"
  run_bin -0 team-quota status
  assert_equal "${lines[-1]}" "$note"
}

@test "with no team home, or no machine name, the usage reading is in the attempt record alone and status shows it" {
  local attempt=$HOME/.local/state/agent-team/quota-usage.json
  rm -rf "${TEAM_HOME:?}"
  usage usage-good
  assert_equal "$status" 0
  assert_equal "$stderr" ""
  [[ ! -e $TEAM_HOME ]]
  assert_equal "$(jq -r '.reading.machine, .reading.source' "$attempt")" $'home-pc\nusage'
  run_bin -0 --separate-stderr team-quota status --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c '{machine: .reading.machine, model_fresh, windows: (.windows | map(.name))}' <<<"$output")" \
    '{"machine":"home-pc","model_fresh":true,"windows":["five_hour","seven_day","model:Fable"]}'
  # No machine name: the reading's machine is null, and no team home file is written.
  mkdir -p "$TEAM_HOME"
  rm "$HOME/.config/agent-team/machine" "$attempt"
  usage usage-good
  assert_equal "$status" 0
  assert_equal "$(jq -r .reading.machine "$attempt")" null
  assert_equal "$(find "$TEAM_HOME" -path '*/quota/*')" ""
  run_bin -0 team-quota status
  assert_equal "${lines[0]}" "read on an unnamed machine 0 min ago"
  assert_equal "${lines[-1]}" "model:Fable 96% (resets Mon 14:00), past 90%; read 0 min ago"
}

@test "status shows a fresh model reading beside a newer status line reading, the model window with its own age" {
  usage_reading home-pc "$(ago 4)"
  reading home-pc "$(ago 1)" 61 25
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{machine: .reading.machine, source: .reading.source, age_minutes, model_age_minutes, model_fresh, model_problem, model_note}' <<<"$output")" \
    '{"machine":"home-pc","source":null,"age_minutes":1,"model_age_minutes":4,"model_fresh":true,"model_problem":null,"model_note":null}'
  assert_equal "$(jq -c '.model_reading | {source, models: (.models | map(.name))}' <<<"$output")" '{"source":"usage","models":["Fable"]}'
  assert_equal "$(jq -c '.windows | map({name, used})' <<<"$output")" \
    '[{"name":"five_hour","used":25},{"name":"seven_day","used":61},{"name":"model:Fable","used":96}]'
  local week fable
  week=$(TZ=UTC date -d "$(jq -r '.windows[1].resets_at' <<<"$output")" '+%a %H:%M')
  fable=$(TZ=UTC date -d "$(jq -r '.windows[2].resets_at' <<<"$output")" '+%a %H:%M')
  run_bin -0 team-quota status
  assert_equal "${#lines[@]}" 4
  assert_equal "${lines[0]}" "read on home-pc 1 min ago"
  assert_equal "${lines[2]}" "seven_day 61% (resets $week)"
  assert_equal "${lines[3]}" "model:Fable 96% (resets $fable), past 90%; read 4 min ago"
}

@test "status leaves out a model reading over 30 minutes old, and finds one in a machine's previous day file" {
  usage_reading home-pc "$(ago 40)"
  reading home-pc "$(ago 1)" 61
  local note="model windows: none fresh, the last read 40 min ago on home-pc; a rule on a model's week falls back to seven_day"
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{windows: (.windows | map(.name)), model_age_minutes, model_fresh, model_note}' <<<"$output")" \
    "{\"windows\":[\"seven_day\"],\"model_age_minutes\":40,\"model_fresh\":false,\"model_note\":\"$note\"}"
  assert_equal "$(jq -r '.model_reading.source' <<<"$output")" usage
  run_bin -0 team-quota status
  assert_equal "${#lines[@]}" 3
  assert_equal "${lines[2]}" "$note"
  # At 30 minutes it is still fresh.
  usage_reading home-pc "$(ago 30)"
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{windows: (.windows | map(.name)), model_age_minutes, model_fresh, model_note}' <<<"$output")" \
    '{"windows":["seven_day","model:Fable"],"model_age_minutes":30,"model_fresh":true,"model_note":null}'
  # A model reading in yesterday's day file, once the status line has opened today's, is found.
  rm -r "${TEAM_HOME:?}/usage"
  # The days before the status line reading's own, whatever the time of day the test runs at.
  local at day
  at=$(ago 1) day=$(date -u -d "$at" +%F)
  reading laptop "$at" 61
  usage_reading laptop "$(ago 20)" 96 "$(day_file laptop "$(date -u -d "$day - 1 day" +%F)T23:59:00Z")"
  # And the file before it is not read: only a machine's latest two day files.
  usage_reading laptop "$(ago 10)" 50 "$(day_file laptop "$(date -u -d "$day - 2 days" +%F)T12:00:00Z")"
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{windows: (.windows | map({name, used})), model_age_minutes}' <<<"$output")" \
    '{"windows":[{"name":"seven_day","used":61},{"name":"model:Fable","used":96}],"model_age_minutes":20}'
}

@test "the line gives the model, the context, the 5-hour and weekly use, each model's week and the weekly reset, in that order" {
  line full
  assert_equal "$output" "Opus 5.5 · ctx 42% · 5h 23% · week 61% · Fable 91% · resets Fri 18:00"
  assert_equal "$stderr" ""
}

@test "the reset is in the machine's local time" {
  TZ=Asia/Kolkata line full
  assert_equal "$output" "Opus 5.5 · ctx 42% · 5h 23% · week 61% · Fable 91% · resets Fri 23:30"
}

@test "with no rate limits, the line is the model alone and nothing is written" {
  line no-limits
  assert_equal "$output" "Opus 5.5"
  [[ ! -e $state ]]
  assert_equal "$(day_files home-pc)" ""
}

@test "with malformed JSON, the line is the model alone, exit 0, and nothing is written" {
  line malformed
  assert_equal "$output" "Opus 5.5"
  [[ ! -e $state ]]
  assert_equal "$(day_files home-pc)" ""
  run_bin -0 --separate-stderr team-quota line </dev/null
  assert_equal "$output" ""
  run_bin -0 team-quota line <<<'[1, 2'
  run_bin -0 team-quota line <<<'"text"'
  run_bin -0 team-quota line <<<'{"model": {"display_name": 5}, "rate_limits": [1]}'
  [[ ! -e $state ]]
}

@test "a window or model window with a missing or wrongly typed field is left out, never the whole reading" {
  line bad-fields
  assert_equal "$output" "Opus 5.5 · week 61% · Haiku 5% · resets Fri 18:00"
  assert_equal "$(readings)" '{"machine":"home-pc","windows":{"seven_day":{"used":61.9,"resets_at":"2036-11-14T18:00:00Z"}},"models":[{"name":"Haiku","used":5.5,"resets_at":"2036-11-17T09:00:00Z"}]}'
}

@test "a reading is written to the state file and the team home's day file, with every window under its own name" {
  line full
  local today
  today=$(date -u +%F)
  assert_equal "$(day_files home-pc)" "usage/home-pc/quota/$today.jsonl"
  assert_equal "$(readings)" '{"machine":"home-pc","windows":{"five_hour":{"used":23.4,"resets_at":"2036-11-10T14:00:00Z"},"seven_day":{"used":61.9,"resets_at":"2036-11-14T18:00:00Z"},"seven_day_sonnet":{"used":12,"resets_at":"2036-11-14T18:00:00Z"}},"models":[{"name":"Fable","used":91.2,"resets_at":"2036-11-17T09:00:00Z"}]}'
  assert_equal "$(jq -c . "$state")" "$(jq -c . "$TEAM_HOME/usage/home-pc/quota/$today.jsonl")"
  [[ $(jq -r .at "$state") =~ ^${today}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "a reading is written again only when a whole percent, a reset or the set of windows changed" {
  local input=$BATS_TEST_TMPDIR/input.json
  # change <jq filter>: the line run on the full fixture changed by <filter>.
  change() {
    jq "$1" "$fixtures/full.json" >"$input"
    run_bin -0 team-quota line <"$input"
  }
  line full
  line full
  # Within the same whole percent, everywhere.
  change '.rate_limits.seven_day.used_percentage = 61.1 | .rate_limits.model_scoped[0].utilization = 91.9
    | .context_window.used_percentage = 80'
  assert_equal "$(readings | wc -l)" 1
  change '.rate_limits.seven_day.used_percentage = 62'
  assert_equal "$(readings | wc -l)" 2
  change '.rate_limits.seven_day.used_percentage = 62 | .rate_limits.five_hour.resets_at = 2109956400'
  assert_equal "$(readings | wc -l)" 3
  change '.rate_limits.seven_day.used_percentage = 62 | .rate_limits.five_hour.resets_at = 2109956400
    | .rate_limits.model_scoped[0].utilization = 92'
  assert_equal "$(readings | wc -l)" 4
  # A window that went, and one that came back.
  change '.rate_limits.seven_day.used_percentage = 62 | .rate_limits.five_hour.resets_at = 2109956400
    | .rate_limits.model_scoped[0].utilization = 92 | del(.rate_limits.seven_day_sonnet)'
  assert_equal "$(readings | wc -l)" 5
  change '.rate_limits.seven_day.used_percentage = 62 | .rate_limits.five_hour.resets_at = 2109956400
    | .rate_limits.model_scoped[0].utilization = 92'
  assert_equal "$(readings | wc -l)" 6
  assert_equal "$(readings | jq -sc 'map(.windows.seven_day.used)')" '[61.9,62,62,62,62,62]'
  # The state file is the machine's latest.
  assert_equal "$(jq -c 'del(.at)' "$state")" "$(readings | tail -n 1)"
}

@test "with no team home, only the machine's state file is written" {
  rm -rf "${TEAM_HOME:?}"
  line full
  assert_equal "$output" "Opus 5.5 · ctx 42% · 5h 23% · week 61% · Fable 91% · resets Fri 18:00"
  assert_equal "$stderr" ""
  assert_equal "$(jq -r '.machine, .windows.seven_day.used' "$state")" $'home-pc\n61.9'
  [[ ! -e $TEAM_HOME ]]
  # Nor when no setting names one.
  rm -f "$state"
  run -0 --separate-stderr env -u TEAM_HOME "$REPO_ROOT/bin/team-quota" line <"$fixtures/full.json"
  assert_equal "$output" "Opus 5.5 · ctx 42% · 5h 23% · week 61% · Fable 91% · resets Fri 18:00"
  assert_equal "$(jq -r .windows.seven_day.used "$state")" 61.9
}

@test "with no machine name, the reading goes to the state file only, its machine null" {
  rm "$HOME/.config/agent-team/machine"
  line full
  assert_equal "$stderr" ""
  assert_equal "$(jq -r .machine "$state")" null
  assert_equal "$(find "$TEAM_HOME" -path '*/quota/*')" ""
}

@test "a held lock skips the write without waiting" {
  mkdir -p "${state%/*}"
  local fd start
  exec {fd}>"${state%/*}/quota.lock"
  flock -n "$fd"
  start=$EPOCHREALTIME
  line full
  exec {fd}>&-
  assert_equal "$output" "Opus 5.5 · ctx 42% · 5h 23% · week 61% · Fable 91% · resets Fri 18:00"
  [[ ! -e $state ]]
  assert_equal "$(day_files home-pc)" ""
  under_seconds 2 "$start"
  # Once the lock is free, the same reading is written.
  line full
  [[ -e $state ]]
}

@test "an input that never ends is cut short: the line ends at once, with exit 0" {
  local start=$EPOCHREALTIME
  run_bin -0 team-quota line < <(cat "$fixtures/full.json"; exec 3>&-; sleep 3)
  under_seconds 2 "$start"
}

@test "an unwritable team home loses only that write: the line prints and the state is kept for the next try" {
  mkdir -p "$TEAM_HOME/usage/home-pc"
  echo "not a directory" >"$TEAM_HOME/usage/home-pc/quota"
  line full
  assert_equal "$output" "Opus 5.5 · ctx 42% · 5h 23% · week 61% · Fable 91% · resets Fri 18:00"
  # The state is left as it was, so the next line tries the team home again.
  [[ ! -e $state ]]
  rm "$TEAM_HOME/usage/home-pc/quota"
  line full
  assert_equal "$(readings | wc -l)" 1
}

@test "status with no reading anywhere says so, exit 0" {
  run_bin -0 team-quota status
  assert_equal "$output" "no quota reading yet: no session has shown a status line since team-quota was set up"
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c . <<<"$output")" '{"schema":"team-quota/1","reading":null,"age_minutes":null,"fresh":false,"windows":[],"model_reading":null,"model_age_minutes":null,"model_fresh":false,"model_problem":null,"model_note":null}'
}

@test "status gives the newest reading across machines' day files and the state file" {
  reading home-pc "$(ago 300)" 40
  reading home-pc "$(ago 50)" 41
  reading laptop "$(ago 20)" 52 95 93
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{machine: .reading.machine, age_minutes, fresh}' <<<"$output")" '{"machine":"laptop","age_minutes":20,"fresh":true}'
  assert_equal "$(jq -c '.windows | map({name, used, crossed})' <<<"$output")" \
    '[{"name":"five_hour","used":95,"crossed":[90]},{"name":"seven_day","used":52,"crossed":[]},{"name":"model:Fable","used":93,"crossed":[90]}]'
  assert_equal "$(jq -r '.windows | map(.resets_at) | unique | length' <<<"$output")" 1
  # This machine's state file, when newer than every day file, gives the windows; the model window
  # is still laptop's, the newest reading that holds one, while it is fresh.
  mkdir -p "${state%/*}"
  jq -cn --arg at "$(ago 5)" --arg reset "$(from_now 24)" \
    '{at: $at, machine: "home-pc", windows: {seven_day: {used: 91.5, resets_at: $reset}}, models: []}' >"$state"
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{machine: .reading.machine, age_minutes, windows: (.windows | map({name, crossed}))}' <<<"$output")" \
    '{"machine":"home-pc","age_minutes":5,"windows":[{"name":"seven_day","crossed":[70,90]},{"name":"model:Fable","crossed":[90]}]}'
  assert_equal "$(jq -c '{machine: .model_reading.machine, model_age_minutes}' <<<"$output")" '{"machine":"laptop","model_age_minutes":20}'
  run_bin -0 team-quota status
  assert_equal "${lines[0]}" "read on home-pc 5 min ago"
  assert_equal "${lines[1]}" "seven_day 91% (resets $(TZ=UTC date -d "$(jq -r .windows.seven_day.resets_at "$state")" '+%a %H:%M')), past 70% and 90%"
}

@test "status names a stale reading, over 180 minutes old" {
  reading laptop "$(ago 181)" 75
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{age_minutes, fresh, crossed: .windows[0].crossed}' <<<"$output")" '{"age_minutes":181,"fresh":false,"crossed":[70]}'
  run_bin -0 team-quota status
  assert_equal "${lines[0]}" "read on laptop 181 min ago: stale, over 180 minutes old"
  reading laptop "$(ago 180)" 75
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{age_minutes, fresh}' <<<"$output")" '{"age_minutes":180,"fresh":true}'
}

@test "status reads a window that has reset since the reading as crossing nothing" {
  local at
  at=$(ago 30)
  jq -cn --arg at "$at" --arg past "$(ago 10)" --arg reset "$(from_now 2)" \
    '{at: $at, machine: "laptop", windows: {five_hour: {used: 97, resets_at: $past}, seven_day: {used: 72, resets_at: $reset}}, models: []}' \
    >"$(day_file laptop "$at")"
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '.windows | map({name, crossed})' <<<"$output")" '[{"name":"five_hour","crossed":[]},{"name":"seven_day","crossed":[70]}]'
  # Each window says whether it has reset and its reset in the words every reader shows.
  local past reset
  past=$(TZ=UTC date -d "$(jq -r .windows[0].resets_at <<<"$output")" '+%a %H:%M')
  reset=$(TZ=UTC date -d "$(jq -r .windows[1].resets_at <<<"$output")" '+%a %H:%M')
  assert_equal "$(jq -c '.windows | map({reset, reset_text})' <<<"$output")" \
    "[{\"reset\":true,\"reset_text\":\"reset at $past, since this reading\"},{\"reset\":false,\"reset_text\":\"resets $reset\"}]"
  run_bin -0 team-quota status
  assert_contains "${lines[1]}" "five_hour 97% (reset at "
  assert_contains "${lines[1]}" ", since this reading)"
}

@test "status skips a line that is not a reading" {
  local at file
  at=$(ago 40)
  # The day file the reading went to, which just after midnight UTC is yesterday's, not today's.
  file=$(day_file laptop "$at")
  reading laptop "$at" 30
  echo 'not json' >>"$file"
  echo '{"at": 5}' >>"$file"
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{age_minutes, used: .windows[0].used}' <<<"$output")" '{"age_minutes":40,"used":30}'
}

@test "status leaves out a stored window or model window with a field missing or of another type, and a line left with none" {
  local at file reset
  at=$(ago 40) reset=$(from_now 24)
  # Every line goes to the first reading's day file, which status reads as the newest one even when
  # a later line's time falls on the next day, just after midnight UTC.
  file=$(day_file laptop "$at")
  reading laptop "$at" 30
  # A newer line whose every window is bad is no reading: the older one stands.
  jq -cn --arg at "$(ago 30)" --arg reset "$reset" \
    '{at: $at, machine: "laptop", windows: {seven_day: {used: 50}, five_hour: {used: "95", resets_at: $reset}},
      models: [{name: "Fable", used: 95}]}' >>"$file"
  run_bin -0 --separate-stderr team-quota status --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c '{age_minutes, windows: (.windows | map({name, used, crossed}))}' <<<"$output")" \
    '{"age_minutes":40,"windows":[{"name":"seven_day","used":30,"crossed":[]}]}'
  # A newer line with one good window gives that window alone.
  jq -cn --arg at "$(ago 20)" --arg reset "$reset" \
    '{at: $at, machine: "laptop", windows: {seven_day: {used: 72, resets_at: $reset}, five_hour: {used: "95", resets_at: $reset},
      seven_day_opus: {used: 10, resets_at: "soon"}},
      models: [{name: "Fable", used: 95, resets_at: 5}, {name: "", used: 95, resets_at: $reset}, {name: "Sol", used: 91, resets_at: $reset}]}' >>"$file"
  run_bin -0 --separate-stderr team-quota status --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c '{age_minutes, windows: (.windows | map({name, used, crossed}))}' <<<"$output")" \
    '{"age_minutes":20,"windows":[{"name":"seven_day","used":72,"crossed":[70]},{"name":"model:Sol","used":91,"crossed":[90]}]}'
  run_bin -0 --separate-stderr team-quota status
  assert_equal "$stderr" ""
  assert_equal "${#lines[@]}" 3
}

@test "a reading team-quota line wrote is the one status reads" {
  line full
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{machine: .reading.machine, age_minutes, fresh, windows: (.windows | map({name, used, resets_at, crossed}))}' <<<"$output")" \
    '{"machine":"home-pc","age_minutes":0,"fresh":true,"windows":[{"name":"five_hour","used":23.4,"resets_at":"2036-11-10T14:00:00Z","crossed":[]},{"name":"seven_day","used":61.9,"resets_at":"2036-11-14T18:00:00Z","crossed":[]},{"name":"seven_day_sonnet","used":12,"resets_at":"2036-11-14T18:00:00Z","crossed":[]},{"name":"model:Fable","used":91.2,"resets_at":"2036-11-17T09:00:00Z","crossed":[90]}]}'
}

@test "status says plainly that no model window is read yet, and that a rule on a model's week falls back to the week" {
  # The status line input as Claude Code 2.1.325 gives it: its rate_limits holds the week alone.
  line week-only
  assert_equal "$output" "Opus 5.5 · ctx 42% · week 77% · resets Fri 18:00"
  local note="model windows: none read yet (team-quota usage reads them from Claude Code, every 10 minutes on the heartbeat); a rule on a model's week falls back to seven_day"
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{windows: (.windows | map({name, used})), model_reading, model_fresh, model_note}' <<<"$output")" \
    "{\"windows\":[{\"name\":\"seven_day\",\"used\":77}],\"model_reading\":null,\"model_fresh\":false,\"model_note\":\"$note\"}"
  run_bin -0 team-quota status
  assert_equal "${#lines[@]}" 3
  assert_equal "${lines[1]}" "seven_day 77% (resets Fri 18:00), past 70%"
  assert_equal "${lines[2]}" "$note"
}

@test "status shows each model window a reading holds beside the week, with its age and no note" {
  line full
  run_bin -0 team-quota status --json
  assert_equal "$(jq -c '{model_age_minutes, model_fresh, model_note}' <<<"$output")" '{"model_age_minutes":0,"model_fresh":true,"model_note":null}'
  run_bin -0 team-quota status
  assert_equal "${#lines[@]}" 5
  assert_equal "${lines[2]}" "seven_day 61% (resets Fri 18:00)"
  assert_equal "${lines[4]}" "model:Fable 91% (resets Mon 09:00), past 90%; read 0 min ago"
}

@test "the workers' and the coordinator's settings run team-quota line as their status line" {
  local file
  for file in settings/worker.json coordinator.settings.json; do
    assert_equal "$(jq -c .statusLine "$REPO_ROOT/$file")" '{"type":"command","command":"@TEAM_CODE@/bin/team-quota line","padding":0}'
  done
}

@test "a launched worker's settings name this checkout's team-quota line" {
  hold_lease home-pc >/dev/null
  local primary wt
  primary=$(make_repo proj)
  wt=$HOME/slots/proj/1
  git -C "${primary:?}" worktree add -q -b feat/T7-task "$wt"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["slots/proj/1"] }
TOML
  stub_script claude <<'EOF'
if [[ $* == "agents --json" ]]; then
  echo '[{"id": "4f2a9c1e", "name": "T7-builder", "pid": 4242}]'
  exit 0
fi
echo "Started background session 4f2a9c1e (T7-builder). Attach with: claude attach 4f2a9c1e"
EOF
  fake_process 4242 1 - claude --bg
  capacity_room $((16 * 1073741824))
  jq -cn --arg wt "$wt" '{ts: (now | todate), task: "T7", event: "thread", discord_thread: "1563"},
    {ts: (now | todate), task: "T7", event: "opened", project: "proj", path: "feature", type: "feat", title: "A task",
      branch: "feat/T7-task", base: "main", base_sha: "0123456", worktree: $wt},
    {ts: (now | todate), task: "T7", event: "plan-approved", by: "coordinator"}' >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-worker T7 builder "$wt" -- go
  assert_equal "$(jq -c .statusLine "$TEAM_HOME/tasks/T7/settings.builder.proj.json")" \
    "$(jq -cn --arg code "$REPO_ROOT" '{type: "command", command: "\($code)/bin/team-quota line", padding: 0}')"
}
