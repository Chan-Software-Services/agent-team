#!/usr/bin/env bats
# hooks/assistant-digest: the assistant's SessionStart hook prints, in order, the offline hold, a
# warning when its Discord state is not its own, its stow note, the hand-offs open to and from it,
# the catch-up step on #assistant and its threads, and on any start but a compaction the
# ListAgents call for an assistant twin. It exits 0 but when a command of its own fails.

load helpers/common

setup() {
  sandbox
  export TEAM_ASSISTANT_CHANNEL=1570965039278596199
  export DISCORD_STATE_DIR=$HOME/.claude/channels/discord-assistant
  export AGENT_TEAM_ROLE=assistant
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
}

# start [<exit>] [<source>]: run the hook on a SessionStart event, as Claude Code sends it.
start() {
  run_bin "${1:--0}" --separate-stderr hooks/assistant-digest \
    <<<"$(jq -cn --arg source "${2:-startup}" '{session_id: "a5515700-0000-4000-8000-000000000000",
      transcript_path: "/tmp/t.jsonl", cwd: "/home/x/agent-team-records", hook_event_name: "SessionStart",
      source: $source}')"
}

# Log a hand-off <id> of <kind> from <from> to <to> in assistant/handoffs.jsonl, sent or answered.
handoff() {
  mkdir -p "$TEAM_HOME/assistant/handoffs"
  jq -cn --arg id "$1" --arg kind "$2" --arg from "$3" --arg to "$4" \
    '{ts: "2026-11-14T10:00:00Z", id: $id, event: "sent", kind: $kind, from: $from, to: $to}' \
    >>"$TEAM_HOME/assistant/handoffs.jsonl"
  printf -- '---\nid: %s\n---\n\nbody\n' "$1" >"$TEAM_HOME/assistant/handoffs/$1.md"
  [[ ${5:-} != answered ]] ||
    jq -cn --arg id "$1" '{ts: "2026-11-14T11:00:00Z", id: $id, event: "answered", by: "coordinator"}' \
      >>"$TEAM_HOME/assistant/handoffs.jsonl"
}

# The catch-up step, naming the thread cache's ids <known> (none by default): catch_up_line [<known>]
catch_up_line() {
  echo "Catch up on Discord before anything else: messages sent while no assistant listened are never delivered to you, only readable. Read #assistant (1570965039278596199) and each thread of yours still open (your stow note's, and of the threads found so far: ${1:-none}) back to your own last message there with the Discord plugin's fetch_messages, which reads at most 100 messages, and answer first what Daniel asked that has no answer."
}

twin_line() {
  echo "Call ListAgents once now, since no script can list a Remote Control session: a row named assistant but this session (the one ListAgents says you are) is an assistant twin, which hears #assistant beside you. Tell Daniel in #assistant where it runs (this machine or Remote Control), and stop nothing yourself."
}

@test "--help prints the header" {
  run_bin -0 hooks/assistant-digest --help
  assert_contains "$output" "SessionStart hook for the assistant"
}

@test "with nothing open it prints the hand-offs line, the catch-up step and the twin step, in that order" {
  start
  assert_equal "$stderr" ""
  assert_equal "$output" "No hand-off is open to or from you (team-assistant list --open).
$(catch_up_line)
$(twin_line)"
}

@test "the catch-up step names the thread cache's ids itself, since the assistant's Bash may not read the file" {
  mkdir -p "$HOME/.local/state/agent-team"
  printf '%s\n' 1571000000000000101 1571000000000000202 >"$HOME/.local/state/agent-team/assistant-threads"
  start
  assert_equal "${lines[1]}" "$(catch_up_line "1571000000000000101, 1571000000000000202")"
}

@test "a compaction, which keeps the process, gets no twin step; a resume and a clear do" {
  start -0 compact
  assert_equal "$output" "No hand-off is open to or from you (team-assistant list --open).
$(catch_up_line)"
  local source
  for source in resume clear; do
    start -0 "$source"
    assert_equal "${lines[-1]}" "$(twin_line)"
  done
  # An event it cannot read is a start.
  run_bin -0 hooks/assistant-digest <<<"not json"
  assert_equal "${lines[-1]}" "$(twin_line)"
}

@test "it prints, in order, the hold, the state warning, the stow note, the open hand-offs, the catch-up and the twin step" {
  mkdir -p "$HOME/.local/state/agent-team" "$TEAM_HOME/assistant"
  echo '{"since": "2026-11-14T09:00:00Z"}' >"$HOME/.local/state/agent-team/offline"
  printf '# Stow note\n\n- topic thread 1570965039278596200 waits on Daniel'"'"'s yes\n' >"$TEAM_HOME/assistant/handoff.md"
  handoff H1 note assistant coordinator answered
  handoff H2 task assistant coordinator
  handoff H3 walkthrough coordinator assistant
  DISCORD_STATE_DIR=$HOME/.claude/channels/discord start
  assert_equal "$stderr" ""
  # The hold is offline_hold's assistant text, the one the lease-fence hook blocks with.
  assert_equal "$output" "GitHub is unreachable (since $(date -d 2026-11-14T09:00:00Z +%H:%M)); the team is holding: keep talking with Daniel, and touch no GitHub (no gh, gh-axi or git push) until your Bash calls stop being held.
WARNING: DISCORD_STATE_DIR is $HOME/.claude/channels/discord, not $HOME/.claude/channels/discord-assistant: the Discord plugin may be reading the coordinator's channels: post nothing, and tell Daniel in #coordinator through the coordinator (a note hand-off).
Your stow note, from your last stow ($TEAM_HOME/assistant/handoff.md): delete it once its work is done.
# Stow note

- topic thread 1570965039278596200 waits on Daniel's yes
The hand-offs open to and from you (team-assistant list --open); read each with team-assistant show H<n>:
H2 task assistant->coordinator 2026-11-14T10:00:00Z open
H3 walkthrough coordinator->assistant 2026-11-14T10:00:00Z open
$(catch_up_line)
$(twin_line)"
}

@test "an unset Discord state directory is warned of; the assistant's own, spelled with a trailing slash, is not" {
  unset DISCORD_STATE_DIR
  start
  assert_equal "${lines[0]}" "WARNING: DISCORD_STATE_DIR is unset, not $HOME/.claude/channels/discord-assistant: the Discord plugin may be reading the coordinator's channels: post nothing, and tell Daniel in #coordinator through the coordinator (a note hand-off)."
  DISCORD_STATE_DIR=$HOME/.claude/channels/discord-assistant/ start
  [[ $output != *WARNING* ]]
}

@test "a hand-off list that fails is said, and the digest goes on; exit 0" {
  # team-assistant refuses any role but the assistant's and the coordinator's.
  AGENT_TEAM_ROLE=planner start
  assert_equal "${lines[0]}" "team-assistant list --open failed (exit 1), so the open hand-offs are unknown: run it by hand. It said: team-assistant: a planner session cannot hand off: that is the assistant's and the coordinator's"
  assert_equal "${lines[-2]}" "$(catch_up_line)"
  assert_equal "${lines[-1]}" "$(twin_line)"
}

@test "assistant.settings.json wires the hook on SessionStart, with its timeout, and no other settings file mentions it" {
  assert_equal "$(jq -c '.hooks.SessionStart' "$REPO_ROOT/assistant.settings.json")" \
    '[{"hooks":[{"type":"command","command":"\"@TEAM_CODE@/bin/hooks/assistant-digest\"","timeout":120}]}]'
  local file
  for file in "$REPO_ROOT"/settings/*.json "$REPO_ROOT/coordinator.settings.json"; do
    if grep -n assistant-digest "$file"; then
      echo "$file wires assistant-digest" >&2
      return 1
    fi
  done
}
