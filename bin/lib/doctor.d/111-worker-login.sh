# worker login  The GitHub login the team's sessions run on (worker_login in
#               bin/lib/github-login.sh), its steps in order, stopping at the first that fails:
#               passes saying it is off with no bin/lib/worker-login; else fails on a malformed
#               bin/lib/worker-login, on its file ~/.config/agent-team/gh-worker/hosts.yml not
#               usable (missing, not a file, empty or off mode 600; no byte of it read), on git's
#               global helpers for github.com being anything but an empty value then one gh auth
#               git-credential, on GitHub refusing it, on its login being another than the
#               constant's or the owner login's own, on git answering for github.com with another
#               login, on its token holding a scope beyond repo and workflow, on the records
#               repository answering it anything but 404, and, per registered project, on it not
#               pushing to the repository or administering it, and on a public organisation
#               repository whose base (or main, when it has one that is not the base) GitHub lets
#               it push to. Warns, where it would pass, naming each such branch of a private
#               repository or a personal account's, which GitHub cannot restrict, and on macOS
#               with a no-mistakes project registered, since the gate's daemon there runs on the
#               machine's own login. Every GitHub call is bounded to 30 s; the token is never
#               printed.
# shellcheck shell=bash
# shellcheck disable=SC2154 # err and os, the doctor's and the os check's
# reads state from: 010-os.sh

# The login git answers for github.com on the worker login, asked of GitHub with the password git
# gives, which reaches gh only through git_token_login's environment and is never printed:
# worker_git_login <dir>, git run in <dir>, outside every checkout, so only the global helpers
# answer. On failure, its reason is the first line of $err.
worker_git_login() {
  local git_dir=$1 git_answer git_line git_password=''
  if ! git_answer=$(printf 'protocol=https\nhost=github.com\n\n' |
    GIT_TERMINAL_PROMPT=0 with_worker_login bounded 30 git -C "$git_dir" credential fill 2>"$err"); then
    echo "git finds no login for github.com on the worker login: $(first_error)" >"$err"
    return 1
  fi
  while IFS= read -r git_line; do
    [[ $git_line != password=* ]] || git_password=${git_line#password=}
  done <<<"$git_answer"
  if [[ -z $git_password ]]; then
    echo "git finds no login for github.com on the worker login: its answer holds no password" >"$err"
    return 1
  fi
  if ! with_worker_login git_token_login </dev/null 2>"$err"; then
    echo "GitHub refuses the login git answers with: $(first_error)" >"$err"
    return 1
  fi
}

# gh api user's login for the password git gave (worker_git_login's git_password), on the worker
# login's environment but for GH_TOKEN, which gh reads before its directory: git_token_login
git_token_login() {
  export GH_TOKEN=$git_password
  bounded 30 gh api user --jq .login
}

# The branches of <repo> GitHub lets the worker login push to, one per line, from its GraphQL
# answer on stdin: its base <base>, then main when <main> is true. A branch with no protection rule
# is one; one that is not there is left out: unrestricted_branches <base> <main>
unrestricted_branches() {
  jq -r --arg base "$1" --argjson main "$2" '(.data.repository // error("GitHub answered with no repository")) as $r
    | ["base", $base], (if $main then ["main", "main"] else empty end)
    | select($r[.[0]] != null and ($r[.[0]].refUpdateRule == null or $r[.[0]].refUpdateRule.viewerCanPush == true))
    | .[1]'
}

worker_login_check() {
  local login problem helpers=() gh_helper reply headers body seen owner_login pushes scope scopes=() extra=() held
  local records project repo base facts refs main branches=() branch warn=() warn_fix='' gate=0 count noun
  local projects=() fix_new="a new token, as sops/machine-setup.md says" doc='sops/machine-setup.md, "The worker login"'
  local -A repo_of=() base_of=() facts_of=()
  if ! login=$(worker_login 2>"$err"); then
    report "worker login" FAIL "$(first_error)" "give bin/lib/worker-login its one line through a PR to dev"
    return
  fi
  if [[ -z $login ]]; then
    report "worker login" PASS "off, since no bin/lib/worker-login names the account: every session runs on the machine's own GitHub login"
    return
  fi
  if problem=$(worker_login_problem); then
    report "worker login" FAIL "$problem" "Daniel's own terminal: team-secrets restore"
    return
  fi

  # Git's helpers for github.com in a project checkout, the global ones: an empty value, dropping
  # every helper set before it, then gh's, which answers with the session's login.
  mapfile -t helpers < <(git config --global --get-all credential.https://github.com.helper || true)
  gh_helper="^!('?)([^']*/)?gh\\1 auth git-credential$"
  if ((${#helpers[@]} != 2)) || [[ -n ${helpers[0]} || ! ${helpers[1]} =~ $gh_helper ]]; then
    report "worker login" FAIL "git has another credential helper for github.com, which answers before the worker login" "gh auth setup-git"
    return
  fi

  # The account GitHub reads the worker login as, and its token's scopes, from one call; logins
  # compared in any case, as GitHub compares them.
  if ! reply=$(with_worker_login bounded 30 gh api -i user 2>"$err" </dev/null); then
    report "worker login" FAIL "GitHub refuses the worker login: $(first_error)" "$fix_new"
    return
  fi
  reply=${reply//$'\r'/}
  headers=${reply%%$'\n\n'*} body=${reply#*$'\n\n'}
  seen=$(jq -r '.login // empty' <<<"$body" 2>/dev/null) || seen=''
  if [[ ${seen,,} != "${login,,}" ]]; then
    report "worker login" FAIL "the worker login on this machine is ${seen:-no account}, not $login" "$fix_new"
    return
  fi
  if ! owner_login=$(with_owner_login bounded 30 gh api user --jq .login 2>"$err" </dev/null); then
    report "worker login" FAIL "the owner login's account cannot be read from GitHub: $(first_error)" \
      "the github login line's fix, then run team-doctor again"
    return
  fi
  if [[ ${owner_login,,} == "${login,,}" ]]; then
    report "worker login" FAIL "the worker login on this machine is the owner's account" "$fix_new"
    return
  fi
  if ! pushes=$(worker_git_login "$scratch"); then
    report "worker login" FAIL "$(first_error)" "gh auth setup-git"
    return
  fi
  if [[ ${pushes,,} != "${login,,}" ]]; then
    report "worker login" FAIL "git pushes as $pushes, not the worker login" "gh auth setup-git"
    return
  fi
  scope=$(grep -i -m1 '^x-oauth-scopes:' <<<"$headers" || true)
  IFS=', ' read -ra scopes <<<"${scope#*:}"
  for scope in "${scopes[@]}"; do
    for held in "${WORKER_TOKEN_SCOPES[@]}" ''; do [[ $scope != "$held" ]] || break; done
    [[ -n $held ]] || extra+=("$scope")
  done
  if ((${#extra[@]})); then
    report "worker login" FAIL "the worker login's token holds $(printf '%s, ' "${scopes[@]}" | sed 's/, $//'), more than $(printf '%s and ' "${WORKER_TOKEN_SCOPES[@]}" | sed 's/ and $//')" "$fix_new"
    return
  fi

  # The records repository, which the worker login must not see at all.
  records=$(team_home_url) records=${records#https://github.com/} records=${records%.git}
  if with_worker_login bounded 30 gh api "repos/$records" >/dev/null 2>"$err" </dev/null || ! grep -q '(HTTP 404)' "$err"; then
    report "worker login" FAIL "the worker login reaches the records repository" "Daniel removes $login's access to $records on GitHub"
    return
  fi

  # Each registered project: the worker login pushes to it and administers nothing there.
  if ! project_registry --list 2>"$err"; then
    report "worker login" FAIL "the registry cannot be read: $(first_error)" "the records line's fix, then run team-doctor again"
    return
  fi
  mapfile -t projects < <(grep . <<<"$registry_reply" || true)
  for project in "${projects[@]}"; do
    if ! project_registry "$project" 2>"$err"; then
      report "worker login" FAIL "the registry cannot be read: $(first_error)" "the records line's fix, then run team-doctor again"
      return
    fi
    repo=$(jq -r .repo <<<"$registry_reply") base=$(jq -r .base <<<"$registry_reply")
    [[ $(jq -r .delivery <<<"$registry_reply") != no-mistakes ]] || gate=1
    if ! facts=$(with_worker_login bounded 30 gh api "repos/$repo" 2>"$err" </dev/null) ||
      ! jq -e '.permissions.push == true' <<<"$facts" >/dev/null 2>&1; then
      report "worker login" FAIL "the worker login cannot push to $repo" "Daniel gives $login the Write role on $repo, as $doc says"
      return
    fi
    if jq -e '.permissions.admin == true or .permissions.maintain == true' <<<"$facts" >/dev/null; then
      report "worker login" FAIL "the worker login administers $repo" "Daniel gives $login the Write role on $repo, not Maintain or Admin"
      return
    fi
    repo_of[$project]=$repo base_of[$project]=$base facts_of[$project]=$facts
  done

  # And merges into none of its base branches: each project's base, and main when the repository
  # has one that is not the base, which GitHub must refuse the worker login a push to.
  for project in "${projects[@]}"; do
    repo=${repo_of[$project]} base=${base_of[$project]} main=true
    [[ $base != main ]] || main=false
    if ! refs=$(with_worker_login bounded 30 gh api graphql -f owner="${repo%%/*}" -f name="${repo#*/}" \
      -f base="refs/heads/$base" -f main=refs/heads/main -f query='query($owner: String!, $name: String!, $base: String!, $main: String!) {
  repository(owner: $owner, name: $name) {
    base: ref(qualifiedName: $base) { refUpdateRule { viewerCanPush } }
    main: ref(qualifiedName: $main) { refUpdateRule { viewerCanPush } }
  }
}' 2>"$err" </dev/null) || ! refs=$(unrestricted_branches "$base" "$main" <<<"$refs" 2>"$err"); then
      report "worker login" FAIL "the branches of $repo cannot be read from GitHub as the worker login: $(first_error)" \
        "run team-doctor again once GitHub answers"
      return
    fi
    [[ -n $refs ]] || continue
    mapfile -t branches <<<"$refs"
    branch=$(printf '%s and ' "${branches[@]}" | sed 's/ and $//')
    if jq -e '.private != true and .owner.type == "Organization"' <<<"${facts_of[$project]}" >/dev/null; then
      report "worker login" FAIL "GitHub does not restrict $branch on $repo to the owner" "$doc"
      return
    fi
    warn+=("$repo: GitHub cannot restrict $branch here (a private repository, or a personal account's)")
    warn_fix=$doc
  done

  count=${#projects[@]} noun=projects
  ((count != 1)) || noun=project
  if [[ $os == macos ]] && ((gate)); then
    warn+=("the gate's daemon runs on the machine's own GitHub login on macOS")
  fi
  if ((${#warn[@]})); then
    report "worker login" WARN "$login: pushes to $count $noun and administers none, but $(printf '%s; ' "${warn[@]}" | sed 's/; $//')" "$warn_fix"
  else
    report "worker login" PASS "$login: pushes to $count $noun, administers none, merges into none of their base branches"
  fi
}
worker_login_check
