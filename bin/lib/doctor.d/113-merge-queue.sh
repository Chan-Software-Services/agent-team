# merge queue   Each registered project whose base has a merge queue, by its rules read from
#               GitHub (base_rules in bin/lib/team.sh: its classic protection and its rulesets):
#               fails naming, for each such project, the first of the queue's merge method not
#               the registry's merge_method, the strict rule (a branch up to date before it
#               merges) on, classic protection left on the base beside the ruleset, or, for a
#               project that is the team's own while the reviewer App is on, agent-review
#               pinned to the App's id missing from the required checks; each fix is Daniel's
#               step 6 of sops/merging.md. A base whose rules cannot be read fails too, with
#               the github login line's fix. Passes naming the projects with a queue, or saying
#               none has one; a base with no queue, an unprotected one included, is not named.
#               Nothing is read while team-project refuses the registry, which is the projects
#               line's, or bin/lib/review-app is malformed, which is the review app line's.
# shellcheck shell=bash
# shellcheck disable=SC2154 # err, the doctor's

merge_queue_check() {
  local own app project repo base method rules problem is_own fields queued=() reasons=() fixes=() joined
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
    if ! rules=$(base_rules "$repo" "$base" 2>"$err"); then
      reasons+=("$base's rules on $repo cannot be read from GitHub: $(first_error)")
      fixes+=("the github login line's fix, then run team-doctor again")
      continue
    fi
    jq -e '.queue != null' <<<"$rules" >/dev/null || continue
    is_own=$(jq --arg project "$project" '.projects | index($project) != null' <<<"$own")
    # The first problem as "<reason>\t<what step 6 sets>", or nothing.
    problem=$(jq -r --arg method "$method" --arg base "$base" --arg repo "$repo" --arg app "$app" --argjson own "$is_own" '
      "\($base)'"'"'s merge queue on \($repo)" as $queue
      | first(
          (select((.queue.merge_method // "" | ascii_downcase) != $method)
            | "\($queue) merges with \(.queue.merge_method // "no method" | ascii_downcase), not \($method), the registry'"'"'s merge_method\tthe queue'"'"'s merge method \($method | ascii_upcase) in \($base)'"'"'s ruleset"),
          (select(.strict)
            | "\($queue) stands beside a strict rule, which holds each PR until its branch is up to date with \($base)\tthe strict rule off in \($base)'"'"'s ruleset, and its classic protection removed"),
          (select(.classic)
            | "\($queue) stands beside \($base)'"'"'s classic protection, which the ruleset replaces\t\($base)'"'"'s classic protection removed"),
          (select($own and $app != "")
            | select(any(.required[]?; .context == "agent-review" and .app_id == ($app | tonumber)) | not)
            | "\($queue) stands beside required checks without agent-review from the reviewer App \($app), so GitHub does not hold its check\tagent-review pinned to App \($app) in \($base)'"'"'s required checks"),
          empty)' <<<"$rules") || {
      reasons+=("$base's rules on $repo could not be judged")
      fixes+=("run team-doctor again")
      continue
    }
    if [[ -z $problem ]]; then
      if [[ $is_own == true && -n $app ]]; then
        queued+=("$project ($base on $repo, agent-review pinned to the reviewer App $app)")
      else
        queued+=("$project ($base on $repo)")
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
