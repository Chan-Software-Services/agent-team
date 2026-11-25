#!/usr/bin/env bats
# shellcheck disable=SC2154 # wt, sha, url and counts are helpers/team-next.bash's
# team-next's verdicts: a reviewer's findings verdict goes back to the holding builder as a round,
# with the findings round's look at the reviewed head, the churn line and the fix round's stow, and
# a pass with no PR yet sends the builder on. The sandbox is helpers/team-next's.

load helpers/common
load helpers/github-api
load helpers/team-next

setup() {
  team_next_sandbox
}

# look_red <head>: the findings round's look at <head> ends failed, exit 1, with a roll-up, a
# failed shard of the PR's own, a runner that never started and a lint step of the PR's own, as
# team-ci-wait --json --look gives them; look_own is what a ci logs of the PR's two.
look_red() {
  local job=https://github.com/owner/proj/actions/runs/7/job
  ci_wait_ends failed "$1" 1 "team-ci-wait: the checks on ${1:0:7} did not pass" "$(jq -cn --arg j "$job" '[
    {name: "test", class: "rollup", kind: "rollup", state: "FAILURE", link: "\($j)/9", run: 7, job: 9, step: null, rerun: null},
    {name: "test-shards (2)", class: "pr", kind: "failed", state: "FAILURE", link: "\($j)/8", run: 7, job: 8,
     step: "Run the tests", rerun: null},
    {name: "smoke-shards (1)", class: "infrastructure", kind: "never-started", state: "CANCELLED", link: "\($j)/10", run: 7,
     job: 10, step: null, rerun: "gh run rerun 7 --job 10 --repo owner/proj"},
    {name: "lint", class: "pr", kind: "failed", state: "FAILURE", link: "\($j)/11", run: 7, job: 11, step: "Lint", rerun: null}]')"
}

look_own() {
  local job=https://github.com/owner/proj/actions/runs/7/job
  jq -cn --arg j "$job" '[{name: "test-shards (2)", class: "pr", kind: "failed", link: "\($j)/8", step: "Run the tests"},
    {name: "lint", class: "pr", kind: "failed", link: "\($j)/11", step: "Lint"}]'
}

@test "a pass with no PR yet, a gated project's, tells the holding builder to go on" {
  sed -i 's/^delivery = "direct-pr"/delivery = "no-mistakes"/' "$TEAM_HOME/projects.toml"
  jq -cn --arg h "$sha" '{template: "reviewer", project: "proj", values: {head: $h}}' >"$TEAM_HOME/tasks/T7/brief-review.json"
  launched r0000002 brief-review '[]' reviewer
  live b0000001 90000
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $sha $counts before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 90k): T7 the review of ${sha:0:8} passed: go on with your delivery"
  assert_equal "$(stub_calls gh)" ""
}

@test "a later phase after a merged PR: its review-ready gets the pre-gate re-review naming no PR, and its pass sends the builder on" {
  sed -i 's/^delivery = "direct-pr"/delivery = "no-mistakes"/' "$TEAM_HOME/projects.toml"
  reviewing "$sha"
  review_logged pass "$sha" '[]'
  event 'done' '{role: "reviewer", session: "r0000002"}'
  event merged "$(jq -cn --arg url "$url" --arg h "$sha" '{pr: 9, url: $url, merge: "abc1234", head: $h, approval: "head"}')"
  # GitHub says the first phase's PR is merged, and nothing else may be read of it.
  export GH_HEAD=$sha
  stub_script gh <<'SH'
case "$*" in
  "pr view 9 --repo owner/proj --json number,state,baseRefName,headRefOid,headRefName,changedFiles")
    jq -cn --arg h "$GH_HEAD" '{number: 9, state: "MERGED", baseRefName: "main", headRefOid: $h, headRefName: "feat/T7-toil", changedFiles: 1}' ;;
  "pr checks 9 --repo owner/proj"*) echo '[]' ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
SH
  local later brief
  later=$(commit later.txt "feat: phase 2")
  launched b0000003 brief-deliver-p2 '["browser"]'
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE review-ready $later"
  assert_contains "$output" "launched T7-reviewer"
  local name
  name=$(jq -r 'select(.event == "launch" and .role == "reviewer") | .brief' "$TEAM_HOME/ledger.jsonl" | tail -n 1)
  brief=$(<"$TEAM_HOME/tasks/T7/$name.md")
  assert_contains "$brief" "No PR yet: reviewed at \`$sha\`, now at the local head \`$later\`."
  [[ $brief != *team-review* && $brief != *team-ci-wait* && $brief != */pull/* && $brief != *'{{'* ]]
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $later $counts before=none guarded=none"
  assert_contains "$(tail -n 1 <<<"$output")" "T7 the review of ${later:0:8} passed: go on with your delivery"
}

@test "a findings verdict needs --sent-back, logs it as numbers and routes the findings to the holder under 250k" {
  local count
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  refused "a DONE findings needs --sent-back <list>, the numbers that go back to the builder (none for no fix round)" \
    T7 -- "T7 DONE findings .scratch/task/review.md $counts before=none guarded=none"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,5 -- "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:2} before=none guarded=none"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "review") | {verdict, head, sent_back}')" \
    "$(jq -cn --arg h "$sha" '{verdict: "findings", head: $h, sent_back: [3, 5]}')"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 120k): T7 fix findings 3 and 5 in .scratch/task/review.md on the same branch, each as narrowly as it asks (a fix that would reach shapes it does not name is a T7 QUESTION first), then deliver again as your brief says"
  assert_equal "$(outside_calls)" ""
  assert_equal "$(bg_calls)" ""
}

@test "a findings verdict whose holder is at 250k or more, or gone, prints the STOW to send" {
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 250000
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:1} before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 250k): T7 STOW; its PAUSED stowed goes to team-next, which launches the round"
  live
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:1} before=none guarded=none"
  assert_contains "$output" "already logged review verdict=findings"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "T7-builder b0000001 is gone: recover it (the recover-worker skill), then send it T7 STOW; its PAUSED stowed goes to team-next, which launches the round"
  # Nothing sent back: no round.
  run_bin -0 --separate-stderr team-next T7 --sent-back none -- "T7 DONE findings .scratch/task/review.md ${counts/note-before:0/note-before:1} before=2 guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off: the review sent nothing back, so there is no fix round"
}

@test "a findings round's look names the PR's own failed checks of the reviewed head and their report in the holder's message, logged once, infrastructure and roll-ups left out" {
  local count report=$TEAM_HOME/tasks/T7/ci-${sha:0:8}.md job=https://github.com/owner/proj/actions/runs/7/job
  local message="T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:2} before=none guarded=none"
  code_checkout
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  echo "# review" >"$wt/.scratch/task/review.md"
  look_red "$sha"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,5 -- "$message"
  # One look at the reviewed head, its agent-review left out: the review's own status is no check.
  assert_equal "$(stub_calls team-ci-wait)" "$(jq -cn --arg url "$url" --arg h "$sha" '["--no-agent-review", "--json", "--look", $url, $h]')"
  assert_equal "$(tail -n 3 <<<"$output")" "report $report
logged ci url=$url head=$sha outcome=failed look=true failed=$(look_own)
send to T7-builder (b0000001, 120k): T7 fix findings 3 and 5 in .scratch/task/review.md, and the failed checks test-shards (2) and lint of ${sha:0:8} in $report on the same branch, each as narrowly as it asks (a fix that would reach shapes it does not name is a T7 QUESTION first), then deliver again as your brief says"
  # The ci follows the review, and holds the PR's own failures alone.
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | paste -sd ' ')" "review done ci"
  assert_equal "$(logged_from $((count + 1)) | jq -cS 'select(.event == "ci")')" \
    "$(jq -cnS --arg url "$url" --arg h "$sha" --argjson f "$(look_own)" '{task: "T7", event: "ci", url: $url, head: $h, outcome: "failed", failed: $f, look: true}')"
  assert_equal "$(<"$report")" "# The failed checks of $url at $sha

The findings round's look at the reviewed head found these failures of the PR's own, one a line: each one's class, check, kind, failing step, link and rerun command.

- the PR's: \`test-shards (2)\`, failed, at the step \"Run the tests\", $job/8, no rerun
- the PR's: \`lint\`, failed, at the step \"Lint\", $job/11, no rerun

The PR's failures, \`test-shards (2)\` and \`lint\`, are \`blocking\` findings of this round beside the review's; the look leaves out infrastructure failures and roll-ups, since the round's new head runs every check again."
  assert_equal "$(outside_calls)" ""
  assert_equal "$(bg_calls)" ""
  # A rerun of the message logs nothing twice and prints the same message.
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,5 -- "$message"
  assert_contains "$output" "already logged ci url=$url head=$sha outcome=failed look=true"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "$count"
  assert_contains "$(tail -n 1 <<<"$output")" "T7 fix findings 3 and 5 in .scratch/task/review.md, and the failed checks test-shards (2) and lint of ${sha:0:8} in $report on the same branch"
  # A full holder gets the STOW, and the round's brief names the review's findings and, after
  # them, the failed checks and their report.
  live b0000001 250000
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,5 -- "$message"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 250k): T7 STOW; its PAUSED stowed goes to team-next, which launches the round"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-round-1.md"
  assert_equal "$(record round-1 | jq -c '.values | {findings, findings_file}')" \
    "$(jq -cn --arg r "$report" '{findings: "3 and 5, and the failed checks test-shards (2) and lint in \($r)", findings_file: ".scratch/task/review.md"}')"
  grep -qF "and findings 3 and 5, and the failed checks test-shards (2) and lint in $report in \`.scratch/task/review.md\`." \
    "$TEAM_HOME/tasks/T7/brief-round-1.md"
}

@test "a findings round's look with nothing of the PR's own failed logs nothing and prints today's message; one that cannot be read says so" {
  local message="T7 DONE findings .scratch/task/review.md ${counts/blocking:0/blocking:1} before=none guarded=none"
  local job=https://github.com/owner/proj/actions/runs/7/job end
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  # The real look on the fake GitHub, which has no check of the head: nothing failed.
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "$message"
  assert_equal "$(tail -n 1 <<<"$output")" "$(fix_line 3 .scratch/task/review.md)"
  stub_calls gh | grep -qF '"repos/owner/proj/pulls/9"'
  # Infrastructure failures and roll-ups alone, a pass so far and checks still pending: today's.
  ci_wait_ends failed "$sha" 1 "team-ci-wait: the checks on ${sha:0:7} did not pass" "[$(infra "smoke-shards (1)" never-started 7 10),
    $(rollup smoke 7 12), $(infra build setup 8 20 "Run actions/checkout@v4")]"
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "$message"
  assert_equal "$(tail -n 1 <<<"$output")" "$(fix_line 3 .scratch/task/review.md)"
  for end in passed none pending; do
    ci_wait_ends "$end" "$sha" 0 "team-ci-wait: $end"
    run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "$message"
    assert_equal "$(tail -n 1 <<<"$output")" "$(fix_line 3 .scratch/task/review.md)"
  done
  [[ $output != *report* ]]
  assert_equal "$(jq -c 'select(.event == "ci")' "$TEAM_HOME/ledger.jsonl")" ""
  [[ ! -e $TEAM_HOME/tasks/T7/ci-${sha:0:8}.md ]]
  # A look GitHub cannot read, or whose head moved, adds why, and logs nothing.
  ci_wait_ends unreadable "$sha" 75 "team-ci-wait: GitHub could not be read for owner/proj#9 for 2 minutes: HTTP 502"
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "$message"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(fix_line 3 .scratch/task/review.md); the checks of ${sha:0:8} could not be read (GitHub could not be read for owner/proj#9 for 2 minutes: HTTP 502)"
  ci_wait_ends other-head 0123456789abcdef 1 "team-ci-wait: the head of owner/proj#9 is 0123456, not ${sha:0:7}"
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "$message"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(fix_line 3 .scratch/task/review.md); the checks of ${sha:0:8} could not be read (the head of owner/proj#9 is 0123456, not ${sha:0:7})"
  # A team-ci-wait that prints no object, its first line the reason.
  stub_reply team-ci-wait "usage: team-ci-wait [--no-agent-review] [--json] [--look] <pr url> [<sha>]" 2
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "$message"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(fix_line 3 .scratch/task/review.md); the checks of ${sha:0:8} could not be read (usage: team-ci-wait [--no-agent-review] [--json] [--look] <pr url> [<sha>])"
  assert_equal "$(jq -c 'select(.event == "ci")' "$TEAM_HOME/ledger.jsonl")" ""
  # The STOW of a full holder says it too.
  ci_wait_ends offline "$sha" 75 "team-ci-wait: the team holds offline"
  live b0000001 250000
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- "$message"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 250k): T7 STOW; its PAUSED stowed goes to team-next, which launches the round; the checks of ${sha:0:8} could not be read (the team holds offline)"
}

@test "a pass that sends findings back looks at the reviewed head too, and names the PR's own failed checks" {
  local fix
  fix=$(commit two.txt "fix: findings 1 and 2")
  rereviewing "$fix" '[1, 2]'
  look_red "$fix"
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- \
    "T7 DONE pass $url ${counts/note-change:0/note-change:1} before=none guarded=none"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(fix_line 3 ".scratch/task/rereview-2.md, and the failed checks test-shards (2) and lint of ${fix:0:8} in $TEAM_HOME/tasks/T7/ci-${fix:0:8}.md")"
  assert_equal "$(jq -c 'select(.event == "ci") | [.head, .outcome, .look]' "$TEAM_HOME/ledger.jsonl")" \
    "$(jq -cn --arg h "$fix" '[$h, "failed", true]')"
}

# rereviewing <fix> <earlier sent_back as JSON> [<earlier review's other fields as a jq object>]:
# the PR logged at $sha and an earlier review of it (findings when it sent any back, else a
# pass, counting 2 blocking) with those fields, its widening among them, then the holder's fix
# pushed as <fix> and a rereviewer launched on brief-rereview-2, whose record names <fix>; GitHub
# has the PR at <fix>, the holder b0000001 is live at 120k, and rereview-2.md is the newest
# findings file.
rereviewing() {
  local verdict=findings
  [[ $2 != '[]' ]] || verdict=pass
  event pr "$(jq -cn --arg url "$url" --arg h "$sha" '{url: $url, head: $h}')"
  review_logged "$verdict" "$sha" "$2" '{"blocking": 2}'
  if [[ -n ${3:-} ]]; then
    jq -c "if .event == \"review\" then . + ${3} else . end" "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/ledger"
    cp "$BATS_TEST_TMPDIR/ledger" "$TEAM_HOME/ledger.jsonl"
  fi
  event pr "$(jq -cn --arg url "$url" --arg h "$1" '{url: $url, head: $h}')"
  jq -cn --arg url "$url" --arg h "$1" '{template: "rereview", project: "proj", values: {pr: $url, head: $h}}' \
    >"$TEAM_HOME/tasks/T7/brief-rereview-2.json"
  launched r0000003 brief-rereview-2 '["browser"]' reviewer
  pr_on_github "$1"
  live b0000001 120000
  echo "# rereview" >"$wt/.scratch/task/rereview-2.md"
}

@test "a second review in a row sending back widening findings prints the churn line, carrying the holder's fix, STOW or recover line, logged once and launching nothing" {
  local fix count stow="T7 STOW; its PAUSED stowed goes to team-next, which launches the round"
  fix=$(commit two.txt "fix: findings 1 and 2")
  # The earlier review marked 2 and 4 widening, of which it sent back 2.
  rereviewing "$fix" '[1, 2]' '{widening: [2, 4]}'
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  local message="T7 DONE findings .scratch/task/rereview-2.md ${counts/blocking:0/blocking:2} before=none guarded=none widening=3,4"
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,4 -- "$message"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "review") | {verdict, head, sent_back, widening}')" \
    "$(jq -cn --arg h "$fix" '{verdict: "findings", head: $h, sent_back: [3, 4], widening: [3, 4]}')"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line "3 and 4" "$fix" 2 decide "$(fix_line "3 and 4" .scratch/task/rereview-2.md)")"
  assert_equal "$(bg_calls)" ""
  assert_equal "$(outside_calls)" ""
  # A rerun logs nothing twice and prints the same line, the earlier review still the one before.
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,4 -- "$message"
  assert_contains "$output" "already logged review verdict=findings"
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "$count"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line "3 and 4" "$fix" 2 decide "$(fix_line "3 and 4" .scratch/task/rereview-2.md)")"
  # A holder at 250k gets the STOW, and a gone one is recovered first.
  live b0000001 250000
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,4 -- "$message"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line "3 and 4" "$fix" 2 decide "send to T7-builder (b0000001, 250k): $stow")"
  live
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,4 -- "$message"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line "3 and 4" "$fix" 2 decide "T7-builder b0000001 is gone: recover it (the recover-worker skill), then send it $stow")"
  assert_equal "$(bg_calls)" ""
}

@test "a churn on a review that found guardrails, permissions or secrets says to ask Daniel naming them; any other area says decide" {
  local fix ask
  fix=$(commit two.txt "fix: findings 1 and 2")
  rereviewing "$fix" '[1, 2]' '{widening: [1, 2]}'
  ask="the review found guarded areas guardrails, so ask Daniel with team-ask T7 <an id> --file <the question>"
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- \
    "T7 DONE findings .scratch/task/rereview-2.md ${counts/blocking:0/blocking:1} before=none guarded=ci,guardrails widening=3"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line 3 "$fix" "1 and 2" "$ask" "$(fix_line 3 .scratch/task/rereview-2.md)")"
  ask="the review found guarded areas secrets and permissions, so ask Daniel with team-ask T7 <an id> --file <the question>"
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- \
    "T7 DONE findings .scratch/task/rereview-2.md ${counts/blocking:0/blocking:1} before=none guarded=secrets,deploy,permissions widening=3"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line 3 "$fix" "1 and 2" "$ask" "$(fix_line 3 .scratch/task/rereview-2.md)")"
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- \
    "T7 DONE findings .scratch/task/rereview-2.md ${counts/blocking:0/blocking:1} before=none guarded=ci widening=3"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line 3 "$fix" "1 and 2" decide "$(fix_line 3 .scratch/task/rereview-2.md)")"
}

@test "a widening round after a review that sent back none, a widening one not sent back, or a serious finding outside widening, prints the plain fix line" {
  local fix ledger=$BATS_TEST_TMPDIR/ledger-before earlier
  fix=$(commit two.txt "fix: findings 1 and 2")
  cp "$TEAM_HOME/ledger.jsonl" "$ledger"
  # The earlier review: a first review or a verify with no widening field, a verify that marked
  # none, one whose widening finding it did not send back, and a pass with nothing sent back.
  for earlier in '[1, 2]|{}' '[1, 2]|{widening: []}' '[1, 2]|{widening: [4]}' '[]|{widening: [2]}'; do
    cp "$ledger" "$TEAM_HOME/ledger.jsonl"
    rereviewing "$fix" "${earlier%%|*}" "${earlier#*|}"
    run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- \
      "T7 DONE findings .scratch/task/rereview-2.md ${counts/blocking:0/blocking:1} before=none guarded=none widening=3"
    assert_equal "$(tail -n 1 <<<"$output")" "$(fix_line 3 .scratch/task/rereview-2.md)"
  done
  # After a widening round: this one's widening finding not sent back, and one that counts a
  # blocking finding outside its widening.
  cp "$ledger" "$TEAM_HOME/ledger.jsonl"
  rereviewing "$fix" '[1, 2]' '{widening: [2]}'
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- \
    "T7 DONE findings .scratch/task/rereview-2.md ${counts/blocking:0/blocking:1} before=none guarded=none widening=5"
  assert_equal "$(tail -n 1 <<<"$output")" "$(fix_line 3 .scratch/task/rereview-2.md)"
  cp "$ledger" "$TEAM_HOME/ledger.jsonl"
  rereviewing "$fix" '[1, 2]' '{widening: [2]}'
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,5 -- \
    "T7 DONE findings .scratch/task/rereview-2.md ${counts/blocking:0/blocking:1} before=none guarded=none widening=3"
  assert_equal "$(tail -n 1 <<<"$output")" "$(fix_line "3 and 5" .scratch/task/rereview-2.md)"
  # The same round with its one finding outside widening a plain note, and no serious finding
  # counted, is churn.
  cp "$ledger" "$TEAM_HOME/ledger.jsonl"
  rereviewing "$fix" '[1, 2]' '{widening: [2]}'
  run_bin -0 --separate-stderr team-next T7 --sent-back 3,5 -- \
    "T7 DONE findings .scratch/task/rereview-2.md ${counts/note-change:0/note-change:2} before=none guarded=none widening=3"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line 3 "$fix" 2 decide "$(fix_line "3 and 5" .scratch/task/rereview-2.md)")"
}

@test "a pass that sends back widening findings on the second widening round in a row prints the churn line" {
  local fix
  fix=$(commit two.txt "fix: findings 1 and 2")
  rereviewing "$fix" '[1, 2]' '{widening: [1]}'
  run_bin -0 --separate-stderr team-next T7 --sent-back 3 -- \
    "T7 DONE pass $url ${counts/note-change:0/note-change:1} before=none guarded=none widening=3"
  assert_equal "$(tail -n 1 <<<"$output")" \
    "$(churn_line 3 "$fix" 1 decide "$(fix_line 3 .scratch/task/rereview-2.md)")"
  [[ $output != *merge* ]]
  assert_equal "$(bg_calls)" ""
}

@test "a PAUSED stowed after a findings review launches the round's builder with every fact derived, once" {
  local count
  reviewing "$sha"
  review_logged findings "$sha" '[3, 5]' '{"blocking": 2}'
  event 'done' '{role: "reviewer", session: "r0000002"}'
  echo "# review" >"$wt/.scratch/task/review.md"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$output" "logged paused reason=stowed cause=stow
brief $TEAM_HOME/tasks/T7/brief-round-1.md
launched T7-builder c0000001"
  assert_equal "$(record round-1 | jq -cS .)" "$(jq -cnS --arg url "$url" '{template: "builder-round",
    values: {findings: "3 and 5", findings_file: ".scratch/task/review.md", goal: "Coordinator toil goes to the scripts.", pr: $url}}')"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "launch") | {role, worktree, toolkits, brief}')" \
    "$(jq -cn --arg wt "$wt" '{role: "builder", worktree: $wt, toolkits: ["browser", "spec-review"], brief: "brief-round-1"}')"
  # A second stow after that launch launches nothing.
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$output" "logged paused reason=stowed cause=stow role=builder session=c0000001
no hand-off for PAUSED stowed: no review's sent-back findings or failed checks wait for a round"
  assert_equal "$(bg_calls | wc -l)" 1
}

@test "a PAUSED stowed whose round launch failed finishes on the rerun; one after a pass, or a re-review, launches nothing" {
  reviewing "$sha"
  review_logged findings "$sha" '[3]' '{"blocking": 1}'
  echo "# review" >"$wt/.scratch/task/review.md"
  touch "$STUB_FIXTURES/fail-once"
  run_bin -1 team-next T7 -- "T7 PAUSED stowed"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$output" "already logged paused reason=stowed cause=stow
brief $TEAM_HOME/tasks/T7/brief-round-1.md
launched T7-builder c0000001"
  # The next round's stow after a re-review that had findings takes round-2.
  launched r0000003 brief-rereview-2 '[]' reviewer
  review_logged findings "$sha" '[4]' '{"blocking": 1}'
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-round-2.md"
  # A reviewer launched since the findings review means they were handed on.
  review_logged findings "$sha" '[6]' '{"blocking": 1}'
  launched r0000004 brief-rereview-3 '[]' reviewer
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_contains "$output" "no hand-off for PAUSED stowed"
  # After a pass, nothing.
  review_logged pass "$sha" '[]'
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_contains "$output" "no hand-off for PAUSED stowed"
  # The failed launch, round-1's and round-2's.
  assert_equal "$(bg_calls | wc -l)" 3
}

@test "a PAUSED stowed whose reason goes on after the word stowed is a stow; one that only starts with its letters is not" {
  reviewing "$sha"
  review_logged findings "$sha" '[3]' '{"blocking": 1}'
  echo "# review" >"$wt/.scratch/task/review.md"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowedaway"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off for PAUSED"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed, handoff.md written"
  assert_equal "$output" "logged paused reason=stowed, handoff.md written cause=stow
brief $TEAM_HOME/tasks/T7/brief-round-1.md
launched T7-builder c0000001"
}

@test "team-next never runs team-post, team-merge or Discord, and the manual's steps 5 and 6 name the verdicts and the stow" {
  if grep -En 'sibling team-(post|merge|ask|answer|inbox|thread)|/team-(post|merge|ask|answer|inbox|thread)\b|discord_api|\bcurl\b' \
    "$REPO_ROOT/bin/team-next"; then return 1; fi
  local manual=$REPO_ROOT/roles/coordinator.md
  grep -qF '`team-next` logs a `DONE pass`, refusing a pass whose PR head moved, and says to arm the checks wait, `team-next T<n> --ci`' "$manual"
  grep -qF 'a `DONE findings` with `--sent-back <list>`' "$manual"
  grep -E '^\| `PAUSED stowed` \|.*`team-next`' "$manual"
}
