#!/usr/bin/env bats
# team-timers' disk step: on the holder after the tmp step and before the inbox step, the real
# team-janitor disk, whose job part reads a fixture jobs tree under the sandbox's HOME ($JOBS,
# never the machine's ~/.claude/jobs) and whose Go part trims a fixture Go build cache of the
# test's own ($GC, TEAM_GO_CACHE, absent until go_cache makes it), never the machine's. The
# heartbeat suite's setup, as tests/team-timers-tmp.bats has it: home-pc holds the lease on a bare
# origin, the stub claude lists the coordinator and the assistant (its answer to agents --json
# --all too), a usage read of the model windows was just taken, the service managers are fakes,
# GitHub is the heartbeat stub and Discord the inbox helper's fake. There is no stack.json: the
# step has no setting.

load helpers/common
load helpers/inbox
load helpers/github-api

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stub_reply claude '[{"id": "c0ffee00", "name": "coordinator", "status": "idle"}, {"id": "a5515700", "name": "assistant", "status": "idle"}]'
  origin=$(hold_lease home-pc)
  usage_read_now
  fake_service_managers
  github_heartbeat_stub
  stub_command uname
  stub_reply uname Linux
  state=$HOME/.local/state/agent-team
  log=$state/heartbeat.log
  inbox_discord alerts
  inbox_guild_kept
  TMP_ROOT=$TEAM_SYSTEM_ROOT/tmp
  mkdir -p "$TMP_ROOT"
  export TEAM_TMP_DF=$BATS_TEST_TMPDIR/df
  printf 'tmpfs 17179869184 1717986919 rw,nosuid,nodev,size=16777216k,usrquota\n' >"$TEAM_TMP_DF"
  JOBS=$HOME/.claude/jobs
  GC=$BATS_TEST_TMPDIR/go-build
  export TEAM_GO_CACHE=$GC
  export TEAM_TIMERS_RUN_SECONDS=120
}

# Let bats remove what a test made read-only.
teardown() {
  chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# The steps a run's output logged, in order, each run of lines once: steps <output>
steps() {
  sed -E 's/^[^ ]+ ([a-z]+): .*$/\1/' <<<"$1" | uniq | paste -sd ' '
}

# The disk step's lines of <output>, each without its time and step.
disk_lines() {
  sed -nE 's/^[^ ]+ disk: //p' <<<"$1"
}

# A team-janitor tmp leftover in the /tmp root: a directory holding a file, untouched 125 minutes.
stale_tmp() {
  mkdir -p "$TMP_ROOT/$1"
  echo data >"$TMP_ROOT/$1/data"
  touch -d '125 minutes ago' "$TMP_ROOT/$1"
}

# closed_job <task> <id>: a builder of <task> launched as job <id>, <task> closed, and the job's
# directory, its state.json done 5 minutes ago and its tmp holding a 2 MB file.
closed_job() {
  opened_task "$1"
  jq -cn --arg task "$1" --arg id "$2" \
    '{ts: "2026-01-02T00:00:00Z", task: $task, event: "launch", role: "builder", session: $id, worktree: "/w/\($task)", toolkits: []},
     {ts: "2026-01-03T00:00:00Z", task: $task, event: "closed", archive: [], returned: [], kept: []}' \
    >>"$TEAM_HOME/ledger.jsonl"
  mkdir -p "$JOBS/$2/tmp"
  head -c 2097152 /dev/zero >"$JOBS/$2/tmp/data"
  jq -n --arg at "$(date -u -d '5 minutes ago' +%FT%T.000Z)" '{state: "done", updatedAt: $at}' >"$JOBS/$2/state.json"
}

# go_cache [<README's first line>]: the fixture Go build cache with its README, Go's own first
# line unless another is given.
go_cache() {
  mkdir -p "$GC"
  printf '%s\n' "${1:-This directory holds cached build artifacts from the Go build system.}" >"$GC/README"
}

# go_entry <path under the cache> <kb> <minutes since last use>: an entry of <kb> kilobytes.
go_entry() {
  mkdir -p "$GC/${1%/*}"
  head -c $(($2 * 1024)) /dev/zero >"$GC/$1"
  touch -d "$3 minutes ago" "$GC/$1"
}

# go_cap <kb>: the Go build cache's cap.
go_cap() {
  export TEAM_GO_CACHE_CAP_KB=$1
}

# Replace team-janitor with the bash read from stdin, in a code checkout of the test's own.
fake_janitor() {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm "$CODE_CHECKOUT/bin/team-janitor"
  { echo '#!/usr/bin/env bash'; cat; } >"$CODE_CHECKOUT/bin/team-janitor"
  chmod +x "$CODE_CHECKOUT/bin/team-janitor"
}

# Origin unreachable for the team home: a closed local port.
cut_origin() {
  git -C "${TEAM_HOME:?}" remote set-url origin https://127.0.0.1:9/agent-team.git
}

# Make the 60-second wait before the probe's second try return at once.
stub_sleep() {
  stub_command sleep
  stub_script sleep </dev/null
}

@test "on the holder the disk step runs after the tmp step and before the inbox step, logging each line team-janitor disk prints" {
  [[ ! -e $HOME/.config/agent-team/stack.json ]]
  inbox_kept
  stale_tmp nm-cli-home-123
  closed_job T422 0f178ea8
  go_cache
  go_entry 0a/0a01-a 600 300
  go_entry 0a/0a02-a 600 290
  go_entry 0b/0b03-d 600 280
  go_cap 1000
  run_bin -0 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint tmp disk inbox"
  local lines
  lines=$(disk_lines "$output")
  assert_equal "$(sed -n 1p <<<"$lines")" "cleared the job tmp of T422's builder 0f178ea8 (2 MB; T422 is closed)"
  [[ $(sed -n 2p <<<"$lines") =~ ^"trimmed the Go build cache $GC from 2 MB to "[0-9]+" MB: 2 entries unused since "[0-9T:-]+Z$ ]]
  assert_equal "$(wc -l <<<"$lines")" 2
  [[ -d $JOBS/0f178ea8/tmp && ! -e $JOBS/0f178ea8/tmp/data ]]
  [[ ! -e $GC/0a/0a01-a && ! -e $GC/0a/0a02-a && -f $GC/0b/0b03-d ]]
  jq -e '(.steps | has("disk") | not) and .last_run.ended == "ok"' "$state/health.json"
}

@test "a quiet disk step logs nothing: no jobs tree, no Go build cache, or a cache under its cap" {
  run_bin -0 team-timers run
  assert_equal "$(disk_lines "$output")" ""
  assert_equal "$(steps "$output")" "lease checkpoint"

  go_cache
  go_entry 0a/0a01-a 600 300
  mkdir -p "$JOBS"
  run_bin -0 team-timers run
  assert_equal "$(disk_lines "$output")" ""
  [[ -f $GC/0a/0a01-a ]]
  jq -e '.last_run.ended == "ok"' "$state/health.json"
}

@test "a team-janitor disk that fails is the disk step failing with its reason; the later steps still run and the run exits 1" {
  inbox_kept
  closed_job T422 0f178ea8
  # A directory that is not Go's over the cap: never trimmed, and the run fails naming it.
  go_cache "Something else's cache."
  go_entry 0a/0a01-a 600 300
  go_cap 100
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint disk inbox"
  local lines
  lines=$(disk_lines "$output")
  assert_equal "$lines" "cleared the job tmp of T422's builder 0f178ea8 (2 MB; T422 is closed)
failed: $GC is not a Go build cache (no Go README); not trimmed"
  grep -E "^[0-9T:-]+Z disk: failed: $GC is not a Go build cache " "$state/heartbeat-failures.log"
  jq -e --arg gc "$GC" '.steps.disk.runs == 1 and .steps.disk.reason == "\($gc) is not a Go build cache (no Go README); not trimmed" and .last_run.ended == "failed"' \
    "$state/health.json"
  [[ -f $GC/0a/0a01-a ]]
}

@test "a team-janitor disk still running past TEAM_TIMERS_DISK_SECONDS is stopped and fails the run" {
  fake_janitor <<'EOF'
[[ $1 == tmp && $# == 1 ]] && exit 0
[[ $1 == disk && $# == 1 ]] || { echo "team-janitor: called as $*" >&2; exit 1; }
exec sleep 30
EOF
  local start=$SECONDS
  TEAM_TIMERS_DISK_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 run_bin -1 team-timers run
  ((SECONDS - start < 20))
  assert_equal "$(disk_lines "$output")" "failed: timed out after 1 s"
  jq -e '.steps.disk.reason == "timed out after 1 s"' "$state/health.json"
}

@test "the disk step runs for 180 s by default" {
  fake_janitor <<'EOF'
[[ $1 == tmp ]] && exit 0
echo "limit: $(ps -o args= -p "$PPID")"
EOF
  run_bin -0 team-timers run
  [[ $(disk_lines "$output") =~ ^"limit: timeout --kill-after=10 180 ".*"/bin/team-janitor disk"$ ]]
}

@test "the disk step never runs off the lease, offline or on a fenced machine, and runs after the back step" {
  closed_job T422 0f178ea8
  make_machine laptop
  on_machine laptop run_bin -0 team-timers run
  assert_equal "$(disk_lines "$output")" ""
  [[ -f $JOBS/0f178ea8/tmp/data ]]

  stub_sleep
  cut_origin
  run_bin -75 team-timers run
  run_bin -75 team-timers run
  assert_equal "$(disk_lines "$output")" ""
  [[ -f $JOBS/0f178ea8/tmp/data ]]
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "back checkpoint disk"
  [[ ! -e $JOBS/0f178ea8/tmp/data ]]

  closed_job T423 0f178eb9
  steal_lease laptop home-pc
  run_bin -0 team-timers run
  assert_contains "$output" "fenced home-pc"
  run_bin -0 team-timers run
  assert_contains "$output" "home-pc is fenced since "
  assert_equal "$(disk_lines "$output")" ""
  [[ -f $JOBS/0f178eb9/tmp/data ]]
}
