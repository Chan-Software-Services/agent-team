#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2088,SC2016,SC2030,SC2031 # output and stderr are set by bats' run; a ~ or a $ is part of a command as an agent types it; each test is a subshell of its own, so what one sets is its own
# hooks/session-records-guard on Bash: a worker's Bash call is held to the same table of
# session-record places (bin/lib/session_records.py) as its Read, Grep and Glob. A call is refused
# when a path one of its commands spells lies in a place and is not the session's own entry
# there; the call's text is read before anything runs, never what a program it starts reads.
# Each test runs the real hook with a PreToolUse JSON on stdin, as Claude Code does.

load helpers/common

OWN=1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d
OTHER=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
# The job directories of the two sessions, each named by its session id's first 8 characters.
JOB=${OWN:0:8}
OTHER_JOB=${OTHER:0:8}

setup() {
  sandbox
  unset CLAUDE_CONFIG_DIR CLAUDE_JOB_DIR SESSION_RECORDS_FOLD_CASE TMP TEMP CDPATH
  # Claude Code's temporary directory, pinned inside the sandbox: its per-user root is $temp.
  export CLAUDE_CODE_TMPDIR=$HOME/tmp
  temp=$CLAUDE_CODE_TMPDIR/claude-$(id -u)
  wt=$HOME/wt
  config=$HOME/.claude
  jobs=$config/jobs
  project=$config/projects/-home-wt
  mkdir -p "$wt/src" "$project/$OWN/tool-results" "$project/$OTHER/tool-results" "$jobs/$JOB/tmp" \
    "$jobs/$OTHER_JOB/tmp" "$temp/-home-wt/$OWN/tasks" "$temp/-home-wt/$OTHER/tasks" "$config/skills"
  touch "$project/$OWN.jsonl" "$project/$OTHER.jsonl"
}

# bash_call <status> <command> [cwd]: run the hook on a Bash call of the session $session (the own
# one unless a test sets it; "-" leaves session_id out of the input).
bash_call() {
  local status=$1 id=${session-$OWN}
  run_bin "$status" --separate-stderr hooks/session-records-guard \
    <<<"$(jq -cn --arg c "$2" --arg cwd "${3:-$wt}" --arg id "$id" \
      '{hook_event_name: "PreToolUse", cwd: $cwd, tool_name: "Bash", tool_input: {command: $c}}
       + (if $id == "-" then {} else {session_id: $id} end)')"
}

# passes <command> [cwd]: the call passes, saying nothing.
passes() {
  bash_call -0 "$@"
  [[ -z $output$stderr ]] || { printf 'command: %s\nsaid: %s%s\n' "$1" "$output" "$stderr" >&2; return 1; }
}

# refused <command> <reason> [cwd]: the call is refused with the guard's reason.
refused() {
  bash_call -2 "$1" "${3:-}"
  assert_equal "$output" ""
  [[ $stderr == "Blocked by session-records-guard: $2" ]] ||
    { printf 'command: %s\nexpected: %s\ngot: %s\n' "$1" "$2" "$stderr" >&2; return 1; }
}

# others <command> <word> <name> <owns> [cwd]: refused as naming another session's entry.
others() {
  refused "$1" "a Bash command naming $2: under $3 a session reads only $4, and this is another session's." "${5:-}"
}

# whole <command> <word> <name> [cwd]: refused as naming a place that holds every session's records.
whole() {
  refused "$1" "a Bash command naming $2: $3 holds every session's records, and a worker session reads none of it." "${4:-}"
}

# wide <command> <word> <name>: refused as naming a place's root or the config directory.
wide() {
  refused "$1" "a Bash command naming $2 would reach every session's records under $3; name a narrower path."
}

PROJECTS_OWNS="its own records, its transcript and what lies under its own session directory"
TEMP_OWNS="what lies under its own session directory"
JOBS_OWNS="what lies in its own job directory"
WHOLE=(transcripts history.jsonl paste-cache sessions daemon daemon.log file-history)
CACHES=(.cache/claude-cli-nodejs Library/Caches/claude-cli-nodejs)

@test "for every place of the table, a Bash command naming another session's entry or a place refused whole is refused" {
  local name path
  others "cat $project/$OTHER.jsonl" "$project/$OTHER.jsonl" "~/.claude/projects" "$PROJECTS_OWNS"
  others "cat $project/$OTHER/tool-results/t.txt" "$project/$OTHER/tool-results/t.txt" "~/.claude/projects" "$PROJECTS_OWNS"
  others "ls $config/projects/-home-other" "$config/projects/-home-other" "~/.claude/projects" "$PROJECTS_OWNS"
  others "tail $temp/-home-wt/$OTHER/tasks/b1.output" "$temp/-home-wt/$OTHER/tasks/b1.output" "$temp" "$TEMP_OWNS"
  others "cat $jobs/$OTHER_JOB/state.json" "$jobs/$OTHER_JOB/state.json" "~/.claude/jobs" "$JOBS_OWNS"
  others "cat $jobs/pins.json" "$jobs/pins.json" "~/.claude/jobs" "$JOBS_OWNS"
  others "cat $config/tasks/$OTHER/1.json" "$config/tasks/$OTHER/1.json" "~/.claude/tasks" "its own task list"
  others "cat $config/session-env/$OTHER/x" "$config/session-env/$OTHER/x" "~/.claude/session-env" "its own environment files"
  for name in "${WHOLE[@]}"; do
    for path in "$config/$name" "$config/$name/x"; do
      whole "cat $path" "$path" "~/.claude/$name"
    done
  done
  for name in "${CACHES[@]}"; do
    whole "ls $HOME/$name/x" "$HOME/$name/x" "~/$name"
  done
}

@test "the refusal holds whichever part of the command names the path: an argument, a wrapper's word, an assignment, a name=value word, a redirection and a cd before a relative name" {
  local history=$config/history.jsonl
  whole "wc -l -- $history" "$history" "~/.claude/history.jsonl"
  whole "flock $history true" "$history" "~/.claude/history.jsonl"
  others "env -C $jobs/$OTHER_JOB ls" "$jobs/$OTHER_JOB" "~/.claude/jobs" "$JOBS_OWNS"
  whole "LOG=$history some-tool" "LOG=$history" "~/.claude/history.jsonl"
  whole "export LOG=$history" "LOG=$history" "~/.claude/history.jsonl"
  whole "dd if=$history of=/dev/null" "if=$history" "~/.claude/history.jsonl"
  whole "some-tool --input=$history" "--input=$history" "~/.claude/history.jsonl"
  whole "wc -l < $history" "$history" "~/.claude/history.jsonl"
  others "echo x > $jobs/$OTHER_JOB/tmp/out" "$jobs/$OTHER_JOB/tmp/out" "~/.claude/jobs" "$JOBS_OWNS"
  others "echo x 2>>$jobs/$OTHER_JOB/log" "$jobs/$OTHER_JOB/log" "~/.claude/jobs" "$JOBS_OWNS"
  whole "cd ~ && cat .claude/history.jsonl" ".claude/history.jsonl" "~/.claude/history.jsonl"
  others "cd $jobs/$JOB && cat ../$OTHER_JOB/state.json" "../$OTHER_JOB/state.json" "~/.claude/jobs" "$JOBS_OWNS"
}

@test "the refusal holds however the path is spelled: ~, \$HOME, \$CLAUDE_JOB_DIR, a variable the command sets, relative, .., a symlink, another case on a folding volume" {
  local owns=$JOBS_OWNS name="~/.claude/jobs"
  whole "cat ~/.claude/history.jsonl" "~/.claude/history.jsonl" "~/.claude/history.jsonl"
  whole 'cat "$HOME/.claude/paste-cache/1.txt"' '$HOME/.claude/paste-cache/1.txt' "~/.claude/paste-cache"
  whole 'cat ${HOME}/.claude/transcripts/x.jsonl' '${HOME}/.claude/transcripts/x.jsonl' "~/.claude/transcripts"
  export CLAUDE_JOB_DIR=$jobs/$JOB
  others 'cat "$CLAUDE_JOB_DIR/../'"$OTHER_JOB"'/state.json"' '$CLAUDE_JOB_DIR/../'"$OTHER_JOB"'/state.json' "$name" "$owns"
  unset CLAUDE_JOB_DIR
  whole 'p=.claude/history.jsonl; cat ~/$p' '~/$p' "~/.claude/history.jsonl"
  others "cat ../$OTHER_JOB/state.json" "../$OTHER_JOB/state.json" "$name" "$owns" "$jobs/$JOB"
  whole "cat ../../transcripts/x.jsonl" "../../transcripts/x.jsonl" "~/.claude/transcripts" "$jobs/$JOB"
  others "cat $jobs/$JOB/../$OTHER_JOB/tmp/x" "$jobs/$JOB/../$OTHER_JOB/tmp/x" "$name" "$owns"
  ln -s "$jobs/$OTHER_JOB" "$wt/their-job"
  others "cat their-job/state.json" "their-job/state.json" "$name" "$owns"
  ln -s "$config/transcripts" "$wt/talk"
  whole "ls $wt/talk" "$wt/talk" "~/.claude/transcripts"
  export SESSION_RECORDS_FOLD_CASE=1
  others "cat $HOME/.claude/Jobs/${OTHER_JOB^^}/state.json" "$HOME/.claude/Jobs/${OTHER_JOB^^}/state.json" "$name" "$owns"
  whole "cat $HOME/.CLAUDE/HISTORY.JSONL" "$HOME/.CLAUDE/HISTORY.JSONL" "~/.claude/history.jsonl"
  passes "cat $HOME/.claude/JOBS/${JOB^^}/state.json"
  unset SESSION_RECORDS_FOLD_CASE
  # A jobs directory that is itself a symlink is guarded by where it leads.
  mv "$jobs" "$HOME/store-jobs"
  ln -s "$HOME/store-jobs" "$jobs"
  others "cat $HOME/store-jobs/$OTHER_JOB/state.json" "$HOME/store-jobs/$OTHER_JOB/state.json" "$name" "$owns"
  passes "cat $HOME/store-jobs/$JOB/state.json"
}

@test "the refusal holds wherever the walk reaches: a later command of a chain, a pipeline, behind a wrapper and in a string a shell is given" {
  local history=$config/history.jsonl name="~/.claude/history.jsonl"
  whole "git status && cat $history" "$history" "$name"
  whole "echo x; cat $history | head" "$history" "$name"
  whole "timeout 5 nohup cat $history" "$history" "$name"
  whole "bash -c 'cat $history'" "$history" "$name"
  whole "eval \"cat $history\"" "$history" "$name"
  whole "echo \$(cat $history)" "$history" "$name"
  whole "find $wt -name x -exec cat $history \\;" "$history" "$name"
}

@test "the session's own entries pass, by path and by \$CLAUDE_JOB_DIR: its job directory and tmp, its background output and its saved tool results" {
  export CLAUDE_JOB_DIR=$jobs/$JOB
  passes "cat $jobs/$JOB/state.json"
  passes 'ls "$CLAUDE_JOB_DIR"/tmp'
  passes 'T=$(mktemp -d "$CLAUDE_JOB_DIR/tmp/x.XXXXXX") && echo hi > "$T/out" && cat "$T/out"'
  passes 'echo x > $CLAUDE_JOB_DIR/tmp/out.txt; cat < ${CLAUDE_JOB_DIR}/tmp/out.txt'
  passes "ls $jobs/$JOB/tmp/*.txt"
  passes "cat tmp/x" "$jobs/$JOB"
  passes "tail -n 20 $temp/-home-wt/$OWN/tasks/b1.output"
  passes "cat $project/$OWN/tool-results/t.txt"
  passes "wc -l $project/$OWN.jsonl"
  passes "cat $config/tasks/$OWN/1.json $config/session-env/$OWN/x"
  # A job directory CLAUDE_JOB_DIR names directly in the jobs directory is the session's own too.
  mkdir -p "$jobs/f74584cf/tmp"
  CLAUDE_JOB_DIR=$jobs/f74584cf passes 'cat "$CLAUDE_JOB_DIR/tmp/x"'
}

@test "a session id that is empty, missing or no UUID owns nothing, its job directory included" {
  local id
  for id in "" "-" "not-a-uuid"; do
    session=$id others "cat $jobs/$JOB/state.json" "$jobs/$JOB/state.json" "~/.claude/jobs" "$JOBS_OWNS"
    session=$id others "cat $project/$OWN.jsonl" "$project/$OWN.jsonl" "~/.claude/projects" "$PROJECTS_OWNS"
  done
}

@test "naming a keyed place's root or the config directory is refused as too wide, and the home directory, /tmp and / pass" {
  wide "ls ~/.claude" "~/.claude" "~/.claude/projects"
  wide "du -sh $config/" "$config/" "~/.claude/projects"
  wide "ls ~/.claude/*.json" "~/.claude/*.json" "~/.claude/projects"
  wide "grep -r x $config/projects" "$config/projects" "~/.claude/projects"
  wide "ls ~/.claude/jobs/" "~/.claude/jobs/" "~/.claude/jobs"
  wide "cat ~/.claude/jobs/*/state.json" "~/.claude/jobs/*/state.json" "~/.claude/jobs"
  wide "ls ~/.claude/tasks" "~/.claude/tasks" "~/.claude/tasks"
  wide "ls ~/.claude/session-env" "~/.claude/session-env" "~/.claude/session-env"
  wide "find $temp -name x" "$temp" "$temp"
  passes "ls ~"
  passes "ls -la \$HOME /tmp /"
  passes "du -sh ~/.cache $CLAUDE_CODE_TMPDIR"
  passes "ls ~/.claude/skills ~/.claude/settings.json ~/.claude/shell-snapshots ~/.claude/backups"
}

@test "an ordinary command passes with nothing said, as does one that mentions a place only inside a longer string, or a word the guard cannot resolve" {
  passes "git status && git diff --stat"
  passes "cd src && ls -la && cat main.sh"
  passes 'git commit -m "the guard reads ~/.claude/history.jsonl as every session'"'"'s"'
  passes "grep -n '~/.claude/jobs/ holds' notes.md"
  passes $'cat > notes.md <<\'EOF\'\ncat ~/.claude/history.jsonl\nEOF'
  passes 'cat "$UNSET_SOMEWHERE/.claude/history.jsonl"'
  passes 'cat "$(cat path.txt)"'
  passes 'cat ~nobody/.claude/history.jsonl'
}

@test "a team script run by name passes whatever it reads, judged by the call's text alone" {
  passes "bin/team-load-check --probe --role builder" "$wt"
  passes "\$HOME/agent-team/bin/team-load-check --probe"
  printf '#!/usr/bin/env bash\ncat ~/.claude/history.jsonl ~/.claude/jobs/%s/state.json\n' "$OTHER_JOB" >"$wt/read-record.sh"
  chmod +x "$wt/read-record.sh"
  passes "./read-record.sh"
  passes "bash read-record.sh"
}

@test "a Bash call with no command string is refused as unreadable" {
  local input
  for input in '{"tool_name": "Bash"}' '{"tool_name": "Bash", "tool_input": {}}' \
    '{"tool_name": "Bash", "tool_input": {"command": 7}}' '{"tool_name": "Bash", "tool_input": {"command": ["ls"]}}' \
    '{"tool_name": "Bash", "tool_input": "ls"}'; do
    run_bin -2 --separate-stderr hooks/session-records-guard <<<"$input"
    assert_equal "$stderr" "Blocked by session-records-guard: its input is not a hook call it can read, and a guard that cannot decide refuses."
  done
}

@test "a failure of the table's module blocks a Bash call, naming its last line" {
  export CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  # The shared hard link is replaced, never written through.
  local module=$CODE_CHECKOUT/bin/lib/session_records.py
  printf 'import sys\nsys.stderr.write("session_records.py: RuntimeError: boom\\n")\nsys.exit(1)\n' >"$module.new"
  mv -f "$module.new" "$module"
  bash_call -2 "ls"
  assert_equal "$stderr" "Blocked by session-records-guard: it could not read the call (bin/lib/session_records.py: session_records.py: RuntimeError: boom), and a guard that cannot decide refuses."
}
