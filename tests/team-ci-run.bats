#!/usr/bin/env bats
# team-ci-run: finds the workflow run of the head a builder pushed, or starts one on its branch,
# then waits on it with the real team-ci-wait --run, on a stub gh answered by look and a stub sleep
# that steps the looks.

load helpers/common
load helpers/github-api

setup() {
  sandbox
  printf '%s\n' '[proj]' 'repo = "owner/proj"' 'path = "projects/proj"' 'base = "dev"' 'delivery = "direct-pr"' \
    'merge_method = "squash"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    'changed_tests = "the tests you changed"' 'branch_ci = "ci.yml"' \
    '[proj.pool]' 'provider = "git"' 'slots = ["slots/proj/1"]' \
    '[plain]' 'repo = "owner/plain"' 'path = "projects/plain"' 'base = "dev"' 'delivery = "direct-pr"' \
    'merge_method = "squash"' 'required_checks = []' 'task_dir = ".scratch/task"' 'docs = []' 'toolkits = []' \
    '[plain.pool]' 'provider = "git"' 'slots = ["slots/plain/1"]' >"$TEAM_HOME/projects.toml"
  head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
  other=9999999988888888777777776666666655555555
  branch=ci/T1-work--02
  run_url=https://github.com/owner/proj/actions/runs/7001
  export GH_DIR=$BATS_TEST_TMPDIR/gh HEAD_SHA=$head BRANCH_NAME=$branch
  mkdir -p "$GH_DIR"
  echo 0 >"$GH_DIR/look"
  github_stub_setup
  # team-ci-wait reads GitHub again at each look, with no time passing but the stub sleep's.
  export TEAM_GITHUB_FRESH_SECONDS=0
  stub_gh
  stub_sleep
  # Origin's branch at the head, no open PR of it, no run of the head, an idle repository, and a gh
  # that prints the run it starts.
  listed 0
  branch_at 0 "$head"
  prs 0
  dispatch 0 "url 7001"
  answer 0 running '{"total_count": 0, "workflow_runs": []}'
}

# answer <look> <what> <answer>: from look <look> on, gh answers <what> (list, branch, prs, dispatch,
# running, run-<run id>, jobs-<run id> or job-<job id>) with <answer>: JSON, or "fail" (gh cannot
# reach GitHub); for branch also "missing" (a 404), and for dispatch "url <run id>" (gh prints the
# run's URL), "quiet" (gh prints none) or "refused" (GitHub refuses the dispatch).
answer() {
  printf '%s\n' "$3" >"$GH_DIR/$2.$1"
}

# a_run <id> <event> <status> [<conclusion> [<head> [<branch>]]]: one workflow run as gh api shows it.
a_run() {
  jq -cn --argjson id "$1" --arg event "$2" --arg status "$3" --arg conclusion "${4:-}" --arg head "${5:-$head}" \
    --arg branch "${6:-$branch}" '{id: $id, event: $event, status: $status,
    conclusion: (if $conclusion == "" then null else $conclusion end), head_sha: $head, head_branch: $branch,
    html_url: "https://github.com/owner/proj/actions/runs/\($id)", updated_at: "2026-10-30T18:52:11Z", name: "CI",
    display_title: "OUTPUT-MARKER"}'
}

# listed <look> <run>...: the workflow's runs of the head as gh api lists them, from <look> on.
listed() {
  local look=$1
  shift
  answer "$look" list "$(jq -cs '{total_count: length, workflow_runs: .}' <<<"$*")"
}

# the_run <look> <run>: the run as gh api shows it by its id, from <look> on.
the_run() {
  answer "$1" "run-$(jq -r .id <<<"$2")" "$2"
}

# run_jobs <look> <run id> [<name>:<status>:<conclusion>:<job id>]...: the run's jobs, from <look> on.
run_jobs() {
  local look=$1 id=$2
  shift 2
  answer "$look" "jobs-$id" "$(jq -cn --arg run "$id" '{jobs: [$ARGS.positional[] | split(":")
    | {id: (.[3] | tonumber), name: .[0], status: .[1], conclusion: (if .[2] == "" then null else .[2] end),
       html_url: "https://github.com/owner/proj/actions/runs/\($run)/job/\(.[3])", runner_name: "GitHub Actions 1",
       steps: []}]}' --args "$@")"
}

# branch_at <look> <sha>|missing|fail: origin's branch, from <look> on.
branch_at() {
  case $2 in
    missing | fail) answer "$1" branch "$2" ;;
    *) answer "$1" branch "$(jq -cn --arg sha "$2" --arg name "$branch" '{name: $name, commit: {sha: $sha}}')" ;;
  esac
}

# prs <look> [<number>:<head>]...: the branch's open PRs, from <look> on.
prs() {
  local look=$1
  shift
  answer "$look" prs "$(jq -cn '[$ARGS.positional[] | split(":") | {number: (.[0] | tonumber), headRefOid: .[1]}]' --args "$@")"
}

# dispatch <look> <how>: what gh workflow run does, from <look> on.
dispatch() {
  answer "$1" dispatch "$2"
}

# A green run 7001 of the head, from <look> on: completed, its one job passed.
green() {
  the_run "$1" "$(a_run 7001 "${2:-workflow_dispatch}" completed success)"
  run_jobs "$1" 7001 lint:completed:success:70
}

# gh answers each read and the dispatch from the latest answer at or before the current look:
# team-ci-run's own reads as gh prints them, and team-ci-wait's, through the reader (gh api -i),
# in gh api -i's form through tests/helpers/github-api.bash, a 304 when the read sends the
# answer's ETag. Anything unplanned fails, a dispatch of another workflow, repo or branch among
# them.
stub_gh() {
  stub_script gh <<'EOF'
source "$GITHUB_STUB_HELPER"
github_request "$@"
n=$(cat "$GH_DIR/look")
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
case "$*" in
  "api repos/owner/proj/actions/workflows/ci.yml/runs?head_sha=$HEAD_SHA&per_page=100") what=list ;;
  "api repos/owner/proj/branches/$BRANCH_NAME") what=branch ;;
  "pr list --repo owner/proj --head $BRANCH_NAME --state open --json number,headRefOid") what=prs ;;
  "workflow run ci.yml --repo owner/proj --ref $BRANCH_NAME") what=dispatch ;;
  "api repos/owner/proj/actions/runs?status=in_progress&per_page=1") what=running ;;
  "api repos/owner/proj/actions/runs/"*"/jobs?per_page=100") what=${2%/jobs*} what=jobs-${what##*/} ;;
  "api repos/owner/proj/actions/runs/"*) what=run-${2##*/} ;;
  "api repos/owner/proj/actions/jobs/"*) what=job-${2##*/} ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
m=$n
while ((m >= 0)) && [[ ! -e $GH_DIR/$what.$m ]]; do m=$((m - 1)); done
if ((m < 0)); then echo "no answer planned for $what at look $n" >&2; exit 1; fi
body=$(cat "$GH_DIR/$what.$m")
if $raw; then
  [[ $body != fail ]] || github_offline
  github_answer 200 "$body"
fi
case $body in
  fail) echo "error connecting to api.github.com" >&2; echo "check your internet connection" >&2; exit 1 ;;
  missing) echo '{"message": "Branch not found", "status": "404"}'; echo "gh: Branch not found (HTTP 404)" >&2; exit 1 ;;
  refused) echo "could not create workflow dispatch event: HTTP 422: Workflow does not have 'workflow_dispatch' trigger" >&2; exit 1 ;;
  quiet) echo "✓ Created workflow_dispatch event for ci.yml at $BRANCH_NAME" ;;
  "url "*)
    echo "✓ Created workflow_dispatch event for ci.yml at $BRANCH_NAME"
    echo "https://github.com/owner/proj/actions/runs/${body#url }"
    ;;
  *) printf '%s\n' "$body" ;;
esac
EOF
}

# The stub sleep moves on to the next look, and the reader's clock on by its seconds, and, after
# LOOK_LIMIT looks (default 200), stops the wait with exit 99, so a wait that never ends shows as
# that exit. The uname stub keeps it ahead of Homebrew's GNU sleep on macOS.
stub_sleep() {
  stub_command sleep uname
  stub_reply uname Linux
  stub_script sleep <<EOF
n=\$(cat "$GH_DIR/look")
((n < \${LOOK_LIMIT:-200})) || exit 99
echo \$((n + 1)) >"$GH_DIR/look"
echo \$((\$(cat "\$TEAM_GITHUB_CLOCK") + \$1)) >"\$TEAM_GITHUB_CLOCK"
EOF
}

# The look the command ended at.
ended_at() {
  cat "$GH_DIR/look"
}

# Each gh call made, its arguments on one line, with the reader's -i and its -H header left out.
gh_calls() {
  stub_calls gh | jq -r '. as $a | [range(length) | select($a[.] != "-i" and $a[.] != "-H" and (. == 0 or $a[. - 1] != "-H"))
    | $a[.]] | join(" ")'
}

# The runs gh was asked to start, one line each.
dispatches() {
  gh_calls | grep '^workflow run' || true
}

@test "with no run and no PR, origin at the head: it starts one run on the branch and waits on the run gh prints, to team-ci-wait's end" {
  the_run 0 "$(a_run 7001 workflow_dispatch in_progress)"
  run_jobs 0 7001 lint:in_progress::70
  green 3
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 3
  assert_equal "$output" "team-ci-run: waiting on $run_url (workflow_dispatch, started) of a1b2c3d
team-ci-wait: waiting on CI run 7001 of owner/proj at a1b2c3d
team-ci-wait: every check passed on a1b2c3d: lint passed"
  assert_equal "$(dispatches)" "workflow run ci.yml --repo owner/proj --ref $branch"
  # Before it starts the run it reads the head's runs, origin's branch and the branch's open PRs, once each.
  assert_equal "$(gh_calls | sed -n '1,4p')" "api repos/owner/proj/actions/workflows/ci.yml/runs?head_sha=$head&per_page=100
api repos/owner/proj/branches/$branch
pr list --repo owner/proj --head $branch --state open --json number,headRefOid
workflow run ci.yml --repo owner/proj --ref $branch"
}

@test "a red run ends exit 1 with team-ci-wait's text, the failure the branch's own" {
  the_run 0 "$(a_run 7001 workflow_dispatch completed failure)"
  run_jobs 0 7001 lint:completed:success:70 test:completed:failure:71
  answer 0 job-71 '{"id": 71, "runner_name": "GitHub Actions 1", "steps": [{"name": "Run tests/run bats", "number": 1, "status": "completed", "conclusion": "failure"}]}'
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-run: waiting on $run_url (workflow_dispatch, started) of a1b2c3d
team-ci-wait: waiting on CI run 7001 of owner/proj at a1b2c3d
team-ci-wait: the checks on a1b2c3d did not pass:
  the branch's: test failed: https://github.com/owner/proj/actions/runs/7001/job/71"
}

@test "a run of the head that exists is waited on with no dispatch, the newest by id, of any event and branch" {
  listed 0 "$(a_run 6990 pull_request completed failure)" "$(a_run 7001 workflow_dispatch in_progress)" \
    "$(a_run 6995 workflow_dispatch completed success)"
  green 0
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "${lines[0]}" "team-ci-run: waiting on $run_url (workflow_dispatch, found) of a1b2c3d"
  assert_contains "$output" "team-ci-wait: every check passed on a1b2c3d: lint passed"
  assert_equal "$(dispatches)" ""
  # A found run ends the looking: nothing of origin's branch or its PRs is read.
  if gh_calls | grep -e branches -e '^pr list'; then return 1; fi
  # A PR's run of the same commit on another branch is a run of the head too.
  listed 0 "$(a_run 7001 pull_request completed success "$head" feat/T1-work)"
  green 0 pull_request
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "${lines[0]}" "team-ci-run: waiting on $run_url (pull_request, found) of a1b2c3d"
  assert_equal "$(dispatches)" ""
}

@test "a run GitHub lists of another head is no run of the head" {
  listed 0 "$(a_run 6990 push completed success "$other")"
  green 0
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "${lines[0]}" "team-ci-run: waiting on $run_url (workflow_dispatch, started) of a1b2c3d"
}

@test "a second call after exit 75 waits on the same run and starts no second one" {
  the_run 0 "$(a_run 7001 workflow_dispatch in_progress)"
  run_jobs 0 7001 lint:in_progress::70
  answer 1 run-7001 fail
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 75
  assert_contains "$output" "team-ci-wait: GitHub could not be read for 5 minutes running: "
  at=$(ended_at)
  listed "$at" "$(a_run 7001 workflow_dispatch completed success)"
  green "$at"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "${lines[0]}" "team-ci-run: waiting on $run_url (workflow_dispatch, found) of a1b2c3d"
  assert_equal "$(dispatches | wc -l)" 1
}

@test "an open PR at the head whose run comes at a later look starts none" {
  prs 0 217:"$head"
  listed 3 "$(a_run 7001 pull_request in_progress)"
  the_run 3 "$(a_run 7001 pull_request in_progress)"
  run_jobs 3 7001 lint:in_progress::70
  green 5 pull_request
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 5
  assert_equal "${lines[0]}" "team-ci-run: waiting on $run_url (pull_request, found) of a1b2c3d"
  assert_equal "$(dispatches)" ""
}

@test "an open PR still shown at its old head, origin's branch at the new one: no run is started, and the PR's run of the head is waited on" {
  # GitHub may show the branch at a pushed head a moment before the PR's head follows.
  prs 0 12:"$other"
  prs 1 12:"$head"
  listed 2 "$(a_run 7001 pull_request completed success)"
  green 2 pull_request
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 2
  assert_equal "${lines[0]}" "team-ci-run: waiting on $run_url (pull_request, found) of a1b2c3d"
  assert_equal "$(dispatches)" ""
}

@test "an open PR of the branch whose run of the head never comes within the grace gets one started" {
  prs 0 217:"$head"
  green 0
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  # 2 minutes of looks, one every 10 seconds, then the dispatch at the 13th.
  assert_equal "$(ended_at)" 12
  assert_equal "${lines[0]}" "team-ci-run: waiting on $run_url (workflow_dispatch, started) of a1b2c3d"
  assert_equal "$(dispatches)" "workflow run ci.yml --repo owner/proj --ref $branch"
  # An open PR of the branch that stays at another head holds the start for the grace too.
  prs 0 217:"$other"
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 12
}

@test "TEAM_CI_RUN_GRACE_SECONDS replaces the grace's seconds, and must be a number" {
  prs 0 217:"$head"
  green 0
  TEAM_CI_RUN_GRACE_SECONDS=30 run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 3
  TEAM_CI_RUN_GRACE_SECONDS=soon run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 2
  assert_equal "$output" "team-ci-run: TEAM_CI_RUN_GRACE_SECONDS must be a number of seconds"
}

@test "origin's branch at another head, or no such branch, ends exit 1 after the grace naming both, with no dispatch" {
  branch_at 0 "$other"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 12
  assert_equal "$output" "team-ci-run: origin's $branch is at 9999999, not a1b2c3d: push that head, then run team-ci-run again"
  assert_equal "$(dispatches)" ""
  branch_at 0 missing
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 12
  assert_equal "$output" "team-ci-run: origin has no branch $branch, not a1b2c3d: push that head, then run team-ci-run again"
  assert_equal "$(dispatches)" ""
}

@test "a push GitHub shows only at a later look is waited for within the grace, then the run started" {
  branch_at 0 missing
  branch_at 2 "$other"
  branch_at 4 "$head"
  green 0
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 4
  assert_equal "$(dispatches)" "workflow run ci.yml --repo owner/proj --ref $branch"
}

@test "gh printing no run URL: the started run is the newest workflow_dispatch run of the head that a later look lists" {
  dispatch 0 quiet
  listed 2 "$(a_run 7003 pull_request in_progress)" "$(a_run 7001 workflow_dispatch in_progress)" \
    "$(a_run 6000 workflow_dispatch completed success)"
  green 0
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 2
  assert_equal "${lines[0]}" "team-ci-run: waiting on $run_url (workflow_dispatch, started) of a1b2c3d"
  assert_equal "$(dispatches | wc -l)" 1
}

@test "gh printing no run URL and GitHub listing no started run of the head for a new grace ends exit 1, with one dispatch" {
  dispatch 0 quiet
  # The dispatch came after 3 looks of a PR's run awaited; the new grace counts from it.
  prs 0 217:"$head"
  TEAM_CI_RUN_GRACE_SECONDS=30 run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 1
  assert_equal "$(ended_at)" 6
  assert_equal "$output" "team-ci-run: started a run on $branch, but GitHub lists none of a1b2c3d after 30 seconds; run team-ci-run again"
  assert_equal "$(dispatches | wc -l)" 1
}

@test "a started run of another head is exit 1 naming the branch moved, with no wait" {
  the_run 0 "$(a_run 7001 workflow_dispatch queued "" "$other")"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-run: the run $run_url is of 9999999, not a1b2c3d: $branch moved; push your head and run team-ci-run again"
  if gh_calls | grep -e '/jobs' -e in_progress; then return 1; fi
}

@test "a dispatch GitHub refuses ends exit 1 with gh's reason, and is not tried again" {
  dispatch 0 refused
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-run: could not start a run on $branch: could not create workflow dispatch event: HTTP 422: Workflow does not have 'workflow_dispatch' trigger; run team-ci-run again, and report BLOCKED if it is refused again"
  assert_equal "$(dispatches | wc -l)" 1
}

@test "gh failing at every look for the grace is exit 75 with its reason, and a look that reads again ends the count" {
  answer 0 list fail
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 12
  assert_equal "$output" "team-ci-run: GitHub could not be read for 2 minutes running: gh api repos/owner/proj/actions/workflows/ci.yml/runs?head_sha=$head&per_page=100: error connecting to api.github.com"
  assert_equal "$(dispatches)" ""
  # Origin's branch unread is a failed look too, never "no such branch".
  listed 0
  branch_at 0 fail
  branch_at 5 "$head"
  green 0
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 0
  assert_equal "$(ended_at)" 5
  # The started run unread for the grace is exit 75 too; the next call finds it by the head.
  answer 0 run-7001 fail
  echo 0 >"$GH_DIR/look"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 75
  assert_contains "$output" "team-ci-run: GitHub could not be read for 2 minutes running: gh api repos/owner/proj/actions/runs/7001: error connecting"
}

@test "while the team holds offline, it ends at once with exit 75 and the hold, before any gh call" {
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"since": "2026-10-22T13:05:00Z", "posted": true}' >"$HOME/.local/state/agent-team/offline"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 75
  assert_equal "$output" "team-ci-run: GitHub is unreachable (since $(date -d 2026-10-22T13:05:00Z +%H:%M)); the team is holding: commit locally, write handoff.md, send T<n> PAUSED offline, and wait."
  assert_equal "$(gh_calls)" ""
}

@test "a hold that starts between two looks ends the looking with exit 75" {
  prs 0 217:"$head"
  stub_script sleep <<EOF
n=\$(cat "$GH_DIR/look")
echo \$((n + 1)) >"$GH_DIR/look"
if ((n == 1)); then echo '{"since": "2026-10-22T13:05:00Z"}' >"$HOME/.local/state/agent-team/offline"; fi
EOF
  mkdir -p "$HOME/.local/state/agent-team"
  run_bin team-ci-run proj "$branch" "$head"
  assert_equal "$status" 75
  assert_equal "$(ended_at)" 2
  assert_contains "$output" "team-ci-run: GitHub is unreachable (since "
  assert_equal "$(dispatches)" ""
}

@test "refused before any gh call: a project with no branch_ci, the base branch, main, an unregistered project and a malformed command line" {
  run_bin team-ci-run plain "$branch" "$head"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-run: plain runs no CI on a branch: projects.toml gives it no branch_ci"
  run_bin team-ci-run proj dev "$head"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-run: dev is proj's base branch: CI runs on a task's or a ticket's branch only"
  run_bin team-ci-run proj main "$head"
  assert_equal "$status" 1
  assert_equal "$output" "team-ci-run: main is no task's branch: CI runs on a task's or a ticket's branch only"
  run_bin team-ci-run nowhere "$branch" "$head"
  assert_equal "$status" 1
  usage="team-ci-run: usage: team-ci-run <project> <branch> <sha>, <sha> the full 40 hex characters of the head you pushed"
  run_bin team-ci-run proj "$branch" a1b2c3d
  assert_equal "$status" 2
  assert_equal "$output" "$usage"
  run_bin team-ci-run proj "$branch" "${head^^}"
  assert_equal "$status" 2
  run_bin team-ci-run proj "$branch"
  assert_equal "$status" 2
  assert_equal "$output" "$usage"
  run_bin team-ci-run proj "$branch" "$head" extra
  assert_equal "$status" 2
  run_bin team-ci-run --json proj "$branch" "$head"
  assert_equal "$status" 2
  run_bin team-ci-run proj "bad branch" "$head"
  assert_equal "$status" 2
  run_bin team-ci-run proj "-x" "$head"
  assert_equal "$status" 2
  assert_equal "$(gh_calls)" ""
}
