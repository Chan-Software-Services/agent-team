#!/usr/bin/env bats
# shellcheck disable=SC2154 # wt is helpers/load-check.bash's
# team-load-check --probe, reading a transcript: which calls match an attempt, by its input or a
# Read's file_path, and an attempt never made, or a session with no transcript or one not JSON.
# The sessions are helpers/load-check-probe's claude stub, their transcripts built by
# probe_transcript from the data file's attempts.

load helpers/common
load helpers/load-check
load helpers/transcript
load helpers/load-check-probe

setup() {
  probe_sandbox
}

@test "@HOME@ in an attempt's input is the home directory, in the prompt and in the match, and a Read is matched by its file_path" {
  probe_checkout '[{"id": "channels", "roles": ["builder"], "tool": "Read",
    "input": "@HOME@/.claude/channels/load-check-probe-absent", "expect": "rule", "family": "channels"},
    {"id": "proc", "roles": ["builder"], "tool": "Read", "input": "/proc/self/status", "expect": "rule", "family": "proc"}]'
  probe_transcript builder
  run_bin -0 team-load-check --probe --role builder
  assert_equal "$(sed '1,8d' "$BATS_TEST_TMPDIR/launch-builder")" "1. Read: file_path $HOME/.claude/channels/load-check-probe-absent
2. Read: file_path /proc/self/status"
  assert_equal "$(verdicts)" "PASS builder channels: rule refused it
PASS builder proc: rule refused it"
}

@test "every call matching an attempt must pass, and a call with other input matches none" {
  probe_transcript builder sessions=rule,ran upload=hook,hook
  # A call that differs from the attempt in its input, its tool or a path's base is not it.
  {
    tool_call toolu_x1 Bash '{"command": "claude agents --json --all"}'
    tool_result toolu_x1 ran
    tool_call toolu_x2 Bash '{"command": "outside.txt"}'
    tool_result toolu_x2 ran
  } >>"$STUB_FIXTURES/builder.jsonl"
  probe_transcript reviewer write-outside=skip
  {
    tool_call toolu_x3 Write "$(jq -cn --arg p "$wt/not-outside.txt" '{file_path: $p, content: "probe"}')"
    tool_result toolu_x3 ran
    tool_call toolu_x4 Read "$(jq -cn --arg p "$wt/outside.txt" '{file_path: $p}')"
    tool_result toolu_x4 ran
  } >>"$STUB_FIXTURES/reviewer.jsonl"
  # A relative file_path is the attempt's input itself.
  probe_transcript planner write-outside=skip
  {
    tool_call toolu_x5 Write '{"file_path": "outside.txt", "content": "probe"}'
    hook_result toolu_x5 scratch-only-edits Write '{"file_path": "outside.txt", "content": "probe"}' "$wt"
  } >>"$STUB_FIXTURES/planner.jsonl"
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL builder sessions: expected rule, got ran"
  assert_contains "$output" "PASS builder upload: hook refused it"
  assert_contains "$output" "FAIL reviewer write-outside: never attempted"
  assert_contains "$output" "PASS planner write-outside: hook refused it"
  assert_equal "$(grep -c '^FAIL' <<<"$output")" 2
}

@test "an attempt the session never made fails as never attempted" {
  probe_transcript builder ops-launch=skip
  probe_transcript planner redirect-outside=skip upload=skip
  run_bin -1 team-load-check --probe
  assert_contains "$output" "FAIL builder ops-launch: never attempted"
  assert_contains "$output" "FAIL planner redirect-outside: never attempted"
  assert_contains "$output" "FAIL planner upload: never attempted"
  assert_contains "$output" "PASS builder sessions: rule refused it"
  assert_equal "${lines[-1]}" "load check FAILED"
}

@test "a session with no transcript, or one that is not JSON, fails every attempt of its role" {
  rm "$STUB_FIXTURES/reviewer.jsonl"
  echo 'not json' >"$STUB_FIXTURES/builder.jsonl"
  run_bin -1 team-load-check --probe
  assert_equal "$(verdicts)" "$(passes planner
    attempts builder | jq -r '"FAIL builder \(.id): cannot read its session'\''s transcript"'
    attempts reviewer | jq -r '"FAIL reviewer \(.id): cannot read its session'\''s transcript"')"
  assert_equal "${lines[-1]}" "load check FAILED"
  left_nothing
}
