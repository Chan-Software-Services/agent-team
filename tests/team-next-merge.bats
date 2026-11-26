#!/usr/bin/env bats
# shellcheck disable=SC2154 # sha, url and counts are helpers/team-next.bash's
# team-next T7 --ci's passed end: the merge ask and its words (the default word, guarded areas,
# counts that keep the merge Daniel's), the catch-up of a PR behind its base, the merge queue, and
# the builder-merge-base step. The sandbox is helpers/team-next's.

load helpers/common
load helpers/github-api
load helpers/team-next

setup() {
  team_next_sandbox
}

@test "--ci on checks that passed logs ci passed of the waited head and prints the merge ask's facts, never posting or merging" {
  local count
  reviewing "$sha"
  pr_on_github "$sha"
  ci_wait_ends passed "$sha"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=ci"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$output" "logged ci url=$url head=$sha outcome=passed
merge ask: $url at $sha, agent-review success, checks green; the review found guarded areas: ci, so the default word does not hold"
  assert_equal "$(stub_calls team-ci-wait)" "[\"--no-agent-review\",\"--json\",\"$url\",\"$sha\"]"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'del(.task)')" \
    "$(jq -cn --arg url "$url" --arg h "$sha" '{event: "ci", url: $url, head: $h, outcome: "passed"}')"
  assert_equal "$(outside_calls)" ""
  assert_equal "$(bg_calls)" ""
}

@test "a pass with before notes and pending checks names them, a rerun logs nothing twice, and a rerun of --ci logs only a new end" {
  reviewing "$sha"
  pr_on_github "$sha" 0 '[{"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}, {"name": "test", "bucket": "pending", "state": "PENDING"}]'
  passed -- "T7 DONE pass $url ${counts%:0}:2 before=4,5 guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks pending: test; queue before notes 4 and 5 as follow-ups and say where each went"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url ${counts%:0}:2 before=4,5 guarded=none"
  assert_contains "$output" "already logged review verdict=pass head=$sha"
  assert_contains "$output" "already logged done role=reviewer session=r0000002"
  assert_equal "$(tail -n 1 <<<"$output")" "$(arm_line "$sha")"
  assert_equal "$(jq -c 'select(.event == "review")' "$TEAM_HOME/ledger.jsonl" | wc -l)" 1
  # --ci again waits again; the same end is logged once, and the merge line printed again.
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(head -n 1 <<<"$output")" "already logged ci url=$url head=$sha outcome=passed"
  assert_contains "$(tail -n 1 <<<"$output")" "merge on the default word: run team-merge T7 for $url at $sha"
  assert_equal "$(stub_calls team-ci-wait | wc -l)" 2
  assert_equal "$(ci_logged)" "[\"$url\",\"$sha\",\"passed\"]"
  # A new end is logged.
  ci_wait_ends deadline "$sha" 75 "team-ci-wait: 90 minutes, and checks still pending on ${sha:0:7}: test (in_progress, run 7 in_progress): run team-ci-wait again to wait on them, or report BLOCKED"
  run_bin -75 --separate-stderr team-next T7 --ci
  assert_equal "$(ci_logged)" "[\"$url\",\"$sha\",\"passed\"]
[\"$url\",\"$sha\",\"pending\"]"
}

# on_origin [<file> <text>]: the PR's branch pushed to origin, and origin's main moved on by a
# commit of another task's that writes <file> (default other.txt) with <text>.
on_origin() {
  local other=$BATS_TEST_TMPDIR/other
  git -C "${wt:?}" push -q origin feat/T7-toil
  git clone -q "$BATS_TEST_TMPDIR/origin/proj.git" "$other"
  echo "${2:-other}" >"$other/${1:-other.txt}"
  git -C "${other:?}" add -A
  git -C "${other:?}" commit -q -m "feat: another task"
  git -C "${other:?}" push -q origin main
}

@test "--ci on a PR behind its base that merges it cleanly prints team-catch-up, with no holder step" {
  on_origin
  reviewing "$sha"
  pr_on_github "$sha" 3
  live b0000001 120000
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$output" "logged ci url=$url head=$sha outcome=passed"
  assert_equal "$(tail -n 2 <<<"$output")" \
    "merge base: $url is 3 behind main, and merges it cleanly: run team-catch-up T7, which needs no rereview (step 6)
then, once the checks pass on its merge: merge on the default word: run team-merge T7 for $url at $sha"
  # It changed no branch, worktree or index: the merge is team-catch-up's to make.
  assert_equal "$(git -C "${wt:?}" rev-parse HEAD)" "$sha"
  assert_equal "$(git -C "${primary:?}" status --porcelain)" ""
  assert_equal "$(outside_calls)" ""
}

@test "--ci on a PR behind its base that merges it cleanly still says the review's before notes, guarded areas and words" {
  on_origin
  reviewing "$sha"
  pr_on_github "$sha" 3
  live b0000001 120000
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 2 <<<"$output")" \
    "merge base: $url is 3 behind main, and merges it cleanly: run team-catch-up T7, which needs no rereview (step 6)
then, once the checks pass on its merge: merge on the default word: run team-merge T7 for $url at $sha"
  launched r0000003 brief-review '["browser"]' reviewer
  passed -- "T7 DONE pass $url ${counts/note-before:0/note-before:2} before=4,5 guarded=ci"
  assert_equal "$(tail -n 2 <<<"$output")" \
    "merge base: $url is 3 behind main, and merges it cleanly: run team-catch-up T7, which needs no rereview (step 6)
then, once the checks pass on its merge: merge ask: $url at $sha; the review found guarded areas: ci, so the default word does not hold; queue before notes 4 and 5 as follow-ups and say where each went"
  assert_equal "$(outside_calls)" ""
}

@test "--ci on a PR behind its base that conflicts with it prints the builder-merge-base step naming the files" {
  on_origin one.txt "dev's own text"
  reviewing "$sha"
  pr_on_github "$sha" 3
  live b0000001 120000
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$output" "logged ci url=$url head=$sha outcome=passed"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge base: $url is 3 behind main and conflicts on one.txt, so it merges main first (step 6): render team-brief T7 builder-merge-base, send its path to T7-builder (b0000001, 120k) and log team-log T7 resumed brief=<its file name without .md>, which holds team-sweep's merge-due"
  # Past 250k, the holder stows and a fresh builder takes the brief.
  live b0000001 260000
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge base: $url is 3 behind main and conflicts on one.txt, so it merges main first (step 6): send T7 STOW to T7-builder (b0000001, 260k), then launch a fresh builder on team-brief T7 builder-merge-base"
  # Gone, a fresh builder takes it.
  live
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge base: $url is 3 behind main and conflicts on one.txt, so it merges main first (step 6): T7-builder b0000001 is gone, so launch a fresh builder on team-brief T7 builder-merge-base"
  assert_equal "$(outside_calls)" ""
}

@test "--ci on a base with a merge queue gives a PR only behind it the merge line, with no catch-up, and a conflict the builder-merge-base step" {
  # shellcheck disable=SC2030,SC2031 # each test is a subshell of its own, and sets it for its stub
  export GH_QUEUE=1
  on_origin
  reviewing "$sha"
  pr_on_github "$sha" 3
  live b0000001 120000
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$output" "logged ci url=$url head=$sha outcome=passed"
  [[ $output != *"merge base"* && $output != *team-catch-up* ]]
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks green"
  assert_equal "$(git -C "${primary:?}" status --porcelain)" ""
  # A conflict is still the holder's to merge, queue or not.
  echo "dev's own text" >"${BATS_TEST_TMPDIR:?}/other/one.txt"
  git -C "${BATS_TEST_TMPDIR:?}/other" add -A
  git -C "${BATS_TEST_TMPDIR:?}/other" commit -q -m "feat: one more task"
  git -C "${BATS_TEST_TMPDIR:?}/other" push -q origin main
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge base: $url is 3 behind main and conflicts on one.txt, so it merges main first (step 6): render team-brief T7 builder-merge-base, send its path to T7-builder (b0000001, 120k) and log team-log T7 resumed brief=<its file name without .md>, which holds team-sweep's merge-due"
  assert_equal "$(outside_calls)" ""
}

@test "--ci on a PR the merge queue dropped for a failure of its own prints the builder-merge-base step, never the merge line nor the rules step, until it is reviewed again" {
  # shellcheck disable=SC2030,SC2031 # each test is a subshell of its own, and sets it for its stub
  export GH_QUEUE=1
  on_origin
  reviewing "$sha"
  pr_on_github "$sha" 0
  live b0000001 120000
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$(tail -n 1 <<<"$output")" "merge on the default word: run team-merge T7"
  # Beside a rules failure too, the PR's own failures lead: a roll-up whose shards the queue
  # cancelled once test failed reads as the rules' with no run open.
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T09:00:00Z", task: "T7", event: "queued", url: $url, head: $head, project: "proj"},
    {ts: "2026-10-23T10:00:00Z", task: "T7", event: "dequeued", url: $url, head: $head, reason: "failed_checks; e2e never reported on the trial commit, which main'"'"'s rules require",
      failed: [{name: "test", class: "pr", kind: "failed", link: "", step: "Run tests"}, {name: "lint", class: "pr", kind: "failed", link: "", step: ""},
        {name: "e2e", class: "rules", kind: "missing", link: "", step: ""}]}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge base: $url failed test and lint on the merge queue's trial merge, which dropped it at 2026-10-23T10:00:00Z, so the builder fixes it on the branch (step 6): render team-brief T7 builder-merge-base, send its path to T7-builder (b0000001, 120k) and log team-log T7 resumed brief=<its file name without .md>, which holds team-sweep's merge-due"
  [[ $output != *"run team-merge"* && $output != *"merge rules:"* ]]
}

@test "--ci on a PR the merge queue dropped for a check the base's rules require prints the rules step, never the merge line nor the merge-base step, until it is queued again" {
  # shellcheck disable=SC2030,SC2031 # each test is a subshell of its own, and sets it for its stub
  export GH_QUEUE=1
  on_origin
  reviewing "$sha"
  pr_on_github "$sha" 0
  live b0000001 120000
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$(tail -n 1 <<<"$output")" "merge on the default word: run team-merge T7"
  # Rules failures beside infrastructure: the rules step alone, naming only the rules checks.
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T09:00:00Z", task: "T7", event: "queued", url: $url, head: $head, project: "proj"},
    {ts: "2026-10-23T10:00:00Z", task: "T7", event: "dequeued", url: $url, head: $head, reason: "Analyze (actions) and e2e never reported on the trial commit, which main'"'"'s rules require",
      failed: [{name: "Analyze (actions)", class: "rules", kind: "missing", link: "", step: ""}, {name: "lint", class: "infrastructure", kind: "setup", link: "", step: "Set up job"},
        {name: "e2e", class: "rules", kind: "missing", link: "", step: ""}]}' \
    >>"$TEAM_HOME/ledger.jsonl"
  local rules_step="merge rules: $url was dropped by the merge queue at 2026-10-23T10:00:00Z: Analyze (actions) and e2e never reported on its trial commit, which main's rules require; the base's rules require a check no workflow makes on a trial commit: run team-doctor (its merge queue line), fix the workflow's merge_group trigger or ask Daniel to change owner/proj's ruleset, then run team-merge T7 again"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "$rules_step"
  [[ $output != *"run team-merge T7 for"* ]]
  [[ $output != *"merge base:"* ]]
  [[ $output != *"merge ask:"* ]]
  # Behind its base too: still the rules step, no catch-up and no merge-base brief.
  pr_on_github "$sha" 3
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "$rules_step"
  [[ $output != *"merge base:"* ]]
  # Queued again once the rules are fixed: the merge line is back.
  pr_on_github "$sha" 0
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T11:00:00Z", task: "T7", event: "queued", url: $url, head: $head, project: "proj"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_contains "$(tail -n 1 <<<"$output")" "merge on the default word: run team-merge T7 for $url"
  [[ $output != *"merge rules:"* ]]
  # A check the project's required_checks alone require is said as theirs, with team-merge's step
  # for them.
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T12:00:00Z", task: "T7", event: "dequeued", url: $url, head: $head, reason: "",
      failed: [{name: "data", class: "rules", kind: "missing", link: "", step: "", source: "required_checks"}]}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "merge rules: $url was dropped by the merge queue at 2026-10-23T12:00:00Z: data never reported on its trial commit, which the project's required_checks require; the project's required_checks require a check no workflow makes on a trial commit: fix the workflow's merge_group trigger or the project's required_checks in the registry, then run team-merge T7 again"
}

@test "--ci on a PR the merge queue dropped for a runner backlog says the runners are the wait and names team-merge once they are back, and after any other drop the merge line" {
  # shellcheck disable=SC2030,SC2031 # each test is a subshell of its own, and sets it for its stub
  export GH_QUEUE=1
  on_origin
  reviewing "$sha"
  pr_on_github "$sha" 0
  live b0000001 120000
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  local merge_line="merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks green"
  assert_equal "$(tail -n 1 <<<"$output")" "$merge_line"
  # runners_line <time>: the line after a runner backlog drop at <time>.
  runners_line() {
    echo "merge runners: $url was dropped by the merge queue at $1: the runners are behind, with nothing of the PR's to fix: tell Daniel, who may raise the check timeout of owner/proj's merge queue while the backlog stands, and run team-merge T7 again once they say the runners are back"
  }
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T09:00:00Z", task: "T7", event: "queued", url: $url, head: $head, project: "proj"},
    {ts: "2026-10-23T10:00:00Z", task: "T7", event: "dequeued", url: $url, head: $head, reason: "failed_checks",
      failed: [{name: "e2e shard 1/2", class: "infrastructure", kind: "queued", link: "", step: ""}, {name: "e2e", class: "infrastructure", kind: "missing", link: "", step: ""},
        {name: "test", class: "rollup", kind: "rollup", link: "", step: ""}]}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "$(runners_line 2026-10-23T10:00:00Z)"
  [[ $output != *"merge on the default word:"* && $output != *"merge ask:"* && $output != *"merge base:"* ]]
  # Behind its base on a base with a queue, which needs no catch-up: still the runners.
  pr_on_github "$sha" 3
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "$(runners_line 2026-10-23T10:00:00Z)"
  [[ $output != *"merge base:"* && $output != *team-catch-up* ]]
  # The queue's own check timeout, with no failure read on the trial commit.
  pr_on_github "$sha" 0
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T11:00:00Z", task: "T7", event: "dequeued", url: $url, head: $head, reason: "checks_timed_out"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "$(runners_line 2026-10-23T11:00:00Z)"
  # Any other drop, as a setup failure's: the merge line as before.
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T12:00:00Z", task: "T7", event: "dequeued", url: $url, head: $head, reason: "failed_checks",
      failed: [{name: "lint", class: "infrastructure", kind: "setup", link: "", step: "Set up job"}]}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "$merge_line"
  [[ $output != *"runners"* ]]
  # Queued again once the runners are back: the merge line.
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T13:00:00Z", task: "T7", event: "dequeued", url: $url, head: $head, reason: "checks_timed_out"},
    {ts: "2026-10-23T14:00:00Z", task: "T7", event: "queued", url: $url, head: $head, project: "proj"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "$merge_line"
  # A conflict is still the holder's to merge first, since team-merge would refuse it.
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T15:00:00Z", task: "T7", event: "dequeued", url: $url, head: $head, reason: "checks_timed_out"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  echo "dev's own text" >"${BATS_TEST_TMPDIR:?}/other/one.txt"
  git -C "${BATS_TEST_TMPDIR:?}/other" add -A
  git -C "${BATS_TEST_TMPDIR:?}/other" commit -q -m "feat: one more task"
  git -C "${BATS_TEST_TMPDIR:?}/other" push -q origin main
  pr_on_github "$sha" 3
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_contains "$(tail -n 1 <<<"$output")" "merge base: $url is 3 behind main and conflicts on one.txt"
}

@test "--ci's merge runners line names team-merge --pr in a task with a PR in another repository, since team-merge alone takes the latest pr event's" {
  # shellcheck disable=SC2030,SC2031 # each test is a subshell of its own, and sets it for its stub
  export GH_QUEUE=1
  on_origin
  reviewing "$sha"
  pr_on_github "$sha" 0
  live b0000001 120000
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  jq -cn --arg url "$url" --arg head "$sha" '{ts: "2026-10-23T09:00:00Z", task: "T7", event: "pr", url: "https://github.com/owner/other/pull/3", head: "0123456"},
    {ts: "2026-10-23T10:00:00Z", task: "T7", event: "dequeued", url: $url, head: $head, reason: "checks_timed_out"}' \
    >>"$TEAM_HOME/ledger.jsonl"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge runners: $url was dropped by the merge queue at 2026-10-23T10:00:00Z: the runners are behind, with nothing of the PR's to fix: tell Daniel, who may raise the check timeout of owner/proj's merge queue while the backlog stands, and run team-merge T7 --pr $url again once they say the runners are back"
}

@test "--ci on a PR behind its base whose merge cannot be read prints the builder-merge-base step with the reason" {
  # The branch is not on origin, so the fetch fails.
  reviewing "$sha"
  pr_on_github "$sha" 3
  live b0000001 120000
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$output" "logged ci url=$url head=$sha outcome=passed"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge base: $url is 3 behind main (whether the merge is clean is not known: the PR's branch feat/T7-toil and main cannot be fetched into $primary: fatal: couldn't find remote ref refs/heads/feat/T7-toil), so it merges main first (step 6): render team-brief T7 builder-merge-base, send its path to T7-builder (b0000001, 120k) and log team-log T7 resumed brief=<its file name without .md>, which holds team-sweep's merge-due"
  # A head git cannot read once fetched: base_merge's line is the reason.
  on_origin
  reviewing 0123456789abcdef0123456789abcdef01234567
  pr_on_github 0123456789abcdef0123456789abcdef01234567 3
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge base: $url is 3 behind main (whether the merge is clean is not known: merge-tree: 0123456789abcdef0123456789abcdef01234567 - not something we can merge), so it merges main first (step 6): render team-brief T7 builder-merge-base, send its path to T7-builder (b0000001, 120k) and log team-log T7 resumed brief=<its file name without .md>, which holds team-sweep's merge-due"
  assert_equal "$(outside_calls)" ""
}

@test "--ci after a team-catch-up waits on the merge's checks, and its merge line names the reviewed head" {
  local merge=fedcba9876543210fedcba9876543210fedcba98
  reviewing "$sha"
  pr_on_github "$sha"
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  # team-catch-up made the merge from the reviewed head, and GitHub shows it as the PR's head.
  event caught-up "$(jq -cn --arg url "$url" --arg h "$sha" --arg m "$merge" '{url: $url, from: $h, head: $m,
    base: "1111111111111111111111111111111111111111"}')"
  pr_on_github "$merge"
  ci_wait_ends passed "$merge"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$output" "logged ci url=$url head=$merge outcome=passed
merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks green"
  assert_equal "$(stub_calls team-ci-wait | tail -n 1)" "[\"--no-agent-review\",\"--json\",\"$url\",\"$merge\"]"
  assert_equal "$(ci_logged)" "[\"$url\",\"$sha\",\"passed\"]
[\"$url\",\"$merge\",\"passed\"]"
}

@test "--ci after a pass while the default word holds says to merge on it, unless the review found guarded areas or the default is withdrawn" {
  reviewing "$sha"
  pr_on_github "$sha"
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks green"
  # A later review that found a guarded area brings the merge back to Daniel.
  launched r0000003 brief-review '["browser"]' reviewer
  passed -- "T7 DONE pass $url $counts before=none guarded=ci,secrets"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks green; the review found guarded areas: ci, secrets, so the default word does not hold"
  # A withdrawal of the default word for the task's project, logged under another task, holds it
  # back; its giving back for every project lets it merge again.
  launched r0000004 brief-review '["browser"]' reviewer
  jq -cn '{ts: "2026-11-01T10:00:00Z", task: "T6", event: "merge-default-withdrawn", scope: "proj",
    discord_message: "1563000000000000046", discord_channel: "1563000000000000012"}' >>"$TEAM_HOME/ledger.jsonl"
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" "merge ask: $url at $sha, agent-review success, checks green"
  launched r0000005 brief-review '["browser"]' reviewer
  event merge-default-restored '{scope: "all", discord_message: "1563000000000000047", discord_channel: "1563000000000000012"}'
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks green"
  # A guarded area a review names only from the areas retired since (T276) holds nothing back.
  launched r0000006 brief-review '["browser"]' reviewer
  event review "$(jq -cn --arg h "$sha" '{verdict: "pass", head: $h, guarded: ["settings"],
    findings: {blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0}}')"
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks green"
  assert_equal "$(outside_calls)" ""
}

@test "a pass counting findings that go back prints no merge line: refused until --sent-back sends them, then routed as findings are" {
  local back count
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  echo "# review" >"$wt/.scratch/task/review.md"
  back=${counts/correctness:0/correctness:1}
  back=${back/note-change:0/note-change:2}
  local why="the pass counts 1 correctness and 2 note-change findings, which go back to the builder before the merge (step 5), so there is no merge yet: run it again with --sent-back <their numbers>, and the round goes as a DONE findings' does, through the holder or builder-round"
  refused "$why" T7 -- "T7 DONE pass $url $back before=none guarded=none"
  refused "$why" T7 --sent-back none -- "T7 DONE pass $url $back before=none guarded=none"
  refused "the pass counts 1 security finding, which goes back" T7 -- "T7 DONE pass $url ${counts/security:0/security:1} before=none guarded=none"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 --sent-back 1,2,3 -- "T7 DONE pass $url $back before=none guarded=none"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "review") | {verdict, sent_back}')" '{"verdict":"findings","sent_back":[1,2,3]}'
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 120k): T7 fix findings 1, 2 and 3 in .scratch/task/review.md on the same branch, each as narrowly as it asks (a fix that would reach shapes it does not name is a T7 QUESTION first), then deliver again as your brief says$(ff_step)"
  # No merge line: the fix message's only merge is its ff-only step.
  [[ ${output//git merge --ff-only/} != *merge* ]]
  # The holder's stow launches the round, as after findings.
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-round-1.md"
  assert_equal "$(record round-1 | jq -r .values.findings)" "1, 2 and 3"
  assert_equal "$(outside_calls)" ""
}

@test "a pass's fix message and its round's brief name the same findings file, a tie in mtime broken by name" {
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  echo "# review" >"$wt/.scratch/task/review.md"
  echo "# rereview" >"$wt/.scratch/task/rereview-2.md"
  touch -d 2026-11-01T10:00:00Z "$wt/.scratch/task/review.md" "$wt/.scratch/task/rereview-2.md"
  run_bin -0 --separate-stderr team-next T7 --sent-back 1 -- "T7 DONE pass $url ${counts/correctness:0/correctness:1} before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 120k): T7 fix findings 1 in .scratch/task/rereview-2.md on the same branch, each as narrowly as it asks (a fix that would reach shapes it does not name is a T7 QUESTION first), then deliver again as your brief says$(ff_step)"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$(record round-1 | jq -r .values.findings_file)" .scratch/task/rereview-2.md
}

@test "--ci after a pass: a security or real-data count on any review of the task, or a review with no counts, keeps the merge Daniel's" {
  review_logged findings 0123456 '[1]' '{"security": 1}'
  launched b0000002 brief-round-1 '["browser"]'
  reviewing "$sha"
  pr_on_github "$sha"
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks green; the review of 0123456 at 2026-11-01T10:00:00Z counted 1 security finding, so the default word does not hold"
  # A review that logged no counts, and a real-data one, are named too.
  event review '{verdict: "findings", head: "89abcde", sent_back: [2], guarded: []}'
  review_logged findings fedcba9 '[1]' '{"real-data": 2}'
  launched r0000003 brief-review '["browser"]' reviewer
  passed -- "T7 DONE pass $url $counts before=none guarded=ci"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks green; the review found guarded areas: ci, so the default word does not hold; the review of 0123456 at 2026-11-01T10:00:00Z counted 1 security finding, the review of 89abcde at 2026-11-01T10:00:00Z logged no counts and the review of fedcba9 at 2026-11-01T10:00:00Z counted 2 real-data findings, so the default word does not hold"
  assert_equal "$(outside_calls)" ""
}

@test "--ci after a pass on a PR of the team's own project prints the merge ask, its guarded areas holding back no default word" {
  # proj's repo is the code checkout's origin, so proj is the team's own.
  code_checkout
  git -C "${CODE_CHECKOUT:?}" remote set-url origin git@github.com:owner/proj.git
  reviewing "$sha"
  pr_on_github "$sha"
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" "merge ask: $url at $sha, agent-review success, checks green"
  launched r0000003 brief-review '["browser"]' reviewer
  passed -- "T7 DONE pass $url $counts before=none guarded=guardrails"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks green; the review found guarded areas: guardrails"
  [[ $output != *"default word"* ]]
}

@test "--ci's merge line names a check that no merge waits on when it failed or still runs, and none when it passed" {
  local macos='{"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}, {"name": "rust-macos", "bucket": "BUCKET", "state": "S"}'
  code_checkout
  git -C "${CODE_CHECKOUT:?}" remote set-url origin git@github.com:owner/proj.git
  reviewing "$sha"
  pr_on_github "$sha" 0 "[${macos/BUCKET/fail}]"
  passed -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks green; no merge waits on rust-macos, which failed, so fix it in a task of its own"
  pr_on_github "$sha" 0 "[${macos/BUCKET/pending}]"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" \
    "merge ask: $url at $sha, agent-review success, checks green; no merge waits on rust-macos, which is still running, so read its end later and fix a failure in a task of its own"
  pr_on_github "$sha" 0 "[${macos/BUCKET/pass}]"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "merge ask: $url at $sha, agent-review success, checks green"
}
