#!/usr/bin/env bats
# team-load-check --probe, the drill record: a probe of all four roles is the load-check-probe
# drill, recorded through this checkout's team-drill once a session has launched; a probe of one
# role is no drill; and a refused record says why on stderr and leaves the probe's exit status.
# The sessions are helpers/load-check-probe's claude stub, their transcripts built by
# probe_transcript from the data file's attempts.

load helpers/common
load helpers/load-check
load helpers/transcript
load helpers/load-check-probe

setup() {
  probe_sandbox
}

@test "a probe of all four roles records load-check-probe: pass on exit 0, fail otherwise, with the attempts as expected" {
  local n
  n=$(total)
  run_bin -0 team-load-check --probe
  assert_equal "$(drill_lines)" "$(drill_line load-check-probe pass "$n of $n attempts as expected")"
  assert_equal "${lines[-2]}" "$(recorded load-check-probe pass)"
  assert_equal "${lines[-1]}" PASS

  # One attempt that ran and one never made: two fewer as expected.
  rm "$TEAM_HOME/drills.jsonl" "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  probe_transcript builder sudo=ran
  probe_transcript reviewer merge=skip
  run_bin -1 team-load-check --probe
  assert_equal "$(drill_lines)" "$(drill_line load-check-probe fail "$((n - 2)) of $n attempts as expected")"
  assert_equal "${lines[-2]}" "$(recorded load-check-probe fail)"
  assert_equal "${lines[-1]}" "load check FAILED"
}

@test "a probe that ends after a launch, before its verdicts, records fail" {
  local n
  n=$(total)
  touch "$STUB_FIXTURES/fail-reviewer"
  run_bin -1 team-load-check --probe
  assert_equal "$(drill_lines)" "$(drill_line load-check-probe fail "0 of $n attempts as expected")"
  assert_equal "${lines[-1]}" "$(recorded load-check-probe fail)"
  left_nothing

  # A first launch that fails launched nothing, so nothing is recorded.
  rm "$TEAM_HOME/drills.jsonl" "$STUB_FIXTURES/fail-reviewer"
  touch "$STUB_FIXTURES/fail-planner"
  run_bin -1 team-load-check --probe
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
  [[ $output != *"team-drill: recorded"* ]]
}

@test "a probe of one role records nothing, and says so" {
  run_bin -0 team-load-check --probe --role builder
  assert_equal "${lines[-2]}" "load check: a probe of one role is not the drill, so nothing is recorded"
  assert_equal "${lines[-1]}" PASS
  [[ ! -e $TEAM_HOME/drills.jsonl ]]

  probe_transcript planner sudo=ran
  run_bin -1 team-load-check --probe --role planner
  assert_equal "${lines[-2]}" "load check: a probe of one role is not the drill, so nothing is recorded"
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
}

@test "a probe the doctor stops, or a malformed probe, records nothing" {
  doctor_results FAIL machine
  run_bin -1 team-load-check --probe
  doctor_results
  run_bin -2 team-load-check --probe --toolkit plain
  run_bin -2 team-load-check --probe --role ops
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
}

@test "a probe's refused record says why on stderr and leaves its exit status" {
  rm "$HOME/.config/agent-team/machine"
  run_bin -0 --separate-stderr team-load-check --probe
  assert_equal "${lines[-1]}" PASS
  assert_equal "$stderr" "load check: not recorded: team-drill: this machine has no team name; write one with: echo <name> > ~/.config/agent-team/machine"
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
}
