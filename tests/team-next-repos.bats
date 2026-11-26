#!/usr/bin/env bats
# shellcheck disable=SC2154 # wt, sha, url, counts, url_other and head_other are helpers/team-next.bash's
# team-next with the reviewer App on, whose check it posts after a verdict, and with a task's PRs
# and workers in two repositories, each verdict, round and wait read from its own repository's.
# The sandbox is helpers/team-next's.

load helpers/common
load helpers/github-api
load helpers/team-next

setup() {
  team_next_sandbox
}

# own_app: proj is the team's own project (its repo the code checkout's origin), with the reviewer
# App on and team-review-check the stub, which keeps how many reviews the ledger held when called.
own_app() {
  code_checkout
  git -C "${CODE_CHECKOUT:?}" remote set-url origin git@github.com:owner/proj.git
  review_app_on
  stub_script team-review-check <<'SH'
grep -c '"event":"review"' "$TEAM_HOME/ledger.jsonl" >>"$STUB_FIXTURES/reviews-at-post"
echo 4242
SH
}

@test "a verdict on a PR of the team's own project with the reviewer App on is taken only from the latest reviewer's session, and its check is posted after the log" {
  own_app
  reviewing "$sha"
  pr_on_github "$sha"
  local pass="T7 DONE pass $url $counts before=none guarded=none" reviews
  # No --from, or one naming the builder: refused before anything is logged or posted.
  refused "team-log: the reviewer App posts agent-review on proj, so its verdict is taken only from T7's latest reviewer session, T7-reviewer (r0000002): run it again with --from r0000002 once the message came from that session" \
    T7 -- "$pass"
  refused "team-log: --from b0000001 is not T7's latest reviewer session, T7-reviewer (r0000002)" T7 --from b0000001 -- "$pass"
  assert_equal "$(stub_calls team-review-check)" ""
  # The latest reviewer's: the review is logged, then the App's check posted on the reviewed head.
  reviews=$(grep -c '"event":"review"' "$TEAM_HOME/ledger.jsonl" || true)
  run_bin -0 --separate-stderr team-next T7 --from r0000002 -- "$pass"
  assert_equal "$output" "logged review verdict=pass head=$sha findings={\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note-change\":0,\"note-before\":0} before=[] guarded=[]
logged done role=reviewer session=r0000002
posted agent-review success on ${sha:0:8} as the reviewer App's check run 4242
$(arm_line "$sha")"
  assert_equal "$(stub_calls team-review-check)" "$(jq -cn --arg url "$url" --arg sha "$sha" '[$url, $sha, "success", "T7'"'"'s review of \($sha[:8]) passed"]')"
  assert_equal "$(cat "$STUB_FIXTURES/reviews-at-post")" "$((reviews + 1))"
  assert_equal "$(outside_calls)" ""
  # The manual's review step says so.
  grep -E '^5\. \*\*Review\.\*\*' "$REPO_ROOT/roles/coordinator.md" |
    grep -qF 'which `team-next` runs on a verdict where the App is on, taken only with `--from <the reviewer'"'"'s session id>`'
}

@test "a findings verdict with the reviewer App on posts its check as failure, and a post that fails exits 1 naming the command, the review logged" {
  own_app
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  local findings="T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:2} before=none guarded=none"
  run_bin -0 --separate-stderr team-next T7 --from r0000002 --sent-back 3,5 -- "$findings"
  assert_equal "$(stub_calls team-review-check)" "$(jq -cn --arg url "$url" --arg sha "$sha" '[$url, $sha, "failure", "T7'"'"'s review of \($sha[:8]) found findings"]')"
  assert_contains "$output" "posted agent-review failure on ${sha:0:8} as the reviewer App's check run 4242"
  assert_contains "$(tail -n 1 <<<"$output")" "send to T7-builder (b0000001, 120k): T7 fix findings 3 and 5"

  # A post that fails: exit 1 after the command to run again, the review staying logged.
  launched r0000003 brief-review '["browser"]' reviewer
  stub_script team-review-check <<'SH'
echo "team-review-check: GitHub refused POST /repos/owner/proj/check-runs (HTTP 422)" >&2
exit 1
SH
  local before
  before=$(grep -c '"event":"review"' "$TEAM_HOME/ledger.jsonl")
  run_bin -1 --separate-stderr team-next T7 --from r0000003 --sent-back 3,5 -- "$findings"
  assert_equal "$(grep -c '"event":"review"' "$TEAM_HOME/ledger.jsonl")" "$((before + 1))"
  assert_contains "$stderr" "team-next: T7's review of ${sha:0:8} is logged, but posting the reviewer App's check on it failed: team-review-check: GitHub refused POST /repos/owner/proj/check-runs (HTTP 422)"
  assert_contains "$stderr" "  run: team-review-check $url $sha failure 'T7'\''s review of ${sha:0:8} found findings'"
  assert_contains "$stderr" "  then team-next T7 again for the next step, which logs nothing twice"
  [[ $output != *"send to"* ]]
}

@test "with the reviewer App on, a verdict on the team's own PR needs the latest reviewer's session though that launch names no project" {
  own_app
  reviewing "$sha"
  pr_on_github "$sha"
  event launch "$(jq -cn --arg wt "$wt" '{role: "reviewer", session: "r0000003", worktree: $wt, toolkits: [],
    branch: "feat/T7-toil", machine: "home-pc", brief: "brief-review"}')"
  refused "team-log: the reviewer App posts agent-review on proj, so its verdict is taken only from T7's latest reviewer session, T7-reviewer (r0000003): run it again with --from r0000003 once the message came from that session" \
    T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(stub_calls team-review-check)" ""
}

# other_reviewing: other's PR logged at its head and its reviewer (r0000003) launched on
# brief-review-2, whose record names that head.
other_reviewing() {
  event pr "$(jq -cn --arg url "$url_other" --arg h "$head_other" '{url: $url, head: $h}')"
  jq -cn --arg url "$url_other" --arg h "$head_other" '{template: "reviewer", project: "other", values: {pr: $url, head: $h}}' \
    >"$TEAM_HOME/tasks/T7/brief-review-2.json"
  launched_in other r0000003 brief-review-2 reviewer
}

# two_repos: a PR and a reviewer in each of two repositories, proj's PR 9 at $sha logged and its
# reviewer (r0000002) launched first, other's last, as three reviews ran beside each other in
# three repositories.
two_repos() {
  second_repo
  reviewing "$sha"
  other_reviewing
}

@test "with a PR and a reviewer in each of two repositories, each verdict is taken from its own repository's latest reviewer, the first launched sent last" {
  own_app
  two_repos
  pr_on_github "$sha"
  local pass="T7 DONE pass $url $counts before=none guarded=none"
  local findings="T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:2} before=none guarded=none"
  # other's verdict comes first, from the task's latest reviewer launch.
  run_bin -0 team-log T7 --from-message "$findings" --from r0000003 --sent-back 1,2
  # proj's pass, from the reviewer launched first, is taken: it is proj's latest reviewer, the
  # review is of proj's head, and the App's check is posted on proj's PR, not other's.
  run_bin -0 --separate-stderr team-next T7 --from r0000002 -- "$pass"
  assert_equal "$output" "logged review verdict=pass head=$sha findings={\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note-change\":0,\"note-before\":0} before=[] guarded=[]
logged done role=reviewer session=r0000002
posted agent-review success on ${sha:0:8} as the reviewer App's check run 4242
$(arm_line "$sha")"
  assert_equal "$(stub_calls team-review-check)" "$(jq -cn --arg url "$url" --arg sha "$sha" '[$url, $sha, "success", "T7'"'"'s review of \($sha[:8]) passed"]')"
  assert_equal "$(outside_calls)" ""
}

# both_on_github: gh answers team-state's reads of proj's PR 9 at $sha and of other's PR 4 at
# $head_other, each open on its task branch with no check.
both_on_github() {
  export GH_HEAD=$sha GH_HEAD_OTHER=$head_other
  stub_script gh <<'SH'
case "$*" in
  *owner/other*) repo=owner/other n=4 head=$GH_HEAD_OTHER ;;
  *) repo=owner/proj n=9 head=$GH_HEAD ;;
esac
case "$*" in
  "pr view $n --repo $repo --json number,state,baseRefName,headRefOid,headRefName,changedFiles")
    jq -cn --arg h "$head" --argjson n "$n" '{number: $n, state: "OPEN", baseRefName: "main", headRefOid: $h,
      headRefName: "feat/T7-toil", changedFiles: 1}' ;;
  "pr checks $n --repo $repo"*) echo '[]' ;;
  "api repos/$repo/compare/main...$head --jq .behind_by") echo 0 ;;
  "api repos/$repo/pulls/$n/files --paginate") echo '[{"filename": "one.txt"}]' ;;
  "api repos/$repo/commits/$head/check-runs?check_name=agent-review&filter=latest&per_page=100")
    echo '{"total_count": 0, "check_runs": []}' ;;
  "api repos/$repo/commits/$head/status") echo '{"state": "pending", "statuses": []}' ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
SH
}

@test "with reviewers in two repositories, the other repository's findings go to its own builder on its own PR, and post no check" {
  own_app
  two_repos
  both_on_github
  ci_wait_ends passed "$head_other"
  live b0000001 120000 b0000002 80000
  local findings="T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:2} before=none guarded=none"
  run_bin -0 --separate-stderr team-next T7 --from r0000003 --sent-back 1,2 -- "$findings"
  assert_contains "$output" "logged review verdict=findings head=$head_other"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000002, 80k): T7 fix findings 1 and 2 in .scratch/task/review.md on the same branch, each as narrowly as it asks (a fix that would reach shapes it does not name is a T7 QUESTION first), then deliver again as your brief says"
  # The look at the checks was other's PR's, at the head its review read, and the App posts nothing there.
  assert_equal "$(stub_calls team-ci-wait)" "$(jq -cn --arg url "$url_other" --arg h "$head_other" '["--no-agent-review", "--json", "--look", $url, $h]')"
  assert_equal "$(stub_calls team-review-check)" ""
  assert_equal "$(outside_calls)" ""
}

@test "--ci after a pass in one of two repositories waits on that repository's PR and prints its merge ask, the other's pr logged last and its findings first" {
  own_app
  two_repos
  pr_on_github "$sha"
  run_bin -0 team-log T7 --from-message "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:2} before=none guarded=none" \
    --from r0000003 --sent-back 1,2
  passed --from r0000002 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$output" "logged ci url=$url head=$sha outcome=passed"
  assert_contains "$(tail -n 1 <<<"$output")" "merge ask: $url at $sha, "
  assert_equal "$(stub_calls team-ci-wait | tail -n 1)" "$(jq -cn --arg url "$url" --arg h "$sha" '["--no-agent-review", "--json", $url, $h]')"
  assert_equal "$(outside_calls)" ""
}

@test "--ci still waits on a passed PR's checks once another repository's findings are logged after the pass" {
  own_app
  two_repos
  pr_on_github "$sha"
  ci_wait_ends passed "$sha"
  run_bin -0 --separate-stderr team-next T7 --from r0000002 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" "$(arm_line "$sha")"
  run_bin -0 team-log T7 --from-message "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:2} before=none guarded=none" \
    --from r0000003 --sent-back 1,2
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_contains "$output" "logged ci url=$url head=$sha outcome=passed"
  assert_contains "$(tail -n 1 <<<"$output")" "merge ask: $url at $sha, "
  # The state names the same wait, passed now.
  run_bin -0 --separate-stderr team-state T7 --json
  assert_equal "$(jq -c '.checks_wait | {url, head, state}' <<<"$output")" \
    "$(jq -cn --arg url "$url" --arg h "$sha" '{url: $url, head: $h, state: "passed"}')"
}

@test "--ci waits on a pass in one repository though another repository's checks failed and went back as a round before it" {
  own_app
  two_repos
  both_on_github
  live b0000001 120000 b0000002 80000
  # proj's pass, whose checks fail on a failure of the PR's own: the round goes back to proj's builder.
  run_bin -0 --separate-stderr team-next T7 --from r0000002 -- "T7 DONE pass $url $counts before=none guarded=none"
  red_checks "$sha"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_contains "$output" "logged ci url=$url head=$sha outcome=failed"
  # other's pass, logged after it, has its own wait.
  run_bin -0 --separate-stderr team-next T7 --from r0000003 -- "T7 DONE pass $url_other $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" "$(url=$url_other arm_line "$head_other")"
  run_bin -0 --separate-stderr team-state T7 --json
  assert_equal "$(jq -c '.checks_wait | {url, head, state}' <<<"$output")" \
    "$(jq -cn --arg url "$url_other" --arg h "$head_other" '{url: $url, head: $h, state: "waiting"}')"
  ci_wait_ends passed "$head_other"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_contains "$output" "logged ci url=$url_other head=$head_other outcome=passed"
  assert_contains "$(tail -n 1 <<<"$output")" "merge on the default word: run team-merge T7 --pr $url_other for $url_other at $head_other, "
  assert_equal "$(stub_calls team-ci-wait | tail -n 1)" \
    "$(jq -cn --arg url "$url_other" --arg h "$head_other" '["--no-agent-review", "--json", $url, $h]')"
  # The passed wait stands before the failed one, which only its own repository's next review ends.
  run_bin -0 --separate-stderr team-state T7 --json
  assert_equal "$(jq -c '.checks_wait | {url, head, state}' <<<"$output")" \
    "$(jq -cn --arg url "$url_other" --arg h "$head_other" '{url: $url, head: $h, state: "passed"}')"
}

@test "--ci waits on a pass in one repository though another repository's wait ended blocked on infrastructure before it" {
  own_app
  two_repos
  both_on_github
  # proj's pass, whose wait ends blocked: a check queued with no runner, which is never rerun.
  run_bin -0 --separate-stderr team-next T7 --from r0000002 -- "T7 DONE pass $url $counts before=none guarded=none"
  ci_wait_ends failed "$sha" 1 "team-ci-wait: the checks on ${sha:0:7} did not pass" "$(infra build queued 5 50 | jq -sc .)"
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_contains "$output" "logged ci url=$url head=$sha outcome=infrastructure"
  assert_contains "$(tail -n 1 <<<"$output")" "blocked: the checks build of $url at ${sha:0:8} failed as infrastructure with no runner for 20 minutes"
  # other's pass, logged after it, has its own wait, ahead of the blocked one.
  run_bin -0 --separate-stderr team-next T7 --from r0000003 -- "T7 DONE pass $url_other $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" "$(url=$url_other arm_line "$head_other")"
  run_bin -0 --separate-stderr team-state T7 --json
  assert_equal "$(jq -c '.checks_wait | {url, head, state}' <<<"$output")" \
    "$(jq -cn --arg url "$url_other" --arg h "$head_other" '{url: $url, head: $h, state: "waiting"}')"
  ci_wait_ends passed "$head_other"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_contains "$output" "logged ci url=$url_other head=$head_other outcome=passed"
  assert_contains "$(tail -n 1 <<<"$output")" "merge on the default word: run team-merge T7 --pr $url_other for $url_other at $head_other, "
  assert_equal "$(stub_calls team-ci-wait | tail -n 1)" \
    "$(jq -cn --arg url "$url_other" --arg h "$head_other" '["--no-agent-review", "--json", $url, $h]')"
  # With nothing else waiting, the blocked wait is the task's again, ahead of the passed one.
  run_bin -0 --separate-stderr team-state T7 --json
  assert_equal "$(jq -c '.checks_wait | {url, head, state}' <<<"$output")" \
    "$(jq -cn --arg url "$url" --arg h "$sha" '{url: $url, head: $h, state: "infrastructure"}')"
}

@test "--ci's passed end, with a pass in each of two repositories, ends on the arm line of the other repository's wait" {
  own_app
  two_repos
  both_on_github
  run_bin -0 --separate-stderr team-next T7 --from r0000002 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" "$(arm_line "$sha")"
  run_bin -0 --separate-stderr team-next T7 --from r0000003 -- "T7 DONE pass $url_other $counts before=none guarded=none"
  # The wait is the first pass's, and its end names the wait that stands after it.
  ci_wait_ends passed "$sha"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_contains "$output" "logged ci url=$url head=$sha outcome=passed"
  assert_contains "$output" "merge ask: $url at $sha, "
  assert_equal "$(tail -n 1 <<<"$output")" "$(url=$url_other arm_line "$head_other")"
  # The other's wait, armed as that line says, ends on its merge ask alone: no wait is left to arm.
  ci_wait_ends passed "$head_other"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_contains "$output" "logged ci url=$url_other head=$head_other outcome=passed"
  assert_contains "$(tail -n 1 <<<"$output")" "merge on the default word: run team-merge T7 --pr $url_other for $url_other at $head_other, "
}

@test "with reviewers in two repositories, a verdict from a session that is not its own repository's latest reviewer is still refused" {
  own_app
  two_repos
  pr_on_github "$sha"
  local pass="T7 DONE pass $url $counts before=none guarded=none"
  local needs="the reviewer App posts agent-review on proj, so its verdict is taken only from T7's latest reviewer session in proj, T7-reviewer (r0000002)"
  # No --from, the other repository's reviewer, the builder or the role's name: refused.
  refused "team-log: $needs: run it again with --from r0000002 once the message came from that session" T7 -- "$pass"
  local from
  for from in r0000003 b0000001 T7-reviewer; do
    refused "team-log: --from $from is not T7's latest reviewer session in proj, T7-reviewer (r0000002)" T7 --from "$from" -- "$pass"
  done
  # A later reviewer in proj makes the first one's verdict stale, whatever other's reviewers do.
  launched r0000004 brief-review '["browser"]' reviewer
  launched_in other r0000005 brief-review-2 reviewer
  refused "team-log: --from r0000002 is not T7's latest reviewer session in proj, T7-reviewer (r0000004)" T7 --from r0000002 -- "$pass"
  # A findings verdict names no PR: its project is its sender's launch's, so proj's needs proj's
  # latest reviewer, and other's, which the App posts nothing for, is taken from other's.
  local findings="T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:2} before=none guarded=none"
  refused "team-log: --from r0000002 is not T7's latest reviewer session in proj, T7-reviewer (r0000004)" \
    T7 --from r0000002 --sent-back 1 -- "$findings"
  assert_equal "$(stub_calls team-review-check)" ""
}

@test "a PR's review hand-off reads only its own repository's reviews: a first review though another repository's is logged, then a rereview of its own" {
  second_repo
  # other's PR was reviewed, with findings sent back, before proj's builder sent its PR.
  other_reviewing
  review_logged findings "$head_other" '[1]' '{"blocking": 1}'
  event 'done' '{role: "reviewer", session: "r0000003"}'
  on_github 9 "$sha"
  refused "T7 has no review yet, so its first reviewer needs --checks <file>, the review's checks" T7 -- "T7 PR $url"
  run_bin -0 --separate-stderr team-next T7 --checks "$(checks)" -- "T7 PR $url"
  assert_equal "$output" "logged pr url=$url head=$sha
brief $TEAM_HOME/tasks/T7/brief-review.md
launched T7-reviewer c0000001"
  assert_equal "$(record review | jq -c '{template, pr: .values.pr, head: .values.head}')" \
    "$(jq -cn --arg url "$url" --arg h "$sha" '{template: "reviewer", pr: $url, head: $h}')"
  # proj's own review sent a finding back: its next PR is a rereview of the head proj's review
  # read, not of other's.
  run_bin -0 team-log T7 --from-message "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:1} before=none guarded=none" \
    --from c0000001 --sent-back 1
  local fix
  fix=$(commit two.txt "fix: finding 1")
  on_github 9 "$fix"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PR $url"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-rereview-2.md"
  assert_equal "$(record rereview-2 | jq -c '{template, pr: .values.pr, head: .values.head, reviewed: .values.reviewed}')" \
    "$(jq -cn --arg url "$url" --arg h "$fix" --arg r "$sha" '{template: "rereview", pr: $url, head: $h, reviewed: $r}')"
}

@test "a merged part in one repository ends that repository's phase alone: the other's PR reported again is re-reviewed from its own reviewed head" {
  second_repo
  # proj's PR 9 passed in proj, then other's PR merged with phase 2 left.
  reviewing "$sha"
  review_logged pass "$sha" '[]'
  event 'done' '{role: "reviewer", session: "r0000002"}'
  other_reviewing
  review_logged pass "$head_other" '[]'
  event 'done' '{role: "reviewer", session: "r0000003"}'
  event merged "$(jq -cn --arg url "$url_other" --arg h "$head_other" \
    '{pr: 4, merge: "m0", head: $h, by: "team-merge", project: "other", url: $url, phases_left: [2]}')"
  # A round fixed a red check on proj's PR, which its builder reports again.
  local fix
  fix=$(commit fix.txt "test: wait for the hand-out")
  on_github 9 "$fix"
  refused "T7 has a review already, so --checks is for its first reviewer only; a rereview takes --since" \
    T7 --checks "$(checks)" -- "T7 PR $url"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PR $url"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-rereview-2.md"
  assert_equal "$(record rereview-2 | jq -c '{template, pr: .values.pr, head: .values.head, reviewed: .values.reviewed}')" \
    "$(jq -cn --arg url "$url" --arg h "$fix" --arg r "$sha" '{template: "rereview", pr: $url, head: $h, reviewed: $r}')"

  # other's own merged part did end its phase: its phase 2 PR is a first review, its phase 1
  # review no longer standing.
  local url_next=https://github.com/owner/other/pull/5 next
  next=$(git -C "${wt_other:?}" commit -q --allow-empty -m "feat: phase 2" && git -C "${wt_other:?}" rev-parse HEAD)
  export NEXT_HEAD=$next
  stub_script gh <<'SH'
[[ $1 == pr && $2 == view && $3 == 5 && $4 == --repo && $5 == owner/other ]] || { echo "unexpected gh $*" >&2; exit 1; }
jq -cn --arg head "$NEXT_HEAD" '{headRefOid: $head, headRefName: "feat/T7-toil"}'
SH
  refused "T7 has no review since its phase merged at 2026-11-01T10:00:00Z, so its first reviewer needs --checks <file>, the review's checks" \
    T7 -- "T7 PR $url_next"
}

@test "a gated project's PR with no review in its phase is a first review of that PR, which comments on it and sets its status" {
  sed -i 's/^delivery = "direct-pr"/delivery = "no-mistakes"/' "$TEAM_HOME/projects.toml"
  on_github 9 "$sha"
  refused "T7 has no review yet, so its first reviewer needs --checks <file>, the review's checks" T7 -- "T7 PR $url"
  run_bin -0 --separate-stderr team-next T7 --checks "$(checks)" -- "T7 PR $url"
  assert_equal "$output" "logged pr url=$url head=$sha
brief $TEAM_HOME/tasks/T7/brief-review.md
launched T7-reviewer c0000001"
  assert_equal "$(record review | jq -c '{template, pr: .values.pr, head: .values.head}')" \
    "$(jq -cn --arg url "$url" --arg h "$sha" '{template: "reviewer", pr: $url, head: $h}')"
  local brief
  brief=$(<"$TEAM_HOME/tasks/T7/brief-review.md")
  assert_contains "$brief" "/team-review-comment $url .scratch/task/review.md"
  assert_contains "$brief" "/team-review-status $url $sha <success|failure>"
  assert_contains "$brief" "- Send \`T7 DONE pass $url findings="
  [[ $brief != *"There is no PR yet"* && $brief != *"Post nothing to GitHub"* ]]
}

# reviewed_in <session> <verdict> <head> <sent_back as JSON> [<more review fields as JSON>]: a review
# of <head> and its reviewer's done, so the review is of the project of <session>'s launch.
reviewed_in() {
  local more=${5:-'{}'}
  event review "$(jq -cn --arg v "$2" --arg h "$3" --argjson s "$4" --argjson more "$more" '{verdict: $v, head: $h, sent_back: $s,
    findings: {blocking: ($s | length), correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0},
    before: [], guarded: []} + $more')"
  event 'done' "$(jq -cn --arg s "$1" '{role: "reviewer", session: $s}')"
}

@test "with builders in two repositories, a PAUSED stowed launches the round of the stowed builder's own repository, whatever the other's reviews and launches log" {
  two_repos
  mkdir -p "$wt_other/.scratch/task"
  echo "# review" >"$wt/.scratch/task/review.md"
  echo "# review" >"$wt_other/.scratch/task/review.md"
  # proj's review sent findings back; other's reviewer, launched after it, takes none of them.
  reviewed_in r0000002 findings "$sha" '[1, 2]'
  launched_in other r0000004 brief-review-3 reviewer
  run_bin -0 --separate-stderr team-next T7 --from b0000001 -- "T7 PAUSED stowed"
  assert_equal "$output" "logged paused reason=stowed cause=stow role=builder session=b0000001
brief $TEAM_HOME/tasks/T7/brief-round-1.md
launched T7-builder c0000001"
  assert_equal "$(record round-1 | jq -c '.values | {findings, findings_file, pr}')" \
    "$(jq -cn --arg url "$url" '{findings: "1 and 2", findings_file: ".scratch/task/review.md", pr: $url}')"
  # The round runs in proj's worktree with proj's builder's toolkits, not other's latest builder's.
  assert_equal "$(jq -c 'select(.event == "launch" and .session == "c0000001") | {project, worktree, toolkits}' "$TEAM_HOME/ledger.jsonl")" \
    "$(jq -cn --arg wt "$wt" '{project: "proj", worktree: $wt, toolkits: ["browser", "spec-review"]}')"
  # other's builder stowing has no round: other's review is not logged yet.
  run_bin -0 --separate-stderr team-next T7 --from b0000002 -- "T7 PAUSED stowed"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off for PAUSED stowed: no review's sent-back findings or failed checks wait for a round"
  # other's findings, logged after proj's round launched, go to other's builder's stow alone, and
  # proj's next stow after its round launched has none.
  reviewed_in r0000004 findings "$head_other" '[3]'
  run_bin -0 --separate-stderr team-next T7 --from c0000001 -- "T7 PAUSED stowed"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off for PAUSED stowed: no review's sent-back findings or failed checks wait for a round"
  run_bin -0 --separate-stderr team-next T7 --from b0000002 -- "T7 PAUSED stowed"
  assert_equal "$(tail -n 2 <<<"$output")" "brief $TEAM_HOME/tasks/T7/brief-round-2.md
launched T7-builder c0000002"
  assert_equal "$(record round-2 | jq -c '.values | {findings, findings_file, pr}')" \
    "$(jq -cn --arg url "$url_other" '{findings: "3", findings_file: ".scratch/task/review.md", pr: $url}')"
  assert_equal "$(jq -c 'select(.event == "launch" and .session == "c0000002") | {project, worktree, toolkits}' "$TEAM_HOME/ledger.jsonl")" \
    "$(jq -cn --arg wt "$wt_other" '{project: "other", worktree: $wt, toolkits: ["spec-review"]}')"
  assert_equal "$(bg_calls | wc -l)" 2
}

@test "with builders in two repositories, a stow's round waits on its own repository's pass whose checks failed, past another repository's pass logged after" {
  two_repos
  reviewed_in r0000002 pass "$sha" '[]'
  event ci "$(jq -cn --arg url "$url" --arg h "$sha" '{url: $url, head: $h, outcome: "failed",
    failed: [{name: "lint", class: "pr", kind: "failure", link: "https://example.com/lint", step: "lint"}]}')"
  echo "# the failed checks" >"$TEAM_HOME/tasks/T7/ci-${sha:0:8}.md"
  reviewed_in r0000003 pass "$head_other" '[]'
  # other's builder has no round: other's pass has no failed checks.
  run_bin -0 --separate-stderr team-next T7 --from b0000002 -- "T7 PAUSED stowed"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off for PAUSED stowed: no review's sent-back findings or failed checks wait for a round"
  run_bin -0 --separate-stderr team-next T7 --from b0000001 -- "T7 PAUSED stowed"
  assert_equal "$(tail -n 2 <<<"$output")" "brief $TEAM_HOME/tasks/T7/brief-round-1.md
launched T7-builder c0000001"
  assert_equal "$(record round-1 | jq -r '.values.findings')" "the failed checks lint of ${sha:0:8}"
  assert_equal "$(jq -c 'select(.event == "launch" and .session == "c0000001") | {project, worktree}' "$TEAM_HOME/ledger.jsonl")" \
    "$(jq -cn --arg wt "$wt" '{project: "proj", worktree: $wt}')"
}

@test "the churn rule reads the previous review of the review's own repository, past another repository's logged between" {
  local fix
  two_repos
  # proj's review sent back finding 2, which it marked widening; other's, logged after it, sent
  # back one it did not.
  reviewed_in r0000002 findings "$sha" '[1, 2]' '{"widening": [2]}'
  reviewed_in r0000003 findings "$head_other" '[1]'
  fix=$(commit two.txt "fix: findings 1 and 2")
  event pr "$(jq -cn --arg url "$url" --arg h "$fix" '{url: $url, head: $h}')"
  jq -cn --arg url "$url" --arg h "$fix" '{template: "rereview", project: "proj", values: {pr: $url, head: $h}}' \
    >"$TEAM_HOME/tasks/T7/brief-rereview-2.json"
  launched r0000004 brief-rereview-2 '["browser"]' reviewer
  pr_on_github "$fix"
  live b0000001 120000
  echo "# rereview" >"$wt/.scratch/task/rereview-2.md"
  run_bin -0 --separate-stderr team-next T7 --from r0000004 --sent-back 3 -- \
    "T7 DONE findings .scratch/task/rereview-2.md ${counts/blocking:0/blocking:1} before=none guarded=none widening=3"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line 3 "$fix" 2 decide "$(fix_line 3 .scratch/task/rereview-2.md)")"
  assert_equal "$(bg_calls)" ""
}

@test "a PR's review hand-off is already handed off by its own repository's reviewer alone: another's launch leaves a failed one to finish, and another's review hands it on to no second reviewer" {
  second_repo
  on_github 9 "$sha"
  # proj's PR is logged and its reviewer's launch fails; other's reviewer launches after it.
  touch "$STUB_FIXTURES/fail-once"
  run_bin -1 team-next T7 --from b0000001 --checks "$(checks)" -- "T7 PR $url"
  other_reviewing
  run_bin -0 --separate-stderr team-next T7 --from b0000001 --checks "$(checks)" -- "T7 PR $url"
  assert_equal "$(tail -n 2 <<<"$output")" "brief $TEAM_HOME/tasks/T7/brief-review.md
launched T7-reviewer c0000001"
  # other's review and its done, logged after proj's reviewer launched, review nothing of proj's.
  reviewed_in r0000003 findings "$head_other" '[1]'
  refused "PR is already handed off: T7-reviewer c0000001 was launched at" T7 --from b0000001 -- "T7 PR $url"
  assert_equal "$(bg_calls | wc -l)" 2
}

@test "a PR's rerun after another repository's launch logs its pr once: the rerun's anchor is the latest launch in the PR's own repository" {
  second_repo
  on_github 9 "$sha"
  # proj's PR is logged and its reviewer's launch fails; other's reviewer launches after it.
  touch "$STUB_FIXTURES/fail-once"
  run_bin -1 team-next T7 --from b0000001 --checks "$(checks)" -- "T7 PR $url"
  other_reviewing
  run_bin -0 --separate-stderr team-next T7 --from b0000001 --checks "$(checks)" -- "T7 PR $url"
  assert_contains "$output" "already logged pr url=$url head=$sha"
  assert_equal "$(jq -c --arg url "$url" --arg h "$sha" 'select(.event == "pr" and .url == $url and .head == $h) | .head' \
    "$TEAM_HOME/ledger.jsonl")" "\"$sha\""
}

@test "a QUESTION's or an INJECTION's rerun after another repository's launch logs it once: the rerun's anchor is the latest launch in its sender's repository" {
  second_repo
  run_bin -0 team-next T7 --from b0000001 -- "T7 QUESTION which way? | options: a, b"
  run_bin -0 team-next T7 --from b0000001 -- "T7 INJECTION README.md asked to push to main"
  launched_in other r0000009 brief-review-2 reviewer
  run_bin -0 team-next T7 --from b0000001 -- "T7 QUESTION which way? | options: a, b"
  assert_equal "$output" "already logged question role=builder text=which way? | options: a, b
no hand-off for QUESTION"
  run_bin -0 team-next T7 --from b0000001 -- "T7 INJECTION README.md asked to push to main"
  assert_equal "$(head -n 1 <<<"$output")" "already logged injection role=builder source=README.md text=asked to push to main"
  assert_equal "$(jq -r 'select(.event == "question" or .event == "injection") | .event' "$TEAM_HOME/ledger.jsonl" | tr '\n' ' ')" \
    "question injection "
}

@test "a ticket's launch that failed finishes on the rerun though another repository's reviewer launched since" {
  ticket 04-fourth "Blocked by: 01"
  second_repo
  touch "$STUB_FIXTURES/fail-once"
  run_bin -1 team-next T7 --from b0000001 -- "T7 DONE 01 $sha done"
  launched_in other r0000009 brief-review-2 reviewer
  run_bin -0 --separate-stderr team-next T7 --from b0000001 -- "T7 DONE 01 $sha done"
  assert_equal "$(tail -n 1 <<<"$output")" "launched T7-builder c0000001"
  refused "ticket 01 is already handed off: T7-builder c0000001 was launched at" T7 --from b0000001 -- "T7 DONE 01 $sha done"
}

@test "with the reviewer App on, a review logged on a short head posts no check on the PR's full head" {
  own_app
  reviewing "${sha:0:7}"
  pr_on_github "$sha"
  run_bin -0 --separate-stderr team-next T7 --from r0000002 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_equal "$(stub_calls team-review-check)" ""
  assert_contains "$output" "posted no agent-review: T7's review names its head ${sha:0:7} by a prefix, not in full, so the reviewer App's check is not posted on the PR's head ${sha:0:8}; a review whose brief records the full head posts it"
}

@test "with the reviewer App on, a check posted whose token was not revoked is said as posted, and the step goes on" {
  own_app
  reviewing "$sha"
  pr_on_github "$sha"
  stub_script team-review-check <<'SH'
echo 4242
echo "team-review-check: revoking the App's token failed: GitHub answered HTTP 500: Server Error; it expires on its own within the hour" >&2
exit 1
SH
  run_bin -0 --separate-stderr team-next T7 --from r0000002 -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$output" "posted agent-review success on ${sha:0:8} as the reviewer App's check run 4242, but revoking the App's token failed: GitHub answered HTTP 500: Server Error; it expires on its own within the hour"
  assert_equal "$(tail -n 1 <<<"$output")" "$(arm_line "$sha")"
}

@test "a findings verdict on a head the PR moved past posts no check with the reviewer App on, and says so" {
  own_app
  # The findings round's look at the reviewed head sees the PR's head moved, and keeps its grace for
  # a push through the stub sleep's looks, not two minutes of the real clock.
  looks_counted
  reviewing "$sha"
  local moved
  moved=$(commit two.txt "feat: after the review")
  pr_on_github "$moved"
  live b0000001 120000
  run_bin -0 --separate-stderr team-next T7 --from r0000002 --sent-back 1 -- \
    "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:1} before=none guarded=none"
  assert_equal "$(stub_calls team-review-check)" ""
  assert_contains "$output" "posted no agent-review: the PR's head ${moved:0:8} moved past the reviewed head ${sha:0:8}, whose check would not count"
  assert_contains "$(tail -n 1 <<<"$output")" "send to T7-builder (b0000001, 120k): T7 fix findings 1"
}
