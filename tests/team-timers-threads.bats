#!/usr/bin/env bats
# team-timers' threads step: on the holder after the inbox step and before the finished step, the
# real team-thread archive, on the fake Discord of helpers/discord-threads. The heartbeat suite's
# setup: home-pc holds the lease on a bare origin, the stub claude lists the coordinator and the
# assistant, the service managers are fakes and GitHub is tests/helpers/github-api.bash's
# heartbeat stub (an idle hour).

load helpers/common
load helpers/github-api
load helpers/discord-threads

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stub_reply claude '[{"id": "c0ffee00", "name": "coordinator", "status": "idle"}, {"id": "a5515700", "name": "assistant", "status": "idle"}]'
  hold_lease home-pc >/dev/null
  fake_service_managers
  github_heartbeat_stub
  stub_command uname
  stub_reply uname Linux
  state=$HOME/.local/state/agent-team
  log=$state/heartbeat.log
  threads_discord
  export TEAM_TIMERS_RUN_SECONDS=120
}

# The steps a run's output logged, in order, each run of lines once: steps <output>
steps() {
  sed -E 's/^[^ ]+ ([a-z]+): .*$/\1/' <<<"$1" | uniq | paste -sd ' '
}

# The threads step's lines of <output>, each without its time and step.
threads_lines() {
  grep -E '^[^ ]+ threads: ' <<<"$1" | cut -d' ' -f3- || true
}

# T7 closed under the rule, its thread's last message <seconds> ago: closed_task <seconds ago>
closed_task() {
  cat >>"$TEAM_HOME/ledger.jsonl" <<'LEDGER'
{"ts":"2026-11-01T10:00:00Z","task":"T7","event":"thread","discord_thread":"1563000000000000701"}
{"ts":"2026-11-02T10:00:00Z","task":"T7","event":"closed","archive":[],"returned":[],"kept":[],"threads":["1563000000000000701"]}
LEDGER
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · Done" "$1"
}

@test "on the holder the threads step runs after the inbox step, archiving each thread the rule allows, one line each" {
  closed_task 172800
  run_bin -0 team-timers run
  assert_equal "$output" "$(cat "$log")"
  assert_equal "$(threads_lines "$output")" "archived 1563000000000000701 T7's thread: T7 · agent-team · Done"
  assert_equal "$(steps "$output")" "lease checkpoint threads"
  assert_equal "$(archived_threads)" "1563000000000000701"
  jq -e '(.steps | has("threads") | not) and .last_run.ended == "ok"' "$state/health.json"

  # A quiet pass logs nothing.
  run_bin -0 team-timers run
  assert_equal "$(threads_lines "$output")" ""
}

@test "a pass that fails is the threads step failing alone: the later steps run and the run still ends 0" {
  closed_task 172800
  touch "$DISCORD_DIR/refuse-1563000000000000701"
  run_bin -0 team-timers run
  assert_equal "$(threads_lines "$output")" "failed: could not archive 1563000000000000701 T7's thread: curl: (22) The requested URL returned error: 403"
  jq -e '.steps.threads.runs == 1 and (.steps.threads.reason | startswith("could not archive ")) and .last_run.ended == "ok"' \
    "$state/health.json"
  grep -E "^[0-9T:-]+Z threads: failed: could not archive " "$state/heartbeat-failures.log"
}

@test "the threads step never runs off the lease" {
  make_machine laptop
  local home=$BATS_TEST_TMPDIR/machines/laptop/team
  cat >>"$home/ledger.jsonl" <<'LEDGER'
{"ts":"2026-11-01T10:00:00Z","task":"T7","event":"thread","discord_thread":"1563000000000000701"}
{"ts":"2026-11-02T10:00:00Z","task":"T7","event":"closed","archive":[],"returned":[],"kept":[],"threads":["1563000000000000701"]}
LEDGER
  thread 1563000000000000701 "$COORDINATOR" "T7 · agent-team · Done" 172800
  on_machine laptop run_bin -0 team-timers run
  assert_equal "$(threads_lines "$output")" ""
  assert_equal "$(archived_threads)" ""
}
