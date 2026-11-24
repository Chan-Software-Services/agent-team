#!/usr/bin/env bats
# shellcheck disable=SC2154 # code and wt are helpers/load-check.bash's
# team-load-check --probe, the kernel layer: a kernel attempt judged by its canary and its result,
# kernel-shell by its marker, and the session tmp and session directories the probe removes.
# The sessions are helpers/load-check-probe's claude stub, their transcripts built by
# probe_transcript from the data file's attempts.

load helpers/common
load helpers/load-check
load helpers/transcript
load helpers/load-check-probe

setup() {
  probe_sandbox
}

@test "a kernel attempt passes when its call ran and its canary stands, and fails as ran when the canary is gone, as a refusing layer when one refused it, and as foreground when a background call was not" {
  local role attempt call hook canary
  # No hook a role holds refuses either call, so the kernel is what refuses the removal: the
  # planner's and the reviewer's scratch-only-edits, command-guard, and every role's lease-fence.
  for attempt in kernel-delete kernel-delete-background kernel-shell; do
    call=$(jq -c --arg id "$attempt" --arg canary "$BATS_TEST_TMPDIR/outside" '.attempts[] | select(.id == $id)
      | {command: (.input | split("@CANARY@") | join($canary)), description: "probe"}' "$(data)")
    for hook in scratch-only-edits command-guard lease-fence; do
      run hook_result toolu_x1 "$hook" Bash "$call" "$wt"
      assert_equal "$status" 1
    done
  done

  run_bin -0 team-load-check --probe
  for role in planner builder reviewer; do
    assert_contains "$output" "PASS $role kernel-delete: kernel refused it"
    assert_contains "$output" "PASS $role kernel-delete-background: kernel refused it"
    # Each role had a canary directory of its own, outside the worktree, with both canaries in it
    # when its session started, and the prompt named it.
    canary=$(head -n 1 "$BATS_TEST_TMPDIR/canary-$role")
    assert_equal "$(basename "$canary")" "$role"
    [[ $canary != "$code"/* ]]
    assert_equal "$(sed 1d "$BATS_TEST_TMPDIR/canary-$role")" "$(printf '%s\n' kernel-delete kernel-delete-background kernel-shell)"
    assert_contains "$(cat "$BATS_TEST_TMPDIR/launch-$role")" ". Bash: python3 -c 'import os; os.rmdir(\"$canary/kernel-delete\")'"
    assert_contains "$(cat "$BATS_TEST_TMPDIR/launch-$role")" ". Bash, with run_in_background true: python3 -c 'import os; os.rmdir(\"$canary/kernel-delete-background\")'"
    # The canary directory is removed at the end, by its path.
    [[ ! -e $(dirname "$canary") ]]
  done

  # An unconfined builder removes its foreground canary, and the planner its background one; a
  # hook, a deny rule or auto mode that refuses the call proves nothing of the kernel.
  echo kernel-delete >"$STUB_FIXTURES/uncanary-builder"
  echo kernel-delete-background >"$STUB_FIXTURES/uncanary-planner"
  probe_transcript reviewer kernel-delete=hook kernel-delete-background=automode
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL builder kernel-delete: expected kernel, got ran (the canary was removed)"
  assert_contains "$output" "PASS builder kernel-delete-background: kernel refused it"
  assert_contains "$output" "PASS planner kernel-delete: kernel refused it"
  assert_contains "$output" "FAIL planner kernel-delete-background: expected kernel, got ran (the canary was removed)"
  assert_contains "$output" "FAIL reviewer kernel-delete: expected kernel, got hook"
  assert_contains "$output" "FAIL reviewer kernel-delete-background: expected kernel, got automode"
  [[ ! -e $(dirname "$(head -n 1 "$BATS_TEST_TMPDIR/canary-builder")") ]]

  # A background attempt made in the foreground does not show the background path confined.
  rm "$STUB_FIXTURES"/uncanary-* "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  probe_transcript reviewer
  jq -c 'del(.message.content[0].input.run_in_background?)' "$STUB_FIXTURES/reviewer.jsonl" >"$STUB_FIXTURES/reviewer.new"
  mv "$STUB_FIXTURES/reviewer.new" "$STUB_FIXTURES/reviewer.jsonl"
  run_bin -1 team-load-check --probe
  assert_contains "$output" "PASS reviewer kernel-delete: kernel refused it"
  assert_contains "$output" "FAIL reviewer kernel-delete-background: expected kernel, got ran in the foreground"
  # A foreground attempt whose result holds no refusal by the kernel shows no command ran confined;
  # a background attempt's result is not read.
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  probe_transcript planner kernel-delete=ran kernel-delete-background=ran
  probe_transcript builder
  probe_transcript reviewer
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL planner kernel-delete: expected kernel, got no refusal by the kernel in its result"
  assert_contains "$output" "PASS planner kernel-delete-background: kernel refused it"
  assert_contains "$output" "PASS builder kernel-delete: kernel refused it"
  # A kernel attempt never made fails as any other.
  probe_transcript builder kernel-delete=skip
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  run_bin -1 team-load-check --probe --role builder
  assert_contains "$output" "FAIL builder kernel-delete: never attempted"
}

@test "the probe removes the T0 session tmp and session directories its sessions made, each a directory of this user's, and leaves a link there, naming the session directories' one" {
  local tmp=$TEAM_SYSTEM_ROOT/tmp/agent-team-T0 dirs=$HOME/.config/agent-team/confine
  mkdir -p "$tmp/sub" "$TEAM_SYSTEM_ROOT/tmp/agent-team-T1" "$BATS_TEST_TMPDIR/kept" "$dirs/T0/builder.agent-team" "$dirs/T1/builder.x"
  : >"$dirs/T0/builder.agent-team/session.json"
  chmod 400 "$dirs/T0/builder.agent-team/session.json"
  : >"$BATS_TEST_TMPDIR/kept/file"
  run_bin -0 --separate-stderr team-load-check --probe
  [[ ! -e $tmp && -d $TEAM_SYSTEM_ROOT/tmp/agent-team-T1 ]]
  [[ ! -e $dirs/T0 && -d $dirs/T1/builder.x ]]
  [[ $stderr != *"session directories"* ]]
  # A link where each would be is left with what it names; the session directories' one is made
  # by the time the sessions are done, since confine-session refuses to write a session directory
  # through a link.
  ln -s "$BATS_TEST_TMPDIR/kept" "$tmp"
  printf 'rm -rf %q && ln -s %q %q\n' "${dirs:?}/T0" "$BATS_TEST_TMPDIR/kept" "$dirs/T0" >"$STUB_FIXTURES/session-does"
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  run_bin -0 --separate-stderr team-load-check --probe --role builder
  [[ -L $tmp && -L $dirs/T0 && -f $BATS_TEST_TMPDIR/kept/file ]]
  assert_contains "$stderr" "team-load-check: left $dirs/T0, which is no directory of this user's, where T0's session directories would be"
}

@test "kernel-shell passes when its result holds the marker and the kernel's refusal, and fails without the marker as a shell that is not the confined one" {
  assert_equal "$(jq -c '.attempts[] | select(.id == "kernel-shell") | [.roles, .expect, .marker, .background]' "$(data)")" \
    '[["planner","builder","reviewer"],"kernel","confine-shell=1",null]'
  run_bin -0 team-load-check --probe
  local role
  for role in planner builder reviewer; do
    assert_contains "$output" "PASS $role kernel-shell: kernel refused it"
    assert_contains "$(cat "$BATS_TEST_TMPDIR/launch-$role")" ". Bash: python3 -c 'import os; print(\"confine-shell=\" + os.environ.get(\"AGENT_TEAM_CONFINE_SHELL\", \"\")); os.rmdir(\"$(head -n 1 "$BATS_TEST_TMPDIR/canary-$role")/kernel-shell\")'"
  done
  # A session whose shell is not the program confine-session wrote prints no value: the prefix
  # alone confined the call, after a shell of the user's.
  probe_transcript builder kernel-shell=no-marker
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL builder kernel-shell: expected kernel, got the session's shell is not the confined one"
  assert_contains "$output" "PASS builder kernel-delete: kernel refused it"
  assert_contains "$output" "PASS planner kernel-shell: kernel refused it"
  # Its canary gone, it is the removal that is named; with neither marker nor refusal, the shell.
  probe_transcript builder kernel-shell=no-marker
  probe_transcript planner kernel-shell=ran
  echo kernel-shell >"$STUB_FIXTURES/uncanary-builder"
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL builder kernel-shell: expected kernel, got ran (the canary was removed)"
  assert_contains "$output" "FAIL planner kernel-shell: expected kernel, got the session's shell is not the confined one"
}
