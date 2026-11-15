#!/usr/bin/env bats
# hooks/assistant-stop: the assistant's Stop hook keeps a turn open once with what it leaves
# unattended (its list's due items, the hand-offs open to it, a second session named assistant on
# this machine), or with "supervision is off" when a command of those fails, and passes with none
# or once the turn was kept open.

load helpers/common

setup() {
  sandbox
  export AGENT_TEAM_ROLE=assistant
  export TEAM_CURRENT_NOW=2026-11-15T12:00:00Z
  stub_reply claude '[]'
}

SELF=a5515700-0000-4000-8000-000000000000

# stop <exit> [<stop_hook_active>] [<session id>]: run the hook on a Stop event, as Claude Code
# sends it.
stop() {
  run_bin "$1" --separate-stderr hooks/assistant-stop \
    <<<"$(jq -cn --argjson active "${2:-false}" --arg session "${3-$SELF}" '{transcript_path: "/tmp/t.jsonl",
      cwd: "/home/x/agent-team-records", permission_mode: "bypassPermissions", hook_event_name: "Stop",
      stop_hook_active: $active} + (if $session == "" then {} else {session_id: $session} end)')"
}

# Log a hand-off <id> of <kind> from <from> to <to> in assistant/handoffs.jsonl, sent, and with
# answered, answered too.
handoff() {
  mkdir -p "$TEAM_HOME/assistant/handoffs"
  jq -cn --arg id "$1" --arg kind "$2" --arg from "$3" --arg to "$4" \
    '{ts: "2026-11-14T10:00:00Z", id: $id, event: "sent", kind: $kind, from: $from, to: $to}' \
    >>"$TEAM_HOME/assistant/handoffs.jsonl"
  [[ ${5:-} != answered ]] ||
    jq -cn --arg id "$1" '{ts: "2026-11-14T11:00:00Z", id: $id, event: "answered", by: "assistant"}' \
      >>"$TEAM_HOME/assistant/handoffs.jsonl"
}

# The id of an item line: the first 6 hex digits of the sha256 of the line without its "- ".
id_of() {
  printf '%s' "${1#- }" | sha256sum | cut -c1-6
}

# session <short id> <full id> <kind> <state> <startedAt>: one session named assistant as claude
# agents --json lists it.
session() {
  jq -cn --arg id "$1" --arg sid "$2" --arg kind "$3" --arg state "$4" --argjson started "$5" \
    '{kind: $kind, id: $id, sessionId: $sid, name: "assistant", status: "idle", state: $state, startedAt: $started, pid: 4242}'
}

reason() {
  jq -r .reason <<<"$output"
}

@test "--help prints the header" {
  run_bin -0 hooks/assistant-stop --help
  assert_contains "$output" "Stop hook for the assistant"
}

@test "with nothing unattended it prints nothing and passes, reading its list, its hand-offs and the session list" {
  # The coordinator's due item, a hand-off to the coordinator and one answered are not its own.
  mkdir -p "$TEAM_HOME/tasks"
  printf '%s\n' "# Current items" "- owe - not mine | 1563000000000000049 | review 2026-11-14 | added 2026-11-12T10:00:00Z" \
    >"$TEAM_HOME/tasks/current.md"
  mkdir -p "$TEAM_HOME/assistant"
  printf '%s\n' "# Assistant items" "- next - later | 1563000000000000047 | review 2026-11-18 | added 2026-11-15T10:00:00Z" \
    >"$TEAM_HOME/assistant/current.md"
  handoff H1 task assistant coordinator
  handoff H2 walkthrough coordinator assistant answered
  stub_reply claude "[$(session a5515700 "$SELF" background working 1762596000000),
    {\"id\": \"3169fcbd\", \"sessionId\": \"3169fcbd-1111\", \"name\": \"coordinator\", \"state\": \"working\"}]"
  stop -0
  assert_equal "$output$stderr" ""
  assert_equal "$(stub_calls claude)" '["agents","--json"]'
}

@test "it blocks once with each due item, each hand-off open to it and each twin, in that order" {
  mkdir -p "$TEAM_HOME/assistant"
  local past="- ask - which login for the docs host | 1563000000000000046 | review 2026-11-13 | added 2026-11-10T10:00:00Z"
  local today="- owe - the spike report | 1563000000000000047 | review 2026-11-15 | added 2026-11-12T10:00:00Z"
  local later="- next - later | 1563000000000000048 | review 2026-11-18 | added 2026-11-15T10:00:00Z"
  printf '%s\n' "# Assistant items" "$past" "$today" "$later" >"$TEAM_HOME/assistant/current.md"
  handoff H1 walkthrough coordinator assistant
  handoff H2 spike coordinator assistant answered
  handoff H3 note assistant coordinator
  handoff H4 spike coordinator assistant
  stub_reply claude "[$(session a5515700 "$SELF" background working 1762596000000),
    $(session 5e7b1c04 5e7b1c04-1111 background blocked 1762682400000),
    {\"kind\": \"interactive\", \"sessionId\": \"c0ffee00-2222\", \"name\": \"assistant\", \"status\": \"idle\", \"pid\": 5151}]"
  stop -0
  assert_equal "$stderr" ""
  assert_equal "$(jq -c 'keys' <<<"$output")" '["decision","reason"]'
  assert_equal "$(jq -r .decision <<<"$output")" block
  assert_equal "$(reason)" "Before this turn ends, attend to what is left:
Due on your list (team-current due), each done once it is done, or renewed with team-current renew <id> --review --reason <why>:
$(id_of "$past") ${past#- }
$(id_of "$today") ${today#- }
Hand-offs to you still open (team-assistant list --open --to assistant), each read with team-assistant show H<n>, run with Daniel in its thread and answered:
H1 walkthrough coordinator->assistant 2026-11-14T10:00:00Z open
H4 spike coordinator->assistant 2026-11-14T10:00:00Z open
Another session named assistant, a twin that hears #assistant beside you: tell Daniel in #assistant where it runs, and stop nothing yourself:
assistant 5e7b1c04 (background, blocked, started 2025-11-09T10:00:00Z) is a second session named assistant on this machine
assistant c0ffee00 (interactive, idle, started at an unknown time) is a second session named assistant on this machine
Act on each, then end the turn."
}

@test "each kind alone is the reason alone; a twin with no session id of its own names every assistant, each if it is not you" {
  mkdir -p "$TEAM_HOME/assistant"
  local today="- owe - the spike report | 1563000000000000047 | review 2026-11-15 | added 2026-11-12T10:00:00Z"
  printf '%s\n' "# Assistant items" "$today" >"$TEAM_HOME/assistant/current.md"
  stop -0
  assert_equal "$(reason)" "Before this turn ends, attend to what is left:
Due on your list (team-current due), each done once it is done, or renewed with team-current renew <id> --review --reason <why>:
$(id_of "$today") ${today#- }
Act on each, then end the turn."

  rm "$TEAM_HOME/assistant/current.md"
  handoff H1 walkthrough coordinator assistant
  stop -0
  assert_equal "$(reason)" "Before this turn ends, attend to what is left:
Hand-offs to you still open (team-assistant list --open --to assistant), each read with team-assistant show H<n>, run with Daniel in its thread and answered:
H1 walkthrough coordinator->assistant 2026-11-14T10:00:00Z open
Act on each, then end the turn."

  handoff H1 walkthrough coordinator assistant answered
  stub_reply claude "[$(session a5515700 "$SELF" background working 1762596000000),
    $(session 5e7b1c04 5e7b1c04-1111 background blocked 1762682400000)]"
  CLAUDE_CODE_SESSION_ID='' stop -0 false ''
  assert_equal "$(reason)" "Before this turn ends, attend to what is left:
Another session named assistant, a twin that hears #assistant beside you: tell Daniel in #assistant where it runs, and stop nothing yourself:
assistant a5515700 (background, working, started 2025-11-08T10:00:00Z) is one of 2 sessions named assistant on this machine, if it is not you
assistant 5e7b1c04 (background, blocked, started 2025-11-09T10:00:00Z) is one of 2 sessions named assistant on this machine, if it is not you
Act on each, then end the turn."
  # With no session id in the event, CLAUDE_CODE_SESSION_ID is its own.
  CLAUDE_CODE_SESSION_ID=$SELF stop -0 false ''
  assert_equal "$(reason | sed -n 3p)" \
    "assistant 5e7b1c04 (background, blocked, started 2025-11-09T10:00:00Z) is a second session named assistant on this machine"
  # A single assistant, its own or not, is no twin.
  stub_reply claude "[$(session 5e7b1c04 5e7b1c04-1111 background blocked 1762682400000)]"
  stop -0
  assert_equal "$output" ""
}

@test "with stop_hook_active it passes at once, reading nothing" {
  mkdir -p "$TEAM_HOME/assistant"
  printf '%s\n' "# Assistant items" "- owe - due | 1563000000000000047 | review 2026-11-15 | added 2026-11-12T10:00:00Z" \
    >"$TEAM_HOME/assistant/current.md"
  stop -0 true
  assert_equal "$output$stderr" ""
  assert_equal "$(stub_calls claude)" ""
}

@test "a command that fails blocks once with supervision is off and why" {
  local tail="Find out why and fix it, or tell Daniel in #assistant; meanwhile check your list (team-current list),
your hand-offs (team-assistant list --open) and ListAgents by hand, then end the turn."
  TEAM_CURRENT_NOW=yesterday stop -0
  assert_equal "$(jq -r .decision <<<"$output")" block
  assert_equal "$(reason)" "supervision is off: team-current due --list assistant failed: team-current: TEAM_CURRENT_NOW \"yesterday\" is not a UTC time as 2026-11-15T10:00:00Z
$tail"
  # team-assistant refuses any role but the assistant's and the coordinator's.
  AGENT_TEAM_ROLE=planner stop -0
  assert_equal "$(reason)" "supervision is off: team-assistant list --open --to assistant failed: team-assistant: a planner session cannot hand off: that is the assistant's and the coordinator's
$tail"
  stub_script claude <<<'echo "cannot reach the daemon" >&2; exit 1'
  stop -0
  assert_equal "$(reason)" "supervision is off: cannot read the live session list (claude agents --json): cannot reach the daemon
$tail"
  stub_script claude <<<'echo "{}"'
  stop -0
  assert_equal "$(reason)" "supervision is off: cannot read the live session list (claude agents --json)
$tail"
  # A session list that hangs is stopped long before the hook's own timeout, which blocks nothing.
  stub_script claude <<<'exec 3>&-; command -p sleep 30'
  local start=$SECONDS
  TEAM_ASSISTANT_STOP_LIST_SECONDS=1 stop -0
  ((SECONDS - start < 15))
  assert_equal "$(reason)" "supervision is off: the live session list (claude agents --json) did not answer in 1 s
$tail"
  grep -q '^LIST_SECONDS=${TEAM_ASSISTANT_STOP_LIST_SECONDS:-30}$' "$REPO_ROOT/bin/hooks/assistant-stop"
}

@test "assistant.settings.json wires the hook on Stop, with its timeout, and no other settings file mentions it" {
  assert_equal "$(jq -c '.hooks.Stop' "$REPO_ROOT/assistant.settings.json")" \
    '[{"hooks":[{"type":"command","command":"\"@TEAM_CODE@/bin/hooks/assistant-stop\"","timeout":120}]}]'
  local file
  for file in "$REPO_ROOT"/settings/*.json "$REPO_ROOT/coordinator.settings.json"; do
    if grep -n assistant-stop "$file"; then
      echo "$file wires assistant-stop" >&2
      return 1
    fi
  done
}

@test "the assistant's role prompt says to act on each Stop finding, naming each kind and the supervision-off case" {
  local role=$REPO_ROOT/roles/assistant.md
  grep -qxF -- "- A Stop hook keeps your turn open once when it ends with something unattended: an item of your list that is due, a hand-off to you still open, or a twin, a second session named assistant on this machine." "$role"
  grep -qxF -- "- Act on each finding before you end the turn: \`done\` or renew the item, run the hand-off with Daniel in its thread and answer it, and tell Daniel of the twin in \`#assistant\`, stopping nothing yourself." "$role"
  grep -qxF -- "- When the Stop hook says supervision is off, find out why from what it names, and tell Daniel in \`#assistant\` when you cannot fix it." "$role"
}
