#!/usr/bin/env bats
# shellcheck disable=SC2154 # wt is helpers/load-check.bash's
# team-load-check --probe, the refusing layer: an attempt passes when the layer it expects refused
# it, a refused attempt, auto mode's stand-in, on any refusing layer, and fails, naming what it
# expected, when it ran or another layer refused it; a rejection with no toolDenialKind is read by
# its decision; and a probe whose every attempt passes removes every session and the worktree.
# The sessions are helpers/load-check-probe's claude stub, their transcripts built by
# probe_transcript from the data file's attempts.

load helpers/common
load helpers/load-check
load helpers/transcript
load helpers/load-check-probe

setup() {
  probe_sandbox
}

@test "every attempt refused as expected passes, in each role's order, and every session and the worktree are removed" {
  run_bin -0 team-load-check --probe
  assert_equal "$(verdicts)" "$(passes planner builder reviewer)"
  assert_equal "${lines[-1]}" PASS
  assert_equal "$(launched)" "$(printf '%s\n' planner builder reviewer)"
  # The hook attempts pass on the real hooks' blocks, each with its own marker.
  assert_contains "$output" "PASS planner write-outside: hook refused it"
  assert_contains "$output" "PASS reviewer redirect-outside: hook refused it"
  assert_contains "$output" "PASS builder ops-launch: hook refused it"
  assert_contains "$output" "PASS builder sessions: rule refused it"
  assert_contains "$output" "PASS builder upload: hook refused it"
  # Each role is refused each probed session-record place by the session records guard's own
  # block, by Read, and five of them by Bash as well.
  local role id absent=load-check-probe-absent
  for role in planner builder reviewer; do
    for id in file-history mcp-logs transcripts job-directory transcripts-directory prompt-history paste-cache \
      task-lists session-env live-sessions daemon daemon-log job-directory-bash transcripts-directory-bash \
      prompt-history-bash paste-cache-bash projects-bash; do
      assert_contains "$output" "PASS $role $id: hook refused it"
    done
    assert_contains "$(cat "$STUB_FIXTURES/$role.jsonl")" "bin/hooks/session-records-guard]: Blocked by session-records-guard: Read of $HOME/.claude/projects/$absent/$absent.jsonl: under ~/.claude/projects a session reads only its own records"
    assert_contains "$(cat "$STUB_FIXTURES/$role.jsonl")" "bin/hooks/session-records-guard]: Blocked by session-records-guard: Read of $HOME/.claude/file-history/$absent/probe: ~/.claude/file-history holds every session's records, and a worker session reads none of it."
    assert_contains "$(cat "$STUB_FIXTURES/$role.jsonl")" "bin/hooks/session-records-guard]: Blocked by session-records-guard: Read of $HOME/.claude/jobs/$absent/state.json: under ~/.claude/jobs a session reads only what lies in its own job directory, and this is another session's."
    assert_contains "$(cat "$STUB_FIXTURES/$role.jsonl")" "bin/hooks/session-records-guard]: Blocked by session-records-guard: a Bash command naming ~/.claude/history.jsonl/$absent: ~/.claude/history.jsonl holds every session's records, and a worker session reads none of it."
  done
  # Only the planner and the reviewer write outside .scratch/ by their hook.
  [[ $output != *"builder write-outside"* && $output != *"builder redirect-outside"* ]]
  for role in planner builder reviewer; do
    assert_contains "$output" "load check: $role's effective autoMode holds the"
    assert_equal "$(sed -n 1,2p "$BATS_TEST_TMPDIR/launch-$role")" "$(printf '%s\n' "$wt" true)"
  done
  assert_equal "$(cat "$BATS_TEST_TMPDIR/automode-cwd")" "$(printf '%s\n' "$wt" "$wt" "$wt")"
  # Each read with the sources team-worker launches the role with, --setting-sources user.
  assert_equal "$(stub_calls claude | jq -c 'select(index("auto-mode") != null)')" \
    "$(for role in planner builder reviewer; do
      echo "[\"--setting-sources\",\"user\",\"--settings\",\"$TEAM_HOME/tasks/T0/settings.$role.code.json\",\"auto-mode\",\"config\"]"
    done)"
  assert_equal "$(stub_calls claude | jq -r 'select(.[0] == "rm") | .[1]')" "$(printf '%s\n' 1a1a1a1a 2b2b2b2b 3c3c3c3c)"
  left_nothing
  # The probe rehearses no lease and keeps no inventory.
  [[ ! -e $TEAM_HOME/tasks/T0/inventory.txt ]]
}

@test "each role's broad kill and delete outside pass on command-guard's own block, which no other hook makes first, and fail when one ran or another hook refused it" {
  local role attempt call
  # The other hooks a role holds let both calls through, so the guard's block is the one each role
  # meets: the planner's and the reviewer's scratch-only-edits, and every role's lease-fence.
  for attempt in broad-kill delete-outside; do
    call=$(jq -c --arg id "$attempt" '.attempts[] | select(.id == $id) | {command: .input, description: "probe"}' "$(data)")
    run hook_result toolu_x1 scratch-only-edits Bash "$call" "$wt"
    assert_equal "$status" 1
    run hook_result toolu_x1 lease-fence Bash "$call" "$wt"
    assert_equal "$status" 1
  done
  run_bin -0 team-load-check --probe
  for role in planner builder reviewer; do
    assert_contains "$output" "PASS $role broad-kill: hook refused it"
    assert_contains "$output" "PASS $role delete-outside: hook refused it"
    # The transcripts hold command-guard's real block of each.
    assert_contains "$(cat "$STUB_FIXTURES/$role.jsonl")" "bin/hooks/command-guard]: Blocked by command-guard: a kill by name or pattern (killall)"
    assert_contains "$(cat "$STUB_FIXTURES/$role.jsonl")" "bin/hooks/command-guard]: Blocked by command-guard: a recursive delete of /load-check-probe-no-such-dir"
  done

  probe_transcript planner broad-kill=ran
  probe_transcript builder delete-outside=other-hook
  probe_transcript reviewer broad-kill=automode delete-outside=rule
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL planner broad-kill: expected hook, got ran"
  assert_contains "$output" "PASS planner delete-outside: hook refused it"
  assert_contains "$output" "PASS builder broad-kill: hook refused it"
  assert_contains "$output" "FAIL builder delete-outside: expected hook, got other-hook"
  assert_contains "$output" "FAIL reviewer broad-kill: expected hook, got automode"
  assert_contains "$output" "FAIL reviewer delete-outside: expected hook, got rule"
}

@test "an attempt that ran fails, naming what it expected" {
  probe_transcript planner write-outside=ran sessions=ran
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL planner write-outside: expected hook, got ran"
  assert_contains "$output" "FAIL planner sessions: expected rule, got ran"
  assert_contains "$output" "PASS planner redirect-outside: hook refused it"
  assert_contains "$(verdicts)" "$(passes builder reviewer)"
  assert_equal "${lines[-1]}" "load check FAILED"
  left_nothing
}

@test "an attempt refused by another layer than it expects fails" {
  probe_transcript planner sessions=automode upload=no-verdict ops-launch=other-hook
  probe_transcript builder sessions=hook upload=rule ops-launch=rule
  probe_transcript reviewer write-outside=safety-check upload=automode redirect-outside=user-rejected sessions=none
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL planner sessions: expected rule, got automode"
  assert_contains "$output" "FAIL planner upload: expected hook, got no-verdict"
  assert_contains "$output" "FAIL planner ops-launch: expected hook, got other-hook"
  assert_contains "$output" "FAIL builder sessions: expected rule, got hook"
  assert_contains "$output" "FAIL builder upload: expected hook, got rule"
  assert_contains "$output" "FAIL builder ops-launch: expected hook, got rule"
  assert_contains "$output" "FAIL reviewer write-outside: expected hook, got safety-check"
  assert_contains "$output" "FAIL reviewer upload: expected hook, got automode"
  assert_contains "$output" "FAIL reviewer redirect-outside: expected hook, got user-rejected"
  assert_contains "$output" "FAIL reviewer sessions: expected rule, got none"
  assert_equal "${lines[-1]}" "load check FAILED"

  # The upload is refused by command-guard's block, with its marker.
  probe_transcript planner upload=hook
  probe_transcript builder
  probe_transcript reviewer
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  run_bin -0 team-load-check --probe
  assert_contains "$output" "PASS planner upload: hook refused it"
}

@test "a refused attempt, auto mode's stand-in, passes on any refusing layer and fails on any other outcome" {
  probe_checkout '[{"id": "stand-in", "roles": ["builder"], "tool": "Bash", "input": "echo stand-in", "expect": "refused"},
    {"id": "unrefused", "roles": ["builder"], "tool": "Bash", "input": "echo unrefused", "expect": "refused"}]'
  probe_transcript builder stand-in=automode,rule,other-hook,safety-check unrefused=automode,no-verdict
  run_bin -1 team-load-check --probe --role builder
  assert_equal "$(verdicts)" "PASS builder stand-in: refused by automode, hook, rule, safety-check
FAIL builder unrefused: expected refused, got no-verdict"
}

@test "a rejection with no toolDenialKind is read by its decision: a deny rule passes, another reason fails as rejected" {
  probe_transcript planner sessions=file-rule merge=ran
  # merge's call ran with a decision of accept; sudo's was rejected for a reason the reader does not
  # model, with no toolDenialKind.
  local merge sudo
  merge=$(call_id planner '^gh pr merge ') sudo=$(call_id planner '^sudo ')
  jq -c --arg merge "$merge" --arg sudo "$sudo" '.message.content[0].tool_use_id? as $id
    | if $id == $merge then .permissionDecision = {decision: "accept", source: "config", reasonType: "classifier"}
      elif $id == $sudo then del(.toolDenialKind)
        | .permissionDecision = {decision: "reject", source: "config", reasonType: "mode"}
      else . end' "$STUB_FIXTURES/planner.jsonl" >"$BATS_TEST_TMPDIR/planner.jsonl"
  mv "$BATS_TEST_TMPDIR/planner.jsonl" "$STUB_FIXTURES/planner.jsonl"
  probe_transcript builder
  probe_transcript reviewer
  run_bin -1 team-load-check --probe
  assert_contains "$output" "PASS planner sessions: rule refused it"
  assert_contains "$output" "FAIL planner merge: expected rule, got ran"
  assert_contains "$output" "FAIL planner sudo: expected rule, got rejected"
  assert_contains "$output" "PASS planner proc: rule refused it"
  assert_contains "$output" "PASS planner channels: rule refused it"
}
