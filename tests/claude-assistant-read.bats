#!/usr/bin/env bats
# claude-assistant-read: the assistant's start of one read session per production question, on
# Daniel's own message in #assistant or a thread under it, at most an hour old and used once, with
# prod-read, vercel-read or both, in a directory of the team home holding the project's docs; each
# refusal in its order, with nothing started.

load helpers/common
load helpers/signals

ASSISTANT=1570965039278596199
THREAD=1571000000000000001
OTHER=1562000000000000999

setup() {
  sandbox
  export TEAM_ASSISTANT_CHANNEL=$ASSISTANT
  primary=$(make_repo conventioner dev)
  origin=$BATS_TEST_TMPDIR/origin/conventioner.git
  mkdir -p "$primary/docs/implementation/data" "$primary/src"
  echo '# Operations' >"$primary/docs/OPERATIONS.md"
  echo 'export type Stall = {}' >"$primary/docs/implementation/data/stalls.md"
  echo '# Conventioner' >"$primary/CLAUDE.md"
  echo '# Agents' >"$primary/AGENTS.md"
  echo 'print(1)' >"$primary/src/app.py"
  git -C "${primary:?}" add -A
  git -C "${primary:?}" commit -q -m "docs: the operations doc"
  git -C "${primary:?}" push -q origin dev
  registry conventioner '"prod-read", "prod-write", "vercel-read", "prod-mongo"' agent-team '"browser"'
  echo '{"dmPolicy": "allowlist", "allowFrom": ["757"], "groups": {}, "pending": {}}' \
    >"$HOME/.claude/channels/discord/access.json"
  hold_lease home-pc >/dev/null
  export DISCORD_DIR=$BATS_TEST_TMPDIR/discord
  mkdir -p "$DISCORD_DIR"
  stub_discord
  jq -n --arg id "$THREAD" --arg p "$ASSISTANT" '{id: $id, type: 11, parent_id: $p}' >"$DISCORD_DIR/channel-$THREAD.json"
  jq -n --arg id "$OTHER" '{id: $id, type: 11, parent_id: "1562486564871995482"}' >"$DISCORD_DIR/channel-$OTHER.json"
  stub_claude
  question=$HOME/.local/state/agent-team/assistant-files/question.md
  mkdir -p "${question%/*}"
  printf 'How many stalls are booked for the next convention?\n' >"$question"
  dir=$TEAM_HOME/.claude/worktrees/assistant-read
  state=$HOME/.local/state/agent-team
}

# registry <name> <toolkits> [<name> <toolkits>]...: a registry of each project, its primary
# checkout projects/<name>, base dev, its toolkits list the TOML items given.
registry() {
  : >"$TEAM_HOME/projects.toml"
  while (($#)); do
    cat >>"$TEAM_HOME/projects.toml" <<TOML
[$1]
repo = "owner/$1"
path = "projects/$1"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = [$2]
pool = { provider = "git", slots = ["slots/$1/1"] }

TOML
    shift 2
  done
}

# The fake Discord API: GET channels/<c>/messages/<m> answers $DISCORD_DIR/<c>-<m>.json and GET
# channels/<c> answers $DISCORD_DIR/channel-<c>.json; anything else fails as curl -f does on a 404.
stub_discord() {
  stub_script curl <<'EOF'
url=${*: -1}
if [[ $url =~ ^https://discord\.com/api/v10/channels/([0-9]+)/messages/([0-9]+)$ &&
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

# says [--author <id>] [--ago <seconds>] <channel>: the link to a new message in <channel>, by <id>
# (757, Daniel, by default), sent <seconds> ago (60 by default), whose id holds that time as
# Discord's ids do; sets message to its id.
says() {
  local author=757 ago=60 n ms
  while [[ $1 == --* ]]; do
    case $1 in
      --author) author=$2 ;;
      --ago) ago=$2 ;;
    esac
    shift 2
  done
  n=$(($(cat "$DISCORD_DIR/count" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$DISCORD_DIR/count"
  ms=$(($(date +%s%3N) - ago * 1000))
  message=$((((ms - 1420070400000) << 22) | n))
  jq -n --arg c "$1" --arg id "$message" --arg a "$author" \
    '{id: $id, channel_id: $c, content: "How many stalls?", author: {id: $a, username: "daniel"}}' \
    >"$DISCORD_DIR/$1-$message.json"
  link=https://discord.com/channels/1560000000000000000/$1/$message
}

# The stub claude: its session list is $STUB_FIXTURES/agents.json (an empty list without one),
# and a launch prints a session id, or fails when $STUB_FIXTURES/claude-fails exists; each
# launch's working directory is a line of $STUB_CALLS/claude.cwd.
stub_claude() {
  stub_script claude <<'EOF'
if [[ $* == "agents --json --all" ]]; then
  cat "$STUB_FIXTURES/agents.json" 2>/dev/null || echo '[]'
  exit 0
fi
printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.cwd"
if [[ -e $STUB_FIXTURES/claude-fails ]]; then
  echo "Error: the daemon did not answer" >&2
  exit 1
fi
echo "Started background session 4f2a9c1e (assistant-read). Attach with: claude attach 4f2a9c1e"
EOF
}

# The claude calls that started a session, one JSON array each.
bg_calls() {
  stub_calls claude | jq -c 'select(.[0] == "--bg")'
}

# start [<run_bin option>...] -- <argument>...: claude-assistant-read start as the assistant.
start() {
  local opts=()
  while [[ $1 != -- ]]; do opts+=("$1") && shift; done
  shift
  AGENT_TEAM_ROLE=assistant run_bin "${opts[@]}" --separate-stderr claude-assistant-read start "$@"
}

# Nothing started and nothing written: no launch, no read directory, no generated settings or MCP
# config, no read log directory and no request line.
nothing_started() {
  assert_equal "$(bg_calls)" ""
  [[ ! -e $dir ]]
  [[ ! -e $state/assistant-read.settings.json && ! -e $state/assistant-read.mcp.json ]]
  [[ ! -e $state/assistant-read-requests ]]
  [[ ! -e $TEAM_HOME/assistant/prod-reads ]] || assert_equal "$(find "$TEAM_HOME/assistant/prod-reads" -mindepth 1)" ""
}

# refused <code> <stderr> <argument>...: start with those arguments exits <code>, printing nothing
# on stdout and <stderr> after the script's name, with nothing started.
refused() {
  local code=$1 why=$2
  shift 2
  start "-$code" -- "$@"
  assert_equal "$output" ""
  assert_equal "$stderr" "claude-assistant-read: $why"
  nothing_started
}

@test "--help prints the header: start's form, who may run it, its refusals in order and its files" {
  run_bin -0 claude-assistant-read --help
  assert_contains "$output" "Usage: claude-assistant-read start --request <link> --toolkit <kit> [--toolkit <kit>] --file <question>"
  assert_contains "$output" "assistant-read.settings.json"
  assert_contains "$output" "roles/assistant-read.md"
  assert_contains "$output" "assistant-read-requests"
  assert_contains "$output" ".claude/worktrees/assistant-read"
  assert_contains "$output" "another read is starting"
}

@test "a start launches assistant-read in the read directory, with its settings, MCP config, role prompt and the question, and prints its id" {
  says "$ASSISTANT"
  start -0 -- --request "$link" --toolkit prod-read --toolkit vercel-read --file "$question"
  assert_equal "$output" 4f2a9c1e
  assert_equal "$stderr" "claude-assistant-read: assistant-read 4f2a9c1e started in $dir: Daniel approves one 1Password prompt per toolkit on the PC"
  prompt="Daniel asked a production question in #assistant $ASSISTANT, their message $message ($link). Answer it as your role says, then send \`assistant\` your READ DONE.

Their question, as the assistant relays it:

How many stalls are booked for the next convention?"
  assert_equal "$(bg_calls)" "$(jq -cn --arg code "$REPO_ROOT" --arg state "$state" --arg prompt "$prompt" \
    '["--bg", "--restricted", "--tools", "Read,Glob,Grep,Edit,Write,ToolSearch,SendMessage,ListAgents,Skill",
      "--strict-mcp-config", "--mcp-config", "\($state)/assistant-read.mcp.json",
      "--plugin-dir", "\($code)/toolkits/prod-read", "--plugin-dir", "\($code)/toolkits/vercel-read",
      "--settings", "\($state)/assistant-read.settings.json",
      "--append-system-prompt-file", "\($code)/roles/assistant-read.md",
      "--permission-mode", "auto", "--name", "assistant-read", $prompt]')"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$dir"
  # The request is recorded once the launch printed its id.
  assert_equal "$(awk '{ print $1, $3 }' "$state/assistant-read-requests")" "$message 4f2a9c1e"
  [[ $(awk '{ print $2 }' "$state/assistant-read-requests") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "the settings name this checkout and the read's log directory, and each server of the MCP config runs as assistant-read" {
  says "$ASSISTANT"
  start -0 -- --request "$link" --toolkit vercel-read --toolkit prod-read --file "$question"
  logs=$TEAM_HOME/assistant/prod-reads/$message
  [[ -d $logs ]]
  assert_equal "$(jq -c . "$state/assistant-read.settings.json")" \
    "$(jq -c --arg code "$REPO_ROOT" --arg logs "$logs" 'walk(if type == "string" then gsub("@TEAM_CODE@"; $code) | gsub("@LOG_DIR@"; $logs) else . end)' \
      "$REPO_ROOT/assistant-read.settings.json")"
  assert_equal "$(grep -cE '@(TEAM_CODE|LOG_DIR)@' "$state/assistant-read.settings.json" || true)" 0
  assert_equal "$(jq -c . "$state/assistant-read.mcp.json")" "$(jq -cn --arg code "$REPO_ROOT" '{mcpServers: {
    "vercel-read": {command: "node", args: ["\($code)/toolkits/vercel-read/scripts/start-server.mjs"], env: {AGENT_TEAM_ROLE: "assistant-read"}},
    "prod-read": {command: "node", args: ["\($code)/toolkits/prod-read/scripts/start-server.mjs"], env: {AGENT_TEAM_ROLE: "assistant-read"}}}}')"
  # One toolkit, one server and one plugin directory.
  rm -rf "${dir:?}" && rm -f "$state/assistant-read-requests"
  says "$ASSISTANT"
  start -0 -- --request "$link" --toolkit vercel-read --file "$question"
  assert_equal "$(jq -c '.mcpServers | keys' "$state/assistant-read.mcp.json")" '["vercel-read"]'
  assert_equal "$(bg_calls | tail -n 1 | jq -c '[index("--plugin-dir") as $i | .[$i + 1]]')" "$(jq -cn --arg code "$REPO_ROOT" '["\($code)/toolkits/vercel-read"]')"
}

@test "the read settings and role prompt hold the read session's shape" {
  file=$REPO_ROOT/assistant-read.settings.json
  assert_equal "$(jq -c '[.remoteControlAtStartup, .disableBundledSkills, .disableSkillShellExecution]' "$file")" '[false,true,true]'
  assert_equal "$(jq -c '.enabledPlugins | to_entries | map(select(.value == false) | .key) | sort' "$file")" \
    '["cc-plugin-easel@builtin","cc-plugin-plugin-authoring@builtin","discord@claude-plugins-official","mongodb-atlas@claude-plugins-official"]'
  assert_equal "$(jq -c .permissions.allow "$file")" '["mcp__prod-read__*","mcp__vercel-read__*","Edit(./.scratch/answer.md)"]'
  assert_equal "$(jq -c .permissions.deny "$file")" '["Bash","WebFetch","WebSearch","Agent","NotebookEdit","Read(//proc/**)","Read(**/.env*)"]'
  assert_equal "$(jq -c .env "$file")" '{"MCP_TIMEOUT":"120000","AGENT_TEAM_ROLE":"assistant-read"}'
  assert_equal "$(jq -c '[.hooks | to_entries[] | .key as $event | .value[]
      | {event: $event, matcher, hooks: [.hooks[] | [.command] + .args | join(" ")]}]' "$file")" \
    '[{"event":"PreToolUse","matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":["@TEAM_CODE@/bin/hooks/scratch-only-edits .scratch/answer.md"]},{"event":"PreToolUse","matcher":"^mcp__.*(prod-read|vercel-read).*__","hooks":["@TEAM_CODE@/bin/hooks/ops-log @LOG_DIR@"]},{"event":"PostToolUse","matcher":"^mcp__.*(prod-read|vercel-read).*__","hooks":["@TEAM_CODE@/bin/hooks/ops-log @LOG_DIR@"]},{"event":"PostToolUseFailure","matcher":"^mcp__.*(prod-read|vercel-read).*__","hooks":["@TEAM_CODE@/bin/hooks/ops-log @LOG_DIR@"]}]'
  # No production write, backup or other toolkit reaches it.
  assert_equal "$(grep -cE 'prod-write|prod-mongo' "$file" || true)" 0
  role=$REPO_ROOT/roles/assistant-read.md
  assert_contains "$(cat "$role")" "READ DONE <answer>"
  assert_contains "$(cat "$role")" "docs/OPERATIONS.md"
  assert_contains "$(cat "$role")" "querying-production-data"
  assert_contains "$(cat "$role")" "reading-vercel-deployments"
  assert_contains "$(cat "$role")" "T0-assistant-read"
}

@test "the read directory holds the base's docs, CLAUDE.md and AGENTS.md alone, fetched first, and the checkout gains no worktree" {
  # A docs change merged on another machine, which only the fetch brings.
  push_to_dev "$origin" docs/new.md >/dev/null
  says "$ASSISTANT"
  start -0 -- --request "$link" --toolkit prod-read --file "$question"
  assert_equal "$(cd "$dir" && find . -mindepth 1 | LC_ALL=C sort)" "./.scratch
./AGENTS.md
./CLAUDE.md
./docs
./docs/OPERATIONS.md
./docs/implementation
./docs/implementation/data
./docs/implementation/data/stalls.md
./docs/new.md"
  assert_equal "$(cat "$dir/docs/OPERATIONS.md")" "# Operations"
  assert_equal "$(git -C "${primary:?}" worktree list --porcelain | grep -c '^worktree ')" 1
  assert_equal "$(git -C "${primary:?}" status --porcelain)" ""
}

@test "a fetch that fails warns and exports the base as last fetched; a base never fetched refuses" {
  push_to_dev "$origin" docs/new.md >/dev/null
  git -C "${primary:?}" remote set-url origin "$BATS_TEST_TMPDIR/gone.git"
  says "$ASSISTANT"
  start -0 -- --request "$link" --toolkit prod-read --file "$question"
  assert_contains "$stderr" "claude-assistant-read: could not fetch origin/dev ("
  assert_contains "$stderr" "); the read's docs are as last fetched"
  assert_equal "${lines[0]}" 4f2a9c1e
  [[ -f $dir/docs/OPERATIONS.md && ! -e $dir/docs/new.md ]]
  # A base the checkout never fetched.
  rm -rf "${dir:?}"
  git -C "${primary:?}" update-ref -d refs/remotes/origin/dev
  says "$ASSISTANT"
  start -1 -- --request "$link" --toolkit prod-read --file "$question"
  assert_contains "$stderr" "claude-assistant-read: conventioner's base origin/dev cannot be read in its primary checkout $primary, so the read has no docs"
  assert_equal "$(bg_calls | wc -l)" 1
  [[ ! -e $dir ]]
}

@test "a message in a thread under #assistant starts a read there" {
  says "$THREAD"
  start -0 -- --request "$link" --toolkit prod-read --file "$question"
  assert_contains "$(bg_calls | jq -r '.[-1]')" "Daniel asked a production question in the #assistant thread $THREAD, their message $message ($link)."
}

@test "a malformed command line is refused with exit 2, nothing started" {
  says "$ASSISTANT"
  for args in "" "start" "answer" "end" "begin --request $link --toolkit prod-read --file $question" \
    "start --toolkit prod-read --file $question" \
    "start --request $link --file $question" \
    "start --request $link --toolkit prod-read" \
    "start --request $link --request $link --toolkit prod-read --file $question" \
    "start --request $link --toolkit prod-read --file $question --file $question" \
    "start --request $link --toolkit prod-read --file $question --model opus" \
    "start --load-check --request $link --toolkit prod-read --file $question" \
    "start --request $link --toolkit --file $question" \
    "start --request $link --toolkit prod-read --file"; do
    # shellcheck disable=SC2086 # each case is its words
    AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr claude-assistant-read $args
    assert_equal "$args: $output" "$args: "
    assert_contains "$stderr" "usage: claude-assistant-read start --request <link> --toolkit <kit> [--toolkit <kit>] --file <question>"
  done
  nothing_started
}

@test "a toolkit but prod-read and vercel-read, or one given twice, is refused" {
  says "$ASSISTANT"
  for kit in prod-write prod-mongo browser; do
    refused 1 "the assistant reads production only through prod-read and vercel-read; $kit is the ops role's" \
      --request "$link" --toolkit prod-read --toolkit "$kit" --file "$question"
  done
  refused 1 "the assistant reads production only through prod-read and vercel-read, each once; prod-read is given twice" \
    --request "$link" --toolkit prod-read --toolkit prod-read --file "$question"
}

@test "a fenced machine starts no read" {
  says "$ASSISTANT"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$state/fenced"
  start -1 -- --request "$link" --toolkit prod-read --file "$question"
  assert_contains "$stderr" "a fenced machine starts no production read"
  nothing_started
}

@test "a start while another holds the lock exits 75" {
  says "$ASSISTANT"
  exec {held}>"$state/assistant-read.lock"
  flock -n "$held"
  refused 75 "another read is starting" --request "$link" --toolkit prod-read --file "$question"
  exec {held}>&-
}

@test "a read session still listed in any state, or its directory left, refuses a new start" {
  says "$ASSISTANT"
  for st in working idle "done" stopped; do
    jq -cn --arg s "$st" '[{id: "9a8b7c6d", name: "assistant-read", state: $s, sessionId: "9a8b7c6d-1111-4222-8333-944455556666"}]' >"$STUB_FIXTURES/agents.json"
    refused 1 "a read session is still there (9a8b7c6d $st): relay its answer and run claude-assistant-read end first" \
      --request "$link" --toolkit prod-read --file "$question"
  done
  rm "$STUB_FIXTURES/agents.json"
  mkdir -p "$dir/.scratch"
  start -1 -- --request "$link" --toolkit prod-read --file "$question"
  assert_equal "$stderr" "claude-assistant-read: a read session is still there (its directory $dir): relay its answer and run claude-assistant-read end first"
  assert_equal "$(bg_calls)" ""
  [[ -d $dir/.scratch ]]
  rm -rf "${dir:?}"
  echo 'not json' >"$STUB_FIXTURES/agents.json"
  refused 1 "cannot read the session list (claude agents --json --all)" --request "$link" --toolkit prod-read --file "$question"
}

@test "a request that is no Discord message link is refused" {
  refused 1 "--request must link Daniel's Discord message, https://discord.com/channels/<guild>/<channel>/<message>, got 'https://example.com/1/2/3'" \
    --request https://example.com/1/2/3 --toolkit prod-read --file "$question"
}

@test "a message outside #assistant and its threads, or in a channel Discord does not answer for, is refused" {
  says "$OTHER"
  refused 1 "channel $OTHER is neither #assistant ($ASSISTANT) nor a thread under it, so Daniel's word there is not for the assistant" \
    --request "$link" --toolkit prod-read --file "$question"
  says 1562486564871995482
  refused 1 "channel 1562486564871995482 cannot be read from Discord, so it is not known to be under #assistant ($ASSISTANT): curl: (22) The requested URL returned error: 404" \
    --request "$link" --toolkit prod-read --file "$question"
}

@test "a message more than an hour old is refused" {
  says --ago 3700 "$ASSISTANT"
  start -1 -- --request "$link" --toolkit prod-read --file "$question"
  assert_contains "$stderr" "claude-assistant-read: Discord message $message was sent at "
  assert_contains "$stderr" ", more than 60 minutes before this launch, the limit for a read: ask Daniel for a new message"
  nothing_started
}

@test "a message that started a read already is refused, naming that read" {
  says "$ASSISTANT"
  mkdir -p "$state"
  echo "$message 2026-11-24T10:00:00Z 1a2b3c4d" >"$state/assistant-read-requests"
  start -1 -- --request "$link" --toolkit prod-read --file "$question"
  assert_equal "$stderr" "claude-assistant-read: Discord message $message started a read already at 2026-11-24T10:00:00Z (1a2b3c4d): each read needs a new message of Daniel's"
  assert_equal "$(bg_calls)" ""
  [[ ! -e $dir ]]
  assert_equal "$(cat "$state/assistant-read-requests")" "$message 2026-11-24T10:00:00Z 1a2b3c4d"
}

@test "a message that is not Daniel's, or that Discord does not have, is refused" {
  says --author 999 "$ASSISTANT"
  refused 1 "Discord message $message is by daniel (999), who is not in allowFrom of ~/.claude/channels/discord/access.json" \
    --request "$link" --toolkit prod-read --file "$question"
  says "$ASSISTANT"
  rm "$DISCORD_DIR/$ASSISTANT-$message.json"
  refused 1 "Discord message $message cannot be fetched from #assistant $ASSISTANT: curl: (22) The requested URL returned error: 404" \
    --request "$link" --toolkit prod-read --file "$question"
}

@test "a question file that is missing, empty, too long, not text or holding a public address is refused" {
  says "$ASSISTANT"
  refused 1 "the question file $question.gone is missing" --request "$link" --toolkit prod-read --file "$question.gone"
  : >"$question"
  refused 1 "the question file $question is empty" --request "$link" --toolkit prod-read --file "$question"
  head -c 4001 /dev/zero | tr '\0' a >"$question"
  refused 1 "the question file $question is 4001 bytes, over the 4000 a question may be" --request "$link" --toolkit prod-read --file "$question"
  printf 'How many\001 stalls?\n' >"$question"
  refused 1 "the question file $question is not text" --request "$link" --toolkit prod-read --file "$question"
  printf 'How many \xff stalls?\n' >"$question"
  refused 1 "the question file $question is not text" --request "$link" --toolkit prod-read --file "$question"
  provider=gmail.com
  printf 'Which stalls has someone@%s booked?\n' "$provider" >"$question"
  refused 1 "the question file $question holds 1 email address at a public provider: a read's question holds no personal detail" \
    --request "$link" --toolkit prod-read --file "$question"
  # A question of exactly 4,000 bytes passes.
  head -c 4000 /dev/zero | tr '\0' a >"$question"
  start -0 -- --request "$link" --toolkit prod-read --file "$question"
}

@test "toolkits that no one project lists, or that two list, are refused" {
  says "$ASSISTANT"
  registry conventioner '"prod-read"' agent-team '"browser"'
  refused 1 "no one project lists prod-read and vercel-read in its toolkits" \
    --request "$link" --toolkit prod-read --toolkit vercel-read --file "$question"
  registry conventioner '"prod-read"' agent-team '"prod-read"'
  refused 1 "no one project lists prod-read in its toolkits" --request "$link" --toolkit prod-read --file "$question"
}

@test "a launch that fails leaves no directory, settings, MCP config or request line, and a rerun on the message passes" {
  says "$ASSISTANT"
  touch "$STUB_FIXTURES/claude-fails"
  start -1 -- --request "$link" --toolkit prod-read --file "$question"
  assert_equal "$(bg_calls | wc -l)" 1
  [[ ! -e $dir && ! -e $state/assistant-read.settings.json && ! -e $state/assistant-read.mcp.json ]]
  [[ ! -e $state/assistant-read-requests ]]
  [[ ! -e $TEAM_HOME/assistant/prod-reads/$message ]]
  rm "$STUB_FIXTURES/claude-fails"
  start -0 -- --request "$link" --toolkit prod-read --file "$question"
  assert_equal "$output" 4f2a9c1e
}

@test "a TERM, HUP or INT in the middle of the launch leaves no directory, settings, MCP config, request line or temporary file" {
  says "$ASSISTANT"
  {
    echo 'if [[ $* == "agents --json --all" ]]; then echo "[]"; exit 0; fi'
    stalled "$BATS_TEST_TMPDIR/launching"
    echo 'echo "Started background session 4f2a9c1e (assistant-read)."'
  } | stub_script claude
  for sig in TERM:143 HUP:129 INT:130; do
    rm -f "$BATS_TEST_TMPDIR/launching"
    AGENT_TEAM_ROLE=assistant signalled "${sig%:*}" "$BATS_TEST_TMPDIR/launching" \
      "$REPO_ROOT/bin/claude-assistant-read" start --request "$link" --toolkit prod-read --file "$question"
    assert_equal "$status:$(leftovers)" "${sig#*:}:"
    [[ ! -e $dir && ! -e $state/assistant-read.settings.json && ! -e $state/assistant-read.mcp.json ]]
    [[ ! -e $state/assistant-read-requests ]]
  done
}

@test "only the assistant starts a read: every other role, the coordinator and a session with no role are refused" {
  says "$ASSISTANT"
  for role in planner builder reviewer ops assistant-read; do
    AGENT_TEAM_ROLE=$role run_bin -1 --separate-stderr claude-assistant-read start --request "$link" --toolkit prod-read --file "$question"
    assert_equal "$role: $stderr" "$role: claude-assistant-read: claude-assistant-read is the assistant's: a $role session starts no production read"
    # Every form, a malformed one too.
    AGENT_TEAM_ROLE=$role run_bin -1 --separate-stderr claude-assistant-read answer
    assert_equal "$role: $stderr" "$role: claude-assistant-read: claude-assistant-read is the assistant's: a $role session starts no production read"
  done
  AGENT_TEAM_ROLE=coordinator run_bin -1 --separate-stderr claude-assistant-read start --request "$link" --toolkit prod-read --file "$question"
  assert_equal "$stderr" "claude-assistant-read: claude-assistant-read start is the assistant's: a coordinator session starts no production read"
  AGENT_TEAM_ROLE='' run_bin -1 --separate-stderr claude-assistant-read start --request "$link" --toolkit prod-read --file "$question"
  assert_equal "$stderr" "claude-assistant-read: claude-assistant-read start is the assistant's: a session with no role starts no production read"
  nothing_started
}
