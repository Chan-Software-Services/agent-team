# shellcheck shell=bash
# shellcheck disable=SC2154 # output is set by bats' run
# The sandbox and readers of team-next's tests, shared by tests/team-next.bats and the
# tests/team-next-*.bats files: load it with `load helpers/team-next` after `load helpers/common`
# and `load helpers/github-api`, and call team_next_sandbox in setup. Each function below says
# what it does.
#
# team-next takes a worker's message to the task's next step: its checks refuse with nothing
# changed, it logs the message's events through team-log once, and it launches the next session
# through team-brief and team-worker. T7 runs in proj, its worktree $wt a real git worktree with
# ticket 01 committed at $sha; claude is a stub whose launches print a fresh session id each. A
# pass's checks wait, team-next T7 --ci, runs from a copy of bin/ whose team-ci-wait is a stub
# answering with a --json end (ci_wait_ends). $url is T7's PR, 9, and $counts a verdict's
# findings counts, every one 0.

# team_next_sandbox: sandbox, then T7 in proj as the header says; call it in setup.
team_next_sandbox() {
  sandbox
  hold_lease home-pc >/dev/null
  # #coordinator's guild, as team-inbox keeps it after its first read, so team-log's refresh of the
  # waiting list calls Discord for nothing.
  mkdir -p "$HOME/.local/state/agent-team"
  echo '{"channel":"1562486564871995482","guild":"1560000000000000000"}' >"$HOME/.local/state/agent-team/inbox.json"
  primary=$(make_repo proj)
  wt=$HOME/slots/proj/1
  git -C "${primary:?}" worktree add -q -b feat/T7-toil "$wt"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = ["browser"]
pool = { provider = "git", slots = ["slots/proj/1", "slots/proj/2"] }
TOML
  mkdir -p "$TEAM_HOME/tasks/T7" "$wt/.scratch/task/tickets"
  printf '%s\n' "# T7 plan" "" "## Goal" "" "Coordinator toil goes to the scripts." "" "## Why" "" "Turns." \
    >"$TEAM_HOME/tasks/T7/plan.md"
  event opened "$(jq -cn --arg wt "$wt" '{project: "proj", path: "feature", type: "feat", title: "toil",
    branch: "feat/T7-toil", base: "main", base_sha: "0123456", worktree: $wt}')"
  event thread '{discord_thread: "1563000000000000012"}'
  event plan-approved '{by: "coordinator"}'
  ticket 01-first "Blocked by: None"
  ticket 02-second "Blocked by: 01"
  ticket 03-third "**Blocked by:** 01" "**Waits for:** T171 merged"
  ticket 04-fourth "Blocked by: 02"
  launched b0000001 brief-build-01 '["browser"]'
  sha=$(commit one.txt "feat: ticket 01")
  # Each launch prints the next session id, c0000001, c0000002...; the session list is
  # $STUB_FIXTURES/agents, else empty, so team-worker stops nothing. Once $STUB_FIXTURES/fail-once exists, the next launch
  # fails and removes it. While $STUB_FIXTURES/launches-live exists, each launch joins the session
  # list, idle, and rm takes a session off it.
  stub_script claude <<'EOF'
if [[ $* == "agents --json" ]]; then cat "$STUB_FIXTURES/agents" 2>/dev/null || echo '[]'; exit 0; fi
if [[ $1 == rm && -e $STUB_FIXTURES/launches-live && -e $STUB_FIXTURES/agents ]]; then
  jq -c --arg id "$2" 'map(select(.id != $id))' "$STUB_FIXTURES/agents" >"$STUB_FIXTURES/agents.next"
  mv "$STUB_FIXTURES/agents.next" "$STUB_FIXTURES/agents"
fi
if [[ $1 == stop || $1 == rm ]]; then exit 0; fi
if [[ -e $STUB_FIXTURES/fail-once ]]; then
  rm "$STUB_FIXTURES/fail-once"
  echo "claude: could not start the session" >&2
  exit 1
fi
n=$(($(cat "$STUB_FIXTURES/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$STUB_FIXTURES/count"
if [[ -e $STUB_FIXTURES/launches-live ]]; then
  [[ -e $STUB_FIXTURES/agents ]] || echo '[]' >"$STUB_FIXTURES/agents"
  jq -c --arg s "c000000$n" '. + [{id: $s, sessionId: "\($s)-0000", kind: "background", status: "idle", state: "blocked"}]' \
    "$STUB_FIXTURES/agents" >"$STUB_FIXTURES/agents.next"
  mv "$STUB_FIXTURES/agents.next" "$STUB_FIXTURES/agents"
fi
echo "Started background session c000000$n (${*: -2:1}). Attach with: claude attach c000000$n"
EOF
}

# event <kind> '<jq object of the other fields>': append one T7 ledger line.
event() {
  jq -cn --arg event "$1" "{ts: \"2026-11-01T10:00:00Z\", task: \"T7\", event: \$event} + $2" >>"$TEAM_HOME/ledger.jsonl"
}

# launched <session> <brief> [<toolkits as JSON>] [<role>]: a launch in the worktree.
launched() {
  event launch "$(jq -cn --arg s "$1" --arg b "$2" --argjson k "${3:-[]}" --arg r "${4:-builder}" --arg wt "$wt" \
    '{role: $r, session: $s, worktree: $wt, toolkits: $k, project: "proj", branch: "feat/T7-toil", machine: "home-pc"}
     + (if $b == "" then {} else {brief: $b} end)')"
}

# ticket <NN-slug> <lines>...: a ticket file of those lines under a title.
ticket() {
  printf '%s\n' "# ${1%%-*}: ${1#*-}" "" "${@:2}" "" "- [ ] it works" >"$wt/.scratch/task/tickets/$1.md"
}

# commit <file> <subject>: a commit in the worktree; prints its full sha.
commit() {
  echo "$2" >"$wt/$1"
  git -C "${wt:?}" add "$1"
  git -C "${wt:?}" commit -q -m "$2"
  git -C "${wt:?}" rev-parse HEAD
}

# The ledger's T7 lines from the n-th on, without ts.
logged_from() {
  tail -n +"$1" "$TEAM_HOME/ledger.jsonl" | jq -c 'del(.ts)'
}

# What a refusal must leave as it was: the ledger, the task's files and the claude calls but its
# reads of the session list.
state() {
  cat "$TEAM_HOME/ledger.jsonl"
  (cd "$TEAM_HOME/tasks" && find . -type f | sort)
  stub_calls claude | jq -c 'select(. != ["agents", "--json"])'
}

# refused <expected text> <team-next arguments>...: exit 1 naming it, with nothing changed.
refused() {
  local before
  before=$(state)
  run_bin -1 team-next "${@:2}"
  assert_contains "$output" "$1"
  assert_equal "$(state)" "$before"
}

# The claude calls that started a session.
bg_calls() {
  stub_calls claude | jq -c 'select(.[0] == "--bg")'
}

# arm_line <head>: the line a pass on PR 9 ($url, below) ends on, arming the checks wait on <head>.
arm_line() {
  echo "checks: arm team-next T7 --ci with Bash run_in_background unless it is already running: it waits on the checks of $url at ${1:0:8}, then prints the merge ask or hands a red check back as a round"
}

# passed <team-next arguments>...: team-next takes the reviewer's pass, which ends on the arm line
# for the PR's head on GitHub ($GH_HEAD, pr_on_github's), and then team-next T7 --ci, whose wait
# says the checks of that head passed; $output is --ci's.
passed() {
  ci_wait_ends passed "$GH_HEAD"
  run_bin -0 --separate-stderr team-next T7 "$@"
  assert_equal "$(tail -n 1 <<<"$output")" "$(arm_line "$GH_HEAD")"
  run_bin -0 --separate-stderr team-next T7 --ci
}

# The ci events logged, each as its url, head and outcome.
ci_logged() {
  jq -c 'select(.event == "ci") | [.url, .head, .outcome]' "$TEAM_HOME/ledger.jsonl"
}

# red_checks <head>: --ci's wait ends failed on <head>, exit 1, with a roll-up, a failed shard of
# the PR's own, a runner that never started, a check the base's rules require and one the registry
# alone requires, not reported, and a lint step of the PR's own, in that order, each in
# team-ci-wait --json's form.
red_checks() {
  local job=https://github.com/owner/proj/actions/runs/7/job
  ci_wait_ends failed "$1" 1 "team-ci-wait: the checks on ${1:0:7} did not pass" "$(jq -cn --arg j "$job" '[
    {name: "test", class: "rollup", kind: "rollup", state: "FAILURE", link: "\($j)/9", run: 7, job: 9, step: null, rerun: null},
    {name: "test-shards (2)", class: "pr", kind: "failed", state: "FAILURE", link: "\($j)/8", run: 7, job: 8,
     step: "Run the tests", rerun: null},
    {name: "smoke-shards (1)", class: "infrastructure", kind: "never-started", state: "CANCELLED", link: "\($j)/10", run: 7,
     job: 10, step: null, rerun: "gh run rerun 7 --job 10 --repo owner/proj"},
    {name: "build", class: "pr", kind: "missing", state: null, link: null, run: null, job: null, step: null, rerun: null,
     source: "rules"},
    {name: "data", class: "pr", kind: "missing", state: null, link: null, run: null, job: null, step: null, rerun: null,
     source: "required_checks"},
    {name: "lint", class: "pr", kind: "failed", state: "FAILURE", link: "\($j)/11", run: 7, job: 11, step: "Lint", rerun: null}]')"
}

# infra <name> <kind> <run> <job> [<step>]: one infrastructure failure of PR 9's checks, as
# team-ci-wait --json gives it; rollup <name> <run> <job> the roll-up of a run's failed shards.
infra() {
  jq -cn --arg n "$1" --arg k "$2" --argjson r "$3" --argjson j "$4" --arg s "${5:-}" '{name: $n, class: "infrastructure",
    kind: $k, state: (if $k == "never-started" then "CANCELLED" elif $k == "queued" then "QUEUED" elif $k == "stuck" then "IN_PROGRESS" else "FAILURE" end),
    link: "https://github.com/owner/proj/actions/runs/\($r)/job/\($j)", run: $r, job: $j,
    step: (if $s == "" then null else $s end),
    rerun: (if $k == "stuck" then "gh run rerun \($r) --repo owner/proj" else "gh run rerun \($r) --job \($j) --repo owner/proj" end)}'
}

rollup() {
  jq -cn --arg n "$1" --argjson r "$2" --argjson j "$3" '{name: $n, class: "rollup", kind: "rollup", state: "FAILURE",
    link: "https://github.com/owner/proj/actions/runs/\($r)/job/\($j)", run: $r, job: $j, step: null, rerun: null}'
}

url=https://github.com/owner/proj/pull/9

# on_github <PR number> <head> [<head branch>]: the gh stub answers gh pr view <number> --repo
# owner/proj with that head and head branch (the task's by default); any other PR is not found.
on_github() {
  jq -cn --arg head "$2" --arg branch "${3:-feat/T7-toil}" '{headRefOid: $head, headRefName: $branch}' \
    >"$STUB_FIXTURES/github-$1"
  stub_script gh <<'SH'
[[ $1 == pr && $2 == view && $4 == --repo && $5 == owner/proj ]] || { echo "unexpected gh $*" >&2; exit 1; }
answer=$STUB_FIXTURES/github-$3
[[ -f $answer ]] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2; exit 1; }
cat "$answer"
SH
}

# review_logged <verdict> <head> <sent_back as JSON> [<findings counts as JSON>]: a review of
# <head>, every count not given 0.
review_logged() {
  local counts=${4:-'{}'}
  event review "$(jq -cn --arg v "$1" --arg h "$2" --argjson s "$3" --argjson f "$counts" '{verdict: $v, head: $h, sent_back: $s,
    findings: ({blocking: 0, correctness: 0, security: 0, "real-data": 0, "note-change": 0, "note-before": 0} + $f),
    before: [], guarded: []}')"
}

# The brief record's template and values, compact.
record() {
  jq -c '{template, values}' "$TEAM_HOME/tasks/T7/brief-$1.json"
}

# checks: writes a one-line checks file under $BATS_TEST_TMPDIR, as a first review's --checks
# takes, and prints its path.
checks() {
  echo "1. team-next launches the reviewer." >"$BATS_TEST_TMPDIR/checks"
  echo "$BATS_TEST_TMPDIR/checks"
}

counts="findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0"

# pr_on_github <head> [<behind_by>] [<checks as JSON>]: the gh stub answers team-state's reads
# of PR 9 (open, against main, at <head>), its checks (agent-review passed by default), its
# required checks (none), the compare of main with <head> (0 behind by default), the real
# team-ci-wait's look at it through the reader (gh api -i, answered through
# tests/helpers/github-api.bash: the PR's state and head, its checks as the head's commit statuses
# with no check run, no workflow run of the head and none of the repository in progress), so a
# findings round's look ends on its first look, and, read only with
# the reviewer App on, the head's agent-review check runs and commit statuses (none). With GH_QUEUE
# set, it answers the reads of main's rules too, a ruleset with a merge queue; else those fail, as
# a base whose rules cannot be read.
pr_on_github() {
  export GH_HEAD=$1 GH_BEHIND=${2:-0}
  export GH_CHECKS=${3:-'[{"name": "agent-review", "bucket": "pass", "state": "SUCCESS"}]'}
  github_stub_setup
  # No time passes between two looks of a test, which read GitHub again each time.
  export TEAM_GITHUB_FRESH_SECONDS=0
  stub_script gh <<'SH'
if [[ $1 == api && $2 == -i ]]; then
  source "$GITHUB_STUB_HELPER"
  github_request "$@"
  case $GITHUB_ENDPOINT in
    repos/owner/proj/pulls/9)
      github_answer 200 "$(jq -cn --arg h "$GH_HEAD" '{number: 9, state: "open", merged: false,
        head: {sha: $h, ref: "feat/T7-toil"}, base: {ref: "main"}}')" ;;
    "repos/owner/proj/commits/$GH_HEAD/check-runs?filter=latest&per_page=100")
      github_answer 200 '{"total_count": 0, "check_runs": []}' ;;
    "repos/owner/proj/commits/$GH_HEAD/status?per_page=100")
      github_answer 200 "$(jq -c '{state: "pending", statuses: [.[] | {context: .name, state: (.state | ascii_downcase),
        target_url: (.link // null)}]}' <<<"$GH_CHECKS")" ;;
    "repos/owner/proj/actions/runs?head_sha=$GH_HEAD&per_page=100" | "repos/owner/proj/actions/runs?status=in_progress&per_page=1")
      github_answer 200 '{"total_count": 0, "workflow_runs": []}' ;;
  esac
  echo "unplanned gh call: $*" >&2
  exit 1
fi
case "$*" in
  "pr view 9 --repo owner/proj --json number,state,baseRefName,headRefOid,headRefName,changedFiles")
    jq -cn --arg h "$GH_HEAD" '{number: 9, state: "OPEN", baseRefName: "main", headRefOid: $h, headRefName: "feat/T7-toil",
      changedFiles: 1}' ;;
  "pr checks 9 --repo owner/proj --required"*) echo '[]' ;;
  "pr checks 9 --repo owner/proj"*) echo "$GH_CHECKS" ;;
  "api repos/owner/proj/compare/main...$GH_HEAD --jq .behind_by") echo "$GH_BEHIND" ;;
  "api repos/owner/proj/pulls/9/files --paginate") echo '[{"filename": "one.txt"}]' ;;
  "api repos/owner/proj/commits/$GH_HEAD/check-runs?check_name=agent-review&filter=latest&per_page=100")
    echo '{"total_count": 0, "check_runs": []}' ;;
  "api repos/owner/proj/commits/$GH_HEAD/status") echo '{"state": "pending", "statuses": []}' ;;
  "api repos/owner/proj/branches/main") [[ -n ${GH_QUEUE:-} ]] && echo '{"name": "main", "protected": true}' ;;
  "api repos/owner/proj/rules/branches/main --paginate")
    [[ -n ${GH_QUEUE:-} ]] && echo '[{"type": "merge_queue", "ruleset_id": 9, "parameters": {"merge_method": "MERGE"}}]' ;;
  "api repos/owner/proj/rulesets/9") [[ -n ${GH_QUEUE:-} ]] && echo '{"id": 9, "name": "main", "bypass_actors": []}' ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
SH
}

# reviewing <head> [<sent_back of an earlier review as JSON>]: the PR logged at <head> and a
# reviewer launched on brief-review, whose record names <head>; with a list, an earlier review
# and a round before it, so this reviewer is the re-review.
reviewing() {
  event pr "$(jq -cn --arg url "$url" --arg h "$1" '{url: $url, head: $h}')"
  if [[ -n ${2:-} ]]; then
    review_logged findings "$1" "$2" '{"blocking": 1}'
    launched b0000002 brief-round-1 '["browser"]'
  fi
  jq -cn --arg url "$url" --arg h "$1" '{template: "reviewer", project: "proj", values: {pr: $url, head: $h}}' \
    >"$TEAM_HOME/tasks/T7/brief-review.json"
  launched r0000002 brief-review '["browser"]' reviewer
}

# live <session> <context in tokens>...: the session list holds each session, idle, its
# transcript's latest reply having read that many tokens.
live() {
  local list='[]'
  mkdir -p "$HOME/.claude/projects/-wt"
  while (($#)); do
    list=$(jq -c --arg s "$1" '. + [{id: $s, sessionId: "\($s)-0000", kind: "background", status: "idle", state: "blocked"}]' <<<"$list")
    jq -cn --argjson n "$2" '{type: "assistant", message: {usage: {input_tokens: $n}}}' >"$HOME/.claude/projects/-wt/$1-0000.jsonl"
    shift 2
  done
  echo "$list" >"$STUB_FIXTURES/agents"
}

# The calls that could reach Discord, merge or post: curl's, and gh's beyond team-state's and
# team-ci-wait's reads (the base's rules among them, its branch, rules/branches and rulesets), the
# reader's -i and its -H header left out.
outside_calls() {
  stub_calls curl
  stub_calls gh | jq -c '. as $a | [range(length) | select($a[.] != "-i" and $a[.] != "-H" and (. == 0 or $a[. - 1] != "-H"))
      | $a[.]]
    | select((.[0] == "pr" and (.[1] == "view" or .[1] == "checks"))
    or (.[0] == "api" and (.[1] | test("/compare/|/branches/|/rulesets/[0-9]+$|/pulls/[0-9]+(/files)?$|/actions/runs[?](head_sha=|status=in_progress&)|/commits/[0-9a-f]+/(check-runs[?]|status([?]|$))"))) | not)'
}

# second_repo: T7 also has a worktree in other, a second registered project the App posts nothing
# for, with a builder there (b0000002) and a PR 4 ($url_other) at its head ($head_other), not
# logged yet.
second_repo() {
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'

[other]
repo = "owner/other"
path = "projects/other"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []
pool = { provider = "git", slots = ["slots/other/1"] }
TOML
  local primary_other
  primary_other=$(make_repo other)
  wt_other=$HOME/slots/other/1
  git -C "${primary_other:?}" worktree add -q -b feat/T7-toil "$wt_other"
  head_other=$(git -C "${wt_other:?}" rev-parse HEAD)
  # shellcheck disable=SC2034 # read by the tests
  url_other=https://github.com/owner/other/pull/4
  event worktree-added "$(jq -cn --arg wt "$wt_other" --arg h "$head_other" \
    '{project: "other", branch: "feat/T7-toil", base: "main", base_sha: $h[:7], worktree: $wt}')"
  launched_in other b0000002 brief-deliver-other builder
}

# launched_in <project> <session> <brief> <role>: a launch in that project's worktree of T7.
launched_in() {
  event launch "$(jq -cn --arg p "$1" --arg s "$2" --arg b "$3" --arg r "$4" --arg wt "$HOME/slots/$1/1" \
    '{role: $r, session: $s, worktree: $wt, toolkits: [], project: $p, branch: "feat/T7-toil", machine: "home-pc", brief: $b}')"
}

# churn_line <findings> <head> <earlier findings> <who> <fix line>: the churn line team-next prints.
churn_line() {
  echo "churn: findings $1 of the review of ${2:0:8} sit in what the fix since the last review added, as findings $3 of the review of ${sha:0:8} did: $4 whether to narrow them (the holder makes each a documented limit in the code's header instead of widening the fix, and the next rereview's --since says so), revert the fix that widened, or run one more round: $5"
}

# ff_step: the step a holder's fix message on PR 9 ends with, bringing feat/T7-toil to the PR's head.
ff_step() {
  echo "; before you start, bring the branch to the PR's head with \`git fetch origin && git merge --ff-only origin/feat/T7-toil\`, and send T7 BLOCKED <git's reason> if it fails"
}

# fix_line <findings> <file>: the fix message to the holder b0000001 at 120k.
fix_line() {
  echo "send to T7-builder (b0000001, 120k): T7 fix findings $1 in $2 on the same branch, each as narrowly as it asks (a fix that would reach shapes it does not name is a T7 QUESTION first), then deliver again as your brief says$(ff_step)"
}

# fill_ready [<parallel>]: T7 ready for --fill, ticket 01 done: a pool of six slots, the task
# branch ignoring .scratch/ as team-open --ticket needs, a scope.txt for the tickets' Touches:
# lines, and a later plan-approved with
# parallel=<parallel> when one is given. Each builder it launches stays live, idle, until it is
# removed, so a fill finds no ticket's builder gone.
fill_ready() {
  touch "$STUB_FIXTURES/launches-live"
  sed -i 's|slots = \["slots/proj/1", "slots/proj/2"\]|slots = ["slots/proj/1", "slots/proj/2", "slots/proj/3", "slots/proj/4", "slots/proj/5", "slots/proj/6"]|' \
    "$TEAM_HOME/projects.toml"
  echo ".scratch/" >"$wt/.gitignore"
  git -C "${wt:?}" add .gitignore
  git -C "${wt:?}" commit -q -m "chore: ignore scratch"
  printf '%s\n' two.txt three.txt four.txt five.txt six.txt seven.txt nine.txt >"$wt/.scratch/task/scope.txt"
  event ticket-done '{ticket: "01", commits: ["0123456"]}'
  [[ -z ${1:-} ]] || event plan-approved "$(jq -cn --arg p "$1" '{by: "Daniel", parallel: $p}')"
}

# ticket_wt <NN>: the worktree last given to ticket NN.
ticket_wt() {
  jq -r --arg n "$1" 'select(.event == "worktree-added" and .ticket == $n) | .worktree' "$TEAM_HOME/ledger.jsonl" |
    tail -n 1
}

# looks_counted: a stub sleep that counts its calls in $BATS_TEST_TMPDIR/looks, each one look on;
# the uname stub keeps it ahead of Homebrew's GNU sleep on macOS.
looks_counted() {
  stub_command sleep uname
  stub_reply uname Linux
  echo 0 >"$BATS_TEST_TMPDIR/looks"
  stub_script sleep <<EOF
echo \$((\$(cat "$BATS_TEST_TMPDIR/looks") + 1)) >"$BATS_TEST_TMPDIR/looks"
EOF
}
