#!/usr/bin/env bats
# team-janitor tmp: the sweep of the team's stale leftovers, run for real against the two roots
# under the sandbox's TEAM_SYSTEM_ROOT ($TMP_ROOT and $VAR_ROOT), never the machine's /tmp. Each
# test asserts on what is left on disk and on what the run printed; an entry is aged with touch
# -d, and a live one is held by a real background sleep, stopped by its pid. The /tmp root's file
# system is the reading TEAM_TMP_DF names, 10% of 16 GiB unless a test writes another, and Discord
# is the inbox helper's fake, which keeps each alert's body.

load helpers/common
load helpers/inbox

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
  STATE=$HOME/.local/state/agent-team
  export TEAM_TMP_DF=$BATS_TEST_TMPDIR/df
  reading 10
  inbox_discord alerts
}

# reading <percent> [<type>] [<options>]: the /tmp root's file system, as TEAM_TMP_DF gives it in
# place of findmnt and df: 16 GiB, <percent> of it used (rounded up to a whole byte), a tmpfs
# mounted with usrquota unless given.
reading() {
  local size=17179869184
  printf '%s %s %s %s\n' "${2:-tmpfs}" "$size" "$(((size * $1 + 99) / 100))" "${3:-rw,nosuid,nodev,size=16777216k,usrquota}" \
    >"$TEAM_TMP_DF"
}

# The texts of the alerts the fake Discord was sent, one per line, in order.
alerts_posted() {
  local id
  [[ -f $STUB_FIXTURES/inbox/alerts ]] || return 0
  while read -r id; do jq -r .content "$STUB_FIXTURES/inbox/$id.json"; done <"$STUB_FIXTURES/inbox/alerts"
}

# The tmp notice the record holds, or null.
tmp_notice() {
  jq -c '.notices.tmp' "$STATE/notices.json"
}

# Set the tmp notice's post <minutes> ago in the record.
posted_ago() {
  jq --arg at "$(date -u -d "$1 minutes ago" +%FT%TZ)" '.notices.tmp.posted = $at' "$STATE/notices.json" >"$STATE/notices.json.new"
  mv "$STATE/notices.json.new" "$STATE/notices.json"
}

# Two entries of this user's under the /tmp root, for the largest: big, a 3 MB file, and small, a
# directory holding a 1 MB file.
two_entries() {
  head -c 3145728 /dev/zero >"$TMP_ROOT/big"
  mkdir "$TMP_ROOT/small"
  head -c 1048576 /dev/zero >"$TMP_ROOT/small/data"
}

# Stop what a test left running, each by its pid, and let bats remove what a test made read-only.
teardown() {
  stop_background
  chmod -R u+w "$TEAM_SYSTEM_ROOT" 2>/dev/null || true
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

@test "team-janitor tmp leaves an entry a process holds only by an open file in it, a lock or a pid file, and removes it once the process ended" {
  stale_dir "$TMP_ROOT/bats-run-AbC123"
  stale_dir "$VAR_ROOT/nm-cli-home-4"
  # Each process runs from the test's directory, and neither its command line nor its environment
  # names the entry: it holds a file in it open, a lock for writing and a pid file for reading.
  (exec sleep 300) 9>"$TMP_ROOT/bats-run-AbC123/lock" >/dev/null 2>&1 3>&- &
  started
  echo 1 >"$VAR_ROOT/nm-cli-home-4/pid"
  (exec sleep 300) 9<"$VAR_ROOT/nm-cli-home-4/pid" >/dev/null 2>&1 3>&- &
  started
  touch -d '125 minutes ago' "$TMP_ROOT/bats-run-AbC123" "$VAR_ROOT/nm-cli-home-4"
  local pid
  while read -r pid; do running "$pid" "sleep 300"; done <"$BATS_TEST_TMPDIR/background"

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  [[ -f $TMP_ROOT/bats-run-AbC123/lock && -f $VAR_ROOT/nm-cli-home-4/pid ]]

  stop_background
  run_bin -0 team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/bats-run-AbC123 (0 MB, untouched 2 h; bats)
removed $VAR_ROOT/nm-cli-home-4 (0 MB, untouched 2 h; no-mistakes)"
}

@test "team-janitor tmp keeps no process's environment in its scratch: its process text holds only lines that name a root" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  # A process whose environment holds a secret and no root, and one whose holds both.
  TEAM_TMP_TEST_SECRET=hunter2-not-a-root sleep 300 >/dev/null 2>&1 3>&- &
  started
  running "$!" "sleep 300"
  TEAM_TMP_TEST_SECRET=hunter2-not-a-root TEAM_TMP_TEST_DIR=$TMP_ROOT/kept sleep 301 >/dev/null 2>&1 3>&- &
  started
  running "$!" "sleep 301"
  # The run's scratch in a directory of the test's, kept as a killed run would leave it: the EXIT
  # trap's removal of it fails, whose exit code is then the run's.
  mkdir "$BATS_TEST_TMPDIR/run-tmp"
  fails_on_call rm "$BATS_TEST_TMPDIR/run-tmp/"
  TMPDIR=$BATS_TEST_TMPDIR/run-tmp run_bin -5 team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)"
  local text
  text=$(find "$BATS_TEST_TMPDIR/run-tmp" -name processes)
  [[ -f $text ]]
  assert_equal "$(cat "$text")" "TEAM_TMP_TEST_DIR=$TMP_ROOT/kept"
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
  assert_equal "$output" "team-janitor: usage: team-janitor tmp [--dry-run] | team-janitor tmp status [--json]"
  run_bin -2 team-janitor tmp --dry-run extra
  TEAM_TMP_AGE_MINUTES=soon run_bin -1 team-janitor tmp
  assert_equal "$output" "team-janitor: TEAM_TMP_AGE_MINUTES is 'soon', not a whole number of minutes"
  [[ -d $TMP_ROOT/nm-cli-home-1 ]]
}

@test "team-janitor tmp refuses a list line whose expression holds an alternation, removing nothing" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  stale_dir "$TMP_ROOT/widened"
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm "$CODE_CHECKOUT/bin/lib/tmp-leftovers"
  { cat "$LIST"; echo 'no-mistakes nm-cli-home-[0-9]+|[a-z]+'; } >"$CODE_CHECKOUT/bin/lib/tmp-leftovers"
  run_bin -1 team-janitor tmp
  assert_equal "$output" "team-janitor: $CODE_CHECKOUT/bin/lib/tmp-leftovers: 'no-mistakes nm-cli-home-[0-9]+|[a-z]+' holds a |, which would widen the names it removes"
  [[ -d $TMP_ROOT/nm-cli-home-1 && -d $TMP_ROOT/widened ]]
}

@test "team-janitor --help documents the tmp subcommand" {
  run_bin -0 team-janitor --help
  assert_contains "$output" "team-janitor tmp [--dry-run]"
  assert_contains "$output" "bin/lib/tmp-leftovers"
  assert_contains "$output" "another team-janitor tmp is running; skipped"
}

# closed_task T<n>: an opened task, then its closed, in the sandbox's ledger.
closed_task() {
  opened_task "$1"
  jq -cn --arg task "$1" '{ts: "2026-01-02T00:00:00Z", task: $task, event: "closed", archive: [], returned: [], kept: []}' \
    >>"$TEAM_HOME/ledger.jsonl"
}

@test "team-janitor tmp removes a closed task's session tmp and task-named scratch from both roots, and leaves an open task's" {
  closed_task T367
  opened_task T394
  local root task expected=''
  # The session tmp, holding a read-only tree, which team-close's plain rm -rf cannot remove.
  stale_dir "$TMP_ROOT/agent-team-T367/go/pkg/mod"
  chmod -R a-w "$TMP_ROOT/agent-team-T367/go"
  touch -d '125 minutes ago' "$TMP_ROOT/agent-team-T367"
  for root in "$TMP_ROOT" "$VAR_ROOT"; do
    for task in 367 394; do
      stale_dir "$root/t$task.x"
      stale_file "$root/T$task-review.x"
      stale_file "$root/t${task}_x.md"
    done
  done
  stale_dir "$VAR_ROOT/agent-team-T367"
  stale_dir "$TMP_ROOT/agent-team-T394" 600
  stale_dir "$VAR_ROOT/agent-team-T394" 600
  for root in "$TMP_ROOT" "$VAR_ROOT"; do
    expected+="removed $root/T367-review.x (0 MB, untouched 2 h; T367 is closed)"$'\n'
    expected+="removed $root/agent-team-T367 (0 MB, untouched 2 h; T367 is closed)"$'\n'
    expected+="removed $root/t367.x (0 MB, untouched 2 h; T367 is closed)"$'\n'
    expected+="removed $root/t367_x.md (0 MB, untouched 2 h; T367 is closed)"$'\n'
  done

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$output" "${expected%$'\n'}"
  assert_equal "$(grep -c 'T367 is closed)$' "$DAY_FILE")" 8
  # The open task's, whatever their age, are all left.
  assert_equal "$(find "$TMP_ROOT" "$VAR_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | uniq -c | sed 's/^ *//')" \
    "2 T394-review.x
2 agent-team-T394
2 t394.x
2 t394_x.md"
}

@test "team-janitor tmp leaves a task-named entry of a number the ledger does not know, and names that are not the task rule's" {
  closed_task T5
  local name
  for name in t6.x T6-review.x agent-team-T6 t5 T5 t5x T5x t5- t5. agent-team-T5x agent-team-t5 xt5.x T05.x; do
    stale_dir "$TMP_ROOT/$name"
    stale_file "$VAR_ROOT/$name"
  done
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(find "$TMP_ROOT" "$VAR_ROOT" -mindepth 1 -maxdepth 1 | wc -l)" 26
}

@test "team-janitor tmp removes a name with a blank by its exact path, and a name with a blank or a line break widens no removal" {
  closed_task T367
  stale_dir "$TMP_ROOT/t367-a b"
  stale_dir "$TMP_ROOT/nm-cli-home-1 x"
  stale_dir "$TMP_ROOT/nm-cli-home-2"
  stale_dir "$TMP_ROOT/nm-cli-home-3"$'\n'"nm-cli-home-2"
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$output" "removed $TMP_ROOT/nm-cli-home-2 (0 MB, untouched 2 h; no-mistakes)
removed $TMP_ROOT/t367-a b (0 MB, untouched 2 h; T367 is closed)"
  [[ ! -e "$TMP_ROOT/t367-a b" && ! -e $TMP_ROOT/nm-cli-home-2 ]]
  [[ -f "$TMP_ROOT/nm-cli-home-1 x/data" && -f "$TMP_ROOT/nm-cli-home-3"$'\n'"nm-cli-home-2/data" ]]
  assert_equal "$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -printf . | wc -c)" 2
}

@test "team-janitor tmp leaves every task-named entry when the ledger cannot be read, says so once, and still removes the listed ones" {
  stale_dir "$TMP_ROOT/agent-team-T3"
  stale_file "$TMP_ROOT/t3.x"
  stale_file "$VAR_ROOT/T4-review.x"
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  rm "$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)"
  assert_equal "$stderr" "team-janitor: could not read the ledger, $TEAM_HOME/ledger.jsonl, so no entry named for a task was removed"
  [[ -d $TMP_ROOT/agent-team-T3 && -f $TMP_ROOT/t3.x && -f $VAR_ROOT/T4-review.x ]]

  # A ledger jq fails on is no ledger either.
  closed_task T3
  stale_dir "$TMP_ROOT/git-template-1"
  fails_on_call jq ledger_events
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/git-template-1 (0 MB, untouched 2 h; no-mistakes)"
  assert_equal "$stderr" "team-janitor: could not read the ledger, $TEAM_HOME/ledger.jsonl, so no entry named for a task was removed"
  [[ -d $TMP_ROOT/agent-team-T3 && -f $TMP_ROOT/t3.x && -f $VAR_ROOT/T4-review.x ]]
}

@test "team-janitor tmp removes a listed stale entry inside an open task's session tmp and a gate session's, and leaves each session tmp" {
  opened_task T394
  stale_dir "$TMP_ROOT/agent-team-T394/nm-cli-home-1"
  stale_file "$TMP_ROOT/agent-team-T394/git-template-2"
  stale_dir "$TMP_ROOT/agent-team-T394/t394.x"
  stale_dir "$TMP_ROOT/agent-team-T394/tmp.AbCdEfGhIj"
  stale_dir "$TMP_ROOT/agent-team-T394/nm-cli-home-3" 10
  touch -d '125 minutes ago' "$TMP_ROOT/agent-team-T394"
  stale_dir "$TMP_ROOT/agent-team-gate-a1B2-c3d/bats-run-AbC123"
  touch -d '125 minutes ago' "$TMP_ROOT/agent-team-gate-a1B2-c3d"
  # Only a session tmp under /tmp is read into.
  stale_dir "$VAR_ROOT/agent-team-T394/nm-cli-home-1"

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$output" "removed $TMP_ROOT/agent-team-T394/git-template-2 (0 MB, untouched 2 h; no-mistakes)
removed $TMP_ROOT/agent-team-T394/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)
removed $TMP_ROOT/agent-team-gate-a1B2-c3d/bats-run-AbC123 (0 MB, untouched 2 h; bats)"
  assert_equal "$(find "$TMP_ROOT/agent-team-T394" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" "nm-cli-home-3
t394.x
tmp.AbCdEfGhIj"
  [[ -d $TMP_ROOT/agent-team-gate-a1B2-c3d && -d $VAR_ROOT/agent-team-T394/nm-cli-home-1 ]]
}

@test "team-janitor tmp removes a closed task's session tmp whole, and reads into it only while a process keeps it" {
  closed_task T367
  stale_dir "$TMP_ROOT/agent-team-T367/nm-cli-home-1"
  touch -d '125 minutes ago' "$TMP_ROOT/agent-team-T367"
  run_bin -0 team-janitor tmp --dry-run
  assert_equal "$output" "would remove $TMP_ROOT/agent-team-T367 (0 MB, untouched 2 h; T367 is closed)"

  (cd "$TMP_ROOT/agent-team-T367" && exec sleep 300) >/dev/null 2>&1 3>&- &
  started
  running "$!" "sleep 300"
  run_bin -0 team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/agent-team-T367/nm-cli-home-1 (0 MB, untouched 2 h; no-mistakes)"
  [[ -d $TMP_ROOT/agent-team-T367 ]]
  stop_background
  run_bin -0 team-janitor tmp
  assert_equal "$output" ""
  touch -d '125 minutes ago' "$TMP_ROOT/agent-team-T367"
  run_bin -0 team-janitor tmp
  assert_equal "$output" "removed $TMP_ROOT/agent-team-T367 (0 MB, untouched 2 h; T367 is closed)"
}

@test "team-janitor tmp leaves a gate session's tmp at 23 hours, removes it at 25, and leaves a live one" {
  stale_dir "$TMP_ROOT/agent-team-gate-abcd1234" $((23 * 60))
  stale_dir "$TMP_ROOT/agent-team-gate-efgh5678" $((25 * 60))
  stale_dir "$TMP_ROOT/agent-team-gate-ijkl9012" $((25 * 60))
  stale_dir "$VAR_ROOT/agent-team-gate-mnop-345" $((25 * 60))
  # Not the gate rule's: seven characters, nine, and one that is no letter, digit or dash.
  stale_dir "$TMP_ROOT/agent-team-gate-abc1234" $((25 * 60))
  stale_dir "$TMP_ROOT/agent-team-gate-abcd12345" $((25 * 60))
  stale_dir "$TMP_ROOT/agent-team-gate-abcd_234" $((25 * 60))
  TMPDIR=$TMP_ROOT/agent-team-gate-ijkl9012 sleep 300 >/dev/null 2>&1 3>&- &
  started
  running "$!" "sleep 300"
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$output" "removed $TMP_ROOT/agent-team-gate-efgh5678 (0 MB, untouched 25 h; a gate session's tmp)
removed $VAR_ROOT/agent-team-gate-mnop-345 (0 MB, untouched 25 h; a gate session's tmp)"
  assert_equal "$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" "agent-team-gate-abc1234
agent-team-gate-abcd1234
agent-team-gate-abcd12345
agent-team-gate-abcd_234
agent-team-gate-ijkl9012"
}

@test "team-janitor tmp neither removes nor reads into a session tmp that is a symbolic link or another owner's" {
  closed_task T367
  opened_task T394
  mkdir -p "$OUTSIDE/session"
  stale_dir "$OUTSIDE/session/nm-cli-home-1"
  ln -s "$OUTSIDE/session" "$TMP_ROOT/agent-team-T367"
  ln -s "$OUTSIDE/session" "$TMP_ROOT/agent-team-T394"
  ln -s "$OUTSIDE/session" "$TMP_ROOT/agent-team-gate-abcd1234"
  touch -h -d '2 days ago' "$TMP_ROOT/agent-team-T367" "$TMP_ROOT/agent-team-T394" "$TMP_ROOT/agent-team-gate-abcd1234"
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  [[ -L $TMP_ROOT/agent-team-T367 && -d $OUTSIDE/session/nm-cli-home-1 ]]

  rm "$TMP_ROOT/agent-team-T367" "$TMP_ROOT/agent-team-T394"
  stale_dir "$TMP_ROOT/agent-team-T367/nm-cli-home-1"
  stale_dir "$TMP_ROOT/agent-team-T394/nm-cli-home-1"
  touch -d '125 minutes ago' "$TMP_ROOT/agent-team-T367" "$TMP_ROOT/agent-team-T394"
  TEAM_TMP_UID=$(($(id -u) + 1)) run_bin -0 team-janitor tmp
  assert_equal "$output" ""
  [[ -d $TMP_ROOT/agent-team-T367/nm-cli-home-1 && -d $TMP_ROOT/agent-team-T394/nm-cli-home-1 ]]
}

@test "team-janitor --help documents the task rule and the gate rule" {
  run_bin -0 team-janitor --help
  assert_contains "$output" "T367 is closed"
  assert_contains "$output" "a gate session's tmp"
  assert_contains "$output" "agent-team-T<n>"
  assert_contains "$output" "agent-team-gate-"
  assert_contains "$output" "24 hours"
}

@test "notice.jq's table has the tmp source: its open post retried, no end action" {
  run -0 jq -cn -L "$REPO_ROOT/bin/lib" 'include "notice"; notice_sources.tmp'
  assert_equal "$output" '{"retry_open":true,"end":null,"unposted_end":false,"retry_end":false}'
}

@test "team-janitor tmp status --json prints the team-tmp/1 reading and status its text, writing nothing" {
  local entry
  # Six entries of this user's: the five largest are listed, largest first.
  for entry in 1 2 3 4 5 6; do head -c $((entry * 1048576)) /dev/zero >"$TMP_ROOT/entry-$entry"; done
  reading 52

  run_bin -0 --separate-stderr team-janitor tmp status --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c 'del(.largest)' <<<"$output")" "$(jq -cn --arg root "$(realpath "$TMP_ROOT")" \
    '{schema: "team-tmp/1", root: $root, type: "tmpfs", judged: true, size: 17179869184, used: 8933531976,
      percent: 52, quota: true, warning: false, removed_today: 0, report: null}')"
  assert_equal "$(jq -c '[.largest[].name]' <<<"$output")" '["entry-6","entry-5","entry-4","entry-3","entry-2"]'
  assert_equal "$(jq -c '[.largest[].bytes]' <<<"$output")" \
    "$(for entry in 6 5 4 3 2; do du -sk "$TMP_ROOT/entry-$entry" | awk '{print $1 * 1024}'; done | jq -sc .)"
  [[ ! -e $STATE/notices.json && ! -e $STATE/janitor && ! -e $STATE/tmp.lock ]]

  run_bin -0 --separate-stderr team-janitor tmp status
  assert_equal "$stderr" ""
  assert_equal "$output" "/tmp is 52% full (8.3 GiB of 16.0 GiB), past 50%
largest: entry-6 6 MB
largest: entry-5 5 MB
largest: entry-4 4 MB
largest: entry-3 3 MB
largest: entry-2 2 MB
removed today: 0"
  [[ ! -e $STATE/notices.json && ! -e $STATE/janitor && ! -e $STATE/tmp.lock ]]
  assert_equal "$(stub_calls curl)" ""
}

@test "team-janitor tmp status counts the day's removals and names its file, and a quiet /tmp has no past clause" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  stale_file "$TMP_ROOT/git-template-2"
  run_bin -0 team-janitor tmp
  reading 12

  run_bin -0 team-janitor tmp status --json
  assert_equal "$(jq -c '[.percent, .warning, .largest, .removed_today, .report]' <<<"$output")" \
    "$(jq -cn --arg report "$DAY_FILE" '[12, false, [], 2, $report]')"
  run_bin -0 team-janitor tmp status
  assert_equal "$output" "/tmp is 12% full (1.9 GiB of 16.0 GiB)
removed today: 2 (~/.local/state/agent-team/janitor/tmp-$(date +%F).md)"
}

@test "team-janitor tmp under 50% posts nothing and prints nothing" {
  two_entries
  reading 49
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(alerts_posted)" ""
  assert_equal "$(tmp_notice)" null
}

@test "team-janitor tmp at 50% posts the warning once, records it and prints the post; the next run posts nothing" {
  two_entries
  reading 50
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$output" "posted to #coordinator (message 1569000000000000001): /tmp is 50% full"
  assert_equal "$(alerts_posted)" "/tmp on home-pc is 50% full (8.0 GiB of 16.0 GiB), past 50%; systemd holds each user to 80% of it. Largest of yours: big 3 MB, small 1 MB. \`team-janitor tmp status\` lists them; today's removals: none."
  assert_equal "$(jq -c '{source, key, state, message}' <<<"$(tmp_notice)")" \
    '{"source":"tmp","key":"tmp","state":"posted","message":"1569000000000000001"}'
  # The post mentions no one.
  assert_equal "$(jq -c .allowed_mentions "$STUB_FIXTURES/inbox/1569000000000000001.json")" '{"parse":[]}'

  run_bin -0 team-janitor tmp status --json
  assert_equal "$(jq .warning <<<"$output")" true

  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(alerts_posted | wc -l)" 1
}

@test "team-janitor tmp's warning names the day's removals in its post" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  reading 70
  run_bin -0 team-janitor tmp
  assert_equal "$(sed -n 2p <<<"$output")" "posted to #coordinator (message 1569000000000000001): /tmp is 70% full"
  [[ $(alerts_posted) == *"Largest of yours: none. \`team-janitor tmp status\` lists them; today's removals: ~/.local/state/agent-team/janitor/tmp-$(date +%F).md." ]]
}

@test "team-janitor tmp keeps the warning at 46%, closes it with no post at 44%, and posts anew at a later crossing" {
  reading 50
  run_bin -0 team-janitor tmp
  reading 46
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$(jq -r .state <<<"$(tmp_notice)")" posted
  reading 44
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(tmp_notice)" null
  assert_equal "$(alerts_posted | wc -l)" 1
  # At 46% with no notice standing nothing opens.
  reading 46
  run_bin -0 team-janitor tmp
  assert_equal "$(tmp_notice)" null
  reading 55
  run_bin -0 team-janitor tmp
  assert_equal "$output" "posted to #coordinator (message 1569000000000000002): /tmp is 55% full"
  assert_equal "$(alerts_posted | wc -l)" 2
}

@test "team-janitor tmp reminds once 240 minutes have passed since the post, with that run's reading" {
  reading 50
  run_bin -0 team-janitor tmp
  reading 61
  posted_ago 239
  run_bin -0 team-janitor tmp
  assert_equal "$output" ""
  posted_ago 241
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$output" "posted to #coordinator (message 1569000000000000002): /tmp is still 61% full"
  assert_equal "$(alerts_posted | sed -n 2p)" "/tmp on home-pc is still 61% full (9.8 GiB of 16.0 GiB), past 50%; systemd holds each user to 80% of it. Largest of yours: none. \`team-janitor tmp status\` lists them; today's removals: none."
  [[ $(jq -r .reminded <<<"$(tmp_notice)") == 20* ]]
  run_bin -0 team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$(alerts_posted | wc -l)" 2
}

@test "team-janitor tmp's warning says the 80% clause only when the mount holds usrquota" {
  reading 50 tmpfs rw,nosuid,nodev,size=16777216k
  run_bin -0 team-janitor tmp
  assert_equal "$(alerts_posted)" "/tmp on home-pc is 50% full (8.0 GiB of 16.0 GiB), past 50%. Largest of yours: none. \`team-janitor tmp status\` lists them; today's removals: none."
  run_bin -0 team-janitor tmp status --json
  assert_equal "$(jq .quota <<<"$output")" false
}

@test "a warning Discord refuses is said on stderr, fails the run, and is posted by the next run" {
  echo "1 500" >"$STUB_FIXTURES/inbox/fail-post"
  reading 50
  run_bin -1 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" "team-janitor: the post to #coordinator failed (curl: (22) The requested URL returned error: 500); it is tried again next run"
  assert_equal "$(jq -c '{state, posted}' <<<"$(tmp_notice)")" '{"state":"open","posted":null}'

  rm "$STUB_FIXTURES/inbox/fail-post"
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$stderr" ""
  assert_equal "$output" "posted to #coordinator (message 1569000000000000001): /tmp is 50% full"
  assert_equal "$(jq -r .state <<<"$(tmp_notice)")" posted
}

@test "a /tmp that is not a memory file system, or is on macOS, is never judged" {
  reading 90 ext4 rw,relatime
  run_bin -0 --separate-stderr team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(tmp_notice)" null
  run_bin -0 team-janitor tmp status
  assert_equal "$(sed -n 1p <<<"$output")" "/tmp is on ext4, not a memory file system, so it is not judged"
  run_bin -0 team-janitor tmp status --json
  assert_equal "$(jq -c '[.type, .judged, .percent, .warning]' <<<"$output")" '["ext4",false,90,false]'

  reading 90
  as_macos
  run_bin -0 team-janitor tmp
  assert_equal "$output" ""
  assert_equal "$(tmp_notice)" null
  run_bin -0 team-janitor tmp status --json
  assert_equal "$(jq -c '[.type, .judged]' <<<"$output")" '["tmpfs",false]'
  assert_equal "$(alerts_posted)" ""
}

@test "team-janitor tmp --dry-run posts no warning and writes no notice" {
  reading 60
  run_bin -0 team-janitor tmp --dry-run
  assert_equal "$output" ""
  assert_equal "$(alerts_posted)" ""
  [[ ! -e $STATE/notices.json ]]
}

@test "team-janitor tmp reads the largest entries only for status and when a post is due" {
  two_entries
  fails_on_call du
  run_bin -0 team-janitor tmp
  reading 50
  # The post is due, so du is read (and fails, so the post names none).
  run_bin -0 team-janitor tmp
  [[ -s $STUB_CALLS/du.failed ]]
  rm "$STUB_CALLS/du.failed"
  # A run whose warning stands already reads none.
  run_bin -0 team-janitor tmp
  [[ ! -e $STUB_CALLS/du.failed ]]
  reading 10
  run_bin -0 team-janitor tmp
  [[ ! -e $STUB_CALLS/du.failed ]]
  run_bin -0 team-janitor tmp status
  [[ -e $STUB_CALLS/du.failed ]]
}

@test "team-janitor tmp status refuses an argument it does not know" {
  run_bin -2 --separate-stderr team-janitor tmp status --dry-run
  assert_equal "$stderr" "team-janitor: usage: team-janitor tmp [--dry-run] | team-janitor tmp status [--json]"
}

@test "team-janitor --help documents status, the warning and its texts" {
  run_bin -0 team-janitor --help
  assert_contains "$output" "team-janitor tmp status [--json]"
  assert_contains "$output" "team-tmp/1"
  assert_contains "$output" "/tmp on <machine> is 52% full (8.3 GiB of 16.0 GiB), past 50%"
  assert_contains "$output" "/tmp on <machine> is still"
  assert_contains "$output" "posted to #coordinator (message <id>): /tmp is 52% full"
  assert_contains "$output" "TEAM_TMP_DF"
}
