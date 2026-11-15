#!/usr/bin/env bats
# team-janitor tmp: the sweep of the team's stale leftovers, run for real against the two roots
# under the sandbox's TEAM_SYSTEM_ROOT ($TMP_ROOT and $VAR_ROOT), never the machine's /tmp. Each
# test asserts on what is left on disk and on what the run printed; an entry is aged with touch
# -d, and a live one is held by a real background sleep, stopped by its pid.

load helpers/common

setup() {
  sandbox
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  TMP_ROOT=$TEAM_SYSTEM_ROOT/tmp
  VAR_ROOT=$TEAM_SYSTEM_ROOT/var/tmp
  mkdir -p "$TMP_ROOT" "$VAR_ROOT"
  OUTSIDE=$BATS_TEST_TMPDIR/outside
  mkdir -p "$OUTSIDE"
  echo kept >"$OUTSIDE/file"
  DAY_FILE=$HOME/.local/state/agent-team/janitor/tmp-$(date +%F).md
  LIST=$REPO_ROOT/bin/lib/tmp-leftovers
}

# Stop what a test left running, each by its pid, and let bats remove a root a test made read-only.
teardown() {
  stop_background
  chmod u+w "$TMP_ROOT" "$VAR_ROOT" 2>/dev/null || true
}

# Note the process just started in the background ($!), for stop_background.
started() {
  echo "$!" >>"$BATS_TEST_TMPDIR/background"
}

# Stop each background process a test noted, and forget them.
stop_background() {
  local pid
  [[ -f $BATS_TEST_TMPDIR/background ]] || return 0
  while read -r pid; do stop "$pid"; done <"$BATS_TEST_TMPDIR/background"
  rm -f "$BATS_TEST_TMPDIR/background"
}

# stop <pid>: end a background process of the test and wait for it.
stop() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# running <pid> <text>: wait until the background process <pid> runs the command whose line holds
# <text>, since until then it is still the test's own shell, with the test's environment.
running() {
  local tries=0
  until [[ $(ps -o args= -p "$1") == *"$2"* ]]; do
    tries=$((tries + 1))
    ((tries < 100)) || { echo "running: process $1 never ran '$2'" >&2; return 1; }
    sleep 0.1
  done
}

# stale_dir <path> [<minutes>]: a directory holding a file, last modified <minutes> ago (125).
stale_dir() {
  mkdir -p "$1"
  echo data >"$1/data"
  touch -d "${2:-125} minutes ago" "$1"
}

# stale_file <path> [<minutes>]: a regular file last modified <minutes> ago (125).
stale_file() {
  echo data >"$1"
  touch -d "${2:-125} minutes ago" "$1"
}

# sample <expression> <digits> <letters>: a name a line's expression matches, its number <digits>
# and its mktemp suffix <letters>, repeated to the length the expression asks for.
sample() {
  local name=$1
  name=${name//'[0-9]+'/$2}
  name=${name//'[A-Za-z0-9]{6,10}'/$3$3}
  name=${name//'[A-Za-z0-9]{6}'/$3$3}
  name=${name//'\.'/.}
  [[ $name =~ ^($1)$ ]] || { echo "sample: '$name' does not match '$1'" >&2; return 1; }
  printf '%s\n' "$name"
}

@test "team-janitor tmp removes a stale directory and a stale file of every line of the list from both roots, and says each" {
  local maker expression first second count=0 expected=''
  while read -r maker expression; do
    [[ -n $maker && $maker != '#'* ]] || continue
    count=$((count + 1))
    first=$(sample "$expression" 123 AbC)
    second=$(sample "$expression" 456 xY9)
    stale_dir "$TMP_ROOT/$first"
    stale_file "$TMP_ROOT/$second"
    stale_file "$VAR_ROOT/$first"
    stale_dir "$VAR_ROOT/$second"
    expected+="removed $TMP_ROOT/$first (0 MB, untouched 2 h; $maker)"$'\n'
    expected+="removed $TMP_ROOT/$second (0 MB, untouched 2 h; $maker)"$'\n'
    expected+="removed $VAR_ROOT/$first (0 MB, untouched 2 h; $maker)"$'\n'
    expected+="removed $VAR_ROOT/$second (0 MB, untouched 2 h; $maker)"$'\n'
  done <"$LIST"
  ((count >= 12))

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$(LC_ALL=C sort <<<"$output")" "$(LC_ALL=C sort <<<"${expected%$'\n'}")"
  assert_equal "$(find "$TMP_ROOT" "$VAR_ROOT" -mindepth 1)" ""

  # The day's file: its title, then each removal as the run printed it, with the local time.
  assert_equal "$(sed -n 1p "$DAY_FILE")" "# Temp files removed on home-pc, $(date +%F)"
  assert_equal "$(sed -n 2p "$DAY_FILE")" ""
  assert_equal "$(sed -n '3,$p' "$DAY_FILE" | grep -cE '^- [0-2][0-9]:[0-5][0-9] removed /')" "$((count * 4))"
  assert_equal "$(sed -n '3,$p' "$DAY_FILE" | sed -E 's/^- [0-9:]{5} //')" "$output"

  # A later removal of the day is appended under the one title.
  stale_dir "$TMP_ROOT/nm-cli-home-7"
  run_bin -0 team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/nm-cli-home-7 (0 MB, untouched 2 h; no-mistakes)"
  assert_equal "$(grep -c '^# ' "$DAY_FILE")" 1
  assert_equal "$(grep -c '^- ' "$DAY_FILE")" "$((count * 4 + 1))"
}

@test "team-janitor tmp says a removal's size in MB and its age in minutes under two hours" {
  mkdir "$TMP_ROOT/nm-cli-home-1"
  head -c $((3 * 1024 * 1024)) /dev/zero >"$TMP_ROOT/nm-cli-home-1/blob"
  touch -d '75 minutes ago' "$TMP_ROOT/nm-cli-home-1"
  run_bin -0 team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/nm-cli-home-1 (3 MB, untouched 75 min; no-mistakes)"
}

@test "team-janitor tmp leaves a fresh entry, a name the list lacks and a symbolic link, and prints nothing" {
  local name
  # Fresh: modified under the 60 minutes.
  stale_dir "$TMP_ROOT/nm-cli-home-1" 59
  stale_file "$VAR_ROOT/git-template-2" 10
  # Names no line matches whole, mktemp's default among them.
  for name in tmp.AbCdEfGhIj nm-cli-home-12x xnm-cli-home-12 nm-cli-home- bats-run-AbC12 systemd-private-x pytest-of-user; do
    stale_dir "$TMP_ROOT/$name"
    stale_file "$VAR_ROOT/$name"
  done
  # A link with a listed name, to a directory and to a file.
  ln -s "$OUTSIDE" "$TMP_ROOT/nm-cli-home-77"
  ln -s "$OUTSIDE/file" "$VAR_ROOT/nm-cli-home-78"
  touch -h -d '125 minutes ago' "$TMP_ROOT/nm-cli-home-77" "$VAR_ROOT/nm-cli-home-78"
  touch -d '125 minutes ago' "$OUTSIDE" "$OUTSIDE/file"
  local before
  before=$(find "$TEAM_SYSTEM_ROOT" "$OUTSIDE" | LC_ALL=C sort)

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(find "$TEAM_SYSTEM_ROOT" "$OUTSIDE" | LC_ALL=C sort)" "$before"
  [[ -L $TMP_ROOT/nm-cli-home-77 && -L $VAR_ROOT/nm-cli-home-78 ]]
  assert_equal "$(cat "$OUTSIDE/file")" kept
  [[ ! -e $DAY_FILE ]]

  # The age is a seam: at 5 minutes the fresh ones are stale.
  TEAM_TMP_AGE_MINUTES=5 run_bin -0 team-janitor tmp
  assert_equal "$(wc -l <<<"$output")" 2
  [[ ! -e $TMP_ROOT/nm-cli-home-1 && ! -e $VAR_ROOT/git-template-2 ]]
}

@test "team-janitor tmp leaves another owner's entry" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  stale_file "$VAR_ROOT/git-template-2"
  TEAM_TMP_UID=$(($(id -u) + 1)) run_bin -0 team-janitor tmp
  assert_equal "$output" ""
  [[ -d $TMP_ROOT/nm-cli-home-1 && -f $VAR_ROOT/git-template-2 ]]
}

@test "team-janitor tmp leaves an entry a process has as its working directory, and removes it once the process ended" {
  stale_dir "$TMP_ROOT/bats-run-AbC123"
  stale_dir "$TMP_ROOT/bats-run-AbC123/test/1"
  # One process in the entry itself, one deeper in it.
  (cd "$TMP_ROOT/bats-run-AbC123" && exec sleep 300) >/dev/null 2>&1 3>&- &
  started
  stale_dir "$VAR_ROOT/nm-cli-home-4"
  mkdir -p "$VAR_ROOT/nm-cli-home-4/deep/er"
  (cd "$VAR_ROOT/nm-cli-home-4/deep/er" && exec sleep 300) >/dev/null 2>&1 3>&- &
  started
  touch -d '125 minutes ago' "$TMP_ROOT/bats-run-AbC123" "$VAR_ROOT/nm-cli-home-4"
  # Each sleep is in its directory before the run reads the processes.
  local pid
  while read -r pid; do running "$pid" "sleep 300"; done <"$BATS_TEST_TMPDIR/background"

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  [[ -d $TMP_ROOT/bats-run-AbC123/test/1 && -d $VAR_ROOT/nm-cli-home-4/deep/er ]]

  stop_background
  run_bin -0 team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/bats-run-AbC123 (0 MB, untouched 2 h; bats)
removed $VAR_ROOT/nm-cli-home-4 (0 MB, untouched 2 h; no-mistakes)"
}

@test "team-janitor tmp leaves an entry a process names in its environment or command line, never one whose name only begins another's" {
  stale_dir "$TMP_ROOT/nm-cli-home-5"
  stale_dir "$TMP_ROOT/nm-cli-home-6"
  stale_dir "$TMP_ROOT/nm-cli-home-7"
  stale_dir "$TMP_ROOT/nm-cli-home-8"
  stale_dir "$TMP_ROOT/nm-cli-home-9"
  # In the environment: alone, as a directory of a PATH, and as the start of a longer path.
  GOMODCACHE=$TMP_ROOT/nm-cli-home-5 SEARCH=/usr/bin:$TMP_ROOT/nm-cli-home-6:/bin HOLDS=$TMP_ROOT/nm-cli-home-7/pkg/mod \
    sleep 300 >/dev/null 2>&1 3>&- &
  started
  running "$!" "sleep 300"
  # On the command line; and nm-cli-home-9 only as the beginning of another name.
  # The process waits on a pipe no one writes to, so it has no child to outlive it.
  mkfifo "$BATS_TEST_TMPDIR/never"
  bash -c 'read -r <"$0"' "$BATS_TEST_TMPDIR/never" "$TMP_ROOT/nm-cli-home-8" "$TMP_ROOT/nm-cli-home-99" >/dev/null 2>&1 3>&- &
  started
  running "$!" "nm-cli-home-99"

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$output" "removed $TMP_ROOT/nm-cli-home-9 (0 MB, untouched 2 h; no-mistakes)"
  [[ -d $TMP_ROOT/nm-cli-home-5 && -d $TMP_ROOT/nm-cli-home-6 && -d $TMP_ROOT/nm-cli-home-7 && -d $TMP_ROOT/nm-cli-home-8 ]]
}

@test "team-janitor tmp removes a read-only tree, and a directory holding a link without what the link points at" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  mkdir -p "$TMP_ROOT/nm-cli-home-1/pkg/mod/cache"
  echo module >"$TMP_ROOT/nm-cli-home-1/pkg/mod/cache/module.go"
  chmod -R a-w "$TMP_ROOT/nm-cli-home-1"
  touch -d '125 minutes ago' "$TMP_ROOT/nm-cli-home-1"
  stale_dir "$VAR_ROOT/git-template-2"
  ln -s "$OUTSIDE" "$VAR_ROOT/git-template-2/link"
  ln -s "$OUTSIDE/file" "$VAR_ROOT/git-template-2/file-link"
  touch -d '125 minutes ago' "$VAR_ROOT/git-template-2"

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$output" "removed $TMP_ROOT/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)
removed $VAR_ROOT/git-template-2 (0 MB, untouched 2 h; no-mistakes)"
  [[ ! -e $TMP_ROOT/nm-cli-home-1 && ! -e $VAR_ROOT/git-template-2 ]]
  assert_equal "$(cat "$OUTSIDE/file")" kept
  [[ -w $OUTSIDE && -w $OUTSIDE/file ]]
}

@test "team-janitor tmp --dry-run prints would remove, removes nothing and writes no file" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  stale_file "$VAR_ROOT/git-template-2"
  local before
  before=$(files_state)
  run_bin -0 --separate-stderr team-janitor tmp --dry-run
  assert_equal "$stderr" ""
  assert_equal "$output" "would remove $TMP_ROOT/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)
would remove $VAR_ROOT/git-template-2 (0 MB, untouched 2 h; no-mistakes)"
  [[ -f $TMP_ROOT/nm-cli-home-1/data && -f $VAR_ROOT/git-template-2 ]]
  assert_equal "$(files_state)" "$before"
  [[ ! -e $HOME/.local/state ]]
}

@test "team-janitor tmp names a removal that fails on stderr, makes the others and exits 1" {
  [[ $(id -u) != 0 ]] || skip "root removes from a read-only directory"
  stale_file "$TMP_ROOT/nm-cli-home-1"
  stale_dir "$VAR_ROOT/git-template-2"
  stale_file "$VAR_ROOT/git-template-3"
  chmod a-w "$TMP_ROOT"

  run_bin -1 --separate-stderr team-janitor tmp
  assert_equal "$output" "removed $VAR_ROOT/git-template-2 (0 MB, untouched 2 h; no-mistakes)
removed $VAR_ROOT/git-template-3 (0 MB, untouched 2 h; no-mistakes)"
  assert_equal "$(wc -l <<<"$stderr")" 1
  [[ $stderr == "team-janitor: could not remove $TMP_ROOT/nm-cli-home-1: rm: cannot remove "* ]]
  [[ -f $TMP_ROOT/nm-cli-home-1 ]]
  assert_equal "$(find "$VAR_ROOT" -mindepth 1)" ""
  # Only what was removed is in the day's file.
  assert_equal "$(grep -c '^- ' "$DAY_FILE")" 2
}

@test "a second team-janitor tmp while one holds the lock is skipped with exit 0" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  local lock=$HOME/.local/state/agent-team/tmp.lock
  mkdir -p "$HOME/.local/state/agent-team"
  (exec 9>"$lock" && flock -n 9 && exec sleep 300) >/dev/null 2>&1 3>&- &
  started
  running "$!" "sleep 300"

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" "another team-janitor tmp is running; skipped"
  assert_equal "$stderr" ""
  [[ -d $TMP_ROOT/nm-cli-home-1 ]]

  # A dry run only reads, so it waits on no one.
  run_bin -0 team-janitor tmp --dry-run
  assert_equal "$output" "would remove $TMP_ROOT/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)"

  stop_background
  run_bin -0 team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)"
}

@test "team-janitor tmp skips a missing root, and a run with nothing to remove prints nothing" {
  rmdir "$VAR_ROOT"
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  [[ ! -e $DAY_FILE ]]

  stale_dir "$TMP_ROOT/nm-cli-home-1"
  run_bin -0 team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)"

  rmdir "$TMP_ROOT"
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
}

@test "team-janitor tmp removes through a root that is a link, by its resolved path" {
  mkdir "$BATS_TEST_TMPDIR/private-tmp"
  rmdir "$TMP_ROOT"
  ln -s "$BATS_TEST_TMPDIR/private-tmp" "$TMP_ROOT"
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  stale_dir "$TMP_ROOT/nm-cli-home-2"
  # A process that names the entry by the root as it is called, before it is resolved.
  HOLDS=$TMP_ROOT/nm-cli-home-2 sleep 300 >/dev/null 2>&1 3>&- &
  started
  running "$!" "sleep 300"
  run_bin -0 team-janitor tmp
  assert_equal "$output" "removed $BATS_TEST_TMPDIR/private-tmp/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)"
  [[ -d $BATS_TEST_TMPDIR/private-tmp/nm-cli-home-2 ]]
}

@test "team-janitor tmp removes nothing and exits 1 saying why when the processes cannot be read" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  # What the reading of the processes runs on each platform: tr over /proc's text on Linux, lsof
  # on macOS.
  if [[ $(uname -s) == Darwin ]]; then fails_on_call lsof; else fails_on_call tr '\0'; fi
  run_bin -1 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  [[ $stderr == "team-janitor: could not read this user's processes, so nothing was removed: "* ]]
  [[ -f $TMP_ROOT/nm-cli-home-1/data ]]
  [[ ! -e $DAY_FILE ]]

  # With nothing to remove the processes are never read, so the run passes.
  touch "$TMP_ROOT/nm-cli-home-1"
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
}

@test "team-janitor tmp refuses an argument it does not know, and a TEAM_TMP_AGE_MINUTES that is no number" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  run_bin -2 team-janitor tmp --apply
  assert_equal "$output" "team-janitor: usage: team-janitor tmp [--dry-run]"
  run_bin -2 team-janitor tmp --dry-run extra
  TEAM_TMP_AGE_MINUTES=soon run_bin -1 team-janitor tmp
  assert_equal "$output" "team-janitor: TEAM_TMP_AGE_MINUTES is 'soon', not a whole number of minutes"
  [[ -d $TMP_ROOT/nm-cli-home-1 ]]
}

@test "team-janitor --help documents the tmp subcommand" {
  run_bin -0 team-janitor --help
  assert_contains "$output" "team-janitor tmp [--dry-run]"
  assert_contains "$output" "bin/lib/tmp-leftovers"
  assert_contains "$output" "another team-janitor tmp is running; skipped"
}
