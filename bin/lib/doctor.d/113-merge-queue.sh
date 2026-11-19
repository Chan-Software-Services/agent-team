# merge queue   Each registered project whose base has a merge queue, by its rules read from GitHub
#               on the owner login (base_rules in bin/lib/team.sh: its classic protection and its
#               rulesets): fails naming, for each such project, the first of the queue's merge
#               method not the registry's merge_method, the strict rule (a branch up to date before
#               it merges) on, classic protection left on the base beside the ruleset, the code
#               scanning roll-up CodeQL required (from GitHub Advanced Security, integration 57789,
#               or from no integration), which GitHub posts only on a pull request, never on a
#               trial commit, a required check named "Analyze (<language>)" while the repository's
#               CodeQL default setup is configured (read on the owner login, 30 seconds bounded,
#               only for a base requiring such a check), which runs nothing on a trial commit and
#               refuses the workflow's uploads, or, for a project that is the team's own while the
#               reviewer App is on, agent-review pinned to the App's id missing from the required
#               checks; each fix is Daniel's step 6 of sops/merging.md. A base whose rules, or a
#               repository whose default setup, cannot be read fails too, with the github login
#               line's fix. Passes naming each project with a queue and the queue's settings, its
#               merge method, the most entries it builds and merges at once and its check timeout
#               ("conventioner (dev on <repo>: merge, build 2, merge 5, timeout 120 min)"), the
#               team's own adding the App's pin, or saying none has one; a base with no queue, an
#               unprotected one included, is not named. Nothing is read while team-project
#               refuses the registry, which is the projects line's, or bin/lib/review-app is
#               malformed, which is the review app line's.
# shellcheck shell=bash
# shellcheck disable=SC2154 # err, the doctor's

# The state of <repo>'s CodeQL default setup ("configured" or "not-configured"), read on the
# caller's login and bounded to 30 seconds; fails writing "gh api <path>: <why>" to $err:
# code_scanning_setup <repo>
code_scanning_setup() {
  local path="repos/$1/code-scanning/default-setup" reply rc=0 why
  reply=$(bounded 30 gh api "$path" 2>"$err" </dev/null) || rc=$?
  if ((rc == 0)) && jq -er '.state | strings' <<<"$reply" 2>/dev/null; then return 0; fi
  why=$(grep -m1 . "$err" || if ((rc == 124)); then echo "no answer in 30 seconds"
  elif ((rc == 0)); then echo "no state in its answer"; else echo "exit $rc"; fi)
  printf 'gh api %s: %s\n' "$path" "$why" >"$err"
  return 1
}

merge_queue_check() {
  local own app project repo base method rules problem is_own fields setup settings queued=() reasons=() fixes=() joined
  # {projects, app}: the team's own projects and the App's id, null while it is off.
  if ! own=$(own_projects 2>/dev/null) || ! project_registry --list 2>/dev/null; then
    report "merge queue" PASS "not read, since the registry or bin/lib/review-app cannot be read, which the projects and review app lines say"
    return
  fi
  app=$(jq -r '.app // empty' <<<"$own")
  while IFS= read -r project; do
    [[ -n $project ]] || continue
    project_registry "$project" 2>/dev/null || continue
    mapfile -d '' -t fields < <(jq --raw-output0 '.repo, .base, .merge_method' <<<"$registry_reply")
    # The registry's repo at the end of its moves (bin/lib/repo-moves.json), where GitHub has it now.
    repo=$(canonical_repo "${fields[0]}") base=${fields[1]} method=${fields[2]}
    if ! rules=$(with_owner_login base_rules "$repo" "$base" 2>"$err"); then
      reasons+=("$base's rules on $repo cannot be read from GitHub: $(first_error)")
      fixes+=("the github login line's fix, then run team-doctor again")
      continue
    fi
    jq -e '.queue != null' <<<"$rules" >/dev/null || continue
    # The default setup matters only to a base requiring the advanced workflow's Analyze checks.
    setup=''
    if jq -e 'any(.required[]?; .context | startswith("Analyze ("))' <<<"$rules" >/dev/null; then
      if ! setup=$(with_owner_login code_scanning_setup "$repo"); then
        reasons+=("$repo's CodeQL default setup cannot be read from GitHub: $(first_error)")
        fixes+=("the github login line's fix, then run team-doctor again")
        continue
      fi
    fi
    is_own=$(jq --arg project "$project" '.projects | index($project) != null' <<<"$own")
    # The first problem as "<reason>\t<what step 6 sets>", or nothing.
    problem=$(jq -r --arg method "$method" --arg base "$base" --arg repo "$repo" --arg app "$app" --arg setup "$setup" --argjson own "$is_own" '
      "\($base)'"'"'s merge queue on \($repo)" as $queue
      | first(
          (select((.queue.merge_method // "" | ascii_downcase) != $method)
            | "\($queue) merges with \(.queue.merge_method // "no method" | ascii_downcase), not \($method), the registry'"'"'s merge_method\tthe queue'"'"'s merge method \($method | ascii_upcase) in \($base)'"'"'s ruleset"),
          (select(.strict)
            | "\($queue) stands beside a strict rule, which holds each PR until its branch is up to date with \($base)\tthe strict rule off in \($base)'"'"'s ruleset, and its classic protection removed"),
          (select(.classic)
            | "\($queue) stands beside \($base)'"'"'s classic protection, which the ruleset replaces\t\($base)'"'"'s classic protection removed"),
          (select(any(.required[]?; .context == "CodeQL" and (.app_id == null or .app_id == 57789)))
            | "\($queue) requires the code scanning roll-up CodeQL, which GitHub posts only on a pull request, never on a trial commit\tthe CodeQL workflow'"'"'s Analyze (<language>) checks required in its place, and a code_scanning rule, in \($base)'"'"'s ruleset"),
          (select($setup == "configured")
            | [.required[] | .context | select(startswith("Analyze ("))] | unique
            | "\($queue) requires \(join(", ")) while CodeQL'"'"'s default setup is configured, which runs nothing on a trial commit and refuses the workflow'"'"'s uploads\tCodeQL'"'"'s default setup turned off on \($repo)"),
          (select($own and $app != "")
            | select(any(.required[]?; .context == "agent-review" and .app_id == ($app | tonumber)) | not)
            | "\($queue) stands beside required checks without agent-review from the reviewer App \($app), so GitHub does not hold its check\tagent-review pinned to App \($app) in \($base)'"'"'s required checks"),
          empty)' <<<"$rules") || {
      reasons+=("$base's rules on $repo could not be judged")
      fixes+=("run team-doctor again")
      continue
    }
    if [[ -z $problem ]]; then
      settings=$(jq -r '.queue | "\(.merge_method // "no method" | ascii_downcase), build \(.max_entries_to_build // "unset"), merge \(.max_entries_to_merge // "unset"), timeout \(.check_response_timeout_minutes // "unset") min"' <<<"$rules")
      if [[ $is_own == true && -n $app ]]; then
        queued+=("$project ($base on $repo: $settings, agent-review pinned to the reviewer App $app)")
      else
        queued+=("$project ($base on $repo: $settings)")
      fi
      continue
    fi
    reasons+=("${problem%%$'\t'*}")
    fixes+=("Daniel takes step 6 of sops/merging.md on $repo, ${problem#*$'\t'}")
  done <<<"$registry_reply"

  if ((${#reasons[@]})); then
    report "merge queue" FAIL "$(printf '%s; ' "${reasons[@]}" | sed 's/; $//')" "$(printf '%s; ' "${fixes[@]}" | sed 's/; $//')"
  elif ((${#queued[@]})); then
    joined=$(printf '%s, ' "${queued[@]}")
    report "merge queue" PASS "${joined%, }: each queue merges with the registry's merge_method, with no strict rule and no classic protection beside it"
  else
    report "merge queue" PASS "no registered project's base has a merge queue"
  fi
}
merge_queue_check
