#!/usr/bin/env bats
# tests/merge-queue-drill, dry-run on stubs: the base commit --setup pushes, the sandbox team home
# the drill builds (its registry held to team-project --check, its ledger to team-log --check),
# the calls it makes to team-review-check, team-ci-wait and team-land, both landings started at
# once, its checks' verdicts on what the stub queue built, what it leaves in the scratch
# repository, and the merge-queue line it records in the team home's drills.jsonl through
# bin/team-drill. GitHub is a bare repository git reaches in place of https://github.com/ and a gh
# stub; the real drill opens and merges pull requests, which only the coordinator runs.
load helpers/common

setup() {
  sandbox
  # The drill runs from a code checkout of the test's own, whose bin/ has the reviewer App on
  # (id 123456, team-review-check the logging stub that prints check run 4242) and team-ci-wait
  # and team-land as stubs.
  code_checkout
  review_app_on
  mkdir -p "$CODE_CHECKOUT/tests"
  shared_make merge-queue-drill "$REPO_ROOT/tests/merge-queue-drill"
  ln "$BATS_RUN_TMPDIR/shared/merge-queue-drill" "$CODE_CHECKOUT/tests/merge-queue-drill"
  drill=$CODE_CHECKOUT/tests/merge-queue-drill
  for cmd in team-ci-wait team-land; do
    ln -f "$BATS_RUN_TMPDIR/shared/stub" "$CODE_CHECKOUT/bin/$cmd"
  done
  stub_reply team-ci-wait "team-ci-wait: the checks passed"
  # GitHub's repositories, which git reaches in place of https://github.com/.
  export GITHUB=$BATS_TEST_TMPDIR/github ORIGIN=$BATS_TEST_TMPDIR/github/org/scratch.git
  git init -q --bare -b dev "$ORIGIN"
  git config --global "url.$GITHUB/.insteadOf" https://github.com/
  export GH_DIR=$BATS_TEST_TMPDIR/gh
  mkdir -p "$GH_DIR"
  queue_rules MERGE 123456
  # The drill's sandbox lands here, so a test can see it is gone afterwards.
  sandboxes=$HOME/.cache/agent-team
  mkdir -p "$sandboxes"
  # team-drill names the machine it records on, and asks claude its version.
  mkdir -p "$HOME/.config/agent-team"
  echo home-pc >"$HOME/.config/agent-team/machine"
  stub_reply claude '2.1.321 (Claude Code)'
  # The listing of the queue's branches does not wait between its looks.
  stub_command sleep
  : >"$STUB_FIXTURES/sleep.out"

  # gh answers from GH_DIR and the bare repository: dev's rules (rules.json); pr create, which
  # numbers the pull requests from 8 and keeps each one's branch; pr view, by the files the
  # team-land stub leaves (pr-<n>.merge once merged, pr-<n>.closed once closed) and the branch's
  # tip; pr close; the deletion of a branch; the queue entry of a pull request not merged
  # (entry-<n>, its trial commit); a commit's check runs (runs-pr-<n>.json when it is PR <n>'s trial
  # commit, else runs.json: the check job, Analyze (actions) and the App's agent-review, each a
  # success) and its commit statuses (statuses-pr-<n>.json the same way, else none); and CodeQL's
  # default setup (default-setup.json, else not configured, or default-setup.error's text, exit 1).
  stub_script gh <<'SH'
jq_out() { # <json> <the call's arguments>: the json through the call's --jq
  local json=$1 filter=.
  shift
  while (($#)); do
    if [[ $1 == --jq ]]; then filter=$2; fi
    shift
  done
  jq -r "$filter" <<<"$json"
}
for_trial() { # <runs or statuses> <sha>: <kind>-pr-<n>.json of the PR whose trial commit it is, if any
  local f n
  for f in "$GH_DIR"/pr-*.merge "$GH_DIR"/entry-*; do
    [[ -e $f && $(<"$f") == "$2" ]] || continue
    n=${f##*/} n=${n#pr-} n=${n#entry-} n=${n%.merge}
    if [[ -e $GH_DIR/$1-pr-$n.json ]]; then echo "$GH_DIR/$1-pr-$n.json"; fi
    return 0
  done
}
pr_json() { # <n>
  local state=OPEN
  if [[ -e $GH_DIR/pr-$1.merge ]]; then state=MERGED; elif [[ -e $GH_DIR/pr-$1.closed ]]; then state=CLOSED; fi
  jq -cn --arg state "$state" --arg head "$(<"$GH_DIR/pr-$1.head")" '{state: $state, headRefOid: $head}'
}
case "$1 $2" in
  "api repos/org/scratch/rules/branches/dev")
    [[ ! -e $GH_DIR/rules.error ]] || { cat "$GH_DIR/rules.error" >&2; exit 1; }
    cat "$GH_DIR/rules.json"
    ;;
  "pr create")
    n=$(($(find "$GH_DIR" -name 'pr-*.branch' | wc -l) + 8))
    [[ ! -e $GH_DIR/create-fails-$n ]] || { echo "pull request create failed: GraphQL: No commits between dev and the branch" >&2; exit 1; }
    while (($#)); do
      if [[ $1 == --head ]]; then branch=$2; fi
      shift
    done
    printf '%s\n' "$branch" >"$GH_DIR/pr-$n.branch"
    git --git-dir="${ORIGIN:?}" rev-parse "refs/heads/$branch" >"$GH_DIR/pr-$n.head"
    echo "https://github.com/org/scratch/pull/$n"
    ;;
  "pr view") jq_out "$(pr_json "${3##*/}")" "$@" ;;
  "pr close") : >"$GH_DIR/pr-${3##*/}.closed" ;;
  "api --method")
    [[ $3 == DELETE && $4 == repos/org/scratch/git/refs/heads/* ]] || { echo "gh stub: no answer for $*" >&2; exit 99; }
    git --git-dir="${ORIGIN:?}" update-ref -d "refs/heads/${4#repos/org/scratch/git/refs/heads/}"
    ;;
  "api graphql")
    for arg; do
      if [[ $arg == number=* ]]; then n=${arg#number=}; fi
    done
    trial=''
    [[ ! -e $GH_DIR/entry-$n ]] || trial=$(<"$GH_DIR/entry-$n")
    jq_out "$(jq -cn --arg trial "$trial" '{data: {repository: {pullRequest: {mergeQueueEntry:
      (if $trial == "" then null else {headCommit: {oid: $trial}} end)}}}}')" "$@"
    ;;
  "api repos/org/scratch/code-scanning/default-setup")
    [[ ! -e $GH_DIR/default-setup.error ]] || { cat "$GH_DIR/default-setup.error" >&2; exit 1; }
    json='{"state": "not-configured", "languages": []}'
    [[ ! -e $GH_DIR/default-setup.json ]] || json=$(<"$GH_DIR/default-setup.json")
    jq_out "$json" "$@"
    ;;
  "api repos/org/scratch/commits/"*"/status?per_page=100")
    sha=${2#repos/org/scratch/commits/} sha=${sha%%/*}
    file=$(for_trial statuses "$sha")
    if [[ -n $file ]]; then cat "$file"; else echo '{"state": "pending", "statuses": []}'; fi
    ;;
  "api repos/org/scratch/commits/"*"/check-runs?filter=latest&per_page=100")
    sha=${2#repos/org/scratch/commits/} sha=${sha%%/*}
    file=$(for_trial runs "$sha")
    cat "${file:-$GH_DIR/runs.json}"
    ;;
  *) echo "gh stub: no answer for $*" >&2; exit 99 ;;
esac
SH
  check_runs 123456 CodeQL

  # team-land plays the queue on the bare repository. It keeps the team home it was given
  # (registry-<n>.check and registry-<n>.status, team-project --check's output and exit there;
  # registry-<n>.json, its project; ledger-<n>.jsonl; each landing its own files, since two run
  # at once), marks that it started
  # and waits until both landings have, then ends as $GH_DIR/land-<n> says (default merged):
  #   merged      it builds the trial commit, the head merged onto dev's tip, on a branch under
  #               gh-readonly-queue/dev/, moves dev to it and ends merged;
  #   swapped     the same with the parents the other way round;
  #   no-branch   merged, with no branch under gh-readonly-queue/;
  #   dequeued    it ends dequeued, exit 1, the pull request in no queue;
  #   waiting     it builds the trial commit on its branch, leaves the pull request in the queue
  #               on it (entry-<n>) and ends waiting, exit 75;
  #   silent      it prints no result.
  stub_script team-land <<'SH'
url=$1 head=$2 n=${1##*/}
git() { command git --git-dir="${ORIGIN:?}" "$@"; }
printf '%s\n' "$TEAM_HOME" >"$GH_DIR/land-$n.team-home"
printf '%s\n' "${TEAM_LAND_DEADLINE_SECONDS:-unset}" >"$GH_DIR/land-$n.deadline"
rc=0
TEAM_HOME=$TEAM_HOME "$CODE_CHECKOUT/bin/team-project" --check >"$GH_DIR/registry-$n.check" 2>&1 || rc=$?
printf '%s\n' "$rc" >"$GH_DIR/registry-$n.status"
TEAM_HOME=$TEAM_HOME "$CODE_CHECKOUT/bin/team-project" agent-team >"$GH_DIR/registry-$n.json"
cp "$TEAM_HOME/ledger.jsonl" "$GH_DIR/ledger-$n.jsonl"
: >"$GH_DIR/started-$n"
for ((i = 0; i < 100; i++)); do
  started=("$GH_DIR"/started-*)
  ((${#started[@]} < 2)) || break
  read -r -t 0.1 <> <(:) || true
done
((${#started[@]} == 2)) || { echo "team-land stub: the other landing never started" >&2; exit 3; }
mode=merged
[[ ! -e $GH_DIR/land-$n ]] || mode=$(<"$GH_DIR/land-$n")
result() { # <outcome> <merge or ''> <reason or ''>
  jq -cn --arg outcome "$1" --arg url "$url" --arg head "$head" --arg merge "$2" --arg reason "$3" '{schema: "team-land/1",
    outcome: $outcome, url: $url, head: $head, merge: (if $merge == "" then null else $merge end),
    reason: (if $reason == "" then null else $reason end), failed: []}'
}
trial() { # <mode>: the trial commit on dev's tip, on its queue branch unless no-branch
  local tip tree sha
  tip=$(git rev-parse refs/heads/dev)
  tree=$(git merge-tree --write-tree "$tip" "$head")
  if [[ $1 == swapped ]]; then
    sha=$(git commit-tree "$tree" -p "$head" -p "$tip" -m "Merge pull request #$n")
  else
    sha=$(git commit-tree "$tree" -p "$tip" -p "$head" -m "Merge pull request #$n")
  fi
  [[ $1 == no-branch ]] || git update-ref "refs/heads/gh-readonly-queue/dev/pr-$n-$tip" "$sha"
  echo "$sha"
}
echo "team-land: enqueued $url at ${head:0:7}"
case $mode in
  merged | swapped | no-branch)
    # One landing at a time moves dev, as the queue does.
    exec 9>"$GH_DIR/queue.lock"
    flock 9
    sha=$(trial "$mode")
    git update-ref refs/heads/dev "$sha"
    printf '%s\n' "$sha" >"$GH_DIR/pr-$n.merge"
    exec 9>&-
    echo "team-land: $url merged as ${sha:0:7}"
    result merged "$sha" ''
    ;;
  dequeued)
    echo "team-land: the merge queue dropped $url: the checks failed"
    result dequeued '' 'the checks failed'
    exit 1
    ;;
  waiting)
    trial waiting >"$GH_DIR/entry-$n"
    result waiting '' 'the deadline came with the PR still in the queue'
    exit 75
    ;;
  silent) exit 1 ;;
esac
SH
}

# queue_rules <merge method or ''> <the App id agent-review is pinned to, or ''> [<context>...]:
# dev's rules as GitHub lists them, a ruleset requiring check and Analyze (actions) from GitHub
# Actions, agent-review and each context named after, pinned to no App, with the merge queue unless
# the method is empty.
queue_rules() {
  jq -n --arg method "$1" --arg app "$2" '$ARGS.positional as $more
    | [{type: "deletion", ruleset_id: 42},
     {type: "required_status_checks", ruleset_id: 42, parameters: {strict_required_status_checks_policy: false,
       required_status_checks: ([{context: "check", integration_id: 15368}, {context: "Analyze (actions)", integration_id: 15368},
         ({context: "agent-review"} + (if $app == "" then {} else {integration_id: ($app | tonumber)} end))]
         + [$more[] | {context: .}])}}]
    + (if $method == "" then [] else [{type: "merge_queue", ruleset_id: 42, parameters: {merge_method: $method,
        grouping_strategy: "ALLGREEN", check_response_timeout_minutes: 120}}] end)' --args "${@:3}" >"$GH_DIR/rules.json"
}

# check_runs <the App id of agent-review> [CodeQL] [<file>]: a commit's check runs as GitHub lists
# them, the check job, Analyze (actions) and agent-review by that App, each a success, with the
# roll-up CodeQL when named; every commit's unless <file>, runs-pr-<n>.json, gives one PR's trial commit's.
check_runs() {
  jq -n --argjson app "$1" --arg codeql "${2:-}" '{check_runs: ([
    {name: "check", status: "completed", conclusion: "success", app: {id: 15368, slug: "github-actions"}},
    {name: "Analyze (actions)", status: "completed", conclusion: "success", app: {id: 15368, slug: "github-actions"}},
    {name: "agent-review", status: "completed", conclusion: "success", app: {id: $app, slug: "an-app"}}]
    + (if $codeql == "" then [] else [{name: "CodeQL", status: "completed", conclusion: "success",
        app: {id: 57789, slug: "github-advanced-security"}}] end))}' >"$GH_DIR/${3:-runs.json}"
}

# The scratch repository's dev holds the drill's base commit, as --setup pushes it.
set_up() {
  "$drill" --setup org/scratch >/dev/null
}

# old_base: the scratch repository's dev as --setup made it before the drill had a CodeQL
# workflow, the marker, the README and ci.yml, with a README of its own that --setup must keep.
old_base() {
  set_up
  local clone
  clone=$(mktemp -d "$BATS_TEST_TMPDIR/old-base.XXXXXX")
  git clone -q "$ORIGIN" "$clone" 2>/dev/null
  git -C "${clone:?}" rm -q .github/workflows/codeql.yml
  echo "A README Daniel edited." >"$clone/README.md"
  git -C "${clone:?}" commit -q -am "ci: the merge queue drill's base commit"
  git -C "${clone:?}" push -q origin HEAD:dev
}

# The team home's drill record, each line's fields but at.
drill_lines() {
  if [[ -e $TEAM_HOME/drills.jsonl ]]; then jq -c 'del(.at)' "$TEAM_HOME/drills.jsonl"; fi
}

# The one merge-queue line a run should have recorded, but at: drill_line <verdict> <detail>
drill_line() {
  jq -cn --arg commit "$(git -C "${CODE_CHECKOUT:?}" rev-parse HEAD)" --arg verdict "$1" --arg detail "$2" \
    '{drill: "merge-queue", machine: "home-pc", commit: $commit, dirty: false, claude: "2.1.321",
      verdict: $verdict, detail: $detail}'
}

# The branches of the scratch repository, one per line.
branches() {
  git --git-dir="${ORIGIN:?}" for-each-ref --format='%(refname:short)' refs/heads
}

# short <file of GH_DIR holding a sha>: its first seven characters.
short() {
  cut -c1-7 "$GH_DIR/$1"
}

@test "--help prints the header, and a malformed command line is refused with the usage" {
  run -0 "$drill" --help
  assert_equal "${lines[0]}" "The merge queue drill, run by hand: land two pull requests at once through the merge queue of a"
  assert_contains "$output" "Usage: tests/merge-queue-drill --setup <repo>
       tests/merge-queue-drill <repo>"
  local args
  for args in "" "--setup" "org/scratch extra" "scratch" "--dry org/scratch" "https://github.com/org/scratch"; do
    # shellcheck disable=SC2086 # the words of one command line
    run -2 "$drill" $args
    assert_equal "$output" "usage: tests/merge-queue-drill [--setup] <repo>"
  done
  assert_equal "$(stub_calls gh)" ""
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
}

@test "a worker session and the code checkout's own origin are refused before anything is read" {
  local role
  for role in planner builder reviewer ops; do
    AGENT_TEAM_ROLE=$role run -1 "$drill" org/scratch
    assert_equal "$output" "merge-queue-drill: a $role session may not run the merge queue drill: that is the coordinator's"
    AGENT_TEAM_ROLE=$role run -1 "$drill" --setup org/scratch
  done
  git -C "${CODE_CHECKOUT:?}" remote set-url origin https://github.com/Org/Scratch.git
  run -1 "$drill" org/scratch
  assert_equal "$output" "merge-queue-drill: org/scratch is the origin of this code checkout, not a scratch repository"
  run -1 "$drill" --setup org/scratch
  assert_equal "$output" "merge-queue-drill: org/scratch is the origin of this code checkout, not a scratch repository"
  assert_equal "$(stub_calls gh)" ""
  assert_equal "$(branches)" ""
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "--setup pushes the base commit to an empty dev, a CI of one job and a CodeQL workflow, once" {
  run -0 "$drill" --setup org/scratch
  local base
  base=$(git --git-dir="${ORIGIN:?}" rev-parse dev)
  assert_equal "$output" "merge-queue-drill: pushed the base commit ${base:0:7} to org/scratch's dev"
  assert_equal "$(branches)" "dev"
  assert_equal "$(git --git-dir="${ORIGIN:?}" ls-tree -r --name-only dev)" ".github/workflows/ci.yml
.github/workflows/codeql.yml
.merge-queue-drill
README.md"
  assert_equal "$(git --git-dir="${ORIGIN:?}" log --format=%s dev)" "ci: the merge queue drill's base commit"
  local workflow
  workflow=$(git --git-dir="${ORIGIN:?}" show dev:.github/workflows/ci.yml)
  assert_contains "$workflow" "on:
  pull_request:
    branches: [dev]
  merge_group:
    types: [checks_requested]
permissions: {}
jobs:
  check:
    runs-on: ubuntu-latest"
  # CodeQL's advanced setup: one job per language, actions alone, on each pull request and push to
  # dev and each trial commit, read-only but its uploads, its actions pinned by full sha.
  workflow=$(git --git-dir="${ORIGIN:?}" show dev:.github/workflows/codeql.yml)
  assert_contains "$workflow" "name: CodeQL
on:
  pull_request:
    branches: [dev]
  push:
    branches: [dev]
  merge_group:
    types: [checks_requested]
permissions: {}"
  assert_contains "$workflow" "jobs:
  analyze:
    name: Analyze (\${{ matrix.language }})
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      security-events: write
      actions: read
    strategy:
      fail-fast: false
      matrix:
        include:
          - language: actions
            build-mode: none
    steps:
      - uses: actions/checkout@"
  assert_contains "$workflow" "        with:
          persist-credentials: false"
  [[ $workflow != *schedule* ]]
  local uses
  uses=$(grep -o 'uses: .*' <<<"$workflow" | sed -E 's/@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$/@<sha>/')
  assert_equal "$uses" "uses: actions/checkout@<sha>
uses: github/codeql-action/init@<sha>
uses: github/codeql-action/analyze@<sha>"
  # A second setup changes nothing.
  run -0 "$drill" --setup org/scratch
  assert_equal "$output" "merge-queue-drill: org/scratch's dev already holds the drill's base files, at ${base:0:7}"
  assert_equal "$(git --git-dir="${ORIGIN:?}" rev-parse dev)" "$base"
  # Neither reads GitHub's API or records a run, and the sandbox is gone.
  assert_equal "$(stub_calls gh)" ""
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "--setup on the drill's older dev adds only the base files it lacks, in one commit, once" {
  old_base
  local before
  before=$(git --git-dir="${ORIGIN:?}" rev-parse dev)
  run -0 "$drill" --setup org/scratch
  local after
  after=$(git --git-dir="${ORIGIN:?}" rev-parse dev)
  assert_equal "$output" "merge-queue-drill: pushed ${after:0:7} to org/scratch's dev, adding the base files it lacked: .github/workflows/codeql.yml"
  assert_equal "$(git --git-dir="${ORIGIN:?}" rev-parse "$after^")" "$before"
  assert_equal "$(git --git-dir="${ORIGIN:?}" log -1 --format=%s dev)" "ci: the merge queue drill's base files"
  assert_equal "$(git --git-dir="${ORIGIN:?}" diff --name-status "$before" "$after")" "A	.github/workflows/codeql.yml"
  # The file is the one an empty repository gets, and the README dev had is kept.
  assert_contains "$(git --git-dir="${ORIGIN:?}" show dev:.github/workflows/codeql.yml)" "    name: Analyze (\${{ matrix.language }})"
  assert_equal "$(git --git-dir="${ORIGIN:?}" show dev:README.md)" "A README Daniel edited."
  # Run again, it pushes nothing.
  run -0 "$drill" --setup org/scratch
  assert_equal "$output" "merge-queue-drill: org/scratch's dev already holds the drill's base files, at ${after:0:7}"
  assert_equal "$(git --git-dir="${ORIGIN:?}" rev-parse dev)" "$after"
  assert_equal "$(stub_calls gh)" ""
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "--setup whose push of the lacking base files dev refuses says so, naming them and Daniel's step" {
  old_base
  # Two files lacking this time, and dev's ruleset refuses every push.
  local clone
  clone=$(mktemp -d "$BATS_TEST_TMPDIR/clone.XXXXXX")
  git clone -q "$ORIGIN" "$clone" 2>/dev/null
  git -C "${clone:?}" rm -q .github/workflows/ci.yml
  git -C "${clone:?}" commit -q -m "ci: no CI"
  git -C "${clone:?}" push -q origin HEAD:dev
  local before
  before=$(git --git-dir="${ORIGIN:?}" rev-parse dev)
  printf '#!/bin/sh\necho "error: GH013: Repository rule violations found for refs/heads/dev." >&2\nexit 1\n' >"$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  run -1 --separate-stderr "$drill" --setup org/scratch
  # shellcheck disable=SC2154 # stderr is bats' run's
  assert_equal "${stderr_lines[-1]}" "merge-queue-drill: org/scratch's dev refused the push of .github/workflows/ci.yml .github/workflows/codeql.yml: its ruleset must be disabled for it, Daniel's step in sops/drills.md, then run --setup again"
  assert_equal "$output" ""
  assert_equal "$(git --git-dir="${ORIGIN:?}" rev-parse dev)" "$before"
  assert_equal "$(branches)" "dev"
  assert_equal "$(stub_calls gh)" ""
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "neither form touches a repository whose dev is not the drill's" {
  local other before
  other=$(mktemp -d "$BATS_TEST_TMPDIR/other.XXXXXX")
  git clone -q "$ORIGIN" "$other" 2>/dev/null
  echo product >"$other/README.md"
  git -C "${other:?}" add README.md
  git -C "${other:?}" commit -q -m "feat: a product"
  git -C "${other:?}" push -q origin HEAD:dev
  before=$(git --git-dir="${ORIGIN:?}" rev-parse dev)
  run -1 "$drill" --setup org/scratch
  assert_equal "$output" "merge-queue-drill: org/scratch's dev holds commits that are not the drill's (no .merge-queue-drill): the drill takes a scratch repository only"
  run -1 "$drill" org/scratch
  assert_equal "${lines[-1]}" "merge-queue-drill: org/scratch's dev has no .merge-queue-drill: the drill takes only the scratch repository tests/merge-queue-drill --setup made"
  assert_equal "$(git --git-dir="${ORIGIN:?}" rev-parse dev)" "$before"
  assert_equal "$(branches)" "dev"
  [[ $(stub_calls gh) != *'"pr"'* ]]
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "the drill stops, with nothing opened or recorded, unless dev's rules hold a MERGE queue and pin agent-review to the App" {
  set_up
  queue_rules "" 123456
  run -1 "$drill" org/scratch
  assert_equal "${lines[-1]}" "merge-queue-drill: org/scratch's dev has no merge queue: its ruleset is Daniel's step, in sops/drills.md"
  queue_rules SQUASH 123456
  run -1 "$drill" org/scratch
  assert_equal "${lines[-1]}" "merge-queue-drill: org/scratch's dev has a merge queue that merges with SQUASH, not MERGE: its ruleset is Daniel's step, in sops/drills.md"
  local app
  for app in "" 999; do
    queue_rules MERGE "$app"
    run -1 "$drill" org/scratch
    assert_equal "${lines[-1]}" "merge-queue-drill: org/scratch's dev does not require agent-review from the reviewer App 123456: its ruleset is Daniel's step, in sops/drills.md"
  done
  echo "gh: Not Found (HTTP 404)" >"$GH_DIR/rules.error"
  run -1 "$drill" org/scratch
  assert_equal "${lines[-1]}" "merge-queue-drill: cannot read org/scratch's rules for dev"
  # With the App off there is nothing to post agent-review with.
  rm "$GH_DIR/rules.error" "$CODE_CHECKOUT/bin/lib/review-app"
  queue_rules MERGE 123456
  run -1 "$drill" org/scratch
  assert_equal "${lines[-1]}" "merge-queue-drill: the reviewer App is off (no id in bin/lib/review-app), so nothing can post agent-review on a trial commit"
  assert_equal "$(branches)" "dev"
  [[ $(stub_calls gh) != *'"pr"'* ]]
  assert_equal "$(stub_calls team-land)" ""
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "the drill stops, with nothing opened or recorded, on a dev with no CodeQL workflow or while CodeQL's default setup is on" {
  old_base
  run -1 "$drill" org/scratch
  assert_equal "${lines[-1]}" "merge-queue-drill: org/scratch's dev has no .github/workflows/codeql.yml: run tests/merge-queue-drill --setup org/scratch"
  set_up
  echo '{"state": "configured", "languages": ["actions"]}' >"$GH_DIR/default-setup.json"
  run -1 "$drill" org/scratch
  assert_equal "${lines[-1]}" "merge-queue-drill: org/scratch: CodeQL's default setup is on, which refuses the drill's workflow's uploads and runs nothing on a trial commit: Daniel turns it off, sops/drills.md"
  assert_equal "$(branches)" "dev"
  [[ $(stub_calls gh) != *'"pr"'* ]]
  assert_equal "$(stub_calls team-review-check)" ""
  assert_equal "$(stub_calls team-land)" ""
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "a default setup that cannot be read is said on one line and the drill goes on" {
  set_up
  echo "gh: Resource not accessible by integration (HTTP 403)" >"$GH_DIR/default-setup.error"
  run -0 --separate-stderr "$drill" org/scratch
  # shellcheck disable=SC2154 # stderr is bats' run's
  assert_equal "$stderr" "merge-queue-drill: org/scratch's CodeQL default setup could not be read, so the drill goes on: gh: Resource not accessible by integration (HTTP 403)"
  assert_contains "$output" "PASS one pull request landed on top of the other, behind dev's tip"
  assert_equal "$(jq -r '.verdict' "$TEAM_HOME/drills.jsonl")" "pass"
}

@test "a passing run: two pull requests land at once through the stub queue, every check passes, and the run is recorded" {
  set_up
  local base
  base=$(git --git-dir="${ORIGIN:?}" rev-parse dev)
  run -0 "$drill" org/scratch
  local a b ma mb
  a=$(<"$GH_DIR/pr-8.head") b=$(<"$GH_DIR/pr-9.head") ma=$(<"$GH_DIR/pr-8.merge") mb=$(<"$GH_DIR/pr-9.merge")
  assert_contains "$output" "== two pull requests from dev at ${base:0:7}
PR #8 https://github.com/org/scratch/pull/8 at ${a:0:7}
PR #9 https://github.com/org/scratch/pull/9 at ${b:0:7}
== agent-review on each head, then the heads' checks
PR #8: the reviewer App's check run 4242
PR #9: the reviewer App's check run 4242
team-ci-wait: the checks passed
team-ci-wait: the checks passed
== team-land on both at once
-- PR #8
team-land: enqueued https://github.com/org/scratch/pull/8 at ${a:0:7}
team-land: https://github.com/org/scratch/pull/8 merged as ${ma:0:7}"
  assert_contains "$output" "== checks
PASS PR #8 landed through the queue (team-land ended merged)
PASS PR #8 is merged at the head the drill pushed, ${a:0:7}, with no catch-up
PASS PR #8's merge commit ${ma:0:7} is on dev, that head merged cleanly onto a commit holding dev at ${base:0:7}
PASS PR #8's merge commit was the trial commit of a branch under gh-readonly-queue/dev/
PASS PR #8's trial commit ${ma:0:7} carries the reviewer App's agent-review success
PASS PR #8's trial commit ${ma:0:7} reported success for every check dev requires (check, Analyze (actions), agent-review)
PASS PR #9 landed through the queue (team-land ended merged)
PASS PR #9 is merged at the head the drill pushed, ${b:0:7}, with no catch-up
PASS PR #9's merge commit ${mb:0:7} is on dev, that head merged cleanly onto a commit holding dev at ${base:0:7}
PASS PR #9's merge commit was the trial commit of a branch under gh-readonly-queue/dev/
PASS PR #9's trial commit ${mb:0:7} carries the reviewer App's agent-review success
PASS PR #9's trial commit ${mb:0:7} reported success for every check dev requires (check, Analyze (actions), agent-review)
PASS one pull request landed on top of the other, behind dev's tip
== the roll-up CodeQL on the trial commits (no check)
PR #8: the roll-up CodeQL posted on the trial commit ${ma:0:7}; its check runs: Analyze (actions) (success), CodeQL (success), agent-review (success), check (success)
PR #9: the roll-up CodeQL posted on the trial commit ${mb:0:7}; its check runs: Analyze (actions) (success), CodeQL (success), agent-review (success), check (success)
== 13 of 13 checks passed on org/scratch PRs #8 and #9; every required check reported on 2 of 2 trial commits; the roll-up CodeQL on 2
team-drill: recorded merge-queue pass on home-pc at $(git -C "${CODE_CHECKOUT:?}" rev-parse --short=7 HEAD)"
  assert_equal "${lines[-1]}" "team-drill: recorded merge-queue pass on home-pc at $(git -C "${CODE_CHECKOUT:?}" rev-parse --short=7 HEAD)"
  # One line in the team home the drill was run with, never the sandbox's.
  assert_equal "$(drill_lines)" "$(drill_line pass "13 of 13 checks passed on org/scratch PRs #8 and #9; every required check reported on 2 of 2 trial commits; the roll-up CodeQL on 2")"

  # The scripts ran in the sandbox's team home, each PR's head given in full, the App's check
  # posted before the wait on the head's checks, and both landings with 30 minutes.
  local team
  team=$(<"$GH_DIR/land-8.team-home")
  [[ $team == "$sandboxes"/merge-queue-drill.*/team && $team != "$TEAM_HOME" ]]
  assert_equal "$(<"$GH_DIR/land-9.team-home")" "$team"
  assert_equal "$(stub_calls team-review-check)" "[\"https://github.com/org/scratch/pull/8\",\"$a\",\"success\",\"the merge queue drill's review of ${a:0:7}\"]
[\"https://github.com/org/scratch/pull/9\",\"$b\",\"success\",\"the merge queue drill's review of ${b:0:7}\"]"
  assert_equal "$(stub_calls team-ci-wait | sort)" "[\"https://github.com/org/scratch/pull/8\",\"$a\"]
[\"https://github.com/org/scratch/pull/9\",\"$b\"]"
  assert_equal "$(stub_calls team-land | sort)" "[\"https://github.com/org/scratch/pull/8\",\"$a\"]
[\"https://github.com/org/scratch/pull/9\",\"$b\"]"
  assert_equal "$(cat "$GH_DIR/land-8.deadline" "$GH_DIR/land-9.deadline")" "1800
1800"

  # The sandbox's registry passes team-project --check: one project, the team's own by its name,
  # on the scratch repository, with the ruleset's required checks but agent-review.
  assert_equal "$(<"$GH_DIR/registry-8.status") $(<"$GH_DIR/registry-8.check")" "0 $team/projects.toml: 1 projects ok"
  assert_equal "$(jq -c '[.repo, .base, .merge_method, .required_checks, (.path | test("/merge-queue-drill\\.[^/]+/checkout$"))]' \
    "$GH_DIR/registry-8.json")" '["org/scratch","dev","merge",["Analyze (actions)","check"],true]'
  # Its ledger holds to the contract, with a passing review of each head under the PR's task.
  mkdir "$BATS_TEST_TMPDIR/drill-home"
  cp "$GH_DIR/ledger-8.jsonl" "$BATS_TEST_TMPDIR/drill-home/ledger.jsonl"
  TEAM_HOME=$BATS_TEST_TMPDIR/drill-home run_bin -0 team-log --check
  assert_equal "$(jq -c 'select(.event != "opened") | [.task, .event, .url // .verdict, .head]' "$GH_DIR/ledger-8.jsonl")" \
    "[\"T1\",\"pr\",\"https://github.com/org/scratch/pull/8\",\"$a\"]
[\"T1\",\"review\",\"pass\",\"$a\"]
[\"T2\",\"pr\",\"https://github.com/org/scratch/pull/9\",\"$b\"]
[\"T2\",\"review\",\"pass\",\"$b\"]"

  # Each pull request's branch started from the base and adds one file of its own, so dev now
  # holds both, and the run's branches and the sandbox are gone.
  assert_equal "$(git --git-dir="${ORIGIN:?}" rev-parse "$a^" "$b^")" "$base
$base"
  [[ $(git --git-dir="${ORIGIN:?}" ls-tree -r --name-only dev -- runs | wc -l) == 2 ]]
  [[ $(branches) != *drill/* ]]
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
  [[ ! -e $GH_DIR/pr-8.closed && ! -e $GH_DIR/pr-9.closed ]]
}

@test "the drill runs on the owner login throughout, whatever GitHub login its session names" {
  set_up
  # The stub gh and the stub team-land log the three login variables of each call first.
  local cmd
  for cmd in gh team-land; do
    { printf '%s\n' 'printf "GH_CONFIG_DIR=<%s> GH_TOKEN=<%s> GITHUB_TOKEN=<%s>\n" "${GH_CONFIG_DIR-unset}" "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" >>"$STUB_CALLS/login.env"'
      cat "$STUB_FIXTURES/$cmd.sh"; } >"$STUB_FIXTURES/$cmd.sh.new"
    mv "$STUB_FIXTURES/$cmd.sh.new" "$STUB_FIXTURES/$cmd.sh"
  done
  # As the coordinator's settings name the worker login.
  GH_CONFIG_DIR=$HOME/.config/agent-team/gh-worker GH_TOKEN='' GITHUB_TOKEN='' run -0 "$drill" org/scratch
  assert_contains "$output" "PASS PR #9 landed through the queue (team-land ended merged)"
  # Every gh call and both landings, none on the session's login.
  assert_equal "$(grep -c . "$STUB_CALLS/login.env")" "$(($(stub_calls gh | grep -c .) + 2))"
  assert_equal "$(sort -u "$STUB_CALLS/login.env")" "GH_CONFIG_DIR=<unset> GH_TOKEN=<unset> GITHUB_TOKEN=<unset>"
}

@test "a head whose checks do not pass ends the drill before any landing, its pull requests closed and the run recorded failed" {
  set_up
  stub_reply team-ci-wait "team-ci-wait: the checks on the head did not pass" 1
  TEAM_LAND_DEADLINE_SECONDS=60 run -1 "$drill" org/scratch
  assert_contains "$output" "team-ci-wait: the checks on the head did not pass
FAIL the checks of the head did not pass on PR #8 #9, so nothing was enqueued
team-drill: recorded merge-queue fail on home-pc at "
  assert_equal "$(stub_calls team-land)" ""
  assert_equal "$(drill_lines)" "$(drill_line fail "the checks of the head did not pass on PR #8 #9, so nothing was enqueued")"
  [[ -e $GH_DIR/pr-8.closed && -e $GH_DIR/pr-9.closed ]]
  assert_equal "$(branches)" "dev"
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "a failed post of the App's check, and a pull request GitHub will not open, end the drill with what it opened closed" {
  set_up
  stub_reply team-review-check "" 1
  run -1 "$drill" org/scratch
  assert_contains "$output" "FAIL team-review-check failed on PR #8's head"
  assert_equal "$(drill_lines)" "$(drill_line fail "team-review-check failed on PR #8's head")"
  [[ -e $GH_DIR/pr-8.closed && -e $GH_DIR/pr-9.closed ]]
  assert_equal "$(branches)" "dev"
  # The second pull request cannot be opened: the first is closed, and both branches deleted.
  rm "$GH_DIR"/pr-* "$TEAM_HOME/drills.jsonl"
  : >"$GH_DIR/create-fails-9"
  run -1 "$drill" org/scratch
  [[ $output == *"FAIL gh pr create failed for drill/"*-b* ]]
  [[ -e $GH_DIR/pr-8.closed && ! -e $GH_DIR/pr-9.branch ]]
  assert_equal "$(branches)" "dev"
  assert_equal "$(jq -r '.verdict' "$TEAM_HOME/drills.jsonl")" "fail"
  assert_equal "$(stub_calls team-land)" ""
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "a pull request the queue dropped fails its checks, is closed, and the run is recorded failed" {
  set_up
  echo dequeued >"$GH_DIR/land-9"
  run -1 "$drill" org/scratch
  local ma
  ma=$(short pr-8.merge)
  assert_contains "$output" "-- PR #9
team-land: enqueued https://github.com/org/scratch/pull/9 at $(short pr-9.head)
team-land: the merge queue dropped https://github.com/org/scratch/pull/9: the checks failed"
  assert_contains "$output" "PASS PR #8's trial commit $ma carries the reviewer App's agent-review success
PASS PR #8's trial commit $ma reported success for every check dev requires (check, Analyze (actions), agent-review)
FAIL PR #9 landed through the queue (team-land ended dequeued)
FAIL PR #9 is merged at the head the drill pushed, $(short pr-9.head), with no catch-up
FAIL PR #9's merge commit is on dev, that head merged cleanly onto a commit holding dev at $(git --git-dir="${ORIGIN:?}" rev-parse --short=7 "$(<"$GH_DIR/pr-8.head")^")
FAIL PR #9's merge commit was the trial commit of a branch under gh-readonly-queue/dev/
FAIL PR #9's trial commit carries the reviewer App's agent-review success
FAIL PR #9's trial commit reported success for every check dev requires (check, Analyze (actions), agent-review): no trial commit to read
FAIL one pull request landed on top of the other, behind dev's tip
== the roll-up CodeQL on the trial commits (no check)
PR #8: the roll-up CodeQL posted on the trial commit $ma; its check runs: Analyze (actions) (success), CodeQL (success), agent-review (success), check (success)
PR #9: no trial commit to read
== 6 of 13 checks passed on org/scratch PRs #8 and #9; every required check reported on 1 of 1 trial commits; the roll-up CodeQL on 1
team-drill: recorded merge-queue fail on home-pc at "
  assert_equal "$(drill_lines)" "$(drill_line fail "6 of 13 checks passed on org/scratch PRs #8 and #9; every required check reported on 1 of 1 trial commits; the roll-up CodeQL on 1")"
  [[ ! -e $GH_DIR/pr-8.closed && -e $GH_DIR/pr-9.closed ]]
  [[ $(branches) != *drill/* ]]
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}

@test "a pull request still queued at the deadline has its trial commit read, where the roll-up CodeQL did not post" {
  set_up
  echo waiting >"$GH_DIR/land-9"
  # Neither trial commit has the roll-up CodeQL, only the workflows' checks and the App's agent-review.
  check_runs 123456 ""
  TEAM_LAND_DEADLINE_SECONDS=7 run -1 "$drill" org/scratch
  local trial
  trial=$(<"$GH_DIR/entry-9")
  assert_equal "$(cat "$GH_DIR/land-8.deadline" "$GH_DIR/land-9.deadline")" "7
7"
  assert_contains "$output" "FAIL PR #9 landed through the queue (team-land ended waiting)"
  assert_contains "$output" "PASS PR #9's trial commit ${trial:0:7} carries the reviewer App's agent-review success"
  assert_contains "$output" "PASS PR #9's trial commit ${trial:0:7} reported success for every check dev requires (check, Analyze (actions), agent-review)"
  assert_contains "$output" "PR #8: the roll-up CodeQL did not post on the trial commit $(short pr-8.merge); its check runs: Analyze (actions) (success), agent-review (success), check (success)
PR #9: the roll-up CodeQL did not post on the trial commit ${trial:0:7}; its check runs: Analyze (actions) (success), agent-review (success), check (success)
== 8 of 13 checks passed on org/scratch PRs #8 and #9; every required check reported on 2 of 2 trial commits; the roll-up CodeQL on 0"
  # The pull request is taken out of the queue by closing it.
  [[ -e $GH_DIR/pr-9.closed ]]
  [[ $(branches) != *drill/* ]]
}

@test "a trial commit that is not the head merged onto dev, was on no queue branch, or carries another App's agent-review fails its check" {
  set_up
  echo swapped >"$GH_DIR/land-8"
  echo no-branch >"$GH_DIR/land-9"
  check_runs 999 CodeQL
  run -1 "$drill" org/scratch
  local ma mb
  ma=$(short pr-8.merge) mb=$(short pr-9.merge)
  assert_contains "$output" "PASS PR #8 landed through the queue (team-land ended merged)
PASS PR #8 is merged at the head the drill pushed, $(short pr-8.head), with no catch-up
FAIL PR #8's merge commit $ma is on dev, that head merged cleanly onto a commit holding dev at "
  assert_contains "$output" "PASS PR #8's merge commit was the trial commit of a branch under gh-readonly-queue/dev/
FAIL PR #8's trial commit $ma carries the reviewer App's agent-review success
FAIL PR #8's trial commit $ma reported success for every check dev requires (check, Analyze (actions), agent-review): agent-review not reported by the App 123456"
  assert_contains "$output" "FAIL PR #9's merge commit was the trial commit of a branch under gh-readonly-queue/dev/
FAIL PR #9's trial commit $mb carries the reviewer App's agent-review success
FAIL PR #9's trial commit $mb reported success for every check dev requires (check, Analyze (actions), agent-review): agent-review not reported by the App 123456"
  assert_equal "$(jq -r '.verdict' "$TEAM_HOME/drills.jsonl")" "fail"
}

@test "a trial commit missing a required check, or carrying one not successful, fails the required-checks check naming each" {
  set_up
  # dev also requires lint, pinned to no App, which a check run or a commit status may meet.
  queue_rules MERGE 123456 lint
  echo waiting >"$GH_DIR/land-9"
  # PR #8's trial commit: no Analyze (actions), and lint a successful status. PR #9's: Analyze
  # (actions) failed, lint a check run still running and a failed status.
  check_runs 123456 "" runs-pr-8.json
  jq '.check_runs |= map(select(.name != "Analyze (actions)"))' "$GH_DIR/runs-pr-8.json" >"$GH_DIR/runs-pr-8.json.new"
  mv "$GH_DIR/runs-pr-8.json.new" "$GH_DIR/runs-pr-8.json"
  echo '{"state": "success", "statuses": [{"context": "lint", "state": "success"}]}' >"$GH_DIR/statuses-pr-8.json"
  check_runs 123456 "" runs-pr-9.json
  jq '.check_runs |= map(if .name == "Analyze (actions)" then .conclusion = "failure" else . end)
    | .check_runs += [{name: "lint", status: "in_progress", conclusion: null, app: {id: 15368}}]' \
    "$GH_DIR/runs-pr-9.json" >"$GH_DIR/runs-pr-9.json.new"
  mv "$GH_DIR/runs-pr-9.json.new" "$GH_DIR/runs-pr-9.json"
  echo '{"state": "failure", "statuses": [{"context": "lint", "state": "failure"}]}' >"$GH_DIR/statuses-pr-9.json"
  TEAM_LAND_DEADLINE_SECONDS=7 run -1 "$drill" org/scratch
  assert_contains "$output" "FAIL PR #8's trial commit $(short pr-8.merge) reported success for every check dev requires (check, Analyze (actions), agent-review, lint): Analyze (actions) not reported"
  assert_contains "$output" "FAIL PR #9's trial commit $(short entry-9) reported success for every check dev requires (check, Analyze (actions), agent-review, lint): Analyze (actions) failure, lint in_progress, lint failure"
  assert_contains "$output" "every required check reported on 1 of 2 trial commits; the roll-up CodeQL on 0"
  assert_equal "$(jq -r '.verdict' "$TEAM_HOME/drills.jsonl")" "fail"
  # A lint met by its status alone passes.
  rm "$GH_DIR"/pr-* "$GH_DIR"/entry-* "$GH_DIR"/started-* "$GH_DIR"/runs-pr-* "$GH_DIR/statuses-pr-9.json" "$GH_DIR/land-9" "$TEAM_HOME/drills.jsonl"
  echo '{"state": "success", "statuses": [{"context": "lint", "state": "success"}]}' >"$GH_DIR/statuses-pr-9.json"
  # The first run's PR #8 landed runs/<stamp>-a.txt on dev, and the stub queue ends at once, so a
  # second run in the same second would name the same file and commit nothing: wait for the next.
  local second
  second=$(date -u +%s)
  while [[ $(date -u +%s) == "$second" ]]; do sleep 0.1; done
  run -0 "$drill" org/scratch
  assert_contains "$output" "PASS PR #8's trial commit $(short pr-8.merge) reported success for every check dev requires (check, Analyze (actions), agent-review, lint)"
  assert_contains "$output" "PASS PR #9's trial commit $(short pr-9.merge) reported success for every check dev requires (check, Analyze (actions), agent-review, lint)"
}

@test "a landing that prints no result fails, and a record team-drill refuses is said with the exit status kept" {
  set_up
  echo silent >"$GH_DIR/land-8"
  rm "$HOME/.config/agent-team/machine"
  run -1 --separate-stderr "$drill" org/scratch
  assert_contains "$output" "FAIL PR #8 landed through the queue (team-land ended no result)"
  # shellcheck disable=SC2154 # stderr is bats' run's
  assert_equal "$stderr" "merge-queue-drill: not recorded: team-drill: this machine has no team name; write one with: echo <name> > ~/.config/agent-team/machine"
  [[ ! -e $TEAM_HOME/drills.jsonl ]]
  [[ -e $GH_DIR/pr-8.closed ]]
  [[ $(branches) != *drill/* ]]
  assert_equal "$(find "$sandboxes" -mindepth 1)" ""
}
