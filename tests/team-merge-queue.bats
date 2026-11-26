#!/usr/bin/env bats
# shellcheck disable=SC2154 # head, merge, gh_dir and discord are helpers/merge.bash's
# team-merge on a base with a merge queue: after its word and checks it logs queued, lands the PR
# through team-land (a stub here, ending as each test says) under the task's lock, and logs what
# the queue did; on a base with no queue it merges as before.

load helpers/common
load helpers/inbox
load helpers/merge

url=https://github.com/owner/proj/pull/5
lock() {
  echo "$HOME/.local/state/agent-team/merge/T14.lock"
}

# The queued event of PR #5 at the head, as team-merge logs it.
queued() {
  jq -cn --arg h "$head" --arg url "$url" '{task: "T14", event: "queued", url: $url, head: $h, project: "proj"}'
}

# The merged event of PR #5 on Daniel's per-head word, as team-merge logs it.
merged_on_head() {
  jq -cn --arg m "$merge" --arg h "$head" --arg url "$url" '{task: "T14", event: "merged", pr: 5, merge: $m, head: $h,
    by: "Discord message 1562661774950400000 in the task'"'"'s thread 1563, from daniel (757)",
    project: "proj", branch: "feat/T14-tooling", discord_message: "1562661774950400000", discord_channel: "1563",
    url: $url, approval: "head"}'
}

# A queued event of PR #5 logged earlier, at <head> (the PR's by default): was_queued [<head>]
was_queued() {
  event T14 queued "{url: \"$url\", head: \"${1:-$head}\", project: \"proj\"}"
}

no_land_call() {
  [[ ! -e $gh_dir/land.calls ]]
}

@test "on a base with a queue, a green, approved PR is queued, landed by team-land under the task's lock, and logged merged" {
  with_queue
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(cat "$gh_dir/land.calls")" "--task T14 $url $head"
  no_merge_call
  assert_equal "$(queue_events)" "$(queued; merged_on_head)"
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg m "$merge" --arg h "$head" --arg url "$url" '{task: "T14",
    pr: $url, merge: $m, head: $h, by: "Discord message 1562661774950400000 in the task'"'"'s thread 1563, from daniel (757)"}')"
  # team-land's lines are shown as it goes, on stderr, so stdout stays the merge's JSON.
  assert_contains "$stderr" "team-land: at work on $url"
  # The lock names the run that held it, and is free once it ends.
  [[ $(cat "$(lock)") =~ ^[1-9][0-9]*$ ]]
  flock -n "$(lock)" true
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "a merge through the queue does what follows a merge: the default word's posts, sent once it merged" {
  default_word
  with_queue
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r '.event + " " + (.approval // "")')" "$(printf '%s\n' "queued " "merged default")"
  assert_equal "$(jq -r .content "$discord/posts")" "$(merge_post "$COORDINATOR_PLAN" "\`git revert -m 1 $merge\`"; merge_post "$COORDINATOR_PLAN" "\`git revert -m 1 $merge\`")"
  assert_equal "$(jq -r .channel "$discord/posts" | head -n 1)" 1563
  # Both posts came after the merged event, never at the queued one.
  assert_equal "$(jq -r .merged "$discord/posts" | sort -u)" 1
}

@test "a PR the queue dropped for a failure of its own is logged dequeued with its failures, and goes back to the builder" {
  with_queue
  land dequeued "the checks failed on the merge group" \
    '[{"name": "test", "class": "pr", "kind": "test", "link": "https://github.com/owner/proj/actions/runs/1/job/2", "step": "Run tests"}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$output" ""
  assert_equal "$(queue_events)" "$(queued; jq -cn --arg h "$head" --arg url "$url" '{task: "T14", event: "dequeued", url: $url,
    head: $h, reason: "the checks failed on the merge group", failed: [{name: "test", class: "pr", kind: "test",
      link: "https://github.com/owner/proj/actions/runs/1/job/2", step: "Run tests"}]}')"
  assert_contains "$stderr" "team-merge: the merge queue dropped PR #5, which is not merged: the checks failed on the merge group"
  assert_contains "$stderr" "  test failed on the trial merge (Run tests): https://github.com/owner/proj/actions/runs/1/job/2"
  assert_contains "$stderr" "  the trial merge failed what the head ${head:0:7} passed: render team-brief T14 builder-merge-base for the builder, then a rereview"
  no_merge_call
  flock -n "$(lock)" true
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "a PR the queue dropped for anything but a failure of its own or a runner backlog says to run team-merge again once what dropped it is fixed" {
  with_queue
  land dequeued "the queue was cleared"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1)" "$(jq -cn --arg h "$head" --arg url "$url" \
    '{task: "T14", event: "dequeued", url: $url, head: $h, reason: "the queue was cleared"}')"
  assert_contains "$stderr" "team-merge: the merge queue dropped PR #5, which is not merged: the queue was cleared"
  assert_contains "$stderr" "  run team-merge T14 again once what dropped it is fixed"
  [[ $stderr != *builder-merge-base* && $stderr != *"runners are"* ]]
  # Infrastructure alone, which team-land enqueued once more for, is no failure of the PR's own,
  # and a setup failure no runner backlog.
  merge_again
  queue_rule
  land dequeued "failed_checks" '[{"name": "test", "class": "infrastructure", "kind": "setup", "link": "", "step": "Set up job"}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1 | jq -c '[.event, .failed[0].class]')" '["dequeued","infrastructure"]'
  assert_contains "$stderr" "  test failed on the trial merge as infrastructure (Set up job)"
  assert_contains "$stderr" "  run team-merge T14 again once what dropped it is fixed"
  [[ $stderr != *builder-merge-base* && $stderr != *"runners are"* ]]
  # A queued check beside a stuck or never-started one, with no check timeout, is no runner
  # backlog alone: the general step.
  local other
  for other in stuck never-started; do
    merge_again
    queue_rule
    land dequeued "failed_checks" \
      '[{"name": "e2e", "class": "infrastructure", "kind": "queued", "link": null, "step": null},
        {"name": "lint", "class": "infrastructure", "kind": "'"$other"'", "link": null, "step": null}]'
    run_bin -1 --separate-stderr team-merge T14
    assert_contains "$stderr" "  run team-merge T14 again once what dropped it is fixed"
    [[ $stderr != *"runners are"* ]]
  done
}

@test "a PR the queue dropped while its checks waited on runners, or on its check timeout, says the runners are behind: tell Daniel and run team-merge again once they are back" {
  local backlog="  the runners are behind, with nothing of the PR's to fix: tell Daniel, who may raise the check timeout of owner/proj's merge queue while the backlog stands, and run team-merge T14 again once they say the runners are back"
  with_queue
  # A required roll-up not listed while its shards waited for runners is infrastructure too: no
  # team-doctor, merge_group trigger or ruleset step, and nothing to fix.
  land dequeued "failed_checks" \
    '[{"name": "e2e shard 1/2", "class": "infrastructure", "kind": "queued", "link": "https://github.com/owner/proj/actions/runs/1/job/3", "step": null},
      {"name": "e2e", "class": "infrastructure", "kind": "missing", "link": null, "step": null}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  e2e shard 1/2 failed on the trial merge as infrastructure: https://github.com/owner/proj/actions/runs/1/job/3"
  assert_contains "$stderr" "  e2e was not reported on the trial merge while a workflow run there was still open, as infrastructure
"
  assert_contains "$stderr" "$backlog"
  [[ $stderr != *team-doctor* && $stderr != *merge_group* && $stderr != *ruleset* && $stderr != *builder-merge-base* ]]
  [[ $stderr != *"once what dropped it is fixed"* ]]
  # A queued check beside a roll-up of its shards: still the runners'.
  merge_again
  queue_rule
  land dequeued "failed_checks" \
    '[{"name": "test-shard 1/3", "class": "infrastructure", "kind": "queued", "link": "https://github.com/owner/proj/actions/runs/1/job/4", "step": null},
      {"name": "test", "class": "rollup", "kind": "rollup", "link": "https://github.com/owner/proj/actions/runs/1/job/5", "step": null}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "$backlog"
  [[ $stderr != *"once what dropped it is fixed"* ]]
  # The queue's own check timeout, with no failure read on the trial commit, and with what
  # team-land adds to GitHub's reason.
  local reason
  for reason in "checks_timed_out" "checks_timed_out; agent-review was not posted on the trial commit a9e124d: GitHub refused it"; do
    merge_again
    queue_rule
    land dequeued "$reason"
    run_bin -1 --separate-stderr team-merge T14
    assert_contains "$stderr" "team-merge: the merge queue dropped PR #5, which is not merged: $reason"
    assert_contains "$stderr" "$backlog"
    [[ $stderr != *"once what dropped it is fixed"* ]]
  done
  # A setup failure beside the timeout: the queue gave up on runners all the same.
  merge_again
  queue_rule
  land dequeued "checks_timed_out" '[{"name": "lint", "class": "infrastructure", "kind": "setup", "link": "", "step": "Set up job"}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "$backlog"
  # A failure of the PR's own beside the timeout is still the builder's round, and a rules failure
  # the rules step.
  merge_again
  queue_rule
  land dequeued "checks_timed_out" \
    '[{"name": "test", "class": "pr", "kind": "failed", "link": "https://github.com/owner/proj/actions/runs/1/job/2", "step": "Run tests"},
      {"name": "e2e", "class": "infrastructure", "kind": "queued", "link": null, "step": null}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  the trial merge failed what the head ${head:0:7} passed: render team-brief T14 builder-merge-base for the builder, then a rereview"
  [[ $stderr != *"runners are"* ]]
  merge_again
  queue_rule
  land dequeued "checks_timed_out; Analyze (python) never reported on the trial commit, which dev's rules require" \
    '[{"name": "Analyze (python)", "class": "rules", "kind": "missing", "link": null, "step": null},
      {"name": "e2e", "class": "infrastructure", "kind": "queued", "link": null, "step": null}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  the base's rules require a check no workflow makes on a trial commit"
  [[ $stderr != *"runners are"* ]]
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

@test "a PR the queue dropped for a check its base's rules require that never reported on the trial commit names the rules step, and beside a failure of its own the merge-base brief" {
  rules_step="  the base's rules require a check no workflow makes on a trial commit: run team-doctor (its merge queue line), fix the workflow's merge_group trigger or ask Daniel to change owner/proj's ruleset, then run team-merge T14 again"
  with_queue
  land dequeued "Analyze (python) never reported on the trial commit, which dev's rules require" \
    '[{"name": "Analyze (python)", "class": "rules", "kind": "missing", "link": null, "step": null}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1)" "$(jq -cn --arg h "$head" --arg url "$url" \
    --arg reason "Analyze (python) never reported on the trial commit, which dev's rules require" '{task: "T14",
    event: "dequeued", url: $url, head: $h, reason: $reason,
    failed: [{name: "Analyze (python)", class: "rules", kind: "missing", link: null, step: null}]}')"
  assert_contains "$stderr" "team-merge: the merge queue dropped PR #5, which is not merged: Analyze (python) never reported on the trial commit, which dev's rules require"
  assert_contains "$stderr" "  Analyze (python) was not reported on the trial merge, which dev's rules require
"
  [[ $stderr != *"Analyze (python) failed"* ]]
  assert_contains "$stderr" "$rules_step"
  [[ $stderr != *builder-merge-base* && $stderr != *"once what dropped it is fixed"* ]]
  # Beside a failure of the PR's own, the builder's round leads: the queue cancels the rest of a
  # trial commit it gives up, so a roll-up whose shards it cancelled reads as the rules' with no run
  # open, as test did beside toolkits' failure, and a rules gap that is real shows alone on the
  # round's new head.
  merge_again
  queue_rule
  land dequeued "failed_checks; test never reported on the trial commit, which dev's rules require" \
    '[{"name": "toolkits", "class": "pr", "kind": "failed", "link": "https://github.com/owner/proj/actions/runs/1/job/2", "step": "Run tests/run toolkits"},
      {"name": "test", "class": "rules", "kind": "missing", "link": null, "step": null, "source": "rules"}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1 | jq -c '[.event, [.failed[].class]]')" '["dequeued",["pr","rules"]]'
  assert_contains "$stderr" "  toolkits failed on the trial merge (Run tests/run toolkits): https://github.com/owner/proj/actions/runs/1/job/2"
  assert_contains "$stderr" "  test was not reported on the trial merge, which dev's rules require
"
  assert_contains "$stderr" "  the trial merge failed what the head ${head:0:7} passed: render team-brief T14 builder-merge-base for the builder, then a rereview"
  [[ $stderr != *team-doctor* && $stderr != *ruleset* && $stderr != *"once what dropped it is fixed"* ]]
  # A check the project's required_checks alone require is said as theirs, and the step names them
  # in place of team-doctor and the ruleset; beside one the rules require, it names both.
  merge_again
  queue_rule
  land dequeued "data never reported on the trial commit, which the project's required_checks require" \
    '[{"name": "data", "class": "rules", "kind": "missing", "link": null, "step": null, "source": "required_checks"}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1 | jq -c '[.event, .failed[].source]')" '["dequeued","required_checks"]'
  assert_contains "$stderr" "  data was not reported on the trial merge, which the project's required_checks require"
  assert_contains "$stderr" "  the project's required_checks require a check no workflow makes on a trial commit: fix the workflow's merge_group trigger or the project's required_checks in the registry, then run team-merge T14 again"
  [[ $stderr != *team-doctor* && $stderr != *ruleset* ]]
  merge_again
  queue_rule
  land dequeued "Analyze (python) never reported on the trial commit, which dev's rules require; data never reported on the trial commit, which the project's required_checks require" \
    '[{"name": "Analyze (python)", "class": "rules", "kind": "missing", "link": null, "step": null, "source": "rules"},
      {"name": "data", "class": "rules", "kind": "missing", "link": null, "step": null, "source": "required_checks"}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  the base's rules and the project's required_checks require a check no workflow makes on a trial commit: run team-doctor (its merge queue line), fix the workflow's merge_group trigger or the project's required_checks in the registry or ask Daniel to change owner/proj's ruleset, then run team-merge T14 again"
  TEAM_HOME=$TEAM_HOME run "$REPO_ROOT/bin/team-log" --check
  assert_equal "$status" 0
}

# dropped_again [<args for team-merge>...]: team-merge T14 of a PR the queue dropped, exiting 1,
# on a queue and a PR as before the drop.
dropped_again() {
  merge_again
  queue_rule
  run_bin -1 --separate-stderr team-merge T14 "$@"
}

@test "in a task with more than one PR, every step a queue drop names says to run team-merge --pr on the dropped PR, since team-merge T14 alone takes the latest pr event's" {
  local again="run team-merge T14 --pr $url again"
  with_queue
  second_pr
  land dequeued "Analyze (python) never reported on the trial commit, which dev's rules require" \
    '[{"name": "Analyze (python)", "class": "rules", "kind": "missing", "link": null, "step": null}]'
  run_bin -1 --separate-stderr team-merge T14 --pr "$url"
  assert_contains "$stderr" "  the base's rules require a check no workflow makes on a trial commit: run team-doctor (its merge queue line), fix the workflow's merge_group trigger or ask Daniel to change owner/proj's ruleset, then $again"
  land dequeued "checks_timed_out"
  dropped_again --pr "$url"
  assert_contains "$stderr" "while the backlog stands, and $again once they say the runners are back"
  land dequeued "the queue was cleared"
  dropped_again --pr "$url"
  assert_contains "$stderr" "  $again once what dropped it is fixed"
  # PR #5 logged again, so it is the latest pr event's: its step names it all the same.
  event T14 pr "{url: \"$url\", head: \"a1b2c3d4\", project: \"proj\"}"
  dropped_again
  assert_contains "$stderr" "  $again once what dropped it is fixed"
}

@test "a task whose latest pr event is another PR of the same repository names --pr too, as team-merge T14 alone would pass over the PR --pr named" {
  with_queue
  second_pr https://github.com/owner/proj/pull/6
  land dequeued "the queue was cleared"
  run_bin -1 --separate-stderr team-merge T14 --pr "$url"
  assert_contains "$stderr" "  run team-merge T14 --pr $url again once what dropped it is fixed"
}

@test "in a task with more than one PR, the steps after a wait, a run of team-land with no result and an outcome it does not know name the PR with --pr" {
  local again="run team-merge T14 --pr $url again" after
  with_queue
  second_pr
  in_queue
  land waiting "still in the queue"
  run_bin -75 --separate-stderr team-merge T14 --pr "$url"
  assert_contains "$stderr" "team-merge: the PR is still in the queue: $again with run_in_background to go on waiting"
  # The PR as read after team-land's wait: out of the queue, merged, or unread.
  for after in \
    "out|{\"data\": {\"repository\": {\"pullRequest\": {\"id\": \"PR_kwDOtest5\", \"state\": \"OPEN\", \"mergeQueueEntry\": null}}}}|team-merge: PR #5 is in no merge queue: $again with run_in_background to enqueue it" \
    "merged|{\"data\": {\"repository\": {\"pullRequest\": {\"id\": \"PR_kwDOtest5\", \"state\": \"MERGED\", \"mergeQueueEntry\": null}}}}|team-merge: PR #5 is merged by now: $again, which logs how it ended" \
    "unread|not json|team-merge: whether PR #5 is still in the queue is not known, GitHub unread: $again with run_in_background to go on waiting"; do
    merge_again
    queue_rule
    in_queue
    land waiting "still in the queue"
    sed -i "1i echo '$(cut -d'|' -f2 <<<"$after")' >\"\$GH_DIR/entry.json\"" "$gh_dir/land.sh"
    run_bin -75 --separate-stderr team-merge T14 --pr "$url"
    assert_contains "$stderr" "$(cut -d'|' -f3 <<<"$after")"
  done
  # No result, with the PR in the queue and then in none.
  merge_again
  queue_rule
  in_queue
  printf '%s\n' 'echo "team-land: jq: error" >&2' 'exit 5' >"$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14 --pr "$url"
  assert_contains "$stderr" "so whether PR #5 is in the queue is not known: $again"
  merge_again
  queue_rule
  in_queue no
  printf '%s\n' 'echo "team-land: jq: error" >&2' 'exit 5' >"$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14 --pr "$url"
  assert_contains "$stderr" "and PR #5 is in no merge queue: $again"
  merge_again
  queue_rule
  land adrift
  run_bin -1 --separate-stderr team-merge T14 --pr "$url"
  assert_contains "$stderr" "team-land ended adrift, which is no outcome of its: check PR #5 on GitHub, then $again"
}

@test "a PR still in the queue at team-land's deadline logs nothing more and exits 75, to go on waiting" {
  with_queue
  in_queue
  land waiting "$url is still in the merge queue after 240 minutes: run team-land again to go on waiting"
  run_bin -75 --separate-stderr team-merge T14
  assert_equal "$output" ""
  assert_equal "$(queue_events)" "$(queued)"
  assert_contains "$stderr" "team-merge: the PR is still in the queue: run team-merge T14 again with run_in_background to go on waiting"
  flock -n "$(lock)" true
}

@test "a wait that ends with the PR in no queue is logged dequeued, never said to be still in the queue: the offline hold before the enqueue" {
  with_queue
  land waiting "GitHub is unreachable (since 13:05); the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait."
  run_bin -75 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1)" "$(jq -cn --arg h "$head" --arg url "$url" '{task: "T14", event: "dequeued", url: $url, head: $h,
    reason: "GitHub is unreachable (since 13:05); the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait.; PR #5 is in no merge queue"}')"
  [[ $stderr != *"still in the queue"* ]]
  assert_contains "$stderr" "team-merge: PR #5 is in no merge queue: run team-merge T14 again with run_in_background to enqueue it"
  # A PR the queue merged meanwhile is not dropped: its queued stands, for the next run to log merged.
  merge_again
  queue_rule
  jq -c 'select(.event | IN("queued", "dequeued") | not)' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  sed -i '1i echo '"'"'{"data": {"repository": {"pullRequest": {"id": "PR_kwDOtest5", "state": "MERGED", "mergeQueueEntry": null}}}}'"'"' >"$GH_DIR/entry.json"' "$gh_dir/land.sh"
  run_bin -75 --separate-stderr team-merge T14
  assert_equal "$(queue_events)" "$(queued)"
  [[ $stderr != *"still in the queue"* ]]
  assert_contains "$stderr" "team-merge: PR #5 is merged by now: run team-merge T14 again, which logs how it ended"
  # Nor is a PR GitHub cannot be asked about said to be in the queue.
  merge_again
  queue_rule
  in_queue
  land waiting "GitHub could not be read at the last look, so whether $url is in the merge queue is not known, after 240 minutes: run team-land again to go on waiting"
  sed -i '1i echo "not json" >"$GH_DIR/entry.json"' "$gh_dir/land.sh"
  run_bin -75 --separate-stderr team-merge T14
  [[ $stderr != *"the PR is still in the queue"* ]]
  assert_contains "$stderr" "team-merge: whether PR #5 is still in the queue is not known, GitHub unread: run team-merge T14 again with run_in_background to go on waiting"
}

@test "a resume that team-land refuses, or that ends with no result, with the PR in no queue by then, ends the standing queued" {
  with_queue
  was_queued
  in_queue
  land refused "the head of $url is 6f6f6f6, not ${head:0:7}: nothing enqueued"
  sed -i '1i echo '"'"'{"data": {"repository": {"pullRequest": {"id": "PR_kwDOtest5", "state": "OPEN", "mergeQueueEntry": null}}}}'"'"' >"$GH_DIR/entry.json"' "$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued"
  assert_equal "$(queue_events | tail -n 1 | jq -r .reason)" "the head of $url is 6f6f6f6, not ${head:0:7}: nothing enqueued; PR #5 is in no merge queue"
  assert_contains "$stderr" "team-merge: team-land refused PR #5: the head of $url is 6f6f6f6, not ${head:0:7}: nothing enqueued"
  # No result at all, and the PR in no queue when it is read after.
  was_queued
  in_queue
  printf '%s\n' 'echo '"'"'{"data": {"repository": {"pullRequest": {"id": "PR_kwDOtest5", "state": "OPEN", "mergeQueueEntry": null}}}}'"'"' >"$GH_DIR/entry.json"' \
    'echo "team-land: jq: error" >&2' 'exit 5' >"$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued queued dequeued"
  assert_equal "$(queue_events | tail -n 1 | jq -r .reason)" "team-land ended with no result (exit 5); PR #5 is in no merge queue"
  assert_contains "$stderr" "team-merge: team-land ended with no result (exit 5), and PR #5 is in no merge queue: run team-merge T14 again"
}

@test "a refusal with a queued standing for a PR in no queue logs dequeued: it left the queue while no team-merge waited" {
  with_queue
  was_queued
  pr_field '.isDraft = true'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  PR #5 is a draft"
  assert_equal "$(queue_events | tail -n 1)" "$(jq -cn --arg h "$head" --arg url "$url" '{task: "T14", event: "dequeued", url: $url, head: $h,
    reason: "PR #5 left the merge queue while no team-merge waited on it"}')"
  assert_equal "$(dequeues)" ""
  no_land_call
  # Once: the next refusal has no queued standing.
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued"
  # The dequeued names the head that was enqueued, the queued's, not the head the PR has now.
  was_queued 6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1 | jq -r .head)" 6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f
}

@test "a PR in the queue whose merge no longer holds is taken out of the queue and logged dequeued with the reasons" {
  default_word
  with_queue
  was_queued
  in_queue
  # A later review of the same head has findings: the default word no longer holds.
  review "$head" findings
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: T14 cannot merge PR #5, so nothing changed:"
  assert_equal "$(dequeues)" "pr=PR_kwDOtest5"
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued"
  assert_contains "$(queue_events | tail -n 1 | jq -r .reason)" "team-merge refused the merge and took PR #5 out of the merge queue: "
  assert_contains "$stderr" "team-merge: took PR #5 out of the merge queue, since its merge does not hold"
  no_land_call
  # A PR GitHub does not let out stays queued, said, with nothing logged.
  was_queued
  rm "$gh_dir/dequeues"
  echo "the pull request is locked" >"$gh_dir/dequeue.error"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued queued"
  assert_contains "$stderr" "team-merge: PR #5 could not be taken out of the merge queue (gh api graphql: the pull request is locked): remove it from the queue on GitHub"
}

@test "a PR in the queue whose conflict GitHub has not worked out is waited on, the queue its proof, with nothing more enqueued" {
  with_queue
  was_queued
  in_queue
  # GitHub leaves mergeable UNKNOWN on a PR that stood in the queue when its base moved.
  pr_field '.mergeable = "UNKNOWN"'
  before=$(queue_events)
  run_bin -0 --separate-stderr team-merge T14
  [[ $stderr != *"GitHub has not worked out yet"* ]]
  assert_equal "$(cat "$gh_dir/land.calls")" "--task T14 $url $head"
  assert_equal "$(dequeues)" ""
  assert_equal "$(queue_events)" "$(printf '%s\n' "$before" "$(merged_on_head)")"
}

@test "a PR whose conflict GitHub has not worked out is refused when its queue entry is UNMERGEABLE, cannot be told in no queue or with the entry unread, and a conflict is refused in the queue too" {
  with_queue
  was_queued
  pr_field '.mergeable = "UNKNOWN"'
  # The queue could not merge it onto what is ahead of it: a refusal that names the queue.
  in_queue UNMERGEABLE
  run_bin -1 --separate-stderr team-merge T14 --holds "$head"
  assert_contains "$stderr" "  PR #5's entry in dev's merge queue is UNMERGEABLE, and GitHub has not worked out whether PR #5 conflicts with its base"
  [[ $stderr != *"try again in a minute"* ]]
  assert_equal "$(dequeues)" ""
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  PR #5's entry in dev's merge queue is UNMERGEABLE, and GitHub has not worked out whether PR #5 conflicts with its base"
  assert_equal "$(dequeues)" "pr=PR_kwDOtest5"
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued"
  no_land_call
  # In no queue, nothing proves the merge yet: today's line, exit 75 with --holds and 1 without, and nothing enqueued.
  in_queue no
  run_bin -75 --separate-stderr team-merge T14 --holds "$head"
  assert_contains "$stderr" "  GitHub has not worked out yet whether PR #5 conflicts with its base; try again in a minute"
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  GitHub has not worked out yet whether PR #5 conflicts with its base; try again in a minute"
  no_land_call
  # An entry that cannot be read proves nothing either.
  echo '{"data": {"repository": null}}' >"$gh_dir/entry.json"
  run_bin -75 --separate-stderr team-merge T14 --holds "$head"
  assert_contains "$stderr" "  GitHub cannot be read: PR #5's merge queue entry"
  assert_contains "$stderr" "  GitHub has not worked out yet whether PR #5 conflicts with its base; try again in a minute"
  # A conflict GitHub did work out refuses wherever the PR stands.
  was_queued
  in_queue
  pr_field '.mergeable = "CONFLICTING"'
  run_bin -1 --separate-stderr team-merge T14 --holds "$head"
  assert_contains "$stderr" "  PR #5 conflicts with its base"
  rm -f "$gh_dir/dequeues"
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  PR #5 conflicts with its base"
  assert_equal "$(dequeues)" "pr=PR_kwDOtest5"
}

@test "a PR in the queue whose local checks could not run now is left in the queue, and one whose local checks failed is taken out" {
  with_local_checks
  with_queue
  was_queued
  in_queue
  before=$(queue_events)
  # team-checks could not take the heavy-run lock: exit 75, nothing failed.
  mv "$CODE_CHECKOUT/bin/team-checks" "$CODE_CHECKOUT/bin/team-checks.real"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "team-checks: the heavy-run lock stayed held: try again later"' 'exit 75' >"$CODE_CHECKOUT/bin/team-checks"
  chmod +x "$CODE_CHECKOUT/bin/team-checks"
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "(team-checks exit 75)"
  assert_contains "$stderr" "team-merge: PR #5 is left in the merge queue, since whether its merge holds cannot be told now"
  assert_equal "$(dequeues)" ""
  assert_equal "$(queue_events)" "$before"
  no_land_call
  # Local checks that ran and failed are a refusal that stands.
  mv -f "$CODE_CHECKOUT/bin/team-checks.real" "$CODE_CHECKOUT/bin/team-checks"
  echo 1 >"$gh_dir/check.status"
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "(team-checks exit 1)"
  assert_equal "$(dequeues)" "pr=PR_kwDOtest5"
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued"
}

@test "a queued standing for a PR merged at another head is ended by a dequeued of the head it names, by a refusal and after team-land" {
  with_queue
  # Merged by hand at the PR's head, while the queued names an earlier one.
  was_queued 6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f
  pr_field '.state = "MERGED"'
  in_queue merged
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  PR #5 is merged, not open"
  assert_equal "$(queue_events | tail -n 1)" "$(jq -cn --arg h "$head" --arg url "$url" '{task: "T14", event: "dequeued", url: $url,
    head: "6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f",
    reason: "PR #5 was merged at \($h[:7]), not at 6f6f6f6, the head its queued names, with no team-merge landing it"}')"
  no_land_call
  # Once: no queued stands for the next refusal.
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued"
  # Merged at another head while team-land waited on a queued that stood before this run.
  merge_again
  queue_rule
  was_queued
  in_queue
  land refused "$url was merged at 7a7a7a7, not at the head ${head:0:7} this run lands: check it on GitHub"
  sed -i '1i echo '"'"'{"data": {"repository": {"pullRequest": {"id": "PR_kwDOtest5", "state": "MERGED", "headRefOid": "7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a", "mergeQueueEntry": null}}}}'"'"' >"$GH_DIR/entry.json"' "$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 2 | jq -r .event | paste -sd' ')" "queued dequeued"
  assert_equal "$(queue_events | tail -n 1 | jq -r .reason)" "$url was merged at 7a7a7a7, not at the head ${head:0:7} this run lands: check it on GitHub"
  assert_contains "$stderr" "team-merge: team-land refused PR #5: $url was merged at 7a7a7a7"
  # And on a queued this run logged: it is ended, and never said not to have joined the queue.
  in_queue no
  land refused "$url was merged at 7a7a7a7, not at the head ${head:0:7} this run lands: check it on GitHub"
  sed -i '1i echo '"'"'{"data": {"repository": {"pullRequest": {"id": "PR_kwDOtest5", "state": "MERGED", "headRefOid": "7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a", "mergeQueueEntry": null}}}}'"'"' >"$GH_DIR/entry.json"' "$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 2 | jq -r .event | paste -sd' ')" "queued dequeued"
  assert_contains "$stderr" "team-merge: team-land refused PR #5: $url was merged at 7a7a7a7"
  [[ $stderr != *"did not join the merge queue"* ]]
}

@test "a dequeued another team-merge logged while team-land waited, taking the PR out, is not logged a second time" {
  with_queue
  land dequeued "GitHub gives no reason"
  # The run that refused the merge took the PR out and logged its dequeued, with no lock.
  sed -i '1i jq -cn --arg h "$2" '"'"'{ts: "2026-10-22T04:00:00Z", task: "T14", event: "dequeued", url: "https://github.com/owner/proj/pull/5", head: $h, reason: "team-merge refused the merge and took PR #5 out of the merge queue: PR #5 is a draft"}'"'"' >>"$TEAM_HOME/ledger.jsonl"' "$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued"
  assert_equal "$(queue_events | tail -n 1 | jq -r .reason)" "team-merge refused the merge and took PR #5 out of the merge queue: PR #5 is a draft"
  assert_contains "$stderr" "team-merge: PR #5's dequeued is logged already, by another team-merge"
  assert_contains "$stderr" "team-merge: the merge queue dropped PR #5, which is not merged: GitHub gives no reason"
}

@test "a dequeued another team-merge logged while team-land waited, the queue having dropped the PR for a failure of its own, is followed by team-land's with its failures" {
  with_queue
  land dequeued "the checks failed on the merge group" \
    '[{"name": "test", "class": "pr", "kind": "test", "link": "https://github.com/owner/proj/actions/runs/1/job/2", "step": "Run tests"}]'
  # A second team-merge, refused before it read the lock, found the PR's entry empty once the queue
  # dropped it, and logged its dequeued with no failures.
  sed -i '1i jq -cn --arg h "$2" '"'"'{ts: "2026-10-22T04:00:00Z", task: "T14", event: "dequeued", url: "https://github.com/owner/proj/pull/5", head: $h, reason: "PR #5 left the merge queue while no team-merge waited on it"}'"'"' >>"$TEAM_HOME/ledger.jsonl"' "$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued dequeued"
  assert_equal "$(queue_events | tail -n 1 | jq -c '{reason, failed: [.failed[].name]}')" \
    '{"reason":"the checks failed on the merge group","failed":["test"]}'
  [[ $stderr != *"logged already"* ]]
  assert_contains "$stderr" "  the trial merge failed what the head ${head:0:7} passed: render team-brief T14 builder-merge-base for the builder, then a rereview"
}

@test "--holds says whether the merge still holds at the head, changing nothing: 0 it holds, 1 it does not, 75 it cannot be told now" {
  default_word
  with_queue
  was_queued
  in_queue
  before=$(cat "$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-merge T14 --pr "$url" --holds "$head"
  assert_equal "$output" ""
  # Another head than the PR's.
  run_bin -1 --separate-stderr team-merge T14 --holds 0000000000000000000000000000000000000000
  assert_contains "$stderr" "  PR #5's head is ${head:0:7}, not 0000000, the head --holds names"
  # A conflict GitHub has not worked out is no reason for a PR in the queue, which is its proof.
  pr_field '.mergeable = "UNKNOWN"'
  run_bin -0 --separate-stderr team-merge T14 --pr "$url" --holds "$head"
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  pr_field '.mergeable = "MERGEABLE"'
  # Cannot be told now: GitHub unread, which gives no reason of the word's own.
  mv "$gh_dir/pr.json" "$gh_dir/pr.kept"
  run_bin -75 --separate-stderr team-merge T14 --holds "$head"
  assert_contains "$stderr" "  GitHub cannot be read: "
  mv "$gh_dir/pr.kept" "$gh_dir/pr.json"
  # The word gone: refused, and the PR left where it is, for team-land to take out.
  review "$head" findings
  run_bin -1 --separate-stderr team-merge T14 --holds "$head"
  assert_contains "$stderr" "team-merge: T14 cannot merge PR #5, so nothing changed:"
  assert_equal "$(dequeues)" ""
  no_land_call
  [[ ! -e $(lock) ]]
  jq -c 'select(.event != "review" or .verdict != "findings")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  assert_equal "$(cat "$TEAM_HOME/ledger.jsonl")" "$before"
  run_bin -2 team-merge T14 --holds abc
}

@test "--holds cannot tell now, exit 75, when the plan's files cannot be read" {
  default_word
  with_queue
  was_queued
  in_queue
  # The plan's task directory is its first project's, lib's, which the registry does not hold.
  jq -c 'if .event == "opened" then .project = "lib" | .branch = "feat/T14-lib" else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l"
  mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  event T14 worktree-added '{project: "proj", branch: "feat/T14-tooling", base: "dev", base_sha: "0123456", worktree: "/w/4"}'
  run_bin -75 --separate-stderr team-merge T14 --holds "$head"
  assert_contains "$stderr" "  the plan's files cannot be read"
  # And the PR in the queue is left there by a team-merge that refuses on it alone.
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "team-merge: PR #5 is left in the merge queue, since whether its merge holds cannot be told now: run team-merge T14 again"
  assert_equal "$(dequeues)" ""
  # With another PR of the task, the step names this one.
  second_pr
  run_bin -1 --separate-stderr team-merge T14 --pr "$url"
  assert_contains "$stderr" "team-merge: PR #5 is left in the merge queue, since whether its merge holds cannot be told now: run team-merge T14 --pr $url again"
}

@test "a run that read the PR open while another logged its merge finds the merged under the lock, and logs no second one" {
  with_queue
  was_queued
  in_queue
  # The other run's merged lands between this run's read of the task's events and its lock: the
  # entry read, the last before the lock, appends it and shows the PR merged.
  cat >"$gh_dir/entry.sh" <<'SH'
if [[ ! -e $GH_DIR/other-merged ]]; then
  : >"$GH_DIR/other-merged"
  jq -cn --arg url "https://github.com/owner/proj/pull/5" --arg m "$MERGE_SHA" --arg h "$(jq -r .headRefOid "$GH_DIR/pr.json")"     '{ts: "2026-10-22T04:00:00Z", task: "T14", event: "merged", pr: 5, merge: $m, head: $h, by: "another run",
      project: "proj", branch: "feat/T14-tooling", url: $url, approval: "head"}' >>"$TEAM_HOME/ledger.jsonl"
fi
SH
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued merged"
  assert_equal "$output" "team-merge: another team-merge logged PR #5 merged while this one read it: nothing more to do"
  no_land_call
}

@test "a run that read a queued standing while another logged its dequeued finds it under the lock, and logs a queued before it lands" {
  with_queue
  was_queued
  in_queue
  # The other run's dequeued lands between this run's read of the task's events and its lock: the
  # entry read, the last before the lock, appends it.
  cat >"$gh_dir/entry.sh" <<'SH'
if [[ ! -e $GH_DIR/other-dequeued ]]; then
  : >"$GH_DIR/other-dequeued"
  jq -cn --arg url "https://github.com/owner/proj/pull/5" --arg h "$(jq -r .headRefOid "$GH_DIR/pr.json")" \
    '{ts: "2026-10-22T04:00:00Z", task: "T14", event: "dequeued", url: $url, head: $h, reason: "another run took it out"}' >>"$TEAM_HOME/ledger.jsonl"
fi
SH
  land merged
  run_bin -0 --separate-stderr team-merge T14
  # The queued is logged before team-land runs, so the PR it enqueues never reads as out of the queue.
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued queued merged"
  assert_equal "$(wc -l <"$gh_dir/land.calls")" 1
}

# A git on PATH whose every fetch leaves a process behind, holding every descriptor the fetch was
# given but its standard streams and bats' fd 3, its pid in $GH_DIR/left-behind: leave_behind_on_fetch
leave_behind_on_fetch() {
  # shellcheck disable=SC2030 # each test's own, read by the scripts it runs
  export TEAM_PATH_FIRST=$BATS_TEST_TMPDIR/stubs
  {
    printf '%s\n' '#!/usr/bin/env bash' 'if [[ " $* " == *" fetch "* ]]; then' \
      '  sleep 300 >/dev/null 2>&1 3>&- &' '  echo $! >>"$GH_DIR/left-behind"' 'fi'
    printf 'exec %q "$@"\n' "$(command -v git)"
  } >"$BATS_TEST_TMPDIR/stubs/git"
  chmod +x "$BATS_TEST_TMPDIR/stubs/git"
}

@test "the task's lock is taken after the local checks, so a process one leaves behind never holds it" {
  with_local_checks
  with_queue
  # The local check leaves a process behind, holding every descriptor it was given.
  cat >"$gh_dir/check.extra" <<'SH'
sleep 300 &
echo $! >"$GH_DIR/left-behind"
SH
  run_bin -0 --separate-stderr team-merge T14
  left=$(cat "$gh_dir/left-behind")
  kill -0 "$left"
  rc=0
  flock -n "$(lock)" true || rc=$?
  kill "$left"
  assert_equal "$rc" 0
}

@test "a team-merge that takes the lock as it starts, for a queued PR, gives it to neither its local checks nor git's fetch, so what they leave behind never holds it" {
  with_local_checks
  with_queue
  was_queued
  in_queue
  # The local check and each git fetch leave a process behind, which would hold the lock had it
  # been given its descriptor.
  cat >"$gh_dir/check.extra" <<'SH'
sleep 300 3>&- &
echo $! >>"$GH_DIR/left-behind"
SH
  leave_behind_on_fetch
  run_bin -0 --separate-stderr team-merge T14
  local -a left
  mapfile -t left <"$gh_dir/left-behind"
  rm "$BATS_TEST_TMPDIR/stubs/git"
  # The fetch's and the check's.
  ((${#left[@]} >= 2))
  kill -0 "${left[@]}"
  rc=0
  flock -n "$(lock)" true || rc=$?
  kill "${left[@]}"
  assert_equal "$rc" 0
}

@test "the --holds run a team-land starts under the lock gives it to no git fetch, so what that leaves behind never holds it" {
  # Daniel's word named another head, so each run fetches the branch to check the head against it.
  moved_head base
  with_queue
  # team-land holds the merge again before it lands, as the real one does.
  land merged
  sed -i '1i "$CODE_CHECKOUT/bin/team-merge" T14 --pr "$1" --holds "$2" || exit' "$gh_dir/land.sh"
  leave_behind_on_fetch
  run_bin -0 --separate-stderr team-merge T14
  local -a left
  mapfile -t left <"$gh_dir/left-behind"
  rm "$BATS_TEST_TMPDIR/stubs/git"
  # The run's fetch and the --holds run's.
  ((${#left[@]} >= 2))
  kill -0 "${left[@]}"
  rc=0
  flock -n "$(lock)" true || rc=$?
  kill "${left[@]}"
  assert_equal "$rc" 0
}

@test "a PR team-land could not enqueue is logged dequeued with why, so no queued of it stands" {
  with_queue
  land refused "GitHub refused to enqueue $url at ${head:0:7}: the queue is full"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1)" "$(jq -cn --arg h "$head" --arg url "$url" '{task: "T14", event: "dequeued", url: $url,
    head: $h, reason: "GitHub refused to enqueue \($url) at \($h[:7]): the queue is full"}')"
  assert_contains "$stderr" "team-merge: PR #5 did not join the merge queue: GitHub refused to enqueue $url at ${head:0:7}: the queue is full"
}

@test "a team-land that ends with no result leaves the queued standing and says to run team-merge again" {
  with_queue
  in_queue
  printf '%s\n' 'echo "team-land: jq: error" >&2' 'exit 5' >"$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events)" "$(queued)"
  assert_contains "$stderr" "team-merge: team-land ended with no result (exit 5), so whether PR #5 is in the queue is not known: run team-merge T14 again"
}

@test "a PR already in the queue is checked again and waited on with no second queued, and taken out when a check no longer holds" {
  with_queue
  was_queued
  in_queue
  before=$(queue_events)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(cat "$gh_dir/land.calls")" "--task T14 $url $head"
  assert_equal "$(queue_events)" "$(printf '%s\n' "$before" "$(merged_on_head)")"
  # The word and the checks are held again: a check now pending on the head refuses the resume,
  # and the PR leaves the queue, since its trial commit would land all the same.
  merge_again
  queue_rule
  in_queue
  rm "$gh_dir/land.calls"
  checks '[{"name": "test", "bucket": "pending", "state": "IN_PROGRESS"}, {"name": "lint", "bucket": "pass", "state": "SUCCESS"},
    {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  checks pending on the head: test"
  no_land_call
  assert_equal "$(dequeues)" "pr=PR_kwDOtest5"
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued dequeued"
}

@test "a queued is logged whenever none stands for what is enqueued: an entry no event shows, a drop nobody waited on, another head" {
  with_queue
  # In the queue on GitHub, with no queued in the ledger.
  in_queue
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(queue_events)" "$(queued; merged_on_head)"
  # A queued stands, but the PR is in no queue: it was dropped unseen, and is enqueued anew.
  merge_again
  queue_rule
  in_queue no
  was_queued
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r .event | paste -sd' ')" "queued queued queued merged"
  # A queued of an earlier head stands, and the entry is of the head now.
  merge_again
  queue_rule
  jq -c 'select(.event != "queued")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  was_queued 0000000000000000000000000000000000000000
  in_queue
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(queue_events | jq -r '.event + " " + .head[:7]' | paste -sd,)" "queued 0000000,queued ${head:0:7},merged ${head:0:7}"
}

@test "a PR the queue landed while no team-merge waited is logged merged on the next run, with nothing enqueued" {
  with_queue
  was_queued
  pr_field ".state = \"MERGED\" | .mergeable = \"UNKNOWN\" | .mergeCommit = {oid: \"$merge\"}"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(cat "$gh_dir/land.calls")" "--task T14 $url $head"
  assert_equal "$(queue_events)" "$(queued; merged_on_head)"
  assert_contains "$stderr" "team-merge: PR #5 is merged, and T14's queued event of its head ${head:0:7} at 2026-10-22T02:00:00Z stands: the queue landed it with no team-merge waiting"
  # With no queued standing for the merged head, a merged PR is refused as ever.
  merge_again
  queue_rule
  jq -c 'select(.event != "queued")' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/l" && mv "$TEAM_HOME/l" "$TEAM_HOME/ledger.jsonl"
  was_queued 0000000000000000000000000000000000000000
  rm "$gh_dir/land.calls"
  pr_field '.state = "MERGED"'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  PR #5 is merged, not open"
  no_land_call
}

@test "a PR landed unwatched whose word no longer reads back is still logged merged, naming the queued it stood on, with no post" {
  default_word
  with_queue
  was_queued
  pr_field ".state = \"MERGED\" | .mergeCommit = {oid: \"$merge\"}"
  echo "# T14 spec, changed" >"$BATS_TEST_TMPDIR/wt/.scratch/task/spec.md"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1)" "$(jq -cn --arg m "$merge" --arg h "$head" --arg url "$url" '{task: "T14", event: "merged",
    pr: 5, merge: $m, head: $h, by: "the word team-merge queued it on at 2026-10-22T02:00:00Z, which does not hold now",
    project: "proj", branch: "feat/T14-tooling", url: $url}')"
  assert_contains "$stderr" "  the plan changed since its approval at 2026-10-22T02:00:00Z (.scratch/task/spec.md): approve it again"
  assert_equal "$(posts)" ""
}

@test "a second team-merge while one is landing the PR names the holder and exits 0, with no second queued or team-land" {
  with_queue
  # The first run's team-land waits until the test lets it go.
  land merged
  sed -i "1i while [[ ! -e \$GH_DIR/go ]]; do sleep 0.1; done" "$gh_dir/land.sh"
  "$CODE_CHECKOUT/bin/team-merge" T14 >"$BATS_TEST_TMPDIR/first.out" 2>"$BATS_TEST_TMPDIR/first.err" 3>&- &
  first=$!
  for _ in $(seq 300); do
    [[ ! -e $gh_dir/land.calls ]] || break
    sleep 0.1
  done
  [[ -e $gh_dir/land.calls ]]
  assert_equal "$(cat "$(lock)")" "$first"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$output" "team-merge is already landing $url (pid $first)"
  assert_equal "$(queue_events)" "$(queued)"
  assert_equal "$(wc -l <"$gh_dir/land.calls")" 1
  touch "$gh_dir/go"
  wait "$first"
  assert_equal "$(queue_events)" "$(queued; merged_on_head)"
}

# The queue-wait findings the coordinator's Stop hook keeps its turn open with, run as Claude
# Code runs it at a turn's end, one a line; nothing with none. Fails when the sweep itself did.
hook_queue_waits() {
  local out
  out=$("${CODE_CHECKOUT:?}/bin/hooks/stop-sweep" <<<'{"stop_hook_active": false}') || return
  if [[ $out == *"team-sweep failed"* ]]; then
    echo "$out" >&2
    return 1
  fi
  jq -r '.reason // empty' <<<"$out" | sed -n '/^T14 queue-wait: /p'
}

# The Bash for a stub to run, which holds it at step <step> the first time it gets there, until
# release <step>: pause_at <step>
pause_at() {
  printf '%s\n' "if [[ ! -e \$GH_DIR/at-$1 ]]; then : >\"\$GH_DIR/at-$1\"" \
    "  for _ in {1..1200}; do [[ -e \$GH_DIR/go-$1 ]] && break; sleep 0.05; done" 'fi'
}

# Wait until a stub is held at <step> (pause_at): reached <step>
reached() {
  for _ in {1..600}; do
    [[ -e $gh_dir/at-$1 ]] && return 0
    sleep 0.05
  done
  echo "nothing reached the step $1" >&2
  return 1
}

release() {
  : >"$gh_dir/go-$1"
}

# Start team-merge T14 in the background, as the coordinator's run_in_background does, its pid in
# $merging: start_merge
start_merge() {
  "$CODE_CHECKOUT/bin/team-merge" T14 >"$BATS_TEST_TMPDIR/merge.out" 2>"$BATS_TEST_TMPDIR/merge.err" 3>&- &
  merging=$!
}

# Hold the sweep's next reading of a merge lock at the step scan: a find (an lsof where there is
# no /proc) on PATH that waits there before the real one reads. The lock of a task merged long
# ago, which nobody holds, is there for it to read, as a machine's lock directory keeps them.
pause_the_lock_reading() {
  local cmd real
  mkdir -p "$HOME/.local/state/agent-team/merge"
  echo 4242 >"$HOME/.local/state/agent-team/merge/T3.lock"
  # shellcheck disable=SC2031 # each test's own, read by the scripts it runs
  export TEAM_PATH_FIRST=$BATS_TEST_TMPDIR/stubs
  for cmd in find lsof; do
    real=$(command -v "$cmd") || continue
    {
      printf '%s\n' '#!/usr/bin/env bash' 'if [[ " $* " == *"-printf %l"* || $0 == */lsof ]]; then'
      pause_at scan
      printf '%s\n' 'fi' "exec $(printf %q "$real") \"\$@\""
    } >"$BATS_TEST_TMPDIR/stubs/$cmd"
    chmod +x "$BATS_TEST_TMPDIR/stubs/$cmd"
  done
}

@test "the Stop hook's sweep finds no queue-wait at any step of a team-merge run again on a queued PR, and finds it with none" {
  stub_reply claude '[]'
  with_local_checks
  with_queue
  was_queued
  in_queue
  # No team-merge waits on it.
  assert_contains "$(hook_queue_waits)" "T14 queue-wait: PR $url is in the merge queue"
  # One run again, at its GitHub reads, at its local checks, and in team-land.
  pause_at reads >"$gh_dir/entry.sh"
  pause_at checks >"$gh_dir/check.extra"
  land waiting "the deadline came with the PR in the queue"
  pause_at land | sed -i '1r /dev/stdin' "$gh_dir/land.sh"
  start_merge
  local step
  for step in reads checks land; do
    reached "$step"
    assert_equal "$step: $(hook_queue_waits)" "$step: "
    release "$step"
  done
  # It ends with the PR still in the queue, so nothing waits on it again.
  local rc=0
  wait "$merging" || rc=$?
  assert_equal "$rc" 75
  assert_contains "$(hook_queue_waits)" "T14 queue-wait: PR $url is in the merge queue"
}

@test "the Stop hook's sweep finds no queue-wait for a team-merge that takes the lock and logs its queued while the sweep reads the locks" {
  stub_reply claude '[]'
  with_queue
  land merged
  pause_at land | sed -i '1r /dev/stdin' "$gh_dir/land.sh"
  pause_the_lock_reading
  hook_queue_waits >"$BATS_TEST_TMPDIR/hook.out" 3>&- &
  local hook=$!
  reached scan
  # The task has no lock file yet: the team-merge the coordinator just started makes it.
  start_merge
  reached land
  assert_equal "$(queue_events)" "$(queued)"
  release scan
  wait "$hook"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/hook.out")" ""
  release land
  wait "$merging"
  assert_equal "$(hook_queue_waits)" ""
}

@test "the Stop hook's sweep finds no queue-wait for a team-merge that logs its merge and lets the lock go while the sweep reads the locks" {
  stub_reply claude '[]'
  with_queue
  land merged
  pause_at land | sed -i '1r /dev/stdin' "$gh_dir/land.sh"
  start_merge
  reached land
  pause_the_lock_reading
  hook_queue_waits >"$BATS_TEST_TMPDIR/hook.out" 3>&- &
  local hook=$!
  reached scan
  release land
  wait "$merging"
  release scan
  wait "$hook"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/hook.out")" ""
}

@test "the Stop hook's sweep finds no queue-wait for a team-merge run again on a queued PR that found the lock held at its start, once its holder ends" {
  stub_reply claude '[]'
  with_local_checks
  with_queue
  was_queued
  in_queue
  pause_at reads >"$gh_dir/entry.sh"
  pause_at checks >"$gh_dir/check.extra"
  land waiting "the deadline came with the PR in the queue"
  # Another run holds the lock as this one starts, and ends, the PR still queued, while this one
  # reads GitHub.
  mkdir -p "$(dirname "$(lock)")"
  flock -o "$(lock)" bash -c "$(pause_at holder)" 3>&- &
  local holder=$!
  reached holder
  start_merge
  reached reads
  release holder
  wait "$holder"
  release reads
  reached checks
  assert_equal "$(hook_queue_waits)" ""
  release checks
  local rc=0
  wait "$merging" || rc=$?
  assert_equal "$rc" 75
}

@test "a refusal on a base with a queue logs nothing, takes no lock and runs no team-land, and a method other than merge is refused" {
  with_queue
  pr_field '.isDraft = true'
  refused "PR #5 is a draft"
  no_land_call
  [[ ! -e $(lock) ]]
  green_pr
  queue_rule
  sed -i 's/^merge_method = "merge"$/merge_method = "squash"/' "$TEAM_HOME/projects.toml"
  refused "dev merges through its merge queue, which the team lands only with merge_method merge, not proj's squash"
  no_land_call
}

@test "on a base with a queue, a required check missing on a head behind its base names team-catch-up, but not with agent-review missing or a head up to date" {
  with_queue
  step="run team-catch-up T14, which merges dev into the PR so the check runs on it"
  checks '[{"name": "lint", "bucket": "pass", "state": "SUCCESS"}, {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  echo 3 >"$gh_dir/behind_by"
  refused "required check test is missing on the head, which is 3 commits behind dev: $step"
  no_land_call
  echo 1 >"$gh_dir/behind_by"
  refused "required check test is missing on the head, which is 1 commit behind dev: $step"
  # agent-review no merge's run brings, so team-catch-up refuses a head lacking it: no step there.
  checks '[{"name": "test", "bucket": "pass", "state": "SUCCESS"}, {"name": "lint", "bucket": "pass", "state": "SUCCESS"}]'
  refused "required check agent-review is missing on the head"
  [[ $stderr != *team-catch-up* ]]
  # Nor beside it: with agent-review missing too, team-catch-up refuses the head all the same.
  checks '[{"name": "lint", "bucket": "pass", "state": "SUCCESS"}]'
  refused "required check test is missing on the head" "required check agent-review is missing on the head"
  [[ $stderr != *team-catch-up* ]]
  # A head that holds its base, or whose compare cannot be read, gets no step.
  checks '[{"name": "lint", "bucket": "pass", "state": "SUCCESS"}, {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  echo 0 >"$gh_dir/behind_by"
  refused "required check test is missing on the head"
  [[ $stderr != *team-catch-up* ]]
  rm "$gh_dir/behind_by"
  refused "required check test is missing on the head"
  [[ $stderr != *team-catch-up* ]]
}

@test "a queue GitHub cannot be asked about is refused, nothing logged" {
  with_queue
  echo 'not json' >"$gh_dir/entry.json"
  refused "GitHub cannot be read: PR #5's merge queue entry"
  no_land_call
}

@test "on a base with no queue the PR is merged directly, with no queue read, lock, queued or team-land" {
  with_queue
  echo '[]' >"$gh_dir/rules.json"
  sed -i 's/^merge_method = "merge"$/merge_method = "squash"/' "$TEAM_HOME/projects.toml"
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["pr", "merge"])')" \
    "[\"pr\",\"merge\",\"5\",\"--repo\",\"owner/proj\",\"--squash\",\"--match-head-commit\",\"$head\"]"
  assert_equal "$(stub_calls gh | jq -c 'select(.[0:2] == ["api", "graphql"])')" ""
  assert_equal "$(queue_events | jq -r .event)" merged
  no_land_call
  [[ ! -e $(lock) ]]
}

@test "the header says to run it in the background on a base with a queue, and names queued, dequeued and the exit codes" {
  run_bin -0 team-merge --help
  assert_contains "$output" "run_in_background"
  assert_contains "$output" "queued"
  assert_contains "$output" "dequeued"
  assert_contains "$output" "Exit 0"
  assert_contains "$output" "75"
  # The rules drop and its next step.
  assert_contains "$(tr -s ' \n' ' ' <<<"$output")" "with a rules failure (a check the base's rules or the project's required_checks require that never reported on the trial commit, each said as \"<name> was not reported on the trial merge, which <base>'s rules require\", or \"which the project's required_checks require\" for one they alone require), to run team-doctor (its merge queue line)"
}
