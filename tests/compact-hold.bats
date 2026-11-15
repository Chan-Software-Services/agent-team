#!/usr/bin/env bats
# hooks/compact-hold: the coordinator's auto-compaction waits for its stow. The real hook runs on
# each event's JSON as Claude Code sends it, and the real team-stowed with CLAUDE_CODE_SESSION_ID
# set; a record's times are written into the past to stand in for waiting.

load helpers/common

session=3169fcbd-0000-4000-8000-000000000000

setup() {
  sandbox
  state=$HOME/.local/state/agent-team
  record=$state/compact-hold/$session.json
  log=$state/compact-hold.log
  transcript=$BATS_TEST_TMPDIR/transcript.jsonl
}

# event <status> <hook event name> [<jq object of more fields>]: run the hook on that event.
event() {
  run_bin "$1" --separate-stderr hooks/compact-hold \
    <<<"$(jq -cn --arg name "$2" --arg session "$session" --arg transcript "$transcript" --argjson more "${3:-{\}}" \
      '{session_id: $session, transcript_path: $transcript, cwd: "/home/x/agent-team", hook_event_name: $name} + $more')"
}

auto() { event "$1" PreCompact '{"trigger": "auto", "custom_instructions": null}'; }
manual() { event "$1" PreCompact '{"trigger": "manual", "custom_instructions": ""}'; }
tool() { event -0 PostToolUse '{"tool_name": "Bash", "tool_input": {"command": "true"}, "tool_response": {}}'; }
prompt() { event -0 UserPromptSubmit '{"prompt": "next"}'; }
# turn_end [<stop_hook_active>]: the turn ends, kept open once already or not (the default).
turn_end() { event -0 Stop '{"stop_hook_active": '"${1:-false}"'}'; }

# told_text <the record's told_at>: the tell, and a reminder that is the first tell of its hold.
told_text() {
  echo "compact-hold: an auto-compaction of this conversation is held until you stow. Run the stow skill now, walking the conversation since your last stow, and end it with team-stowed, which lets the compaction run. Unstowed, it runs anyway at $(clock "$(($1 + 900))") UTC, 15 minutes from now."
}

# reminded_text <the record's told_at>: a reminder of a hold told before it.
reminded_text() {
  echo "compact-hold: an auto-compaction of this conversation is held until you stow. Run the stow skill now, walking the conversation since your last stow, and end it with team-stowed, which lets the compaction run. Unstowed, it runs anyway from $(clock "$(($1 + 900))") UTC, 15 minutes after you were first told."
}

stowed_now() {
  CLAUDE_CODE_SESSION_ID=$session run_bin -0 team-stowed
}

# age <jq assignment>...: rewrite the record, $now being the time in epoch seconds, which it
# keeps as aged_at.
age() {
  local program
  program=$(IFS='|'; echo "$*")
  aged_at=$(date +%s)
  jq -c --argjson now "$aged_at" "$program" "$record" >"$record.aged"
  mv "$record.aged" "$record"
}

# at_aged <command>...: run it with the hook's clock at the last age's time, for a case one
# second short of a limit, which a second passing between the two would carry over it.
at_aged() { TEAM_COMPACT_HOLD_NOW=$aged_at "$@"; }

# The log's events, one "<event>" or "<event> <why>" per line.
logged() {
  [[ ! -e $log ]] || jq -r '[.event, .why // empty] | join(" ")' "$log"
}

# clock <epoch seconds>: HH:MM in UTC.
clock() {
  date -u -d "@$1" +%H:%M
}

held_text="compact-hold: this auto-compaction waits for the coordinator's stow (team-stowed lets it run)"
keep="every promise made to Daniel; and each open task's id with what it waits on."

stowed_text() {
  echo "The coordinator stowed at $(clock "$(jq .stowed_at "$record")") UTC (team-stowed), so the disk holds its decisions up to then. Keep in this summary, word for word: every decision or answer Daniel gave after that time, with its Discord message id; $keep"
}

unstowed_text() {
  echo "The coordinator did not stow before this compaction ($1). Keep in this summary, word for word: every decision or answer Daniel gave in this conversation, with its Discord message id; $keep Begin the next turn by running the stow skill on what this summary holds."
}

# reply <tokens>: the transcript's latest main-conversation reply read that many tokens, a third
# each of input, cache writes and cache reads, with a larger sidechain reply after it.
reply() {
  jq -cn --argjson third "$(($1 / 3))" '{type: "assistant", message: {usage: {input_tokens: 1, cache_read_input_tokens: 5}}},
    {type: "assistant", message: {usage: {input_tokens: $third, cache_creation_input_tokens: $third, cache_read_input_tokens: $third}}},
    {type: "user", message: {content: "next"}},
    {type: "assistant", isSidechain: true, message: {usage: {input_tokens: 900000}}}' >"$transcript"
}

@test "an auto-compaction is held, the coordinator is told once, and it runs after team-stowed with the stowed instructions" {
  auto -2
  assert_equal "$output" ""
  assert_equal "$stderr" "$held_text"
  assert_equal "$(jq -c '[.held_at != null, .told_at, .stowed_at, .released_at, .blocks]' "$record")" '[true,null,null,null,1]'

  tool
  assert_equal "$stderr" ""
  assert_equal "$(jq -c 'keys, (.hookSpecificOutput | keys)' <<<"$output")" '["hookSpecificOutput"]'$'\n''["additionalContext","hookEventName"]'
  assert_equal "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" PostToolUse
  assert_equal "$(jq -r .hookSpecificOutput.additionalContext <<<"$output")" "$(told_text "$(jq .told_at "$record")")"
  # Told once per hold: every later tool call prints nothing.
  tool
  assert_equal "$output$stderr" ""

  # Still held while unstowed, each block counted.
  auto -2
  assert_equal "$stderr" "$held_text"
  assert_equal "$(jq .blocks "$record")" 2

  stowed_now
  assert_equal "$output" "stowed at $(clock "$(jq .stowed_at "$record")") UTC; the held auto-compaction runs at its next check"
  tool
  assert_equal "$output$stderr" ""

  auto -0
  assert_equal "$stderr" ""
  assert_equal "$output" "$(stowed_text)"
  assert_equal "$(jq -c '[.held_at, .told_at, .stowed_at != null, .released_at != null]' "$record")" '[null,null,true,true]'
  assert_equal "$(logged)" $'held\ntold\nstowed\nreleased stowed'
  assert_equal "$(jq -sc 'map(keys) | unique' "$log")" '[["at","event","session"],["at","event","session","why"]]'
  assert_equal "$(jq -r 'select(.session != "'"$session"'" or (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$") | not)) | .event' "$log")" ""
}

@test "a stow less than 10 minutes old lets the first auto-compaction run, and an older one does not" {
  stowed_now
  assert_equal "$output" "stowed at $(clock "$(jq .stowed_at "$record")") UTC; no auto-compaction is held"
  age '.stowed_at = $now - 599'
  at_aged auto -0
  assert_equal "$output" "$(stowed_text)"
  assert_equal "$(jq -c '[.held_at, .blocks]' "$record")" '[null,0]'
  assert_equal "$(logged)" stowed

  age '.stowed_at = $now - 600'
  auto -2
  assert_equal "$stderr" "$held_text"
  assert_equal "$(logged)" $'stowed\nheld'
  # A stow before the hold began does not release it, and the coordinator is still told.
  auto -2
  tool
  assert_contains "$output" "held until you stow"
}

@test "a told hold 15 minutes old runs with the unstowed instructions, and an untold one never times out" {
  auto -2
  age '.held_at = $now - 7200'
  auto -2
  tool
  age '.told_at = $now - 899'
  at_aged auto -2
  assert_equal "$(jq .blocks "$record")" 3
  age '.told_at = $now - 900'
  auto -0
  assert_equal "$stderr" ""
  assert_equal "$output" "$(unstowed_text "it was held 15 minutes after the tell")"
  assert_equal "$(jq -c '[.held_at, .told_at, .released_at != null]' "$record")" '[null,null,true]'
  assert_equal "$(logged)" $'held\ntold\nreleased timeout'
}

@test "a hold whose conversation's last reply read 300k tokens runs with the unstowed instructions" {
  reply 299997
  auto -2
  auto -2
  reply 300000
  auto -0
  assert_equal "$output" "$(unstowed_text "the conversation reached 300k tokens")"
  assert_equal "$(logged)" $'held\nreleased ceiling'
  # With no hold standing, the size alone lets nothing through: the next one is held.
  auto -2
  assert_equal "$(jq .blocks "$record")" 1
}

@test "a stowed hold at 300k tokens is released as stowed" {
  reply 300000
  auto -2
  stowed_now
  auto -0
  assert_equal "$output" "$(stowed_text)"
  assert_equal "$(logged)" $'held\nstowed\nreleased stowed'
}

@test "a manual compaction is never held and leaves the record as it is" {
  manual -0
  assert_equal "$stderr" ""
  assert_equal "$output" "$(unstowed_text "no stow was recorded")"
  [[ ! -e $record && ! -e $log ]]

  auto -2
  tool
  local before
  before=$(cat "$record")
  manual -0
  assert_equal "$output" "$(unstowed_text "no stow was recorded")"
  assert_equal "$(cat "$record")" "$before"

  # A stow standing since the last release gives the stowed instructions, the hold still standing.
  stowed_now
  before=$(cat "$record")
  manual -0
  assert_equal "$output" "$(stowed_text)"
  assert_equal "$(cat "$record")" "$before"

  # Once a release has used that stow, a manual compaction is unstowed again.
  auto -0
  age '.released_at = .stowed_at + 1'
  manual -0
  assert_equal "$output" "$(unstowed_text "no stow was recorded")"
  assert_equal "$(logged)" $'held\ntold\nstowed\nreleased stowed'
}

@test "a tool call with no hold standing, or after the stow, tells nothing" {
  tool
  assert_equal "$output$stderr" ""
  [[ ! -e $state/compact-hold ]]
  stowed_now
  tool
  assert_equal "$output$stderr" ""
  auto -0
  tool
  assert_equal "$output$stderr" ""
  assert_equal "$(logged)" stowed
}

@test "each prompt of a held, unstowed session reminds the coordinator, the first as the tell when no tool call told it" {
  auto -2
  prompt
  assert_equal "$stderr" ""
  assert_equal "$(jq -c 'keys, (.hookSpecificOutput | keys)' <<<"$output")" '["hookSpecificOutput"]'$'\n''["additionalContext","hookEventName"]'
  assert_equal "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" UserPromptSubmit
  # Untold until now, so the reminder is the tell and the 15 minutes run from it.
  local told
  told=$(jq .told_at "$record")
  assert_equal "$(jq -r .hookSpecificOutput.additionalContext <<<"$output")" "$(told_text "$told")"
  # A tool call tells nothing more, since the hold is told.
  tool
  assert_equal "$output$stderr" ""

  # Every later prompt reminds again, and the time it names stays the first tell's.
  age '.told_at = $now - 300'
  told=$(jq .told_at "$record")
  prompt
  assert_equal "$(jq -r .hookSpecificOutput.additionalContext <<<"$output")" "$(reminded_text "$told")"
  prompt
  assert_equal "$(jq -r .hookSpecificOutput.additionalContext <<<"$output")" "$(reminded_text "$told")"
  assert_equal "$(jq -c '[.told_at, .blocks]' "$record")" "[$told,1]"
  assert_equal "$(logged)" $'held\nreminded\nreminded\nreminded'
  assert_equal "$(jq -sc 'map(keys) | unique' "$log")" '[["at","event","session"]]'

  # A hold a tool call told is reminded too, and the reminder's 15 minutes still time it out.
  age '.told_at = $now - 900'
  auto -0
  assert_equal "$output" "$(unstowed_text "it was held 15 minutes after the tell")"
}

@test "a turn of a held, unstowed session cannot end without the reminder once" {
  auto -2
  tool
  local told before
  told=$(jq .told_at "$record")
  before=$(cat "$record")
  turn_end
  assert_equal "$stderr" ""
  assert_equal "$(jq -c 'keys' <<<"$output")" '["decision","reason"]'
  assert_equal "$(jq -r .decision <<<"$output")" block
  assert_equal "$(jq -r .reason <<<"$output")" "$(reminded_text "$told")"
  assert_equal "$(cat "$record")" "$before"
  assert_equal "$(logged)" $'held\ntold\nreminded'

  # Kept open once already, the turn ends: nothing printed, logged or written.
  turn_end true
  assert_equal "$output$stderr" ""
  assert_equal "$(cat "$record")" "$before"
  assert_equal "$(logged)" $'held\ntold\nreminded'

  # A Stop event that does not say is one not yet kept open.
  event -0 Stop
  assert_equal "$(jq -r .decision <<<"$output")" block
  assert_equal "$(logged)" $'held\ntold\nreminded\nreminded'
}

@test "a turn that ends on an untold hold is told by its reminder, whose 15 minutes then run" {
  auto -2
  turn_end
  local told
  told=$(jq .told_at "$record")
  [[ $told != null ]]
  assert_equal "$(jq -r .reason <<<"$output")" "$(told_text "$told")"
  tool
  assert_equal "$output$stderr" ""
  assert_equal "$(logged)" $'held\nreminded'
  age '.told_at = $now - 900'
  auto -0
  assert_equal "$(logged)" $'held\nreminded\nreleased timeout'
}

@test "a prompt or a turn's end with no hold standing, or after the stow, reminds nothing" {
  prompt
  assert_equal "$output$stderr" ""
  turn_end
  assert_equal "$output$stderr" ""
  [[ ! -e $state/compact-hold ]]

  # A stow with no hold, then a held compaction that is stowed, then its release.
  stowed_now
  prompt
  assert_equal "$output$stderr" ""
  turn_end
  assert_equal "$output$stderr" ""
  age '.stowed_at = $now - 600'
  auto -2
  stowed_now
  local before
  before=$(cat "$record")
  prompt
  assert_equal "$output$stderr" ""
  turn_end
  assert_equal "$output$stderr" ""
  assert_equal "$(cat "$record")" "$before"
  auto -0
  prompt
  assert_equal "$output$stderr" ""
  turn_end
  assert_equal "$output$stderr" ""
  assert_equal "$(logged)" $'stowed\nheld\nstowed\nreleased stowed'
}

@test "a reminder that cannot read its record fails without keeping the turn open" {
  auto -2
  echo 'not a record' >"$record"
  event -1 Stop '{"stop_hook_active": false}'
  assert_equal "$output" ""
  assert_contains "$stderr" "$record is not a compact-hold record"
  event -1 UserPromptSubmit '{"prompt": "next"}'
  assert_equal "$output" ""
}

@test "each session has its own hold" {
  auto -2
  local other=5e7b1c04-1111
  run_bin -2 --separate-stderr hooks/compact-hold \
    <<<"$(jq -cn --arg session "$other" '{session_id: $session, hook_event_name: "PreCompact", trigger: "auto"}')"
  assert_equal "$(jq -r '[.session, .event] | join(" ")' "$log")" "$session held"$'\n'"$other held"
  CLAUDE_CODE_SESSION_ID=$other run_bin -0 team-stowed
  auto -2
}

@test "the fast path reads no library: an event of a session with no record exits 0 from the hook alone" {
  local alone=$BATS_TEST_TMPDIR/alone/hooks name
  mkdir -p "$alone"
  link_shared compact-hold-alone "$REPO_ROOT/bin/hooks/compact-hold" "$alone/compact-hold"
  for name in PostToolUse UserPromptSubmit Stop; do
    run --separate-stderr "$alone/compact-hold" <<<"$(jq -cn --arg name "$name" --arg session "$session" '{session_id: $session, hook_event_name: $name}')"
    assert_equal "$status $output$stderr" "0 "
  done
  # Input that is no event, and an event with no session, cost no more.
  run --separate-stderr "$alone/compact-hold" <<<"not json"
  assert_equal "$status $output$stderr" "0 "
  run --separate-stderr "$alone/compact-hold" <<<'{"hook_event_name": "PostToolUse", "session_id": "../x"}'
  assert_equal "$status $output$stderr" "0 "
  # With a record, and for every PreCompact, it reads the library, which the copy lacks.
  auto -2
  run "$alone/compact-hold" <<<"$(jq -cn --arg session "$session" '{session_id: $session, hook_event_name: "PostToolUse"}')"
  assert_equal "$status" 1
  [[ ! -e $state/compact-hold/.json ]]
}

@test "a PreCompact with no usable session id runs with the unstowed instructions and writes nothing" {
  local id
  for id in '"../x"' '""' null 7; do
    run_bin -0 --separate-stderr hooks/compact-hold <<<"$(jq -cn --argjson id "$id" '{session_id: $id, hook_event_name: "PreCompact", trigger: "auto"}')"
    assert_equal "$output" "$(unstowed_text "no stow was recorded")"
  done
  [[ ! -e $state/compact-hold && ! -e $log ]]
}

@test "a failure of its own never exits 2, so a broken hold lets the compaction run" {
  auto -2
  echo 'not a record' >"$record"
  auto -1
  assert_equal "$output" ""
  assert_contains "$stderr" "$record is not a compact-hold record"
  # jq's own exit 2, a usage error, is no hold either.
  echo '{"held_at": 1, "told_at": null, "stowed_at": null, "released_at": null, "blocks": 1}' >"$record"
  ln "$(shared jq-exit-2 <<'STUB'
#!/usr/bin/env bash
# jq, but for the hold's decision, which exits 2 as jq does on a usage error.
[[ " $* " != *" context "* ]] || exit 2
PATH=${PATH//"${0%/*}:"/} exec jq "$@"
STUB
  )" "$BATS_TEST_TMPDIR/stubs/jq"
  auto -1
  assert_equal "$stderr" ""
  assert_equal "$output" ""
}

@test "any other event prints nothing, and an argument is a usage error" {
  auto -2
  event -0 SessionStart '{"source": "compact"}'
  assert_equal "$output$stderr" ""
  run_bin -2 hooks/compact-hold now </dev/null
  assert_equal "$output" "compact-hold: it takes no argument: the event's JSON comes on stdin"
}
