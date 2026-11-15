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
  assert_equal "$(cat "$gh_dir/land.calls")" "$url $head"
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

@test "a PR the queue dropped for anything but a failure of its own says to run team-merge again once the reason is fixed" {
  with_queue
  land dequeued "the queue was cleared"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1)" "$(jq -cn --arg h "$head" --arg url "$url" \
    '{task: "T14", event: "dequeued", url: $url, head: $h, reason: "the queue was cleared"}')"
  assert_contains "$stderr" "team-merge: the merge queue dropped PR #5, which is not merged: the queue was cleared"
  assert_contains "$stderr" "  run team-merge T14 again once the queue was cleared is fixed"
  [[ $stderr != *builder-merge-base* ]]
  # Infrastructure alone, which team-land enqueued once more for, is no failure of the PR's own.
  merge_again
  queue_rule
  land dequeued "the checks timed out" '[{"name": "test", "class": "infrastructure", "kind": "runner", "link": "", "step": ""}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events | tail -n 1 | jq -c '[.event, .failed[0].class]')" '["dequeued","infrastructure"]'
  assert_contains "$stderr" "  test failed on the trial merge as infrastructure"
  assert_contains "$stderr" "  run team-merge T14 again once the checks timed out is fixed"
  [[ $stderr != *builder-merge-base* ]]
}

@test "a PR still in the queue at team-land's deadline logs nothing more and exits 75, to go on waiting" {
  with_queue
  land waiting "$url is still in the merge queue after 240 minutes: run team-land again to go on waiting"
  run_bin -75 --separate-stderr team-merge T14
  assert_equal "$output" ""
  assert_equal "$(queue_events)" "$(queued)"
  assert_contains "$stderr" "team-merge: the PR is still in the queue: run team-merge T14 again with run_in_background to go on waiting"
  flock -n "$(lock)" true
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
  printf '%s\n' 'echo "team-land: jq: error" >&2' 'exit 5' >"$gh_dir/land.sh"
  run_bin -1 --separate-stderr team-merge T14
  assert_equal "$(queue_events)" "$(queued)"
  assert_contains "$stderr" "team-merge: team-land ended with no result (exit 5), so whether PR #5 is in the queue is not known: run team-merge T14 again"
}

@test "a PR already in the queue is checked again and waited on with no second queued" {
  with_queue
  was_queued
  in_queue
  before=$(queue_events)
  run_bin -0 --separate-stderr team-merge T14
  assert_equal "$(cat "$gh_dir/land.calls")" "$url $head"
  assert_equal "$(queue_events)" "$(printf '%s\n' "$before" "$(merged_on_head)")"
  # The word and the checks are held again: a check now pending on the head refuses the resume.
  merge_again
  queue_rule
  in_queue
  rm "$gh_dir/land.calls"
  checks '[{"name": "test", "bucket": "pending", "state": "IN_PROGRESS"}, {"name": "lint", "bucket": "pass", "state": "SUCCESS"},
    {"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'
  run_bin -1 --separate-stderr team-merge T14
  assert_contains "$stderr" "  checks pending on the head: test"
  no_land_call
  assert_equal "$(queue_events)" "$before"
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
  assert_equal "$(cat "$gh_dir/land.calls")" "$url $head"
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
}
