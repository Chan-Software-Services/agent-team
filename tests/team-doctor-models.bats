#!/usr/bin/env bats
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the models line, which reads the team home's models.toml with team-models --check;
# on the doctor's machine it is the shipped file, tests/fixtures/models.toml;
# tests/team-models.bats covers the reader itself.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
  only_checks 181-models.sh
  tools_at arch
}

# Write the team home's models.toml from stdin: models
models() {
  cat >"$TEAM_HOME/models.toml"
}

@test "the models line passes on a file that reads, counting its lines and naming the default" {
  # The doctor's machine has the shipped file.
  run_bin -0 team-doctor
  assert_equal "$output" "PASS models: models.toml reads: 1 line; default opus at high"
  models <<'TOML'
# A comment is no line.
"default" = { model = "claude-opus-5-5", effort = "xhigh" }
"reviewer.rereview" = { model = "sonnet" }
default.load-check = 1
TOML
  # A bare dotted key is refused, so the count is never of a nested table's keys.
  run_bin -1 team-doctor
  models <<'TOML'
# A comment is no line.
"default" = { model = "claude-opus-5-5", effort = "xhigh" }
"reviewer.rereview" = { model = "sonnet" }
"builder path=small" = { effort = "medium" }
TOML
  run_bin -0 team-doctor
  assert_equal "$output" "PASS models: models.toml reads: 3 lines; default claude-opus-5-5 at xhigh"
}

@test "the models line names the settings' word for a default axis no line names or one set to default" {
  models <<'TOML'
"default" = { model = "default" }
"builder" = { effort = "low" }
TOML
  run_bin -0 team-doctor
  assert_equal "$output" "PASS models: models.toml reads: 2 lines; default the settings' model at the settings' effort"
}

@test "the models line warns with no models.toml in the team home" {
  rm "$TEAM_HOME/models.toml"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN models: no models.toml in the team home, so every session runs on the user settings' model; fix: write it as sops/models.md says"
}

@test "the models line fails naming team-models --check's first problem" {
  models <<'TOML'
"default" = { model = "gpt-5" }
"reviewr" = { model = "sonnet" }
TOML
  run_bin -1 team-doctor
  assert_equal "$output" "FAIL models: models.toml: \"default\": model: 'gpt-5' is not opus, sonnet, haiku, fable or claude-<name>, each optionally with [1m], or default; fix: fix that line of models.toml, then team-models --check"
  # A file that is no TOML names its line.
  models <<'TOML'
"default" = { model = "opus"
TOML
  run_bin -1 team-doctor
  assert_contains "$output" "FAIL models: models.toml: line 1"
  assert_contains "$output" "; fix: fix that line of models.toml, then team-models --check"
}
