#!/usr/bin/env bats
# shellcheck disable=SC2153 # TOOL_STUBS and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the team home login line, which holds the team home's own
# credential.https://github.com.helper to an empty value, then this machine's gh on the owner
# login, and the effect of those values on real git.

load helpers/common
load helpers/doctor

KEY=credential.https://github.com.helper
FAIL_LINE="FAIL team home login: the team home's git does not name the owner login for github.com; fix: team-bootstrap"

setup() {
  sandbox
  doctor_machine
  only_checks 088-team-home-login.sh
  tools_at arch
}

# The team home's own values of the key, one per line.
helpers() {
  git -C "${TEAM_HOME:?}" config --local --get-all "$KEY"
}

# Give the team home's own config exactly the values <value>... of the key: set_helpers <value>...
set_helpers() {
  git -C "${TEAM_HOME:?}" config --local --unset-all "$KEY" || true
  local value
  for value in "$@"; do git -C "${TEAM_HOME:?}" config --local --add "$KEY" "$value"; done
}

@test "the team home login line passes on an empty value, then the gh of this machine on the owner login" {
  assert_equal "$(helpers)" "
!env -u GH_CONFIG_DIR -u GH_TOKEN -u GITHUB_TOKEN $TOOL_STUBS/gh auth git-credential"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home login')" "PASS team home login: its git asks $TOOL_STUBS/gh for github.com on the owner login"
}

@test "with the worker login off, the team home login line only warns on a team home without the two values, so nothing that stops on a FAIL stops on it" {
  set_helpers
  worker_login_off
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home login')" "WARN team home login: the team home's git does not name the owner login for github.com, which it needs once bin/lib/worker-login names the worker login; fix: team-bootstrap"
  set_helpers '' "!env -u GH_CONFIG_DIR -u GH_TOKEN -u GITHUB_TOKEN /opt/other/gh auth git-credential"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home login' | cut -d: -f1)" "WARN team home login"
  # Once the constant names the worker login, the same team home fails.
  worker_login_on
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home login')" "$FAIL_LINE"
}

@test "with the worker login on, the team home login line fails with no value, without the empty value first, with another gh, or with a third value" {
  local helper="!env -u GH_CONFIG_DIR -u GH_TOKEN -u GITHUB_TOKEN $TOOL_STUBS/gh auth git-credential"
  worker_login_on
  set_helpers
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home login')" "$FAIL_LINE"
  # The global config's helpers would answer before it.
  set_helpers "$helper"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home login')" "$FAIL_LINE"
  set_helpers '' "!env -u GH_CONFIG_DIR -u GH_TOKEN -u GITHUB_TOKEN /opt/other/gh auth git-credential"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home login')" "$FAIL_LINE"
  # A third value, empty or not, after the two.
  set_helpers '' "$helper" ''
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home login')" "$FAIL_LINE"
  set_helpers '' "$helper" store
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home login')" "$FAIL_LINE"
  # A session's login variables dropped from the helper.
  set_helpers '' "!$TOOL_STUBS/gh auth git-credential"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home login')" "$FAIL_LINE"
  # The values in the global config alone are not the team home's own.
  set_helpers
  git config --global --add "$KEY" ''
  git config --global --add "$KEY" "$helper"
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home login')" "$FAIL_LINE"
  set_helpers '' "$helper"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'team home login' | cut -d: -f1)" "PASS team home login"
}

@test "the team home login line is left out while the team home line fails" {
  git -C "${TEAM_HOME:?}" remote rename origin elsewhere
  run_bin -1 team-doctor
  assert_equal "$(line_of 'team home login')" ""
}

@test "with those values, git's credentials for github.com come from gh with the session's login variables unset, and no other helper is asked" {
  # gh's git-credential logs the login variables it sees and answers the owner's credentials.
  stub_script gh <<'EOF'
case $* in
  'auth git-credential get')
    printf 'GH_CONFIG_DIR=%s GH_TOKEN=%s GITHUB_TOKEN=%s\n' "${GH_CONFIG_DIR-unset}" "${GH_TOKEN-unset}" \
      "${GITHUB_TOKEN-unset}" >>"$STUB_CALLS/gh.env"
    printf '%s\n' protocol=https host=github.com username=owner password=owner-fixture-token ;;
  *) echo "gh stub: unplanned call: $*" >&2; exit 127 ;;
esac
EOF
  # A global helper for github.com, as gh auth setup-git leaves one, which the empty value drops.
  git config --global --add "$KEY" "!echo global >>$STUB_CALLS/global-helper.log; echo username=global; echo password=global-token #"
  run -0 env GH_CONFIG_DIR="$HOME/.config/agent-team/gh-worker" GH_TOKEN= GITHUB_TOKEN=worker-fixture-token \
    GIT_TERMINAL_PROMPT=0 git -C "${TEAM_HOME:?}" credential fill <<<$'protocol=https\nhost=github.com\n'
  assert_equal "$output" "protocol=https
host=github.com
username=owner
password=owner-fixture-token"
  assert_equal "$(cat "$STUB_CALLS/gh.env")" "GH_CONFIG_DIR=unset GH_TOKEN=unset GITHUB_TOKEN=unset"
  [[ ! -e $STUB_CALLS/global-helper.log ]]
  # Outside the team home the global helper answers, as it does for a project checkout.
  run -0 env GIT_TERMINAL_PROMPT=0 git -C "${HOME:?}" credential fill <<<$'protocol=https\nhost=github.com\n'
  assert_contains "$output" password=global-token
  assert_equal "$(cat "$STUB_CALLS/global-helper.log")" global
}
