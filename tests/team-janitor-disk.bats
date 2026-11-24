#!/usr/bin/env bats
# team-janitor disk: the sweep of the home directory's caches, run for real against a fixture jobs
# tree under the sandbox's HOME ($JOBS, never the real ~/.claude/jobs). Each job is a directory of
# 8 hex digits with a state.json and a tmp holding a file; the ledger's launches say whose it is,
# and the stub claude answers `agents --json --all` from $BATS_TEST_TMPDIR/sessions.json. Each test
# asserts on what is left on disk, on what the run printed, on the day's file and on the record. A
# live tmp is held by a real background sleep, stopped by its pid.

load helpers/common

setup() {
  sandbox
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  JOBS=$HOME/.claude/jobs
  mkdir -p "$JOBS"
  STATE=$HOME/.local/state/agent-team
  DAY_FILE=$STATE/janitor/disk-$(date +%F).md
  RECORD=$STATE/janitor/disk.json
  # The Go build cache is a fixture of the test's own, absent until go_cache makes it.
  GC=$BATS_TEST_TMPDIR/go-build
  export TEAM_GO_CACHE=$GC
  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  stub_script claude <<'EOF'
if [[ $* == 'agents --json --all' ]]; then
  if [[ -e $BATS_TEST_TMPDIR/agents.fail ]]; then
    echo "agents: the background service did not answer" >&2
    exit 1
  fi
  cat "$BATS_TEST_TMPDIR/sessions.json"
  exit 0
fi
exit 3
EOF
}

teardown() {
  stop_background
  chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# Note the process just started in the background ($!), for stop_background.
started() {
  echo "$!" >>"$BATS_TEST_TMPDIR/background"
}

# Stop each background process a test noted, by its pid, and wait for it.
stop_background() {
  local pid
  [[ -f $BATS_TEST_TMPDIR/background ]] || return 0
  while read -r pid; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done <"$BATS_TEST_TMPDIR/background"
  rm -f "$BATS_TEST_TMPDIR/background"
}

# running <pid> <text>: wait until the background process <pid> runs the command whose line holds
# <text>, since until then it is still the test's own shell.
running() {
  local tries=0
  until [[ $(ps -o args= -p "$1") == *"$2"* ]]; do
    tries=$((tries + 1))
    ((tries < 100)) || { echo "running: process $1 never ran '$2'" >&2; return 1; }
    sleep 0.1
  done
}

# job <id> [<minutes since its last change>]: a job directory whose state.json was updated
# <minutes> ago (5), and whose tmp, mode 700, holds a 2 MB file and a directory with a read-only
# file in it.
job() {
  local dir=$JOBS/$1
  mkdir -p "$dir/tmp/shots"
  chmod 700 "$dir/tmp"
  head -c 2097152 /dev/zero >"$dir/tmp/data"
  echo shot >"$dir/tmp/shots/one.png"
  chmod -R a-w "$dir/tmp/shots"
  jq -n --arg at "$(date -u -d "${2:-5} minutes ago" +%FT%T.000Z)" '{state: "done", updatedAt: $at}' >"$dir/state.json"
}

# launch <task> <role> <id>: the task opened and a launch of <role> with session <id> in the ledger.
launch() {
  grep -q "\"task\":\"$1\",\"event\":\"opened\"" "$TEAM_HOME/ledger.jsonl" || opened_task "$1"
  jq -cn --arg task "$1" --arg role "$2" --arg id "$3" \
    '{ts: "2026-01-02T00:00:00Z", task: $task, event: "launch", role: $role, session: $id, worktree: "/w/\($task)", toolkits: []}' \
    >>"$TEAM_HOME/ledger.jsonl"
}

# closed <task>: the task closed in the ledger.
closed() {
  jq -cn --arg task "$1" '{ts: "2026-01-03T00:00:00Z", task: $task, event: "closed", archive: [], returned: [], kept: []}' \
    >>"$TEAM_HOME/ledger.jsonl"
}

# listed <id> <state> [<pid>]: Claude Code lists job <id> in <state>, with <pid> when given.
listed() {
  jq --arg id "$1" --arg state "$2" --arg pid "${3:-}" \
    '. + [{id: $id, cwd: "/w", kind: "background", startedAt: 1761100000000, sessionId: "\($id)-0000-0000-0000-000000000000",
      state: $state} + (if $pid == "" then {} else {pid: ($pid | tonumber)} end)]' \
    "$BATS_TEST_TMPDIR/sessions.json" >"$BATS_TEST_TMPDIR/sessions.new"
  mv "$BATS_TEST_TMPDIR/sessions.new" "$BATS_TEST_TMPDIR/sessions.json"
}

# The kilobytes du counts in the tmps of jobs <id>..., summed, as the run measures them before it
# clears them: kb_of <id>...
kb_of() {
  local id total=0 kb
  for id in "$@"; do
    kb=$(du -sk "$JOBS/$id/tmp" | cut -f 1)
    total=$((total + kb))
  done
  echo "$total"
}

# Whether job <id>'s tmp is there, empty, with its mode 700 kept.
cleared() {
  [[ -d $JOBS/$1/tmp && $(stat -c %a "$JOBS/$1/tmp") == 700 ]] || { echo "the tmp of $1 is gone or its mode changed" >&2; return 1; }
  assert_equal "$(find "$JOBS/$1/tmp" -mindepth 1)" ""
}

# Whether job <id>'s tmp still holds its two entries.
kept() {
  [[ -f $JOBS/$1/tmp/data && -f $JOBS/$1/tmp/shots/one.png ]] || { echo "the tmp of $1 lost its entries" >&2; return 1; }
}

@test "team-janitor disk clears the tmp of a closed task's session, keeping the directory, and records it" {
  launch T422 builder 0f178ea8
  closed T422
  job 0f178ea8
  listed 0f178ea8 "done"
  local kb
  kb=$(kb_of 0f178ea8)

  run_bin -0 --separate-stderr team-janitor disk
  assert_equal "$output" "cleared the job tmp of T422's builder 0f178ea8 (2 MB; T422 is closed)"
  assert_equal "$stderr" ""
  cleared 0f178ea8
  # The job's own files are left to Claude Code.
  [[ -f $JOBS/0f178ea8/state.json ]]
  assert_equal "$(head -n 1 "$DAY_FILE")" "# Disk cleared on home-pc, $(date +%F)"
  grep -Eq "^- [0-9]{2}:[0-9]{2} cleared the job tmp of T422's builder 0f178ea8 \(2 MB; T422 is closed\)$" "$DAY_FILE"
  assert_equal "$(jq -c '{schema, ok, go, jobs}' "$RECORD")" \
    '{"schema":"team-disk/1","ok":true,"go":{"path":null,"kb":null,"cap_kb":10485760,"trimmed_today":{"entries":0,"kb":0},"over_cap_said":null},"jobs":{"cleared_today":{"count":1,"kb":'"$kb"'}}}'

  # The next run has nothing to clear and prints nothing.
  run_bin -0 team-janitor disk
  assert_equal "$output" ""
}

@test "team-janitor disk clears an open task's session that is not listed, stopped, or done or failed and idle past 24 hours" {
  launch T9 builder aaaa0001
  launch T9 reviewer aaaa0002
  launch T9 planner aaaa0003
  launch T9 builder aaaa0004
  launch T9 builder aaaa0005
  job aaaa0001
  job aaaa0002
  listed aaaa0002 stopped
  job aaaa0003 $((25 * 60))
  listed aaaa0003 "done"
  job aaaa0004 $((26 * 60 + 10))
  listed aaaa0004 failed
  # Settled 23 hours ago: kept.
  job aaaa0005 $((23 * 60))
  listed aaaa0005 "done"
  local kb
  kb=$(kb_of aaaa0001 aaaa0002 aaaa0003 aaaa0004)

  run_bin -0 --separate-stderr team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder aaaa0001 (2 MB; not listed by Claude Code)
cleared the job tmp of T9's reviewer aaaa0002 (2 MB; stopped)
cleared the job tmp of T9's planner aaaa0003 (2 MB; done and idle 25 h)
cleared the job tmp of T9's builder aaaa0004 (2 MB; failed and idle 26 h)"
  assert_equal "$stderr" ""
  cleared aaaa0001
  cleared aaaa0002
  cleared aaaa0003
  cleared aaaa0004
  kept aaaa0005
  assert_equal "$(jq -c .jobs.cleared_today "$RECORD")" '{"count":4,"kb":'"$kb"'}'
}

@test "team-janitor disk keeps a working, blocked, unknown-state, pid-holding or unreadable-state session, whatever its age" {
  launch T9 builder bbbb0001
  launch T9 builder bbbb0002
  launch T9 builder bbbb0003
  launch T9 builder bbbb0004
  launch T9 builder bbbb0005
  launch T8 builder bbbb0006
  closed T8
  local old=$((3 * 24 * 60))
  job bbbb0001 "$old"
  listed bbbb0001 working
  job bbbb0002 "$old"
  listed bbbb0002 blocked
  job bbbb0003 "$old"
  listed bbbb0003 resting
  # Listed with a pid, even settled long ago: a process runs it.
  job bbbb0004 "$old"
  listed bbbb0004 "done" 4242
  # No readable state.json: kept, even unlisted.
  job bbbb0005 "$old"
  rm "$JOBS/bbbb0005/state.json"
  # Even a closed task's session is kept while it has a pid.
  job bbbb0006 "$old"
  listed bbbb0006 "done" 4243

  run_bin -0 --separate-stderr team-janitor disk
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  for id in bbbb0001 bbbb0002 bbbb0003 bbbb0004 bbbb0005 bbbb0006; do kept "$id"; done
}

@test "team-janitor disk reads a job's last change from state.json's mtime when it has no updatedAt" {
  launch T9 builder cccc0001
  launch T9 builder cccc0002
  job cccc0001
  echo '{"state": "done"}' >"$JOBS/cccc0001/state.json"
  touch -d '30 hours ago' "$JOBS/cccc0001/state.json"
  listed cccc0001 "done"
  job cccc0002
  echo 'not json' >"$JOBS/cccc0002/state.json"
  touch -d '2 hours ago' "$JOBS/cccc0002/state.json"
  listed cccc0002 "done"

  run_bin -0 team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder cccc0001 (2 MB; done and idle 30 h)"
  kept cccc0002
}

@test "the 24 hours of TEAM_DISK_JOB_IDLE_MINUTES is a whole number of minutes" {
  launch T9 builder cccc0003
  job cccc0003 90
  listed cccc0003 "done"

  TEAM_DISK_JOB_IDLE_MINUTES=60 run_bin -0 team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder cccc0003 (2 MB; done and idle 90 min)"

  TEAM_DISK_JOB_IDLE_MINUTES=soon run_bin -1 team-janitor disk
  assert_contains "$output" "TEAM_DISK_JOB_IDLE_MINUTES is 'soon', not a whole number of minutes"
}

@test "team-janitor disk never touches a session no planner, builder or reviewer launch names" {
  # The coordinator's, the assistant's and Daniel's own have no launch; an ops session's is the
  # ops role's, left to team-ops-end.
  launch T7 ops dddd0001
  closed T7
  job dddd0001
  job dddd0002
  job dddd0003
  listed dddd0003 stopped

  run_bin -0 --separate-stderr team-janitor disk
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  kept dddd0001
  kept dddd0002
  kept dddd0003
}

@test "team-janitor disk keeps a tmp a live process names and clears its twin once the process ended" {
  launch T9 builder eeee0001
  launch T9 builder eeee0002
  job eeee0001 $((2 * 24 * 60))
  listed eeee0001 "done"
  job eeee0002 $((2 * 24 * 60))
  listed eeee0002 "done"
  (cd "$JOBS/eeee0001/tmp" && exec sleep 300) >/dev/null 2>&1 3>&- &
  started
  running "$!" "sleep 300"

  run_bin -0 team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder eeee0002 (2 MB; done and idle 48 h)"
  kept eeee0001

  stop_background
  run_bin -0 team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder eeee0001 (2 MB; done and idle 48 h)"
}

@test "team-janitor disk never follows a link and skips a name that is not 8 lowercase hex digits" {
  launch T9 builder ffff0001
  launch T9 builder ffff0002
  launch T9 builder ffff0003
  local target=$BATS_TEST_TMPDIR/target
  mkdir -p "$target/tmp"
  echo keep >"$target/tmp/file"
  echo '{"state": "done", "updatedAt": "2026-01-01T00:00:00Z"}' >"$target/state.json"
  # A job directory that is a link to another directory.
  ln -s "$target" "$JOBS/ffff0001"
  # A tmp that is a link.
  mkdir "$JOBS/ffff0002"
  echo '{"state": "done", "updatedAt": "2026-01-01T00:00:00Z"}' >"$JOBS/ffff0002/state.json"
  ln -s "$target/tmp" "$JOBS/ffff0002/tmp"
  # Names not a job's.
  job FFFF0003
  job ffff00031

  run_bin -0 --separate-stderr team-janitor disk
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  [[ -f $target/tmp/file ]]
  kept FFFF0003
  kept ffff00031
}

@test "a session list or ledger that cannot be read clears nothing and exits 1 saying why" {
  launch T9 builder abab0001
  job abab0001
  touch "$BATS_TEST_TMPDIR/agents.fail"

  run_bin -1 --separate-stderr team-janitor disk
  assert_equal "$output" ""
  assert_equal "$stderr" "team-janitor: claude agents --json --all failed: agents: the background service did not answer, so no job tmp was cleared"
  kept abab0001
  assert_equal "$(jq .ok "$RECORD")" false

  # A list that is not one.
  rm "$BATS_TEST_TMPDIR/agents.fail"
  echo '{"error": "nope"}' >"$BATS_TEST_TMPDIR/sessions.json"
  run_bin -1 --separate-stderr team-janitor disk
  assert_equal "$stderr" "team-janitor: claude agents --json --all printed no list of sessions, so no job tmp was cleared"
  kept abab0001

  echo '[]' >"$BATS_TEST_TMPDIR/sessions.json"
  mv "$TEAM_HOME/ledger.jsonl" "$TEAM_HOME/ledger.moved"
  run_bin -1 --separate-stderr team-janitor disk
  assert_equal "$stderr" "team-janitor: could not read the ledger, $TEAM_HOME/ledger.jsonl, so no job tmp was cleared"
  kept abab0001

  mv "$TEAM_HOME/ledger.moved" "$TEAM_HOME/ledger.jsonl"
  run_bin -0 team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder abab0001 (2 MB; not listed by Claude Code)"
}

@test "a broken session list fails the run on a quiet machine too, with nothing to clear" {
  touch "$BATS_TEST_TMPDIR/agents.fail"
  run_bin -1 --separate-stderr team-janitor disk
  assert_equal "$output" ""
  assert_equal "$stderr" "team-janitor: claude agents --json --all failed: agents: the background service did not answer, so no job tmp was cleared"
  assert_equal "$(jq .ok "$RECORD")" false
}

@test "a clearing that fails is said on stderr, fails the run, and the other jobs go on" {
  launch T9 builder acac0001
  launch T9 builder acac0002
  job acac0001
  job acac0002
  fails_on_call rm acac0001
  local kb
  kb=$(kb_of acac0002)

  run_bin -1 --separate-stderr team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder acac0002 (2 MB; not listed by Claude Code)"
  assert_equal "$stderr" "team-janitor: could not clear $JOBS/acac0001/tmp: no reason given"
  kept acac0001
  cleared acac0002
  assert_equal "$(jq -c '{ok, jobs}' "$RECORD")" '{"ok":false,"jobs":{"cleared_today":{"count":1,"kb":'"$kb"'}}}'
}

@test "team-janitor disk --dry-run says what it would clear, changes nothing and takes no lock" {
  launch T9 builder adad0001
  job adad0001
  local before
  # What the stub claude logs of its calls aside.
  before=$(files_state | grep -v " $STUB_CALLS/")

  run_bin -0 --separate-stderr team-janitor disk --dry-run
  assert_equal "$output" "would clear the job tmp of T9's builder adad0001 (2 MB; not listed by Claude Code)"
  assert_equal "$stderr" ""
  kept adad0001
  assert_equal "$(files_state | grep -v " $STUB_CALLS/")" "$before"
  [[ ! -e $STATE ]]
}

@test "a second team-janitor disk while one holds the lock is skipped with exit 0" {
  launch T9 builder aeae0001
  job aeae0001
  mkdir -p "$STATE"
  (exec 9>"$STATE/disk.lock" && flock -n 9 && exec sleep 300) >/dev/null 2>&1 3>&- &
  started
  running "$!" "sleep 300"

  run_bin -0 --separate-stderr team-janitor disk
  assert_equal "$output" "another team-janitor disk is running; skipped"
  assert_equal "$stderr" ""
  kept aeae0001
  [[ ! -e $RECORD ]]

  # A dry run only reads, so it waits on no one.
  run_bin -0 team-janitor disk --dry-run
  assert_equal "$output" "would clear the job tmp of T9's builder aeae0001 (2 MB; not listed by Claude Code)"

  stop_background
  run_bin -0 team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder aeae0001 (2 MB; not listed by Claude Code)"
}

@test "the record adds up the day's clearings, starts again on a new day, and status reads it back, changing nothing" {
  run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache at $GC; 0 job tmps cleared today (0 MB)"
  run_bin -0 team-janitor disk status --json
  assert_equal "$(jq -c . <<<"$output")" \
    "{\"schema\":\"team-disk-status/1\",\"go\":{\"path\":null,\"kb\":null,\"cap_kb\":10485760,\"over_cap\":false,\"trimmed_today\":{\"entries\":0,\"kb\":0},\"none\":\"no Go build cache at $GC\"},"'"jobs":{"cleared_today":{"count":0,"kb":0}},"last_run":null}'
  [[ ! -e $STATE ]]

  launch T9 builder afaf0001
  launch T9 builder afaf0002
  job afaf0001
  # Both jobs' tmps are alike, so the day's total is twice the first's.
  local kb
  kb=$(($(kb_of afaf0001) * 2))
  run_bin -0 team-janitor disk
  run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache at $GC; 1 job tmp cleared today (2 MB)"
  job afaf0002
  run_bin -0 team-janitor disk
  local at
  at=$(jq -r .at "$RECORD")
  [[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  local before
  before=$(files_state)
  run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache at $GC; 2 job tmps cleared today (4 MB)"
  run_bin -0 team-janitor disk status --json
  assert_equal "$(jq -c '{jobs, last_run}' <<<"$output")" "{\"jobs\":{\"cleared_today\":{\"count\":2,\"kb\":$kb}},\"last_run\":\"$at\"}"
  assert_equal "$(files_state)" "$before"
  # Written whole: no temporary file is left beside it.
  assert_equal "$(find "$STATE/janitor" -name 'disk.json.*')" ""

  # A record of an earlier day counts nothing today.
  jq '.at = "2026-01-01T12:00:00Z"' "$RECORD" >"$RECORD.edit"
  mv "$RECORD.edit" "$RECORD"
  run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache at $GC; 0 job tmps cleared today (0 MB)"
  run_bin -0 team-janitor disk
  assert_equal "$(jq -c .jobs.cleared_today "$RECORD")" '{"count":0,"kb":0}'
}

@test "a run after a half-cleared tmp clears the rest" {
  launch T9 builder baba0001
  job baba0001
  rm "$JOBS/baba0001/tmp/data"

  run_bin -0 team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder baba0001 (0 MB; not listed by Claude Code)"
  cleared baba0001
  jq -e . "$RECORD" >/dev/null
}

@test "team-janitor disk with no jobs root has nothing to do, and refuses an unknown argument" {
  rm -rf "${JOBS:?}"
  run_bin -0 team-janitor disk
  assert_equal "$output" ""
  run_bin -2 team-janitor disk --now
  assert_contains "$output" "usage: team-janitor disk [--dry-run] | team-janitor disk status [--json]"
  run_bin -2 team-janitor disk status --yaml
  assert_contains "$output" "usage: team-janitor disk"
}

@test "team-janitor --help documents the disk subcommand" {
  run_bin -0 team-janitor --help
  assert_contains "$output" "team-janitor disk [--dry-run]"
  assert_contains "$output" "team-janitor disk status [--json]"
  assert_contains "$output" "cleared the job tmp of T422's builder 0f178ea8 (9.5 GiB; done and idle 26 h)"
  assert_contains "$output" "trimmed the Go build cache"
  assert_contains "$output" "TEAM_GO_CACHE_CAP_KB"
  assert_contains "$output" "TEAM_GO_CACHE_KEEP_MINUTES"
}

# The Go build cache part. A fixture cache at $GC holds Go's README and trim.txt and entries made
# by go_entry, each aged with touch -d; its sizes are read with du, as the run reads them.

# go_cache [<README first line>]: the fixture cache, with Go's README unless another first line is
# given, and trim.txt and testexpire.txt, all last modified 30 days ago.
go_cache() {
  mkdir -p "$GC"
  printf '%s\n%s\n' "${1:-This directory holds cached build artifacts from the Go build system.}" \
    'Run "go clean -cache" if the directory is getting too large.' >"$GC/README"
  echo 1763000000 >"$GC/trim.txt"
  echo 1763000000 >"$GC/testexpire.txt"
  touch -d '30 days ago' "$GC/README" "$GC/trim.txt" "$GC/testexpire.txt"
}

# go_entry <path under the cache> <kb> <minutes since last use>: a file of <kb> kilobytes, or with
# a trailing / a directory holding one, last modified <minutes> ago.
go_entry() {
  local path=$GC/${1%/}
  mkdir -p "${path%/*}"
  if [[ $1 == */ ]]; then
    mkdir -p "$path"
    head -c $(($2 * 1024)) /dev/zero >"$path/reapmain"
    touch -d "$3 minutes ago" "$path/reapmain"
  else
    head -c $(($2 * 1024)) /dev/zero >"$path"
  fi
  touch -d "$3 minutes ago" "$path"
}

# go_cap <kb>: the cap the runs of this test take (TEAM_GO_CACHE_CAP_KB).
go_cap() {
  export TEAM_GO_CACHE_CAP_KB=$1
}

# <kilobytes> as the run says a size below 1024 MB.
mb() {
  echo "$((($1 + 512) / 1024)) MB"
}

# The cache's kilobytes, as du counts them.
gc_kb() {
  du -sk "$GC" | cut -f 1
}

# The UTC minute an entry <path under the cache> was last modified, as the trim line names it.
used_at() {
  date -u -d "@$(stat -c %Y "$GC/$1")" +%FT%H:%MZ
}

# ten_old_two_new: ten 400 KB entries used 10 to 1 days ago, the oldest a -d directory, and two
# used in the last hour; and, all old, what is not an entry: a file of another name, an entry
# under a directory that is not two hex digits, an uppercase name, a link to a file outside the
# cache, and a two-hex directory that is a link to one outside it.
ten_old_two_new() {
  local i
  go_cache
  go_entry 0a/0a000001-d/ 400 $((10 * 1440))
  for i in 2 3 4 5 6 7 8 9; do go_entry "0$i/0${i}00000$i-a" 400 $(((11 - i) * 1440)); done
  go_entry 0b/0b000010-d 400 1440
  go_entry ff/ff000011-a 400 30
  go_entry ff/ff000012-d 400 50
  go_entry 0a/notes.txt 1 $((30 * 1440))
  go_entry zz/abcd-a 1 $((30 * 1440))
  go_entry 0a/ABCD-a 1 $((30 * 1440))
  mkdir -p "$BATS_TEST_TMPDIR/outside/dir"
  echo target >"$BATS_TEST_TMPDIR/outside/0c000001-a"
  echo target >"$BATS_TEST_TMPDIR/outside/dir/0d000001-a"
  touch -d '30 days ago' "$BATS_TEST_TMPDIR/outside/0c000001-a" "$BATS_TEST_TMPDIR/outside/dir/0d000001-a"
  mkdir -p "$GC/0c"
  ln -s "$BATS_TEST_TMPDIR/outside/0c000001-a" "$GC/0c/0c000001-a"
  ln -s "$BATS_TEST_TMPDIR/outside/dir" "$GC/0d"
  touch -h -d '30 days ago' "$GC/0c/0c000001-a" "$GC/0d"
}

# Whether what ten_old_two_new made that is not an entry is all there.
not_entries_kept() {
  local path
  for path in README trim.txt testexpire.txt 0a/notes.txt zz/abcd-a 0a/ABCD-a; do
    [[ -f $GC/$path ]] || { echo "$path is gone" >&2; return 1; }
  done
  [[ -L $GC/0c/0c000001-a && -L $GC/0d ]] || { echo "a link is gone" >&2; return 1; }
  [[ -f $BATS_TEST_TMPDIR/outside/0c000001-a && -f $BATS_TEST_TMPDIR/outside/dir/0d000001-a ]] ||
    { echo "a link's target is gone" >&2; return 1; }
}

@test "over its cap, team-janitor disk trims the Go build cache to 80% of it, least recently used first, keeping recent entries and what is not an entry" {
  ten_old_two_new
  local before cap after i
  before=$(gc_kb)
  # 1000 KB over the cap, so the trim to 80% of it takes the five oldest entries.
  cap=$((before - 1000))
  go_cap "$cap"
  # The newest of the five it removes.
  local since
  since=$(used_at 05/05000005-a)

  run_bin -0 --separate-stderr team-janitor disk
  after=$(gc_kb)
  assert_equal "$stderr" ""
  assert_equal "$output" \
    "trimmed the Go build cache $GC from $(mb "$before") to $(mb "$after"): 5 entries unused since $since"
  ((after <= cap * 80 / 100))
  [[ ! -e $GC/0a/0a000001-d ]]
  for i in 2 3 4 5; do [[ ! -e $GC/0$i/0${i}00000$i-a ]]; done
  for i in 6 7 8 9; do [[ -f $GC/0$i/0${i}00000$i-a ]]; done
  [[ -f $GC/0b/0b000010-d && -f $GC/ff/ff000011-a && -f $GC/ff/ff000012-d ]]
  not_entries_kept
  grep -Eq "^- [0-9]{2}:[0-9]{2} trimmed the Go build cache $GC from " "$DAY_FILE"
  assert_equal "$(jq -c .go "$RECORD")" \
    "{\"path\":\"$GC\",\"kb\":$after,\"cap_kb\":$cap,\"trimmed_today\":{\"entries\":5,\"kb\":$((before - after))},\"over_cap_said\":null}"
  assert_equal "$(jq .ok "$RECORD")" true

  run_bin -0 team-janitor disk status
  assert_equal "$output" "Go build cache $(mb "$after") of its $(mb "$cap") cap at $GC; 0 job tmps cleared today (0 MB)"
  run_bin -0 team-janitor disk status --json
  assert_equal "$(jq -c .go <<<"$output")" \
    "{\"path\":\"$GC\",\"kb\":$after,\"cap_kb\":$cap,\"over_cap\":false,\"trimmed_today\":{\"entries\":5,\"kb\":$((before - after))},\"none\":null}"

  # Under the cap now, a second run trims nothing, and the day's total stands.
  run_bin -0 team-janitor disk
  assert_equal "$output" ""
  assert_equal "$(jq -c .go.trimmed_today "$RECORD")" "{\"entries\":5,\"kb\":$((before - after))}"
}

@test "at or under its cap, the Go build cache is left whole and the run prints nothing; status says it against the cap" {
  ten_old_two_new
  local kb
  kb=$(gc_kb)
  go_cap "$kb"

  run_bin -0 --separate-stderr team-janitor disk
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(gc_kb)" "$kb"
  [[ -d $GC/0a/0a000001-d ]]
  [[ ! -e $DAY_FILE ]]
  assert_equal "$(jq -c .go "$RECORD")" \
    "{\"path\":\"$GC\",\"kb\":$kb,\"cap_kb\":$kb,\"trimmed_today\":{\"entries\":0,\"kb\":0},\"over_cap_said\":null}"

  # Status measures the cache now, so a lower cap reads as over it, changing nothing.
  local before
  before=$(files_state)
  TEAM_GO_CACHE_CAP_KB=1024 run_bin -0 team-janitor disk status
  assert_equal "$output" "Go build cache $(mb "$kb") of its 1 MB cap at $GC; 0 job tmps cleared today (0 MB)"
  TEAM_GO_CACHE_CAP_KB=1024 run_bin -0 team-janitor disk status --json
  assert_equal "$(jq -c '.go | {kb, cap_kb, over_cap}' <<<"$output")" "{\"kb\":$kb,\"cap_kb\":1024,\"over_cap\":true}"
  assert_equal "$(files_state)" "$before"
  assert_equal "$(gc_kb)" "$kb"
  # With its default cap, the line says 10.0 GiB.
  unset TEAM_GO_CACHE_CAP_KB
  run_bin -0 team-janitor disk status
  assert_equal "$output" "Go build cache $(mb "$kb") of its 10.0 GiB cap at $GC; 0 job tmps cleared today (0 MB)"
}

@test "when only recently used entries keep the Go build cache over its cap, the run says so once a local day, failing nothing" {
  local i
  go_cache
  go_entry 01/01000001-a 400 $((3 * 1440))
  go_entry 02/02000002-a 400 $((2 * 1440))
  for i in 3 4 5 6 7 8; do go_entry "0$i/0${i}00000$i-a" 400 30; done
  local before cap since after
  before=$(gc_kb)
  # Removing both old entries still leaves it over the cap.
  cap=$((before - 4 * 400))
  go_cap "$cap"
  since=$(used_at 02/02000002-a)

  run_bin -0 --separate-stderr team-janitor disk
  after=$(gc_kb)
  assert_equal "$stderr" ""
  assert_equal "$output" "trimmed the Go build cache $GC from $(mb "$before") to $(mb "$after"): 2 entries unused since $since
the Go build cache $GC holds $(mb "$after"), over its $(mb "$cap") cap, the rest used in the last 2 h; kept"
  for i in 3 4 5 6 7 8; do [[ -f $GC/0$i/0${i}00000$i-a ]]; done
  grep -Fq "over its $(mb "$cap") cap, the rest used in the last 2 h; kept" "$DAY_FILE"
  assert_equal "$(jq -r .go.over_cap_said "$RECORD")" "$(date +%F)"
  assert_equal "$(jq .ok "$RECORD")" true

  # Said once a day: the next run is quiet.
  run_bin -0 team-janitor disk
  assert_equal "$output" ""
  assert_equal "$(jq -r .go.over_cap_said "$RECORD")" "$(date +%F)"
  run_bin -0 team-janitor disk status --json
  assert_equal "$(jq .go.over_cap <<<"$output")" true

  # Said on an earlier day: said again.
  jq '.go.over_cap_said = "2026-01-01"' "$RECORD" >"$RECORD.edit"
  mv "$RECORD.edit" "$RECORD"
  run_bin -0 team-janitor disk
  assert_equal "$output" "the Go build cache $GC holds $(mb "$after"), over its $(mb "$cap") cap, the rest used in the last 2 h; kept"

  # TEAM_GO_CACHE_KEEP_MINUTES replaces the 2 hours: kept for 10 minutes only, the rest may go.
  TEAM_GO_CACHE_KEEP_MINUTES=10 run_bin -0 team-janitor disk
  assert_contains "$output" "trimmed the Go build cache $GC from "
  (($(gc_kb) <= cap * 80 / 100))
}

@test "a directory without Go's README is not trimmed: the run names it, exits 1, and the job part still runs" {
  launch T9 builder abab0001
  job abab0001
  mkdir -p "$GC/01"
  head -c 409600 /dev/zero >"$GC/01/01000001-a"
  touch -d '3 days ago' "$GC/01/01000001-a"
  go_cap 1

  run_bin -1 --separate-stderr team-janitor disk
  assert_equal "$output" "cleared the job tmp of T9's builder abab0001 (2 MB; not listed by Claude Code)"
  assert_equal "$stderr" "team-janitor: $GC is not a Go build cache (no Go README); not trimmed"
  [[ -f $GC/01/01000001-a ]]
  assert_equal "$(jq -c '{ok, path: .go.path}' "$RECORD")" '{"ok":false,"path":null}'
  run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache at $GC (no Go README); 1 job tmp cleared today (2 MB)"

  # A README of another first line is no Go README either.
  go_cache "This directory holds something else."
  run_bin -1 --separate-stderr team-janitor disk
  assert_equal "$stderr" "team-janitor: $GC is not a Go build cache (no Go README); not trimmed"
  [[ -f $GC/01/01000001-a ]]
}

@test "a session list that cannot be read still lets the Go part trim, and the run exits 1" {
  launch T9 builder abab0002
  job abab0002
  touch "$BATS_TEST_TMPDIR/agents.fail"
  go_cache
  go_entry 01/01000001-a 400 $((3 * 1440))
  go_entry 02/02000002-a 400 $((2 * 1440))
  go_cap $(($(gc_kb) - 400))

  run_bin -1 --separate-stderr team-janitor disk
  assert_contains "$output" "trimmed the Go build cache $GC from "
  assert_contains "$stderr" "so no job tmp was cleared"
  kept abab0002
  [[ ! -e $GC/01/01000001-a ]]
  assert_equal "$(jq -c '{ok, entries: .go.trimmed_today.entries}' "$RECORD")" '{"ok":false,"entries":2}'
}

@test "team-janitor disk --dry-run says what it would trim and removes nothing" {
  ten_old_two_new
  local before cap old i
  before=$(gc_kb)
  cap=$((before - 1000))
  go_cap "$cap"
  # The five oldest entries' kilobytes, as the trim counts them.
  old=$(du -sk "$GC/0a/0a000001-d" "$GC"/0[2-5]/0[2-5]00000[2-5]-a | awk '{ kb += $1 } END { print kb }')
  local since
  since=$(used_at 05/05000005-a)

  run_bin -0 --separate-stderr team-janitor disk --dry-run
  assert_equal "$stderr" ""
  assert_equal "$output" "would trim the Go build cache $GC from $(mb "$before") to $(mb $((before - old))): 5 entries unused since $since"
  assert_equal "$(gc_kb)" "$before"
  for i in 2 3 4 5; do [[ -f $GC/0$i/0${i}00000$i-a ]]; done
  [[ ! -e $STATE ]]
}

@test "the Go build cache is TEAM_GO_CACHE, else go env GOCACHE, else Go's default; off, empty or missing is no Go build cache and no failure" {
  stub_command go
  stub_script go <<'STUB'
if [[ $* == 'env GOCACHE' ]]; then
  [[ ! -e $BATS_TEST_TMPDIR/go.fail ]] || exit 1
  cat "$BATS_TEST_TMPDIR/gocache"
  exit 0
fi
exit 3
STUB
  go_cache
  echo "$BATS_TEST_TMPDIR/from-go-env" >"$BATS_TEST_TMPDIR/gocache"

  # TEAM_GO_CACHE wins over go env.
  run_bin -0 team-janitor disk status
  assert_equal "$output" "Go build cache $(mb "$(gc_kb)") of its 10.0 GiB cap at $GC; 0 job tmps cleared today (0 MB)"
  # Set but empty, it is off.
  TEAM_GO_CACHE='' run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache (GOCACHE is off); 0 job tmps cleared today (0 MB)"

  unset TEAM_GO_CACHE
  echo "$GC" >"$BATS_TEST_TMPDIR/gocache"
  run_bin -0 team-janitor disk status
  assert_equal "$output" "Go build cache $(mb "$(gc_kb)") of its 10.0 GiB cap at $GC; 0 job tmps cleared today (0 MB)"
  # go env names the cache the run trims too.
  go_entry 01/01000001-a 400 $((3 * 1440))
  go_entry 02/02000002-a 400 $((2 * 1440))
  TEAM_GO_CACHE_CAP_KB=$(($(gc_kb) - 400)) run_bin -0 team-janitor disk
  assert_contains "$output" "trimmed the Go build cache $GC from "
  [[ ! -e $GC/01/01000001-a ]]

  echo off >"$BATS_TEST_TMPDIR/gocache"
  run_bin -0 --separate-stderr team-janitor disk
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  run_bin -0 team-janitor disk status --json
  assert_equal "$(jq -c .go <<<"$output")" \
    '{"path":null,"kb":null,"cap_kb":10485760,"over_cap":false,"trimmed_today":{"entries":2,"kb":'"$(jq .go.trimmed_today.kb "$RECORD")"'},"none":"no Go build cache (GOCACHE is off)"}'
  : >"$BATS_TEST_TMPDIR/gocache"
  run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache (GOCACHE is off); 0 job tmps cleared today (0 MB)"

  # Where go env does not answer, Go's own default: GOCACHE, else the user cache directory.
  touch "$BATS_TEST_TMPDIR/go.fail"
  stub_command uname
  stub_reply uname Linux
  GOCACHE=$GC run_bin -0 team-janitor disk status
  assert_equal "$output" "Go build cache $(mb "$(gc_kb)") of its 10.0 GiB cap at $GC; 0 job tmps cleared today (0 MB)"
  XDG_CACHE_HOME=$BATS_TEST_TMPDIR/xdg run_bin -0 --separate-stderr team-janitor disk
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache at $HOME/.cache/go-build; 0 job tmps cleared today (0 MB)"
  XDG_CACHE_HOME=$BATS_TEST_TMPDIR/xdg run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache at $BATS_TEST_TMPDIR/xdg/go-build; 0 job tmps cleared today (0 MB)"
  as_macos
  run_bin -0 team-janitor disk status
  assert_equal "$output" "no Go build cache at $HOME/Library/Caches/go-build; 0 job tmps cleared today (0 MB)"
}

@test "the Go cap and keep window are whole numbers" {
  TEAM_GO_CACHE_CAP_KB=10G run_bin -1 team-janitor disk
  assert_contains "$output" "TEAM_GO_CACHE_CAP_KB is '10G', not a whole number of kilobytes"
  TEAM_GO_CACHE_CAP_KB=10G run_bin -1 team-janitor disk status
  assert_contains "$output" "TEAM_GO_CACHE_CAP_KB is '10G'"
  TEAM_GO_CACHE_KEEP_MINUTES=2h run_bin -1 team-janitor disk
  assert_contains "$output" "TEAM_GO_CACHE_KEEP_MINUTES is '2h', not a whole number of minutes"
}
