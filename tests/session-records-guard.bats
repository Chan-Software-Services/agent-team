#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2088 # output and stderr are set by bats' run; a ~ is part of a path as an agent types it
# hooks/session-records-guard: the worker roles' PreToolUse hook on Read, Grep and Glob, which
# lets a session reach, under ~/.claude/projects, only its own transcript and session directory.
# Each test runs the real hook with a PreToolUse JSON on stdin, as Claude Code does.

load helpers/common

OWN=1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d
OTHER=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee

setup() {
  sandbox
  unset CLAUDE_CONFIG_DIR
  wt=$HOME/wt
  root=$HOME/.claude/projects
  project=$root/-home-wt
  elsewhere=$root/-home-other
  mkdir -p "$wt/src" "$project/$OWN/tool-results" "$project/$OWN/subagents" "$project/memory" \
    "$project/$OTHER/tool-results" "$project/$OTHER/subagents" "$elsewhere/$OTHER/tool-results" \
    "$elsewhere/$OTHER/subagents" "$HOME/.claude/skills"
  touch "$project/$OWN.jsonl" "$project/$OTHER.jsonl" "$elsewhere/$OTHER.jsonl"
}

# call <status> <tool> <tool_input as JSON> [cwd]: run the hook on a call of the session
# $session (the own one unless a test sets it; "-" leaves session_id out of the input).
call() {
  local status=$1 id=${session-$OWN}
  run_bin "$status" --separate-stderr hooks/session-records-guard \
    <<<"$(jq -cn --arg tool "$2" --argjson input "$3" --arg cwd "${4:-$wt}" --arg id "$id" \
      '{hook_event_name: "PreToolUse", cwd: $cwd, tool_name: $tool, tool_input: $input}
       + (if $id == "-" then {} else {session_id: $id} end)')"
}

# read_file, grep_in, glob_in <status> <path> [cwd]: a Read of the file, or a Grep or Glob rooted
# at the path.
read_file() {
  call "$1" Read "$(jq -cn --arg p "$2" '{file_path: $p}')" "${3:-}"
}
grep_in() {
  call "$1" Grep "$(jq -cn --arg p "$2" '{pattern: "x", path: $p}')" "${3:-}"
}
glob_in() {
  call "$1" Glob "$(jq -cn --arg p "$2" '{pattern: "**/*.md", path: $p}')" "${3:-}"
}

# allowed: the last call passed, saying nothing.
allowed() {
  assert_equal "$output$stderr" ""
}

# others <tool> <path>: the last call was refused as a reach into another session's records.
others() {
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by session-records-guard: $1 of $2: under ~/.claude/projects a session reads only its own records, its transcript and what lies under its own session directory, and this is another session's."
}

# wide <tool> <path>: the last call was refused as a search of every session's records.
wide() {
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by session-records-guard: $1 rooted at $2 would search every session's records under ~/.claude/projects; give it a narrower path."
}

# unreadable: the last call was refused as input the hook cannot read.
unreadable() {
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by session-records-guard: its input is not a hook call it can read, and a guard that cannot decide refuses."
}

@test "a Read of the session's own transcript, saved tool result and subagent transcript passes" {
  local path
  for path in "$project/$OWN.jsonl" "$project/$OWN/tool-results/toolu_1.txt" \
    "$project/$OWN/subagents/agent-1.jsonl" "$project/$OWN/subagents/agent-1/tool-results/x.txt"; do
    read_file -0 "$path"
    allowed
  done
}

@test "a Read of another session's transcript, tool result or subagent transcript is refused, in the same project directory and in another" {
  local dir path
  for dir in "$project" "$elsewhere"; do
    for path in "$dir/$OTHER.jsonl" "$dir/$OTHER/tool-results/toolu_1.txt" "$dir/$OTHER/subagents/agent-1.jsonl"; do
      read_file -2 "$path"
      others Read "$path"
    done
  done
}

@test "a Read of anything else under the projects directory is refused, a project's old memory directory and a project directory included" {
  read_file -2 "$project/memory/x.md"
  others Read "$project/memory/x.md"
  read_file -2 "$project"
  others Read "$project"
  # The own id in another place than the second component owns nothing.
  read_file -2 "$root/$OWN/x"
  others Read "$root/$OWN/x"
  read_file -2 "$project/$OTHER/$OWN/x"
  others Read "$project/$OTHER/$OWN/x"
  read_file -2 "$project/$OWN.jsonl.bak"
  others Read "$project/$OWN.jsonl.bak"
}

@test "a path outside the projects directory passes for each of the three tools" {
  local path
  for path in "$wt/src/main.sh" "$wt" /etc/hostname "~/.claude/skills/x" "$HOME/.claude/projects-old/x" src; do
    read_file -0 "$path"
    allowed
    grep_in -0 "$path"
    allowed
    glob_in -0 "$path"
    allowed
  done
}

@test "a Read of the projects directory or one above it passes, to fail as a directory by itself" {
  local path
  for path in "$root" "$HOME/.claude" "$HOME" /; do
    read_file -0 "$path"
    allowed
  done
}

@test "a ~ path, a relative path, a .. and a symlink are resolved before the decision" {
  read_file -2 "~/.claude/projects/-home-wt/$OTHER.jsonl"
  others Read "~/.claude/projects/-home-wt/$OTHER.jsonl"
  # Relative to a working directory inside the projects directory.
  read_file -2 "$OTHER.jsonl" "$project"
  others Read "$OTHER.jsonl"
  read_file -2 "../$OTHER/tool-results/toolu_1.txt" "$project/$OWN"
  others Read "../$OTHER/tool-results/toolu_1.txt"
  read_file -2 "$project/$OWN/../$OTHER/tool-results/toolu_1.txt"
  others Read "$project/$OWN/../$OTHER/tool-results/toolu_1.txt"
  ln -s "$project/$OTHER.jsonl" "$wt/notes.jsonl"
  read_file -2 "$wt/notes.jsonl"
  others Read "$wt/notes.jsonl"
  ln -s "$elsewhere/$OTHER" "$wt/dir"
  read_file -2 "$wt/dir/tool-results/toolu_1.txt"
  others Read "$wt/dir/tool-results/toolu_1.txt"
  grep_in -2 "$wt/dir"
  others Grep "$wt/dir"
  # The session's own, reached the same ways, passes.
  ln -s "$project/$OWN.jsonl" "$wt/own.jsonl"
  read_file -0 "$wt/own.jsonl"
  allowed
  read_file -0 "~/.claude/projects/-home-wt/$OWN/tool-results/toolu_1.txt"
  allowed
  read_file -0 "tool-results/toolu_1.txt" "$project/$OWN"
  allowed
}

@test "a projects directory that is itself a symlink is guarded by where it leads" {
  mkdir -p "$HOME/store"
  mv "$root" "$HOME/store/projects"
  ln -s "$HOME/store/projects" "$root"
  read_file -2 "$HOME/store/projects/-home-wt/$OTHER.jsonl"
  others Read "$HOME/store/projects/-home-wt/$OTHER.jsonl"
  read_file -2 "$project/$OTHER.jsonl"
  read_file -0 "$project/$OWN.jsonl"
  allowed
}

@test "a Grep or Glob rooted at the projects directory or above it is refused, naming a narrower path as the fix" {
  local path
  for path in "$root" "$HOME/.claude" "~/.claude" "$HOME" "~" /; do
    grep_in -2 "$path"
    wide Grep "$path"
    glob_in -2 "$path"
    wide Glob "$path"
  done
  # With no path, the search is rooted at the working directory.
  call -2 Grep '{"pattern": "x"}' "$HOME"
  wide Grep "$HOME"
  call -2 Glob '{"pattern": "**/*.jsonl"}' "$root"
  wide Glob "$root"
  call -0 Grep '{"pattern": "x"}'
  allowed
}

@test "a Grep or Glob rooted in the session's own directory passes, and in a project directory or another session's is refused" {
  grep_in -0 "$project/$OWN"
  allowed
  glob_in -0 "$project/$OWN/tool-results"
  allowed
  grep_in -0 "$project/$OWN.jsonl"
  allowed
  grep_in -2 "$project"
  others Grep "$project"
  glob_in -2 "$project"
  others Glob "$project"
  glob_in -2 "$elsewhere/$OTHER"
  others Glob "$elsewhere/$OTHER"
  call -2 Grep '{"pattern": "x"}' "$project/$OTHER"
  others Grep "$project/$OTHER"
}

@test "a Glob whose absolute or ~ pattern starts at the projects directory, above it or in another session's records is refused by its literal start" {
  local pattern
  for pattern in "~/.claude/projects/**/*.jsonl" "$root/**/*.jsonl" "$root/*" "$HOME/.claude/proj*/x" "~/**" "/**/*.jsonl" \
    "$HOME/.claude/{projects,skills}/*" "$root"; do
    call -2 Glob "$(jq -cn --arg p "$pattern" '{pattern: $p}')"
    wide Glob "$pattern"
  done
  for pattern in "$project/*.jsonl" "$project/$OTHER/**" "~/.claude/projects/-home-wt/$OTHER/tool-results/*.txt" \
    "$project/[a-f0-9]*/tool-results/*" "$project/$OTHER.jsonl"; do
    call -2 Glob "$(jq -cn --arg p "$pattern" '{pattern: $p}')"
    others Glob "$pattern"
  done
  # The session's own, a pattern outside the root, and a relative pattern pass.
  for pattern in "$project/$OWN/**" "$project/$OWN/tool-results/*.txt" "$wt/**/*.sh" "~/.claude/skills/**" "**/*.jsonl" \
    "src/*.sh" "*"; do
    call -0 Glob "$(jq -cn --arg p "$pattern" '{pattern: $p}')"
    allowed
  done
  # The path is judged too, whatever the pattern.
  call -2 Glob "$(jq -cn --arg p "$project/$OWN/**" --arg r "$root" '{pattern: $p, path: $r}')"
  wide Glob "$root"
}

@test "a session id that is empty, missing or no UUID owns nothing under the projects directory" {
  local session
  mkdir -p "$project/team-doctor"
  for session in "" - team-doctor "*" "$OWN/.." "${OWN^^}" "$OWN "; do
    read_file -2 "$project/$OWN.jsonl"
    others Read "$project/$OWN.jsonl"
    read_file -2 "$project/$OWN/tool-results/toolu_1.txt"
    grep_in -2 "$project/$OWN"
    read_file -0 "$wt/src/main.sh"
    allowed
  done
  session=team-doctor
  read_file -2 "$project/team-doctor/x"
  read_file -2 "$project/.jsonl"
  session=''
  read_file -2 "$project//x"
  # A session id that is not a string is no id either.
  run_bin -2 --separate-stderr hooks/session-records-guard \
    <<<"$(jq -cn --arg p "$project/$OWN.jsonl" '{tool_name: "Read", session_id: 7, tool_input: {file_path: $p}}')"
  others Read "$project/$OWN.jsonl"
}

@test "the projects directory moves with CLAUDE_CONFIG_DIR" {
  local config=$HOME/config
  mkdir -p "$config/projects/-home-wt/$OWN"
  export CLAUDE_CONFIG_DIR=$config
  read_file -2 "$config/projects/-home-wt/$OTHER.jsonl"
  others Read "$config/projects/-home-wt/$OTHER.jsonl"
  read_file -0 "$config/projects/-home-wt/$OWN.jsonl"
  allowed
  grep_in -2 "$config"
  wide Grep "$config"
  # ~/.claude/projects is then no session's records.
  read_file -0 "$project/$OTHER.jsonl"
  allowed
}

@test "input the hook cannot read is refused: no JSON, no tool_name, a Read with no file_path, a path that is no string" {
  local input
  for input in 'not json' '' '[]' '"Read"' '{}' '{"tool_name": 7}' '{"tool_name": "Read"}' \
    '{"tool_name": "Read", "tool_input": {}}' '{"tool_name": "Read", "tool_input": {"file_path": ""}}' \
    '{"tool_name": "Read", "tool_input": {"file_path": ["/etc/hostname"]}}' \
    '{"tool_name": "Read", "tool_input": "/etc/hostname"}' \
    '{"tool_name": "Grep", "tool_input": {"pattern": "x", "path": 7}}' \
    '{"tool_name": "Glob", "tool_input": {"pattern": ["*"]}}'; do
    run_bin -2 --separate-stderr hooks/session-records-guard <<<"$input"
    unreadable
  done
}

@test "any tool but Read, Grep and Glob passes unread" {
  call -0 Bash "$(jq -cn --arg c "cat $project/$OTHER.jsonl" '{command: $c}')"
  allowed
  call -0 Edit "$(jq -cn --arg p "$project/$OTHER.jsonl" '{file_path: $p}')"
  allowed
  call -0 mcp__x__read '{"file_path": 7}'
  allowed
}

@test "the hook decides with no team home, and a failure of its own blocks the call" {
  rm -rf "${TEAM_HOME:?}"
  read_file -0 "$wt/src/main.sh"
  allowed
  read_file -2 "$project/$OTHER.jsonl"
  others Read "$project/$OTHER.jsonl"
  # An argument is a wrong settings entry, which blocks every call.
  run_bin -2 --separate-stderr hooks/session-records-guard extra <<<'{}'
  assert_contains "$stderr" "usage: session-records-guard"
}

@test "--help prints the header" {
  run_bin -0 hooks/session-records-guard --help
  assert_contains "$output" "Usage: session-records-guard"
  assert_contains "$output" "a session reaches only its own"
}
