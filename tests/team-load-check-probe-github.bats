#!/usr/bin/env bats
# team-load-check --probe, the github calls: while bin/lib/worker-login names a login, the load
# check itself makes each call of the data file's github list on the worker login for each of the
# team's own projects, after the sessions' attempts, asking for a moved repo where it is now. Each
# call passes when GitHub refuses it and fails the probe, naming its answer, when it does not; a
# merge answered 405 for another reason than the push restriction, or 409, is not shown and fails
# nothing, and with no open pull request no merge is tried. With every call refused, each session's
# login attempts pass and its prompt names the login call as its one exception; a login attempt that
# fails is team-load-check-probe-login.bats'.
# The sessions are helpers/load-check-probe's claude stub, their transcripts built by
# probe_transcript from the data file's attempts; login_on stands for the worker login and GitHub.

load helpers/common
load helpers/load-check
load helpers/transcript
load helpers/load-check-probe

setup() {
  probe_sandbox
}

@test "with the worker login on, GitHub refusing it each github call passes, each call made on the worker login after the sessions' attempts" {
  login_on
  local n worker=$HOME/.config/agent-team/gh-worker role
  n=$(($(total) + 4))
  run_bin -0 team-load-check --probe
  assert_equal "$(github_lines)" "$(refused_all)"
  # Each session's login attempt passes, among its role's attempts, all of which pass.
  assert_equal "$(verdicts)" "$(passes planner builder reviewer)"
  for role in planner builder reviewer; do
    assert_contains "$output" "PASS $role login: the session's GitHub login is team-worker-bot"
    assert_contains "$output" "PASS $role login-assigned: hook refused it"
    assert_contains "$output" "PASS $role login-unset: hook refused it"
    # The prompt names the one call expected to run, and lists it.
    assert_contains "$(cat "$BATS_TEST_TMPDIR/launch-$role")" "The one exception is the call gh api user --jq .login, which is expected to run and print this session's GitHub login."
    assert_contains "$(cat "$BATS_TEST_TMPDIR/launch-$role")" ". Bash: gh api user --jq .login"
  done
  # The github lines come after every role's attempts.
  assert_equal "$(grep -nE '^(PASS|FAIL) reviewer ' <<<"$output" | tail -n 1 | cut -d: -f1)" \
    "$(($(grep -n '^PASS github push ' <<<"$output" | cut -d: -f1) - 1))"
  # Each call on the worker login: its directory, both tokens empty.
  assert_equal "$(sed 's/ GH_CONFIG_DIR=.*//' "$STUB_CALLS/gh.env")" "api repos/owner/agent-team
api repos/owner/agent-team/pulls?state=open&base=main&sort=created&direction=asc&per_page=1 --jq .[0].number // empty
api --include --method POST graphql --input -
api --include --method POST repos/owner/agent-team/branches/main/protection/enforce_admins --input /dev/null
api --include --method PATCH repos/owner/agent-team --input -
api --include --method PUT repos/owner/agent-team/pulls/7/merge --input -"
  assert_equal "$(sed 's/^.* GH_CONFIG_DIR=/GH_CONFIG_DIR=/' "$STUB_CALLS/gh.env" | sort -u)" \
    "GH_CONFIG_DIR=<$worker> GH_TOKEN=<> GITHUB_TOKEN=<>"
  # The push read asks for the base by GitHub's own owner and name, the setting sends the name
  # GitHub read, and the merge a sha that matches no head.
  assert_equal "$(sed -n 1p "$STUB_CALLS/gh.bodies" | jq -c .variables)" \
    '{"owner":"Owner","name":"Agent-Team","ref":"refs/heads/main"}'
  assert_equal "$(sed -n 2p "$STUB_CALLS/gh.bodies")" '{"name":"Agent-Team"}'
  assert_equal "$(sed -n 3p "$STUB_CALLS/gh.bodies")" '{"sha":"0000000000000000000000000000000000000000"}'
  # The drill counts the github calls with the attempts.
  assert_equal "$(drill_lines)" "$(checkout_drill_line pass "$n of $n attempts as expected")"
  assert_equal "${lines[-1]}" PASS
  left_nothing
}

@test "a registry still naming a moved repo's old owner has each github call ask for the repo where it is now" {
  login_on
  # bin/'s files are links to the run's shared copy: replace the file, never write into it.
  local moves=$CODE_CHECKOUT/bin/lib/repo-moves.json
  jq '.moves += [{from: "old-owner/agent-team", to: "owner/agent-team", on: "2026-11-01"}]' "$moves" >"$moves.new"
  rm "$moves"
  mv "$moves.new" "$moves"
  sed -i 's#^repo = "owner/agent-team"$#repo = "old-owner/agent-team"#' "$TEAM_HOME/projects.toml"
  run_bin -0 team-load-check --probe
  assert_equal "$(github_lines)" "$(refused_all)"
  assert_equal "$(grep -c old-owner "$STUB_CALLS/gh.env" || true)" 0
}

@test "each github call GitHub does not refuse fails the probe, naming its answer" {
  login_on
  local n
  n=$(($(total) + 4))
  echo true >"$STUB_FIXTURES/gh-push"
  echo 204 >"$STUB_FIXTURES/gh-protection"
  echo 200 >"$STUB_FIXTURES/gh-setting"
  echo 200 >"$STUB_FIXTURES/gh-merge"
  run_bin -1 team-load-check --probe
  assert_equal "$(github_lines)" "FAIL github push owner/agent-team: not refused (true)
FAIL github protection owner/agent-team: not refused (204)
FAIL github setting owner/agent-team: not refused (200)
FAIL github merge owner/agent-team: not refused (200)"
  assert_equal "$(drill_lines)" "$(checkout_drill_line fail "$((n - 4)) of $n attempts as expected")"
  assert_equal "${lines[-1]}" "load check FAILED"

  # Each alone fails the probe; a refusal of 404 passes as 403 does.
  local id answer
  for id in push protection setting merge; do
    rm "$STUB_FIXTURES"/gh-* "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-* "$TEAM_HOME/drills.jsonl"
    case $id in push) answer=true ;; *) answer=201 ;; esac
    echo "$answer" >"$STUB_FIXTURES/gh-$id"
    run_bin -1 team-load-check --probe
    assert_equal "$(grep '^FAIL' <<<"$output")" "FAIL github $id owner/agent-team: not refused ($answer)"
  done
  rm "$STUB_FIXTURES"/gh-* "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-*
  echo 404 >"$STUB_FIXTURES/gh-protection"
  echo 404 >"$STUB_FIXTURES/gh-setting"
  run_bin -0 team-load-check --probe
  assert_contains "$output" "PASS github protection owner/agent-team: refused (404)"
  assert_contains "$output" "PASS github setting owner/agent-team: refused (404)"
}

@test "a merge GitHub answers 405 for another reason than the push restriction is not shown, and does not fail the probe" {
  login_on
  local n
  n=$(($(total) + 4))
  echo 'Pull Request is not mergeable' >"$STUB_FIXTURES/gh-merge-message"
  run_bin -0 team-load-check --probe
  assert_equal "$(github_lines)" "$(refused_all | sed '$d')
WARN github merge owner/agent-team: not shown: GitHub refused the merge for another reason than the push restriction (405: Pull Request is not mergeable)"
  assert_equal "$(drill_lines)" "$(checkout_drill_line pass "$((n - 1)) of $((n - 1)) attempts as expected")"
  assert_equal "${lines[-1]}" PASS
}

@test "a merge GitHub answers 409 is not shown, and with no open pull request it is not tried; neither fails the probe" {
  login_on
  local n
  n=$(($(total) + 4))
  echo 409 >"$STUB_FIXTURES/gh-merge"
  run_bin -0 team-load-check --probe
  assert_equal "$(github_lines)" "$(refused_all | sed '$d')
WARN github merge owner/agent-team: not shown: GitHub compared the head first"
  # The drill counts only the calls that showed a refusal.
  assert_equal "$(drill_lines)" "$(checkout_drill_line pass "$((n - 1)) of $((n - 1)) attempts as expected")"
  assert_equal "${lines[-1]}" PASS

  rm "$STUB_FIXTURES"/gh-* "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-* "$STUB_CALLS/gh.env" "$TEAM_HOME/drills.jsonl"
  echo '[]' >"$STUB_FIXTURES/pulls"
  run_bin -0 team-load-check --probe
  assert_equal "$(github_lines)" "$(refused_all | sed '$d')
WARN github merge owner/agent-team: not tried: no open pull request into main"
  [[ $(cat "$STUB_CALLS/gh.env") != *"/merge"* ]]
  assert_equal "${lines[-1]}" PASS

  # A repository the worker login cannot read is no call tried, and fails each.
  rm "$STUB_FIXTURES"/launched-* "$STUB_FIXTURES"/removed-* "$STUB_FIXTURES/pulls" "$STUB_CALLS/gh.env"
  echo 404 >"$STUB_FIXTURES/repo-read"
  run_bin -1 team-load-check --probe
  assert_equal "$(github_lines)" "$(printf 'FAIL github %s owner/agent-team: not tried: the repository cannot be read as the worker login (gh: refused (HTTP 404))\n' \
    push protection setting merge)"
  assert_equal "$(wc -l <"$STUB_CALLS/gh.env")" 1
}
