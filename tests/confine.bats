#!/usr/bin/env bats
# lib/confine.py: the kernel layer, a wrapper that enters a Landlock domain and then runs its
# command, so removing or renaming a directory entry succeeds only under its roots. Tested by
# outcome: each case runs the real wrapper in a sandbox worktree with a canary tree outside its
# roots and asserts what survived, never what was parsed. A control runs each spelling without
# the wrapper and must destroy the canary, so the test can fail.
# Every case skips, naming the ABI, where the kernel's Landlock ABI is below 2 (no Landlock,
# ABI 1, macOS).
# lib/confine-session writes a session's directory, its session file and its program bash, into
# the sandbox's HOME, with a session tmp in the test's own directory, so no test makes a
# directory under the machine's ~/.config or /tmp. A session's commands are driven as Claude Code
# drives them: the program as its shell, <dir>/bash -c [-l] "<dir>/bash '<line>'", and the
# program as its prefix, <dir>/bash '<line>' (lib/confine-shell's two forms).

load helpers/common

setup() {
  sandbox
  unset AGENT_TEAM_WORKTREE AGENT_TEAM_GIT_DIR CLAUDE_PROJECT_DIR CLAUDE_JOB_DIR CLAUDE_CODE_SHELL BASH_ENV ENV
  unset CONFINE_TEST_ABI CONFINE_TEST_FAIL CONFINE_REAL
  CONFINE=$REPO_ROOT/bin/lib/confine.py
  WRITE=$REPO_ROOT/bin/lib/confine-session
  ABI=$(python3 -I "$CONFINE" --abi)
  ((ABI >= 2)) || skip "this machine's Landlock ABI is $ABI, and the file rules need 2"
  BOX=$BATS_TEST_TMPDIR/box
  WT=$BOX/wt OUT=$BOX/out GIT=$BOX/git STMP=$BOX/stmp
  TASK=T7
  SDIR=$HOME/.config/agent-team/confine/$TASK/builder.test--22
  SFILE=$SDIR/session.json PROGRAM=$SDIR/bash
  JOB=$HOME/.claude/jobs/0badc0de
  mkdir -p "$WT" "$OUT" "$GIT" "$JOB/tmp"
}

# Exports each <NAME=value> to the wrapper the test runs after it: with <NAME=value>...
with() {
  export "${@?}"
}

# The wrapper run from <dir> with <arguments>, stdout and stderr apart: confined <dir> <argument>...
confined() {
  local dir=$1
  shift
  run --separate-stderr env -C "$dir" python3 -I "$CONFINE" "$@"
}

# The wrapper has no seam, so a test that needs another ABI or a domain that cannot be entered
# runs it through tests/helpers/confine-seams.py, which reads CONFINE_TEST_ABI and
# CONFINE_TEST_FAIL and loads the wrapper CONFINE named.
seams() {
  with CONFINE_REAL="$CONFINE"
  CONFINE=$BATS_TEST_DIRNAME/helpers/confine-seams.py
}

# The canary tree outside the roots, made new, and the links in the worktree that reach it.
canary() {
  rm -rf "${OUT:?}"
  mkdir -p "$OUT/x/deep" "$OUT/x/empty" "$WT/src/a/b" "$WT/build/d" "$WT/build/c" "$WT/T"
  echo canary >"$OUT/x/deep/file"
  echo mine >"$WT/mine"
  ln -sfn "$OUT" "$WT/src/a/b/l"
  ln -sfn "$OUT" "$WT/build/d/.l"
  ln -sfn "$OUT" "$WT/build/c/L"
}

# Every entry of the canary tree and its file's content, which is whole while this prints what
# WHOLE holds.
canary_tree() {
  find "$OUT/x" 2>/dev/null | LC_ALL=C sort
  cat "$OUT/x/deep/file" 2>/dev/null || true
}

WHOLE='OUT/x
OUT/x/deep
OUT/x/deep/file
OUT/x/empty
canary'

# Each delete spelling, run by bash -c from the worktree's root, with OUT for the directory
# outside the roots: a new spelling is one line. The first block is the plain forms, then the
# spellings of T302's review findings 26 to 39 (the text guard's fix rounds 8 and 9), then what
# no text guard sees. Each must exit non-zero, so a form whose own status hides the refused
# delete (a trap, a background job) hands it on.
SPELLINGS=(
  'rm -rf OUT/x'
  'rm -r OUT/x/deep'
  'rm OUT/x/deep/file'
  'rmdir OUT/x/empty'
  'unlink OUT/x/deep/file'
  'find OUT/x -delete'
  'find OUT/x -depth -exec rm -rf {} +'
  # 26: a name split by quotes or a backslash, and a decoded script.
  "r''m -rf OUT/x"
  'r\m -rf OUT/x'
  "printf '\\x72m -rf OUT/x\\n' > x.sh; bash x.sh"
  # 27: brace expansion of the command word.
  '{rm,-rf,OUT/x}'
  # 28: a .. or a link after a glob.
  'rm -rf src/*/../../../out/x'
  'rm -rf build/d/.l/x'
  'rm -rf src/a/b/*/x'
  # 29: find's -- and -files0-from.
  'find -- OUT/x -delete'
  'printf "OUT/x\0" > list; find -files0-from list -delete'
  # 32 and 37: a shell option that changes what a path means.
  $'V=OUT\nshopt -s cdable_vars\ncd V; rm -rf x'
  $'V=OUT\nshopt -s cdable_v\'\'ars\ncd V; rm -rf x'
  $'shopt -s extglob\ncd OUT; rm -rf @(x)'
  # 35 and 36: a line continuation and a locale string.
  $'r\\\nm -rf OUT/x'
  $'find OUT/x -del\\\nete'
  '$"rm" -rf OUT/x'
  # 38: glob options.
  $'shopt -s dotglob\nrm -rf build/d/*/x'
  $'GLOBIGNORE=q\nrm -rf build/d/*/x'
  $'shopt -s nocaseglob\nrm -rf build/c/l*/x'
  $'shopt -s globstar\nrm -rf src/**/x'
  # 39: a decoded script piped into a shell.
  "printf '\\x72m -rf OUT/x\\n' | bash"
  "echo -e '\\x72m -rf OUT/x' | sh"
  # Not seen by the text guard: an interpreter's own delete, a name built at run time, an alias,
  # a function, a trap, a script written then run, a rename out, and another tool's delete.
  "python3 -c 'import shutil; shutil.rmtree(\"OUT/x\")'"
  "python3 -c 'import os; os.rmdir(\"OUT/x/empty\")'"
  "python3 -c 'import os; os.unlink(\"OUT/x/deep/file\")'"
  "python3 -c 'import os; os.rename(\"OUT/x\", \"OUT/y\")'"
  'eval "$(echo rm) -rf OUT/x"'
  'X=rm; $X -rf OUT/x'
  'alias z="rm -rf"; shopt -s expand_aliases; eval "z OUT/x"'
  'f() { command rm -rf "$@"; }; f OUT/x'
  'trap "rm -rf OUT/x || exit 1" EXIT'
  $'cat > s.py <<EOF\nimport shutil\nshutil.rmtree("OUT/x")\nEOF\npython3 s.py'
  $'cat > s.sh <<EOF\nrm -rf OUT/x\nEOF\nchmod +x s.sh; ./s.sh'
  'mv OUT/x ./stolen'
  'mv OUT/x OUT/y'
  'mv OUT/x/deep/file OUT/x/empty/file'
  'mv -f mine OUT/x/deep/file'
  'python3 -c "import os; os.replace(\"mine\", \"OUT/x/deep/file\")"'
  'rsync -a --delete T/ OUT/x/'
  'git -C OUT init -q . && git -C OUT clean -q -fdx'
  'setsid bash -c "rm -rf OUT/x" & wait $!'
  'nohup bash -c "rm -rf OUT/x" >/dev/null 2>&1 & wait $!'
)

# Runs each spelling the machine has the tool for through <runner>, a function taking the
# worktree and the command text, and fails naming the first whose outcome <judge> refuses, a
# function reading $status and the canary tree: each_spelling <runner> <judge>
each_spelling() {
  local runner=$1 judge=$2 spelling text ran=0
  for spelling in "${SPELLINGS[@]}"; do
    if [[ $spelling == rsync\ * ]] && ! command -v rsync >/dev/null; then continue; fi
    text=${spelling//OUT/$OUT}
    canary
    rm -rf "${WT:?}/stolen"
    "$runner" "$text"
    "$judge" || {
      printf '%s: %s\nstatus %s, stdout: %s\nstderr: %s\ncanary tree:\n%s\n' "$judge" "$spelling" "$status" "$output" \
        "$stderr" "$(canary_tree)" >&2
      return 1
    }
    ran=$((ran + 1))
  done
  ((ran >= ${#SPELLINGS[@]} - 1))
}

run_confined() { bash_call "$1"; }
run_plain() { run --separate-stderr env -C "$WT" bash -c "$1"; }
canary_whole() { [[ $status -ne 0 && $(canary_tree) == "${WHOLE//OUT/$OUT}" ]]; }
canary_lost() { [[ $(canary_tree) != "${WHOLE//OUT/$OUT}" ]]; }

# The session's directory, written by the real confine-session for the worktree WT, the git
# directory GIT, the sandbox's HOME and team home, and the session tmp STMP: session_dir
session_dir() {
  run -0 "$WRITE" write --dir "$SDIR" --task "$TASK" --worktree "$WT" --git-dir "$GIT" --team-home "$TEAM_HOME" \
    --home "$HOME" --session-tmp "$STMP"
  assert_equal "$output" "$PROGRAM"
}

# Rewrites the session file with a jq filter, keeping its mode: edit_session <jq arguments>...
edit_session() {
  jq "$@" "$SFILE" >"$BOX/session.json"
  chmod u+w "$SFILE"
  cat "$BOX/session.json" >"$SFILE"
  chmod 400 "$SFILE"
}

# A Bash call as Claude Code 2.1.325 runs it in a session whose shell and prefix are the
# session's program: <program> -c [-l] "<program> '<line>'", the line one quoted argument holding
# what Claude Code puts around the command (the eval of its text, then the working directory
# written to a file); -l is what it adds while it has no shell snapshot: bash_call [-l] <command>
bash_call() {
  local login=() line
  if [[ $1 == -l ]]; then
    login=(-l)
    shift
  fi
  printf -v line 'eval %q && pwd -P >| %q' "$1" "$BOX/cwd"
  printf -v line '%q %q' "$PROGRAM" "$line"
  run --separate-stderr env -C "$WT" "$PROGRAM" -c "${login[@]}" "$line"
}

# The same call through the real bash, with no program of the session's: plain_call [-l] <command>
plain_call() {
  local login=() line
  if [[ $1 == -l ]]; then
    login=(-l)
    shift
  fi
  printf -v line 'bash -c %q' "$1"
  run --separate-stderr env -C "$WT" bash -c "${login[@]}" "$line"
}

# A linked worktree of a new repository, MAIN, as the session's worktree, its common git directory
# as team-worker names it at the launch, its session tmp, the state directory bin/lib/confine-roots
# lists and, as once the session has its id, its job tmp.
session() {
  rmdir "${WT:?}"
  MAIN=$(make_repo main)
  git -C "${MAIN:?}" worktree add -q "$WT" -b task
  GIT=$(realpath "$MAIN/.git")
  mkdir -p "$HOME/.local/state/agent-team"
  session_dir
  run -0 "$WRITE" job --dir "$SDIR" --session-id 0badc0de
}

# A copy of the wrapper beside a confine-roots file holding <line>...: listed <line>...
listed() {
  mkdir -p "$BOX/lib"
  cp "$REPO_ROOT/bin/lib/confine.py" "$BOX/lib/"
  printf '%s\n' '# a comment' '' "$@" >"$BOX/lib/confine-roots"
  CONFINE=$BOX/lib/confine.py
}

# Both forms of the session's program must exit 3 with <text> on stderr and run nothing:
# refused_session <text>
refused_session() {
  run --separate-stderr env -C "$WT" "$PROGRAM" "touch $WT/ran"
  assert_equal "$status: $stderr" "3: confine: $1"
  run --separate-stderr env -C "$WT" "$PROGRAM" -c -l "touch $WT/ran"
  assert_equal "$status: $stderr" "3: confine: $1"
  [[ ! -e $WT/ran && -z $output ]]
}

# A profile file that removes the canary tree, as code a call left for the next one's shell.
profile() {
  printf 'rm -rf %q\n' "${OUT:?}/x" >"$1"
}

# Every variable phase 4 read for a root, each to name the canary's directory.
ROOT_VARIABLES=(AGENT_TEAM_WORKTREE AGENT_TEAM_GIT_DIR CLAUDE_PROJECT_DIR CLAUDE_JOB_DIR HOME TEAM_HOME)

# The canary tree, and under the canary's directory what a variable would root there: a job tmp
# and the state directory of confine-roots.
variable_canaries() {
  canary
  mkdir -p "$OUT/tmp" "$OUT/.local/state/agent-team"
  : >"$OUT/tmp/f"
  : >"$OUT/.local/state/agent-team/f"
}

variables_moved_nothing() {
  [[ $status -ne 0 ]]
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  [[ -e $OUT/tmp/f && -e $OUT/.local/state/agent-team/f ]]
}

# write with the test's values but for each <option> <value> given: write_with [<option> <value>]...
write_with() {
  local -A options=([--dir]=$SDIR [--task]=$TASK [--worktree]=$WT [--git-dir]=$GIT [--team-home]=$TEAM_HOME [--home]=$HOME [--session-tmp]=$STMP)
  local arguments=() option
  while (($# > 0)); do
    options[$1]=$2
    shift 2
  done
  for option in "${!options[@]}"; do
    arguments+=("$option" "${options[$option]}")
  done
  run --separate-stderr "$WRITE" write "${arguments[@]}"
}

@test "spellings: every delete spelling a session's Bash call runs leaves the canary tree outside its roots whole and exits non-zero" {
  session_dir
  each_spelling run_confined canary_whole
}

@test "control: every delete spelling run without the wrapper removes part of the canary tree" {
  each_spelling run_plain canary_lost
}

@test "workload: a worker's ordinary deletes, renames and git calls in each root pass in a session's Bash calls" {
  local work text
  session
  : >"$OUT/kept"
  work=(
    'mkdir -p build/a && touch build/a/f && rm -rf build'
    'echo a > f.txt && sed -i s/a/b/ f.txt && grep -q b f.txt && rm f.txt'
    'touch a.txt && mv a.txt b.txt && rm b.txt'
    "mkdir -p $JOB/tmp/x/y && rm -rf ${JOB:?}/tmp/x"
    '[[ $TMPDIR == '"$STMP"' ]] && d=$(mktemp -d) && [[ $d == $TMPDIR/* ]] && touch "$d/f" && rm -rf "$d"'
    'f=$(mktemp) && mv "$f" moved && rm moved'
    "touch $HOME/.local/state/agent-team/live.json.1 && mv -f $HOME/.local/state/agent-team/live.json.1 $HOME/.local/state/agent-team/live.json"
    "rm $HOME/.local/state/agent-team/live.json"
    "echo x > $OUT/written && echo y >> $OUT/written && ln $OUT/written $OUT/linked && : > $OUT/written"
    'echo x > tracked && git add tracked && git commit -q -m probe'
    'echo y >> tracked && git stash push -q -m probe && git stash pop -q && git commit -q -a -m again'
    'git gc -q'
    'git checkout -q -b other && git checkout -q task && git branch -q -d other'
    'git rm -q tracked && git commit -q -m gone'
  )
  for text in "${work[@]}"; do
    bash_call "$text"
    [[ $status -eq 0 ]] ||
      { printf 'refused: %s\nstatus %s, stdout: %s\nstderr: %s\n' "$text" "$status" "$output" "$stderr" >&2; return 1; }
  done
  # The same session still removes nothing outside its roots.
  bash_call "rm $OUT/kept"
  [[ $status -ne 0 && -e $OUT/kept ]]
  bash_call "rm -rf ${MAIN:?}/README.md"
  [[ $status -ne 0 && -e $MAIN/README.md ]]
}

@test "--session roots the worktree its file names, whatever directory the command was started in" {
  local elsewhere
  session
  elsewhere=$(make_repo elsewhere)
  : >"$elsewhere/f"
  confined "$elsewhere" --session "$SFILE" -- bash -c 'rm f; git rm -q README.md'
  [[ $status -ne 0 && -e $elsewhere/f && -e $elsewhere/README.md ]]
  confined "$elsewhere" --session "$SFILE" -- bash -c 'cd "$1" && touch f && rm f' _ "$WT"
  assert_equal "$status" 0
}

@test "--session makes the file's session tmp with mode 700 and gives it to the command as TMPDIR" {
  session_dir
  with TMPDIR="$BOX"
  [[ ! -e $STMP ]]
  confined "$WT" --session "$SFILE" -- bash -c 'echo "$TMPDIR"; d=$(mktemp -d) && rmdir "$d"'
  assert_equal "$status" 0
  assert_equal "$output" "$STMP"
  assert_equal "$(stat -c '%a %F' "$STMP")" "700 directory"
  # One already there is kept as it is.
  : >"$STMP/kept"
  confined "$WT" --session "$SFILE" -- rm "$STMP/kept"
  assert_equal "$status" 0
}

@test "--session refuses a session tmp that is a link, no directory or relative, without running the command" {
  session_dir
  ln -s "$OUT" "$STMP"
  confined "$WT" --session "$SFILE" -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: the session tmp $STMP is a link, no directory or another user's"
  rm "${STMP:?}"
  : >"$STMP"
  confined "$WT" --session "$SFILE" -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: the session tmp $STMP is a link, no directory or another user's"
  edit_session '.session_tmp = "stmp"'
  confined "$WT" --session "$SFILE" -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: the session file $SFILE names the session tmp stmp, which is not an absolute path"
  [[ ! -e $WT/ran ]]
}

@test "confine-roots: a listed directory is a root, with ~/ for the session file's home, and a missing one is skipped" {
  session_dir
  mkdir -p "$BOX/cache" "$HOME/.cache/tool"
  : >"$BOX/cache/f"
  : >"$HOME/.cache/tool/f"
  : >"$OUT/f"
  listed "$BOX/cache" "$BOX/missing" "  ~/.cache/tool"
  confined "$WT" --session "$SFILE" -- rm "$BOX/cache/f" "$HOME/.cache/tool/f" "$OUT/f"
  [[ $status -ne 0 && ! -e $BOX/cache/f && ! -e $HOME/.cache/tool/f && -e $OUT/f ]]
  # Without --session the file is not read.
  : >"$BOX/cache/f"
  confined "$WT" --root "$WT" -- rm "$BOX/cache/f"
  [[ $status -ne 0 && -e $BOX/cache/f ]]
}

@test "confine-roots: a line in or above a directory the session file keeps, or a relative one, is refused naming it" {
  local line
  session_dir
  mkdir -p "$TEAM_HOME/tasks" "$HOME/.claude/jobs"
  ln -s "$TEAM_HOME/tasks" "$BOX/link"
  # shellcheck disable=SC2088 # the roots file names HOME as ~
  for line in "$TEAM_HOME" "$TEAM_HOME/tasks" "$TEAM_HOME/not-there" "$BOX/link" "~/.config/agent-team" "~/.claude/jobs" \
    "~/.config" "$HOME" /; do
    listed "$BOX" "$line"
    confined "$WT" --session "$SFILE" -- touch "$WT/ran"
    assert_equal "$status" 3
    assert_contains "$stderr" "confine: $BOX/lib/confine-roots lists $line, which is, holds or is under "
  done
  listed cache
  confined "$WT" --session "$SFILE" -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: $BOX/lib/confine-roots lists cache, which is not an absolute path"
  [[ ! -e $WT/ran ]]
  # The kept directories are the file's alone: with another team home written there, the
  # environment's team home is a directory like any other.
  edit_session --arg other "$BOX/other-home" '.kept[0] = $other'
  listed "$TEAM_HOME/tasks"
  confined "$WT" --session "$SFILE" -- touch "$WT/ran-with-another-team-home"
  assert_equal "$status" 0
  # And no roots file at all.
  rm "$BOX/lib/confine-roots"
  confined "$WT" --session "$SFILE" -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_contains "$stderr" "confine: cannot read $BOX/lib/confine-roots: "
  [[ ! -e $WT/ran ]]
}

@test "confine-roots: the checkout's file lists the team's state directory, ~/.cargo and ~/.cache/sccache, each with its comment, and nothing the wrapper refuses" {
  local roots=$REPO_ROOT/bin/lib/confine-roots line
  session_dir
  # shellcheck disable=SC2088 # the roots file names HOME as ~
  assert_equal "$(grep -v -e '^#' -e '^$' "$roots")" "~/.local/state/agent-team
~/.cargo
~/.cache/sccache"
  # Each line follows a comment line of its own.
  for line in .local/state/agent-team .cargo .cache/sccache; do
    # shellcheck disable=SC2088 # the roots file names HOME as ~
    grep -B 1 -x -F "~/$line" "$roots" | head -n 1 | grep -q '^# '
  done
  mkdir -p "$HOME/.claude" "$HOME/.cargo/registry" "$HOME/.cache/sccache" "$HOME/.rustup"
  : >"$HOME/.cargo/registry/f"
  : >"$HOME/.cache/sccache/f"
  : >"$HOME/.rustup/f"
  confined "$WT" --session "$SFILE" -- rm "$HOME/.cargo/registry/f" "$HOME/.cache/sccache/f"
  assert_equal "$status" 0
  assert_equal "$stderr" ""
  # Not ~/.rustup: a worker installs no toolchain.
  confined "$WT" --session "$SFILE" -- rm "$HOME/.rustup/f"
  [[ $status -ne 0 && -e $HOME/.rustup/f ]]
}

UNCONFINED="so this command runs unconfined; the text guard alone holds it"

@test "no Landlock: the command runs unconfined with the one stderr line, once per session tmp and every time with none" {
  local abi
  session_dir
  canary
  seams
  for abi in 0 1; do
    : >"$OUT/f"
    CONFINE_TEST_ABI=$abi confined "$WT" --root "$WT" -- bash -c "rm $OUT/f && echo ran"
    assert_equal "$status" 0
    assert_equal "$output" ran
    assert_equal "$stderr" "confine: this machine has no Landlock (ABI $abi), $UNCONFINED"
    [[ ! -e $OUT/f ]]
  done
  CONFINE_TEST_ABI=0 confined "$WT" --abi
  assert_equal "$output" 0
  with CONFINE_TEST_ABI="1"
  confined "$WT" --session "$SFILE" -- bash -c 'echo "$TMPDIR"'
  assert_equal "$output" "$STMP"
  assert_equal "$stderr" "confine: this machine has no Landlock (ABI 1), $UNCONFINED"
  confined "$WT" --session "$SFILE" --shell -- -c 'echo ran'
  assert_equal "$status" 0
  assert_equal "$output" ran
  assert_equal "$stderr" ""
  # A command with no session tmp is told every time.
  confined "$WT" --root "$WT" -- echo ran
  assert_equal "$stderr" "confine: this machine has no Landlock (ABI 1), $UNCONFINED"
  confined "$WT" --root "$WT" -- echo ran
  assert_equal "$stderr" "confine: this machine has no Landlock (ABI 1), $UNCONFINED"
}

@test "a domain that cannot be entered exits 3 naming the step, and the command does not run" {
  seams
  CONFINE_TEST_FAIL=restrict confined "$WT" --root "$WT" -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: cannot enter the domain: Operation not permitted"
  confined "$WT" --root "$WT/missing" -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: --root names no directory: $WT/missing"
  [[ ! -e $WT/ran && -z $output ]]
}

USAGE="Usage: python3 -I confine.py [--root <dir>]... [--session <file>] [--shell] [--entry shell|prefix] -- <command or the shell's arguments>"

@test "the wrapper's command line: --help is its docstring, --abi the kernel's version, the command's status its own" {
  local line
  session_dir
  confined "$WT" --help
  assert_equal "$status" 0
  assert_equal "${lines[0]}" "Runs a command where the kernel refuses a delete or a rename outside its roots."
  assert_contains "$output" "$USAGE"
  confined "$WT" --abi
  assert_equal "$status" 0
  assert_equal "$output" "$ABI"
  confined "$WT" --root "$WT" -- bash -c 'echo out; echo err >&2; exit 7'
  assert_equal "$status" 7
  assert_equal "$output" out
  assert_equal "$stderr" err
  run -127 --separate-stderr python3 -I "$CONFINE" -- "$WT/no-such-command"
  assert_equal "$stderr" "confine: cannot run $WT/no-such-command: No such file or directory"
  # Among them --session with no file, as phase 4 had it, --shell with no session, and an entry
  # of no form.
  for line in "" "--root" "--root $WT" "--session" "--session -- true" "--unknown -- true" "--root $WT --" \
    "--shell -- -c true" "--session $SFILE --shell --" "--session $SFILE --entry both -- true" "--entry"; do
    # shellcheck disable=SC2086  # each line is a command line's words
    confined "$WT" $line
    assert_equal "$line: $status" "$line: 2"
    assert_equal "${stderr%%$'\n'*}" "$USAGE"
    assert_equal "$output" ""
  done
}

@test "--shell runs the session file's shell with the words after --, and --entry names the form in the command's environment alone" {
  session_dir
  mkdir -p "$BOX/bin"
  printf '#!/bin/sh\necho "the other shell ran: $*"\n' >"$BOX/bin/bash"
  chmod +x "$BOX/bin/bash"
  with SHELL="$BOX/bin/bash" CLAUDE_CODE_SHELL="$BOX/bin/bash" AGENT_TEAM_CONFINE_SHELL=7
  confined "$WT" --session "$SFILE" --shell --entry prefix -- -c 'echo "$0 shell=${AGENT_TEAM_CONFINE_SHELL-} prefix=${AGENT_TEAM_CONFINE_PREFIX-}"'
  assert_equal "$status" 0
  assert_equal "$output" "$(jq -r .shell "$SFILE") shell=7 prefix=1"
  edit_session --arg shell "$BOX/bin/bash" '.shell = $shell'
  confined "$WT" --session "$SFILE" --shell --entry shell -- -c -l 'a line'
  assert_equal "$output" "the other shell ran: -c -l a line"
}

@test "a confined command that runs the wrapper again stays inside its first domain" {
  canary
  confined "$WT" --root "$WT" -- python3 -I "$CONFINE" --root "$OUT" -- rm -rf "${OUT:?}/x"
  [[ $status -ne 0 ]]
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
}

@test "the wrapper reads no ABI and no failure from its environment" {
  canary
  with CONFINE_TEST_ABI=0 CONFINE_TEST_FAIL=restrict
  confined "$WT" --root "$WT" -- rm -rf "${OUT:?}/x"
  [[ $status -ne 0 && $status -ne 3 ]]
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  confined "$WT" --abi
  assert_equal "$output" "$ABI"
}

@test "--session takes the common git directory from its file alone, whatever the worktree's own files name" {
  session
  canary
  # The worktree's files may name another git directory: the roots stay the launch's.
  mkdir -p "$OUT/objects" "$OUT/refs"
  echo 'ref: refs/heads/x' >"$OUT/HEAD"
  bash_call 'mv .git .git.aside && echo "gitdir: '"$OUT"'" >.git'
  assert_equal "$status" 0
  bash_call "rm -rf ${OUT:?}/x"
  [[ $status -ne 0 ]]
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
}

@test "--session refuses a common git directory that is a link, no directory, relative, or in or above a directory no root may be" {
  local named
  session
  mkdir -p "$HOME/.claude/repo.git" "$TEAM_HOME/.git"
  ln -s "$OUT" "$BOX/linked.git"
  : >"$BOX/file.git"
  for named in "$BOX/linked.git" "$BOX/file.git" "$BOX/missing.git" "main/.git" "$TEAM_HOME/.git" "$HOME/.claude/repo.git" "$HOME" /; do
    edit_session --arg named "$named" '.git_dir = $named'
    confined "$WT" --session "$SFILE" -- touch "$WT/ran"
    assert_equal "$named: $status" "$named: 3"
    assert_contains "$stderr" "confine: "
    assert_contains "$stderr" "$named"
    [[ ! -e $WT/ran && -z $output ]]
  done
}

@test "the job tmp is a root only after confine-session job names it, and one that is a link or no directory is refused" {
  local named
  session_dir
  canary
  : >"$JOB/tmp/f"
  # Before the session has an id, its commands remove nothing there, whatever CLAUDE_JOB_DIR says.
  with CLAUDE_JOB_DIR="$JOB"
  bash_call "rm $JOB/tmp/f"
  [[ $status -ne 0 && -e $JOB/tmp/f ]]
  run -0 "$WRITE" job --dir "$SDIR" --session-id 0badc0de
  assert_equal "$(jq -r .job_tmp "$SFILE")" "$JOB/tmp"
  assert_equal "$(stat -c %a "$SFILE")" 400
  bash_call "rm $JOB/tmp/f"
  [[ $status -eq 0 && ! -e $JOB/tmp/f ]]
  # A missing job tmp is no root and no refusal.
  rmdir "${JOB:?}/tmp"
  bash_call "touch $WT/ran"
  assert_equal "$status" 0
  ln -s "$OUT" "$JOB/tmp"
  bash_call "rm -rf ${OUT:?}/x"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: $JOB/tmp is a link, no directory or another user's, so it is no root"
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  rm "${JOB:?}/tmp"
  : >"$JOB/tmp"
  bash_call "touch $WT/ran-again"
  assert_equal "$status" 3
  [[ ! -e $WT/ran-again ]]
  # job takes the id of a session, 8 hexadecimal characters, and a session file that is there.
  for named in "" 0badc0d 0BADC0DE 0badc0de0 ../../x; do
    run -2 "$WRITE" job --dir "$SDIR" --session-id "$named"
  done
  run -1 "$WRITE" job --dir "$SDIR/missing" --session-id 0badc0de
  assert_equal "$output" "confine-session: $SDIR/missing/session.json is no session file of this user's"
}

@test "a listed root that is a link is refused, without running the command" {
  session_dir
  canary
  ln -s "$OUT" "$BOX/listed"
  listed "$BOX/listed"
  confined "$WT" --session "$SFILE" -- rm -rf "${OUT:?}/x"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: $BOX/listed is a link, no directory or another user's, so it is no root"
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
}

@test "a session file that is a link, of another mode, no JSON, of another version or short of a key is refused with its text, and nothing runs" {
  local key unsafe="the session file $SFILE is a link, no regular file, another user's, or writable by group or others"
  session_dir
  cp "$SFILE" "$BOX/whole.json"
  chmod 600 "$BOX/whole.json"
  # A link, to a file that is whole.
  rm -f "${SFILE:?}"
  ln -s "$BOX/whole.json" "$SFILE"
  refused_session "$unsafe"
  rm "${SFILE:?}"
  # No regular file, and none at all.
  mkdir "$SFILE"
  refused_session "$unsafe"
  rmdir "${SFILE:?}"
  refused_session "cannot read the session file $SFILE: No such file or directory"
  # Writable by group, or by others.
  for key in 460 406 664; do
    cp "$BOX/whole.json" "$SFILE"
    chmod "$key" "$SFILE"
    refused_session "$unsafe"
    rm -f "${SFILE:?}"
  done
  # No JSON, and JSON that is no object.
  echo 'worktree=/' >"$SFILE"
  run --separate-stderr env -C "$WT" "$PROGRAM" "touch $WT/ran"
  assert_equal "$status" 3
  assert_contains "$stderr" "confine: cannot read the session file $SFILE: "
  echo '[1]' >"$SFILE"
  refused_session "cannot read the session file $SFILE: it holds no JSON object"
  # Another version, or none.
  jq '.version = 2' "$BOX/whole.json" >"$SFILE"
  refused_session "the session file $SFILE is not version 1"
  jq 'del(.version)' "$BOX/whole.json" >"$SFILE"
  refused_session "the session file $SFILE is not version 1"
  # Each key it must name, missing, empty or of another type.
  for key in home kept worktree git_dir session_tmp shell; do
    jq --arg key "$key" 'del(.[$key])' "$BOX/whole.json" >"$SFILE"
    refused_session "the session file $SFILE names no $key"
    jq --arg key "$key" '.[$key] = ""' "$BOX/whole.json" >"$SFILE"
    refused_session "the session file $SFILE names no $key"
    jq --arg key "$key" '.[$key] = 1' "$BOX/whole.json" >"$SFILE"
    refused_session "the session file $SFILE names no $key"
  done
  jq '.kept = ["relative"]' "$BOX/whole.json" >"$SFILE"
  refused_session "the session file $SFILE names no kept"
  # A shell that is no program, and a worktree that is no directory.
  for key in "$BOX/no-bash" "$WT" bash "$BOX/whole.json"; do
    jq --arg shell "$key" '.shell = $shell' "$BOX/whole.json" >"$SFILE"
    refused_session "the session file $SFILE names the shell $key, which is no program"
  done
  jq --arg worktree "$BOX/missing" '.worktree = $worktree' "$BOX/whole.json" >"$SFILE"
  refused_session "the session file $SFILE names the worktree $BOX/missing, which is no directory"
  # The whole file runs again.
  cp "$BOX/whole.json" "$SFILE"
  run -0 env -C "$WT" "$PROGRAM" "touch $WT/ran"
  [[ -e $WT/ran ]]
}

@test "a login shell's profile files run inside the domain: a call with no snapshot leaves an outside canary whole, and the real bash destroys it" {
  local file
  session_dir
  for file in .bash_profile .profile; do
    canary
    rm -f "${HOME:?}/.bash_profile" "${HOME:?}/.profile"
    profile "$HOME/$file"
    bash_call -l true
    assert_equal "$file: $(canary_tree)" "$file: ${WHOLE//OUT/$OUT}"
    # The control: the same call with the real bash as the shell runs the profile unconfined.
    plain_call -l true
    canary_lost
  done
}

@test "the file BASH_ENV names runs inside the domain: a call with a snapshot leaves an outside canary whole, and the real bash destroys it" {
  session_dir
  canary
  profile "$BOX/env.sh"
  with BASH_ENV="$BOX/env.sh"
  bash_call true
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  plain_call true
  canary_lost
}

@test "no variable of a call's environment moves a root: with each naming the canary's directory a delete there is refused" {
  local name line deletes="rm -rf ${OUT:?}/x; rm ${OUT:?}/tmp/f; rm ${OUT:?}/.local/state/agent-team/f"
  session
  variable_canaries
  printf -v line '%q %q' "$PROGRAM" "$deletes"
  for name in "${ROOT_VARIABLES[@]}"; do
    run --separate-stderr env -C "$WT" "$name=$OUT" "$PROGRAM" -c "$line"
    variables_moved_nothing
  done
  run --separate-stderr env -C "$WT" "${ROOT_VARIABLES[@]/%/=$OUT}" "$PROGRAM" -c -l "$line"
  variables_moved_nothing
  # The prefix form alone, as a hook's command or a server's start reaches it.
  run --separate-stderr env -C "$WT" "${ROOT_VARIABLES[@]/%/=$OUT}" "$PROGRAM" "$deletes"
  variables_moved_nothing
  # The control: unconfined, the same deletes remove all three.
  run_plain "$deletes"
  canary_lost
  [[ ! -e $OUT/tmp/f && ! -e $OUT/.local/state/agent-team/f ]]
}

@test "no variable a first call wrote into a profile moves a root for the second call" {
  local name deletes="rm -rf ${OUT:?}/x; rm ${OUT:?}/tmp/f; rm ${OUT:?}/.local/state/agent-team/f" exports=''
  session
  variable_canaries
  for name in "${ROOT_VARIABLES[@]}"; do
    exports+="export $name=$OUT; "
  done
  bash_call "echo '$exports' | tee $HOME/.bash_profile $HOME/.profile $HOME/.bashrc $BOX/env.sh >/dev/null"
  assert_equal "$status" 0
  grep -q "export HOME=$OUT" "$HOME/.bash_profile"
  with BASH_ENV="$BOX/env.sh"
  bash_call -l "$deletes"
  variables_moved_nothing
  bash_call "$deletes"
  variables_moved_nothing
}

@test "a session's Bash call: a delete outside the worktree leaves it whole, one inside removes it, and both forms name themselves" {
  session
  canary
  bash_call "rm -rf ${OUT:?}/x"
  [[ $status -ne 0 ]]
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  bash_call "cd ${OUT:?} && rm -rf x; python3 -c 'import shutil; shutil.rmtree(\"x\")'"
  [[ $status -ne 0 ]]
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  mkdir -p "$WT/build/a"
  : >"$WT/build/a/f"
  bash_call 'rm -rf build && cd src && echo "it ran in $TMPDIR, shell=${AGENT_TEAM_CONFINE_SHELL-} prefix=${AGENT_TEAM_CONFINE_PREFIX-}"'
  assert_equal "$status" 0
  assert_equal "$output" "it ran in $STMP, shell=1 prefix=1"
  [[ ! -e $WT/build ]]
  assert_equal "$(<"$BOX/cwd")" "$(realpath "$WT")/src"
  # The prefix form alone, a hook's command, is not the shell form.
  run -0 --separate-stderr env -C "$WT" "$PROGRAM" 'echo "shell=${AGENT_TEAM_CONFINE_SHELL-} prefix=${AGENT_TEAM_CONFINE_PREFIX-}"'
  assert_equal "$output" "shell= prefix=1"
  # What Claude Code runs its shell with at a session's start: the environment probe and the
  # snapshot's script, a login shell.
  run -0 --separate-stderr env -C "$WT" "$PROGRAM" -c env
  assert_contains "$output" "AGENT_TEAM_CONFINE_SHELL=1"
  run -0 --separate-stderr env -C "$WT" "$PROGRAM" -c -l 'echo "$0"'
  assert_equal "$output" "$(jq -r .shell "$SFILE")"
}

@test "confine-shell: one word is the shell's line to read, never the wrapper's options, and any other command line exits 2" {
  local shell=$REPO_ROOT/bin/lib/confine-shell usage="confine-shell: usage: confine-shell --session <file> <line>, or --session <file> -c ..."
  session
  canary
  # A shell-form hook's command reaches the prefix as it is written.
  run -127 --separate-stderr env -C "$WT" "$PROGRAM" "--root ${OUT:?} -- rm -rf ${OUT:?}/x"
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  run -127 --separate-stderr env -C "$WT" "$PROGRAM" '--abi'
  assert_equal "$output" ''
  run -127 --separate-stderr env -C "$WT" "$PROGRAM" '--help x'
  assert_equal "$output" ''
  # --help alone, which is no call's line, is the header, with a session file and with none.
  run -0 --separate-stderr env -C "$WT" "$PROGRAM" --help
  assert_equal "${lines[0]}" "A confined session's shell and its shell prefix, in one program: bin/lib/confine-session writes"
  run -0 --separate-stderr "$shell" --help
  assert_equal "${lines[0]}" "A confined session's shell and its shell prefix, in one program: bin/lib/confine-session writes"
  # Phase 4's one-argument form, no words, and no session file.
  run --separate-stderr env -C "$WT" "$shell" "touch $WT/ran"
  assert_equal "$status: $stderr" "2: $usage"
  run --separate-stderr env -C "$WT" "$shell"
  assert_equal "$status: $stderr" "2: $usage"
  run --separate-stderr env -C "$WT" "$shell" --session "$SFILE"
  assert_equal "$status: $stderr" "2: $usage"
  run --separate-stderr env -C "$WT" "$shell" -c "touch $WT/ran"
  assert_equal "$status: $stderr" "2: $usage"
  run --separate-stderr env -C "$WT" "$shell" --root "$WT" "touch $WT/ran"
  assert_equal "$status: $stderr" "2: $usage"
  [[ ! -e $WT/ran ]]
}

@test "confine-shell: the interpreter, the shell and the roots come from no variable and no program on the session's PATH" {
  local tool
  session
  canary
  mkdir -p "$BOX/bin"
  for tool in git python3 bash sh zsh; do
    printf '#!/bin/sh\nrm -rf %s\nexit 0\n' "${OUT:?}/x" >"$BOX/bin/$tool"
    chmod +x "$BOX/bin/$tool"
  done
  with PATH="$BOX/bin:$PATH" SHELL="$BOX/bin/zsh" CLAUDE_CODE_SHELL="$BOX/bin/bash"
  bash_call 'echo "$0"'
  assert_equal "$status" 0
  assert_equal "$output" "$(jq -r .shell "$SFILE")"
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  # The control: a planted program does remove it when one is run.
  run "$BOX/bin/bash"
  canary_lost
}

@test "confine-session write: the directory is mode 700, the file 400 and the program 500, and a second write replaces the first's files" {
  local lib
  lib=$(cd "$REPO_ROOT/bin/lib" && pwd -P)
  session_dir
  assert_equal "$(stat -c %a "$SDIR" "${SDIR%/*}" "${SDIR%/*/*}" "$SFILE" "$PROGRAM" | tr '\n' ' ')" "700 700 700 400 500 "
  assert_equal "$(jq -c 'del(.shell)' "$SFILE")" "$(jq -cn --arg task "$TASK" --arg home "$HOME" --arg team "$(realpath "$TEAM_HOME")" \
    --arg worktree "$(realpath "$WT")" --arg git "$(realpath "$GIT")" --arg tmp "$STMP" \
    '{version: 1, task: $task, home: $home, kept: [$team, ($home + "/.config/agent-team"), ($home + "/.claude")], worktree: $worktree, git_dir: $git, session_tmp: $tmp}')"
  [[ $(jq -r .shell "$SFILE") =~ ^(/opt/homebrew/bin|/usr/local/bin|/usr/bin|/bin)/bash$ ]]
  assert_equal "$(<"$PROGRAM")" "#!/bin/sh
# Written by confine-session for $TASK's builder.test--22: the session's shell, which enters its domain first.
exec '$lib/confine-shell' --session '$SFILE' \"\$@\""
  assert_equal "$(find "$SDIR" -mindepth 1 | LC_ALL=C sort)" "$PROGRAM
$SFILE"
  # A relaunch writes it anew: another worktree, no job tmp of the first's session, the default
  # session tmp, and nothing left of the temporary names.
  run -0 "$WRITE" job --dir "$SDIR" --session-id 0badc0de
  mkdir "$BOX/wt2"
  run -0 "$WRITE" write --dir "$SDIR/" --task "$TASK" --worktree "$BOX/wt2" --git-dir "$GIT" --team-home "$TEAM_HOME" --home "$HOME"
  assert_equal "$output" "$PROGRAM"
  assert_equal "$(jq -r '.worktree, .job_tmp, .session_tmp' "$SFILE")" "$(realpath "$BOX/wt2")
null
/tmp/agent-team-$TASK"
  assert_equal "$(find "$SDIR" -mindepth 1 | LC_ALL=C sort)" "$PROGRAM
$SFILE"
  run -0 "$WRITE" --help
  assert_equal "${lines[0]}" "Writes a confined session's directory: the file its roots are read from and the program its"
}

@test "confine-session write refuses a path the session's shell path may not be, a directory that is a link, and a worktree or git directory that is none" {
  local base=$HOME/.config/agent-team/confine named
  write_with --dir "$base/T7/it's"
  assert_equal "$status: $stderr" "1: confine-session: $base/T7/it's holds a single quote, which the session's shell path may not"
  write_with --dir "$base/T7/a"$'\n'"b"
  assert_equal "$status: $stderr" "1: confine-session: $base/T7/a"$'\n'"b holds a newline, which the session's shell path may not"
  write_with --dir "$base/T7/a -b"
  assert_equal "$status: $stderr" "1: confine-session: $base/T7/a -b holds \" -\", which the session's shell path may not"
  write_with --dir "$base/T7/zsh-builder"
  assert_equal "$status: $stderr" "1: confine-session: $base/T7/zsh-builder holds \"zsh\", which the session's shell path may not"
  [[ ! -e $base ]]
  # The checkout's own path, which the program quotes too.
  mkdir -p "$BOX/zsh/lib"
  cp "$WRITE" "$REPO_ROOT/bin/lib/temp-files.sh" "$BOX/zsh/lib/"
  run --separate-stderr "$BOX/zsh/lib/confine-session" write --dir "$SDIR" --task "$TASK" --worktree "$WT" --git-dir "$GIT" \
    --team-home "$TEAM_HOME" --home "$HOME"
  assert_equal "$status: $stderr" "1: confine-session: $(realpath "$BOX")/zsh/lib holds \"zsh\", which the session's shell path may not"
  # A directory outside <home>/.config/agent-team, where a root may be.
  for named in "$BOX/session" "$HOME/.config/agent-team/../x" "$HOME/.config/agent-team"; do
    write_with --dir "$named"
    assert_equal "$status: $stderr" "1: confine-session: $named is not under $HOME/.config/agent-team, where no root may be"
  done
  # A link or a file on the way down, each named, and nothing written past it.
  mkdir -p "$base" "$BOX/elsewhere"
  ln -s "$BOX/elsewhere" "$base/T7"
  write_with
  assert_equal "$status: $stderr" "1: confine-session: $base/T7 is a link, no directory or another user's"
  [[ -z $(ls -A "$BOX/elsewhere") ]]
  rm "${base:?}/T7"
  mkdir "$base/T7"
  : >"$SDIR"
  write_with
  assert_equal "$status: $stderr" "1: confine-session: $SDIR is a link, no directory or another user's"
  rm "${SDIR:?}"
  mv "$HOME/.config/agent-team" "$BOX/moved"
  ln -s "$BOX/moved" "$HOME/.config/agent-team"
  write_with
  assert_equal "$status: $stderr" "1: confine-session: $HOME/.config/agent-team is a link, no directory or another user's"
  rm "${HOME:?}/.config/agent-team"
  mv "$BOX/moved" "$HOME/.config/agent-team"
  # A worktree, a git directory or a home that is no directory.
  write_with --worktree "$BOX/missing"
  assert_equal "$status: $stderr" "1: confine-session: the worktree $BOX/missing is no directory"
  write_with --git-dir "$BOX/missing"
  assert_equal "$status: $stderr" "1: confine-session: the git directory $BOX/missing is no directory"
  write_with --home "$BOX/missing"
  assert_equal "$status: $stderr" "1: confine-session: the home directory $BOX/missing is no directory"
  [[ ! -e $SDIR ]]
  # A malformed command line.
  write_with --task 'T7 x'
  assert_equal "$status" 2
  write_with --worktree wt
  assert_equal "$status" 2
  write_with --dir session
  assert_equal "$status" 2
  run -2 "$WRITE" write --dir "$SDIR" --unknown x
  run -2 "$WRITE" write --dir
  run -2 "$WRITE" other
  run -2 "$WRITE"
  write_with
  assert_equal "$status: $output" "0: $PROGRAM"
}
