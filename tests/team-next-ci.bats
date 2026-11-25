#!/usr/bin/env bats
# shellcheck disable=SC2154 # sha, url and counts are helpers/team-next.bash's
# team-next's checks wait: a reviewer's pass ends on the arm line, and team-next T7 --ci waits on
# the PR's checks through the team-ci-wait stub (ci_wait_ends), reruns infrastructure, hands a red
# check back as a round, and is refused or stopped where a wait does not fit. What a passed wait
# prints is tests/team-next-merge.bats'. The sandbox is helpers/team-next's.

load helpers/common
load helpers/github-api
load helpers/team-next

setup() {
  team_next_sandbox
}

# The failures red_checks logs on its ci: each one's name, class, kind, link and step.
red_logged() {
  jq -c '.failures | map({name, class, kind, link, step})' "$STUB_FIXTURES/team-ci-wait.out"
}

# ci_fix <who> <head>: the fix message --ci prints to the holder <who> for red_checks on <head>.
ci_fix() {
  echo "send to $1: T7 fix the failed checks test-shards (2), build and lint of ${2:0:8} in $TEAM_HOME/tasks/T7/ci-${2:0:8}.md on the same branch, each as narrowly as it asks (a fix that would reach shapes it does not name is a T7 QUESTION first), then deliver again as your brief says"
}

# ci_ends <end>...: the team-ci-wait stub answers its calls with these ends of $sha in turn, the
# last one again after them: passed, unreadable, or a failed end's failures, one JSON object per
# line (infra, rollup); ci_waits counts its calls.
ci_ends() {
  local k=0 end
  rm -f "$STUB_FIXTURES"/ci-end-*
  for end; do
    k=$((k + 1))
    case $end in
      passed) ci_wait_ends passed "$sha" ;;
      unreadable) ci_wait_ends unreadable "$sha" 75 "team-ci-wait: GitHub not read for now" ;;
      *) ci_wait_ends failed "$sha" 1 "team-ci-wait: the checks on ${sha:0:7} did not pass, end $k" "$(jq -sc . <<<"$end")" ;;
    esac
    mv "$STUB_FIXTURES/team-ci-wait.out" "$STUB_FIXTURES/ci-end-$k.out"
    mv "$STUB_FIXTURES/team-ci-wait.status" "$STUB_FIXTURES/ci-end-$k.status"
  done
  stub_script team-ci-wait <<'SH'
n=$(($(cat "$STUB_FIXTURES/ci-end-n" 2>/dev/null || echo 0) + 1))
[[ -f $STUB_FIXTURES/ci-end-$n.out ]] || n=$((n - 1))
echo "$n" >"$STUB_FIXTURES/ci-end-n"
print_file "$STUB_FIXTURES/ci-end-$n.out"
exit "$(<"$STUB_FIXTURES/ci-end-$n.status")"
SH
}

ci_waits() {
  stub_calls team-ci-wait | wc -l
}

# reruns_on_github <pr_on_github arguments>...: pr_on_github's gh, which also answers gh run rerun
# and the reads of a run (gh api repos/owner/proj/actions/runs/<run>): a run is at attempt 1,
# completed, until a rerun takes it to the next attempt, queued; with $STUB_FIXTURES/rerun-refused
# a rerun prints its text and exits 1, and with $STUB_FIXTURES/rerun-stays a rerun moves nothing.
reruns_on_github() {
  pr_on_github "$@"
  mv "$STUB_FIXTURES/gh.sh" "$STUB_FIXTURES/gh-pr.sh"
  stub_script gh <<'SH'
case "$*" in
  "run rerun "*)
    if [[ -f $STUB_FIXTURES/rerun-refused ]]; then print_file "$STUB_FIXTURES/rerun-refused" >&2; exit 1; fi
    if [[ ! -f $STUB_FIXTURES/rerun-stays ]]; then
      echo $(($(cat "$STUB_FIXTURES/attempt-$3" 2>/dev/null || echo 1) + 1)) >"$STUB_FIXTURES/attempt-$3"
    fi ;;
  "api repos/owner/proj/actions/runs/"*)
    run=${2##*/}
    jq -cn --argjson r "$run" --argjson a "$(cat "$STUB_FIXTURES/attempt-$run" 2>/dev/null || echo 1)" \
      '{id: $r, run_attempt: $a, status: (if $a > 1 then "queued" else "completed" end)}' ;;
  *) source "$STUB_FIXTURES/gh-pr.sh" ;;
esac
SH
}

# during_wait <event> <its fields as a jq object>: the team-ci-wait stub that ci_ends set logs that
# event of T7, as event does, at its first call, before it answers, as a hold, an ask or a review
# logged while --ci waits.
during_wait() {
  mv "$STUB_FIXTURES/team-ci-wait.sh" "$STUB_FIXTURES/ci-ends.sh"
  jq -cn --arg event "$1" "{ts: \"2026-11-01T10:00:00Z\", task: \"T7\", event: \$event} + $2" >"$STUB_FIXTURES/during-wait"
  stub_script team-ci-wait <<'SH'
if [[ -f $STUB_FIXTURES/during-wait ]]; then
  print_file "$STUB_FIXTURES/during-wait" >>"$TEAM_HOME/ledger.jsonl"
  rm "$STUB_FIXTURES/during-wait"
fi
source "$STUB_FIXTURES/ci-ends.sh"
SH
}

# The gh calls that rerun a check.
rerun_calls() {
  stub_calls gh | jq -c 'select(.[0] == "run")'
}

# The ci-rerun events logged, each as its check, run and job.
reruns_logged() {
  jq -c 'select(.event == "ci-rerun") | [.check, .run, .job]' "$TEAM_HOME/ledger.jsonl"
}

# T172 ticket 14: a reviewer's verdict, and the fix round's stow.

@test "a pass whose PR head moved past the reviewed head is refused naming both, nothing logged" {
  local moved
  reviewing "$sha"
  moved=$(commit two.txt "feat: after the review")
  pr_on_github "$moved"
  refused "the PR's head $moved moved past the reviewed head $sha, so the pass is not taken; re-review the new head" \
    T7 -- "T7 DONE pass $url $counts before=none guarded=none"
}

@test "a pass on a PR logs the review and ends on the arm line, with no merge line, even on pending checks" {
  local count
  reviewing "$sha"
  pr_on_github "$sha" 0 '[{"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}, {"name": "test", "bucket": "pending", "state": "PENDING"}]'
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=ci"
  assert_equal "$output" "logged review verdict=pass head=$sha findings={\"blocking\":0,\"correctness\":0,\"security\":0,\"real-data\":0,\"note-change\":0,\"note-before\":0} before=[] guarded=[\"ci\"]
logged done role=reviewer session=r0000002
$(arm_line "$sha")"
  assert_equal "$(logged_from $((count + 1)) | jq -c '{event, verdict, head, guarded, role, session}')" \
    "$(jq -cn --arg h "$sha" '{event: "review", verdict: "pass", head: $h, guarded: ["ci"], role: null, session: null},
      {event: "done", verdict: null, head: null, guarded: null, role: "reviewer", session: "r0000002"}' | jq -c .)"
  assert_equal "$(outside_calls)" ""
  assert_equal "$(bg_calls)" ""
}

@test "--ci's other ends: the deadline re-arms, a moved head stops, an unreadable GitHub re-arms, a closed PR ends" {
  local other=fedcba9876543210fedcba9876543210fedcba98 text
  reviewing "$sha"
  pr_on_github "$sha"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  # The deadline logs ci pending and re-arms, exit 75.
  text="team-ci-wait: 90 minutes, and checks still pending on ${sha:0:7}: test (in_progress, run 7 in_progress): run team-ci-wait again to wait on them, or report BLOCKED"
  ci_wait_ends deadline "$sha" 75 "$text"
  run_bin -75 --separate-stderr team-next T7 --ci
  assert_equal "$output" "logged ci url=$url head=$sha outcome=pending
re-arm: the checks of ${sha:0:8} are still pending after 90 minutes ($text): run team-next T7 --ci again with Bash run_in_background"
  assert_equal "$(ci_logged)" "[\"$url\",\"$sha\",\"pending\"]"
  # A head no round made, whether it moved during the wait or was another from the start: exit 1,
  # nothing logged.
  for end in moved other-head; do
    ci_wait_ends "$end" "$other" 1 "team-ci-wait: the head of owner/proj#9 is another"
    run_bin -1 --separate-stderr team-next T7 --ci
    assert_equal "$output" \
      "the head of $url is ${other:0:8}, not the passed ${sha:0:8}: a commit no round made; read it with team-state T7 before anything else"
  done
  # GitHub unreadable, or the team offline: the wait's line, exit 75, nothing logged.
  for end in unreadable offline; do
    ci_wait_ends "$end" "$sha" 75 "team-ci-wait: $end for now"
    run_bin -75 --separate-stderr team-next T7 --ci
    assert_equal "$output" "team-ci-wait: $end for now"
  done
  # A merged or closed PR: the wait's line, exit 0.
  ci_wait_ends closed "$sha" 1 "team-ci-wait: owner/proj#9 is merged: its checks no longer matter"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$output" "team-ci-wait: owner/proj#9 is merged: its checks no longer matter"
  assert_equal "$(ci_logged)" "[\"$url\",\"$sha\",\"pending\"]"
  assert_equal "$(outside_calls)" ""
  assert_equal "$(bg_calls)" ""
}

@test "--ci on infrastructure alone reruns each never-started, setup or stuck check once, by its run, logs each ci-rerun once its run starts, and waits again; a roll-up is never rerun" {
  local count
  reviewing "$sha"
  pr_on_github "$sha"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  reruns_on_github "$sha"
  # Two shards of run 7 that never started (and their roll-up), a checkout that failed in run 8's
  # setup, and a check of run 9 whose status GitHub lost; then the checks pass.
  ci_ends "$(infra "smoke-shards (1)" never-started 7 10; infra "smoke-shards (2)" never-started 7 11; rollup smoke 7 12
    infra "test-shards (1)" setup 8 20 "Run actions/checkout@v4"; infra e2e stuck 9 30)" passed
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$output" "logged ci-rerun url=$url head=$sha check=smoke-shards (1) run=7 job=10
logged ci-rerun url=$url head=$sha check=smoke-shards (2) run=7 job=11
logged ci-rerun url=$url head=$sha check=test-shards (1) run=8 job=20
logged ci-rerun url=$url head=$sha check=e2e run=9 job=30
logged ci url=$url head=$sha outcome=passed
merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks green"
  # One rerun a run: a run's one job by its id, two of one run as its failed jobs (GitHub reruns
  # no job of a run already running again), a lost status as the whole run, as team-ci-wait says.
  assert_equal "$(rerun_calls)" '["run","rerun","7","--failed","--repo","owner/proj"]
["run","rerun","8","--job","20","--repo","owner/proj"]
["run","rerun","9","--repo","owner/proj"]'
  assert_equal "$(logged_from $((count + 1)) | jq -c 'del(.task)')" "$(jq -cn --arg url "$url" --arg h "$sha" '
    ({check: "smoke-shards (1)", run: "7", job: "10"}, {check: "smoke-shards (2)", run: "7", job: "11"},
     {check: "test-shards (1)", run: "8", job: "20"}, {check: "e2e", run: "9", job: "30"}
     | {event: "ci-rerun", url: $url, head: $h} + .),
    {event: "ci", url: $url, head: $h, outcome: "passed"}')"
  assert_equal "$(ci_waits)" 2
  assert_equal "$(stub_calls team-ci-wait | sort -u)" "[\"--no-agent-review\",\"--json\",\"$url\",\"$sha\"]"
  assert_equal "$(bg_calls)" ""
  assert_contains "$(stub_calls gh)" '["api","repos/owner/proj/actions/runs/7"]'
}

@test "a check rerun once on the head that fails as infrastructure again, after a restart too, logs ci infrastructure and the blocked line; a queued one at once; a re-arm after it reruns again" {
  local link=https://github.com/owner/proj/actions/runs/7/job blocked
  reviewing "$sha"
  pr_on_github "$sha"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  reruns_on_github "$sha"
  # The rerun is logged, then the wait ends unreadable: the coordinator re-arms.
  ci_ends "$(infra "smoke-shards (1)" never-started 7 10; rollup smoke 7 12)" unreadable
  run_bin -75 --separate-stderr team-next T7 --ci
  assert_equal "$output" "logged ci-rerun url=$url head=$sha check=smoke-shards (1) run=7 job=10
team-ci-wait: GitHub not read for now"
  # The restart reads the rerun from the ledger: the check, under the new job id of its new
  # attempt, failing so again is not rerun.
  ci_ends "$(infra "smoke-shards (1)" never-started 7 13; rollup smoke 7 14)"
  run_bin -1 --separate-stderr team-next T7 --ci
  blocked="blocked: the checks smoke-shards (1) of $url at ${sha:0:8} failed as infrastructure again after a rerun: $link/13; tell Daniel, and run team-next T7 --ci again once they say the runners are back"
  assert_equal "$output" "logged ci url=$url head=$sha outcome=infrastructure failed=$(jq -c '.failures | map({name, class, kind, link, step})' "$STUB_FIXTURES/ci-end-1.out")
$blocked"
  assert_equal "$(rerun_calls)" '["run","rerun","7","--job","10","--repo","owner/proj"]'
  assert_equal "$(reruns_logged)" '["smoke-shards (1)","7","10"]'
  assert_equal "$(ci_logged)" "[\"$url\",\"$sha\",\"infrastructure\"]"
  assert_equal "$(jq -c 'select(.event == "ci") | .failed | map(.name)' "$TEAM_HOME/ledger.jsonl")" '["smoke-shards (1)","smoke"]'
  # Once Daniel says the runners are back, the re-armed wait reruns it once more.
  ci_ends "$(infra "smoke-shards (1)" never-started 7 13; rollup smoke 7 14)" passed
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(head -n 2 <<<"$output")" "logged ci-rerun url=$url head=$sha check=smoke-shards (1) run=7 job=13
logged ci url=$url head=$sha outcome=passed"
  assert_equal "$(rerun_calls | tail -n 1)" '["run","rerun","7","--job","13","--repo","owner/proj"]'
  # A check queued with no runner is never rerun: the blocked line at once, beside a rerun of a
  # check that never started, which is waited on first.
  review_logged pass "$sha" '[]'
  ci_ends "$(infra build queued 5 50; infra "smoke-shards (2)" never-started 6 60)" "$(infra build queued 5 50)"
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_equal "$output" "logged ci-rerun url=$url head=$sha check=smoke-shards (2) run=6 job=60
logged ci url=$url head=$sha outcome=infrastructure failed=$(jq -c '.failures | map({name, class, kind, link, step})' "$STUB_FIXTURES/ci-end-2.out")
blocked: the checks build of $url at ${sha:0:8} failed as infrastructure with no runner for 20 minutes: https://github.com/owner/proj/actions/runs/5/job/50; tell Daniel, and run team-next T7 --ci again once they say the runners are back"
  assert_equal "$(rerun_calls | grep -c '"5"')" 0
  assert_equal "$(bg_calls)" ""
}

@test "a rerun GitHub refuses, a run that does not start within 2 minutes of looks, a run that cannot be read and a lease refusal each log nothing and print the blocked line, exit 1" {
  local count link=https://github.com/owner/proj/actions/runs/7/job/10
  reviewing "$sha"
  pr_on_github "$sha"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  reruns_on_github "$sha"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  # GitHub refuses the rerun.
  echo "run 7 cannot be rerun; This workflow is already running" >"$STUB_FIXTURES/rerun-refused"
  ci_ends "$(infra "smoke-shards (1)" never-started 7 10)" passed
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_equal "$output" "blocked: GitHub refused gh run rerun 7 --job 10 --repo owner/proj (run 7 cannot be rerun; This workflow is already running): $link"
  rm "$STUB_FIXTURES/rerun-refused"
  # The run never moves: twelve looks 10 s apart, 2 minutes.
  touch "$STUB_FIXTURES/rerun-stays"
  looks_counted
  ci_ends "$(infra "smoke-shards (1)" never-started 7 10)" passed
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_equal "$output" "blocked: run 7 did not start again within 2 minutes of gh run rerun 7 --job 10 --repo owner/proj: $link"
  assert_equal "$(<"$BATS_TEST_TMPDIR/looks")" 12
  assert_equal "$(stub_calls sleep | sort -u)" '["10"]'
  rm "$STUB_FIXTURES/rerun-stays"
  # The run cannot be read before its rerun, so its attempt is not known.
  stub_script gh <<'SH'
case "$*" in
  "api repos/owner/proj/actions/runs/"*) echo "HTTP 404: Not Found" >&2; exit 1 ;;
  "run rerun "*) exit 0 ;;
  *) source "$STUB_FIXTURES/gh-pr.sh" ;;
esac
SH
  ci_ends "$(infra "smoke-shards (1)" never-started 7 10)" passed
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_equal "$output" "blocked: run 7 cannot be read before its rerun (HTTP 404: Not Found): $link"
  reruns_on_github "$sha"
  # A fenced machine reruns nothing.
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T14:00:00Z", "holder": "laptop", "epoch": 2}' >"$HOME/.local/state/agent-team/fenced"
  ci_ends "$(infra "smoke-shards (1)" never-started 7 10)" passed
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_equal "$output" "blocked: home-pc is fenced since 2026-10-22T14:00:00Z (holder seen laptop, epoch 2): a fenced machine reruns no check: $link"
  # Nothing was logged, and only the refused rerun and the one that never started reached GitHub.
  assert_equal "$(wc -l <"$TEAM_HOME/ledger.jsonl")" "$count"
  assert_equal "$(rerun_calls)" '["run","rerun","7","--job","10","--repo","owner/proj"]
["run","rerun","7","--job","10","--repo","owner/proj"]'
  assert_equal "$(ci_waits)" 4
}

@test "--ci on a failure of the PR's own logs one ci failed holding every failure, writes their report in class order, reruns nothing and hands the round on as a findings round's" {
  local count short=${sha:0:8} job=https://github.com/owner/proj/actions/runs/7/job
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 120000
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  red_checks "$sha"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$output" "report $TEAM_HOME/tasks/T7/ci-$short.md
logged ci url=$url head=$sha outcome=failed failed=$(red_logged)
$(ci_fix "T7-builder (b0000001, 120k)" "$sha")"
  # One ci, holding every failure, the infrastructure one and the roll-up among them.
  assert_equal "$(logged_from $((count + 1)) | jq -c 'del(.task)')" \
    "$(jq -cn --arg url "$url" --arg h "$sha" --argjson f "$(red_logged)" '{event: "ci", url: $url, head: $h, outcome: "failed", failed: $f}')"
  assert_equal "$(red_logged | jq -r 'map(.name) | join(",")')" "test,test-shards (2),smoke-shards (1),build,lint"
  # The report: the PR's failures first, then infrastructure, then the roll-up, each with its
  # class, name, kind, step, link and rerun, and the closing line.
  assert_equal "$(<"$TEAM_HOME/tasks/T7/ci-$short.md")" "# The failed checks of $url at $sha

The checks wait after the pass ended on these failures, one a line, the PR's first: each one's class, check, kind, failing step, link and rerun command.

- the PR's: \`test-shards (2)\`, failed, at the step \"Run the tests\", $job/8, no rerun
- the PR's: \`build\`, missing, at no step, no link, no rerun
- the PR's: \`lint\`, failed, at the step \"Lint\", $job/11, no rerun
- infrastructure: \`smoke-shards (1)\`, never-started, at no step, $job/10, rerun with \`gh run rerun 7 --job 10 --repo owner/proj\`
- roll-up: \`test\`, rollup, at no step, $job/9, no rerun

The PR's failures, \`test-shards (2)\`, \`build\` and \`lint\`, are this round's \`blocking\` findings; the others are not, since an infrastructure failure or a roll-up is no defect of the PR, and the round's new head runs every check again."
  # Nothing was rerun, posted or launched.
  assert_equal "$(outside_calls)" ""
  assert_equal "$(bg_calls)" ""
  # The checks went back as a round, so --ci is refused until the next pass.
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_contains "$stderr" "team-next: the checks of $short failed and went back as a round on "
  # A holder at 250k or more gets the STOW, a gone one is recovered first, as a findings round's.
  review_logged pass "$sha" '[]'
  live b0000001 260000
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 260k): T7 STOW; its PAUSED stowed goes to team-next, which launches the round"
  review_logged pass "$sha" '[]'
  live
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" \
    "T7-builder b0000001 is gone: recover it (the recover-worker skill), then send it T7 STOW; its PAUSED stowed goes to team-next, which launches the round"
  assert_equal "$(ci_logged)" "[\"$url\",\"$sha\",\"failed\"]
[\"$url\",\"$sha\",\"failed\"]
[\"$url\",\"$sha\",\"failed\"]"
  assert_equal "$(stub_calls team-ci-wait | wc -l)" 3
}

@test "a PAUSED stowed after a failed ci launches builder-round on the failed checks and their report, and the next PR a rereview whose since says this round fixed them" {
  local short=${sha:0:8} report fix
  report=${TEAM_HOME/#"$HOME"/\~}/tasks/T7/ci-$short.md
  # The round's launch renders its brief from the code checkout --ci runs from.
  code_checkout
  reviewing "$sha"
  pr_on_github "$sha"
  live b0000001 260000
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  red_checks "$sha"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" \
    "send to T7-builder (b0000001, 260k): T7 STOW; its PAUSED stowed goes to team-next, which launches the round"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$(tail -n 2 <<<"$output")" "brief $TEAM_HOME/tasks/T7/brief-round-1.md
launched T7-builder c0000001"
  assert_equal "$(record round-1 | jq -cS .)" "$(jq -cnS --arg url "$url" --arg r "$report" --arg s "$short" '{template: "builder-round",
    values: {findings: "the failed checks test-shards (2), build and lint of \($s)", findings_file: $r,
      goal: "Coordinator toil goes to the scripts.", pr: $url}}')"
  assert_contains "$(<"$TEAM_HOME/tasks/T7/brief-round-1.md")" \
    "and findings the failed checks test-shards (2), build and lint of $short in \`$report\`."
  # A second stow after that launch launches nothing.
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off for PAUSED stowed: no review's sent-back findings or failed checks wait for a round"
  # The round's PR goes to a rereview, not a verify, whose since says the checks failed on the pass.
  fix=$(commit two.txt "fix: the failed checks")
  on_github 9 "$fix"
  run_bin -0 --separate-stderr team-next T7 -- "T7 PR $url"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-rereview-2.md"
  assert_equal "$(record rereview-2 | jq -r .template)" rereview
  grep -qxF "The last review, of \`$short\`, passed; then the checks test-shards (2), build and lint failed on it, which this round fixed." \
    "$TEAM_HOME/tasks/T7/brief-rereview-2.md"
  # A stow after a pass with no failed ci since launches nothing.
  review_logged pass "$fix" '[]'
  run_bin -0 --separate-stderr team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off for PAUSED stowed: no review's sent-back findings or failed checks wait for a round"
  assert_equal "$(bg_calls | wc -l)" 2
}

@test "--ci is refused, logging nothing and waiting on nothing: no pass on an open PR, checks that failed, a closed or held task, an ask, a worker" {
  ci_wait_ends passed "$sha"
  local none="team-next: T7's latest review is not a pass on an open PR, so no checks wait for a merge"
  refused "$none" T7 --ci
  reviewing "$sha"
  review_logged findings "$sha" '[1]'
  refused "$none" T7 --ci
  review_logged pass "$sha" '[]'
  event ci "$(jq -cn --arg url "$url" --arg h "$sha" '{url: $url, head: $h, outcome: "failed", failed: []}')"
  refused "team-next: the checks of ${sha:0:8} failed and went back as a round on 2026-11-01T10:00:00Z" T7 --ci
  event ci "$(jq -cn --arg url "$url" --arg h "$sha" '{url: $url, head: $h, outcome: "passed"}')"
  event held '{reason: "Daniel: not now", cause: "daniel-hold", discord_message: "1563000000000000044"}'
  refused "T7 is on Daniel's hold since 2026-11-01T10:00:00Z (held-1): Daniel: not now" T7 --ci
  event resumed '{id: "held-1", discord_message: "1563000000000000046"}'
  event asked '{id: "scope", text: "Which scope?"}'
  refused "T7 has an unanswered ask, scope, since 2026-11-01T10:00:00Z" T7 --ci
  event answered '{id: "scope", text: "This one.", discord_message: "1563000000000000045"}'
  event closed '{archive: [], returned: [], kept: []}'
  refused "T7 is closed" T7 --ci
  assert_equal "$(stub_calls team-ci-wait)" ""
  worker_refused team-next "runs no team-next" T7 --ci
}

@test "--ci reads the ledger again when a wait ends: a hold, an ask, a findings review or a catch-up logged meanwhile stops it, with no ci logged, no rerun and no hand-off; a new pass's facts are taken" {
  reviewing "$sha"
  pr_on_github "$sha"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  reruns_on_github "$sha"
  # Daniel's hold logged while the checks went green: no ci, no merge line.
  ci_ends passed
  during_wait held '{reason: "Daniel: not now", cause: "daniel-hold", discord_message: "1563000000000000044"}'
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_equal "$output" ""
  assert_contains "$stderr" "T7 is on Daniel's hold since 2026-11-01T10:00:00Z (held-1): Daniel: not now"
  assert_equal "$(ci_logged)" ""
  event resumed '{id: "held-1", discord_message: "1563000000000000046"}'
  # An ask logged while the checks failed as infrastructure: nothing is rerun.
  ci_ends "$(infra "test-shards (1)" never-started 8 20)" passed
  during_wait asked '{id: "scope", text: "Which scope?"}'
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_equal "$output" ""
  assert_contains "$stderr" "T7 has an unanswered ask, scope, since 2026-11-01T10:00:00Z"
  assert_equal "$(rerun_calls)" ""
  assert_equal "$(reruns_logged)" ""
  event answered '{id: "scope", text: "This one.", discord_message: "1563000000000000045"}'
  # A findings review of the head logged while the checks failed as the PR's own: no round.
  ci_ends "$(jq -cn '{name: "lint", class: "pr", kind: "failed", state: "FAILURE", link: null, run: null, job: null, step: "Lint", rerun: null}')"
  during_wait review "{verdict: \"findings\", head: \"$sha\", sent_back: [1], findings: {blocking: 1}}"
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_equal "$output" ""
  assert_contains "$stderr" "T7's latest review is not a pass on an open PR, so no checks wait for a merge"
  assert_equal "$(ci_logged)" ""
  [[ ! -e $TEAM_HOME/tasks/T7/ci-${sha:0:8}.md ]]
  # A new pass of the head logged meanwhile: the merge line takes its before notes.
  review_logged pass "$sha" '[]'
  ci_ends passed
  during_wait review "{verdict: \"pass\", head: \"$sha\", findings: {blocking: 0, \"note-before\": 1}, before: [3], guarded: []}"
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks green; queue before notes 3 as follow-ups and say where each went"
  # A catch-up logged meanwhile moves the wait to its merge: arm it again.
  review_logged pass "$sha" '[]'
  ci_ends passed
  during_wait caught-up "{url: \"$url\", from: \"$sha\", head: \"f00ba47a00000000000000000000000000000000\", base: \"0e0e0e0e\"}"
  run_bin -1 --separate-stderr team-next T7 --ci
  assert_contains "$stderr" "the checks wait of T7 moved to $url at f00ba47a while it waited on ${sha:0:8}: arm team-next T7 --ci again"
}

@test "a second --ci while one waits on the task's checks says so and ends, waiting on nothing" {
  local lock=$HOME/.local/state/agent-team/ci/T7.lock fd
  reviewing "$sha"
  pr_on_github "$sha"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE pass $url $counts before=none guarded=none"
  ci_wait_ends passed "$sha"
  mkdir -p "${lock%/*}"
  exec {fd}>>"$lock"
  flock -n "$fd"
  run_bin -0 --separate-stderr team-next T7 --ci
  exec {fd}>&-
  assert_equal "$output" "the checks wait of T7 is already running ($lock): its end prints the next step"
  assert_equal "$(stub_calls team-ci-wait)" ""
  assert_equal "$(ci_logged)" ""
  # Once that one ended, the next one waits.
  run_bin -0 --separate-stderr team-next T7 --ci
  assert_equal "$(tail -n 1 <<<"$output")" "merge on the default word: run team-merge T7 for $url at $sha, agent-review success, checks green"
}

@test "--ci takes no message and no other option, and --help documents it, the pass's arm line and the round on failed checks" {
  run_bin -2 team-next T7 --ci -- "T7 DONE pass $url $counts before=none guarded=none"
  assert_contains "$output" "--ci takes no message and no other option: team-next T<n> --ci"
  run_bin -2 team-next T7 --from r0000002 --ci
  assert_contains "$output" "--ci takes no message and no other option"
  run_bin -2 team-next T7 --ci --sent-back 1
  assert_contains "$output" "--ci takes no message and no other option"
  run_bin -2 team-next T7 --ci --ci
  assert_contains "$output" "--ci is given twice"
  run_bin -0 team-next --help
  assert_contains "$output" "       team-next T<n> --ci"
  assert_contains "$output" "checks: arm team-next T<n> --ci with Bash run_in_background"
  assert_contains "$output" "team-ci-wait --no-agent-review --json <url> <head>"
  assert_contains "$output" "writes the report"
  assert_contains "$output" "tasks/T<n>/ci-<the head's first 8 characters>.md in the team home"
  assert_contains "$output" "sent findings back, or a ci of outcome failed on a PR of its repo, or naming"
  assert_contains "$output" "with infrastructure and roll-up failures alone: reruns each never-started,"
  assert_contains "$output" "so once a check and head until Daniel's word re-arms it after the blocked"
  assert_contains "$output" "writes to GitHub are the reviewer App's check at a verdict and --ci's reruns."
}
