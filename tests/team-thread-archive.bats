#!/usr/bin/env bats
# team-thread archive: the pass that archives the team's Discord threads whose work is done, under
# bin/lib/threads.sh's rule (waiting.json names nothing of the thread, and its last message is a
# day old), on a fake Discord (helpers/discord-threads). Each test writes waiting.json after the
# ledger, as team-inbox does, since one older than the ledger or a list archives nothing.

load helpers/common
load helpers/discord-threads

DAY=86400

setup() {
  sandbox
  threads_discord
}

# A ledger line: event <task> <kind> [<field json>]
event() {
  local more=${3:-'{}'}
  jq -cn --arg task "$1" --arg kind "$2" --argjson more "$more" \
    '{ts: "2026-11-01T10:00:00Z", task: $task, event: $kind} + $more' >>"$TEAM_HOME/ledger.jsonl"
}

# Task <task>'s thread <id> (and interview thread <interview> when given), the task closed under the
# rule, its closed naming them, unless <how> is old (a close from before it) or open (no close):
# task_threads <task> <how> <id> [<interview>]
task_threads() {
  event "$1" thread "{\"discord_thread\": \"$3\"}"
  [[ -z ${4:-} ]] || event "$1" interview-thread "{\"discord_thread\": \"$4\"}"
  case $2 in
    rule) event "$1" closed "$(jq -cn --args '{archive: [], returned: [], kept: [], threads: $ARGS.positional}' "$3" ${4:+"$4"})" ;;
    old) event "$1" closed '{"archive": [], "returned": [], "kept": []}' ;;
    open) ;;
  esac
}

# The assistant's topic <id>, closed with team-assistant thread --close: topic_closed <id>
topic_closed() {
  mkdir -p "$TEAM_HOME/assistant"
  jq -cn --arg id "$1" '{ts: "2026-11-01T10:00:00Z", thread: $id, event: "closed", by: "assistant"}' >>"$TEAM_HOME/assistant/topics.jsonl"
}

@test "a pass archives the threads of the closes under the rule and the closed topics the rule allows, and keeps the rest" {
  task_threads T7 rule 1563000000000000701 1563000000000000702
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · Done" $((2 * DAY))
  thread 1563000000000000702 "$INTERVIEW" "T7 · agent-team · Done" -
  # Its last message is two hours old: Daniel has had no day to read the closing post.
  task_threads T8 rule 1563000000000000801
  thread 1563000000000000801 "$COORDINATOR" "T8 · agent-team · Recent" 7200
  # An ask of T9 waits on Daniel, and T12's thread is where an owed reply points.
  task_threads T9 rule 1563000000000000901
  thread 1563000000000000901 "$COORDINATOR" "T9 · agent-team · Asked" $((3 * DAY))
  task_threads T12 rule 1563000000000001201
  thread 1563000000000001201 "$COORDINATOR" "T12 · agent-team · Owed" $((3 * DAY))
  # A close from before the rule, and an open task.
  task_threads T10 old 1563000000000001001
  thread 1563000000000001001 "$COORDINATOR" "T10 · agent-team · Old" $((30 * DAY))
  task_threads T11 open 1563000000000001101
  thread 1563000000000001101 "$COORDINATOR" "T11 · agent-team · Open" $((30 * DAY))
  # Topics: one closed and quiet, one closed with an item of waiting.md linking it, one still open.
  topic_closed 1571000000000000001
  thread 1571000000000000001 "$ASSISTANT" "The doctor's slow line" $((2 * DAY))
  topic_closed 1571000000000000002
  thread 1571000000000000002 "$ASSISTANT" "Release" $((2 * DAY))
  thread 1571000000000000003 "$ASSISTANT" "Still talking" $((2 * DAY))
  waiting '[{"n": 3, "key": "ask T9 plan x", "kind": "ask", "task": "T9", "id": "plan", "thread": "1563000000000000901", "message": "1"},
    {"n": 5, "key": "note abc", "kind": "note", "task": "-", "id": "abc", "where": "1571000000000000002", "list": "assistant",
     "line": "- **5** Assistant: release <https://discord.com/channels/1/1571000000000000002/9>"}]' \
    '[{"task": "-", "text": "the merged list", "where": "https://discord.com/channels/1/1563000000000001201/5", "list": "coordinator"}]'

  run_bin -0 --separate-stderr team-thread archive
  assert_equal "$output" "archived 1563000000000000701 T7's thread: T7 · agent-team · Done
archived 1563000000000000702 T7's interview thread: T7 · agent-team · Done
archived 1571000000000000001 the assistant's topic: The doctor's slow line"
  assert_equal "$stderr" ""
  assert_equal "$(archived_threads)" "1563000000000000701
1563000000000000702
1571000000000000001"
  # Nothing archived is listed again, and one read of the active threads serves the whole pass.
  run_bin -0 team-thread archive
  assert_equal "$output" ""
  assert_equal "$(stub_calls curl | jq -r 'select(.[-1] | endswith("/threads/active")) | .[-1]' | sort -u)" \
    "https://discord.com/api/v10/guilds/$GUILD/threads/active"
}

@test "a dry run archives nothing and says what it would archive and what it keeps, and --all adds the closes from before the rule" {
  task_threads T7 rule 1563000000000000701
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · Done" $((2 * DAY))
  task_threads T8 rule 1563000000000000801
  thread 1563000000000000801 "$COORDINATOR" "T8 · agent-team · Recent" 7200
  task_threads T10 old 1563000000000001001 1563000000000001002
  thread 1563000000000001001 "$COORDINATOR" "T10 · agent-team · Old" $((30 * DAY))
  thread 1563000000000001002 "$INTERVIEW" "T10 · agent-team · Old" $((30 * DAY))
  task_threads T11 open 1563000000000001101
  thread 1563000000000001101 "$COORDINATOR" "T11 · agent-team · Open" $((30 * DAY))
  waiting '[{"n": 2, "key": "note x", "kind": "note", "task": "T10", "id": "x", "where": "-", "list": "coordinator"}]'

  run_bin -0 --separate-stderr team-thread archive --dry-run
  assert_equal "$output" "would archive 1563000000000000701 T7's thread: T7 · agent-team · Done
keeps 1563000000000000801 T8's thread: its last message is 2 h old, under a day
would archive 1 thread, keeps 1"
  run_bin -0 --separate-stderr team-thread archive --all --dry-run
  assert_equal "$output" "would archive 1563000000000000701 T7's thread: T7 · agent-team · Done
keeps 1563000000000000801 T8's thread: its last message is 2 h old, under a day
keeps 1563000000000001001 T10's thread: item 2 of waiting.md waits on Daniel in it
keeps 1563000000000001002 T10's interview thread: item 2 of waiting.md waits on Daniel in it
would archive 1 thread, keeps 3"
  assert_equal "$(archived_threads)" ""
  assert_equal "$(stub_calls curl | grep -c PATCH)" "0"

  waiting '[]'
  run_bin -0 team-thread archive --all
  assert_equal "$output" "archived 1563000000000000701 T7's thread: T7 · agent-team · Done
archived 1563000000000001001 T10's thread: T10 · agent-team · Old
archived 1563000000000001002 T10's interview thread: T10 · agent-team · Old"
  # The open task's thread is never the pass's.
  [[ $(archived_threads) != *1563000000000001101* ]]
}

@test "a waiting.json that is missing or cannot be read archives nothing" {
  task_threads T7 rule 1563000000000000701
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · Done" $((2 * DAY))
  run_bin -1 --separate-stderr team-thread archive
  assert_equal "$stderr" "team-thread: archives no thread: there is no waiting.json, so what waits on Daniel is not known: team-inbox writes it"
  echo '{"schema": "team-waiting/0", "items": []}' >"$TEAM_HOME/waiting.json"
  run_bin -1 --separate-stderr team-thread archive
  assert_equal "$stderr" "team-thread: archives no thread: waiting.json cannot be read, so what waits on Daniel is not known: its schema is not team-waiting/1"
  echo '{' >"$TEAM_HOME/waiting.json"
  run_bin -1 --separate-stderr team-thread archive
  assert_contains "$stderr" "team-thread: archives no thread: waiting.json cannot be read, so what waits on Daniel is not known: "
  assert_equal "$(stub_calls curl)" ""
}

@test "a waiting.json older than the ledger or either list team-inbox reads archives nothing, and one as new does" {
  task_threads T7 rule 1563000000000000701
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · Done" $((2 * DAY))
  mkdir -p "$TEAM_HOME/tasks" "$TEAM_HOME/assistant"
  touch "$TEAM_HOME/tasks/current.md" "$TEAM_HOME/assistant/current.md"
  waiting '[]'
  touch -d '-1 minute' "$TEAM_HOME/waiting.json"
  touch -d '-2 minutes' "$TEAM_HOME/tasks/current.md" "$TEAM_HOME/assistant/current.md"
  run_bin -1 --separate-stderr team-thread archive
  assert_equal "$stderr" "team-thread: archives no thread: waiting.json is older than ledger.jsonl, so what waits on Daniel may have changed since it was written: team-inbox writes it afresh"
  touch -d '-2 minutes' "$TEAM_HOME/ledger.jsonl"
  for list in tasks/current.md assistant/current.md; do
    touch "$TEAM_HOME/$list"
    run_bin -1 --separate-stderr team-thread archive
    assert_equal "$stderr" "team-thread: archives no thread: waiting.json is older than $list, so what waits on Daniel may have changed since it was written: team-inbox writes it afresh"
    touch -d '-2 minutes' "$TEAM_HOME/$list"
  done
  assert_equal "$(archived_threads)" ""
  # A list written in the same clock tick as waiting.json is taken as read by it.
  touch -r "$TEAM_HOME/waiting.json" "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-thread archive
  assert_equal "$(archived_threads)" "1563000000000000701"
}

@test "a refused archive fails the pass after the rest, and a 429 is waited out" {
  task_threads T7 rule 1563000000000000701
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · Done" $((2 * DAY))
  task_threads T8 rule 1563000000000000801
  thread 1563000000000000801 "$COORDINATOR" "T8 · agent-team · Done" $((2 * DAY))
  waiting '[]'
  touch "$DISCORD_DIR/refuse-1563000000000000701" "$DISCORD_DIR/limit-1563000000000000801"
  run_bin -1 --separate-stderr team-thread archive
  assert_equal "$output" "archived 1563000000000000801 T8's thread: T8 · agent-team · Done"
  assert_equal "$stderr" "team-thread: could not archive 1563000000000000701 T7's thread: curl: (22) The requested URL returned error: 403"
  assert_equal "$(stub_calls curl | grep -c '"PATCH"')" "3"
}

@test "a Discord that cannot be read archives nothing, saying why" {
  task_threads T7 rule 1563000000000000701
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · Done" $((2 * DAY))
  waiting '[]'
  rm "$DISCORD_DIR/channel-$COORDINATOR.json"
  run_bin -1 --separate-stderr team-thread archive
  assert_equal "$stderr" "team-thread: cannot read #coordinator's guild from Discord: curl: (22) The requested URL returned error: 404"
  : >"$HOME/.claude/channels/discord/.env"
  run_bin -1 --separate-stderr team-thread archive
  assert_equal "$stderr" "team-thread: no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env"
  assert_equal "$(archived_threads)" ""
}

@test "a fenced machine archives nothing, and a worker session is refused" {
  task_threads T7 rule 1563000000000000701
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · Done" $((2 * DAY))
  local state=$HOME/.local/state/agent-team
  mkdir -p "$state"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$state/fenced"
  run_bin -1 --separate-stderr team-thread archive --dry-run
  assert_equal "$stderr" "team-thread: this machine is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine archives no thread; the coordinator on the holder does."
  assert_equal "$(stub_calls curl)" ""
  rm "$state/fenced"
  worker_refused team-thread "archives no Discord thread" archive
}

@test "archive takes only --all and --dry-run" {
  for args in "archive T7" "archive --now" "archive --all --frob"; do
    # shellcheck disable=SC2086 # each form's words
    run_bin -2 team-thread $args
    assert_contains "$output" "team-thread archive [--all] [--dry-run]"
  done
  assert_equal "$(stub_calls curl)" ""
}

@test "with no thread whose work is done, a pass asks Discord nothing and needs no waiting.json" {
  task_threads T11 open 1563000000000001101
  thread 1563000000000001101 "$COORDINATOR" "T11 · agent-team · Open" $((30 * DAY))
  run_bin -0 team-thread archive
  assert_equal "$output" ""
  run_bin -0 team-thread archive --all --dry-run
  assert_equal "$output" "would archive 0 threads, keeps 0"
  assert_equal "$(stub_calls curl)" ""
}
