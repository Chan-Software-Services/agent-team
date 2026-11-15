#!/usr/bin/env bats
# lib/confine.py: the kernel layer, a wrapper that enters a Landlock domain and then runs its
# command, so removing or renaming a directory entry succeeds only under its roots. Tested by
# outcome: each case runs the real wrapper in a sandbox worktree with a canary tree outside its
# roots and asserts what survived, never what was parsed. A control runs each spelling without
# the wrapper and must destroy the canary, so the test can fail.
# Every case skips, naming the ABI, where the kernel's Landlock ABI is below 2 (no Landlock,
# ABI 1, macOS). The session tmp is under the machine's /tmp, as the wrapper fixes it, so each
# test's is named for a task number and a session id no session has, and removed in teardown.
# lib/confine-shell, the prefix a confined worker's Claude Code runs its shell commands through,
# is driven as Claude Code calls it, with the command line as one argument.

load helpers/common

setup() {
  sandbox
  unset AGENT_TEAM_WORKTREE AGENT_TEAM_GIT_DIR CLAUDE_JOB_DIR CONFINE_TEST_ABI CONFINE_TEST_FAIL CONFINE_REAL
  CONFINE=$REPO_ROOT/bin/lib/confine.py
  ABI=$(python3 -I "$CONFINE" --abi)
  ((ABI >= 2)) || skip "this machine's Landlock ABI is $ABI, and the file rules need 2"
  BOX=$BATS_TEST_TMPDIR/box
  WT=$BOX/wt OUT=$BOX/out JOB=$BOX/job
  TASK=T$((7000000000 + $$ * 1000 + BATS_TEST_NUMBER))
  printf -v SESSION 'g%07d-0000-test' $((($$ * 100 + BATS_TEST_NUMBER) % 10000000))
  TASK_TMP=/tmp/agent-team-$TASK GATE_TMP=/tmp/agent-team-gate-${SESSION:0:8}
  mkdir -p "$WT" "$OUT" "$JOB/tmp"
}

teardown() {
  [[ -z ${TASK_TMP-} ]] || rm -rf "${TASK_TMP:?}" "${GATE_TMP:?}"
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

run_confined() { confined "$WT" --root "$WT" -- bash -c "$1"; }
run_plain() { run --separate-stderr env -C "$WT" bash -c "$1"; }
canary_whole() { [[ $status -ne 0 && $(canary_tree) == "${WHOLE//OUT/$OUT}" ]]; }
canary_lost() { [[ $(canary_tree) != "${WHOLE//OUT/$OUT}" ]]; }

@test "spellings: every delete spelling run under the wrapper leaves the canary tree outside its roots whole and exits non-zero" {
  each_spelling run_confined canary_whole
}

@test "control: every delete spelling run without the wrapper removes part of the canary tree" {
  each_spelling run_plain canary_lost
}

# A linked worktree of a new repository, MAIN, as the session's worktree, its common git directory
# as team-worker names it at the launch, its job tmp, its session tmp and the state directory
# bin/lib/confine-roots lists, with the session's variables exported.
session() {
  rmdir "$WT"
  MAIN=$(make_repo main)
  git -C "${MAIN:?}" worktree add -q "$WT" -b task
  mkdir -p "$HOME/.local/state/agent-team"
  with AGENT_TEAM_WORKTREE="$WT" AGENT_TEAM_GIT_DIR="$(realpath "$MAIN/.git")" CLAUDE_JOB_DIR="$JOB" AGENT_TEAM_TASK="$TASK"
}

@test "workload: a worker's ordinary deletes, renames and git calls in each root pass under --session" {
  local work text
  session
  : >"$OUT/kept"
  work=(
    'mkdir -p build/a && touch build/a/f && rm -rf build'
    'echo a > f.txt && sed -i s/a/b/ f.txt && grep -q b f.txt && rm f.txt'
    'touch a.txt && mv a.txt b.txt && rm b.txt'
    "mkdir -p $JOB/tmp/x/y && rm -rf $JOB/tmp/x"
    '[[ $TMPDIR == '"$TASK_TMP"' ]] && d=$(mktemp -d) && [[ $d == $TMPDIR/* ]] && touch "$d/f" && rm -rf "$d"'
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
    confined "$WT" --session -- bash -c "$text"
    [[ $status -eq 0 ]] ||
      { printf 'refused: %s\nstatus %s, stdout: %s\nstderr: %s\n' "$text" "$status" "$output" "$stderr" >&2; return 1; }
  done
  # The same session still removes nothing outside its roots.
  confined "$WT" --session -- rm "$OUT/kept"
  [[ $status -ne 0 && -e $OUT/kept ]]
  confined "$WT" --session -- rm -rf "${MAIN:?}/README.md"
  [[ $status -ne 0 && -e $MAIN/README.md ]]
}

@test "--session roots the worktree AGENT_TEAM_WORKTREE names, and not the directory CLAUDE_PROJECT_DIR names beside it" {
  mkdir -p "$BOX/project"
  : >"$WT/f"
  : >"$BOX/project/f"
  with AGENT_TEAM_WORKTREE="$WT" CLAUDE_PROJECT_DIR="$BOX/project"
  confined "$BOX" --session -- rm "$WT/f" "$BOX/project/f"
  [[ $status -ne 0 && ! -e $WT/f && -e $BOX/project/f ]]
}

@test "--session roots the directory CLAUDE_PROJECT_DIR names when AGENT_TEAM_WORKTREE names none" {
  : >"$WT/f"
  : >"$WT/g"
  : >"$OUT/f"
  with CLAUDE_PROJECT_DIR="$WT"
  confined "$BOX" --session -- rm "$WT/f" "$OUT/f"
  [[ $status -ne 0 && ! -e $WT/f && -e $OUT/f ]]
  with AGENT_TEAM_WORKTREE="$BOX/missing"
  confined "$BOX" --session -- rm "$WT/g"
  [[ $status -eq 0 && ! -e $WT/g ]]
}

@test "--session roots nothing in another repository the command was started in" {
  local elsewhere
  session
  elsewhere=$(make_repo elsewhere)
  : >"$elsewhere/f"
  confined "$elsewhere" --session -- bash -c 'rm f; git rm -q README.md'
  [[ $status -ne 0 && -e $elsewhere/f && -e $elsewhere/README.md ]]
  confined "$elsewhere" --session -- bash -c 'cd "$1" && touch f && rm f' _ "$WT"
  assert_equal "$status" 0
}

@test "--session makes a task's session tmp with mode 700 and gives it to the command as TMPDIR" {
  with AGENT_TEAM_WORKTREE="$WT" AGENT_TEAM_TASK="$TASK" CLAUDE_CODE_SESSION_ID="$SESSION" TMPDIR="$BOX"
  [[ ! -e $TASK_TMP ]]
  confined "$WT" --session -- bash -c 'echo "$TMPDIR"; d=$(mktemp -d) && rmdir "$d"'
  assert_equal "$status" 0
  assert_equal "$output" "$TASK_TMP"
  assert_equal "$(stat -c '%a %F' "$TASK_TMP")" "700 directory"
  [[ ! -e $GATE_TMP ]]
  # One already there is kept as it is.
  : >"$TASK_TMP/kept"
  confined "$WT" --session -- rm "$TASK_TMP/kept"
  assert_equal "$status" 0
}

@test "--session makes a gate agent's session tmp from its session id, and none for a task or an id of another form" {
  with AGENT_TEAM_WORKTREE="$WT" CLAUDE_CODE_SESSION_ID="$SESSION" TMPDIR="$BOX"
  confined "$WT" --session -- bash -c 'echo "$TMPDIR"; f=$(mktemp) && rm "$f"'
  assert_equal "$status" 0
  assert_equal "$output" "$GATE_TMP"
  assert_equal "$(stat -c '%a %F' "$GATE_TMP")" "700 directory"
  with AGENT_TEAM_TASK="T7x" CLAUDE_CODE_SESSION_ID="../$SESSION"
  confined "$WT" --session -- bash -c 'echo "$TMPDIR"'
  assert_equal "$status" 0
  assert_equal "$output" "$BOX"
}

@test "--session refuses a session tmp that is a link or no directory, without running the command" {
  with AGENT_TEAM_WORKTREE="$WT" AGENT_TEAM_TASK="$TASK"
  ln -s "$OUT" "$TASK_TMP"
  confined "$WT" --session -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: the session tmp $TASK_TMP is a link, no directory or another user's"
  rm "$TASK_TMP"
  : >"$TASK_TMP"
  confined "$WT" --session -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: the session tmp $TASK_TMP is a link, no directory or another user's"
  [[ ! -e $WT/ran ]]
}

@test "--session with no worktree is refused with its text, and the command does not run" {
  with AGENT_TEAM_TASK="$TASK"
  confined "$WT" --session -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: no worktree for this session (AGENT_TEAM_WORKTREE and CLAUDE_PROJECT_DIR name no directory)"
  with AGENT_TEAM_WORKTREE="$BOX/missing" CLAUDE_PROJECT_DIR="$WT/f"
  : >"$WT/f"
  confined "$WT" --session -- touch "$WT/ran"
  assert_equal "$status" 3
  [[ ! -e $WT/ran && -z $output ]]
}

# A copy of the wrapper beside a confine-roots file holding <line>...: listed <line>...
listed() {
  mkdir -p "$BOX/lib"
  cp "$REPO_ROOT/bin/lib/confine.py" "$BOX/lib/"
  printf '%s\n' '# a comment' '' "$@" >"$BOX/lib/confine-roots"
  CONFINE=$BOX/lib/confine.py
}

@test "confine-roots: a listed directory is a root, with ~/ for the home directory, and a missing one is skipped" {
  with AGENT_TEAM_WORKTREE="$WT"
  mkdir -p "$BOX/cache" "$HOME/.cache/tool"
  : >"$BOX/cache/f"
  : >"$HOME/.cache/tool/f"
  : >"$OUT/f"
  listed "$BOX/cache" "$BOX/missing" "  ~/.cache/tool"
  confined "$WT" --session -- rm "$BOX/cache/f" "$HOME/.cache/tool/f" "$OUT/f"
  [[ $status -ne 0 && ! -e $BOX/cache/f && ! -e $HOME/.cache/tool/f && -e $OUT/f ]]
  # Without --session the file is not read.
  : >"$BOX/cache/f"
  confined "$WT" --root "$WT" -- rm "$BOX/cache/f"
  [[ $status -ne 0 && -e $BOX/cache/f ]]
}

@test "confine-roots: a line in or above the team home, ~/.config/agent-team or ~/.claude, or a relative one, is refused naming it" {
  local line
  with AGENT_TEAM_WORKTREE="$WT"
  mkdir -p "$TEAM_HOME/tasks" "$HOME/.config/agent-team" "$HOME/.claude/jobs"
  ln -s "$TEAM_HOME/tasks" "$BOX/link"
  # shellcheck disable=SC2088 # the roots file names HOME as ~
  for line in "$TEAM_HOME" "$TEAM_HOME/tasks" "$TEAM_HOME/not-there" "$BOX/link" "~/.config/agent-team" "~/.claude/jobs" \
    "~/.config" "$HOME" /; do
    listed "$BOX" "$line"
    confined "$WT" --session -- touch "$WT/ran"
    assert_equal "$status" 3
    assert_contains "$stderr" "confine: $BOX/lib/confine-roots lists $line, which is, holds or is under "
  done
  listed cache
  confined "$WT" --session -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: $BOX/lib/confine-roots lists cache, which is not an absolute path"
  # The team home named by ~/.config/agent-team/home, as the scripts find it.
  mv "$TEAM_HOME" "$HOME/records"
  echo records >"$HOME/.config/agent-team/home"
  unset TEAM_HOME
  # shellcheck disable=SC2088 # the roots file names HOME as ~
  listed "~/records/tasks"
  confined "$WT" --session -- touch "$WT/ran"
  assert_equal "$status" 3
  # And no roots file at all.
  rm "$BOX/lib/confine-roots"
  confined "$WT" --session -- touch "$WT/ran"
  assert_equal "$status" 3
  assert_contains "$stderr" "confine: cannot read $BOX/lib/confine-roots: "
  [[ ! -e $WT/ran ]]
}

@test "confine-roots: the checkout's file lists the team's state directory first, and nothing the wrapper refuses" {
  with AGENT_TEAM_WORKTREE="$WT"
  # shellcheck disable=SC2088 # the roots file names HOME as ~
  assert_equal "$(grep -v -e '^#' -e '^$' "$REPO_ROOT/bin/lib/confine-roots" | head -n 1)" "~/.local/state/agent-team"
  mkdir -p "$HOME/.config/agent-team" "$HOME/.claude"
  confined "$WT" --session -- true
  assert_equal "$status" 0
  assert_equal "$stderr" ""
}

UNCONFINED="so this command runs unconfined; the text guard alone holds it"

@test "no Landlock: the command runs unconfined with the one stderr line, once per session tmp and every time with none" {
  local abi
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
  with AGENT_TEAM_WORKTREE="$WT" AGENT_TEAM_TASK="$TASK" CONFINE_TEST_ABI="1"
  confined "$WT" --session -- bash -c 'echo "$TMPDIR"'
  assert_equal "$output" "$TASK_TMP"
  assert_equal "$stderr" "confine: this machine has no Landlock (ABI 1), $UNCONFINED"
  confined "$WT" --session -- echo ran
  assert_equal "$status" 0
  assert_equal "$output" ran
  assert_equal "$stderr" ""
  # A session with no session tmp is told on every command.
  unset AGENT_TEAM_TASK
  confined "$WT" --session -- echo ran
  assert_equal "$stderr" "confine: this machine has no Landlock (ABI 1), $UNCONFINED"
  confined "$WT" --session -- echo ran
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

@test "the wrapper's command line: --help is its docstring, --abi the kernel's version, the command's status its own" {
  local line
  confined "$WT" --help
  assert_equal "$status" 0
  assert_equal "${lines[0]}" "Runs a command where the kernel refuses a delete or a rename outside its roots."
  assert_contains "$output" "Usage: python3 -I confine.py [--root <dir>]... [--session] -- <command> [args...]"
  confined "$WT" --abi
  assert_equal "$status" 0
  assert_equal "$output" "$ABI"
  confined "$WT" --root "$WT" -- bash -c 'echo out; echo err >&2; exit 7'
  assert_equal "$status" 7
  assert_equal "$output" out
  assert_equal "$stderr" err
  run -127 --separate-stderr python3 -I "$CONFINE" -- "$WT/no-such-command"
  assert_equal "$stderr" "confine: cannot run $WT/no-such-command: No such file or directory"
  for line in "" "--root" "--root $WT" "--session" "--unknown -- true" "--root $WT --"; do
    # shellcheck disable=SC2086  # each line is a command line's words
    confined "$WT" $line
    assert_equal "$status" 2
    assert_equal "${stderr%%$'\n'*}" "Usage: python3 -I confine.py [--root <dir>]... [--session] -- <command> [args...]"
    assert_equal "$output" ""
  done
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

@test "--session takes the common git directory from AGENT_TEAM_GIT_DIR alone, whatever the worktree's own files name" {
  session
  canary
  # The worktree's files may name another git directory: the roots stay the launch's.
  mkdir -p "$OUT/objects" "$OUT/refs"
  echo 'ref: refs/heads/x' >"$OUT/HEAD"
  confined "$WT" --session -- bash -c 'mv .git .git.aside && echo "gitdir: $1" >.git' _ "$OUT"
  assert_equal "$status" 0
  confined "$WT" --session -- rm -rf "${OUT:?}/x"
  [[ $status -ne 0 ]]
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  mv -f "$WT/.git.aside" "$WT/.git"
  # With none named there is no such root, and git is not asked.
  : >"$MAIN/.git/probe"
  unset AGENT_TEAM_GIT_DIR
  confined "$WT" --session -- rm "$MAIN/.git/probe"
  [[ $status -ne 0 && -e $MAIN/.git/probe ]]
}

@test "--session refuses a common git directory that is a link, no directory, relative, or in or above a directory no root may be" {
  local named
  session
  mkdir -p "$HOME/.claude/repo.git" "$HOME/.config/agent-team" "$TEAM_HOME/.git"
  ln -s "$OUT" "$BOX/linked.git"
  : >"$BOX/file.git"
  for named in "$BOX/linked.git" "$BOX/file.git" "$BOX/missing.git" "main/.git" "$TEAM_HOME/.git" "$HOME/.claude/repo.git" "$HOME" /; do
    with AGENT_TEAM_GIT_DIR="$named"
    confined "$WT" --session -- touch "$WT/ran"
    assert_equal "$named: $status" "$named: 3"
    assert_contains "$stderr" "confine: "
    [[ ! -e $WT/ran && -z $output ]]
  done
}

@test "--session refuses a job tmp or a listed root that is a link or no directory, without running the command" {
  session
  canary
  rmdir "$JOB/tmp"
  ln -s "$OUT" "$JOB/tmp"
  confined "$WT" --session -- rm -rf "${OUT:?}/x"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: $JOB/tmp is a link, no directory or another user's, so it is no root"
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  rm "$JOB/tmp"
  : >"$JOB/tmp"
  confined "$WT" --session -- touch "$WT/ran"
  assert_equal "$status" 3
  rm "$JOB/tmp"
  # A missing job tmp is no root and no refusal.
  confined "$WT" --session -- touch "$WT/ran"
  assert_equal "$status" 0
  ln -s "$OUT" "$BOX/listed"
  listed "$BOX/listed"
  confined "$WT" --session -- rm -rf "${OUT:?}/x"
  assert_equal "$status" 3
  assert_equal "$stderr" "confine: $BOX/listed is a link, no directory or another user's, so it is no root"
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
}

# A Bash call as Claude Code 2.1.325 hands it to CLAUDE_CODE_SHELL_PREFIX: its shell runs
# '<prefix>' '<line>', the line one quoted argument holding what Claude Code puts around the
# command (the eval of its text, then the working directory written to a file):
# bash_call <command>
bash_call() {
  local line
  printf -v line 'eval %q && pwd -P >| %q' "$1" "$BOX/cwd"
  printf -v line '%q %q' "$REPO_ROOT/bin/lib/confine-shell" "$line"
  run --separate-stderr env -C "$WT" bash -c "$line"
}

@test "confine-shell: a Bash call's delete outside the worktree leaves it whole, and one inside removes it" {
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
  bash_call 'rm -rf build && cd src && echo "it ran in $TMPDIR"'
  assert_equal "$status" 0
  assert_equal "$output" "it ran in $TASK_TMP"
  [[ ! -e $WT/build ]]
  assert_equal "$(<"$BOX/cwd")" "$(realpath "$WT")/src"
}

@test "confine-shell: the line is the shell's to read, never the wrapper's options, and any other count of arguments exits 2" {
  local prefix=$REPO_ROOT/bin/lib/confine-shell
  session
  canary
  # A shell-form hook's command reaches the prefix as it is written.
  run -127 --separate-stderr env -C "$WT" "$prefix" "--root ${OUT:?} -- rm -rf ${OUT:?}/x"
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
  run -127 --separate-stderr env -C "$WT" "$prefix" '--abi'
  assert_equal "$output" ''
  run -127 --separate-stderr env -C "$WT" "$prefix" '--help x'
  assert_equal "$output" ''
  # --help alone, which is no call's line, is the header.
  run -0 --separate-stderr env -C "$WT" "$prefix" --help
  assert_equal "${lines[0]}" "The prefix a confined worker's Claude Code runs its shell commands through: team-worker names"
  run --separate-stderr env -C "$WT" "$prefix"
  assert_equal "$status" 2
  assert_equal "$stderr" "confine-shell: takes one argument, the command line, as Claude Code's CLAUDE_CODE_SHELL_PREFIX passes it"
  run --separate-stderr env -C "$WT" "$prefix" echo ran
  assert_equal "$status" 2
  assert_equal "$output" ''
}

@test "confine-shell: the shell is CLAUDE_CODE_SHELL, else SHELL, when an executable bash or zsh, else bash" {
  local prefix=$REPO_ROOT/bin/lib/confine-shell
  session
  mkdir -p "$BOX/bin" "$BOX/other"
  ln -s "$(command -v bash)" "$BOX/bin/zsh"
  ln -s "$(command -v bash)" "$BOX/other/bash"
  ln -s "$(command -v bash)" "$BOX/bin/fish"
  with SHELL="$BOX/bin/zsh"
  run --separate-stderr env -C "$WT" "$prefix" 'echo "$0"'
  assert_equal "$output" "$BOX/bin/zsh"
  with CLAUDE_CODE_SHELL="$BOX/other/bash"
  run --separate-stderr env -C "$WT" "$prefix" 'echo "$0"'
  assert_equal "$output" "$BOX/other/bash"
  with CLAUDE_CODE_SHELL="$BOX/bin/fish" SHELL="$BOX/missing/bash"
  run --separate-stderr env -C "$WT" "$prefix" 'echo "$0"'
  assert_equal "$output" bash
}

@test "confine-shell: the interpreter and the wrapper's roots come from no program on the session's PATH" {
  session
  canary
  mkdir -p "$BOX/bin"
  with PATH="$BOX/bin:$PATH"
  bash_call "for tool in git python3; do printf '#!/bin/sh\\nrm -rf %s\\nexit 0\\n' ${OUT:?}/x >$BOX/bin/\$tool && chmod +x $BOX/bin/\$tool; done"
  assert_equal "$status" 0
  [[ -x $BOX/bin/git && -x $BOX/bin/python3 ]]
  bash_call true
  assert_equal "$status" 0
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
}

@test "confine-shell: a profile the outer shell reads sets no seam, so the command still runs confined" {
  session
  canary
  echo 'export CONFINE_TEST_ABI=0 CONFINE_TEST_FAIL=' >"$HOME/.bash_profile"
  local line
  printf -v line '%q %q' "$REPO_ROOT/bin/lib/confine-shell" "rm -rf ${OUT:?}/x"
  run --separate-stderr env -C "$WT" bash -l -c "$line"
  [[ $status -ne 0 ]]
  assert_equal "$(canary_tree)" "${WHOLE//OUT/$OUT}"
}
