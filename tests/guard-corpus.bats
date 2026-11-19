#!/usr/bin/env bats
# The guard hooks on the calls they must allow: every PreToolUse hook of every session's settings
# (settings/worker.json with a role's file over it, coordinator.settings.json,
# assistant.settings.json and the gate's bin/lib/gate-claude-settings.json) is run, as its
# settings entry writes it, on each call of tests/fixtures/guard-corpus/allowed.jsonl that its
# matcher takes, and must pass it with nothing on stderr. The other guard tests hold what a hook
# refuses; this one fails when a hook starts refusing ordinary work.
#
# The corpus is data, one JSON object a line, so another guard implementation can run it too:
#   roles  the sessions that make the call: builder, planner, reviewer, ops, coordinator,
#          assistant, gate (a gate's agent, which has no role)
#   tool   the tool's name, and input, its tool_input
#   cwd    the session's working directory, @WORKTREE@ when left out
#   local  true for a call that runs nothing lease-fence holds (no push, GitHub command, CI wait,
#          post, Discord tool, or lease-decided command of the coordinator or the assistant), so
#          it must pass on a fenced machine and while the team holds offline too
# Its commands have the shapes of real ones from the sessions' transcripts, with every value a
# fixture: no real path, name, address, id, task text, token or host. A string holds these
# placeholders, which the test fills: @WORKTREE@ (the session's worktree), @JOB@ (its
# CLAUDE_JOB_DIR), @TEAM_HOME@, @TEAM_CODE@ (the code checkout), @ASSISTANT_CHANNEL@ and
# @ASSISTANT_THREAD@ (the assistant's channel and a thread of it), @SESSION@ (the session's id,
# which each hook's input carries as its session_id) and @CLAUDE_TMP@ (Claude Code's temporary
# directory, which holds the output of a session's background Bash calls). @JOB@, and the paths
# under @CLAUDE_TMP@ and ~/.claude/projects that hold @SESSION@, name the session's own records,
# which session-records-guard, on Read, Grep, Glob and Bash (its matcher Read|Grep|Glob|Bash),
# lets the session reach.
#
# To add a case: append a line to allowed.jsonl with the roles that really make the call, and
# local when it holds; each role must have a hook that sees it, and the last test holds the line
# to fixtures.

load helpers/common

CORPUS=$BATS_TEST_DIRNAME/fixtures/guard-corpus/allowed.jsonl
ROLES=(builder planner reviewer ops coordinator assistant gate)
ASSISTANT=1570000000000000100
THREAD=1570000000000000201
SESSION=0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d

# The sessions' world: this machine holds the lease, a worktree with a task directory, the
# session's job directory, a task's directory in the team home, and the assistant's channel, a
# thread of it the hook has already read, and a report it may attach.
setup() {
  sandbox
  hold_lease home-pc >/dev/null
  WT=$HOME/code/.claude/worktrees/1 JOB=$HOME/.claude/jobs/0a1b2c3d TASK_DIR=$TEAM_HOME/tasks/T12
  mkdir -p "$WT/.scratch/task/work" "$WT/front-end/test-results" "$WT/front-end/dist" "$WT/.stack-logs" \
    "$JOB/tmp/replay" "$TASK_DIR" "$TEAM_HOME/assistant/research" "$HOME/.local/state/agent-team"
  echo "# Report" >"$TEAM_HOME/assistant/research/2026-01-02-widget-counts.md"
  echo "$THREAD" >"$HOME/.local/state/agent-team/assistant-threads"
  export TEAM_ASSISTANT_CHANNEL=$ASSISTANT
}

# The settings files a <role>'s session loads its hooks from, in this checkout: settings_of <role>
settings_of() {
  case $1 in
    builder | planner | reviewer | ops) printf '%s\n' "$REPO_ROOT/settings/worker.json" "$REPO_ROOT/settings/$1.json" ;;
    coordinator) echo "$REPO_ROOT/coordinator.settings.json" ;;
    assistant) echo "$REPO_ROOT/assistant.settings.json" ;;
    gate) echo "$REPO_ROOT/bin/lib/gate-claude-settings.json" ;;
  esac
}

# What a <role>'s session has in its environment when a hook runs, with no CLAUDE_CODE_TMPDIR, so
# session-records-guard and @CLAUDE_TMP@ read the same temporary directory: session <role>
session() {
  export CLAUDE_PROJECT_DIR=$WT CLAUDE_JOB_DIR=$JOB AGENT_TEAM_TASK=T12
  unset AGENT_TEAM_ROLE CLAUDE_CODE_TMPDIR
  case $1 in
    builder | planner | reviewer | ops) export AGENT_TEAM_ROLE=$1 ;;
    coordinator | assistant) export CLAUDE_PROJECT_DIR=$TEAM_HOME ;;&
    coordinator | assistant | gate) unset AGENT_TEAM_TASK ;;
  esac
}

# Each run a <role>'s settings ask for on the corpus, one a line, its fields parted by the unit
# separator (no blank, so an empty field, as an entry with no matcher has, stays one): the corpus line's
# number, the settings file, the entry's matcher, the hook's command as written, the shell line
# that runs it (its placeholders filled, its args quoted after it) and the hook's input; a corpus
# line of the role that no entry's matcher takes has "-" for its file; with local, only the
# corpus's local lines: plan <role> [local]
plan() {
  local files
  mapfile -t files < <(settings_of "$1")
  jq -rn --arg role "$1" --arg only "${2:-}" --rawfile corpus "$CORPUS" --arg root "$REPO_ROOT" --arg wt "$WT" --arg job "$JOB" \
    --arg home "$TEAM_HOME" --arg task "$TASK_DIR" --arg channel "$ASSISTANT" --arg thread "$THREAD" \
    --arg session "$SESSION" --arg claude_tmp "${TMPDIR:-/tmp}/claude-$(id -u)" '
    def fill($map): reduce ($map | to_entries[]) as $e (.; split($e.key) | join($e.value));
    # A matcher of names and bars is a list of exact names; any other is a regular expression.
    def takes($tool): . as $m
      | if $m == null or $m == "" or $m == "*" then true
        elif ($m | test("^[A-Za-z0-9_|]+$")) then ($m | split("|") | index($tool)) != null
        else ($tool | test($m)) end;
    {"@WORKTREE@": $wt, "@JOB@": $job, "@TEAM_HOME@": $home, "@TEAM_CODE@": $root,
      "@ASSISTANT_CHANNEL@": $channel, "@ASSISTANT_THREAD@": $thread, "@SESSION@": $session,
      "@CLAUDE_TMP@": $claude_tmp} as $values
    | {"@TEAM_CODE@": $root, "$HOME/agent-team": $root, "@TASK_DIR@": $task, "@WORKTREE@": $wt} as $paths
    | [inputs as $s | input_filename as $file | $s.hooks.PreToolUse // [] | .[]
        | .matcher as $matcher | .hooks[] | {$file, $matcher, command, args: (.args // [])}] as $entries
    | $corpus | split("\n") | to_entries[] | select(.value != "") | (.key + 1) as $n | (.value | fromjson)
    | select((.roles | index($role)) and ($only != "local" or .local == true))
    | (walk(if type == "string" then fill($values) else . end)) as $case
    | [$entries[] | select(.matcher | takes($case.tool))] as $seen
    | if ($seen | length) == 0 then [$n, "-", "", "", "", ""] | map(tostring) | join("\u001f")
      else $seen[] | [($n | tostring), (.file | ltrimstr($root + "/")), (.matcher // ""), .command,
        ([.command | fill($paths)] + [.args[] | fill($paths) | @sh] | join(" ")),
        ({hook_event_name: "PreToolUse", session_id: $session, cwd: ($case.cwd // $wt), tool_name: $case.tool, tool_input: $case.input} | tojson)]
        | join("\u001f") end' "${files[@]}"
}

# Every call of the corpus a <role> makes reaches a hook of its settings, and each hook passes it
# in silence, on the machine as it stands; with local, every local call: passes <role> [local]
passes() {
  local role=$1 n file command line payload err status ran=0 failed=0
  while IFS=$'\x1f' read -r n file _ command line payload; do
    if [[ $file == - ]]; then
      echo "allowed.jsonl:$n: no PreToolUse hook of the settings of role $role sees this call, so the line tests nothing for it" >&2
      failed=1
      continue
    fi
    status=0
    # A here-string, written before the hook starts: a hook that ends without reading its input
    # leaves no writer to fail on a closed pipe.
    err=$(bash -c "$line" 2>&1 >/dev/null <<<"$payload") || status=$?
    ran=$((ran + 1))
    if ((status != 0)) || [[ -n $err ]]; then
      printf 'allowed.jsonl:%s: %s (%s) did not pass a call it must allow (role %s), %s: exit %s\n  %s\n  %s\n' \
        "$n" "$command" "$file" "$role" "$MACHINE" "$status" "$(sed -n "${n}p" "$CORPUS")" "$err" >&2
      failed=1
    fi
  done < <(plan "$@")
  ((ran > 0)) || { echo "the corpus holds no call of role $role that a hook sees${2:+, among its local ones}" >&2; return 1; }
  return "$failed"
}

# A <role>'s calls pass on the machine that holds the lease, and its local calls pass on a fenced
# machine and while the team holds offline too; every failure is named, by the corpus line's
# number and the machine's state: allowed_for <role>
allowed_for() {
  [[ -n ${UNTRACED_DEBUG+set} ]] || { untraced allowed_for "$@"; return; }
  local state=$HOME/.local/state/agent-team failed=0
  guard_sandbox || return 1
  session "$1"
  MACHINE="with the lease held"
  passes "$1" || failed=1
  MACHINE="on a fenced machine"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$state/fenced"
  passes "$1" local || failed=1
  rm "$state/fenced"
  MACHINE="while the team holds offline"
  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$state/offline"
  passes "$1" local || failed=1
  rm "$state/offline"
  return "$failed"
}

# Point the test's corpus at a copy of it whose line <n> holds another session's id in place of
# @SESSION@: another_session_on <n>
another_session_on() {
  sed "${1}s/@SESSION@/11111111-2222-4333-8444-555555555555/" "$CORPUS" >"$BATS_TEST_TMPDIR/allowed.jsonl"
  CORPUS=$BATS_TEST_TMPDIR/allowed.jsonl
}

@test "every line of the corpus is a call: roles the test knows, a tool, its input, and at most a cwd and local" {
  run jq -r '
    def bad: type != "object" or (keys - ["cwd", "input", "local", "roles", "tool"]) != []
      or (.roles | type != "array" or length == 0 or (. - $ARGS.positional) != [] or (unique | length) != length)
      or (.tool | type != "string" or . == "") or (.input | type != "object")
      or (has("cwd") and (.cwd | type != "string")) or (has("local") and .local != true);
    select(bad) | "allowed.jsonl:\(input_line_number): \(tojson)"' "$CORPUS" --args "${ROLES[@]}"
  assert_equal "$status" 0
  assert_equal "$output" ""
  [[ -s $CORPUS ]]
}

@test "a builder's allowed calls pass every hook its settings run on them" {
  allowed_for builder
}

@test "a planner's allowed calls pass every hook its settings run on them" {
  allowed_for planner
}

@test "a reviewer's allowed calls pass every hook its settings run on them" {
  allowed_for reviewer
}

@test "an ops session's allowed calls pass every hook its settings run on them" {
  allowed_for ops
}

@test "the coordinator's allowed calls pass every hook its settings run on them" {
  allowed_for coordinator
}

@test "the assistant's allowed calls pass every hook its settings run on them" {
  allowed_for assistant
}

@test "a gate agent's allowed calls pass every hook its settings run on them" {
  allowed_for gate
}

@test "a hook entry with no matcher sees every call of a role, and is run as its command" {
  # An entry with no matcher is every tool's: the plan's row for it has an empty field.
  echo '{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "true"}]}]}}' >"$BATS_TEST_TMPDIR/settings.json"
  settings_of() { echo "$BATS_TEST_TMPDIR/settings.json"; }
  run allowed_for builder
  assert_equal "$output" ""
  assert_equal "$status" 0
  [[ $(plan builder | wc -l) -eq $(jq -c 'select(.roles | index("builder"))' "$CORPUS" | wc -l) ]]
}

@test "a session's read of another session's background output fails, whatever CLAUDE_CODE_TMPDIR the shell set" {
  # The corpus's background-output line, given another session's id: the guard and the test read
  # one temporary directory, so the line now reads another session's records and must be named.
  local n
  n=$(grep -n '"@CLAUDE_TMP@/' "$CORPUS" | cut -d: -f1)
  [[ $n =~ ^[0-9]+$ ]]
  another_session_on "$n"
  export CLAUDE_CODE_TMPDIR=$BATS_TEST_TMPDIR/elsewhere
  run allowed_for builder
  assert_equal "$status" 1
  [[ $output == *"allowed.jsonl:$n: @TEAM_CODE@/bin/hooks/session-records-guard (settings/worker.json) did not pass"* ]]
}

@test "every PreToolUse hook entry of every settings file is run on a call of the corpus" {
  local role file entries ran
  # The files that hold a PreToolUse hook are the ones a role above loads.
  run bash -c 'cd "$1" && jq -r "select(.hooks.PreToolUse != null) | input_filename" settings/*.json \
    coordinator.settings.json assistant.settings.json bin/lib/gate-claude-settings.json toolkits/*/hooks/hooks.json | sort' _ "$REPO_ROOT"
  assert_equal "$status" 0
  assert_equal "$output" "$(for role in "${ROLES[@]}"; do settings_of "$role"; done | sort -u |
    while IFS= read -r file; do jq -e '.hooks.PreToolUse != null' "$file" >/dev/null && echo "${file#"$REPO_ROOT"/}"; done)"
  # Both sides are the plan's fields as written, parted by the unit separator.
  entries=$(for file in $output; do
    jq -r --arg file "$file" '.hooks.PreToolUse[] | (.matcher // "") as $m | .hooks[] | [$file, $m, .command] | join("\u001f")' "$REPO_ROOT/$file"
  done | sort -u)
  ran=$(for role in "${ROLES[@]}"; do plan "$role" | cut -d $'\x1f' -f 2-4; done | grep -v '^-' | sort -u)
  assert_equal "$ran" "$entries"
}

@test "the corpus holds fixtures only: no home path, no long id, no host or repository but the example ones" {
  run grep -nE '/home/|/Users/|[0-9]{12,}' "$CORPUS"
  assert_equal "$output" ""
  # Each host a call names is the loopback or an example one.
  run bash -c 'grep -oE "https?://[^/\" ]+" "$1" | sort -u | grep -vxE "https?://(127\.0\.0\.1|localhost)(:[0-9]+)?|https://(github\.com|example\.com|registry\.npmjs\.org)"' _ "$CORPUS"
  assert_equal "$output" ""
  run bash -c 'grep -oE "github\.com/[^/\" ]+/[^/\" ]+|--repo [^ \"]+|repos/[^/\" ]+/[^/\" ]+" "$1" | grep -v "example-org/example-repo"' _ "$CORPUS"
  assert_equal "$output" ""
  # Each address is at a fixture domain.
  run bash -c 'grep -oE "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+" "$1" | grep -v "@example\.com$"' _ "$CORPUS"
  assert_equal "$output" ""
}
