#!/usr/bin/env bats
# team-timers' tmp step: on the holder after the github step and before the inbox step, the real
# team-janitor tmp, whose sweep and warning run against the two roots under the sandbox's
# TEAM_SYSTEM_ROOT ($TMP_ROOT and $VAR_ROOT), never the machine's /tmp, with the /tmp root's file
# system the reading TEAM_TMP_DF names (10% of 16 GiB unless a test writes another). The
# heartbeat suite's setup: home-pc holds the lease on a bare origin, the stub claude lists the
# coordinator and the assistant, a usage read of the model windows was just taken
# (usage_read_now), so the quota step starts no Claude Code and logs nothing, the service managers
# are fakes, GitHub is tests/helpers/github-api.bash's heartbeat stub (an idle hour), and Discord
# is the inbox helper's fake, which keeps each alert's body. There is no stack.json: the step has
# no setting.

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
  VAR_ROOT=$TEAM_SYSTEM_ROOT/var/tmp
  mkdir -p "$TMP_ROOT" "$VAR_ROOT"
  export TEAM_TMP_DF=$BATS_TEST_TMPDIR/df
  reading 10
  export TEAM_TIMERS_RUN_SECONDS=120
}

# Let bats remove what a test made read-only.
teardown() {
  chmod -R u+w "$TEAM_SYSTEM_ROOT" 2>/dev/null || true
}

# reading <percent>: the /tmp root's file system, as TEAM_TMP_DF gives it: a tmpfs of 16 GiB
# mounted with usrquota, <percent> of it used.
reading() {
  local size=17179869184
  printf 'tmpfs %s %s rw,nosuid,nodev,size=16777216k,usrquota\n' "$size" "$(((size * $1 + 99) / 100))" >"$TEAM_TMP_DF"
}

# stale_dir <path>: a directory holding a file, last modified 125 minutes ago.
stale_dir() {
  mkdir -p "$1"
  echo data >"$1/data"
  touch -d '125 minutes ago' "$1"
}

# The steps a run's output logged, in order, each run of lines once: steps <output>
steps() {
  sed -E 's/^[^ ]+ ([a-z]+): .*$/\1/' <<<"$1" | uniq | paste -sd ' '
}

# The tmp step's lines of <output>, each without its time and step.
tmp_lines() {
  sed -nE 's/^[^ ]+ tmp: //p' <<<"$1"
}

# A quota reading of the week at 72%, which the quota step posts.
quota_past() {
  mkdir -p "$state"
  jq -cn --arg at "$(date -u +%FT%TZ)" \
    '{at: $at, machine: "home-pc",
      windows: {five_hour: {used: 10, resets_at: "2036-11-14T18:00:00Z"}, seven_day: {used: 72, resets_at: "2036-11-17T09:00:00Z"}},
      models: []}' >"$state/quota.json"
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

# Replace team-janitor with the bash read from stdin, in a code checkout of the test's own.
fake_janitor() {
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm "$CODE_CHECKOUT/bin/team-janitor"
  { echo '#!/usr/bin/env bash'; cat; } >"$CODE_CHECKOUT/bin/team-janitor"
  chmod +x "$CODE_CHECKOUT/bin/team-janitor"
}

@test "on the holder the tmp step runs after the github step and before the inbox step, logging each line team-janitor tmp prints" {
  [[ ! -e $HOME/.config/agent-team/stack.json ]]
  quota_past
  inbox_kept
  stale_dir "$TMP_ROOT/nm-cli-home-123"
  stale_dir "$VAR_ROOT/git-template-4"
  reading 52
  run_bin -0 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(steps "$output")" "lease checkpoint quota tmp inbox"
  local lines
  lines=$(tmp_lines "$output")
  assert_equal "$(sed -n 1,2p <<<"$lines")" "removed $TMP_ROOT/nm-cli-home-123 (0 MB, untouched 2 h; no-mistakes)
removed $VAR_ROOT/git-template-4 (0 MB, untouched 2 h; no-mistakes)"
  [[ $(sed -n 3p <<<"$lines") =~ ^"posted to #coordinator (message "[0-9]+"): /tmp is 52% full"$ ]]
  assert_equal "$(wc -l <<<"$lines")" 3
  [[ ! -e $TMP_ROOT/nm-cli-home-123 && ! -e $VAR_ROOT/git-template-4 ]]
  [[ $(jq -r .content "$STUB_FIXTURES/inbox/$(tail -n 1 "$STUB_FIXTURES/inbox/alerts").json") == "/tmp on home-pc is 52% full "* ]]
  jq -e '(.steps | has("tmp") | not) and .last_run.ended == "ok"' "$state/health.json"
}

# wall-clock: a tmp entry's age is its file's time, which the kernel writes from the real clock, so
# with the clock moved ahead an entry made now is stale and removed.
# bats test_tags=wall-clock
@test "a quiet tmp step logs nothing: nothing stale, the warning not wanted, and no /tmp root at all" {
  mkdir "$TMP_ROOT/nm-cli-home-1"
  run_bin -0 team-timers run
  assert_equal "$(tmp_lines "$output")" ""
  [[ -d $TMP_ROOT/nm-cli-home-1 ]]

  rm -r "${TEAM_SYSTEM_ROOT:?}"
  run_bin -0 team-timers run
  assert_equal "$(tmp_lines "$output")" ""
  assert_equal "$(steps "$output")" "lease checkpoint"
}

@test "a team-janitor tmp that fails is the tmp step failing with its reason; the later steps still run and the run exits 1" {
  inbox_kept
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  stale_dir "$VAR_ROOT/nm-cli-home-2"
  # The /tmp root read-only: its entry cannot be removed, the other root's still is.
  chmod a-w "$TMP_ROOT"
  run_bin -1 team-timers run
  assert_equal "$(steps "$output")" "lease checkpoint tmp inbox"
  local lines
  lines=$(tmp_lines "$output")
  assert_equal "$(sed -n 1p <<<"$lines")" "removed $VAR_ROOT/nm-cli-home-2 (0 MB, untouched 2 h; no-mistakes)"
  [[ $(sed -n 2p <<<"$lines") =~ ^"failed: could not remove $TMP_ROOT/nm-cli-home-1: ".+$ ]]
  assert_equal "$(wc -l <<<"$lines")" 2
  grep -E "^[0-9T:-]+Z tmp: failed: could not remove $TMP_ROOT/nm-cli-home-1: " "$state/heartbeat-failures.log"
  jq -e '.steps.tmp.runs == 1 and (.steps.tmp.reason | startswith("could not remove ")) and .last_run.ended == "failed"' \
    "$state/health.json"
  [[ -d $TMP_ROOT/nm-cli-home-1 && ! -e $VAR_ROOT/nm-cli-home-2 ]]
}

@test "a team-janitor tmp still running past TEAM_TIMERS_TMP_SECONDS is stopped and fails the run" {
  fake_janitor <<'EOF'
[[ $1 == tmp && $# == 1 ]] || { echo "team-janitor: called as $*" >&2; exit 1; }
exec sleep 30
EOF
  local start=$SECONDS
  TEAM_TIMERS_TMP_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 run_bin -1 team-timers run
  ((SECONDS - start < 20))
  assert_equal "$(tmp_lines "$output")" "failed: timed out after 1 s"
  jq -e '.steps.tmp.reason == "timed out after 1 s"' "$state/health.json"
}

@test "the tmp step runs for 120 s by default" {
  fake_janitor <<'EOF'
echo "limit: $(ps -o args= -p "$PPID")"
EOF
  run_bin -0 team-timers run
  [[ $(tmp_lines "$output") =~ ^"limit: timeout --kill-after=10 120 ".*"/bin/team-janitor tmp"$ ]]
}

@test "the tmp step never runs off the lease, offline or on a fenced machine, and runs after the back step" {
  stale_dir "$TMP_ROOT/nm-cli-home-1"
  make_machine laptop
  on_machine laptop run_bin -0 team-timers run
  assert_equal "$(tmp_lines "$output")" ""
  [[ -d $TMP_ROOT/nm-cli-home-1 ]]

  stub_sleep
  cut_origin
  run_bin -75 team-timers run
  run_bin -75 team-timers run
  assert_equal "$(tmp_lines "$output")" ""
  [[ -d $TMP_ROOT/nm-cli-home-1 ]]
  git -C "${TEAM_HOME:?}" remote set-url origin "${origin:?}"
  run_bin -0 team-timers run
  assert_equal "$(steps "$output")" "back checkpoint tmp"
  [[ ! -e $TMP_ROOT/nm-cli-home-1 ]]

  stale_dir "$TMP_ROOT/nm-cli-home-2"
  steal_lease laptop home-pc
  run_bin -0 team-timers run
  assert_contains "$output" "fenced home-pc"
  run_bin -0 team-timers run
  assert_contains "$output" "home-pc is fenced since "
  assert_equal "$(tmp_lines "$output")" ""
  [[ -d $TMP_ROOT/nm-cli-home-2 ]]
}
