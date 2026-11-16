# team home login
#               The team home's own git config (--local) gives credential.https://github.com.helper
#               exactly the two values owner_git_helpers (bin/lib/github-login.sh) prints for the
#               gh that command -v gh finds: an empty one, which drops every helper the global
#               config set, then that gh's git-credential with GH_CONFIG_DIR, GH_TOKEN and
#               GITHUB_TOKEN unset, so the ledger's pushes, the checkpoint and the lease reach the
#               records repository on the owner login from a session on the worker login, which
#               has no access to it. Fails otherwise, its fix team-bootstrap, whose machine stage
#               sets them. Left out while the team home line fails.
# shellcheck shell=bash
# shellcheck disable=SC2154 # home_ok, from the team home check
# reads state from: 080-team-home.sh

if ((home_ok)); then
  home_login_gh=$(command -v gh) || home_login_gh=''
  mapfile -t home_login_helpers < <(git -C "$TEAM_HOME" config --local --get-all credential.https://github.com.helper || true)
  # Counted first, since $(...) drops the newline a third, empty value would add.
  if [[ -n $home_login_gh ]] && ((${#home_login_helpers[@]} == 2)) &&
    [[ $(printf '%s\n' "${home_login_helpers[@]}") == "$(owner_git_helpers "$home_login_gh")" ]]; then
    report "team home login" PASS "its git asks $(tilde "$home_login_gh") for github.com on the owner login"
  else
    report "team home login" FAIL "the team home's git does not name the owner login for github.com" team-bootstrap
  fi
fi
