#!/usr/bin/env bats
# team-assistant: the hand-offs between the assistant and the coordinator, each a file in the team
# home's assistant/handoffs/ and a line of assistant/handoffs.jsonl, logged on the task it names,
# committed and pushed; Daniel's word held to their own unedited message in #assistant or a thread
# under it, read from Discord; and the assistant's topic threads under #assistant.

load helpers/common

ASSISTANT=1570965039278596199
COORDINATOR=1562486564871995482
THREAD=1571000000000000001
OTHER_THREAD=1571000000000000002
DANIEL=1571000000000000100

setup() {
  sandbox
  export TEAM_ASSISTANT_CHANNEL=$ASSISTANT
  cp "$REPO_ROOT/tests/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  cat >"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-10-01T10:00:00Z","task":"T7","event":"opened","project":"agent-team","path":"feature","type":"feat","title":"x","branch":"feat/T7-x","base":"dev","base_sha":"0123456","worktree":"/w/7"}
LEDGER
  echo '{"dmPolicy": "allowlist", "allowFrom": ["757"], "groups": {}, "pending": {}}' \
    >"$HOME/.claude/channels/discord/access.json"
  origin=$(make_team_home home-pc)
  discord=$BATS_TEST_TMPDIR/discord
  mkdir -p "$discord"
  export DISCORD_DIR=$discord
  stub_discord
  channel "$THREAD" "$ASSISTANT"
  channel "$OTHER_THREAD" 1562000000000000999
  message "$THREAD" "$DANIEL" 757 $'Open a task for the doctor\'s slow line.\n  Queue it.  '
  body=$BATS_TEST_TMPDIR/body.md
  printf 'Project: agent-team\nWhen: queue\nModel: opus\n\nThe doctor takes 40 s on its docker line.\n' >"$body"
}

# The fake Discord API: GET channels/<c>/messages/<m> answers $DISCORD_DIR/<c>-<m>.json, GET
# channels/<c> answers $DISCORD_DIR/channel-<c>.json, and a POST of a thread answers a new
# thread's id, 1571000000000000777, unless $DISCORD_DIR/refuse exists; anything else fails as
# curl -f does on a 404.
stub_discord() {
  stub_script curl <<'EOF'
cat >>"$DISCORD_DIR/stdin"
url=${*: -1}
if [[ $url =~ ^https://discord\.com/api/v10/channels/[0-9]+(/messages/[0-9]+)?/threads$ ]]; then
  if [[ -e $DISCORD_DIR/refuse ]]; then
    echo "curl: (22) The requested URL returned error: 403" >&2
    exit 22
  fi
  echo '{"id": "1571000000000000777", "type": 11}'
elif [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)/messages/([0-9]+)$ &&
  -f $DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json ]]; then
  cat "$DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"
elif [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)$ && -f $DISCORD_DIR/channel-${BASH_REMATCH[1]}.json ]]; then
  cat "$DISCORD_DIR/channel-${BASH_REMATCH[1]}.json"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
EOF
}

# Thread <id> under channel <parent>: channel <id> <parent>
channel() {
  jq -n --arg id "$1" --arg p "$2" '{id: $id, type: 11, parent_id: $p}' >"$discord/channel-$1.json"
}

# Message <id> in channel <channel> by author <author id>, saying <content>:
# message <channel> <id> <author> <content>
message() {
  jq -n --arg c "$1" --arg id "$2" --arg a "$3" --arg text "$4" \
    '{id: $id, channel_id: $c, content: $text, author: {id: $a, username: "daniel"}, edited_timestamp: null}' \
    >"$discord/$1-$2.json"
}

# The ledger's events after the setup's, without their ts.
logged() {
  tail -n +2 "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)'
}

# The hand-off log's lines, without their ts.
handoffs() {
  jq -c 'del(.ts)' "$TEAM_HOME/assistant/handoffs.jsonl"
}

# Hand-off file <n>, its sent time and its answer's time written as <ts>.
handoff_file() {
  sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<ts>/' "$TEAM_HOME/assistant/handoffs/H$1.md"
}

# The commits on origin's dev since the team home's start, newest first, as subject and files.
pushed() {
  git -C "$origin" log --format='%s' --name-only dev -- | sed '/^$/d' | sed '/^chore: start the team home$/,$d'
}

# The team home's state: its tree, its index and its commits, for a refusal that writes nothing.
records_state() {
  { git -C "$TEAM_HOME" status --porcelain --untracked-files=all; git -C "$TEAM_HOME" rev-parse HEAD
    cat "$TEAM_HOME/ledger.jsonl"; } | sha256sum
}

@test "the assistant's note is a file and a log line, committed and pushed, printing its id and path" {
  printf 'The doctor line is slow.\n' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-assistant send note --file "$body"
  assert_equal "$output" "H1 assistant/handoffs/H1.md"
  assert_equal "$stderr" ""
  assert_equal "$(handoff_file 1)" "---
id: H1
kind: note
from: assistant
to: coordinator
sent: <ts>
---

The doctor line is slow."
  assert_equal "$(handoffs)" '{"id":"H1","event":"sent","kind":"note","from":"assistant","to":"coordinator"}'
  assert_equal "$(logged)" ""
  assert_equal "$(pushed)" "chore: handoff H1 note
assistant/handoffs.jsonl
assistant/handoffs/H1.md"
  assert_equal "$(stub_calls curl)" ""
  # The next hand-off takes the next number, the coordinator's to the assistant.
  printf 'Walk Daniel through the 1Password restore.\n' >"$body"
  run_bin -0 team-assistant send walkthrough --file "$body"
  assert_equal "$output" "H2 assistant/handoffs/H2.md"
  assert_equal "$(handoffs | tail -n 1)" '{"id":"H2","event":"sent","kind":"walkthrough","from":"coordinator","to":"assistant"}'
  assert_equal "$(head -n 5 "$TEAM_HOME/assistant/handoffs/H2.md" | tail -n 2)" "from: coordinator
to: assistant"
}

@test "a task hand-off holds Daniel's message read from a thread under #assistant, and one naming a task is logged on it" {
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-assistant send task --file "$body" \
    --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$output" "H1 assistant/handoffs/H1.md"
  assert_equal "$(handoff_file 1)" "---
id: H1
kind: task
from: assistant
to: coordinator
sent: <ts>
daniel_message: $DANIEL
daniel_channel: $THREAD
---

Project: agent-team
When: queue
Model: opus

The doctor takes 40 s on its docker line."
  assert_equal "$(handoffs)" "{\"id\":\"H1\",\"event\":\"sent\",\"kind\":\"task\",\"from\":\"assistant\",\"to\":\"coordinator\",\"daniel_message\":\"$DANIEL\",\"daniel_channel\":\"$THREAD\"}"
  # The thread is read to be under #assistant, then Daniel's message from it, the token on stdin.
  assert_equal "$(stub_calls curl | jq -r '.[-1]')" "https://discord.com/api/v10/channels/$THREAD
https://discord.com/api/v10/channels/$THREAD/messages/$DANIEL"
  [[ $(cat "$discord/stdin") == "Authorization: Bot $FAKE_DISCORD_TOKEN"* ]]
  # The thread is known to be the assistant's, for its Discord guard.
  assert_equal "$(cat "$HOME/.local/state/agent-team/assistant-threads")" "$THREAD"
  # A decision in #assistant itself, naming a task, is logged on that task and pushed with it.
  message "$ASSISTANT" 1571000000000000101 757 "Hold T7 until Monday."
  printf 'Daniel holds T7.\n' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant send decision --file "$body" --task T7 \
    --daniel 1571000000000000101 --channel "$ASSISTANT"
  assert_equal "$output" "H2 assistant/handoffs/H2.md"
  assert_equal "$(sed -n 7p "$TEAM_HOME/assistant/handoffs/H2.md")" "task: T7"
  assert_equal "$(logged)" '{"task":"T7","event":"handoff","id":"H2","kind":"decision","from":"assistant","state":"sent"}'
  assert_equal "$(pushed | head -n 4)" "chore: handoff H2 decision
assistant/handoffs.jsonl
assistant/handoffs/H2.md
ledger.jsonl"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "hand-offs are numbered from the log, one more than its highest" {
  mkdir -p "$TEAM_HOME/assistant"
  printf '%s\n' '{"ts":"2026-11-14T10:00:00Z","id":"H9","event":"sent","kind":"note","from":"assistant","to":"coordinator"}' \
    '{"ts":"2026-11-14T10:00:01Z","id":"H12","event":"sent","kind":"note","from":"coordinator","to":"assistant"}' \
    '{"ts":"2026-11-14T10:00:02Z","id":"H12","event":"answered","by":"assistant"}' >"$TEAM_HOME/assistant/handoffs.jsonl"
  run_bin -0 team-assistant send spike --file "$body"
  assert_equal "$output" "H13 assistant/handoffs/H13.md"
}

@test "a research hand-off names its report under assistant/research/" {
  mkdir -p "$TEAM_HOME/assistant/research"
  echo "# Findings" >"$TEAM_HOME/assistant/research/2026-11-14-doctor.md"
  printf 'The doctor is slow on docker info.\n' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant send research --file "$body" \
    --report "$TEAM_HOME/assistant/research/2026-11-14-doctor.md"
  assert_equal "$(sed -n 7p "$TEAM_HOME/assistant/handoffs/H1.md")" "report: assistant/research/2026-11-14-doctor.md"
  assert_equal "$(handoffs | jq -r .report)" "assistant/research/2026-11-14-doctor.md"
  # The report is committed with the hand-off.
  assert_equal "$(pushed)" "chore: handoff H1 research
assistant/handoffs.jsonl
assistant/handoffs/H1.md
assistant/research/2026-11-14-doctor.md"
  # Named relative to the team home, it is the same report.
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant send research --file "$body" \
    --report assistant/research/2026-11-14-doctor.md
  assert_equal "$(handoffs | tail -n 1 | jq -r .report)" "assistant/research/2026-11-14-doctor.md"
}

@test "a worker session is refused every form, writing and reading nothing" {
  local role before
  before=$(records_state)
  for role in planner builder reviewer ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 --separate-stderr team-assistant send note --file "$body"
    assert_contains "$stderr" "team-assistant: a"
    assert_contains "$stderr" " $role session cannot hand off: that is the assistant's and the coordinator's"
    AGENT_TEAM_ROLE=$role run_bin -1 --separate-stderr team-assistant list
    assert_contains "$stderr" "$role session cannot hand off"
  done
  AGENT_TEAM_ROLE=ops run_bin -1 --separate-stderr team-assistant list
  assert_equal "$stderr" "team-assistant: an ops session cannot hand off: that is the assistant's and the coordinator's"
  assert_equal "$(records_state)" "$before"
  assert_equal "$(stub_calls curl)" ""
}

@test "a kind not the sender's is refused, naming the sender's kinds" {
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send walkthrough --file "$body"
  assert_equal "$stderr" "team-assistant: the assistant sends task, decision, research or note, not walkthrough"
  run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: the coordinator sends walkthrough, spike or note, not task"
  [[ ! -e $TEAM_HOME/assistant ]]
}

@test "task and decision need Daniel's message, both its id and its channel" {
  local kind before
  before=$(records_state)
  for kind in task decision; do
    AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send "$kind" --file "$body"
    assert_equal "$stderr" "team-assistant: a $kind hand-off needs Daniel's own message: --daniel <message id> --channel <channel id>"
  done
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-assistant send decision --file "$body" --daniel "$DANIEL"
  assert_contains "$stderr" "--daniel and --channel go together"
  assert_equal "$(records_state)" "$before"
  assert_equal "$(stub_calls curl)" ""
}

@test "a message not Daniel's, edited, or outside #assistant and its threads is refused, writing nothing" {
  local before
  before=$(records_state)
  message "$THREAD" "$DANIEL" 999 "Open a task."
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: Discord message $DANIEL is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json"
  message "$THREAD" "$DANIEL" 757 "Open a task."
  jq '.edited_timestamp = "2026-11-14T10:05:00+00:00"' "$discord/$THREAD-$DANIEL.json" >"$discord/edited.json"
  mv "$discord/edited.json" "$discord/$THREAD-$DANIEL.json"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: Discord message $DANIEL was edited at 2026-11-14T10:05:00+00:00, so its text may not be what Daniel first sent: ask them to say it again as a new message"
  message "$OTHER_THREAD" "$DANIEL" 757 "Open a task."
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$OTHER_THREAD"
  assert_equal "$stderr" "team-assistant: channel $OTHER_THREAD is neither #assistant ($ASSISTANT) nor a thread under it, so Daniel's word there is not for the assistant"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$COORDINATOR"
  assert_equal "$stderr" "team-assistant: channel $COORDINATOR cannot be read from Discord, so it is not known to be under #assistant ($ASSISTANT): curl: (22) The requested URL returned error: 404"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel 1571000000000000999 --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: Discord message 1571000000000000999 cannot be fetched from the #assistant thread $THREAD: curl: (22) The requested URL returned error: 404"
  TEAM_ASSISTANT_CHANNEL='' AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: no assistant channel is set (TEAM_ASSISTANT_CHANNEL is empty), so Daniel's word cannot be held to #assistant"
  assert_equal "$(records_state)" "$before"
  # No thread but the one under #assistant is known to be the assistant's.
  [[ ! -e $HOME/.local/state/agent-team/assistant-threads ]] || ! grep -qvx "$THREAD" "$HOME/.local/state/agent-team/assistant-threads"
}

@test "a task body needs its Project, When and Model lines, and a project the registry knows" {
  local before
  before=$(records_state)
  printf 'When: queue\nModel: opus\n' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: a task hand-off's body needs a line Project: <name>"
  printf 'Project: agent-team\nModel: opus\n' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: a task hand-off's body needs a line When: now or When: queue (queue when Daniel said neither)"
  printf 'Project: agent-team\nWhen: later\nModel: opus\n' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: a task hand-off's body needs a line When: now or When: queue (queue when Daniel said neither)"
  printf 'Project: agent-team\nWhen: now\n' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: a task hand-off's body needs a line Model: opus or Model: fable (fable only on Daniel's word)"
  printf 'Project: nowhere\nWhen: now\nModel: fable\n' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_equal "$stderr" "team-assistant: project 'nowhere' is not registered (team-project --list: conventioner, agent-team, no-mistakes)"
  assert_equal "$(records_state)" "$before"
  assert_equal "$(stub_calls curl)" ""
}

@test "research needs its report, a file under the team home's assistant/research/" {
  local before
  mkdir -p "$TEAM_HOME/assistant/research" "$TEAM_HOME/assistant/other"
  echo x >"$TEAM_HOME/assistant/other/r.md"
  echo x >"$BATS_TEST_TMPDIR/r.md"
  before=$(records_state)
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send research --file "$body"
  assert_equal "$stderr" "team-assistant: a research hand-off needs its report: --report <a file under assistant/research/>"
  for report in "$BATS_TEST_TMPDIR/r.md" assistant/other/r.md assistant/research/../other/r.md assistant/research/none.md assistant/research; do
    AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send research --file "$body" --report "$report"
    assert_equal "$stderr" "team-assistant: the report '$report' is not a file under the team home's assistant/research/"
  done
  assert_equal "$(records_state)" "$before"
}

@test "a body that is missing, empty, an image or holds an address the records refuse is refused" {
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send note --file "$BATS_TEST_TMPDIR/none.md"
  assert_equal "$stderr" "team-assistant: cannot read the body $BATS_TEST_TMPDIR/none.md"
  printf ' \n\n' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send note --file "$body"
  assert_equal "$stderr" "team-assistant: the body $body has no text"
  printf '\x89PNG\r\n\x1a\n0000' >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send note --file "$body"
  assert_equal "$stderr" "team-assistant: the body $body is an image (png), which the records never take: attach it from ~/.local/state/agent-team/assistant-files/ instead"
  printf 'Write to someone@%s.\n' "gmail.com" >"$body"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send note --file "$body"
  assert_equal "$stderr" "team-assistant: the body $body holds 1 email address at a public provider, which the records never take; give it without the address"
  [[ ! -e $TEAM_HOME/assistant ]]
}

@test "a task that is not open is refused" {
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send note --file "$body" --task T99
  assert_equal "$stderr" "team-assistant: T99 is not open: the ledger has no opened event for it"
  [[ ! -e $TEAM_HOME/assistant ]]
}

@test "a fenced machine, or one that lost the lease, hands nothing off and opens no thread" {
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  assert_contains "$stderr" "a fenced machine hands nothing off: the assistant and the coordinator on the holder do"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant thread "Doctor"
  assert_contains "$stderr" "a fenced machine opens no thread: the assistant on the holder does"
  # Reading stays open: a list and a show write nothing.
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant list
  rm "$HOME/.local/state/agent-team/fenced"
  "$REPO_ROOT/bin/team-lease" take >/dev/null
  make_machine laptop
  steal_lease laptop home-pc
  rm -f "$HOME/.local/state/agent-team/probe.json"
  run_bin -1 --separate-stderr team-assistant send note --file "$body"
  assert_contains "$stderr" "home-pc no longer holds the lease: origin names laptop"
  assert_contains "$stderr" "a machine that lost the lease hands nothing off"
  assert_equal "$(stub_calls curl)" ""
  [[ ! -e $TEAM_HOME/assistant ]]
}

@test "a push that fails keeps the commit for the next checkpoint, saying so, and the hand-off stands" {
  git -C "$TEAM_HOME" remote set-url origin "$BATS_TEST_TMPDIR/nowhere.git"
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-assistant send note --file "$body"
  assert_equal "$output" "H1 assistant/handoffs/H1.md"
  assert_contains "$stderr" "team-assistant: H1 is not on origin yet ("
  assert_contains "$stderr" "); the next checkpoint pushes it"
  assert_equal "$(git -C "$TEAM_HOME" log -1 --format=%s)" "chore: handoff H1 note"
}

@test "show prints the hand-off's state and file, and Daniel's message read again, verbatim" {
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  run_bin -0 --separate-stderr team-assistant show H1
  assert_equal "$(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<ts>/' <<<"$output")" "H1 task assistant->coordinator <ts> open

---
id: H1
kind: task
from: assistant
to: coordinator
sent: <ts>
daniel_message: $DANIEL
daniel_channel: $THREAD
---

Project: agent-team
When: queue
Model: opus

The doctor takes 40 s on its docker line.

Daniel's message $DANIEL in the #assistant thread $THREAD, verbatim:
Open a task for the doctor's slow line.
  Queue it.  "
  assert_equal "$stderr" ""
  # The assistant reads it too.
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant show H1
}

@test "show exits 1 when Daniel's message no longer reads as theirs and unedited" {
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  jq '.edited_timestamp = "2026-11-14T10:05:00+00:00" | .content = "Open it now."' "$discord/$THREAD-$DANIEL.json" >"$discord/edited.json"
  mv "$discord/edited.json" "$discord/$THREAD-$DANIEL.json"
  run_bin -1 --separate-stderr team-assistant show H1
  assert_contains "$output" "The doctor takes 40 s on its docker line."
  [[ $output != *"Open it now."* ]]
  assert_equal "$stderr" "team-assistant: Discord message $DANIEL was edited at 2026-11-14T10:05:00+00:00, so its text may not be what Daniel first sent: ask them to say it again as a new message"
  rm "$discord/$THREAD-$DANIEL.json"
  run_bin -1 --separate-stderr team-assistant show H1
  assert_equal "$stderr" "team-assistant: Discord message $DANIEL cannot be fetched from the #assistant thread $THREAD: curl: (22) The requested URL returned error: 404"
  run_bin -1 --separate-stderr team-assistant show H2
  assert_equal "$stderr" "team-assistant: no hand-off H2 in assistant/handoffs.jsonl"
}

@test "answer is the recipient's alone and once, appends the answer, logs it and its task" {
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant send task --file "$body" --daniel "$DANIEL" --channel "$THREAD"
  printf 'Queued as tasks/queued/doctor-slow-line.md.\n' >"$BATS_TEST_TMPDIR/answer.md"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant answer H1 --file "$BATS_TEST_TMPDIR/answer.md"
  assert_equal "$stderr" "team-assistant: H1 is the assistant's to the coordinator: only the coordinator answers it"
  run_bin -0 --separate-stderr team-assistant answer H1 --file "$BATS_TEST_TMPDIR/answer.md" --task T7
  assert_equal "$output" "H1 assistant/handoffs/H1.md"
  assert_equal "$stderr" ""
  assert_equal "$(handoff_file 1 | tail -n 6)" "The doctor takes 40 s on its docker line.

## Answer

<ts>, by the coordinator:
Queued as tasks/queued/doctor-slow-line.md."
  assert_equal "$(handoffs | tail -n 1)" '{"id":"H1","event":"answered","by":"coordinator","task":"T7"}'
  assert_equal "$(logged)" '{"task":"T7","event":"handoff","id":"H1","kind":"task","from":"assistant","state":"answered"}'
  assert_equal "$(pushed | head -n 4)" "chore: handoff H1 answered
assistant/handoffs.jsonl
assistant/handoffs/H1.md
ledger.jsonl"
  run_bin -1 --separate-stderr team-assistant answer H1 --file "$BATS_TEST_TMPDIR/answer.md"
  assert_contains "$stderr" "team-assistant: H1 was answered at "
  assert_contains "$stderr" " by the coordinator; a follow-up is a new hand-off (team-assistant send)"
  run_bin -0 team-assistant show H1
  assert_contains "${lines[0]}" " answered"
  # A hand-off that names a task is logged on it when answered, with no --task.
  printf 'Walk Daniel through the token.\n' >"$body"
  run_bin -0 team-assistant send walkthrough --file "$body" --task T7
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant answer H2 --file "$BATS_TEST_TMPDIR/answer.md"
  assert_equal "$(logged | tail -n 2)" '{"task":"T7","event":"handoff","id":"H2","kind":"walkthrough","from":"coordinator","state":"sent"}
{"task":"T7","event":"handoff","id":"H2","kind":"walkthrough","from":"coordinator","state":"answered"}'
  assert_equal "$(handoffs | tail -n 1)" '{"id":"H2","event":"answered","by":"assistant","task":"T7"}'
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "answer refuses an unknown hand-off, a fenced machine and a body with no text" {
  run_bin -0 team-assistant send spike --file "$body"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant answer H5 --file "$body"
  assert_equal "$stderr" "team-assistant: no hand-off H5 in assistant/handoffs.jsonl"
  : >"$BATS_TEST_TMPDIR/empty.md"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant answer H1 --file "$BATS_TEST_TMPDIR/empty.md"
  assert_equal "$stderr" "team-assistant: the body $BATS_TEST_TMPDIR/empty.md has no text"
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant answer H1 --file "$body"
  assert_contains "$stderr" "a fenced machine hands nothing off"
  assert_equal "$(handoffs | jq -r .event)" "sent"
}

@test "list prints every hand-off, filtered by --open and --to, and --json their objects" {
  mkdir -p "$TEAM_HOME/assistant"
  printf '%s\n' '{"ts":"2026-11-14T10:00:00Z","id":"H1","event":"sent","kind":"task","from":"assistant","to":"coordinator","daniel_message":"1","daniel_channel":"2"}' \
    '{"ts":"2026-11-14T10:01:00Z","id":"H2","event":"sent","kind":"walkthrough","from":"coordinator","to":"assistant","task":"T7"}' \
    '{"ts":"2026-11-14T10:02:00Z","id":"H3","event":"sent","kind":"note","from":"assistant","to":"coordinator"}' \
    '{"ts":"2026-11-14T10:03:00Z","id":"H1","event":"answered","by":"coordinator","task":"T8"}' >"$TEAM_HOME/assistant/handoffs.jsonl"
  run_bin -0 team-assistant list
  assert_equal "$output" "H1 task assistant->coordinator 2026-11-14T10:00:00Z answered
H2 walkthrough coordinator->assistant 2026-11-14T10:01:00Z open
H3 note assistant->coordinator 2026-11-14T10:02:00Z open"
  run_bin -0 team-assistant list --open
  assert_equal "$output" "H2 walkthrough coordinator->assistant 2026-11-14T10:01:00Z open
H3 note assistant->coordinator 2026-11-14T10:02:00Z open"
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant list --open --to coordinator
  assert_equal "$output" "H3 note assistant->coordinator 2026-11-14T10:02:00Z open"
  run_bin -0 team-assistant list --to assistant --json
  assert_equal "$output" '[{"id":"H2","kind":"walkthrough","from":"coordinator","to":"assistant","sent":"2026-11-14T10:01:00Z","answered":null,"task":"T7"}]'
  run_bin -0 team-assistant list --json
  assert_equal "$(jq -c '.[0]' <<<"$output")" '{"id":"H1","kind":"task","from":"assistant","to":"coordinator","sent":"2026-11-14T10:00:00Z","answered":"2026-11-14T10:03:00Z","task":"T8"}'
  # With no hand-off yet, nothing, or an empty list.
  rm "$TEAM_HOME/assistant/handoffs.jsonl"
  run_bin -0 team-assistant list
  assert_equal "$output" ""
  run_bin -0 team-assistant list --json
  assert_equal "$output" "[]"
  run_bin -2 team-assistant list --to daniel
  assert_contains "$output" "usage: team-assistant"
}

@test "thread opens a public thread under #assistant with a 7-day archive, records its id and prints it" {
  local name
  name=$(printf 'x%.0s' {1..120})
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-assistant thread "$name"
  assert_equal "$output" "1571000000000000777"
  assert_equal "$stderr" ""
  assert_equal "$(stub_calls curl | jq -r '.[-1]')" "https://discord.com/api/v10/channels/$ASSISTANT/threads"
  assert_equal "$(stub_calls curl | jq -r '.[index("-d") + 1]')" \
    "{\"name\":\"$(printf 'x%.0s' {1..100})\",\"type\":11,\"auto_archive_duration\":10080}"
  assert_equal "$(stub_calls curl | jq -c '.[:6]')" '["-fsS","-H","@-","-X","POST","-H"]'
  AGENT_TEAM_ROLE=assistant run_bin -0 team-assistant thread "The doctor's slow line" --from "$DANIEL"
  assert_equal "$(stub_calls curl | tail -n 1 | jq -r '.[-1]')" "https://discord.com/api/v10/channels/$ASSISTANT/messages/$DANIEL/threads"
  assert_equal "$(stub_calls curl | tail -n 1 | jq -r '.[index("-d") + 1]')" \
    '{"name":"The doctor'\''s slow line","auto_archive_duration":10080}'
  assert_equal "$(cat "$HOME/.local/state/agent-team/assistant-threads")" "1571000000000000777"
  [[ $(cat "$discord/stdin") == "Authorization: Bot $FAKE_DISCORD_TOKEN"* ]]
}

@test "thread is the assistant's alone, needs the channel, and says when Discord refuses" {
  run_bin -1 --separate-stderr team-assistant thread "Doctor"
  assert_equal "$stderr" "team-assistant: thread is the assistant's alone: it opens the assistant's topic threads under #assistant"
  AGENT_TEAM_ROLE=coordinator run_bin -1 team-assistant thread "Doctor"
  TEAM_ASSISTANT_CHANNEL='' AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant thread "Doctor"
  assert_equal "$stderr" "team-assistant: no assistant channel is set (TEAM_ASSISTANT_CHANNEL is empty), so no thread can open under #assistant"
  assert_equal "$(stub_calls curl)" ""
  touch "$discord/refuse"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-assistant thread "Doctor"
  assert_equal "$stderr" "team-assistant: Discord opened no thread under #assistant: curl: (22) The requested URL returned error: 403"
  [[ ! -e $HOME/.local/state/agent-team/assistant-threads ]]
}

@test "a malformed command line is a usage error, and nothing is read or written" {
  local args
  for args in "" "send" "send note" "send note --file" "send note --file x --task 7" "send note --file x --daniel 12 --channel x" "send note file x" \
    "show" "show 1" "show H0" "show H1 more" "answer H1" "answer H1 --file" "list --all" "thread" "thread ''" "thread \$'a\\nb'" \
    "thread x --from y" "frob"; do
    eval "AGENT_TEAM_ROLE=assistant run_bin -2 team-assistant $args"
    assert_contains "$output" "usage: team-assistant"
  done
  assert_equal "$(stub_calls curl)" ""
  [[ ! -e $TEAM_HOME/assistant ]]
}

@test "the hand-offs are records, which the code repository never holds" {
  local matched
  matched=$(printf '%s\0' assistant/handoffs/H1.md assistant/handoffs.jsonl assistant/current.md assistant.settings.json roles/assistant.md |
    TEAM_HOME=$TEAM_HOME bash -c 'source "$1/bin/lib/team.sh"; only_records' _ "$REPO_ROOT")
  assert_equal "$matched" "assistant/handoffs/H1.md
assistant/handoffs.jsonl
assistant/current.md"
}
