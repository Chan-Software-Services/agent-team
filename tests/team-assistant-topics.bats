#!/usr/bin/env bats
# team-assistant thread --close: the assistant closes a topic, recorded in the team home's
# assistant/topics.jsonl (committed and pushed), and its thread is archived under bin/lib/threads.sh's
# rule, now or by the heartbeat's team-thread archive, on the fake Discord of helpers/discord-threads.

load helpers/common
load helpers/discord-threads

DAY=86400
TOPIC=1571000000000000001

setup() {
  sandbox
  threads_discord
  waiting '[]'
  origin=$(make_team_home home-pc)
}

# The closes recorded, each without its time.
topics() {
  jq -c 'del(.ts)' "$TEAM_HOME/assistant/topics.jsonl"
}

@test "closing a quiet topic records it, pushes the record and archives its thread" {
  thread "$TOPIC" "$ASSISTANT" "The doctor's slow line" $((2 * DAY))
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-assistant thread --close "$TOPIC"
  assert_equal "$output" "closed $TOPIC; archived its thread"
  assert_equal "$stderr" ""
  assert_equal "$(topics)" "{\"thread\":\"$TOPIC\",\"event\":\"closed\",\"by\":\"assistant\"}"
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$TEAM_HOME/assistant/topics.jsonl"
  assert_equal "$(git -C "${origin:?}" log -1 --format=%s dev)" "chore: topic $TOPIC closed"
  assert_equal "$(git -C "${origin:?}" show dev:assistant/topics.jsonl)" "$(cat "$TEAM_HOME/assistant/topics.jsonl")"
  assert_equal "$(archived_threads)" "$TOPIC"
}

@test "a topic with its last message under a day old, or an item of waiting.md in it, stays in view until the heartbeat's pass" {
  thread "$TOPIC" "$ASSISTANT" "Release" 3600
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-assistant thread --close "$TOPIC"
  assert_equal "$output" "closed $TOPIC; its thread stays in view: its last message is 1 h old, under a day; the heartbeat archives it once the rule allows (team-thread archive)"
  assert_equal "$(archived_threads)" ""

  # A second close records nothing more; the item of waiting.md in it keeps it.
  thread "$TOPIC" "$ASSISTANT" "Release" $((2 * DAY))
  waiting "[{\"n\": 4, \"key\": \"note a\", \"kind\": \"note\", \"task\": \"-\", \"id\": \"a\", \"where\": \"$TOPIC\", \"list\": \"assistant\"}]"
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-assistant thread --close "$TOPIC"
  assert_equal "$output" "closed $TOPIC already; its thread stays in view: item 4 of waiting.md waits on Daniel in it; the heartbeat archives it once the rule allows (team-thread archive)"
  assert_equal "$(topics | wc -l)" "1"

  # Once the item is gone the heartbeat's pass archives it.
  waiting '[]'
  run_bin -0 team-thread archive
  assert_equal "$output" "archived $TOPIC the assistant's topic: Release"
}

@test "a thread that is not under #assistant, or that Discord cannot read, is refused, recording nothing" {
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · x" $((2 * DAY))
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant thread --close 1563000000000000701
  assert_equal "$stderr" "team-assistant: 1563000000000000701 is no thread under #assistant ($ASSISTANT), so it is no topic of the assistant's"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant thread --close 1571000000000000999
  assert_equal "$stderr" "team-assistant: cannot read the thread 1571000000000000999 from Discord: curl: (22) The requested URL returned error: 404"
  [[ ! -e $TEAM_HOME/assistant/topics.jsonl ]]
  assert_equal "$(archived_threads)" ""
}

@test "a thread under #assistant that the bot did not open is no topic: refused, recording nothing and archiving nothing" {
  thread "$TOPIC" "$ASSISTANT" "Daniel's own thread" $((2 * DAY)) 1561000000000000009
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant thread --close "$TOPIC"
  assert_equal "$stderr" "team-assistant: $TOPIC was opened by user 1561000000000000009, not by the bot ($BOT), so it is no topic of the assistant's"
  [[ ! -e $TEAM_HOME/assistant/topics.jsonl ]]
  assert_equal "$(archived_threads)" ""
  assert_equal "$(stub_calls curl | grep -c PATCH || true)" "0"
}

@test "closing is the assistant's alone, refused on a fenced machine, and takes one thread id" {
  thread "$TOPIC" "$ASSISTANT" "Release" $((2 * DAY))
  run_bin -1 --separate-stderr team-assistant thread --close "$TOPIC"
  assert_equal "$stderr" "team-assistant: thread is the assistant's alone: it opens and closes the assistant's topic threads under #assistant"
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant thread --close "$TOPIC"
  assert_equal "$stderr" "team-assistant: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine closes no topic: the assistant on the holder does"
  rm "$HOME/.local/state/agent-team/fenced"
  for args in "--close" "--close x" "--close $TOPIC $TOPIC"; do
    # shellcheck disable=SC2086 # each form's words
    AGENT_TEAM_ROLE=assistant run_bin -2 team-assistant thread $args
  done
  [[ ! -e $TEAM_HOME/assistant/topics.jsonl ]]
  assert_equal "$(archived_threads)" ""
}
