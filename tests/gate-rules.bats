#!/usr/bin/env bats
# bin/lib/gate-rules.md: the rules every agent of the gate reads, its CPU load cap, its kill by
# the agent's own pid and its names without a task's; and the SessionStart hook of
# bin/lib/gate-claude-settings.json that loads them on a Claude Code gate, run here as Claude Code
# runs a hook's command. tests/opencode-gate.bats holds the instructions that load them on an
# opencode gate.

load helpers/common

setup() {
  sandbox
  RULES=$HOME/agent-team/bin/lib/gate-rules.md
  mkdir -p "${RULES%/*}"
  cp "$REPO_ROOT/bin/lib/gate-rules.md" "$RULES"
}

@test "the rules hold the team's load cap with its timeout, the kill by the agent's own pid, and names without a task's" {
  local rules
  rules=$(<"$REPO_ROOT/bin/lib/gate-rules.md")
  assert_contains "$rules" 'Add at most 4 busy CPU cores of load of your own beyond the project'"'"'s own test command'
  assert_contains "$rules" 'never one per core or `nproc`, and give it a timeout no longer than the run it loads.'
  assert_contains "$rules" 'stop it by that pid alone once its run ends, never by `pkill`, `killall` or a kill of a `pgrep` or `ps` search'
  assert_contains "$rules" 'never after the branch, a task or ticket id (such as `TEAM_TASK`'"'"'s value)'
}

@test "a Claude Code gate's agents read the rules at each session start, its compactions and resumes included" {
  local settings=$REPO_ROOT/bin/lib/gate-claude-settings.json command
  # One entry with no matcher, which Claude Code runs on every source of a session's start.
  run -0 jq -c '[.hooks.SessionStart[] | {matcher, types: [.hooks[].type]}]' "$settings"
  assert_equal "$output" '[{"matcher":null,"types":["command"]}]'
  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$settings")
  # Claude Code runs a hook's command in a shell, which expands its $HOME, and adds what it
  # prints to the session's context.
  run -0 bash -c "$command" </dev/null
  assert_equal "$output" "$(<"$RULES")"
}
