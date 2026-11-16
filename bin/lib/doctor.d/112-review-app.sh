# review app    The reviewer App, whose agent-review check run the team's own project merges
#               behind (review_app in bin/lib/team.sh): passes saying it is off with no
#               bin/lib/review-app; else fails on the first of a malformed bin/lib/review-app, its
#               key ~/.config/agent-team/review-app.pem missing, not a file or off mode 600 (no
#               byte of it read), no registered project the team's own, or such a project's base
#               whose rules, read from GitHub (base_rules in bin/lib/team.sh: its classic
#               protection and its rulesets), do not require agent-review from the App's id, or
#               that classic protection enforces its required checks for anyone but everyone, or
#               a ruleset of them has a bypass actor.
# shellcheck shell=bash
# shellcheck disable=SC2154 # err, the doctor's

review_app_check() {
  local app app_id app_slug key=$HOME/.config/agent-team/review-app.pem shown own project repo base mode rules problem
  local restore="Daniel runs team-secrets restore in their own terminal"
  if ! app=$(review_app 2>"$err"); then
    report "review app" FAIL "$(first_error)" "give bin/lib/review-app its two lines through a PR to dev"
    return
  fi
  if [[ -z $app ]]; then
    report "review app" PASS "off, since no bin/lib/review-app names the reviewer App: the team's own project merges on the per-head word alone"
    return
  fi
  read -r app_id app_slug <<<"$app"
  shown=$(tilde "$key")
  local on="the reviewer App $app_slug ($app_id) is on, but its key $shown"
  if [[ ! -e $key ]]; then
    report "review app" FAIL "$on is missing" "$restore"
    return
  elif [[ ! -f $key ]]; then
    report "review app" FAIL "$on is not a file" "move aside what is at $shown, then $restore"
    return
  fi
  mode=$(stat -L -c %a -- "$key")
  if [[ $mode != 600 ]]; then
    report "review app" FAIL "$on is mode $mode, not 600" "Daniel runs chmod 600 $shown"
    return
  fi

  # Each project that is the team's own: its base's rules, as team-merge reads them.
  if ! own=$(own_projects 2>"$err"); then
    report "review app" FAIL "the registry cannot be read: $(first_error)" "the records line's fix, then run team-doctor again"
    return
  fi
  if jq -e '.projects == []' <<<"$own" >/dev/null; then
    report "review app" FAIL "the reviewer App $app_slug ($app_id) is on, but no registered project is the team's own, so no base's rules are read" \
      "register agent-team in projects.toml (team-project --help)"
    return
  fi
  local where=()
  while IFS= read -r project; do
    if ! project_registry "$project" 2>"$err"; then
      report "review app" FAIL "the registry cannot be read: $(first_error)" "the records line's fix, then run team-doctor again"
      return
    fi
    # The registry's repo at the end of its moves (bin/lib/repo-moves.json), where GitHub has it now.
    repo=$(canonical_repo "$(jq -r .repo <<<"$registry_reply")") base=$(jq -r .base <<<"$registry_reply")
    if ! rules=$(base_rules "$repo" "$base" 2>"$err"); then
      report "review app" FAIL "$base's rules on $repo cannot be read from GitHub: $(first_error)" \
        "the github login line's fix, then run team-doctor again"
      return
    fi
    problem=$(ledger_jq 'first(review_app_pin_problems($app))
      | if .kind == "pin" then
          "pin\t\($base)'"'"'s protection and rulesets on \($repo) do not require agent-review from the reviewer App \($app), so GitHub does not hold its check"
        elif .kind == "admins" then
          "admins\t\($base)'"'"'s protection on \($repo) enforces its required checks for \(.level), not everyone, so an administrator could merge past them"
        else
          "bypass\t\(.name) (\(.ruleset))\t\($base)'"'"'s \(bypass_text(" on \($repo)"))"
        end' -r --argjson app "$app_id" --arg base "$base" --arg repo "$repo" <<<"$rules") ||
      problem="pin	$base's rules on $repo could not be judged"
    case ${problem%%$'\t'*} in
      pin)
        report "review app" FAIL "${problem#*$'\t'}" \
          "Daniel takes step 6 of sops/merging.md, agent-review pinned to App $app_id in $base's required checks"
        return
        ;;
      admins)
        report "review app" FAIL "${problem#*$'\t'}" "Daniel turns on enforce_admins in $base's protection on $repo"
        return
        ;;
      bypass)
        problem=${problem#*$'\t'}
        report "review app" FAIL "${problem#*$'\t'}" "Daniel removes the bypass actors of ruleset ${problem%%$'\t'*} on $repo"
        return
        ;;
    esac
    where+=("$base's protection and rulesets on $repo")
  done < <(jq -r '.projects[]' <<<"$own")
  local joined
  joined=$(printf '%s, ' "${where[@]}")
  report "review app" PASS "the reviewer App $app_slug ($app_id) is on: its key $shown is in place with mode 600, and ${joined%, } require agent-review from it, enforced for everyone"
}
review_app_check
