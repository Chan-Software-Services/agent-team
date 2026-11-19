#!/usr/bin/env bats
# The GitHub logins' library, bin/lib/github-login.sh, as a script that sources bin/lib/team.sh
# has it: the worker login's constant, read from a copy of bin/ (worker_login_on, worker_login_off),
# the login's file judged by its type, size and mode alone, the environment a session on it gets,
# and gh run on the worker login and on the owner login, shown by a stub gh that logs the three
# login variables beside each call.

load helpers/common

setup() {
  sandbox
  # The stub gh logs, beside each call, the login variables it ran with, "unset" for one it
  # did not have, and exits GH_EXIT (default 0).
  stub_script gh <<'EOF'
printf 'GH_CONFIG_DIR=<%s> GH_TOKEN=<%s> GITHUB_TOKEN=<%s>\n' "${GH_CONFIG_DIR-unset}" "${GH_TOKEN-unset}" \
  "${GITHUB_TOKEN-unset}" >>"$STUB_CALLS/gh.env"
exit "${GH_EXIT:-0}"
EOF
}

# Run the library's <code> in a fresh bash that sources bin/lib/team.sh from CODE_CHECKOUT (made
# by worker_login_on or worker_login_off), with stderr apart: library <code>
library() {
  guard_sandbox
  run --separate-stderr bash -c 'source "$1/bin/lib/team.sh"; eval "$2"' library "$CODE_CHECKOUT" "$1"
}

worker_dir() {
  printf '%s\n' "$HOME/.config/agent-team/gh-worker"
}

@test "with no bin/lib/worker-login the worker login is off: no login, no environment, gh as the caller has it" {
  worker_login_off
  library 'worker_login; echo "status $?"; worker_login_env; echo "status $?"'
  assert_equal "$status" 0
  assert_equal "$output" "$(printf '%s\n' 'status 0' 'status 0')"
  assert_equal "$stderr" ""
  GH_CONFIG_DIR=/elsewhere GH_TOKEN=caller-token library 'worker_gh api user'
  assert_equal "$status" 0
  assert_equal "$(stub_calls gh)" '["api","user"]'
  assert_equal "$(cat "$STUB_CALLS/gh.env")" 'GH_CONFIG_DIR=</elsewhere> GH_TOKEN=<caller-token> GITHUB_TOKEN=<unset>'
}

@test "a constant of one login= line names the worker login, team-worker-bot by default" {
  worker_login_on
  library worker_login
  assert_equal "$status" 0
  assert_equal "$output" team-worker-bot
  worker_login_on Some-Bot-2
  library worker_login
  assert_equal "$output" Some-Bot-2
  # The longest GitHub login, 39 characters.
  worker_login_on "a$(printf 'b%.0s' {1..37})c"
  library worker_login
  assert_equal "$status" 0
  assert_equal "${#output}" 39
}

@test "a constant that is anything but one login= line of a GitHub login is refused, naming the file" {
  worker_login_off
  local file=$CODE_CHECKOUT/bin/lib/worker-login body
  local bodies=('' $'\n' 'login=' 'login=-bot' 'login=bot-' 'login=a--b' 'login=a_b' 'login=a.b' 'login=a b'
    " login=bot" 'login =bot' 'user=bot' 'bot' $'login=bot\n\n' $'login=bot\nlogin=other\n'
    "login=a$(printf 'b%.0s' {1..38})c")
  for body in "${bodies[@]}"; do
    printf '%s' "$body" >"$file"
    library 'worker_login'
    [[ $status == 1 && -z $output && $stderr == "library: $file is not one login=<a GitHub login> line" ]] ||
      { printf 'body %q: exit %s, stdout %s, stderr %s\n' "$body" "$status" "$output" "$stderr" >&2; return 1; }
    library 'worker_login_env'
    [[ $status == 1 && -z $output ]] || { printf 'env of body %q: exit %s\n' "$body" "$status" >&2; return 1; }
  done
  rm -f "$file"
  mkdir "$file"
  library worker_login
  assert_equal "$status" 1
  assert_equal "$stderr" "library: $file is not one login=<a GitHub login> line"
}

@test "the worker login's file is judged in order: its directory, then hosts.yml missing, not a file, empty, off mode 600" {
  worker_login_off
  local dir shown=\~/.config/agent-team/gh-worker
  dir=$(worker_dir)
  library worker_login_problem
  assert_equal "$output" "$shown is missing"
  mkdir -p "${dir%/*}"
  touch "$dir"
  library worker_login_problem
  assert_equal "$output" "$shown is not a directory"
  rm -f "$dir"
  mkdir -m 700 "$dir"
  library worker_login_problem
  assert_equal "$status" 0
  assert_equal "$output" "$shown/hosts.yml is missing"
  # A pipe is no file, and the judging opens none: reading it would never end.
  mkfifo "$dir/hosts.yml"
  library worker_login_problem
  assert_equal "$output" "$shown/hosts.yml is not a file"
  rm -f "$dir/hosts.yml"
  mkdir "$dir/hosts.yml"
  library worker_login_problem
  assert_equal "$output" "$shown/hosts.yml is not a file"
  rmdir "$dir/hosts.yml"
  install -m 600 /dev/null "$dir/hosts.yml"
  library worker_login_problem
  assert_equal "$output" "$shown/hosts.yml is empty"
  echo 'github.com:' >"$dir/hosts.yml"
  chmod 644 "$dir/hosts.yml"
  library worker_login_problem
  assert_equal "$output" "$shown/hosts.yml is mode 644, not 600"
  chmod 000 "$dir/hosts.yml"
  library worker_login_problem
  assert_equal "$output" "$shown/hosts.yml is mode 0, not 600"
  assert_equal "$stderr" ""
}

@test "a usable worker login's file is no problem: worker_login_problem fails, printing nothing" {
  worker_login_on
  library worker_login_problem
  assert_equal "$status" 1
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  # The constant plays no part: the file alone is judged.
  worker_login_off
  library worker_login_problem
  assert_equal "$status" 1
}

@test "a session on the worker login gets its gh directory and both token variables empty" {
  worker_login_on
  library worker_login_env
  assert_equal "$status" 0
  assert_equal "$output" "$(printf '%s\n' "GH_CONFIG_DIR=$(worker_dir)" GH_TOKEN= GITHUB_TOKEN=)"
  library worker_login_dir
  assert_equal "$output" "$(worker_dir)"
}

@test "a session's settings env is that environment as an object, {} with no login, and the launchers' refusal when its file is not usable" {
  worker_login_on team-bot
  library 'worker_login_settings_env "$(worker_login)"'
  assert_equal "$status" 0
  assert_equal "$output" "$(jq -cn --arg dir "$(worker_dir)" '{GH_CONFIG_DIR: $dir, GH_TOKEN: "", GITHUB_TOKEN: ""}')"
  library 'worker_login_settings_env ""'
  assert_equal "$output" '{}'
  rm "$(worker_dir)/hosts.yml"
  library 'worker_login_settings_env team-bot'
  assert_equal "$status" 1
  assert_equal "$output" ""
  # shellcheck disable=SC2088 # ~ is part of the message as the library prints it
  assert_equal "$stderr" "library: the worker login team-bot is not on this machine (~/.config/agent-team/gh-worker/hosts.yml is missing): Daniel's team-secrets restore brings it (the secret worker-github-login)"
}

@test "session_login is worker only with GH_CONFIG_DIR the worker login's directory, else owner, on or off" {
  worker_login_off
  library 'session_login'
  assert_equal "$output" owner
  GH_CONFIG_DIR=$(worker_dir) library 'session_login'
  assert_equal "$output" worker
  GH_CONFIG_DIR=$(worker_dir)// library 'session_login'
  assert_equal "$output" worker
  for dir in /elsewhere "$(worker_dir)-old" "" /; do
    GH_CONFIG_DIR=$dir library 'session_login'
    assert_equal "$output" owner
  done
  worker_login_on
  library 'session_login; with_worker_login session_login; GH_CONFIG_DIR=$(worker_login_dir) with_owner_login session_login'
  assert_equal "$output" "$(printf '%s\n' owner worker owner)"
  assert_equal "$(stub_calls gh)" ""
}

@test "worker_gh runs gh on the worker login's directory, whatever login the caller has, with its arguments and exit" {
  worker_login_on
  GH_CONFIG_DIR=/elsewhere GH_TOKEN=caller-token GITHUB_TOKEN=caller-token GH_EXIT=3 \
    library 'worker_gh api -i user; echo "status $?"; echo "after <${GH_CONFIG_DIR-unset}> <${GH_TOKEN-unset}>"'
  assert_equal "$output" "$(printf '%s\n' 'status 3' 'after </elsewhere> <caller-token>')"
  assert_equal "$(stub_calls gh)" '["api","-i","user"]'
  assert_equal "$(cat "$STUB_CALLS/gh.env")" "GH_CONFIG_DIR=<$(worker_dir)> GH_TOKEN=<> GITHUB_TOKEN=<>"
}

@test "worker_gh refuses with a malformed constant and runs no gh" {
  worker_login_off
  echo 'login=' >"$CODE_CHECKOUT/bin/lib/worker-login"
  library 'worker_gh api user'
  assert_equal "$status" 1
  assert_equal "$stderr" "library: $CODE_CHECKOUT/bin/lib/worker-login is not one login=<a GitHub login> line"
  assert_equal "$(stub_calls gh)" ""
}

@test "owner_gh runs gh with the three login variables unset, leaving the caller's as they were" {
  worker_login_on
  GH_CONFIG_DIR=/elsewhere GH_TOKEN=caller-token GITHUB_TOKEN=caller-token GH_EXIT=4 \
    library 'owner_gh auth status; echo "status $?"; echo "after <${GH_CONFIG_DIR-unset}> <${GITHUB_TOKEN-unset}>"'
  assert_equal "$output" "$(printf '%s\n' 'status 4' 'after </elsewhere> <caller-token>')"
  assert_equal "$(stub_calls gh)" '["auth","status"]'
  assert_equal "$(cat "$STUB_CALLS/gh.env")" 'GH_CONFIG_DIR=<unset> GH_TOKEN=<unset> GITHUB_TOKEN=<unset>'
}

@test "use_owner_login unsets the three login variables in the caller, for gh and every command after" {
  worker_login_on
  GH_CONFIG_DIR=/elsewhere GH_TOKEN=caller-token GITHUB_TOKEN=caller-token \
    library 'use_owner_login; gh api user; env | grep -cE "^(GH_CONFIG_DIR|GH_TOKEN|GITHUB_TOKEN)=" || true'
  assert_equal "$output" 0
  assert_equal "$(cat "$STUB_CALLS/gh.env")" 'GH_CONFIG_DIR=<unset> GH_TOKEN=<unset> GITHUB_TOKEN=<unset>'
}

@test "the login variables are the owner login's names, and the token's scopes are repo and workflow" {
  worker_login_off
  library 'printf "%s\n" "${LOGIN_VARIABLES[@]}"; echo -; owner_login_env; echo -; printf "%s\n" "${WORKER_TOKEN_SCOPES[@]}"'
  assert_equal "$output" "$(printf '%s\n' GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN - GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN - repo workflow)"
}
