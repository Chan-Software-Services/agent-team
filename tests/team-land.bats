#!/usr/bin/env bats
# team-land: one PR landed through its base's merge queue, on a GraphQL stub that steps through the
# queue's states look by look. The real team-ci-wait --merge-group waits on each trial commit's
# checks, from the same stub; the poster of agent-review (team-review-status, or team-review-check
# on the App's project) is the logging stub, but in the last test, which runs the real one's proof
# on a real origin (helpers/queue).

load helpers/common
load helpers/queue
load helpers/github-api

setup() {
  sandbox
  printf '%s\n' '[proj]' 'repo = "owner/proj"' 'path = "projects/proj"' 'base = "dev"' 'delivery = "direct-pr"' \
    'merge_method = "merge"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    '[proj.pool]' 'provider = "git"' 'slots = ["slots/proj/1"]' >"$TEAM_HOME/projects.toml"
  head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
  merge=0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e
  t1=5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e
  t2=6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f
  url=https://github.com/owner/proj/pull/5
  export GH_DIR=$BATS_TEST_TMPDIR/gh
  mkdir -p "$GH_DIR"
  echo 0 >"$GH_DIR/look"
  github_stub_setup
  # team-ci-wait reads GitHub again at each look, with no time passing but the stub sleep's.
  export TEAM_GITHUB_FRESH_SECONDS=0
  review_app_off
  poster team-review-status "agent-review success"
  land_gh
  stub_sleep
  answer 0 enqueue '{"data": {"enqueuePullRequest": {"mergeQueueEntry": {"id": "MQE_1"}}}}'
  answer 0 dequeue '{"data": {"dequeuePullRequest": {"mergeQueueEntry": {"id": "MQE_1"}}}}'
}

# poster <script> <stdout> [<status>]: the project's poster of agent-review is the logging stub,
# its calls stub_calls <script>.
poster() {
  shared_make stub "$REPO_ROOT/tests/helpers/stub"
  ln -f "$BATS_RUN_TMPDIR/shared/stub" "$CODE_CHECKOUT/bin/$1"
  stub_reply "$1" "$2" "${3:-0}"
}

# answer <look> <what> <answer>: from look <look> on, gh answers <what> (pr, enqueue, dequeue,
# checks-<short trial sha> or job-<job id>) with <answer>: JSON, "fail" (gh cannot reach GitHub)
# or "refuse: <text>" (GitHub's GraphQL error).
answer() {
  printf '%s\n' "$3" >"$GH_DIR/$2.$1"
}

# pr_at <look> <state> [<trial sha> [<removal id> [<reason>]]]: the PR as GraphQL answers it from
# <look> on: its state (OPEN, MERGED with its merge commit, CLOSED), its queue entry on <trial
# sha> ("none": an entry with no trial commit yet; empty: no entry), and its latest removal from
# the queue, with GitHub's reason. Its head is PR_HEAD, else the head the tests land.
pr_at() {
  answer "$1" pr "$(jq -cn --arg state "$2" --arg trial "${3:-}" --arg removal "${4:-}" --arg reason "${5:-}" \
    --arg head "${PR_HEAD:-$head}" --arg merge "$merge" '
    {data: {repository: {pullRequest: {id: "PR_kwDOtest5", state: $state, headRefOid: $head,
      mergeCommit: (if $state == "MERGED" then {oid: $merge} else null end),
      mergeQueueEntry: (if $trial == "" then null else {state: "AWAITING_CHECKS", position: 1,
        enqueuedAt: "2026-11-15T10:00:00Z", headCommit: (if $trial == "none" then null else {oid: $trial} end)} end),
      timelineItems: {nodes: (if $removal == "" then [] else [{id: $removal, createdAt: "2026-11-15T10:30:00Z",
        reason: (if $reason == "" then null else $reason end)}] end)}}}}}')"
}

# check_run <name> <status> [<conclusion> [<run id> <job id>]]: one check run of a trial commit,
# its link an Actions job link when a run is given.
check_run() {
  jq -cn --arg name "$1" --arg status "$2" --arg conclusion "${3:-}" --arg run "${4:-}" --arg job "${5:-}" '{name: $name,
    status: $status, conclusion: (if $conclusion == "" then null else $conclusion end),
    html_url: (if $run == "" then "https://ci.example.invalid/\($name)"
      else "https://github.com/owner/proj/actions/runs/\($run)/job/\($job)" end)}'
}

# trial_checks <look> <trial sha> <check run>...: that trial commit's check runs from <look> on.
trial_checks() {
  local look=$1 sha=$2
  shift 2
  answer "$look" "checks-${sha:0:7}" "$(jq -cs '{total_count: length, check_runs: .}' <<<"$*")"
}

# job <job id> <step>=<conclusion>...: the Actions job as gh api shows it, on a runner.
job() {
  local id=$1
  shift
  answer 0 "job-$id" "$(jq -cn --argjson id "$id" '{id: $id, runner_name: "runner-1", status: "completed",
    steps: [$ARGS.positional | to_entries[] | (.value | rindex("=")) as $i
      | {name: .value[:$i], status: "completed", number: (.key + 1), conclusion: .value[$i + 1:]}]}' --args "$@")"
}

# gh answers team-land's read of the PR and team-ci-wait's read of its entry (one answer, pr), an
# enqueue (enqueue, its variables kept in $GH_DIR/enqueues), a dequeue (dequeue, its variables
# kept in $GH_DIR/dequeues), a trial commit's check runs, no
# status and no workflow run of it, a job, team-ci-wait's read of dev's rules (branch, rules and
# ruleset-<id>, planned by rules_require; with none planned the read fails, and team-ci-wait holds
# the registry's checks alone), and a status POST, each from the latest answer at or
# before the current look; team-ci-wait's REST reads (gh api -i, through bin/lib/github-api.sh) in
# gh api -i's form through tests/helpers/github-api.bash. Each call is one line of $GH_DIR/calls,
# with -i and an -H header left out. Anything unplanned fails.
land_gh() {
  stub_script gh <<'EOF'
source "$GITHUB_STUB_HELPER"
github_request "$@"
args=() raw=false
while (($#)); do
  case $1 in
    -i) raw=true ;;
    -H) shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
set -- "${args[@]}"
# answer <body>: the read's answer, in gh api -i's form for the reader.
answer() {
  if $raw; then github_answer 200 "$1"; fi
  printf '%s\n' "$1"
  exit 0
}
n=$(cat "$GH_DIR/look")
if (($# > 2)); then printf '%s\n' "$1 $2 ${*: -1}"; else printf '%s\n' "$1 $2"; fi >>"$GH_DIR/calls"
case "$1 $2" in
  "api graphql")
    what=pr
    if [[ $4 == *enqueuePullRequest* ]]; then
      what=enqueue
      [[ $4 == *"expectedHeadOid: \$head"* && $4 == *"pullRequestId: \$pr"* ]] || { echo "not the planned mutation" >&2; exit 1; }
      printf '%s\n' "${*:5}" >>"$GH_DIR/enqueues"
    elif [[ $4 == *dequeuePullRequest* ]]; then
      what=dequeue
      [[ $4 == *"dequeuePullRequest(input: {id: \$pr})"* ]] || { echo "not the planned mutation" >&2; exit 1; }
      printf '%s\n' "${*:5}" >>"$GH_DIR/dequeues"
    fi
    ;;
  "api --method") echo '{"state": "success"}'; exit 0 ;;
  "api repos/owner/proj/commits/"*"/check-runs?filter=latest&per_page=100")
    sha=${2#repos/owner/proj/commits/}
    what=checks-${sha:0:7}
    ;;
  "api repos/owner/proj/commits/"*"/status?per_page=100") answer '{"state": "pending", "statuses": []}' ;;
  "api repos/owner/proj/actions/runs?head_sha="*) answer '{"total_count": 0, "workflow_runs": []}' ;;
  "api repos/owner/proj/actions/runs?status=in_progress&per_page=1") answer '{"total_count": 0, "workflow_runs": []}' ;;
  "api repos/owner/proj/actions/jobs/"*) what=job-${2##*/} ;;
  "api repos/owner/proj/branches/dev") what=branch ;;
  "api repos/owner/proj/rules/branches/dev") what=rules ;;
  "api repos/owner/proj/rulesets/"*) what=ruleset-${2##*/} ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
m=$n
while ((m >= 0)) && [[ ! -e $GH_DIR/$what.$m ]]; do m=$((m - 1)); done
if ((m < 0)); then echo "no answer planned for $what at look $n" >&2; exit 1; fi
body=$(cat "$GH_DIR/$what.$m")
case $body in
  fail) echo "error connecting to api.github.com" >&2; exit 1 ;;
  refuse:*) echo '{"errors": []}'; echo "gh:${body#refuse:}" >&2; exit 1 ;;
esac
answer "$body"
EOF
}

# rules_require <context>...: dev protected by the active ruleset 41 alone, which requires those
# checks, as base_rules reads them.
rules_require() {
  answer 0 branch '{"protected": true}'
  answer 0 rules "$(jq -cn '[{type: "required_status_checks", ruleset_id: 41, ruleset_source_type: "Repository",
    parameters: {strict_required_status_checks_policy: false, required_status_checks: [$ARGS.positional[] | {context: .}]}}]' \
    --args "$@")"
  answer 0 ruleset-41 '{"id": 41, "name": "dev", "bypass_actors": []}'
}

# ci_wait_ends <failure>...: team-ci-wait is the logging stub, each wait ending failed with those
# failures, each {name, class, kind, link, step}, and a line for each.
ci_wait_ends() {
  shared_make stub "$REPO_ROOT/tests/helpers/stub"
  ln -f "$BATS_RUN_TMPDIR/shared/stub" "$CODE_CHECKOUT/bin/team-ci-wait"
  stub_reply team-ci-wait "$(jq -cs '{schema: "team-ci-wait/1", outcome: "failed", failures: .,
    text: (["team-ci-wait: the checks did not pass:"] + map("  \(.class): \(.name)") | join("\n"))}' <<<"$*")" 1
}

# The stub sleep moves on to the next look, and the reader's clock on by its seconds, and, after
# LOOK_LIMIT looks (default 60), stops the script with exit 99, so a landing that never ends shows
# as that exit. The uname stub keeps it ahead of Homebrew's GNU sleep on macOS.
stub_sleep() {
  stub_command sleep uname
  stub_reply uname Linux
  stub_script sleep <<EOF
n=\$(cat "$GH_DIR/look")
((n < \${LOOK_LIMIT:-60})) || exit 99
echo \$((n + 1)) >"$GH_DIR/look"
echo \$((\$(cat "\$TEAM_GITHUB_CLOCK") + \$1)) >"\$TEAM_GITHUB_CLOCK"
EOF
}

# The look the landing ended at, the enqueues made, and the trial commits agent-review was posted
# on through <script> (default team-review-status), in order.
ended_at() {
  cat "$GH_DIR/look"
}

enqueues() {
  cat "$GH_DIR/enqueues" 2>/dev/null || true
}

dequeues() {
  cat "$GH_DIR/dequeues" 2>/dev/null || true
}

posted_on() {
  stub_calls "${1:-team-review-status}" | jq -r 'join(" ")'
}

# The end's JSON, the last line of what the landing printed, as [outcome, merge, reason, failed].
end_json() {
  local last=${lines[-1]}
  assert_equal "$(jq -r '[.schema, .url, .head, (keys | join(" "))] | join(" ")' <<<"$last")" \
    "team-land/1 $url $head failed head merge outcome reason schema url"
  jq -c '[.outcome, .merge, .reason, .failed]' <<<"$last"
}

@test "a PR in no queue is enqueued at its head, agent-review posted on its trial commit, and it ends merged with the merge commit" {
  pr_at 0 OPEN
  pr_at 1 OPEN none
  pr_at 2 OPEN "$t1"
  trial_checks 2 "$t1" "$(check_run test in_progress)"
  trial_checks 3 "$t1" "$(check_run test completed success)"
  pr_at 4 MERGED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 4
  assert_equal "$output" "team-land: enqueued $url at a1b2c3d
team-land: set agent-review success on the trial commit 5e5e5e5
team-land: the checks of the trial commit 5e5e5e5: closed
  team-ci-wait: owner/proj#5 is merged: its checks no longer matter
team-land: $url merged as 0e0e0e0
{\"schema\":\"team-land/1\",\"outcome\":\"merged\",\"url\":\"$url\",\"head\":\"$head\",\"merge\":\"$merge\",\"reason\":null,\"failed\":[]}"
  assert_equal "$(end_json)" "[\"merged\",\"$merge\",null,[]]"
  assert_equal "$(enqueues)" "-f pr=PR_kwDOtest5 -f head=$head"
  assert_equal "$(posted_on)" "--merge-group $url $t1"
  # The wait on the trial commit is team-ci-wait's: the commit's check runs, never the PR's checks.
  grep -Fxq "api repos/owner/proj/commits/$t1/check-runs?filter=latest&per_page=100" "$GH_DIR/calls"
  if grep -E '^pr ' "$GH_DIR/calls"; then return 1; fi
}

@test "a trial commit whose checks all passed is waited on until the queue merges it, with one post and one wait" {
  pr_at 0 OPEN
  pr_at 1 OPEN "$t1"
  trial_checks 1 "$t1" "$(check_run test completed success)" "$(check_run agent-review completed success)"
  pr_at 9 MERGED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 9
  assert_equal "$(end_json)" "[\"merged\",\"$merge\",null,[]]"
  assert_contains "$output" "team-land: the checks of the trial commit 5e5e5e5: passed
  team-ci-wait: every check passed on 5e5e5e5: test passed, agent-review passed"
  assert_equal "$(posted_on)" "--merge-group $url $t1"
  assert_equal "$(grep -c "check-runs" "$GH_DIR/calls")" 5
}

@test "a PR the queue rebuilds onto a second trial commit gets agent-review on both, once each, and lands" {
  pr_at 0 OPEN
  pr_at 1 OPEN "$t1"
  trial_checks 1 "$t1" "$(check_run test in_progress)"
  pr_at 3 OPEN "$t2"
  trial_checks 3 "$t2" "$(check_run test in_progress)"
  pr_at 6 MERGED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 6
  assert_equal "$(end_json)" "[\"merged\",\"$merge\",null,[]]"
  assert_equal "$(enqueues)" "-f pr=PR_kwDOtest5 -f head=$head"
  assert_equal "$(posted_on)" "--merge-group $url $t1
--merge-group $url $t2"
  assert_contains "$output" "team-land: the checks of the trial commit 5e5e5e5: other-head"
  assert_contains "$output" "its trial commit is now 6f6f6f6, whose checks need a wait of their own"
}

@test "a PR dropped for a failure of its own on the trial commit ends dequeued, with GitHub's reason and the failure, and no second enqueue" {
  pr_at 0 OPEN '' RMQE_old "an earlier drop"
  pr_at 1 OPEN "$t1" RMQE_old "an earlier drop"
  trial_checks 1 "$t1" "$(check_run test in_progress)" "$(check_run data in_progress)"
  trial_checks 2 "$t1" "$(check_run test completed failure 7001 97001)" "$(check_run data completed cancelled 7001 97002)"
  job 97001 "Set up job=success" "Run tests=failure"
  pr_at 2 OPEN '' RMQE_new "failed checks"
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 2
  assert_equal "$(end_json)" '["dequeued",null,"failed checks",[{"name":"test","class":"pr","kind":"failed","link":"https://github.com/owner/proj/actions/runs/7001/job/97001","step":"Run tests"}]]'
  assert_contains "$output" "team-land: the merge queue dropped $url: failed checks"
  assert_contains "$output" "  the PR's: test failed: https://github.com/owner/proj/actions/runs/7001/job/97001"
  assert_equal "$(enqueues)" "-f pr=PR_kwDOtest5 -f head=$head"
  assert_equal "$(posted_on)" "--merge-group $url $t1"
}

@test "a PR dropped with only infrastructure failures is enqueued at the same head once more, and lands" {
  pr_at 0 OPEN
  pr_at 1 OPEN "$t1"
  trial_checks 1 "$t1" "$(check_run test in_progress)"
  # test rolls up its shard, which failed in setup: no failure is the PR's own.
  trial_checks 2 "$t1" "$(check_run test completed failure 7001 97001)" "$(check_run "test-shards (2)" completed failure 7001 97002)"
  job 97002 "Set up job=failure"
  pr_at 2 OPEN '' RMQE_1 "failed checks"
  pr_at 3 OPEN "$t2" RMQE_1 "failed checks"
  trial_checks 3 "$t2" "$(check_run test in_progress)"
  pr_at 5 MERGED '' RMQE_1 "failed checks"
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 5
  assert_equal "$(end_json)" "[\"merged\",\"$merge\",null,[]]"
  assert_equal "$(enqueues)" "-f pr=PR_kwDOtest5 -f head=$head
-f pr=PR_kwDOtest5 -f head=$head"
  assert_contains "$output" "team-land: only infrastructure failed on the trial commit: enqueued $url at a1b2c3d once more"
  assert_equal "$(posted_on)" "--merge-group $url $t1
--merge-group $url $t2"
}

@test "a PR dropped twice with only infrastructure failures ends dequeued after its one more enqueue, naming the second drop's failures" {
  pr_at 0 OPEN
  pr_at 1 OPEN "$t1"
  trial_checks 1 "$t1" "$(check_run test completed failure 7001 97001)"
  job 97001 "Set up job=failure"
  pr_at 2 OPEN '' RMQE_1 "failed checks"
  pr_at 3 OPEN "$t2" RMQE_1 "failed checks"
  trial_checks 3 "$t2" "$(check_run data completed failure 7002 97003)"
  job 97003 "Run actions/checkout@v4=failure"
  pr_at 4 OPEN '' RMQE_2 "failed checks again"
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 4
  assert_equal "$(end_json)" '["dequeued",null,"failed checks again",[{"name":"data","class":"infrastructure","kind":"setup","link":"https://github.com/owner/proj/actions/runs/7002/job/97003","step":"Run actions/checkout@v4"}]]'
  assert_equal "$(enqueues | wc -l)" 2
  # The one more enqueue that GitHub refuses ends it too, saying so after GitHub's reason.
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR/enqueues"
  answer 2 enqueue "refuse: Pull request is not mergeable"
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 2
  assert_equal "$(jq -c '[.[0, 2], (.[3] | map(.name))]' <<<"$(end_json)")" \
    '["dequeued","failed checks; enqueuing a1b2c3d once more failed: Pull request is not mergeable",["test"]]'
}

@test "a check dev's rules require that never reports on the trial commit takes the PR out of the queue at once, never enqueued again" {
  rules_require test "Analyze (python)"
  pr_at 0 OPEN
  pr_at 1 OPEN "$t1"
  trial_checks 1 "$t1" "$(check_run test completed success)"
  # The queue would drop it only at the check's timeout; team-land does not wait for that.
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(end_json)" '["dequeued",null,"Analyze (python) never reported on the trial commit, which dev'"'"'s rules require",[{"name":"Analyze (python)","class":"rules","kind":"missing","link":null,"step":null}]]'
  assert_contains "$output" "  rules: Analyze (python) was not reported on the trial commit, though dev's rules require it: no workflow makes it on a merge queue's trial commit"
  assert_contains "$output" "team-land: took $url out of the merge queue: Analyze (python) never reported on the trial commit, which dev's rules require"
  assert_equal "$(dequeues)" "-f pr=PR_kwDOtest5"
  assert_equal "$(enqueues)" "-f pr=PR_kwDOtest5 -f head=$head"
  # The header says the drop and its next step.
  run_bin -0 team-land --help
  output=$(tr -s ' \n#' ' ' <<<"$output")
  assert_contains "$output" "a wait that ends with any rules failure, whatever else failed, has the PR taken out of the queue at once"
  assert_contains "$output" "A rules drop is never enqueued again: the next step is the base's rules or the workflow's merge_group trigger, which team-merge names."
}

@test "a rules failure beside others takes the PR out at once, and a drop of rules and infrastructure is never enqueued again" {
  # rules beside a failure of the PR's own: out at once, every failure kept.
  ci_wait_ends '{"name": "test", "class": "pr", "kind": "failed", "link": "https://ci.example.invalid/test", "step": "Run tests"}' \
    '{"name": "CodeQL", "class": "rules", "kind": "missing", "link": null, "step": null}' \
    '{"name": "Analyze (python)", "class": "rules", "kind": "missing", "link": null, "step": null}'
  pr_at 0 OPEN
  pr_at 1 OPEN "$t1"
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 1
  assert_equal "$(end_json | jq -c '[.[0], .[2], [.[3][] | .class]]')" '["dequeued","CodeQL and Analyze (python) never reported on the trial commit, which dev'"'"'s rules require",["pr","rules","rules"]]'
  assert_equal "$(dequeues)" "-f pr=PR_kwDOtest5"
  # rules beside infrastructure, with a dequeue GitHub refuses: tried again at each look, and when
  # the queue drops the PR meanwhile it is not enqueued again, as infrastructure alone would be.
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/enqueues "$GH_DIR"/dequeues "$GH_DIR"/pr.*
  ci_wait_ends '{"name": "data", "class": "infrastructure", "kind": "setup", "link": "https://ci.example.invalid/data", "step": "Set up job"}' \
    '{"name": "Analyze (python)", "class": "rules", "kind": "missing", "link": null, "step": null}'
  answer 0 dequeue "refuse: Pull request cannot be dequeued now"
  pr_at 0 OPEN
  pr_at 1 OPEN "$t1"
  pr_at 3 OPEN '' RMQE_1 "failed checks"
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(end_json | jq -c '[.[0], .[2], [.[3][] | .class]]')" '["dequeued","failed checks; Analyze (python) never reported on the trial commit, which dev'"'"'s rules require",["infrastructure","rules"]]'
  assert_equal "$(dequeues | wc -l)" 2
  assert_equal "$(enqueues)" "-f pr=PR_kwDOtest5 -f head=$head"
  [[ $output != *"enqueued $url at a1b2c3d once more"* ]]
}

@test "a PR already in the queue is waited on with no second enqueue, and one already merged ends merged at once" {
  pr_at 0 OPEN "$t1"
  trial_checks 0 "$t1" "$(check_run test in_progress)"
  pr_at 2 MERGED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 2
  assert_equal "${lines[0]}" "team-land: $url is already in the merge queue: waiting on it, with no second enqueue"
  assert_equal "$(end_json)" "[\"merged\",\"$merge\",null,[]]"
  assert_equal "$(enqueues)" ""
  assert_equal "$(posted_on)" "--merge-group $url $t1"
  echo 0 >"$GH_DIR/look"
  pr_at 0 MERGED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 0
  assert_equal "$(end_json)" "[\"merged\",\"$merge\",null,[]]"
  assert_equal "$(enqueues)" ""
  assert_equal "$(posted_on | wc -l)" 1
}

@test "at the deadline it exits 75, waiting, with the PR left in the queue, and a rerun goes on waiting" {
  pr_at 0 OPEN "$t1"
  trial_checks 0 "$t1" "$(check_run test in_progress)"
  TEAM_LAND_DEADLINE_SECONDS=0 run_bin team-land "$url" "$head"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 0
  assert_equal "$(end_json)" "[\"waiting\",null,\"$url is still in the merge queue after 0 minutes: run team-land again to go on waiting\",[]]"
  assert_contains "$output" "team-land: the checks of the trial commit 5e5e5e5: deadline"
  assert_equal "$(enqueues)" ""
  # A PR it enqueued itself is left there too.
  pr_at 0 OPEN
  TEAM_LAND_DEADLINE_SECONDS=0 run_bin team-land "$url" "$head"
  assert_equal "$status" 75
  assert_equal "$(jq -r '.[0]' <<<"$(end_json)")" waiting
  assert_equal "$(enqueues)" "-f pr=PR_kwDOtest5 -f head=$head"
  # The team holding offline is a wait too, before GitHub is read.
  rm "$GH_DIR/calls" "$GH_DIR/enqueues"
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$HOME/.local/state/agent-team/offline"
  run_bin team-land "$url" "$head"
  assert_equal "$status" 75
  assert_equal "$(jq -r '.[0]' <<<"$(end_json)")" waiting
  assert_contains "$(jq -r '.[2]' <<<"$(end_json)")" "GitHub is unreachable (since "
  [[ ! -e $GH_DIR/calls ]]
  rm "$HOME/.local/state/agent-team/offline"
  TEAM_LAND_DEADLINE_SECONDS=x run_bin team-land "$url" "$head"
  assert_equal "$status" 2
}

@test "an agent-review that cannot be posted is tried again at each look, and named in the reason when the queue drops the PR" {
  pr_at 0 OPEN "$t1"
  trial_checks 0 "$t1" "$(check_run test in_progress)"
  stub_script team-review-status <<'SH'
if (($(cat "$GH_DIR/look") < 2)); then
  echo "team-review-status: the merge queue entry of owner/proj#5 cannot be read: gh api graphql: HTTP 502; nothing set" >&2
  exit 75
fi
echo "agent-review success"
SH
  pr_at 4 MERGED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 4
  # Said once, tried at looks 0, 1 and 2, and waited on only once posted.
  assert_equal "$(grep -c "agent-review was not posted" <<<"$output")" 1
  assert_contains "$output" "team-land: agent-review was not posted on the trial commit 5e5e5e5: the merge queue entry of owner/proj#5 cannot be read: gh api graphql: HTTP 502; nothing set; trying again at each look"
  assert_equal "$(posted_on | wc -l)" 3
  assert_contains "$output" "team-land: set agent-review success on the trial commit 5e5e5e5"
  # Never posted: no wait on its checks, and the drop names why. With no removal shown by GitHub,
  # the PR is taken as dropped after 2 minutes of looks.
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/pr.* "$GH_DIR/calls"
  pr_at 0 OPEN "$t1"
  pr_at 2 OPEN ''
  poster team-review-status "" 75
  rm -f "$STUB_FIXTURES/team-review-status.sh"
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 6
  assert_equal "$(end_json)" '["dequeued",null,"GitHub shows no removal and no reason; agent-review was not posted on the trial commit 5e5e5e5: team-review-status failed",[]]'
  if grep check-runs "$GH_DIR/calls"; then return 1; fi
  assert_equal "$(dequeues)" ""
}

@test "an agent-review the poster refuses on a trial commit takes the PR out of the queue and ends dequeued, unless the entry moved on" {
  pr_at 0 OPEN "$t1"
  stub_script team-review-status <<'SH'
echo "team-review-status: 5e5e5e5 changes more than the merge of its parents; nothing set" >&2
exit 1
SH
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 0
  assert_equal "$(end_json)" '["dequeued",null,"agent-review was not posted on the trial commit 5e5e5e5: 5e5e5e5 changes more than the merge of its parents; nothing set",[]]'
  assert_contains "$output" "team-land: took $url out of the merge queue: agent-review was not posted on the trial commit 5e5e5e5"
  assert_equal "$(dequeues)" "-f pr=PR_kwDOtest5"
  assert_equal "$(posted_on | wc -l)" 1
  # A PR GitHub does not let out is said once, and tried again at each look, until the queue ends it.
  rm "$GH_DIR/dequeues"
  answer 0 dequeue "refuse: the pull request is locked"
  pr_at 3 OPEN '' RMQE_1 "the checks timed out"
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 3
  assert_equal "$(grep -c "could not be taken out of the merge queue (gh api graphql: the pull request is locked); trying again at each look" <<<"$output")" 1
  assert_equal "$(dequeues | wc -l)" 3
  # The entry on another trial commit by the time it is read again: the refusal was of a commit
  # the queue left, so nothing is taken out, and the next look posts on the new one.
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/pr.* "$GH_DIR/dequeues" "$STUB_CALLS/team-review-status.log"
  answer 0 dequeue '{"data": {"dequeuePullRequest": {"mergeQueueEntry": {"id": "MQE_1"}}}}'
  pr_at 0 OPEN "$t1"
  stub_script team-review-status <<SH
if [[ \$3 == $t1 ]]; then
  cp "$GH_DIR/pr.moved" "$GH_DIR/pr.0"
  echo "team-review-status: 5e5e5e5 is not the trial commit of owner/proj#5's queue entry, which is 6f6f6f6; nothing set" >&2
  exit 1
fi
echo "agent-review success"
SH
  pr_at 0 OPEN "$t2"
  mv "$GH_DIR/pr.0" "$GH_DIR/pr.moved"
  pr_at 0 OPEN "$t1"
  trial_checks 0 "$t2" "$(check_run test in_progress)"
  pr_at 2 MERGED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(dequeues)" ""
  assert_equal "$(posted_on)" "--merge-group $url $t1
--merge-group $url $t2"
}

@test "with --task the merge is held again before each trial commit's agent-review, and one that no longer holds takes the PR out of the queue" {
  # Held on each new trial commit, once each, and posted on while it holds.
  poster team-merge ""
  pr_at 0 OPEN "$t1"
  trial_checks 0 "$t1" "$(check_run test in_progress)"
  pr_at 2 OPEN "$t2"
  trial_checks 2 "$t2" "$(check_run test in_progress)"
  pr_at 4 MERGED
  run_bin team-land --task T14 "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(stub_calls team-merge | jq -r 'join(" ")')" "T14 --pr $url --holds $head
T14 --pr $url --holds $head"
  assert_equal "$(posted_on | wc -l)" 2
  assert_equal "$(dequeues)" ""
  # The word withdrawn while it waited: the second trial commit gets no agent-review, and the PR
  # is taken out of the queue with team-merge's reasons.
  echo 0 >"$GH_DIR/look"
  rm "$STUB_CALLS/team-merge.log" "$STUB_CALLS/team-review-status.log"
  stub_script team-merge <<'SH'
if (($(cat "$GH_DIR/look") < 2)); then exit 0; fi
{
  echo "team-merge: T14 cannot merge PR #5, so nothing changed:"
  echo "  Daniel withdrew the default word for T14 at 2026-11-15T10:00:00Z"
  echo "  the latest review of a1b2c3d has findings"
  echo "  (Daniel's default word does not hold: ask them for the per-head word)"
} >&2
exit 1
SH
  run_bin team-land --task T14 "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 2
  assert_equal "$(end_json)" '["dequeued",null,"the merge of T14 does not hold now, so agent-review is not posted on the trial commit 6f6f6f6: Daniel withdrew the default word for T14 at 2026-11-15T10:00:00Z; the latest review of a1b2c3d has findings",[]]'
  assert_equal "$(posted_on)" "--merge-group $url $t1"
  assert_equal "$(dequeues)" "-f pr=PR_kwDOtest5"
  # A merge that cannot be told now (GitHub unread) posts nothing and takes nothing out: held
  # again at each look, said once.
  echo 0 >"$GH_DIR/look"
  rm "$STUB_CALLS/team-review-status.log" "$GH_DIR/dequeues" "$GH_DIR"/pr.*
  stub_script team-merge <<'SH'
if (($(cat "$GH_DIR/look") >= 2)); then exit 0; fi
{
  echo "team-merge: T14 cannot merge PR #5, so nothing changed:"
  echo "  GitHub cannot be read: gh pr view: error connecting to api.github.com"
} >&2
exit 75
SH
  pr_at 0 OPEN "$t1"
  pr_at 3 MERGED
  run_bin team-land --task T14 "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(grep -c "whether the merge of T14 still holds cannot be told now: GitHub cannot be read: gh pr view: error connecting to api.github.com; trying again at each look" <<<"$output")" 1
  assert_equal "$(posted_on)" "--merge-group $url $t1"
  assert_equal "$(dequeues)" ""
  # Without --task nothing is held: the landing alone, as the drill runs it.
  run_bin -2 team-land --task 14 "$url" "$head"
}

@test "at the deadline the reason says where the PR was at the last look: not shown in the queue, or GitHub unread" {
  pr_at 0 OPEN
  answer 1 pr fail
  TEAM_LAND_DEADLINE_SECONDS=0 run_bin team-land "$url" "$head"
  assert_equal "$status" 75
  assert_equal "$(end_json)" "[\"waiting\",null,\"$url is not shown in the merge queue after 0 minutes: run team-land again to go on waiting\",[]]"
  # The first look reads the queued PR; the deadline, 10 seconds on, which the stub sleep really
  # waits so a slow first look stays ahead of it, comes on a look GitHub does not answer.
  rm "$GH_DIR"/pr.*
  pr_at 0 OPEN none
  answer 1 pr fail
  local real_sleep
  real_sleep=$(PATH=/usr/bin:/bin command -v sleep)
  stub_script sleep <<EOF
echo \$((\$(cat "$GH_DIR/look") + 1)) >"$GH_DIR/look"
exec "$real_sleep" 10
EOF
  TEAM_LAND_DEADLINE_SECONDS=10 run_bin team-land "$url" "$head"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 1
  assert_equal "$(end_json)" "[\"waiting\",null,\"GitHub could not be read at the last look, so whether $url is in the merge queue is not known, after 0 minutes: run team-land again to go on waiting\",[]]"
}

@test "refused, exit 1, with nothing enqueued: a head that is not the PR's, a closed PR, a PR GitHub cannot read, and an enqueue GitHub refuses" {
  PR_HEAD=$t2 pr_at 0 OPEN
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(end_json)" "[\"refused\",null,\"the head of $url is 6f6f6f6, not a1b2c3d: nothing enqueued\",[]]"
  pr_at 0 CLOSED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(end_json)" "[\"refused\",null,\"$url is closed: nothing enqueued\",[]]"
  answer 0 pr fail
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(end_json)" '["refused",null,"GitHub cannot be read: gh api graphql: error connecting to api.github.com: nothing enqueued",[]]'
  answer 0 pr '{"data": {"repository": {"pullRequest": null}}}'
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(end_json)" '["refused",null,"GitHub cannot be read: gh api graphql: no such pull request: nothing enqueued",[]]'
  assert_equal "$(enqueues)" ""
  # GitHub refuses the enqueue where gh pr merge would turn auto-merge on: checks still pending.
  pr_at 0 OPEN
  answer 0 enqueue "refuse: Required status check \"test\" is expected."
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(end_json)" '["refused",null,"GitHub refused to enqueue https://github.com/owner/proj/pull/5 at a1b2c3d: Required status check \"test\" is expected.",[]]'
  assert_equal "$(ended_at)" 0
  assert_equal "$(posted_on)" ""
}

@test "a worker session is refused before anything is read, and a malformed command line exits 2" {
  pr_at 0 OPEN
  local role
  for role in planner builder reviewer ops; do
    AGENT_TEAM_ROLE=$role run_bin team-land "$url" "$head"
    assert_equal "$status" 1
    assert_equal "$output" "team-land: a $role session lands no PR: that is the coordinator's; send it your message"
  done
  run_bin team-land "$url"
  assert_equal "$status" 2
  run_bin team-land "$url" a1b2c3d
  assert_equal "$status" 2
  assert_contains "$output" "the head is a full 40-hex commit sha"
  run_bin team-land https://github.com/owner/proj/issues/5 "$head"
  assert_equal "$status" 2
  run_bin team-land https://github.com/other/repo/pull/5 "$head"
  assert_equal "$status" 1
  assert_contains "$output" "other/repo is no registered project's repo"
  [[ ! -e $GH_DIR/calls ]]
  # The coordinator's own session lands.
  pr_at 0 MERGED
  AGENT_TEAM_ROLE=coordinator run_bin team-land "$url" "$head"
  assert_equal "$status" 0
}

@test "on the project whose agent-review the reviewer App posts, each trial commit gets the App's check run, a failed revoke aside" {
  # A code checkout whose origin is the project's, in place of setup's bare copy of bin/.
  rm -r "${CODE_CHECKOUT:?}"
  unset CODE_CHECKOUT
  code_checkout
  git -C "${CODE_CHECKOUT:?}" remote set-url origin git@github.com:owner/proj.git
  review_app_on
  poster team-review-status "" 1
  pr_at 0 OPEN "$t1"
  trial_checks 0 "$t1" "$(check_run test in_progress)"
  pr_at 2 OPEN "$t2"
  trial_checks 2 "$t2" "$(check_run test in_progress)"
  pr_at 4 MERGED
  # The second post's token revoke fails after the check run's id: posted all the same.
  stub_script team-review-check <<'SH'
if [[ $3 == 5e5e5e5* ]]; then echo 4242; exit 0; fi
echo 4243
echo "team-review-check: the installation token could not be revoked: HTTP 500" >&2
exit 1
SH
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(end_json)" "[\"merged\",\"$merge\",null,[]]"
  assert_equal "$(posted_on team-review-check)" "--merge-group $url $t1
--merge-group $url $t2"
  assert_equal "$(posted_on team-review-status)" ""
  assert_contains "$output" "team-land: posted agent-review success on the trial commit 5e5e5e5 as the reviewer App's check run 4242"
  assert_contains "$output" "team-land: posted agent-review success on the trial commit 6f6f6f6 as the reviewer App's check run 4243, but the installation token could not be revoked: HTTP 500"
}

@test "a PR found merged at another head than the one it lands is refused, never reported merged at that head" {
  pr_at 0 OPEN "$t1"
  trial_checks 0 "$t1" "$(check_run test in_progress)"
  PR_HEAD=$t2 pr_at 1 MERGED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(end_json)" "[\"refused\",null,\"$url was merged at 6f6f6f6, not at the head a1b2c3d this run lands: check it on GitHub\",[]]"
}

@test "with the real team-review-status, a trial commit that is the reviewed head merged cleanly gets the status and the PR lands; one that is not gets none and leaves the queue" {
  ln -f "$BATS_RUN_TMPDIR/shared/bin/team-review-status" "$CODE_CHECKOUT/bin/team-review-status"
  queue_repo proj
  land_gh
  jq -cn --arg url "$url" --arg head "$QUEUE_HEAD" '
    {task: "T9", event: "opened", project: "proj"},
    {task: "T9", event: "pr", url: $url, project: "proj", head: $head},
    {task: "T9", event: "review", verdict: "pass", head: $head, ts: "2026-11-14T09:00:00Z"}' >>"$TEAM_HOME/ledger.jsonl"
  head=$QUEUE_HEAD
  local trial bad
  trial=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD")
  # team-review-status reads the entry through its own query, whose answer names the base too.
  entry_at() {
    answer "$1" pr "$(jq -c --arg base "$QUEUE_BASE" '.data.repository.pullRequest.mergeQueueEntry.baseCommit = {oid: $base}' "$GH_DIR/pr.$1")"
  }
  pr_at 0 OPEN "$trial"
  entry_at 0
  trial_checks 0 "$trial" "$(check_run test in_progress)"
  pr_at 2 MERGED
  run_bin team-land "$url" "$head"
  assert_equal "$status" 0
  assert_equal "$(end_json)" "[\"merged\",\"$merge\",null,[]]"
  assert_contains "$output" "team-land: set agent-review success on the trial commit ${trial:0:7}"
  assert_equal "$(grep -c "^api --method " "$GH_DIR/calls")" 1
  grep -Fxq "api --method description=the merge queue's clean merge of the reviewed head ${QUEUE_HEAD:0:7}" "$GH_DIR/calls"
  # A trial commit that holds more than the merge: no status, and the PR is taken out of the
  # queue, naming it.
  echo 0 >"$GH_DIR/look"
  rm "$GH_DIR"/pr.* "$GH_DIR/calls"
  bad=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD" "$QUEUE_HEAD")
  pr_at 0 OPEN "$bad"
  entry_at 0
  run_bin team-land "$url" "$head"
  assert_equal "$status" 1
  assert_equal "$(dequeues)" "-f pr=PR_kwDOtest5"
  assert_equal "$(end_json)" "[\"dequeued\",null,\"agent-review was not posted on the trial commit ${bad:0:7}: ${bad:0:7} changes more than the merge of its parents; nothing set\",[]]"
  if grep "^api --method " "$GH_DIR/calls"; then return 1; fi
}
