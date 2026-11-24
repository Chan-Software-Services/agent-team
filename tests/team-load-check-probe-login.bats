#!/usr/bin/env bats
# team-load-check --probe, the login attempts: while bin/lib/worker-login names a login, each
# session makes a login attempt, which passes only on the worker login; with the worker login off,
# the probe makes no github call and no login attempt.
# The sessions are helpers/load-check-probe's claude stub, their transcripts built by
# probe_transcript from the data file's attempts; login_on stands for the worker login and GitHub.

load helpers/common
load helpers/load-check
load helpers/transcript
load helpers/load-check-probe

setup() {
  probe_sandbox
}

@test "a session on another login, or whose login call was refused or gave nothing, fails its login attempt" {
  login_on
  probe_transcript planner login=as-team-owner
  probe_transcript builder login=hook
  probe_transcript reviewer login=skip
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL planner login: the session's GitHub login is team-owner, not team-worker-bot"
  assert_contains "$output" "FAIL builder login: its call did not run: hook"
  assert_contains "$output" "FAIL reviewer login: never attempted"
  assert_equal "$(github_lines)" "$(refused_all)"
  assert_equal "${lines[-1]}" "load check FAILED"

  # The login in another case is the same login; a call with no result, or a result that is no
  # login, fails, and only a GitHub login leaves the transcript.
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  probe_transcript planner login=as-Team-Worker-Bot
  probe_transcript builder login=none
  probe_transcript reviewer login=as-HTTP-401:refused
  run_bin -1 team-load-check --probe
  assert_contains "$output" "PASS planner login: the session's GitHub login is team-worker-bot"
  assert_contains "$output" "FAIL builder login: its call did not run: none"
  assert_contains "$output" "FAIL reviewer login: its call gave a result that is no GitHub login"
  [[ $output != *"HTTP-401"* ]]
}

@test "with the worker login off, the probe makes no github call and no login attempt, and says so in one line" {
  probe_checkout "$(jq -c .attempts "$REPO_ROOT/bin/lib/probe.json")"
  worker_login_off
  committed_checkout
  own_registry
  local n role
  n=$(total)
  run_bin -0 team-load-check --probe
  assert_equal "$(grep -c '^github: off, since no bin/lib/worker-login names the account$' <<<"$output")" 1
  assert_equal "$(github_lines)" ""
  assert_equal "$(stub_calls gh)" ""
  [[ $output != *" login: "* ]]
  for role in planner builder reviewer; do
    [[ $(cat "$BATS_TEST_TMPDIR/launch-$role") != *"gh api user"* ]]
    [[ $(cat "$BATS_TEST_TMPDIR/launch-$role") != *"The one exception"* ]]
    assert_contains "$output" "PASS $role login-assigned: hook refused it"
  done
  assert_equal "$(verdicts)" "$(passes planner builder reviewer)"
  assert_equal "$(drill_lines)" "$(checkout_drill_line pass "$n of $n attempts as expected")"
  assert_equal "${lines[-1]}" PASS
}
