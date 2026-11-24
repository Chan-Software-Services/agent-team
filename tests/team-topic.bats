#!/usr/bin/env bats
# team-topic: the assistant opens a topic task on Daniel's word, its thread under the topic
# channel, its plan, its brief and its T<n>-topic session, through the real team-open,
# team-thread, team-brief and team-worker, with Discord and claude stubbed.

load helpers/common

# #assistant, a thread under it where Daniel asked, and the topic channel.
ASSISTANT=1570965039278596199
ASKED_IN=1571000000000000001
TOPICS=1565336720998928556

setup() {
  sandbox
  # This machine, home-pc, holds the lease, so the topic's session may launch here.
  hold_lease home-pc >/dev/null
  primary=$(make_repo proj)
  echo ".scratch/" >"$primary/.gitignore"
  echo "# proj" >"$primary/CLAUDE.md"
  git -C "${primary:?}" add .gitignore CLAUDE.md
  git -C "${primary:?}" commit -q -m "chore: ignore scratch"
  git -C "${primary:?}" push -q origin main
  slots=$HOME/slots/proj
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

[proj.pool]
provider = "git"
slots = ["slots/proj/1", "slots/proj/2"]
TOML
  export TEAM_ASSISTANT_CHANNEL=$ASSISTANT TEAM_INTERVIEW_CHANNEL=$TOPICS DISCORD_DIR=$BATS_TEST_TMPDIR/discord
  unset TEAM_TOPIC_CHANNEL
  mkdir -p "$DISCORD_DIR"
  echo '{"dmPolicy": "allowlist", "allowFrom": ["757"], "groups": {}, "pending": {}}' \
    >"$HOME/.claude/channels/discord/access.json"
  # The fake Discord: GET channels/<c>/messages/<m> answers $DISCORD_DIR/<c>-<m>.json, GET
  # channels/<c> answers $DISCORD_DIR/channel-<c>.json, a POST of a thread answers a new id;
  # anything else fails as curl -f does on a 404.
  stub_script curl <<'STUB'
url=${*: -1}
if [[ $url =~ ^https://discord\.com/api/v10/channels/[0-9]+/threads$ ]]; then
  echo '{"id": "1563000000000000001"}'
elif [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)/messages/([0-9]+)$ &&
  -f $DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json ]]; then
  cat "$DISCORD_DIR/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"
elif [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)$ && -f $DISCORD_DIR/channel-${BASH_REMATCH[1]}.json ]]; then
  cat "$DISCORD_DIR/channel-${BASH_REMATCH[1]}.json"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
STUB
  jq -n --arg id "$ASKED_IN" --arg p "$ASSISTANT" '{id: $id, type: 11, parent_id: $p}' >"$DISCORD_DIR/channel-$ASKED_IN.json"
  # claude: the session list is $STUB_FIXTURES/agents.json (none at first), a launch adds its
  # session to it, idle, and prints its id.
  echo '[]' >"$STUB_FIXTURES/agents.json"
  stub_script claude <<'STUB'
if [[ $1 == agents ]]; then cat "$STUB_FIXTURES/agents.json"; exit 0; fi
if [[ $1 == stop || $1 == rm ]]; then exit 0; fi
name=${*: -2:1}
jq --arg name "$name" '. + [{id: "4f2a9c1e", name: $name, state: "idle", status: "idle", pid: 4242}]' \
  "$STUB_FIXTURES/agents.json" >"$STUB_FIXTURES/agents.next"
mv "$STUB_FIXTURES/agents.next" "$STUB_FIXTURES/agents.json"
echo "Started background session 4f2a9c1e ($name). Attach with: claude attach 4f2a9c1e"
STUB
  fake_process 4242 1 - claude --bg
  # A reading of the machine with room for every launch.
  capacity_room $((16 * 1073741824))
  about=$BATS_TEST_TMPDIR/about.md
  printf '%s\n' "Daniel wants to design the release checklist: what it checks, when it runs, where it reports." >"$about"
}

# Print the id of a new message of Daniel's (757) in <channel>, sent a minute ago, whose id holds
# that time as Discord's ids do: word <channel>
word() {
  local n ms id
  n=$(($(cat "$DISCORD_DIR/count" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$DISCORD_DIR/count"
  ms=$(($(date +%s%3N) - 60000))
  id=$((((ms - 1420070400000) << 22) | n))
  jq -n --arg c "$1" --arg id "$id" \
    '{id: $id, channel_id: $c, content: "Yes, open a topic on the checklist.", author: {id: "757", username: "daniel"}, edited_timestamp: null}' \
    >"$DISCORD_DIR/$1-$id.json"
  echo "$id"
}

# The events of one kind in the sandbox ledger, one compact object per line.
events() {
  jq -c --arg e "$1" 'select(.event == $e)' "$TEAM_HOME/ledger.jsonl"
}

# What an open takes: the task directories, the ledger and the primary checkout's worktrees.
taken_state() {
  ls "$TEAM_HOME/tasks" 2>/dev/null || true
  cat "$TEAM_HOME/ledger.jsonl"
  git -C "${primary:?}" worktree list --porcelain
}

# The thread POSTs the fake Discord took.
thread_posts() {
  stub_calls curl | jq -r 'select(any(.[]; . == "POST")) | .[-1]'
}

@test "the assistant opens a topic: its task, its thread under the topic channel, its plan, its brief and its session" {
  local daniel
  daniel=$(word "$ASKED_IN")
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-topic open --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj release-checklist "The release checklist"
  assert_equal "$output" "T1 topic open in <#1563000000000000001>: session 4f2a9c1e"
  assert_equal "$stderr" ""

  assert_equal "$(events opened | jq -c '{task, project, path, type, title, branch, discord_message, discord_channel}')" \
    "$(jq -cn --arg m "$daniel" --arg c "$ASKED_IN" '{task: "T1", project: "proj", path: "topic", type: "research",
      title: "The release checklist", branch: "research/T1-release-checklist", discord_message: $m, discord_channel: $c}')"
  assert_equal "$(events thread)" ""
  assert_equal "$(events interview-thread | jq -r .discord_thread)" "1563000000000000001"
  assert_equal "$(thread_posts)" "https://discord.com/api/v10/channels/$TOPICS/threads"
  assert_equal "$(stub_calls curl | jq -r 'select(any(.[]; . == "POST")) | index("-d") as $i | .[$i + 1] | fromjson | .name')" \
    "T1 · proj · The release checklist"
  assert_equal "$(events launch | jq -c '{role, session, worktree, brief}')" \
    "$(jq -cn --arg wt "$slots/1" '{role: "topic", session: "4f2a9c1e", worktree: $wt, brief: "brief"}')"
  run_bin -0 team-log --check

  # The plan, from the topic's template.
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/plan.md")" "# T1: The release checklist

A topic, opened by the assistant on Daniel's word, $(date -u +%F).
Project: proj.
Path: topic.
Daniel's message: $daniel in channel $ASKED_IN.

No plan, PR or merge: a topic's report goes to the assistant.

## What Daniel asked for

Daniel wants to design the release checklist: what it checks, when it runs, where it reports."
  # The brief, with the about text and the thread, which the session was told to read.
  assert_equal "$(head -n 1 "$TEAM_HOME/tasks/T1/brief.md")" "# T1 brief (topic): The release checklist"
  assert_contains "$(cat "$TEAM_HOME/tasks/T1/brief.md")" "Daniel wants to design the release checklist"
  assert_contains "$(cat "$TEAM_HOME/tasks/T1/brief.md")" "Discord thread \`1563000000000000001\`"
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] == "--bg") | [.[-2], .[-1]] | join(" ")')" \
    "T1-topic Read your brief at $TEAM_HOME/tasks/T1/brief.md"
}

@test "agent-team is the default project, and the coordinator and Daniel's shell open a topic too" {
  local daniel
  sed -i 's/^\[proj\]$/[agent-team]/; s/^\[proj.pool\]$/[agent-team.pool]/' "$TEAM_HOME/projects.toml"
  daniel=$(word "$ASSISTANT")
  AGENT_TEAM_ROLE=coordinator run_bin -0 --separate-stderr team-topic open --daniel "$daniel" --channel "$ASSISTANT" \
    --about "$about" toolkits "Toolkits"
  assert_equal "$output" "T1 topic open in <#1563000000000000001>: session 4f2a9c1e"
  assert_equal "$(events opened | jq -r .project)" "agent-team"
  daniel=$(word "$ASSISTANT")
  run_bin -0 --separate-stderr team-topic open --daniel "$daniel" --channel "$ASSISTANT" --about "$about" playbooks "Playbooks"
  assert_equal "$output" "T2 topic open in <#1563000000000000001>: session 4f2a9c1e"
}

@test "a worker session is refused in every form but --help, and a malformed line is a usage error" {
  local role before
  before=$(files_state)
  for role in planner builder reviewer ops topic; do
    for args in "open --daniel 1 --channel 2 --about $about x X" "close T1" "" "nonsense"; do
      # shellcheck disable=SC2086 # each form's words
      AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 --separate-stderr team-topic $args
      assert_equal "$output" ""
      assert_equal "$stderr" "team-topic: a $role session opens or closes no topic: that is the coordinator's; send it your message"
    done
    AGENT_TEAM_ROLE=$role run_bin -0 team-topic --help
    assert_contains "$output" "Usage: team-topic open --daniel <message id>"
  done
  assert_equal "$(files_state)" "$before"

  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic open --channel "$ASKED_IN" --about "$about" x "X"
  assert_contains "$stderr" "usage: team-topic open --daniel <message id> --channel <channel id> --about <file>"
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic open --daniel 1 --channel "$ASKED_IN" x "X"
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic open --daniel 1 --channel "$ASKED_IN" --about "$about" x
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic open --daniel abc --channel "$ASKED_IN" --about "$about" x "X"
  assert_equal "$stderr" "team-topic: --daniel needs a Discord id, got 'abc'"
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic open --task 7 --daniel 1 --channel "$ASKED_IN" --about "$about" x "X"
  assert_equal "$stderr" "team-topic: task must look like T<n>, got '7'"
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic open --daniel 1 --channel "$ASKED_IN" --about "$about" --later x "X"
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic close
  assert_equal "$stderr" "team-topic: usage: team-topic close T<n> [--no-report]"
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic close 7
  assert_equal "$stderr" "team-topic: task must look like T<n>, got '7'"
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic close T1 --later
  AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr team-topic close T1 T2
  assert_equal "$(files_state)" "$before"
}

@test "each refusal before the open is exit 1 with nothing opened" {
  local daniel before
  daniel=$(word "$ASKED_IN")
  before=$(taken_state)
  # refused <stderr> <about file> [<slug> <title>]: the open refused with exactly <stderr>.
  refused() {
    AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic open --daniel "$daniel" --channel "$ASKED_IN" \
      --about "$2" --project proj "${3:-ingest}" "${4:-The ingest}"
    assert_equal "$output" ""
    assert_equal "$stderr" "team-topic: $1"
    assert_equal "$(taken_state)" "$before"
  }
  refused "the about file $BATS_TEST_TMPDIR/none.md does not exist" "$BATS_TEST_TMPDIR/none.md"
  mkdir "$BATS_TEST_TMPDIR/dir.md"
  refused "cannot read the about file $BATS_TEST_TMPDIR/dir.md" "$BATS_TEST_TMPDIR/dir.md"
  : >"$BATS_TEST_TMPDIR/empty.md"
  refused "the about file $BATS_TEST_TMPDIR/empty.md is empty: write what Daniel asked the topic for" "$BATS_TEST_TMPDIR/empty.md"
  head -c 8193 /dev/zero | tr '\0' a >"$BATS_TEST_TMPDIR/long.md"
  refused "the about file $BATS_TEST_TMPDIR/long.md is 8193 bytes, over the 8 KiB a topic's about takes: say what Daniel asked for in fewer words" \
    "$BATS_TEST_TMPDIR/long.md"
  head -c 8192 /dev/zero | tr '\0' a >"$BATS_TEST_TMPDIR/full.md"
  printf '\x89PNG\r\n\x1a\n0000000000' >"$BATS_TEST_TMPDIR/image.md"
  refused "the about file $BATS_TEST_TMPDIR/image.md is an image (png), not text" "$BATS_TEST_TMPDIR/image.md"
  printf 'text\0more\n' >"$BATS_TEST_TMPDIR/nul.md"
  refused "the about file $BATS_TEST_TMPDIR/nul.md holds a NUL byte, so it is no text" "$BATS_TEST_TMPDIR/nul.md"
  printf ' \n\t\n' >"$BATS_TEST_TMPDIR/blank.md"
  refused "the about file $BATS_TEST_TMPDIR/blank.md has no text" "$BATS_TEST_TMPDIR/blank.md"
  local provider=gmail.com corp=corp.io
  printf 'Write to daniel@%s or ops@%s.\n' "$provider" "$corp" >"$BATS_TEST_TMPDIR/address.md"
  refused "the about file $BATS_TEST_TMPDIR/address.md holds 1 email address at a public provider, 1 email address outside the fixture domains, which a topic's plan and brief never take; write it without the address" \
    "$BATS_TEST_TMPDIR/address.md"
  refused "slug must be lower-case kebab case of at most 40 characters, got 'The_Ingest'" "$about" The_Ingest
  refused "slug must be lower-case kebab case of at most 40 characters, got '$(printf 'a%.0s' {1..41})'" "$about" "$(printf 'a%.0s' {1..41})"
  refused "the title has no text" "$about" ingest " "

  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  refused "home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine opens no topic: the assistant on the holder does" "$about"
  rm "$HOME/.local/state/agent-team/fenced"
  assert_equal "$(stub_calls curl)" ""

  # Daniel's word is team-open's to hold, its refusal passed on with nothing opened.
  jq '.author.id = "999"' "$DISCORD_DIR/$ASKED_IN-$daniel.json" >"$DISCORD_DIR/other.json"
  mv "$DISCORD_DIR/other.json" "$DISCORD_DIR/$ASKED_IN-$daniel.json"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic open --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$BATS_TEST_TMPDIR/full.md" --project proj ingest "The ingest"
  assert_contains "$stderr" "team-open: Discord message $daniel in channel $ASKED_IN cannot open a topic: Discord message $daniel is by daniel (999), who is not in allowFrom"
  assert_equal "$(taken_state)" "$before"
  # With a number of Daniel's, a refusal that took nothing names no half-open task to finish.
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic open --task T9 --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj ingest "The ingest"
  assert_contains "$stderr" "who is not in allowFrom"
  [[ $stderr != *"half open"* ]]
  assert_equal "$(taken_state)" "$before"
}

@test "a run that fails after the open is finished by --task, leaving one task, one thread and one launch" {
  local daniel real_thread
  code_checkout
  daniel=$(word "$ASKED_IN")
  # team-thread fails once the task is open, as a Discord outage would leave it.
  real_thread=$CODE_CHECKOUT/bin/team-thread.real
  mv "$CODE_CHECKOUT/bin/team-thread" "$real_thread"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "team-thread: Discord did not return a thread id" >&2' 'exit 1' >"$CODE_CHECKOUT/bin/team-thread"
  chmod +x "$CODE_CHECKOUT/bin/team-thread"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic open --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj release-checklist "The release checklist"
  assert_contains "$stderr" "team-thread: Discord did not return a thread id"
  assert_contains "$stderr" "team-topic: T1 is half open; finish it with: team-topic open --task T1 --daniel $daniel --channel $ASKED_IN --about $about --project proj release-checklist The\\ release\\ checklist"
  assert_equal "$(events opened | wc -l)" "1"
  assert_equal "$(events interview-thread)" ""
  [[ ! -e $TEAM_HOME/tasks/T1/plan.md ]]

  mv -f "$real_thread" "$CODE_CHECKOUT/bin/team-thread"
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-topic open --task T1 --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj release-checklist "The release checklist"
  assert_equal "$output" "T1 topic open in <#1563000000000000001>: session 4f2a9c1e"
  # A kept plan is not rewritten, and a run once all is done changes nothing but prints the line.
  echo "Daniel's note." >>"$TEAM_HOME/tasks/T1/plan.md"
  cp "$TEAM_HOME/tasks/T1/plan.md" "$BATS_TEST_TMPDIR/plan.before"
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-topic open --task T1 --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj release-checklist "The release checklist"
  assert_equal "$output" "T1 topic open in <#1563000000000000001>: session 4f2a9c1e"
  assert_equal "$(cat "$TEAM_HOME/tasks/T1/plan.md")" "$(cat "$BATS_TEST_TMPDIR/plan.before")"
  assert_equal "$(ls "$TEAM_HOME/tasks")" "T1"
  assert_equal "$(events opened | wc -l) $(events interview-thread | wc -l) $(events launch | wc -l)" "1 1 1"
  assert_equal "$(thread_posts | wc -l)" "1"
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "--bg")' | wc -l)" "1"
  run_bin -0 team-log --check

  # A stopped session is launched again.
  jq 'map(.state = "stopped")' "$STUB_FIXTURES/agents.json" >"$STUB_FIXTURES/agents.next"
  mv "$STUB_FIXTURES/agents.next" "$STUB_FIXTURES/agents.json"
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-topic open --task T1 --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj release-checklist "The release checklist"
  assert_equal "$(events launch | wc -l)" "2"
}

@test "a rerun whose session list cannot be read launches nothing, so a live session is never doubled" {
  local daniel answer
  daniel=$(word "$ASKED_IN")
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-topic open --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj release-checklist "The release checklist"
  assert_equal "$(events launch | wc -l)" "1"
  # A list that is no array, an object, a list of no JSON and a claude that fails each refuse the
  # rerun, and no session is started.
  for answer in '{}' 'not json' fail; do
    if [[ $answer == fail ]]; then
      stub_script claude <<'STUB'
if [[ $1 == agents ]]; then echo "claude: no" >&2; exit 1; fi
STUB
    else
      echo "$answer" >"$STUB_FIXTURES/agents.json"
    fi
    AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic open --task T1 --daniel "$daniel" --channel "$ASKED_IN" \
      --about "$about" --project proj release-checklist "The release checklist"
    assert_contains "$stderr" "team-topic: cannot read the session list (claude agents --json --all)"
    assert_equal "$(events launch | wc -l)" "1"
    assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "--bg")' | wc -l)" "1"
  done
}

@test "--task refuses another message's topic, a closed one and a task of another path" {
  local daniel other before
  daniel=$(word "$ASKED_IN")
  AGENT_TEAM_ROLE=assistant run_bin -0 team-topic open --daniel "$daniel" --channel "$ASKED_IN" --about "$about" --project proj ingest "The ingest"
  other=$(word "$ASKED_IN")
  before=$(taken_state)
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic open --task T1 --daniel "$other" --channel "$ASKED_IN" \
    --about "$about" --project proj ingest "The ingest"
  assert_equal "$stderr" "team-topic: T1 was opened on Daniel's message $daniel, not $other: --task finishes only the topic that message opened"
  run_bin -0 --separate-stderr team-open proj feature feat other "Other"
  before=$(taken_state)
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic open --task T2 --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj ingest "The ingest"
  assert_equal "$stderr" "team-topic: T2 is a feature task, not a topic: --task finishes only a half-open topic"
  echo '{"ts":"2026-11-24T00:00:01Z","task":"T1","event":"closed","archive":[],"returned":[],"kept":[]}' >>"$TEAM_HOME/ledger.jsonl"
  before=$(taken_state)
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic open --task T1 --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj ingest "The ingest"
  assert_equal "$stderr" "team-topic: T1 is closed: --task finishes only an open topic"
  assert_equal "$(taken_state)" "$before"
}

@test "no room for the session exits 75 with the rerun line, the task open, and the rerun launches it" {
  local daniel real_capacity
  code_checkout
  daniel=$(word "$ASKED_IN")
  # team-capacity admit has room for the open's dry run, and none for the session.
  real_capacity=$CODE_CHECKOUT/bin/team-capacity.real
  mv "$CODE_CHECKOUT/bin/team-capacity" "$real_capacity"
  cat >"$CODE_CHECKOUT/bin/team-capacity" <<'SH'
#!/usr/bin/env bash
if [[ $1 == admit && " $* " != *" --dry-run "* ]]; then
  echo "team-capacity: no room for session:topic at level minor: 2.0 GiB free of the 6.0 GiB budget" >&2
  exit 75
fi
exec "$0.real" "$@"
SH
  chmod +x "$CODE_CHECKOUT/bin/team-capacity"
  AGENT_TEAM_ROLE=assistant run_bin -75 --separate-stderr team-topic open --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj release-checklist "The release checklist"
  assert_equal "$output" ""
  assert_equal "$(grep '^team-topic:' <<<"$stderr")" "team-topic: T1 is open with no session yet: no room (team-capacity: no room for session:topic at level minor: 2.0 GiB free of the 6.0 GiB budget); run team-topic open --task T1 --daniel $daniel --channel $ASKED_IN --about $about --project proj release-checklist The\\ release\\ checklist again once there is"
  assert_equal "$(events opened | jq -r .task) $(events interview-thread | jq -r .task) $(events launch | wc -l)" "T1 T1 0"
  [[ -e $TEAM_HOME/tasks/T1/plan.md && -e $TEAM_HOME/tasks/T1/brief.md ]]
  run_bin -0 team-log --check

  mv -f "$real_capacity" "$CODE_CHECKOUT/bin/team-capacity"
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-topic open --task T1 --daniel "$daniel" --channel "$ASKED_IN" \
    --about "$about" --project proj release-checklist "The release checklist"
  assert_equal "$output" "T1 topic open in <#1563000000000000001>: session 4f2a9c1e"
  assert_equal "$(events launch | jq -r .role)" "topic"
}

# Open a topic T<n> in proj, its session listed idle, and print its task directory in its
# worktree: open_topic <slug> <title>
open_topic() {
  local daniel
  daniel=$(word "$ASKED_IN")
  AGENT_TEAM_ROLE=assistant run_bin -0 team-topic open --daniel "$daniel" --channel "$ASKED_IN" --about "$about" \
    --project proj "$1" "$2"
}

# The task directory of T<n>'s worktree: topic_dir T<n>
topic_dir() {
  echo "$(events launch | jq -r --arg t "$1" 'select(.task == $t) | .worktree' | tail -n 1)/.scratch/task"
}

@test "the assistant closes a topic: its report filed under the research, the task closed" {
  local dir filed
  open_topic release-checklist "The release checklist"
  dir=$(topic_dir T1)
  printf '%s\n' "# T1 report: the release checklist" "" "Decided: run it daily (Daniel, 1564000000000000514)." >"$dir/report.md"
  filed=$TEAM_HOME/assistant/research/$(events opened | jq -r '.ts[:10]')-T1-release-checklist.md
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-topic close T1
  assert_equal "$output" "T1 closed; report at $filed"
  [[ $stderr != *"team-topic:"* ]]
  assert_equal "$(cat "$filed")" "$(printf '%s\n' "# T1 report: the release checklist" "" "Decided: run it daily (Daniel, 1564000000000000514).")"
  assert_equal "$(ls "$TEAM_HOME/assistant/research")" "$(basename "$filed")"
  assert_equal "$(events closed | jq -r .task)" "T1"
  # team-close archived the task directory and returned the worktree.
  [[ -f $TEAM_HOME/tasks/T1/scratch/report.md && ! -e $dir ]]
  run_bin -0 team-log --check

  # A closed topic is no open topic.
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic close T1
  assert_equal "$stderr" "team-topic: T1 is not an open topic: close a task with team-close"
}

@test "close refuses a fenced machine, a task that is no open topic and a topic with no report.md" {
  local before
  open_topic ingest "The ingest"
  run_bin -0 team-open proj feature feat other "Other"
  before=$(taken_state)
  # refused <stderr> <arg>...: the close refused with exactly <stderr>, nothing changed.
  refused() {
    AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic close "${@:2}"
    assert_equal "$output" ""
    assert_equal "$stderr" "team-topic: $1"
    assert_equal "$(taken_state)" "$before"
    [[ ! -e $TEAM_HOME/assistant/research ]]
  }
  refused "T1 has no report.md yet; ask it for its report, or close with --no-report" T1
  refused "T2 is not an open topic: close a task with team-close" T2
  refused "T2 is not an open topic: close a task with team-close" T2 --no-report
  refused "T9 is not an open topic: close a task with team-close" T9
  echo "# report" >"$(topic_dir T1)/report.md"
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  refused "home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine closes no topic: the assistant on the holder does" T1
}

@test "--no-report closes a topic with no report, and files none" {
  open_topic ingest "The ingest"
  echo "# report" >"$(topic_dir T1)/report.md"
  AGENT_TEAM_ROLE=coordinator run_bin -0 --separate-stderr team-topic close T1 --no-report
  assert_equal "$output" "T1 closed with no report"
  [[ ! -e $TEAM_HOME/assistant/research ]]
  assert_equal "$(events closed | jq -r .task)" "T1"
}

@test "a busy topic session refuses the close as team-close does, the report filed, and a rerun closes it" {
  local filed
  open_topic ingest "The ingest"
  echo "# first" >"$(topic_dir T1)/report.md"
  filed=$TEAM_HOME/assistant/research/$(events opened | jq -r '.ts[:10]')-T1-ingest.md
  # Another file of the research is never touched.
  mkdir -p "$TEAM_HOME/assistant/research"
  echo "# a spike" >"$TEAM_HOME/assistant/research/2026-11-01-spike.md"
  jq 'map(.status = "busy" | .state = "busy")' "$STUB_FIXTURES/agents.json" >"$STUB_FIXTURES/agents.next"
  mv "$STUB_FIXTURES/agents.next" "$STUB_FIXTURES/agents.json"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic close T1
  assert_equal "$output" ""
  assert_contains "$stderr" "team-close: T1 cannot close, so nothing changed:
  T1-topic 4f2a9c1e is busy"
  assert_equal "$(cat "$filed")" "# first"
  assert_equal "$(events closed)" ""

  # The topic rewrote its report; the rerun files it under the same name and closes.
  echo "# final" >"$(topic_dir T1)/report.md"
  jq 'map(.status = "idle" | .state = "idle")' "$STUB_FIXTURES/agents.json" >"$STUB_FIXTURES/agents.next"
  mv "$STUB_FIXTURES/agents.next" "$STUB_FIXTURES/agents.json"
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-topic close T1
  assert_equal "$output" "T1 closed; report at $filed"
  assert_equal "$(cat "$filed")" "# final"
  assert_equal "$(ls "$TEAM_HOME/assistant/research")" "$(printf '%s\n' 2026-11-01-spike.md "$(basename "$filed")" | sort)"
  assert_equal "$(cat "$TEAM_HOME/assistant/research/2026-11-01-spike.md")" "# a spike"
  assert_equal "$(events closed | jq -r .task)" "T1"
}

@test "a close that failed once the worktree was returned is finished by a rerun, the report read from the archive" {
  local real_close filed
  code_checkout
  open_topic ingest "The ingest"
  echo "# the report" >"$(topic_dir T1)/report.md"
  filed=$TEAM_HOME/assistant/research/$(events opened | jq -r '.ts[:10]')-T1-ingest.md
  # team-close fails at its end, its worktree returned and its task directory archived, with no
  # closed logged.
  real_close=$BATS_TEST_TMPDIR/team-close.real
  cp "$CODE_CHECKOUT/bin/team-close" "$real_close"
  sed -i 's/^ledger_append "$(jq -cn --arg task "$task" --argjson archive /die "cannot log the close"\n&/' \
    "$CODE_CHECKOUT/bin/team-close"
  grep -q '^die "cannot log the close"$' "$CODE_CHECKOUT/bin/team-close"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-topic close T1
  assert_contains "$stderr" "team-close: cannot log the close"
  assert_equal "$(events closed)" ""
  assert_equal "$(events worktree-returned | jq -r .task)" "T1"
  rm "$filed"

  cp -f "$real_close" "$CODE_CHECKOUT/bin/team-close"
  AGENT_TEAM_ROLE=assistant run_bin -0 --separate-stderr team-topic close T1
  assert_equal "$output" "T1 closed; report at $filed"
  assert_equal "$(cat "$filed")" "# the report"
  assert_equal "$(events closed | jq -r .task)" "T1"
}
