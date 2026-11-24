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
    '{"schema":"team-disk/1","ok":true,"go":{"path":null,"kb":null,"cap_kb":null,"trimmed_today":null},"jobs":{"cleared_today":{"count":1,"kb":'"$kb"'}}}'

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
  assert_equal "$output" "0 job tmps cleared today (0 MB)"
  run_bin -0 team-janitor disk status --json
  assert_equal "$(jq -c . <<<"$output")" \
    '{"schema":"team-disk-status/1","go":{"path":null,"kb":null,"cap_kb":null,"over_cap":null,"trimmed_today":null},"jobs":{"cleared_today":{"count":0,"kb":0}},"last_run":null}'
  [[ ! -e $STATE ]]

  launch T9 builder afaf0001
  launch T9 builder afaf0002
  job afaf0001
  # Both jobs' tmps are alike, so the day's total is twice the first's.
  local kb
  kb=$(($(kb_of afaf0001) * 2))
  run_bin -0 team-janitor disk
  run_bin -0 team-janitor disk status
  assert_equal "$output" "1 job tmp cleared today (2 MB)"
  job afaf0002
  run_bin -0 team-janitor disk
  local at
  at=$(jq -r .at "$RECORD")
  [[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  local before
  before=$(files_state)
  run_bin -0 team-janitor disk status
  assert_equal "$output" "2 job tmps cleared today (4 MB)"
  run_bin -0 team-janitor disk status --json
  assert_equal "$(jq -c '{jobs, last_run}' <<<"$output")" "{\"jobs\":{\"cleared_today\":{\"count\":2,\"kb\":$kb}},\"last_run\":\"$at\"}"
  assert_equal "$(files_state)" "$before"
  # Written whole: no temporary file is left beside it.
  assert_equal "$(find "$STATE/janitor" -name 'disk.json.*')" ""

  # A record of an earlier day counts nothing today.
  jq '.at = "2026-01-01T12:00:00Z"' "$RECORD" >"$RECORD.edit"
  mv "$RECORD.edit" "$RECORD"
  run_bin -0 team-janitor disk status
  assert_equal "$output" "0 job tmps cleared today (0 MB)"
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
}
