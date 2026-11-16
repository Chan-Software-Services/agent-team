#!/usr/bin/env bats
# shellcheck disable=SC2153 # CODE_CHECKOUT and the other globals are helpers/doctor.bash's
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the worker login line, each of its steps in order, on a stub gh that answers as
# GitHub would for the login each call runs on (a token's, the worker login's directory's or the
# owner's) and logs the login variables beside each call, real git asking it through the global
# credential helpers, and a stub timeout that logs each bounded call.

load helpers/common
load helpers/doctor

CONVENTIONER_REPO=Chan-Software-Services/Conventioner
DOC='sops/machine-setup.md, "The worker login"'
NEW_TOKEN='fix: a new token, as sops/machine-setup.md says'

setup() {
  sandbox
  doctor_machine
  only_checks 111-worker-login.sh
  tools_at arch
  worker_login_on
  # Conventioner's base is dev, so its main is asked too; site's is main.
  local registry=$TEAM_HOME/projects.toml
  sed '0,/^base = "main"$/s//base = "dev"/' "$registry" >"$registry.new"
  mv "$registry.new" "$registry"
  # Git's global helpers for github.com, as gh auth setup-git writes them.
  git config --global --add credential.https://github.com.helper ''
  git config --global --add credential.https://github.com.helper '!gh auth git-credential'
  # Everything right: the worker login's token holds repo and workflow, the records repository
  # answers it 404, it pushes to both projects and administers neither, and every base and main
  # refuses it a push.
  echo 'repo, workflow' >"$STUB_FIXTURES/scopes"
  echo 404 >"$STUB_FIXTURES/records-status"
  mkdir -p "$STUB_FIXTURES/repos" "$STUB_FIXTURES/refs"
  repo_facts "$CONVENTIONER_REPO" public Organization push
  repo_facts owner/site public User push
  repo_refs "$CONVENTIONER_REPO" refused refused
  repo_refs owner/site refused refused
  # timeout runs its command at once, logging the call (its arguments are the stub's log).
  stub_command timeout
  stub_script timeout <<'EOF'
exec "${@:2}"
EOF
  stub_script gh <<'EOF'
worker_dir=$HOME/.config/agent-team/gh-worker
printf 'GH_CONFIG_DIR=<%s> GH_TOKEN=<%s> GITHUB_TOKEN=<%s>\n' "${GH_CONFIG_DIR-unset}" "${GH_TOKEN-unset}" \
  "${GITHUB_TOKEN-unset}" >>"$STUB_CALLS/gh.env"
# The account this call runs as: its token's, else the worker login directory's, else the owner's.
if [[ -n ${GH_TOKEN:-} ]]; then
  as=${GH_TOKEN#fixture-token-of-} worker=0
elif [[ ${GH_CONFIG_DIR:-} == "$worker_dir" ]]; then
  as=$(cat "$STUB_FIXTURES/worker-as" 2>/dev/null || echo team-worker-bot) worker=1
else
  as=team-owner worker=0
fi
case $* in
  'auth status --hostname github.com') echo "  - Logged in to github.com account $as" ;;
  'auth git-credential get')
    cat >/dev/null
    token=fixture-token-of-team-owner
    ((worker == 0)) || token=$(cat "$STUB_FIXTURES/git-token" 2>/dev/null || echo fixture-token-of-team-worker-bot)
    printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n' "$token" ;;
  'api -i user')
    if [[ -f $STUB_FIXTURES/user.err ]]; then cat "$STUB_FIXTURES/user.err" >&2; exit 1; fi
    # A scopes fixture of "none" is a token GitHub names no scopes for, a fine-grained one.
    if [[ $(cat "$STUB_FIXTURES/scopes") == none ]]; then
      printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{"login":"%s","id":1}\n' "$as"
    else
      printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nX-Oauth-Scopes: %s\r\n\r\n{"login":"%s","id":1}\n' \
        "$(cat "$STUB_FIXTURES/scopes")" "$as"
    fi ;;
  'api user --jq .login') echo "$as" ;;
  'api repos/Chan-Software-Services/agent-team-records')
    case $(cat "$STUB_FIXTURES/records-status") in
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      403) echo "gh: Forbidden (HTTP 403)" >&2; exit 1 ;;
      none) echo "error connecting to api.github.com" >&2; exit 1 ;;
      *) echo '{"full_name": "Chan-Software-Services/agent-team-records"}' ;;
    esac ;;
  'api repos/'*)
    facts=$STUB_FIXTURES/repos/${2#repos/}.json
    if [[ ! -f $facts ]]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    cat "$facts" ;;
  'api graphql '*)
    owner='' name=''
    for arg; do
      case $arg in owner=*) owner=${arg#owner=} ;; name=*) name=${arg#name=} ;; esac
    done
    cat "$STUB_FIXTURES/refs/$owner/$name.json" ;;
  *) echo "gh stub: unplanned call: $*" >&2; exit 127 ;;
esac
EOF
}

# What GitHub's repository read answers the worker login for <repo>: repo_facts <repo>
# <public|private> <Organization|User> <push|pull|admin|maintain>, the last its role.
repo_facts() {
  mkdir -p "$STUB_FIXTURES/repos/${1%/*}"
  jq -n --arg private "$2" --arg type "$3" --arg role "$4" '{private: ($private == "private"), owner: {type: $type},
    permissions: {admin: ($role == "admin"), maintain: ($role == "admin" or $role == "maintain"),
      push: ($role != "pull"), triage: true, pull: true}}' >"$STUB_FIXTURES/repos/$1.json"
}

# What GitHub's GraphQL answers the worker login for <repo>'s base and main refs, each refused (a
# rule that refuses it a push), pushed (a rule that lets it), unruled (a branch with no rule) or
# absent (no such branch): repo_refs <repo> <base> <main>
repo_refs() {
  mkdir -p "$STUB_FIXTURES/refs/${1%/*}"
  jq -n --arg base "$2" --arg main "$3" 'def ref($kind): {refused: {refUpdateRule: {viewerCanPush: false}},
      pushed: {refUpdateRule: {viewerCanPush: true}}, unruled: {refUpdateRule: null}, absent: null}[$kind];
    {data: {repository: {base: ref($base), main: ref($main)}}}' >"$STUB_FIXTURES/refs/$1.json"
}

# The worker login line's FAIL with <reason> and <fix>.
fails_with() {
  run_bin -1 team-doctor
  assert_equal "$(line_of 'worker login')" "FAIL worker login: $1; fix: $2"
}

@test "with no bin/lib/worker-login the worker login line passes, saying it is off, and asks GitHub nothing" {
  worker_login_off
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login')" "PASS worker login: off, since no bin/lib/worker-login names the account: every session runs on the machine's own GitHub login"
  assert_equal "$(stub_calls gh)" ""
}

@test "the worker login line fails on a malformed bin/lib/worker-login, naming it, and asks GitHub nothing" {
  echo 'login=' >"$CODE_CHECKOUT/bin/lib/worker-login"
  fails_with "$CODE_CHECKOUT/bin/lib/worker-login is not one login=<a GitHub login> line" \
    "give bin/lib/worker-login its one line through a PR to dev"
  assert_equal "$(stub_calls gh)" ""
}

@test "the worker login line fails on its file missing, empty or off mode 600, with Daniel's restore" {
  local file=$HOME/.config/agent-team/gh-worker/hosts.yml shown=\~/.config/agent-team/gh-worker/hosts.yml
  chmod 644 "$file"
  fails_with "$shown is mode 644, not 600" "Daniel's own terminal: team-secrets restore"
  : >"$file"
  chmod 600 "$file"
  fails_with "$shown is empty" "Daniel's own terminal: team-secrets restore"
  rm "$file"
  fails_with "$shown is missing" "Daniel's own terminal: team-secrets restore"
  assert_equal "$(stub_calls gh)" ""
}

@test "the worker login line fails when git's global helpers for github.com are not an empty value then gh's alone" {
  local key=credential.https://github.com.helper reason="git has another credential helper for github.com, which answers before the worker login"
  git config --global --unset-all "$key"
  fails_with "$reason" "gh auth setup-git"
  git config --global --add "$key" '!gh auth git-credential'
  fails_with "$reason" "gh auth setup-git"
  git config --global --unset-all "$key"
  git config --global --add "$key" ''
  git config --global --add "$key" store
  fails_with "$reason" "gh auth setup-git"
  git config --global --add "$key" '!gh auth git-credential'
  fails_with "$reason" "gh auth setup-git"
  assert_equal "$(stub_calls gh)" ""
  # gh's own path, as gh auth setup-git writes it, quoted or not, is gh's.
  git config --global --unset-all "$key"
  git config --global --add "$key" ''
  git config --global --add "$key" "!$TOOL_STUBS/gh auth git-credential"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login' | cut -d: -f1)" "PASS worker login"
  git config --global --replace-all "$key" "!'$TOOL_STUBS/gh' auth git-credential" '^!'
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login' | cut -d: -f1)" "PASS worker login"
}

@test "the worker login line fails on GitHub refusing the worker login, with its first error line" {
  printf '%s\n' "gh: Bad credentials (HTTP 401)" "more" >"$STUB_FIXTURES/user.err"
  fails_with "GitHub refuses the worker login: gh: Bad credentials (HTTP 401)" "${NEW_TOKEN#fix: }"
}

@test "the worker login line fails on a login other than the constant's, in any case but its own" {
  echo some-other-bot >"$STUB_FIXTURES/worker-as"
  fails_with "the worker login on this machine is some-other-bot, not team-worker-bot" "${NEW_TOKEN#fix: }"
  echo Team-Worker-Bot >"$STUB_FIXTURES/worker-as"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login' | cut -d: -f1)" "PASS worker login"
}

@test "the worker login line fails on the owner's own account" {
  worker_login_on Team-Owner
  echo Team-Owner >"$STUB_FIXTURES/worker-as"
  fails_with "the worker login on this machine is the owner's account" "${NEW_TOKEN#fix: }"
  # The owner's account is asked on the owner login, whatever the doctor's session has.
  assert_equal "$(grep -c 'GH_CONFIG_DIR=<unset> GH_TOKEN=<unset> GITHUB_TOKEN=<unset>' "$STUB_CALLS/gh.env")" 1
}

@test "the worker login line fails when git answers for github.com with another login than the worker login" {
  echo fixture-token-of-team-owner >"$STUB_FIXTURES/git-token"
  fails_with "git pushes as team-owner, not the worker login" "gh auth setup-git"
}

@test "the worker login line fails on a token scope beyond repo and workflow, and passes on fewer" {
  echo 'admin:org, repo, workflow' >"$STUB_FIXTURES/scopes"
  fails_with "the worker login's token holds admin:org, repo, workflow, more than repo and workflow" "${NEW_TOKEN#fix: }"
  echo 'repo' >"$STUB_FIXTURES/scopes"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login' | cut -d: -f1)" "PASS worker login"
}

@test "the worker login line warns on a token GitHub names no scopes for, which is no classic token" {
  echo none >"$STUB_FIXTURES/scopes"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login')" "WARN worker login: team-worker-bot: pushes to 2 projects and administers none, but GitHub names no scopes for its token, so it is no classic token and its scopes go unchecked; $NEW_TOKEN"
}

@test "the worker login line says GitHub did not answer when the records repository's call fails with no HTTP status" {
  echo none >"$STUB_FIXTURES/records-status"
  fails_with "GitHub did not answer whether the worker login reaches the records repository: error connecting to api.github.com" \
    "run team-doctor again once GitHub answers"
}

@test "the worker login line fails when the records repository answers the worker login anything but 404" {
  local fix="Daniel removes team-worker-bot's access to Chan-Software-Services/agent-team-records on GitHub"
  echo 200 >"$STUB_FIXTURES/records-status"
  fails_with "the worker login reaches the records repository" "$fix"
  echo 403 >"$STUB_FIXTURES/records-status"
  fails_with "the worker login reaches the records repository" "$fix"
}

@test "the worker login line fails on a project it cannot push to, or cannot see" {
  repo_facts "$CONVENTIONER_REPO" public Organization pull
  fails_with "the worker login cannot push to $CONVENTIONER_REPO" "Daniel gives team-worker-bot the Write role on $CONVENTIONER_REPO, as $DOC says"
  rm "$STUB_FIXTURES/repos/$CONVENTIONER_REPO.json"
  fails_with "the worker login cannot push to $CONVENTIONER_REPO" "Daniel gives team-worker-bot the Write role on $CONVENTIONER_REPO, as $DOC says"
}

@test "the worker login line fails on a project it administers or maintains" {
  repo_facts owner/site public User admin
  fails_with "the worker login administers owner/site" "Daniel gives team-worker-bot the Write role on owner/site, not Maintain or Admin"
  repo_facts owner/site public User maintain
  fails_with "the worker login administers owner/site" "Daniel gives team-worker-bot the Write role on owner/site, not Maintain or Admin"
}

@test "the worker login line fails on a base or main of a public organisation repository GitHub lets it push to" {
  repo_refs "$CONVENTIONER_REPO" pushed refused
  fails_with "GitHub does not restrict dev on $CONVENTIONER_REPO to the owner" "$DOC"
  # A branch with no protection rule at all is one too, and both are named.
  repo_refs "$CONVENTIONER_REPO" unruled pushed
  fails_with "GitHub does not restrict dev and main on $CONVENTIONER_REPO to the owner" "$DOC"
  repo_refs "$CONVENTIONER_REPO" refused unruled
  fails_with "GitHub does not restrict main on $CONVENTIONER_REPO to the owner" "$DOC"
}

@test "the worker login line warns on each base or main of a private repository or a personal account's" {
  repo_facts "$CONVENTIONER_REPO" private Organization push
  repo_refs "$CONVENTIONER_REPO" unruled pushed
  repo_refs owner/site unruled absent
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login')" "WARN worker login: team-worker-bot: pushes to 2 projects and administers none, but $CONVENTIONER_REPO: GitHub cannot restrict dev and main here (a private repository, or a personal account's); owner/site: GitHub cannot restrict main here (a private repository, or a personal account's); fix: $DOC"
}

@test "the worker login line passes with everything right, asking each base and main as the worker login, every call bounded" {
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login')" "PASS worker login: team-worker-bot: pushes to 2 projects, administers none, merges into none of their base branches"
  # Each project's base and main are asked; site's base is main, so its main is read as its base.
  assert_equal "$(stub_calls gh | jq -r 'select(.[1] == "graphql") | map(select(test("^(owner|name|base|main)="))) | join(" ")')" \
    "owner=Chan-Software-Services name=Conventioner base=refs/heads/dev main=refs/heads/main
owner=owner name=site base=refs/heads/main main=refs/heads/main"
  # Every GitHub call runs on the worker login but the owner's account read, and the one call
  # with git's answer, which runs on its token.
  local worker="GH_CONFIG_DIR=<$HOME/.config/agent-team/gh-worker>"
  assert_equal "$(cut -d' ' -f1 "$STUB_CALLS/gh.env" | LC_ALL=C sort | uniq -c | sed 's/^ *//')" "8 $worker
1 GH_CONFIG_DIR=<unset>"
  assert_equal "$(grep -c "GH_TOKEN=<fixture-token-of-team-worker-bot>" "$STUB_CALLS/gh.env")" 1
  # Every gh call, and git's, went through timeout 30; git's helper call is git's own.
  assert_equal "$(stub_calls timeout | jq -r '.[0:2] | join(" ")' | LC_ALL=C sort | uniq -c | sed 's/^ *//')" "8 30 gh
1 30 git"
}

@test "the worker login line never prints, logs or passes as an argument the worker login's token" {
  local all=''
  run_bin -0 team-doctor
  all+=$output
  run_bin -0 team-doctor --json
  all+=$output
  # A failing step prints its reason, never the token git gave.
  echo fixture-token-of-team-owner >"$STUB_FIXTURES/git-token"
  run_bin -1 team-doctor
  all+=$output
  echo some-other-bot >"$STUB_FIXTURES/worker-as"
  run_bin -1 team-doctor
  all+=$output
  assert_equal "$(grep -c fixture-token-of <<<"$all" || true)" 0
  # Nor is it an argument of gh, of timeout or of git.
  assert_equal "$(cat "$STUB_CALLS/gh.log" "$STUB_CALLS/timeout.log" | grep -c fixture-token-of || true)" 0
  # It reached gh through the environment of git's one call alone.
  assert_equal "$(grep -c 'GH_TOKEN=<fixture-token-of-' "$STUB_CALLS/gh.env")" 3
}

@test "on macOS with a no-mistakes project the worker login line warns that the gate's daemon runs on the machine's own login" {
  on_macos
  tools_at macos
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login')" "WARN worker login: team-worker-bot: pushes to 2 projects and administers none, but the gate's daemon runs on the machine's own GitHub login on macOS"
  # Without one, it passes.
  sed -i 's/^delivery = "no-mistakes"$/delivery = "direct-pr"/' "$TEAM_HOME/projects.toml"
  run_bin -0 team-doctor
  assert_equal "$(line_of 'worker login' | cut -d: -f1)" "PASS worker login"
}
