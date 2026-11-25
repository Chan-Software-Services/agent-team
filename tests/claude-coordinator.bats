#!/usr/bin/env bats
# bin/claude-coordinator: one coordinator at a time, only on the lease holder, launched as before.
load helpers/common

setup() {
  sandbox
  # This machine, home-pc, holds the lease; make_machine laptop builds the other one.
  hold_lease home-pc >/dev/null
  lock=$HOME/.local/state/agent-team/coordinator-launch.lock
  # claude answers `agents --json` from $BATS_TEST_TMPDIR/sessions.json as Claude Code 2.1.319's
  # printAgentsJson does: without --all it leaves out a background job with no process (no pid)
  # whose state is neither working nor blocked. A launch records its cwd and whether the launch
  # lock was free while it ran, and whether it inherited the lock's file.
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  # `claude mcp list` answers from $BATS_TEST_TMPDIR/mcp-list.txt: today's servers on home-pc.
  cat >"$BATS_TEST_TMPDIR/mcp-list.txt" <<'TXT'
Checking MCP server health…

claude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected
plugin:mongodb-atlas:mongodb-atlas: https://mcp.mongodb.com/ (HTTP) - ! Needs authentication
codegraph: codegraph serve --mcp - ✔ Connected
vercel: https://mcp.vercel.com (HTTP) - ✔ Connected
resend: https://mcp.resend.com/mcp (HTTP) - ✔ Connected
playwright: npx -y @playwright/mcp@0.0.83 - ✗ Failed to connect
TXT
  stub_script claude <<'EOF'
lock=$HOME/.local/state/agent-team/coordinator-launch.lock
if flock -n "$lock" true; then held=free; else held=held; fi
if [[ $1 == agents ]]; then
  echo "agents $held" >>"$STUB_CALLS/claude.lock"
  if [[ " $* " == *" --all "* ]]; then
    cat "$BATS_TEST_TMPDIR/sessions.json"
  else
    jq 'if type == "array" then map(select(.pid or .state == null or .state == "working" or .state == "blocked")) else . end' \
      "$BATS_TEST_TMPDIR/sessions.json" 2>/dev/null || cat "$BATS_TEST_TMPDIR/sessions.json"
  fi
  exit "$(cat "$BATS_TEST_TMPDIR/agents.status" 2>/dev/null || echo 0)"
fi
if [[ $1 == mcp ]]; then
  echo "mcp $held" >>"$STUB_CALLS/claude.lock"
  printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.mcp-cwd"
  cat "$BATS_TEST_TMPDIR/mcp-list.txt"
  exit "$(cat "$BATS_TEST_TMPDIR/mcp.status" 2>/dev/null || echo 0)"
fi
echo "launch $held" >>"$STUB_CALLS/claude.lock"
printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.cwd"
printf '%s\n' "$PATH" >>"$STUB_CALLS/claude.path"
# Each open file by device and inode, through /dev/fd as both Linux and macOS have it.
for fd in /dev/fd/*; do
  if [[ $(stat -L -c %d:%i "$fd" 2>/dev/null) == "$(stat -c %d:%i "$lock")" ]]; then
    echo "launch inherited the lock" >>"$STUB_CALLS/claude.lock"
  fi
done
echo "Started background session 7c3e9a10 (coordinator). Attach with: claude attach 7c3e9a10"
exit "$(cat "$BATS_TEST_TMPDIR/launch.status" 2>/dev/null || echo 0)"
EOF
}

# session <id|-> <sessionId> <name> <status> [<kind>]: one listed session as JSON, with a process.
session() {
  jq -cn --arg id "$1" --arg sid "$2" --arg name "$3" --arg status "$4" --arg kind "${5:-background}" \
    '{pid: 4242, cwd: "/somewhere", kind: $kind, startedAt: 1761100000000, sessionId: $sid,
      name: $name, status: $status} + (if $id == "-" then {} else {id: $id, state: "working"} end)'
}

# settled <id> <sessionId> <name> <state>: a background job the daemon holds with no process, as
# claude agents --json --all lists it: no pid and no status.
settled() {
  jq -cn --arg id "$1" --arg sid "$2" --arg name "$3" --arg state "$4" \
    '{id: $id, cwd: "/somewhere", kind: "background", startedAt: 1761100000000, sessionId: $sid,
      name: $name, state: $state}'
}

# sessions <session json>...: the list `claude agents --json --all` prints.
sessions() {
  printf '%s\n' "$@" | jq -s . >"$BATS_TEST_TMPDIR/sessions.json"
}

# The launch command line: today's, plus this checkout's manual, the coordinator's skills and its
# toolkit's MCP servers.
launch_argv() {
  jq -cn --arg state "$HOME/.local/state/agent-team" --arg code "$REPO_ROOT" \
    '["--bg", "--name", "coordinator",
    "--autocompact", "200k",
    "--mcp-config", "\($state)/coordinator.mcp.json",
    "--channels", "plugin:discord@claude-plugins-official",
    "--dangerously-skip-permissions",
    "--append-system-prompt-file", "\($code)/roles/coordinator.md",
    "--plugin-dir", "\($code)/plugins/coordinator-skills",
    "--settings", "\($state)/coordinator.settings.json",
    "You are the coordinator. Daniel talks to you on Discord. Wait for their messages."]'
}

assert_not_launched() {
  if [[ -e $STUB_CALLS/claude.cwd ]] || grep -q -- '"--bg"' "$STUB_CALLS/claude.log" 2>/dev/null; then
    echo "claude --bg was called: $(stub_calls claude)" >&2
    return 1
  fi
}

@test "--help prints the header" {
  run_bin -0 claude-coordinator --help
  assert_contains "$output" "Start the one session that owns #coordinator and the tasks' threads: the team's coordinator."
  assert_contains "$output" "Usage: claude-coordinator [--prompt <text>] [working-directory]"
  assert_equal "$(stub_calls claude)" ""
}

@test "with no coordinator live it launches as before, from the team home by default" {
  sessions "$(session 0a1b2c3d 0a1b2c3d-1111 T14-builder busy)" "$(session - 9f9f9f9f-2222 '' idle interactive)"
  run_bin -0 claude-coordinator
  assert_contains "$output" "Started background session 7c3e9a10"
  assert_equal "$(stub_calls claude)" "$(printf '%s\n%s\n%s' '["agents","--json","--all"]' '["mcp","list"]' "$(launch_argv)")"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$TEAM_HOME"
}

@test "the session gets the library's PATH: the tool directories from tools.lock first" {
  # Arch, where uname says Linux; Bun installed under HOME, which the caller's PATH lacks.
  export TEAM_OS_RELEASE=$BATS_TEST_TMPDIR/os-release
  echo ID=arch >"$TEAM_OS_RELEASE"
  mkdir -p "$HOME/.bun/bin"
  run_bin -0 claude-coordinator
  [[ :$(cat "$STUB_CALLS/claude.path"): == *":$HOME/.bun/bin:"*"$BATS_TEST_TMPDIR/stubs:"* ]] ||
    { echo "claude's PATH: $(cat "$STUB_CALLS/claude.path")" >&2; return 1; }
}

@test "the launch appends the manual and loads the skills plugin, both from its own checkout" {
  run_bin -0 claude-coordinator
  local argv manual plugin
  argv=$(stub_calls claude | tail -n 1)
  manual=$(jq -r 'index("--append-system-prompt-file") as $i | .[$i + 1]' <<<"$argv")
  plugin=$(jq -r 'index("--plugin-dir") as $i | .[$i + 1]' <<<"$argv")
  assert_equal "$manual" "$REPO_ROOT/roles/coordinator.md"
  assert_equal "$plugin" "$REPO_ROOT/plugins/coordinator-skills"
  [[ -f $manual && -f $plugin/.claude-plugin/plugin.json ]]
}

@test "its settings are the checkout's, with the hooks of the same checkout" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json
  # All but the servers denied, which the launch adds (the toolkit's tests below).
  assert_equal "$(jq -c 'del(.deniedMcpServers)' "$settings")" \
    "$(jq -c --arg code "$REPO_ROOT" 'walk(if type == "string" then gsub("@TEAM_CODE@"; $code) else . end)' \
      "$REPO_ROOT/coordinator.settings.json")"
  assert_equal "$(jq -r '[.hooks[][].hooks[].command] | .[]' "$settings")" \
    "\"$REPO_ROOT/bin/hooks/session-digest\""$'\n'"\"$REPO_ROOT/bin/hooks/stop-sweep\""$'\n'"\"$REPO_ROOT/bin/hooks/compact-hold\""$'\n'"\"$REPO_ROOT/bin/hooks/compact-hold\""$'\n'"\"$REPO_ROOT/bin/hooks/compact-hold\""$'\n'"\"$REPO_ROOT/bin/hooks/compact-hold\""$'\n'"\"$REPO_ROOT/bin/hooks/lease-fence\""$'\n'"\"$REPO_ROOT/bin/hooks/lease-fence\" --coordinator"
  [[ -x $REPO_ROOT/bin/hooks/session-digest && -x $REPO_ROOT/bin/hooks/stop-sweep && -x $REPO_ROOT/bin/hooks/compact-hold && -x $REPO_ROOT/bin/hooks/lease-fence ]]
  # compact-hold holds an auto-compaction, tells the coordinator after a tool call and reminds it
  # on each prompt, with no matcher; its PreCompact entry has no onFailure, so a broken hold lets
  # the compaction run. Its Stop reminder sits beside stop-sweep, in the one Stop entry.
  assert_equal "$(jq -c '[.hooks.PreCompact, .hooks.PostToolUse, .hooks.UserPromptSubmit] | map(map(del(.hooks[].command)))' "$settings")" \
    '[[{"hooks":[{"type":"command","timeout":30}]}],[{"hooks":[{"type":"command","timeout":10}]}],[{"hooks":[{"type":"command","timeout":10}]}]]'
  assert_equal "$(jq -c '.hooks.Stop | map(.hooks |= map(.command |= sub(".*/"; "") | .command |= rtrimstr("\"")))' "$settings")" \
    '[{"hooks":[{"type":"command","command":"stop-sweep"},{"type":"command","command":"compact-hold","timeout":10}]}]'
  [[ $(cat "$settings") != *"@TEAM_CODE@"* ]]
  assert_equal "$(jq .isolatePeerMachines "$settings")" true
  assert_equal "$(find "${settings%/*}" -name '*.json.*')" ""
}

@test "its settings name it in AGENT_TEAM_ROLE, the signal a hook sees in a team session" {
  run_bin -0 claude-coordinator
  assert_equal "$(jq -r .env.AGENT_TEAM_ROLE "$HOME/.local/state/agent-team/coordinator.settings.json")" coordinator
}

@test "its settings keep every tool and skill its manual and skills name, and what it uses with Daniel" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json skill tool
  keeps_named "$settings" "$REPO_ROOT/roles/coordinator.md" "$REPO_ROOT"/plugins/coordinator-skills/skills/*/SKILL.md
  # Its own skills, by their bare names too, which an override might reach.
  for skill in "$REPO_ROOT"/plugins/coordinator-skills/skills/*/; do
    skill=$(basename "$skill")
    assert_equal "$(jq -r --arg s "$skill" '.skillOverrides[$s] // "on"' "$settings")" on
  done
  # Discord stays; the claude.ai connectors are left to the launch's deny list; Claude Code's
  # built-in easel plugin, whose chart tool is an MCP tool Daniel never added to the coordinator's
  # toolkit, is off.
  assert_equal "$(jq -c '[.enabledPlugins["discord@claude-plugins-official"], .disableClaudeAiConnectors,
    .syncClaudeAiPlugins, .enabledPlugins["cc-plugin-plugin-authoring@builtin"], .enabledPlugins["cc-plugin-easel@builtin"]]' "$settings")" \
    '[true,null,false,false,false]'
  for tool in SendUserFile PushNotification CronCreate CronList CronDelete Monitor SendMessage ListAgents Agent \
    ReadNotifications TaskStop WebFetch WebSearch; do
    if jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null; then
      echo "denies $tool, which the coordinator may use with Daniel" >&2 && return 1
    fi
  done
  # A background session nobody watches cannot answer a question or leave plan mode.
  for tool in AskUserQuestion EnterPlanMode ExitPlanMode SendFeedback; do
    jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null ||
      { echo "no deny rule for $tool" >&2; return 1; }
  done
}

@test "its settings deny the tools it never calls, whose definitions every reply would carry" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json tool
  # A deny rule on a bare tool name takes the tool's definition out of the session's context.
  for tool in Artifact ArtifactComments ArtifactData ReportFindings ScheduleWakeup Workflow; do
    jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null ||
      { echo "no deny rule for $tool" >&2; return 1; }
  done
  # None of them is named in its manual or its skills, or keeps_named would say so.
  keeps_named "$settings" "$REPO_ROOT/roles/coordinator.md" "$REPO_ROOT"/plugins/coordinator-skills/skills/*/SKILL.md
}

@test "it gets no task reminder: the task list's tools are denied, and the reminder is off by its own switch" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json tool
  # Claude Code sends the reminder only to a session that has TaskUpdate, and never in the mode off.
  for tool in TaskCreate TaskGet TaskList TaskUpdate; do
    jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null ||
      { echo "no deny rule for $tool" >&2; return 1; }
  done
  assert_equal "$(jq -r .env.CLAUDE_CODE_TODO_REMINDER_MODE "$settings")" off
}

@test "every skill its manual and its skills name is one of its own plugin's, since the launch hides every other" {
  local skill named=0
  # The names keeps_named's pattern finds: `/<skill>`, skills/<skill>/SKILL.md and the `<skill>` skill.
  while IFS= read -r skill; do
    named=$((named + 1))
    [[ -d $REPO_ROOT/plugins/coordinator-skills/skills/$skill ]] ||
      { echo "names the skill $skill, which is not in plugins/coordinator-skills/skills" >&2; return 1; }
  done < <(grep -ohE '`/[a-z][a-z0-9-]*`|skills/[a-z][a-z0-9-]*/SKILL\.md|the `[a-z][a-z0-9-]*` skill' \
    "$REPO_ROOT/roles/coordinator.md" "$REPO_ROOT"/plugins/coordinator-skills/skills/*/SKILL.md |
    sed -E 's#^`/##; s#`$##; s#^skills/##; s#/SKILL\.md$##; s#^the `##; s#` skill$##' | sort -u)
  # The pattern finds some: the manual names its skills this way.
  ((named > 0))
}

# personal_skill <directory> [<name>]: a skill in the user's skills directory, its frontmatter
# naming it <name> when given.
personal_skill() {
  local name=''
  [[ -z ${2:-} ]] || name="name: $2"$'\n'
  mkdir -p "$HOME/.claude/skills/$1"
  printf -- '---\n%sdescription: A skill of the user.\n---\n\nname: not-frontmatter\n' "$name" \
    >"$HOME/.claude/skills/$1/SKILL.md"
}

@test "its skill listing is kept to its own skills: the synced and bundled ones off, Discord's for Daniel to type, each personal one off" {
  personal_skill code-review
  personal_skill grilling
  personal_skill renamed shown-as
  # One Daniel adds later is off at the next launch, with no change to the settings.
  personal_skill added-later
  # A personal skill with the name of one of its own: an override by the bare name might reach its own.
  personal_skill handoff
  personal_skill retro
  # Not a skill: a directory with no SKILL.md, and a file.
  mkdir -p "$HOME/.claude/skills/synced"
  touch "$HOME/.claude/skills/notes.md"
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json
  assert_equal "$(jq -c '[.syncClaudeAiSkills, .disableBundledSkills]' "$settings")" '[false,true]'
  # The Discord plugin's two skills are Daniel's to type, never the model's to call.
  assert_equal "$(jq -c '.skillOverrides | to_entries | sort_by(.key) | map("\(.key)=\(.value)")' "$settings")" \
    '["added-later=off","code-review=off","discord:access=user-invocable-only","discord:configure=user-invocable-only","grilling=off","renamed=off","shown-as=off"]'
}

@test "with CLAUDE_CONFIG_DIR set, the personal skills turned off are that directory's" {
  personal_skill code-review
  mkdir -p "$BATS_TEST_TMPDIR/config/skills/wizard"
  printf -- '---\ndescription: A skill.\n---\n' >"$BATS_TEST_TMPDIR/config/skills/wizard/SKILL.md"
  CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/config run_bin -0 claude-coordinator
  assert_equal "$(jq -c '.skillOverrides | [.wizard, .["code-review"]]' "$HOME/.local/state/agent-team/coordinator.settings.json")" \
    '["off",null]'
}

@test "with no personal skills directory it turns off none" {
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c '.skillOverrides | keys' "$HOME/.local/state/agent-team/coordinator.settings.json")" \
    '["discord:access","discord:configure"]'
}

# The names in the settings' deniedMcpServers, one per line, sorted.
denied() {
  jq -r '.deniedMcpServers[].serverName' "$HOME/.local/state/agent-team/coordinator.settings.json" | sort
}

@test "its MCP servers come only from its toolkit, by --mcp-config, never --strict-mcp-config, which would cut Discord" {
  run_bin -0 claude-coordinator
  local argv mcp=$HOME/.local/state/agent-team/coordinator.mcp.json
  argv=$(stub_calls claude | tail -n 1)
  assert_equal "$(jq -r 'index("--mcp-config") as $i | .[$i + 1]' <<<"$argv")" "$mcp"
  assert_equal "$(jq -r 'map(select(. == "--mcp-config")) | length' <<<"$argv")" 1
  assert_equal "$(jq 'index("--strict-mcp-config")' <<<"$argv")" null
  assert_equal "$(jq -c . "$mcp")" "$(jq -c . "$REPO_ROOT/toolkits/coordinator/.mcp.json")"
  assert_equal "$(jq -c .mcpServers "$mcp")" '{}'
  assert_equal "$(find "${mcp%/*}" -name '*.json.*')" ""
}

@test "its settings deny every server claude mcp list names in its working directory, every claude.ai connector included" {
  printf '%s\n' 'claude.ai Gmail: https://gmail.mcp.claude.com/mcp - ✔ Connected' >>"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(cat "$STUB_CALLS/claude.mcp-cwd")" "$TEAM_HOME"
  assert_equal "$(denied)" "$(printf '%s\n' 'claude.ai Claude Docs' 'claude.ai Gmail' codegraph playwright \
    plugin:mongodb-atlas:mongodb-atlas resend vercel)"
  # Its toolkit keeps no connector, by Daniel's choice of 2026-10-27: its records stay in local
  # files and the team home.
  assert_equal "$(jq -c . "$REPO_ROOT/toolkits/coordinator/connectors.json")" '[]'
  # The connectors stay on, so one its toolkit keeps would load; every other is denied by name.
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json
  assert_equal "$(jq 'has("disableClaudeAiConnectors")' "$settings")" false
  # The checkout's own settings name no server: the list is the launch's.
  assert_equal "$(jq 'has("deniedMcpServers")' "$REPO_ROOT/coordinator.settings.json")" false
}

@test "a connector its toolkit keeps is kept by its exact name" {
  code_checkout
  echo '["claude.ai Claude Docs"]' >"$CODE_CHECKOUT/toolkits/coordinator/connectors.json"
  run_bin -0 claude-coordinator
  assert_equal "$(denied | grep -c '^claude\.ai ')" 0
  echo '["claude.ai Claude"]' >"$CODE_CHECKOUT/toolkits/coordinator/connectors.json"
  run_bin -0 claude-coordinator
  assert_equal "$(denied | grep '^claude\.ai ')" 'claude.ai Claude Docs'
}

@test "a missing connectors file refuses the launch, naming it, and launches nothing" {
  code_checkout
  rm "$CODE_CHECKOUT/toolkits/coordinator/connectors.json"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$stderr" "claude-coordinator: cannot read the connectors to keep, $CODE_CHECKOUT/toolkits/coordinator/connectors.json (a JSON list of names), so the connectors to deny are unknown"
  if grep -q -- '"--bg"' "$STUB_CALLS/claude.log" 2>/dev/null; then
    echo "claude --bg was called: $(stub_calls claude)" >&2
    return 1
  fi
}

@test "the Discord plugin and its channel stay on, and its servers are never denied" {
  printf '%s\n' 'plugin:discord:discord: bun run start - ✔ Connected' 'other: x - ✔ Connected' \
    >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  local argv settings=$HOME/.local/state/agent-team/coordinator.settings.json
  argv=$(stub_calls claude | tail -n 1)
  assert_equal "$(jq -r 'index("--channels") as $i | .[$i + 1]' <<<"$argv")" plugin:discord@claude-plugins-official
  assert_equal "$(jq '.enabledPlugins["discord@claude-plugins-official"]' "$settings")" true
  assert_equal "$(denied)" other
}

@test "a server in its toolkit reaches it and is not denied, with @TEAM_CODE@ naming the checkout" {
  code_checkout
  cat >"$CODE_CHECKOUT/toolkits/coordinator/.mcp.json" <<'JSON'
{"mcpServers": {"notes": {"command": "node", "args": ["@TEAM_CODE@/servers/notes.mjs"]}}}
JSON
  printf '%s\n' 'notes: node x - ✔ Connected' 'vercel: https://mcp.vercel.com (HTTP) - ✔ Connected' \
    >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c .mcpServers "$HOME/.local/state/agent-team/coordinator.mcp.json")" \
    "$(jq -cn --arg code "$CODE_CHECKOUT" '{notes: {command: "node", args: ["\($code)/servers/notes.mjs"]}}')"
  assert_equal "$(denied)" vercel
}

@test "with no server listed it denies none" {
  echo 'No MCP servers configured. Use `claude mcp add` to add a server.' >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c .deniedMcpServers "$HOME/.local/state/agent-team/coordinator.settings.json")" '[]'
}

@test "with nothing listed it denies none" {
  printf '\n  \n' >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c .deniedMcpServers "$HOME/.local/state/agent-team/coordinator.settings.json")" '[]'
  : >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c .deniedMcpServers "$HOME/.local/state/agent-team/coordinator.settings.json")" '[]'
  # Claude Code's other wording of an empty list, after the health line.
  printf '%s\n' 'Checking MCP server health…' '' 'No MCP servers configured. Run `claude mcp add` to add one.' \
    >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c .deniedMcpServers "$HOME/.local/state/agent-team/coordinator.settings.json")" '[]'
}

@test "a list it cannot read refuses the launch, naming its first line, so a changed format never starts it with every server" {
  printf '%s\n' '' 'Checking MCP server health…' '' '✔ codegraph (codegraph serve --mcp)' \
    '✔ vercel (https://mcp.vercel.com)' >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$stderr" "claude-coordinator: claude mcp list printed lines but named no server in its format (\"<name>: <what it runs> - <health>\"), so the servers to deny are unknown; its first line: Checking MCP server health…"
  assert_not_launched
  assert_equal "$(find "$HOME/.local/state/agent-team" -name 'coordinator.settings.json*')" ""
  # One server it reads is enough: the lines it cannot read are not servers.
  printf '%s\n' 'Checking MCP server health…' '' 'vercel: https://mcp.vercel.com (HTTP) - ✔ Connected' \
    '✔ codegraph (codegraph serve --mcp)' >"$BATS_TEST_TMPDIR/mcp-list.txt"
  run_bin -0 claude-coordinator
  assert_equal "$(denied)" vercel
}

@test "a failed claude mcp list refuses the launch, so no coordinator starts with servers it should not have" {
  echo 1 >"$BATS_TEST_TMPDIR/mcp.status"
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "claude-coordinator: claude mcp list failed, so the servers to deny are unknown"
  assert_not_launched
}

@test "it compacts at 200k tokens, by the launch flag, which no settings scope preempts" {
  run_bin -0 claude-coordinator
  local argv
  argv=$(stub_calls claude | tail -n 1)
  assert_equal "$(jq -r 'index("--autocompact") as $i | .[$i + 1]' <<<"$argv")" 200k
  assert_equal "$(jq -r 'map(select(. == "--autocompact")) | length' <<<"$argv")" 1
  # The prompt stays last, so no flag can take it as a value.
  assert_equal "$(jq -r '.[-1]' <<<"$argv")" "You are the coordinator. Daniel talks to you on Discord. Wait for their messages."
}

@test "its settings compact it while idle from 100k tokens, and leave the compaction window to the flag" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json
  assert_equal "$(jq .idleCompaction "$settings")" true
  assert_equal "$(jq -r '.env.CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS' "$settings")" 100000
  assert_equal "$(jq '.env.CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS | type' "$settings")" '"string"'
  assert_equal "$(jq 'has("autoCompactWindow")' "$settings")" false
  assert_equal "$(jq '.env | has("CLAUDE_CODE_AUTO_COMPACT_WINDOW")' "$settings")" false
}

@test "its Discord reply, react and edit_message, and its Bash, and nothing else, go through the fence hook" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json tool
  # A matcher of names and | lists those tools exactly.
  for tool in reply react edit_message; do
    assert_equal "$(jq -r --arg tool "mcp__plugin_discord_discord__$tool" '.hooks.PreToolUse[]
      | select(.matcher | split("|") | index($tool)) | .hooks[].command' "$settings")" "\"$REPO_ROOT/bin/hooks/lease-fence\""
  done
  assert_equal "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$settings")" \
    "\"$REPO_ROOT/bin/hooks/lease-fence\" --coordinator"
  assert_equal "$(jq -r '[.hooks.PreToolUse[].matcher | split("|") | length] | add' "$settings")" 4
  jq -e '.hooks.PreToolUse[].matcher | test("^[A-Za-z0-9_|]+$")' "$settings"
}

@test "its settings deny sudo, and leave it free to start Claude sessions" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json command
  for command in "sudo" "sudo -n true" "sudo pacman -S jq"; do
    denied_in "$settings" "$command" || { echo "allows: $command" >&2; return 1; }
  done
  for command in "claude --bg --name x go" "claude -p hi" "claude agents" "grep -rn sudo tests"; do
    if denied_in "$settings" "$command"; then echo "denies: $command" >&2; return 1; fi
  done
}

@test "its settings deny its own call of team-land, the landing team-merge and the drill run for it" {
  run_bin -0 claude-coordinator
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json command
  for command in "team-land https://github.com/o/p/pull/6 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" \
    "team-land --task T7 https://github.com/o/p/pull/6 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" \
    "$HOME/agent-team/bin/team-land https://github.com/o/p/pull/6 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" \
    "$HOME/agent-team/bin/team-land --help"; do
    denied_in "$settings" "$command" || { echo "allows: $command" >&2; return 1; }
  done
  # team-merge and the drill start team-land themselves, with no Bash call of the coordinator's.
  for command in "team-merge T7" "$HOME/agent-team/bin/team-merge T7 --pr https://github.com/o/p/pull/6" \
    "tests/merge-queue-drill org/scratch" "team-lander T7" "team-state T7"; do
    if denied_in "$settings" "$command"; then echo "denies: $command" >&2; return 1; fi
  done
}

@test "it launches from the working directory it is given" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run_bin -0 claude-coordinator "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
}

@test "--prompt replaces the first prompt, as team-resume starts it" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run_bin -0 claude-coordinator --prompt "Follow the resume skill." "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$BATS_TEST_TMPDIR/elsewhere"
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv | jq -c '.[-1] = "Follow the resume skill."')"
}

@test "a malformed command line is a usage error, launching nothing" {
  local args
  for args in "--prompt" "--prompt ''" "a b" "--other" "$HOME/agent-team --prompt x"; do
    eval "run_bin -2 --separate-stderr claude-coordinator $args"
    assert_contains "$stderr" "usage: claude-coordinator [--prompt <text>] [working-directory]"
  done
  assert_equal "$(stub_calls claude)" ""
}

@test "a live coordinator refuses the launch, naming its session id" {
  sessions "$(session 0a1b2c3d 0a1b2c3d-1111 T14-builder busy)" "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator idle)"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$output" ""
  assert_contains "$stderr" "claude-coordinator: a coordinator is already live: session 5e6f7a8b"
  assert_equal "$(stub_calls claude)" '["agents","--json","--all"]'
  assert_not_launched
}

@test "a busy coordinator refuses the launch too" {
  sessions "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator busy)"
  run_bin -1 claude-coordinator
  assert_contains "$output" "session 5e6f7a8b"
  assert_not_launched
}

@test "a background coordinator whose turn is done and whose process the daemon settled refuses the launch" {
  sessions "$(session 0a1b2c3d 0a1b2c3d-1111 T14-builder busy)" "$(settled 6d7e8f90 6d7e8f90-4444 coordinator "done")"
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "claude-coordinator: a coordinator is already live: session 6d7e8f90"
  assert_equal "$(stub_calls claude)" '["agents","--json","--all"]'
  assert_not_launched
}

@test "a failed background coordinator refuses the launch too, since a message may wake it" {
  sessions "$(settled 5e6f7a8b 5e6f7a8b-3333 coordinator failed)"
  run_bin -1 claude-coordinator
  assert_contains "$output" "session 5e6f7a8b"
  assert_not_launched
}

@test "a stopped coordinator, which nothing wakes on its own, does not refuse the launch" {
  sessions "$(settled 1a2b3c4d 1a2b3c4d-5555 coordinator stopped)" "$(settled 6d7e8f90 6d7e8f90-4444 coordinator stopped)" \
    "$(settled 0a1b2c3d 0a1b2c3d-1111 T14-builder "done")"
  run_bin -0 claude-coordinator
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
}

@test "an interactive coordinator, which has no short id, is named by its session id" {
  sessions "$(session - d4c3b2a1-4444-5555 coordinator idle interactive)"
  run_bin -1 claude-coordinator
  assert_contains "$output" "session d4c3b2a1"
  assert_not_launched
}

@test "only a session named exactly coordinator counts" {
  sessions "$(session 11111111 11111111-a T14-coordinator busy)" "$(session 22222222 22222222-b coordinator-old idle)" \
    "$(session 33333333 33333333-c Coordinator idle)"
  run_bin -0 claude-coordinator
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
}

@test "an unreadable session list refuses the launch" {
  echo 'not json' >"$BATS_TEST_TMPDIR/sessions.json"
  run_bin -1 claude-coordinator
  assert_contains "$output" "cannot read the session list (claude agents --json --all)"
  assert_not_launched

  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  echo 1 >"$BATS_TEST_TMPDIR/agents.status"
  run_bin -1 claude-coordinator
  assert_contains "$output" "cannot read the session list (claude agents --json --all)"
  assert_not_launched
}

@test "it holds the launch lock across the check and the launch, and the session does not inherit it" {
  run_bin -0 claude-coordinator
  assert_equal "$(cat "$STUB_CALLS/claude.lock")" "$(printf 'agents held\nmcp held\nlaunch held')"
  [[ -f $lock ]]
}

@test "a second launch while the lock is held exits 1 at once, without asking claude anything" {
  mkdir -p "${lock%/*}"
  exec {held}>"$lock"
  flock -n "$held"
  guard_sandbox
  run -1 --separate-stderr timeout 10 "$REPO_ROOT/bin/claude-coordinator"
  exec {held}>&-
  assert_contains "$stderr" "claude-coordinator: another claude-coordinator is launching right now"
  assert_contains "$stderr" "$lock"
  assert_equal "$(stub_calls claude)" ""
}

@test "the lock is released when it exits, so the next launch passes" {
  sessions "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator idle)"
  run_bin -1 claude-coordinator
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  run_bin -0 claude-coordinator
  run_bin -0 claude-coordinator
  assert_equal "$(grep -c -- '"--bg"' "$STUB_CALLS/claude.log")" 2
}

@test "a failed launch exits with claude's status" {
  echo 3 >"$BATS_TEST_TMPDIR/launch.status"
  run_bin -3 claude-coordinator
}

@test "with the lease held by the other machine it refuses, naming the holder and the next step" {
  make_machine laptop
  run_bin -0 team-lease release
  on_machine laptop run_bin -0 team-lease take
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$output" ""
  assert_contains "$stderr" "team-lease: home-pc no longer holds the lease: laptop holds it (epoch 2"
  assert_contains "$stderr" "claude-coordinator: laptop holds the lease: run team-resume --wait here, then hand off there once it says this machine is ready"
  assert_not_launched
  [[ ! -e $HOME/.local/state/agent-team/coordinator.settings.json ]]
}

@test "with GitHub unreachable it refuses: a coordinator never starts offline" {
  git -C "${TEAM_HOME:?}" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "team-lease: GitHub is unreachable"
  assert_contains "$stderr" "claude-coordinator: GitHub unreachable; a coordinator never starts offline"
  assert_not_launched
}

@test "with the lease released, or held at an epoch this machine has no record of, it refuses with the lease's reason" {
  run_bin -0 team-lease release
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "team-lease: the lease is released (last held by home-pc, epoch 1); take it with team-lease take"
  assert_contains "$stderr" "claude-coordinator: a coordinator starts only on the machine that holds the lease"
  assert_not_launched

  run_bin -0 team-lease take
  rm "$HOME/.local/state/agent-team/lease.json"
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "but this machine has no record of taking it"
  assert_contains "$stderr" "claude-coordinator: a coordinator starts only on the machine that holds the lease"
  assert_not_launched
}

@test "without a team name for this machine it refuses" {
  rm "$HOME/.config/agent-team/machine"
  run_bin -1 --separate-stderr claude-coordinator
  assert_contains "$stderr" "this machine has no team name"
  assert_not_launched
}

@test "the lease is checked under the launch lock, and no git the check runs inherits the lock's file" {
  local real_git
  real_git=$(command -v git)
  # git, first on PATH: records whether the launch lock is held and whether it has the lock's
  # file open, then runs the real git.
  {
    echo '#!/usr/bin/env bash'
    printf 'lock=%q calls=%q real=%q\n' "$lock" "$STUB_CALLS/git.lock" "$real_git"
    cat <<'SH'
for fd in /dev/fd/*; do
  if [[ $(stat -L -c %d:%i "$fd" 2>/dev/null) == "$(stat -c %d:%i "$lock")" ]]; then
    echo "git inherited the lock" >>"$calls"
  fi
done
if flock -n "$lock" true; then echo "git: lock free" >>"$calls"; else echo "git: lock held" >>"$calls"; fi
exec "$real" "$@"
SH
  } >"$BATS_TEST_TMPDIR/stubs/git"
  chmod +x "$BATS_TEST_TMPDIR/stubs/git"
  run_bin -0 claude-coordinator
  assert_equal "$(sort -u "$STUB_CALLS/git.lock")" "git: lock held"
}

# The worker login (bin/lib/github-login.sh): with bin/lib/worker-login naming an account, the
# session's settings point gh and git at that login's own directory, and a launch refuses while
# the login is named but not on this machine.

# The refusal when the login is named but its file is not usable, by what is wrong with the file:
# login_refusal <login> <what of hosts.yml>
login_refusal() {
  # shellcheck disable=SC2088 # ~ is part of the message as the script prints it
  echo "claude-coordinator: the worker login $1 is not on this machine (~/.config/agent-team/gh-worker/hosts.yml $2): Daniel's team-secrets restore brings it (the secret worker-github-login)"
}

@test "with the worker login on, its settings hold the login's environment, and nothing else changes" {
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json off
  code_checkout
  worker_login_off
  run_bin -0 claude-coordinator
  off=$(jq -c . "$settings")
  worker_login_on
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c '[.env.GH_CONFIG_DIR, .env.GH_TOKEN, .env.GITHUB_TOKEN]' "$settings")" \
    "$(jq -cn --arg dir "$HOME/.config/agent-team/gh-worker" '[$dir, "", ""]')"
  assert_equal "$(jq -c 'del(.env.GH_CONFIG_DIR, .env.GH_TOKEN, .env.GITHUB_TOKEN)' "$settings")" "$off"
  assert_equal "$(grep -c -- '"--bg"' "$STUB_CALLS/claude.log")" 2
}

@test "with the worker login off, its settings are today's: the template, with no login of its own" {
  local settings=$HOME/.local/state/agent-team/coordinator.settings.json
  code_checkout
  worker_login_on
  worker_login_off
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c 'del(.deniedMcpServers, .skillOverrides)' "$settings")" \
    "$(jq -c --arg code "$CODE_CHECKOUT" 'walk(if type == "string" then gsub("@TEAM_CODE@"; $code) else . end) | del(.skillOverrides)' \
      "$CODE_CHECKOUT/coordinator.settings.json")"
  assert_equal "$(jq -c '.env | keys | map(select(test("^(GH_|GITHUB_)")))' "$settings")" '[]'
}

@test "with the worker login named but not on this machine, it refuses before writing or starting anything" {
  local dir=$HOME/.config/agent-team/gh-worker state=$HOME/.local/state/agent-team
  code_checkout
  worker_login_on team-bot
  rm "$dir/hosts.yml"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$stderr" "$(login_refusal team-bot 'is missing')"
  : >"$dir/hosts.yml"
  chmod 600 "$dir/hosts.yml"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$stderr" "$(login_refusal team-bot 'is empty')"
  echo 'github.com:' >"$dir/hosts.yml"
  chmod 644 "$dir/hosts.yml"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$stderr" "$(login_refusal team-bot 'is mode 644, not 600')"
  # It asked only for the session list, the check it makes first.
  assert_equal "$(stub_calls claude | sort -u)" '["agents","--json","--all"]'
  assert_not_launched
  [[ ! -e $state/coordinator.settings.json && ! -e $state/coordinator.mcp.json ]]
}

@test "a malformed worker login constant refuses the launch with the reader's message" {
  local state=$HOME/.local/state/agent-team
  code_checkout
  worker_login_on
  printf '%s\n' 'login=team-bot' 'login=other' >"$CODE_CHECKOUT/bin/lib/worker-login"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$stderr" "claude-coordinator: $CODE_CHECKOUT/bin/lib/worker-login is not one login=<a GitHub login> line"
  assert_not_launched
  [[ ! -e $state/coordinator.settings.json && ! -e $state/coordinator.mcp.json ]]
}

@test "the login check comes after the lock and the one-session check" {
  code_checkout
  worker_login_on team-bot
  rm "$HOME/.config/agent-team/gh-worker/hosts.yml"
  sessions "$(session 5e6f7a8b 5e6f7a8b-3333 coordinator idle)"
  run_bin -1 --separate-stderr claude-coordinator
  assert_equal "$stderr" "claude-coordinator: a coordinator is already live: session 5e6f7a8b; stop it with claude stop 5e6f7a8b first"
  mkdir -p "${lock%/*}"
  exec {held}>"$lock"
  flock -n "$held"
  guard_sandbox
  run -1 --separate-stderr timeout 10 "$CODE_CHECKOUT/bin/claude-coordinator"
  exec {held}>&-
  assert_equal "$stderr" "claude-coordinator: another claude-coordinator is launching right now (it holds $lock)"
}

# Its session runs no command-guard, so its own settings refuse the plain spelling of a change to
# its GitHub login, an emptied environment among it, which drops GH_CONFIG_DIR; the team's scripts
# that choose a login do so inside themselves, unseen here.
@test "its settings deny a command that sets or unsets its GitHub login, and leave gh and team-merge" {
  local settings=$REPO_ROOT/coordinator.settings.json rule command
  for rule in 'Bash(*GH_CONFIG_DIR*)' 'Bash(*GH_TOKEN*)' 'Bash(*GITHUB_TOKEN*)' \
    'Bash(*env -i*)' 'Bash(*env --i*)' 'Bash(*env - *)' 'Bash(*exec -c*)'; do
    jq -e --arg r "$rule" '.permissions.deny | index($r) != null' "$settings" >/dev/null ||
      { echo "coordinator.settings.json does not deny $rule" >&2; return 1; }
  done
  for command in 'GH_CONFIG_DIR= gh auth status' 'export GH_TOKEN=x' 'env -u GITHUB_TOKEN gh api user' \
    'unset GH_CONFIG_DIR GH_TOKEN' 'cd ~ && GH_CONFIG_DIR=/tmp/x gh pr list' \
    'env -i gh auth status' 'env -i PATH=/usr/bin HOME=/tmp/x gh pr list' 'cd ~ && env -iC /tmp gh api user' \
    'env --ignore-environment gh auth status' 'env --ignore-env git push' 'env - gh pr list' \
    'exec -c gh auth status' 'bash -c "env -i gh api user"'; do
    denied_in "$settings" "$command" || { echo "allows: $command" >&2; return 1; }
  done
  for command in 'gh auth status' 'gh pr list' 'team-merge https://github.com/me/shop/pull/5' \
    'team-next T5 --ci' 'git push origin feat/T1-x' 'env A=1 team-state T5' 'env -u HOME ls'; do
    if denied_in "$settings" "$command"; then echo "denies: $command" >&2; return 1; fi
  done
}

@test "no command its manual or its skills name holds a GitHub login variable, which its settings deny" {
  local found
  found=$(grep -rnE 'GH_CONFIG_DIR|GH_TOKEN|GITHUB_TOKEN' "$REPO_ROOT/roles/coordinator.md" "$REPO_ROOT/plugins/coordinator-skills/" || true)
  assert_equal "$found" ""
}

@test "its header says the session runs on the worker login when one is named" {
  run_bin -0 claude-coordinator --help
  assert_contains "$(tr -s ' \n' '  ' <<<"$output")" "Its session runs on the worker login when bin/lib/worker-login names one"
}

# The model config, the team home's models.toml (bin/team-models, sops/models.md): the session
# launches on the coordinator line's model and effort, its subagents on the line's subagent
# fields, and each launch is one line of the team home's sessions.jsonl (launch_log in
# bin/lib/launch.sh).

# models <toml line>...: the team home's models.toml, as those lines.
models() {
  printf '%s\n' "$@" >"$TEAM_HOME/models.toml"
}

# The launch command line with the model flags given after --name: argv_with <flag>...
argv_with() {
  launch_argv | jq -c '.[0:3] + $ARGS.positional + .[3:]' --args -- "$@"
}

# sessions.jsonl's lines, each but its ts, which every test reads.
session_lines() {
  jq -c 'del(.ts)' "$TEAM_HOME/sessions.jsonl"
}

# The user settings' model and effort, which a launch with nothing named runs on: user_settings <json>
user_settings() {
  mkdir -p "$HOME/.claude"
  echo "$1" >"$HOME/.claude/settings.json"
}

@test "with no models.toml it launches as before, logging the settings' word as Claude Code reads it" {
  user_settings '{"model": "opus", "effortLevel": "high", "modelSettings": {"opus": {"effortLevel": "xhigh"}}}'
  run_bin -0 claude-coordinator
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
  assert_equal "$(session_lines)" \
    '{"machine":"home-pc","name":"coordinator","category":"coordinator","model":"opus","model_from":"settings","effort":"xhigh","effort_from":"settings","id":"7c3e9a10"}'
  [[ $(jq -r .ts "$TEAM_HOME/sessions.jsonl") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  # Its settings' env carries no subagent choice.
  assert_equal "$(jq -c '.env | [has("CLAUDE_CODE_SUBAGENT_MODEL"), has("CLAUDE_CODE_SUBAGENT_EFFORT")]' "$HOME/.local/state/agent-team/coordinator.settings.json")" '[false,false]'
}

@test "with no model in any settings it logs Claude Code's default" {
  run_bin -0 claude-coordinator
  assert_equal "$(session_lines)" \
    '{"machine":"home-pc","name":"coordinator","category":"coordinator","model":"default","model_from":"default","effort":"default","effort_from":"default","id":"7c3e9a10"}'
}

@test "the coordinator line's model and effort are its flags, its subagent fields its settings' env, all logged" {
  models '"default" = { model = "opus", effort = "high" }' \
    '"coordinator" = { model = "sonnet", subagent_model = "haiku", subagent_effort = "low" }' \
    '"assistant" = { model = "fable", effort = "max" }'
  run_bin -0 claude-coordinator
  assert_equal "$(stub_calls claude | tail -n 1)" "$(argv_with --model sonnet --effort high)"
  assert_equal "$(jq -c '.env | {CLAUDE_CODE_SUBAGENT_MODEL, CLAUDE_CODE_SUBAGENT_EFFORT}' "$HOME/.local/state/agent-team/coordinator.settings.json")" \
    '{"CLAUDE_CODE_SUBAGENT_MODEL":"haiku","CLAUDE_CODE_SUBAGENT_EFFORT":"low"}'
  # The template's env stays as it is beside them.
  assert_equal "$(jq -c '.env | del(.CLAUDE_CODE_SUBAGENT_MODEL, .CLAUDE_CODE_SUBAGENT_EFFORT)' "$HOME/.local/state/agent-team/coordinator.settings.json")" \
    "$(jq -c --arg code "$REPO_ROOT" '.env | map_values(gsub("@TEAM_CODE@"; $code))' "$REPO_ROOT/coordinator.settings.json")"
  assert_equal "$(session_lines)" \
    '{"machine":"home-pc","name":"coordinator","category":"coordinator","model":"sonnet","model_from":"config","effort":"high","effort_from":"config","id":"7c3e9a10","subagent_model":"haiku","subagent_effort":"low"}'
}

@test "a line of default passes nothing for its axis, so the settings' word stands" {
  user_settings '{"model": "opus", "effortLevel": "medium"}'
  models '"default" = { model = "sonnet", effort = "high" }' '"coordinator" = { model = "default", subagent_model = "default" }'
  run_bin -0 claude-coordinator
  assert_equal "$(stub_calls claude | tail -n 1)" "$(argv_with --effort high)"
  assert_equal "$(jq -c '.env | has("CLAUDE_CODE_SUBAGENT_MODEL")' "$HOME/.local/state/agent-team/coordinator.settings.json")" false
  assert_equal "$(session_lines)" \
    '{"machine":"home-pc","name":"coordinator","category":"coordinator","model":"opus","model_from":"settings","effort":"high","effort_from":"config","id":"7c3e9a10"}'
}

@test "changing the coordinator's line between two launches changes the second, and each is logged" {
  models '"default" = { model = "opus", effort = "high" }'
  run_bin -0 claude-coordinator
  models '"default" = { model = "opus", effort = "high" }' '"coordinator" = { model = "fable", effort = "medium" }'
  run_bin -0 claude-coordinator
  assert_equal "$(stub_calls claude | grep -F '"--bg"')" "$(argv_with --model opus --effort high)
$(argv_with --model fable --effort medium)"
  assert_equal "$(jq -c '[.model, .effort]' "$TEAM_HOME/sessions.jsonl")" '["opus","high"]
["fable","medium"]'
}

@test "a models.toml that does not read warns and launches on the settings' word, logged settings" {
  user_settings '{"model": "opus"}'
  models '"default" = { model = "opus", effort = "high" }' '"coordinatr" = { model = "sonet" }'
  local first
  first=$("$REPO_ROOT/bin/team-models" --check 2>&1 | head -n 1)
  [[ -n $first ]]
  run_bin -0 --separate-stderr claude-coordinator
  assert_equal "$stderr" "claude-coordinator: models.toml does not read: $first; launching on the settings' model"
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
  assert_equal "$(session_lines)" \
    '{"machine":"home-pc","name":"coordinator","category":"coordinator","model":"opus","model_from":"settings","effort":"default","effort_from":"default","id":"7c3e9a10"}'
}

@test "a sessions.jsonl that cannot be written is a warning, and the launch stands" {
  mkdir "$TEAM_HOME/sessions.jsonl"
  run_bin -0 --separate-stderr claude-coordinator
  assert_equal "$output" "Started background session 7c3e9a10 (coordinator). Attach with: claude attach 7c3e9a10"
  assert_contains "$stderr" "claude-coordinator: could not record the launch in $TEAM_HOME/sessions.jsonl:"
  assert_contains "$stderr" "; the session runs on"
}

@test "a failed launch logs no session, and one whose output names no id is logged without one" {
  echo 3 >"$BATS_TEST_TMPDIR/launch.status"
  run_bin -3 claude-coordinator
  [[ ! -e $TEAM_HOME/sessions.jsonl ]]
  stub_script claude <<'SH'
[[ $1 == agents ]] && { echo '[]'; exit 0; }
[[ $1 == mcp ]] && exit 0
echo "Started a background session"
SH
  run_bin -0 claude-coordinator
  assert_equal "$(jq -c 'has("id")' "$TEAM_HOME/sessions.jsonl")" false
}

@test "its header says where its model and effort come from and that it logs its launch" {
  run_bin -0 claude-coordinator --help
  local text
  text=$(tr -s ' \n' '  ' <<<"$output")
  assert_contains "$text" "the coordinator line of the team home's models.toml"
  assert_contains "$text" "sessions.jsonl"
}
