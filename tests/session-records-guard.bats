#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2088,SC2030,SC2031 # output and stderr are set by bats' run; a ~ is part of a path as an agent types it; each test is a subshell of its own, so what one sets is its own
# hooks/session-records-guard on Read, Grep and Glob: of the session-record places its table
# (bin/lib/session_records.py) lists, a session reaches only its own entry in a place keyed by its
# session or job id (~/.claude/projects, Claude Code's temporary directory, ~/.claude/jobs, tasks
# and session-env), and none of a place that holds every session's records (~/.claude/transcripts,
# history.jsonl, paste-cache, sessions, daemon, daemon.log, file-history and the CLI cache).
# Each test runs the real hook with a PreToolUse JSON on stdin, as Claude Code does.

load helpers/common

OWN=1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d
OTHER=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
# The job directories of the two sessions, each named by its session id's first 8 characters.
JOB=${OWN:0:8}
OTHER_JOB=${OTHER:0:8}

setup() {
  sandbox
  unset CLAUDE_CONFIG_DIR CLAUDE_JOB_DIR SESSION_RECORDS_FOLD_CASE TMP TEMP
  # Claude Code's temporary directory, pinned inside the sandbox: its per-user root is $temp.
  export CLAUDE_CODE_TMPDIR=$HOME/tmp
  temp=$CLAUDE_CODE_TMPDIR/claude-$(id -u)
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

# wide <tool> <path> [<root>]: the last call was refused as a search of every session's records,
# under ~/.claude/projects or the root named.
wide() {
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by session-records-guard: $1 rooted at $2 would search every session's records under ${3:-~/.claude/projects}; give it a narrower path."
}

# others_temp <tool> <path>: the last call was refused as a reach into another session's
# directory of Claude Code's temporary directory; others_in <root> <tool> <path>, of the
# temporary directory at <root>.
others_temp() {
  others_in "$temp" "$@"
}
others_in() {
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by session-records-guard: $2 of $3: under $1 a session reads only what lies under its own session directory, and this is another session's."
}

# owned_by <name> <owns> <tool> <path>: the last call was refused as a reach into another
# session's entry of the place shown as <name>, where a session reads only <owns>.
owned_by() {
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by session-records-guard: $3 of $4: under $1 a session reads only $2, and this is another session's."
}

# whole <name> <tool> <path>: the last call was refused as a reach into the place shown as <name>,
# which holds every session's records.
whole() {
  assert_equal "$output" ""
  assert_equal "$stderr" "Blocked by session-records-guard: $2 of $3: $1 holds every session's records, and a worker session reads none of it."
}

# The keyed places this table adds, each as <dir name>:<what a session owns there>, and the
# places refused whole under the config directory; the CLI cache's two paths are under $HOME.
KEYED=("jobs:what lies in its own job directory" "tasks:its own task list" "session-env:its own environment files")
WHOLE=(transcripts history.jsonl paste-cache sessions daemon daemon.log file-history)
CACHES=(.cache/claude-cli-nodejs Library/Caches/claude-cli-nodejs)

# own_entry <dir name>: the name of the session's own entry in that keyed place, and
# other_entry <dir name> another session's.
own_entry() {
  if [[ $1 == jobs ]]; then echo "$JOB"; else echo "$OWN"; fi
}
other_entry() {
  if [[ $1 == jobs ]]; then echo "$OTHER_JOB"; else echo "$OTHER"; fi
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
  for session in "" - team-doctor "*" "$OWN/.." "${OWN^^}" "$OWN " \
    hhhhhhhh-hhhh-hhhh-hhhh-hhhhhhhhhhhh "h${OWN:1}"; do
    read_file -2 "$project/$OWN.jsonl"
    others Read "$project/$OWN.jsonl"
    read_file -2 "$project/$OWN/tool-results/toolu_1.txt"
    grep_in -2 "$project/$OWN"
    read_file -0 "$wt/src/main.sh"
    allowed
  done
  # A letter that is no hex digit makes no UUID, so such an id does not own even its own name.
  for session in hhhhhhhh-hhhh-hhhh-hhhh-hhhhhhhhhhhh "h${OWN:1}"; do
    read_file -2 "$project/$session.jsonl"
    others Read "$project/$session.jsonl"
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

@test "on a volume that folds case, a path that names the projects directory or another session's records in another case is refused" {
  # No Linux volume of the tests folds case, so the seam says this one does.
  export SESSION_RECORDS_FOLD_CASE=1
  local path
  for path in "$HOME/.claude/Projects/-home-wt/$OTHER.jsonl" "$HOME/.CLAUDE/projects/-home-wt/$OTHER.jsonl" \
    "${root^^}/-HOME-WT/${OTHER^^}/tool-results/toolu_1.txt" "$HOME/.claude/PROJECTS/-home-wt"; do
    read_file -2 "$path"
    others Read "$path"
  done
  grep_in -2 "$HOME/.Claude"
  wide Grep "$HOME/.Claude"
  glob_in -2 "$HOME/.claude/Projects"
  wide Glob "$HOME/.claude/Projects"
  call -2 Glob "$(jq -cn --arg p "$HOME/.CLAUDE/projects/**/*.jsonl" '{pattern: $p}')"
  wide Glob "$HOME/.CLAUDE/projects/**/*.jsonl"
  # The session's own records are its own in any case, and a path outside is outside.
  read_file -0 "$HOME/.claude/Projects/-home-wt/$OWN.jsonl"
  allowed
  read_file -0 "${root^^}/-HOME-WT/${OWN^^}/tool-results/toolu_1.txt"
  allowed
  read_file -0 "$wt/SRC/main.sh"
  allowed
  # The temporary directory's root folds with it.
  read_file -2 "${temp^^}/-home-wt/$OTHER/tasks/b1.output"
  others_temp Read "${temp^^}/-home-wt/$OTHER/tasks/b1.output"
}

@test "a volume that does not fold case keeps a re-cased name a path of its own" {
  [[ ! ${root^^} -ef $root ]] || skip "this volume folds case"
  read_file -0 "$HOME/.claude/Projects/-home-wt/$OTHER.jsonl"
  allowed
  grep_in -0 "$HOME/.claude/Projects"
  allowed
}

@test "under Claude Code's temporary directory a session reaches only its own session directory" {
  mkdir -p "$temp/-home-wt/$OWN/tasks" "$temp/-home-wt/$OTHER/tasks" "$temp/-home-other/$OTHER/scratchpad"
  local path tool
  for path in "$temp/-home-wt/$OWN/tasks/b1.output" "$temp/-home-wt/$OWN/scratchpad/notes.md"; do
    read_file -0 "$path"
    allowed
  done
  grep_in -0 "$temp/-home-wt/$OWN"
  allowed
  glob_in -0 "$temp/-home-wt/$OWN/tasks"
  allowed
  for path in "$temp/-home-wt/$OTHER/tasks/b1.output" "$temp/-home-other/$OTHER/scratchpad/notes.md" \
    "$temp/-home-wt/x" "$temp/-home-wt/$OWN/../$OTHER/tasks/b1.output"; do
    read_file -2 "$path"
    others_temp Read "$path"
  done
  ln -s "$temp/-home-wt/$OTHER/tasks" "$wt/their-tasks"
  read_file -2 "$wt/their-tasks/b1.output"
  others_temp Read "$wt/their-tasks/b1.output"
  grep_in -2 "$temp/-home-wt/$OTHER"
  others_temp Grep "$temp/-home-wt/$OTHER"
  glob_in -2 "$temp/-home-wt"
  others_temp Glob "$temp/-home-wt"
  # The root and what lies above it: a search there would walk every session's directory.
  for path in "$temp" "$CLAUDE_CODE_TMPDIR"; do
    grep_in -2 "$path"
    wide Grep "$path" "$temp"
    glob_in -2 "$path"
    wide Glob "$path" "$temp"
    read_file -0 "$path"
    allowed
  done
  call -2 Glob "$(jq -cn --arg p "$temp/**/*.output" '{pattern: $p}')"
  wide Glob "$temp/**/*.output" "$temp"
  # A sibling of the root in the same directory is no session's records.
  for tool in read_file grep_in glob_in; do
    "$tool" -0 "$CLAUDE_CODE_TMPDIR/build"
    allowed
  done
  # A session with no UUID owns nothing there either.
  session=team-doctor read_file -2 "$temp/-home-wt/$OWN/tasks/b1.output"
}

@test "the temporary directory is CLAUDE_CODE_TMPDIR's, else TMPDIR's, TMP's, TEMP's, else /tmp's claude-<uid>" {
  local uid
  uid=$(id -u)
  unset CLAUDE_CODE_TMPDIR
  export TMPDIR=$HOME/os-tmp/
  read_file -2 "$HOME/os-tmp/claude-$uid/-home-wt/$OTHER/tasks/b1.output"
  read_file -0 "$HOME/os-tmp/claude-$uid/-home-wt/$OWN/tasks/b1.output"
  allowed
  read_file -0 "$temp/-home-wt/$OTHER/tasks/b1.output"
  allowed
  # With no TMPDIR the OS temp dir is TMP's, then TEMP's, as Node's os.tmpdir() reads them.
  unset TMPDIR
  export TEMP=$HOME/temp-var
  read_file -2 "$HOME/temp-var/claude-$uid/-home-wt/$OTHER/tasks/b1.output"
  others_in "$HOME/temp-var/claude-$uid" Read "$HOME/temp-var/claude-$uid/-home-wt/$OTHER/tasks/b1.output"
  read_file -0 "$HOME/temp-var/claude-$uid/-home-wt/$OWN/tasks/b1.output"
  allowed
  export TMP=$HOME/tmp-var
  read_file -2 "$HOME/tmp-var/claude-$uid/-home-wt/$OTHER/tasks/b1.output"
  others_in "$HOME/tmp-var/claude-$uid" Read "$HOME/tmp-var/claude-$uid/-home-wt/$OTHER/tasks/b1.output"
  read_file -0 "$HOME/temp-var/claude-$uid/-home-wt/$OTHER/tasks/b1.output"
  allowed
  unset TMP TEMP
  read_file -2 "/tmp/claude-$uid/-home-wt/$OTHER/tasks/b1.output"
  read_file -0 "/tmp/claude-$uid/-home-wt/$OWN/tasks/b1.output"
  allowed
}

@test "under ~/.claude/jobs, tasks and session-env a session reaches only its own entry, for each of the three tools" {
  local entry place owns dir own other path tool
  for entry in "${KEYED[@]}"; do
    place=${entry%%:*} owns=${entry#*:} dir=$HOME/.claude/$place
    own=$(own_entry "$place") other=$(other_entry "$place")
    mkdir -p "$dir/$own/sub" "$dir/$other"
    for path in "$dir/$own" "$dir/$own/state.json" "$dir/$own/sub/x.json"; do
      for tool in read_file grep_in glob_in; do
        "$tool" -0 "$path"
        allowed
      done
    done
    # Another session's entry, a file of the place's own, a near name and the full id where the
    # place keys by its prefix are all another session's.
    for path in "$dir/$other" "$dir/$other/state.json" "$dir/pins.json" "$dir/${own}x/state.json" \
      "$dir/${own:0:7}/state.json"; do
      read_file -2 "$path"
      owned_by "~/.claude/$place" "$owns" Read "$path"
      grep_in -2 "$path"
      owned_by "~/.claude/$place" "$owns" Grep "$path"
      glob_in -2 "$path"
      owned_by "~/.claude/$place" "$owns" Glob "$path"
    done
  done
  read_file -2 "$HOME/.claude/jobs/$OWN/state.json"
  owned_by "~/.claude/jobs" "what lies in its own job directory" Read "$HOME/.claude/jobs/$OWN/state.json"
}

@test "the own job directory is the one the session id's first 8 characters name, or the one CLAUDE_JOB_DIR names directly in the jobs directory, and no other" {
  local jobs=$HOME/.claude/jobs dir owns="what lies in its own job directory"
  mkdir -p "$jobs/f74584cf/tmp" "$jobs/$JOB" "$jobs/$OTHER_JOB/tmp" "$HOME/elsewhere/$OTHER_JOB"
  export CLAUDE_JOB_DIR=$jobs/f74584cf
  read_file -0 "$jobs/f74584cf/tmp/notes.txt"
  allowed
  grep_in -0 "$jobs/f74584cf"
  allowed
  glob_in -0 "$jobs/f74584cf/tmp"
  allowed
  read_file -0 "$jobs/$JOB/state.json"
  allowed
  read_file -2 "$jobs/$OTHER_JOB/state.json"
  owned_by "~/.claude/jobs" "$owns" Read "$jobs/$OTHER_JOB/state.json"
  # A CLAUDE_JOB_DIR anywhere but directly in the jobs directory owns nothing there.
  for dir in "$HOME/elsewhere/$OTHER_JOB" "$jobs/$OTHER_JOB/tmp" "$jobs" "$HOME/.claude"; do
    CLAUDE_JOB_DIR=$dir read_file -2 "$jobs/$OTHER_JOB/state.json"
    owned_by "~/.claude/jobs" "$owns" Read "$jobs/$OTHER_JOB/state.json"
    CLAUDE_JOB_DIR=$dir read_file -2 "$jobs/tmp/x"
    owned_by "~/.claude/jobs" "$owns" Read "$jobs/tmp/x"
    CLAUDE_JOB_DIR=$dir read_file -2 "$jobs/jobs/x"
    CLAUDE_JOB_DIR=$dir read_file -2 "$jobs/.claude/x"
  done
}

@test "a session id that is empty, missing or no UUID owns nothing under jobs, tasks or session-env, CLAUDE_JOB_DIR's directory included" {
  local session entry place dir
  export CLAUDE_JOB_DIR=$HOME/.claude/jobs/$JOB
  for session in "" - team-doctor "${OWN^^}" "$OWN " "h${OWN:1}"; do
    for entry in "${KEYED[@]}"; do
      place=${entry%%:*} dir=$HOME/.claude/$place/$(own_entry "$place")
      read_file -2 "$dir/state.json"
      owned_by "~/.claude/$place" "${entry#*:}" Read "$dir/state.json"
      grep_in -2 "$dir"
    done
    read_file -2 "$HOME/.claude/jobs/${session:0:8}/state.json"
  done
}

@test "each place that holds every session's records is refused whole, itself and what lies under it, for each of the three tools, whatever the session id" {
  local place name path tool session
  for place in "${WHOLE[@]/#/.claude/}" "${CACHES[@]}"; do
    name="~/$place"
    for session in "$OWN" - team-doctor; do
      for path in "$HOME/$place" "$HOME/$place/$OWN.jsonl" "$HOME/$place/$OWN/x" "$HOME/$place/x/y.txt"; do
        read_file -2 "$path"
        whole "$name" Read "$path"
        grep_in -2 "$path"
        whole "$name" Grep "$path"
        glob_in -2 "$path"
        whole "$name" Glob "$path"
      done
    done
  done
}

@test "a Grep or Glob rooted at jobs, tasks or session-env is refused as too wide, naming it, and a Read there fails by itself" {
  local entry dir name
  for entry in "${KEYED[@]}"; do
    dir=$HOME/.claude/${entry%%:*} name="~/.claude/${entry%%:*}"
    mkdir -p "$dir"
    grep_in -2 "$dir"
    wide Grep "$dir" "$name"
    glob_in -2 "$dir"
    wide Glob "$dir" "$name"
    call -2 Grep '{"pattern": "x"}' "$dir"
    wide Grep "$dir" "$name"
    read_file -0 "$dir"
    allowed
  done
  # The config directory and above name the projects directory, the first place in the table.
  for dir in "$HOME/.claude" "~/.claude" "$HOME"; do
    grep_in -2 "$dir"
    wide Grep "$dir"
  done
  # A directory above the CLI cache alone names it.
  grep_in -2 "$HOME/.cache"
  wide Grep "$HOME/.cache" "~/.cache/claude-cli-nodejs"
  glob_in -2 "$HOME/Library"
  wide Glob "$HOME/Library" "~/Library/Caches/claude-cli-nodejs"
}

@test "a Glob whose absolute or ~ pattern starts in jobs, tasks, session-env or a place refused whole is refused by its literal start" {
  local pattern place
  for place in jobs tasks session-env; do
    for pattern in "~/.claude/$place/*/state.json" "$HOME/.claude/$place/**" "$HOME/.claude/$place" "$HOME/.claude/$place/[a-f]*/x"; do
      call -2 Glob "$(jq -cn --arg p "$pattern" '{pattern: $p}')"
      wide Glob "$pattern" "~/.claude/$place"
    done
  done
  for pattern in "~/.claude/jobs/$OTHER_JOB/**" "$HOME/.claude/jobs/$OTHER_JOB/tmp/[a-f]*"; do
    call -2 Glob "$(jq -cn --arg p "$pattern" '{pattern: $p}')"
    owned_by "~/.claude/jobs" "what lies in its own job directory" Glob "$pattern"
  done
  call -2 Glob "$(jq -cn --arg p "~/.claude/tasks/$OTHER/*.json" '{pattern: $p}')"
  owned_by "~/.claude/tasks" "its own task list" Glob "~/.claude/tasks/$OTHER/*.json"
  for place in "${WHOLE[@]}"; do
    for pattern in "~/.claude/$place/*.jsonl" "$HOME/.claude/$place/$OWN/**" "~/.claude/$place"; do
      call -2 Glob "$(jq -cn --arg p "$pattern" '{pattern: $p}')"
      whole "~/.claude/$place" Glob "$pattern"
    done
  done
  call -2 Glob "$(jq -cn --arg p "~/.cache/claude-cli-nodejs/*/mcp-logs-*" '{pattern: $p}')"
  whole "~/.cache/claude-cli-nodejs" Glob "~/.cache/claude-cli-nodejs/*/mcp-logs-*"
  # The session's own passes.
  for pattern in "~/.claude/jobs/$JOB/**" "$HOME/.claude/tasks/$OWN/*.json" "~/.claude/session-env/$OWN/*"; do
    call -0 Glob "$(jq -cn --arg p "$pattern" '{pattern: $p}')"
    allowed
  done
}

@test "a path into jobs or a place refused whole is refused however it is spelled: ~, relative, .., a symlink, another case on a folding volume" {
  local jobs=$HOME/.claude/jobs owns="what lies in its own job directory" transcripts=$HOME/.claude/transcripts
  mkdir -p "$jobs/$JOB/tmp" "$jobs/$OTHER_JOB/tmp" "$transcripts"
  read_file -2 "~/.claude/jobs/$OTHER_JOB/state.json"
  owned_by "~/.claude/jobs" "$owns" Read "~/.claude/jobs/$OTHER_JOB/state.json"
  read_file -2 "~/.claude/transcripts/x.jsonl"
  whole "~/.claude/transcripts" Read "~/.claude/transcripts/x.jsonl"
  # Relative to a working directory in the session's own job directory.
  read_file -2 "../$OTHER_JOB/state.json" "$jobs/$JOB"
  owned_by "~/.claude/jobs" "$owns" Read "../$OTHER_JOB/state.json"
  read_file -2 "../../transcripts/x.jsonl" "$jobs/$JOB"
  whole "~/.claude/transcripts" Read "../../transcripts/x.jsonl"
  read_file -2 "$jobs/$JOB/../$OTHER_JOB/tmp/x"
  owned_by "~/.claude/jobs" "$owns" Read "$jobs/$JOB/../$OTHER_JOB/tmp/x"
  ln -s "$jobs/$OTHER_JOB" "$wt/their-job"
  read_file -2 "$wt/their-job/state.json"
  owned_by "~/.claude/jobs" "$owns" Read "$wt/their-job/state.json"
  grep_in -2 "$wt/their-job"
  owned_by "~/.claude/jobs" "$owns" Grep "$wt/their-job"
  ln -s "$transcripts" "$wt/talk"
  glob_in -2 "$wt/talk"
  whole "~/.claude/transcripts" Glob "$wt/talk"
  # The session's own, reached the same ways, passes.
  read_file -0 "~/.claude/jobs/$JOB/tmp/x"
  allowed
  read_file -0 "tmp/x" "$jobs/$JOB"
  allowed
  ln -s "$jobs/$JOB/tmp" "$wt/scratch"
  grep_in -0 "$wt/scratch"
  allowed
  # On a volume that folds case, another case names the same place.
  export SESSION_RECORDS_FOLD_CASE=1
  read_file -2 "$HOME/.claude/Jobs/${OTHER_JOB^^}/state.json"
  owned_by "~/.claude/jobs" "$owns" Read "$HOME/.claude/Jobs/${OTHER_JOB^^}/state.json"
  read_file -2 "$HOME/.CLAUDE/Transcripts/x.jsonl"
  whole "~/.claude/transcripts" Read "$HOME/.CLAUDE/Transcripts/x.jsonl"
  read_file -2 "$HOME/.claude/HISTORY.JSONL"
  whole "~/.claude/history.jsonl" Read "$HOME/.claude/HISTORY.JSONL"
  read_file -0 "$HOME/.claude/JOBS/${JOB^^}/state.json"
  allowed
  unset SESSION_RECORDS_FOLD_CASE
  # A jobs directory that is itself a symlink is guarded by where it leads.
  mv "$jobs" "$HOME/store-jobs"
  ln -s "$HOME/store-jobs" "$jobs"
  read_file -2 "$HOME/store-jobs/$OTHER_JOB/state.json"
  owned_by "~/.claude/jobs" "$owns" Read "$HOME/store-jobs/$OTHER_JOB/state.json"
  read_file -0 "$HOME/store-jobs/$JOB/state.json"
  allowed
}

@test "a neighbour of each place passes for each of the three tools: shell-snapshots, backups, skills and files of the config directory that are no place" {
  local path tool
  for path in "$HOME/.claude/shell-snapshots/snapshot-bash-1.sh" "$HOME/.claude/backups/x.json" \
    "$HOME/.claude/skills/x/SKILL.md" "$HOME/.claude/settings.json" "$HOME/.claude/daemon.status.json" \
    "$HOME/.claude/history.jsonl.bak" "$HOME/.claude/jobs-old/x" "$HOME/.claude/tasks.md" "$HOME/.claude/daemon.log.1" \
    "$HOME/.cache/other/x" "$HOME/.cache/claude-cli-nodejs-old/x" "$HOME/Library/Caches/other"; do
    for tool in read_file grep_in glob_in; do
      "$tool" -0 "$path"
      allowed
    done
  done
}

@test "the config directory's places move with CLAUDE_CONFIG_DIR, and the CLI cache stays under the home directory" {
  local config=$HOME/config
  mkdir -p "$config/jobs/$JOB" "$config/jobs/f74584cf"
  export CLAUDE_CONFIG_DIR=$config
  read_file -2 "$config/jobs/$OTHER_JOB/state.json"
  owned_by "~/.claude/jobs" "what lies in its own job directory" Read "$config/jobs/$OTHER_JOB/state.json"
  read_file -0 "$config/jobs/$JOB/state.json"
  allowed
  CLAUDE_JOB_DIR=$config/jobs/f74584cf read_file -0 "$config/jobs/f74584cf/tmp/x"
  allowed
  read_file -2 "$config/tasks/$OTHER/1.json"
  owned_by "~/.claude/tasks" "its own task list" Read "$config/tasks/$OTHER/1.json"
  read_file -2 "$config/history.jsonl"
  whole "~/.claude/history.jsonl" Read "$config/history.jsonl"
  grep_in -2 "$config/session-env"
  wide Grep "$config/session-env" "~/.claude/session-env"
  # ~/.claude's are then no session's records, and the CLI cache is where it was.
  read_file -0 "$HOME/.claude/jobs/$OTHER_JOB/state.json"
  allowed
  read_file -0 "$HOME/.claude/history.jsonl"
  allowed
  read_file -2 "$HOME/.cache/claude-cli-nodejs/x/mcp-logs-y/1.txt"
  whole "~/.cache/claude-cli-nodejs" Read "$HOME/.cache/claude-cli-nodejs/x/mcp-logs-y/1.txt"
}

@test "a failure of the table's module blocks the call, naming its last line, and so does output that holds no reason" {
  export CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  # The shared hard link is replaced, never written through.
  local module=$CODE_CHECKOUT/bin/lib/session_records.py
  printf 'import sys\nsys.stderr.write("session_records.py: RuntimeError: boom\\n")\nsys.exit(1)\n' >"$module.new"
  mv -f "$module.new" "$module"
  read_file -2 "$wt/src/main.sh"
  assert_equal "$stderr" "Blocked by session-records-guard: it could not read the call (bin/lib/session_records.py: session_records.py: RuntimeError: boom), and a guard that cannot decide refuses."
  call -2 Edit "$(jq -cn --arg p "$wt/src/main.sh" '{file_path: $p}')"
  printf 'print(%s)\n' "'{\"rule\": \"x\"}'" >"$module.new"
  mv -f "$module.new" "$module"
  read_file -2 "$wt/src/main.sh"
  assert_equal "$stderr" 'Blocked by session-records-guard: it could not read the call (bin/lib/session_records.py: {"rule": "x"}), and a guard that cannot decide refuses.'
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
  assert_contains "$output" "reaches only its own. Exit 2 blocks the call"
  assert_contains "$output" "One table, bin/lib/session_records.py's, lists every session-record place"
}
