#!/usr/bin/env bats
# bin/claude-assistant: one assistant at a time, only on the lease holder, hearing only #assistant
# through a Discord state of its own, with its settings, its memory and its role.
load helpers/common

setup() {
  sandbox
  # This machine, home-pc, holds the lease; make_machine laptop builds the other one.
  hold_lease home-pc >/dev/null
  lock=$HOME/.local/state/agent-team/assistant-launch.lock
  state=$HOME/.local/state/agent-team
  discord_state=$HOME/.claude/channels/discord-assistant
  export TEAM_ASSISTANT_CHANNEL=1570965039278596199
  # The coordinator's access file: Daniel's ids, and the groups the coordinator hears.
  echo '{"dmPolicy": "allowlist", "allowFrom": ["757", 758], "groups": {"1562486564871995482": {"requireMention": false, "allowFrom": []}}, "pending": {}}' \
    >"$HOME/.claude/channels/discord/access.json"
  # claude answers `agents --json --all` from $BATS_TEST_TMPDIR/sessions.json and `mcp list` from
  # $BATS_TEST_TMPDIR/mcp-list.txt; each call records whether the launch lock was free while it
  # ran, and the launch its cwd and whether it inherited the lock's file.
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  cat >"$BATS_TEST_TMPDIR/mcp-list.txt" <<'TXT'
Checking MCP server health…

claude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected
plugin:discord:discord: bun run start - ✔ Connected
plugin:mongodb-atlas:mongodb-atlas: https://mcp.mongodb.com/ (HTTP) - ! Needs authentication
codegraph: codegraph serve --mcp - ✔ Connected
vercel: https://mcp.vercel.com (HTTP) - ✔ Connected
TXT
  stub_script claude <<'EOF'
lock=$HOME/.local/state/agent-team/assistant-launch.lock
if flock -n "$lock" true; then held=free; else held=held; fi
if [[ $1 == agents ]]; then
  echo "agents $held" >>"$STUB_CALLS/claude.lock"
  cat "$BATS_TEST_TMPDIR/sessions.json"
  exit "$(cat "$BATS_TEST_TMPDIR/agents.status" 2>/dev/null || echo 0)"
fi
if [[ $1 == mcp ]]; then
  echo "mcp $held" >>"$STUB_CALLS/claude.lock"
  printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.mcp-cwd"
  cat "$BATS_TEST_TMPDIR/mcp-list.txt"
  exit 0
fi
echo "launch $held" >>"$STUB_CALLS/claude.lock"
printf '%s\n' "$PWD" >>"$STUB_CALLS/claude.cwd"
for fd in /dev/fd/*; do
  if [[ $(stat -L -c %d:%i "$fd" 2>/dev/null) == "$(stat -c %d:%i "$lock")" ]]; then
    echo "launch inherited the lock" >>"$STUB_CALLS/claude.lock"
  fi
done
echo "Started background session 4d5e6f70 (assistant). Attach with: claude attach 4d5e6f70"
exit "$(cat "$BATS_TEST_TMPDIR/launch.status" 2>/dev/null || echo 0)"
EOF
}

# session <id> <sessionId> <name> <state>: one listed session as claude agents --json --all lists it.
session() {
  jq -cn --arg id "$1" --arg sid "$2" --arg name "$3" --arg state "$4" \
    '{id: $id, cwd: "/somewhere", kind: "background", startedAt: 1761100000000, sessionId: $sid, name: $name, state: $state}'
}

# sessions <session json>...: the list `claude agents --json --all` prints.
sessions() {
  printf '%s\n' "$@" | jq -s . >"$BATS_TEST_TMPDIR/sessions.json"
}

# The launch command line, with the given first prompt or the default one: launch_argv [<prompt>]
launch_argv() {
  jq -cn --arg state "$state" --arg code "$REPO_ROOT" \
    --arg prompt "${1:-You are the assistant. Daniel talks to you in #assistant on Discord. Wait for their messages.}" \
    '["--bg", "--name", "assistant",
    "--autocompact", "200k",
    "--mcp-config", "\($state)/assistant.mcp.json",
    "--channels", "plugin:discord@claude-plugins-official",
    "--dangerously-skip-permissions",
    "--append-system-prompt-file", "\($code)/roles/assistant.md",
    "--settings", "\($state)/assistant.settings.json",
    $prompt]'
}

assert_not_launched() {
  if [[ -e $STUB_CALLS/claude.cwd ]] || grep -q -- '"--bg"' "$STUB_CALLS/claude.log" 2>/dev/null; then
    echo "claude --bg was called: $(stub_calls claude)" >&2
    return 1
  fi
}

# Nothing of the assistant's Discord state or settings was written.
assert_nothing_written() {
  assert_not_launched
  [[ ! -e $discord_state && ! -e $state/assistant.settings.json && ! -e $state/assistant.mcp.json ]] ||
    { echo "wrote: $(ls -A "$discord_state" "$state" 2>&1)" >&2; return 1; }
}

@test "--help prints the header" {
  run_bin -0 claude-assistant --help
  assert_contains "$output" "Start the assistant: the long-lived session Daniel talks to in #assistant on Discord"
  assert_contains "$output" "Usage: claude-assistant [--prompt <text>]"
  assert_equal "$(stub_calls claude)" ""
}

@test "with no assistant live it launches in the team home, with the exact command line" {
  sessions "$(session 0a1b2c3d 0a1b2c3d-1111 coordinator working)" "$(session 1b2c3d4e 1b2c3d4e-2222 T14-builder working)"
  cd "$BATS_TEST_TMPDIR"
  run_bin -0 claude-assistant
  assert_contains "$output" "Started background session 4d5e6f70 (assistant)"
  assert_equal "$(stub_calls claude)" "$(printf '%s\n%s\n%s' '["agents","--json","--all"]' '["mcp","list"]' "$(launch_argv)")"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$TEAM_HOME"
  assert_equal "$(cat "$STUB_CALLS/claude.mcp-cwd")" "$TEAM_HOME"
}

@test "--prompt replaces the first prompt, as team-resume starts it" {
  run_bin -0 claude-assistant --prompt "You are the assistant, resuming on home-pc."
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv "You are the assistant, resuming on home-pc.")"
}

@test "a malformed command line is a usage error, launching nothing" {
  local args
  for args in "--prompt" "--prompt ''" "$TEAM_HOME" "--other" "--prompt x extra"; do
    eval "run_bin -2 --separate-stderr claude-assistant $args"
    assert_equal "$stderr" "claude-assistant: usage: claude-assistant [--prompt <text>] | claude-assistant --load-check <worktree> [--prompt <text>]"
  done
  assert_equal "$(stub_calls claude)" ""
}

@test "it holds the launch lock across the check and the launch, and the session does not inherit it" {
  run_bin -0 claude-assistant
  assert_equal "$(cat "$STUB_CALLS/claude.lock")" "$(printf 'agents held\nmcp held\nlaunch held')"
  [[ -f $lock ]]
}

@test "a second launch while the lock is held exits 1 at once, without asking claude anything" {
  mkdir -p "${lock%/*}"
  exec {held}>"$lock"
  flock -n "$held"
  guard_sandbox
  run -1 --separate-stderr timeout 10 "$REPO_ROOT/bin/claude-assistant"
  exec {held}>&-
  assert_equal "$stderr" "claude-assistant: another claude-assistant is launching right now (it holds $lock)"
  assert_equal "$(stub_calls claude)" ""
  assert_nothing_written
}

@test "a live assistant in any state but stopped refuses the launch, naming its session id" {
  local live
  for live in working blocked idle "done" failed; do
    sessions "$(session 0a1b2c3d 0a1b2c3d-1111 coordinator working)" "$(session 5e6f7a8b 5e6f7a8b-3333 assistant "$live")"
    run_bin -1 --separate-stderr claude-assistant
    assert_equal "$stderr" "claude-assistant: an assistant is already live: session 5e6f7a8b; stop it with claude stop 5e6f7a8b first"
    assert_nothing_written
  done
  assert_equal "$(stub_calls claude | sort -u)" '["agents","--json","--all"]'
}

@test "a stopped assistant, and a session named otherwise, do not refuse the launch" {
  sessions "$(session 1a2b3c4d 1a2b3c4d-5555 assistant stopped)" "$(session 22222222 22222222-b T0-assistant working)" \
    "$(session 33333333 33333333-c Assistant working)" "$(session 44444444 44444444-d coordinator working)"
  run_bin -0 claude-assistant
  assert_equal "$(stub_calls claude | tail -n 1)" "$(launch_argv)"
}

@test "an unreadable session list refuses the launch" {
  echo 'not json' >"$BATS_TEST_TMPDIR/sessions.json"
  run_bin -1 --separate-stderr claude-assistant
  assert_equal "$stderr" "claude-assistant: cannot read the session list (claude agents --json --all)"
  assert_nothing_written
}

@test "with the lease held by the other machine it refuses, naming the holder and the next step" {
  make_machine laptop
  run_bin -0 team-lease release
  on_machine laptop run_bin -0 team-lease take
  run_bin -1 --separate-stderr claude-assistant
  assert_contains "$stderr" "claude-assistant: laptop holds the lease: run team-resume --wait here, then hand off there once it says this machine is ready"
  assert_nothing_written
}

@test "with the lease released it refuses: an assistant starts only on the lease holder" {
  run_bin -0 team-lease release
  run_bin -1 --separate-stderr claude-assistant
  assert_contains "$stderr" "claude-assistant: an assistant starts only on the machine that holds the lease"
  assert_nothing_written
}

@test "with GitHub unreachable it refuses: an assistant never starts offline" {
  git -C "${TEAM_HOME:?}" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -1 --separate-stderr claude-assistant
  assert_contains "$stderr" "claude-assistant: GitHub unreachable; an assistant never starts offline"
  assert_nothing_written
}

@test "with no assistant channel set it refuses, naming the variable" {
  TEAM_ASSISTANT_CHANNEL='' run_bin -1 --separate-stderr claude-assistant
  assert_equal "$stderr" "claude-assistant: no assistant channel is set (TEAM_ASSISTANT_CHANNEL is empty), so the assistant would hear nothing: unset it to use ASSISTANT_CHANNEL in bin/lib/team.sh"
  assert_nothing_written
}

@test "the channel is the library's #assistant unless overridden" {
  unset TEAM_ASSISTANT_CHANNEL
  run_bin -0 claude-assistant
  assert_equal "$(jq -c '.groups | keys' "$discord_state/access.json")" '["1570965039278596199"]'
  TEAM_ASSISTANT_CHANNEL=42 run_bin -0 claude-assistant
  assert_equal "$(jq -c '.groups | keys' "$discord_state/access.json")" '["42"]'
}

@test "with no bot token in the coordinator's Discord state it refuses, naming team-secrets check" {
  rm "$HOME/.claude/channels/discord/.env"
  run_bin -1 --separate-stderr claude-assistant
  assert_equal "$stderr" "claude-assistant: no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, which the assistant's Discord state links to: run team-secrets check"
  assert_nothing_written
  echo "OTHER=1" >"$HOME/.claude/channels/discord/.env"
  run_bin -1 --separate-stderr claude-assistant
  assert_contains "$stderr" "no DISCORD_BOT_TOKEN"
  assert_nothing_written
}

@test "with no Daniel's id readable from the coordinator's access file it refuses" {
  local access=$HOME/.claude/channels/discord/access.json body
  for body in '{"allowFrom": []}' '{"groups": {}}' '{"allowFrom": "757"}' '{"allowFrom": ["daniel"]}' 'not json'; do
    printf '%s\n' "$body" >"$access"
    run_bin -1 --separate-stderr claude-assistant
    assert_equal "$stderr" "claude-assistant: cannot read Daniel's Discord ids from the allowFrom of ~/.claude/channels/discord/access.json, so the assistant would hear nobody"
    assert_nothing_written
  done
  rm "$access"
  run_bin -1 --separate-stderr claude-assistant
  assert_contains "$stderr" "cannot read Daniel's Discord ids"
  assert_nothing_written
}

@test "with a coordinator group for #assistant it refuses, naming the fix" {
  jq '.groups["1570965039278596199"] = {requireMention: false, allowFrom: []}' "$HOME/.claude/channels/discord/access.json" \
    >"$BATS_TEST_TMPDIR/access.json"
  mv "$BATS_TEST_TMPDIR/access.json" "$HOME/.claude/channels/discord/access.json"
  run_bin -1 --separate-stderr claude-assistant
  assert_equal "$stderr" "claude-assistant: the coordinator would hear #assistant too: remove that group with /discord:access group rm 1570965039278596199 in the coordinator"
  assert_nothing_written
}

@test "it writes its own Discord state: mode 700, the token by a link, and the exact access file" {
  run_bin -0 claude-assistant
  assert_equal "$(stat -c %a "$discord_state")" 700
  [[ -L $discord_state/.env ]]
  assert_equal "$(readlink "$discord_state/.env")" ../discord/.env
  assert_equal "$(cat "$discord_state/.env")" "DISCORD_BOT_TOKEN=$FAKE_DISCORD_TOKEN"
  assert_equal "$(stat -c %a "$discord_state/access.json")" 600
  assert_equal "$(jq -c . "$discord_state/access.json")" \
    '{"dmPolicy":"allowlist","allowFrom":[],"groups":{"1570965039278596199":{"requireMention":false,"allowFrom":["757","758"]}},"pending":{},"ackReaction":"👀","replyToMode":"first","textChunkLimit":2000,"chunkMode":"newline"}'
  assert_equal "$(find "$discord_state" -name '*.json.*')" ""
}

@test "each launch writes the access file whole, whatever an edit left there" {
  run_bin -0 claude-assistant
  local expected
  expected=$(jq -c . "$discord_state/access.json")
  echo '{"dmPolicy": "pairing", "allowFrom": ["1"], "groups": {"9": {}}}' >"$discord_state/access.json"
  ln -sfn /elsewhere "$discord_state/.env"
  chmod 755 "$discord_state"
  run_bin -0 claude-assistant
  assert_equal "$(jq -c . "$discord_state/access.json")" "$expected"
  assert_equal "$(readlink "$discord_state/.env")" ../discord/.env
  assert_equal "$(stat -c %a "$discord_state")" 700
  # The inbox of Daniel's attachments, which the plugin writes, stays.
  mkdir -p "$discord_state/inbox"
  echo x >"$discord_state/inbox/a.png"
  run_bin -0 claude-assistant
  [[ -f $discord_state/inbox/a.png ]]
}

@test "its settings are the template with the checkout, the team home and its Discord state filled in" {
  run_bin -0 claude-assistant
  local settings=$state/assistant.settings.json
  assert_equal "$(jq -c 'del(.deniedMcpServers)' "$settings")" \
    "$(jq -c --arg code "$REPO_ROOT" --arg home "$TEAM_HOME" --arg discord "$discord_state" \
      'walk(if type == "string" then gsub("@TEAM_CODE@"; $code) | gsub("@TEAM_HOME@"; $home) | gsub("@DISCORD_STATE_DIR@"; $discord) else . end)' \
      "$REPO_ROOT/assistant.settings.json")"
  [[ $(cat "$settings") != *@TEAM_CODE@* && $(cat "$settings") != *@TEAM_HOME@* && $(cat "$settings") != *@DISCORD_STATE_DIR@* ]]
  # Its Remote Control is the user settings', which its own settings leave alone.
  assert_equal "$(jq -c 'has("remoteControlAtStartup")' "$settings")" false
  assert_equal "$(jq -c '[.env.AGENT_TEAM_ROLE, .env.DISCORD_STATE_DIR, .env.DISCORD_ACCESS_MODE, .autoMemoryDirectory]' "$settings")" \
    "$(jq -cn --arg d "$discord_state" --arg m "$TEAM_HOME/memory/assistant" '["assistant", $d, "static", $m]')"
  assert_equal "$(find "$state" -name '*.json.*')" ""
}

@test "its MCP config names no server, and its settings deny every listed server but the Discord plugin's" {
  run_bin -0 claude-assistant
  assert_equal "$(jq -c . "$state/assistant.mcp.json")" '{"mcpServers":{}}'
  assert_equal "$(jq -r '.deniedMcpServers[].serverName' "$state/assistant.settings.json" | sort)" \
    "$(printf '%s\n' 'claude.ai Claude Docs' codegraph plugin:mongodb-atlas:mongodb-atlas vercel)"
}

@test "its settings keep the coordinator's keys and compaction, and it takes no model or effort of its own" {
  run_bin -0 claude-assistant
  local settings=$state/assistant.settings.json coordinator=$REPO_ROOT/coordinator.settings.json key
  # But for what the coordinator alone trims from its starting context: its skill listing
  # (skillOverrides, the synced and the bundled skills) and the task reminder's switch.
  for key in enabledPlugins syncClaudeAiPlugins crossSessionInbound isolatePeerMachines promptCacheTtl idleCompaction; do
    assert_equal "$(jq -c --arg k "$key" '.[$k]' "$settings")" "$(jq -c --arg k "$key" '.[$k]' "$coordinator")"
  done
  # Its own skillOverrides keep the synced docs skill off, which steers a session to the Claude
  # Docs connector the launch denies.
  assert_equal "$(jq -r '.skillOverrides["anthropic-skills:docs"]' "$settings")" off
  assert_equal "$(jq -c '.env | del(.AGENT_TEAM_ROLE, .DISCORD_STATE_DIR, .DISCORD_ACCESS_MODE)' "$REPO_ROOT/assistant.settings.json")" \
    "$(jq -c '.env | del(.AGENT_TEAM_ROLE, .CLAUDE_CODE_TODO_REMINDER_MODE)' "$coordinator")"
  assert_equal "$(jq -c '[has("model"), has("effortLevel"), has("autoCompactWindow"), (.env | has("CLAUDE_CODE_AUTO_COMPACT_WINDOW"))]' "$settings")" \
    '[false,false,false,false]'
  local argv
  argv=$(stub_calls claude | tail -n 1)
  assert_equal "$(jq -c 'map(select(. == "--model" or . == "--effort" or . == "--plugin-dir" or . == "--strict-mcp-config"))' <<<"$argv")" '[]'
}

@test "its settings deny every rule of the coordinator's and the Discord token and access files, and its command-guard the coordinator's acts, GitHub's writes and the thread cache's writes" {
  local settings=$REPO_ROOT/assistant.settings.json command
  # But for the tools the coordinator denies only to keep their definitions out of its context,
  # and its rules on its GitHub login, a force push and a cd into ~/.config/agent-team, which the
  # assistant's command-guard hook holds instead, command by command.
  assert_equal "$(jq -r --slurpfile a "$settings" '.permissions.deny - $a[0].permissions.deny | .[]' "$REPO_ROOT/coordinator.settings.json" | paste -sd ' ')" \
    "Artifact ArtifactComments ArtifactData ReportFindings ScheduleWakeup TaskCreate TaskGet TaskList TaskUpdate Workflow Bash(*GH_CONFIG_DIR*) Bash(*GH_TOKEN*) Bash(*GITHUB_TOKEN*) Bash(*env -i*) Bash(*env --i*) Bash(*env - *) Bash(*exec -c*) Bash(git push --force*) Bash(git push -f*) Bash(git push * --force*) Bash(git push * -f*) Bash(git push * +*) Bash(git -C * push --force*) Bash(git -C * push -f*) Bash(git -C * push * --force*) Bash(git -C * push * -f*) Bash(git -C * push * +*) Bash(cd *.config/agent-team*) Bash(pushd *.config/agent-team*)"
  # shellcheck disable=SC2088 # ~ is part of the command as an agent types it
  for command in "cat ~/.claude/channels/discord/.env" "cat $HOME/.claude/channels/discord/access.json" \
    "ls ~/.claude/channels/discord/" "cat ~/.claude/channels/discord-assistant/.env" \
    "jq . ~/.claude/channels/discord-assistant/access.json" "cd ~/.claude/channels && cat discord/.env" \
    "git push" "git push origin main" "git push -u origin x" "git -C ~/agent-team-records push" \
    "git -C ~/agent-team-records push origin main" "git commit -m x" "git -C ~/agent-team-records commit -m x" \
    "gh pr create --fill" "gh pr merge 5" "gh pr comment 5 --body x" "gh pr review 5 --approve" "gh pr ready 5" \
    "gh-axi pr edit 5 --title x" "gh issue create --title x" "gh-axi issue comment 3 --body x" \
    "gh repo delete x/y" "gh repo edit --visibility public" "team-lease take --steal" "team-land T1" \
    "$REPO_ROOT/bin/team-land https://github.com/o/r/pull/5" "claude stop 0a1b2c3d" "claude rm 0a1b2c3d" "claude attach coordinator" "claude --bg --name x go" \
    "claude -p hi" "claude --model opus --print hi" "$HOME/.local/bin/claude stop x" \
    "sudo pacman -S jq" "op read op://x/y" "cat /proc/1/environ"; do
    denied_in "$settings" "$command" || { echo "allows: $command" >&2; return 1; }
  done
  # A cd into the bot's directories: its command-guard hook refuses it, command by command.
  # shellcheck disable=SC2088
  for command in "cd ~/.claude/channels/discord && cat .env" "cd ~/.claude/channels/discord-assistant && cat .env" \
    "pushd ~/.claude/channels/discord" "cd ~/.config/agent-team && cat review-app.pem"; do
    AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr hooks/command-guard <<<"$(jq -cn --arg c "$command" \
      '{tool_name: "Bash", cwd: env.HOME, tool_input: {command: $c}}')"
    assert_contains "$stderr" "Blocked by command-guard: a cd into ~/.config/agent-team or the Discord bot's directories"
  done
  # A run of the coordinator's acts: its command-guard hook's assistant-acts row refuses it, command
  # by command, where its deny rules refused any call naming the script.
  # shellcheck disable=SC2088
  for command in "team-handoff laptop" "team-resume" "$REPO_ROOT/bin/team-resume --wait" "team-lease take" \
    "team-lease release" "team-timers run" "team-timers disable" "team-stow T1" "team-checkpoint" \
    "team-config apply" "team-config capture" "team-secrets restore" "team-secrets save discord-bot-env" \
    "team-records-rewrite --plan" "team-ops-end T1" "team-stack up --worktree ~/wt" "team-stack down" \
    "team-stack stop" "team-stack seed" "team-capacity install" "team-capacity place" "claude-coordinator" \
    "$REPO_ROOT/bin/claude-coordinator --prompt x" "~/agent-team/bin/team-handoff laptop" \
    "$REPO_ROOT/bin/team-lease take" "~/agent-team/bin/team-stack down" \
    "team-review-comment https://github.com/o/r/pull/5 ~/agent-team-records/tasks/T1/x.md" \
    "$REPO_ROOT/bin/team-review-comment https://github.com/o/r/pull/5 x.md" "team-load-check --probe --role assistant" \
    "~/agent-team/bin/team-load-check" "team-heavy run -- git push" "$REPO_ROOT/bin/team-heavy run --label x -- sh -c x"; do
    AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr hooks/command-guard <<<"$(jq -cn --arg c "$command" \
      '{tool_name: "Bash", cwd: env.HOME, tool_input: {command: $c}}')"
    assert_contains "$stderr" "Blocked by command-guard: the coordinator's acts, which an assistant session never runs ("
  done
  # A GitHub write by gh api, release, secret or variable: its assistant-github-write row refuses
  # it, command by command, where its deny rules refused any gh api call with a field and any call
  # of the three groups.
  for command in "gh api -X POST repos/o/r/issues" "gh api repos/o/r/issues --method POST" \
    "gh api repos/o/r/issues -f title=x" "gh api repos/o/r/issues -F title=x" "gh api --input body.json x" \
    "gh api graphql -f query='mutation{x}'" "gh release create v1" "gh secret set X" "gh variable delete X" \
    "gh-axi release upload v1 a.tgz" "gh-axi secret set X" "gh-axi variable set X"; do
    AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr hooks/command-guard <<<"$(jq -cn --arg c "$command" \
      '{tool_name: "Bash", cwd: env.HOME, tool_input: {command: $c}}')"
    assert_contains "$stderr" "Blocked by command-guard: a GitHub write, which an assistant session never makes ("
  done
  # A write of the thread cache the Discord guard trusts: its assistant-thread-cache row refuses it,
  # command by command, where its deny rule refused any call naming the cache.
  # shellcheck disable=SC2088
  for command in "echo 1571000000000000101 >>~/.local/state/agent-team/assistant-threads" \
    "cd ~/.local/state/agent-team && tee -a assistant-threads" "sed -i 1d $HOME/.local/state/agent-team/assistant-threads" \
    "cp /tmp/x ~/.local/state/agent-team/assistant-threads" "rm ~/.local/state/agent-team/assistant-threads" \
    "ls 2>~/.local/state/agent-team/assistant-threads"; do
    AGENT_TEAM_ROLE=assistant run_bin -2 --separate-stderr hooks/command-guard <<<"$(jq -cn --arg c "$command" \
      '{tool_name: "Bash", cwd: env.HOME, tool_input: {command: $c}}')"
    assert_contains "$stderr" "Blocked by command-guard: the thread cache the Discord guard trusts, which only the scripts and hooks write ("
  done
}

@test "its settings leave it the reads, its inbox and the team's read-only forms" {
  local settings=$REPO_ROOT/assistant.settings.json command
  # shellcheck disable=SC2088 # ~ is part of the command as an agent types it
  for command in "git status" "git log --oneline -5" "git -C ~/agent-team-records log -3" "git diff" \
    "gh pr view 5" "gh pr list" "gh-axi pr view 5" "gh pr checks 5" "gh api repos/o/r/pulls/5" \
    "gh issue view 3" "gh run view 1 --log" "ls ~/.claude/channels/discord-assistant/inbox" \
    "cat ~/.claude/channels/discord-assistant/inbox/a.png" \
    "team-state" "team-lease status" "team-lease check" "team-timers health" "team-timers status --json" \
    "team-config diff" "team-secrets check" "team-stack ls" "team-capacity status" "team-doctor" \
    "claude agents" "claude --version" "grep -rn claude-coordinator bin" "team-proc 4242" "team-proc 4242 io cgroup" \
    "sed -n 1,40p bin/team-load-check | head -20" "grep -rn toolkit bin/claude-coordinator bin/claude-assistant" \
    "wc -l bin/team-checkpoint bin/team-review-comment" "team-load-check --help" "team-timers watch --once" \
    "bin/team-stow --help" "bin/team-handoff --help" "bin/team-resume --help" "bin/team-checkpoint --help" \
    "bin/team-review-comment --help" "bin/team-records-rewrite --help" "bin/team-ops-end --help" \
    "bin/claude-coordinator --help" "gh api -X GET search/issues -f q=repo:o/r" \
    "gh api --method GET repos/o/r/pulls -F per_page=100" "gh api graphql -f query='{viewer{login}}'" \
    "gh release list" "gh release view v1" "gh secret list" "gh variable list" "gh variable get X" \
    "gh-axi release list" "gh-axi secret list" "gh-axi variable list" "grep -rn assistant-threads bin" \
    "cat ~/.local/state/agent-team/assistant-threads" "wc -l ~/.local/state/agent-team/assistant-threads" \
    "jq -R . ~/.local/state/agent-team/assistant-threads" "sed -n 1p ~/.local/state/agent-team/assistant-threads"; do
    if denied_in "$settings" "$command"; then echo "denies: $command" >&2; return 1; fi
  done
}

@test "its settings deny the Read and Edit tools the Discord token and access files, the Edit tool the thread cache, and leave the inbox" {
  local settings=$REPO_ROOT/assistant.settings.json rule tool
  for tool in Read Edit; do
    for rule in "$tool(~/.claude/channels/discord/**)" "$tool(~/.claude/channels/discord-assistant/.env)" \
      "$tool(~/.claude/channels/discord-assistant/access.json)"; do
      jq -e --arg r "$rule" '.permissions.deny | index($r) != null' "$settings" >/dev/null ||
        { echo "no deny rule $rule" >&2; return 1; }
    done
  done
  # The thread cache the Discord guard trusts, which only the scripts and hooks write.
  jq -e '.permissions.deny | index("Edit(~/.local/state/agent-team/assistant-threads)") != null' "$settings" >/dev/null
  assert_equal "$(jq -c '[.permissions.deny[] | select(test("discord-assistant/(inbox|\\*)"))]' "$settings")" '[]'
}

@test "its settings keep every tool its role names, and a background session cannot ask or plan" {
  local settings=$REPO_ROOT/assistant.settings.json tool
  keeps_named "$settings" "$REPO_ROOT/roles/assistant.md"
  for tool in SendMessage ListAgents WebFetch WebSearch Agent Monitor; do
    if jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null; then
      echo "denies $tool, which the assistant uses" >&2 && return 1
    fi
  done
  for tool in AskUserQuestion EnterPlanMode ExitPlanMode SendFeedback; do
    jq -e --arg t "$tool" '.permissions.deny | index($t) != null' "$settings" >/dev/null ||
      { echo "no deny rule for $tool" >&2; return 1; }
  done
}

@test "a failed launch exits with claude's status" {
  echo 3 >"$BATS_TEST_TMPDIR/launch.status"
  run_bin -3 claude-assistant
}

# The worker login (bin/lib/github-login.sh), as tests/claude-coordinator.bats has it: the same
# settings writer, bin/lib/launch.sh's launch_settings, gives both sessions the login.

# The refusal when the login is named but its file is not usable, by what is wrong with the file:
# login_refusal <login> <what of hosts.yml>
login_refusal() {
  # shellcheck disable=SC2088 # ~ is part of the message as the script prints it
  echo "claude-assistant: the worker login $1 is not on this machine (~/.config/agent-team/gh-worker/hosts.yml $2): Daniel's team-secrets restore brings it (the secret worker-github-login)"
}

@test "with the worker login on, its settings hold the login's environment, and nothing else changes" {
  local settings=$state/assistant.settings.json off
  code_checkout
  worker_login_off
  run_bin -0 claude-assistant
  off=$(jq -c . "$settings")
  worker_login_on
  run_bin -0 claude-assistant
  assert_equal "$(jq -c '[.env.GH_CONFIG_DIR, .env.GH_TOKEN, .env.GITHUB_TOKEN]' "$settings")" \
    "$(jq -cn --arg dir "$HOME/.config/agent-team/gh-worker" '[$dir, "", ""]')"
  assert_equal "$(jq -c 'del(.env.GH_CONFIG_DIR, .env.GH_TOKEN, .env.GITHUB_TOKEN)' "$settings")" "$off"
}

@test "with the worker login off, its settings are today's: the template, with no login of its own" {
  local settings=$state/assistant.settings.json
  code_checkout
  worker_login_on
  worker_login_off
  run_bin -0 claude-assistant
  assert_equal "$(jq -c 'del(.deniedMcpServers)' "$settings")" \
    "$(jq -c --arg code "$CODE_CHECKOUT" --arg home "$TEAM_HOME" --arg discord "$discord_state" \
      'walk(if type == "string" then gsub("@TEAM_CODE@"; $code) | gsub("@TEAM_HOME@"; $home) | gsub("@DISCORD_STATE_DIR@"; $discord) else . end)' \
      "$CODE_CHECKOUT/assistant.settings.json")"
  assert_equal "$(jq -c '.env | keys | map(select(test("^(GH_|GITHUB_)")))' "$settings")" '[]'
}

@test "with the worker login named but not on this machine, it refuses before writing or starting anything" {
  local dir=$HOME/.config/agent-team/gh-worker
  code_checkout
  worker_login_on team-bot
  rm "$dir/hosts.yml"
  run_bin -1 --separate-stderr claude-assistant
  assert_equal "$stderr" "$(login_refusal team-bot 'is missing')"
  assert_nothing_written
  echo 'github.com:' >"$dir/hosts.yml"
  chmod 640 "$dir/hosts.yml"
  run_bin -1 --separate-stderr claude-assistant
  assert_equal "$stderr" "$(login_refusal team-bot 'is mode 640, not 600')"
  assert_nothing_written
  # It asked only for the session list, the check it makes first.
  assert_equal "$(stub_calls claude | sort -u)" '["agents","--json","--all"]'
}

@test "a malformed worker login constant refuses the launch with the reader's message" {
  code_checkout
  worker_login_on
  echo 'team-bot' >"$CODE_CHECKOUT/bin/lib/worker-login"
  run_bin -1 --separate-stderr claude-assistant
  assert_equal "$stderr" "claude-assistant: $CODE_CHECKOUT/bin/lib/worker-login is not one login=<a GitHub login> line"
  assert_nothing_written
}

@test "the login check comes after the lock, the one-session check and the Discord checks" {
  code_checkout
  worker_login_on team-bot
  rm "$HOME/.config/agent-team/gh-worker/hosts.yml"
  sessions "$(session 5e6f7a8b 5e6f7a8b-3333 assistant working)"
  run_bin -1 --separate-stderr claude-assistant
  assert_equal "$stderr" "claude-assistant: an assistant is already live: session 5e6f7a8b; stop it with claude stop 5e6f7a8b first"
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  rm "$HOME/.claude/channels/discord/.env"
  run_bin -1 --separate-stderr claude-assistant
  assert_contains "$stderr" "claude-assistant: no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env"
  assert_nothing_written
}

@test "its header says the session runs on the worker login when one is named" {
  run_bin -0 claude-assistant --help
  assert_contains "$(tr -s ' \n' '  ' <<<"$output")" "Its session runs on the worker login when bin/lib/worker-login names one"
}

# The load check's form: claude-assistant --load-check <worktree> [--prompt <text>].

# The load check's launch command line, with the given first prompt or the default one:
# load_check_argv [<prompt>]
load_check_argv() {
  jq -cn --arg state "$state" --arg code "$REPO_ROOT" \
    --arg prompt "${1:-You are the assistant. Daniel talks to you in #assistant on Discord. Wait for their messages.}" \
    '["--bg", "--name", "T0-assistant",
    "--autocompact", "200k",
    "--mcp-config", "\($state)/assistant-load-check.mcp.json",
    "--dangerously-skip-permissions",
    "--append-system-prompt-file", "\($code)/roles/assistant.md",
    "--settings", "\($state)/assistant-load-check.settings.json",
    $prompt]'
}

@test "--load-check launches T0-assistant in the worktree with no Discord, printing its id alone" {
  local wt=$BATS_TEST_TMPDIR/load-check
  mkdir -p "$wt"
  cd "$BATS_TEST_TMPDIR"
  run_bin -0 claude-assistant --load-check "$wt" --prompt "Reply with OK and nothing else."
  assert_equal "$output" 4d5e6f70
  assert_equal "$(stub_calls claude)" "$(printf '%s\n%s' '["mcp","list"]' "$(load_check_argv "Reply with OK and nothing else.")")"
  assert_equal "$(cat "$STUB_CALLS/claude.cwd")" "$wt"
  assert_equal "$(cat "$STUB_CALLS/claude.mcp-cwd")" "$wt"
  # It takes no launch lock, so nothing of its holds the assistant's.
  assert_equal "$(cat "$STUB_CALLS/claude.lock")" "$(printf 'mcp free\nlaunch free')"
  # The assistant's settings, with the Discord plugin off and its server denied too.
  local settings=$state/assistant-load-check.settings.json
  assert_equal "$(jq -c 'del(.deniedMcpServers)' "$settings")" \
    "$(jq -c --arg code "$REPO_ROOT" --arg home "$TEAM_HOME" --arg discord "$discord_state" \
      'walk(if type == "string" then gsub("@TEAM_CODE@"; $code) | gsub("@TEAM_HOME@"; $home) | gsub("@DISCORD_STATE_DIR@"; $discord) else . end)
       | .enabledPlugins["discord@claude-plugins-official"] = false
       | del(.hooks.Stop, .hooks.SessionStart)
       | .remoteControlAtStartup = false' "$REPO_ROOT/assistant.settings.json")"
  # Remote Control off, outranking the user settings' true, so the run leaves no row in Daniel's
  # Remote Control list on claude.ai.
  assert_equal "$(jq -c '.remoteControlAtStartup' "$settings")" false
  # Neither the Stop hook nor the start digest, which read the live assistant's list and hand-offs
  # and would have this session act on them; the guards on its tool calls stay.
  assert_equal "$(jq -c '.hooks | keys' "$settings")" '["PreToolUse"]'
  jq -e '[.. | strings | select(test("assistant-stop|assistant-digest"))] == []' "$settings" >/dev/null
  assert_equal "$(jq -r '.deniedMcpServers[].serverName' "$settings" | sort)" \
    "$(printf '%s\n' 'claude.ai Claude Docs' codegraph plugin:discord:discord plugin:mongodb-atlas:mongodb-atlas vercel)"
  assert_equal "$(jq -c . "$state/assistant-load-check.mcp.json")" '{"mcpServers":{}}'
  # Nothing of the live assistant's: its settings, its MCP config and its Discord state.
  [[ ! -e $discord_state && ! -e $state/assistant.settings.json && ! -e $state/assistant.mcp.json ]]
  assert_equal "$(find "$state" -name '*.json.*' -o -name '*.template*')" ""
}

@test "--load-check takes the default prompt, and launches beside a live assistant, off the lease and with no Discord state" {
  local wt=$BATS_TEST_TMPDIR/load-check
  mkdir -p "$wt"
  sessions "$(session 9f8e7d6c 9f8e7d6c-1111 assistant working)"
  run_bin -0 team-lease release
  rm "$HOME/.claude/channels/discord/access.json"
  TEAM_ASSISTANT_CHANNEL='' run_bin -0 claude-assistant --load-check "$wt"
  assert_equal "$output" 4d5e6f70
  assert_equal "$(stub_calls claude | tail -n 1)" "$(load_check_argv)"
  # The live assistant's settings stay as they were.
  [[ ! -e $state/assistant.settings.json ]]
}

@test "--load-check refuses a worktree that is no directory, and a malformed command line" {
  run_bin -1 --separate-stderr claude-assistant --load-check "$BATS_TEST_TMPDIR/none"
  assert_equal "$stderr" "claude-assistant: no worktree at $BATS_TEST_TMPDIR/none for the load check's assistant"
  local args
  for args in "--load-check" "--load-check ''" "--load-check $BATS_TEST_TMPDIR --prompt" \
    "--load-check $BATS_TEST_TMPDIR --load-check $BATS_TEST_TMPDIR" "--load-check $BATS_TEST_TMPDIR extra"; do
    eval "run_bin -2 --separate-stderr claude-assistant $args"
    assert_equal "$stderr" "claude-assistant: usage: claude-assistant [--prompt <text>] | claude-assistant --load-check <worktree> [--prompt <text>]"
  done
  assert_not_launched
}

@test "--load-check exits with a failed launch's status, and fails when claude names no session id" {
  local wt=$BATS_TEST_TMPDIR/load-check
  mkdir -p "$wt"
  echo 3 >"$BATS_TEST_TMPDIR/launch.status"
  run_bin -3 claude-assistant --load-check "$wt"
  rm "$BATS_TEST_TMPDIR/launch.status"
  stub_script claude <<'SH'
[[ $1 == mcp ]] && exit 0
echo "Started a background session"
SH
  run_bin -1 --separate-stderr claude-assistant --load-check "$wt" --prompt x
  assert_equal "$stderr" "claude-assistant: could not read the session id from: Started a background session"
}
