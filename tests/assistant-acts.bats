#!/usr/bin/env bats
# The coordinator's acts refuse the assistant's session themselves (assistant_refusal in
# bin/lib/team.sh), beside command-guard's assistant-acts row, which reads only the calls its walk
# can read: a whole act with any words, an acting subcommand with any words after it, each with
# nothing written; the same read forms the row passes (a first --help or -h, each read subcommand)
# are not refused; and every other role passes the function. team-heavy run is left to the row
# alone, so tests/run and team-checks stay open to the assistant.

load helpers/common

setup() {
  sandbox
  # team-resume fast-forwards its code checkout, so every act runs from the test's own.
  code_checkout
}

# Run <script> [<arg>...] as the assistant: refused, exit 1, naming <does>, and nothing in the
# team home or HOME written.
refused() {
  local does=$1 script=$2 before
  shift 2
  before=$(find "$TEAM_HOME" "$HOME" -type f -print0 | sort -z | xargs -0r sha256sum)
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr "$script" "$@"
  assert_equal "$stderr" "$script: an assistant session $does: that is the coordinator's; send it your message"
  assert_equal "$(find "$TEAM_HOME" "$HOME" -type f -print0 | sort -z | xargs -0r sha256sum)" "$before"
}

# Run <script> [<arg>...] as the assistant, whatever it exits, and fail if it printed the refusal.
not_refused() {
  local script=$1
  shift
  AGENT_TEAM_ROLE=assistant run_bin --separate-stderr "$script" "$@"
  [[ $stderr != *"an assistant session runs no"* ]] ||
    { echo "$script $* was refused to the assistant: $stderr" >&2; return 1; }
}

WHOLE_ACTS="team-checkpoint team-handoff team-load-check team-ops-end team-records-rewrite team-resume team-review-comment team-stow claude-coordinator"

@test "each whole act refuses the assistant with any words, writing nothing, and answers its --help and -h" {
  local script
  for script in $WHOLE_ACTS; do
    refused "runs no $script" "$script"
    refused "runs no $script" "$script" T1
    refused "runs no $script" "$script" --load-check-probe
    refused "runs no $script" "$script" T1 --help
    AGENT_TEAM_ROLE=assistant run_bin -0 "$script" --help
    [[ $output == *"Usage: $script"* ]] || { echo "$script --help printed no usage: $output" >&2; return 1; }
    AGENT_TEAM_ROLE=assistant run_bin -0 "$script" -h
    [[ $output == *"Usage: $script"* ]] || { echo "$script -h printed no usage: $output" >&2; return 1; }
  done
}

@test "each acting subcommand refuses the assistant with any words after it, writing nothing" {
  local script sub
  while read -r script sub; do
    refused "runs no $script $sub" "$script" "$sub"
    refused "runs no $script $sub" "$script" "$sub" --load-check-probe
    refused "runs no $script $sub" "$script" "$sub" --help
  done <<'ACTS'
team-capacity install
team-capacity place
team-config apply
team-config capture
team-lease take
team-lease renew
team-lease release
team-secrets restore
team-secrets save
team-stack down
team-stack seed
team-stack stop
team-stack up
team-timers disable
team-timers enable
team-timers run
ACTS
}

@test "the acting subcommands' scripts answer the assistant's --help and run its read subcommands" {
  local script
  for script in team-capacity team-config team-heavy team-lease team-secrets team-stack team-timers; do
    AGENT_TEAM_ROLE=assistant run_bin -0 "$script" --help
    [[ $output == *"Usage: $script"* ]] || { echo "$script --help printed no usage: $output" >&2; return 1; }
    AGENT_TEAM_ROLE=assistant run_bin -0 "$script" -h
  done
  not_refused team-capacity status
  not_refused team-capacity plan --json
  not_refused team-capacity costs
  not_refused team-capacity jobs
  not_refused team-config diff
  not_refused team-config own
  not_refused team-lease status
  not_refused team-lease check
  not_refused team-secrets check
  not_refused team-stack ls
  not_refused team-timers status
  not_refused team-timers health
  # team-heavy run is the guard row's alone, so a suite run through tests/run or team-checks stays
  # the assistant's, as on dev.
  not_refused team-heavy status
  not_refused team-heavy run --load-check-probe
}

@test "assistant_refusal refuses the assistant alone, so every other role and Daniel's shell run the acts as before" {
  local role
  for role in coordinator builder planner reviewer ops ""; do
    AGENT_TEAM_ROLE=$role run bash -c 'source "$1/bin/lib/team.sh" && assistant_refusal "runs no team-stow"' _ "$REPO_ROOT"
    assert_equal "$status $output" "1 "
  done
  AGENT_TEAM_ROLE=assistant run bash -c 'source "$1/bin/lib/team.sh" && assistant_refusal "runs no team-stow"' _ "$REPO_ROOT"
  assert_equal "$status $output" "0 an assistant session runs no team-stow: that is the coordinator's; send it your message"
}

@test "an act the guard's walk cannot read, run from an interpreter's program, refuses the assistant itself" {
  local before
  before=$(find "$TEAM_HOME" "$HOME" -type f -print0 | sort -z | xargs -0r sha256sum)
  AGENT_TEAM_ROLE=assistant run -1 python3 -c 'import os, sys; sys.exit(os.system(sys.argv[1] + " T1") >> 8)' "$CODE_CHECKOUT/bin/team-stow"
  assert_equal "$output" "team-stow: an assistant session runs no team-stow: that is the coordinator's; send it your message"
  AGENT_TEAM_ROLE=assistant run -1 python3 -c 'import subprocess, sys; sys.exit(subprocess.call([sys.argv[1], "take"]))' "$CODE_CHECKOUT/bin/team-lease"
  assert_equal "$output" "team-lease: an assistant session runs no team-lease take: that is the coordinator's; send it your message"
  assert_equal "$(find "$TEAM_HOME" "$HOME" -type f -print0 | sort -z | xargs -0r sha256sum)" "$before"
}
