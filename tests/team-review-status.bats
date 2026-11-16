#!/usr/bin/env bats
# team-review-status: the reviewer's only way to set a status, agent-review on the head it reviewed
# of a registered project's PR, the call built by the script so its allow rule lets nothing else
# through, and never on a commit pushed after the review. Its --merge-group form, on the merge
# queue's trial commit, runs on a real origin and primary checkout (helpers/queue).

load helpers/common
load helpers/queue

HEAD_SHA=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "Owner/Proj"
path = "projects/proj"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1"]
TOML
  export HEAD_SHA
  # gh pr view answers the head; gh api answers the status it created.
  stub_script gh <<'SH'
case $1 in
  pr) echo "$HEAD_SHA" ;;
  api) echo '{"state": "success"}' ;;
esac
SH
}

# PR 5 of proj on a real origin (helpers/queue), its head logged, reviewed and passed by T9.
queued_pr() {
  queue_repo proj
  URL=https://github.com/owner/proj/pull/5
  jq -cn --arg url "$URL" --arg head "$QUEUE_HEAD" '
    {task: "T9", event: "opened", project: "proj"},
    {task: "T9", event: "pr", url: $url, project: "proj", head: $head},
    {task: "T9", event: "review", verdict: "pass", head: $head, ts: "2026-11-14T09:00:00Z"}' >>"$TEAM_HOME/ledger.jsonl"
}

# The status POSTs gh was given, one JSON array each.
status_posts() {
  stub_calls gh | jq -c 'select(.[1] == "--method")'
}

# --merge-group on <sha> is refused, exit 1, with <text> in what it says, and no status set.
group_refused() {
  run_bin "-${GROUP_STATUS:-1}" team-review-status --merge-group "$URL" "$1"
  assert_contains "$output" "$2"
  assert_contains "$output" "nothing set"
  assert_equal "$(status_posts)" ""
}

@test "sets agent-review on the reviewed head, in the registered repo's spelling" {
  run_bin -0 team-review-status https://github.com/owner/proj/pull/5 "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "agent-review success on Owner/Proj@$HEAD_SHA"
  assert_equal "$(stub_calls gh)" "$(jq -cn --arg head "$HEAD_SHA" '
    ["pr", "view", "5", "--repo", "Owner/Proj", "--json", "headRefOid", "--jq", ".headRefOid"],
    ["api", "--method", "POST", "repos/Owner/Proj/statuses/\($head)",
      "-f", "state=success", "-f", "context=agent-review", "-f", "description=no blocking findings"]')"
}

@test "failure is the other state" {
  run_bin -0 team-review-status https://github.com/Owner/Proj/pull/12 "$HEAD_SHA" failure "2 blocking"
  assert_contains "$(stub_calls gh | tail -n 1)" '"-f","state=failure","-f","context=agent-review","-f","description=2 blocking"]'
}

@test "a hostile description is one field's value, never more fields" {
  run_bin -0 team-review-status https://github.com/owner/proj/pull/5 "$HEAD_SHA" success 'x -f context=ci" -X PUT'
  assert_equal "$(stub_calls gh | tail -n 1 | jq -r '.[-1]')" 'description=x -f context=ci" -X PUT'
  assert_equal "$(stub_calls gh | tail -n 1 | jq 'length')" 10
}

@test "a malformed command line is refused before any gh call" {
  local url=https://github.com/owner/proj/pull/5
  local -a cases=(
    ''
    "$url"
    "$url $HEAD_SHA success"
    "$url success x"
    "$url $HEAD_SHA success x -f context=ci"
    "$url $HEAD_SHA success x --repo someone/else"
  )
  local args
  for args in "${cases[@]}"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 team-review-status $args
  done
  assert_equal "$(stub_calls gh)" ""
}

@test "anything but a registered project's PR URL, a full sha, success or failure, and a short line is refused" {
  local good=https://github.com/owner/proj/pull/5
  local -a hostile=(
    "$good|${HEAD_SHA:0:7}|success|x"
    "$good|${HEAD_SHA^^}|success|x"
    "$good|${HEAD_SHA}0|success|x"
    "$good|HEAD|success|x"
    "$good|main|success|x"
    "$good|$HEAD_SHA -X PUT|success|x"
    "$good|../../pulls/5/merge|success|x"
    "$good||success|x"
    "https://github.com/owner/proj/pulls/5/merge|$HEAD_SHA|success|x"
    "https://github.com/owner/proj/pull/5/merge|$HEAD_SHA|success|x"
    "https://github.com/owner/proj/pull/5 -X PUT|$HEAD_SHA|success|x"
    "https://github.com/owner/proj/pull/5/../../git/refs/heads/dev|$HEAD_SHA|success|x"
    "https://github.com/owner/proj/pull/0|$HEAD_SHA|success|x"
    "https://github.com/owner/proj/pull/5x|$HEAD_SHA|success|x"
    "http://github.com/owner/proj/pull/5|$HEAD_SHA|success|x"
    "https://github.com.evil.example/owner/proj/pull/5|$HEAD_SHA|success|x"
    "https://github.com/someone/else/pull/5|$HEAD_SHA|success|x"
    "repos/owner/proj/statuses/$HEAD_SHA|$HEAD_SHA|success|x"
    "$good|$HEAD_SHA|pending|x"
    "$good|$HEAD_SHA|error|x"
    "$good|$HEAD_SHA|success -f context=ci|x"
    "$good|$HEAD_SHA|SUCCESS|x"
    "$good|$HEAD_SHA|success|"
    "$good|$HEAD_SHA|success|$(printf 'one\ntwo')"
    "$good|$HEAD_SHA|success|$(printf 'tab\there')"
    "$good|$HEAD_SHA|success|$(printf '%141s' x)"
  )
  local case url sha state description
  for case in "${hostile[@]}"; do
    IFS='|' read -r -d '' url sha state description <<<"$case" || true
    description=${description%$'\n'}
    run_bin team-review-status "$url" "$sha" "$state" "$description"
    [[ $status -ne 0 ]] || { echo "allowed: $case" >&2; return 1; }
  done
  assert_equal "$(stub_calls gh)" ""
}

@test "a description of 140 characters is the longest taken" {
  run_bin -0 team-review-status https://github.com/owner/proj/pull/5 "$HEAD_SHA" success "$(printf '%140s' x)"
}

@test "a PR that moved past the reviewed head sets nothing" {
  run_bin -1 team-review-status https://github.com/owner/proj/pull/5 0123456789abcdef0123456789abcdef01234567 success x
  assert_equal "$output" "team-review-status: https://github.com/owner/proj/pull/5 moved past the reviewed 0123456789abcdef0123456789abcdef01234567: its head is now $HEAD_SHA; nothing set"
  assert_equal "$(stub_calls gh | jq -r '.[0]')" pr
}

@test "a PR gh cannot read sets nothing" {
  rm "$STUB_FIXTURES/gh.sh"
  stub_reply gh "" 1
  run_bin -1 team-review-status https://github.com/owner/proj/pull/5 "$HEAD_SHA" success x
  assert_contains "$output" "cannot read the head of https://github.com/owner/proj/pull/5"
  assert_equal "$(stub_calls gh | wc -l)" 1
}

@test "a status GitHub refuses is a failure" {
  stub_script gh <<'SH'
case $1 in
  pr) echo "$HEAD_SHA" ;;
  api) echo 'HTTP 403' >&2 && exit 1 ;;
esac
SH
  run_bin -1 team-review-status https://github.com/owner/proj/pull/5 "$HEAD_SHA" success x
  assert_contains "$output" "GitHub refused the status"
}

@test "a planner, builder or ops session is refused with nothing set; a reviewer, the coordinator and a terminal set it" {
  local role
  for role in planner builder ops; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 --separate-stderr team-review-status \
      https://github.com/owner/proj/pull/5 "$HEAD_SHA" success "no blocking findings"
    assert_equal "$output" ""
    assert_equal "$stderr" "team-review-status: a $role session sets no agent-review status: that is a reviewer's or the coordinator's; send the coordinator your message"
  done
  assert_equal "$(stub_calls gh)" ""
  AGENT_TEAM_ROLE=builder run_bin -0 team-review-status --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-review-status")"
  for role in reviewer coordinator ''; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -0 team-review-status https://github.com/owner/proj/pull/5 "$HEAD_SHA" success "no blocking findings"
    assert_equal "$output" "agent-review success on Owner/Proj@$HEAD_SHA"
  done
  assert_equal "$(stub_calls gh | grep -c statuses)" 3
}

@test "on the team's own project with the reviewer App on, it sets nothing and sends the reviewer to the coordinator; on another project and with the App off, it sets the status" {
  # proj is the team's own once its repo is the code checkout's origin.
  code_checkout
  git -C "${CODE_CHECKOUT:?}" remote set-url origin git@github.com:Owner/Proj.git
  review_app_on
  local role
  for role in reviewer coordinator ''; do
    AGENT_TEAM_ROLE=$role AGENT_TEAM_TASK=T7 run_bin -1 --separate-stderr team-review-status \
      https://github.com/owner/proj/pull/5 "$HEAD_SHA" success "no blocking findings"
    assert_equal "$output" ""
    assert_equal "$stderr" "team-review-status: the reviewer App posts agent-review on proj: send your verdict to the coordinator, whose team-next posts it"
  done
  assert_equal "$(stub_calls gh)" ""
  assert_equal "$(stub_calls team-review-check)" ""
  # Another project's PR, with the App on: the status, as before.
  git -C "${CODE_CHECKOUT:?}" remote set-url origin git@github.com:owner/agent-team.git
  run_bin -0 team-review-status https://github.com/owner/proj/pull/5 "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "agent-review success on Owner/Proj@$HEAD_SHA"
  # The team's own project with the App off: the status, as before.
  git -C "${CODE_CHECKOUT:?}" remote set-url origin git@github.com:Owner/Proj.git
  rm "$CODE_CHECKOUT/bin/lib/review-app"
  run_bin -0 team-review-status https://github.com/owner/proj/pull/5 "$HEAD_SHA" failure "2 blocking"
  assert_equal "$output" "agent-review failure on Owner/Proj@$HEAD_SHA"
  assert_equal "$(stub_calls gh | grep -c statuses)" 2
  # The reviewer's role says the verdict alone goes there.
  grep -qF 'On a project whose `agent-review` the reviewer App posts, `team-review-status` refuses and says so: set no status there, and send your verdict alone' \
    "$REPO_ROOT/roles/reviewer.md"
}

@test "--merge-group sets success on the queue's trial commit that is the reviewed head merged cleanly onto the entry's base" {
  queued_pr
  local trial
  trial=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD")
  queue_entry "$trial"
  run ! git -C "${QUEUE_PRIMARY:?}" cat-file -e "$trial"
  run_bin -0 team-review-status --merge-group "$URL" "$trial"
  assert_equal "$output" "agent-review success on Owner/Proj@$trial"
  # GitHub is read for the PR's queue entry alone, then the status goes on the trial commit.
  assert_equal "$(stub_calls gh | jq -c 'if .[1] == "graphql" then [.[0, 1], .[4:][]] else . end')" "$(jq -cn --arg trial "$trial" --arg head "${QUEUE_HEAD:0:7}" '
    ["api", "graphql", "-f", "owner=Owner", "-f", "name=Proj", "-F", "number=5"],
    ["api", "--method", "POST", "repos/Owner/Proj/statuses/\($trial)", "-f", "state=success", "-f", "context=agent-review",
      "-f", "description=the merge queue'"'"'s clean merge of the reviewed head \($head)"]')"
  assert_equal "$(git -C "${QUEUE_PRIMARY:?}" status --porcelain)" ""
}

@test "--merge-group refuses a trial commit with any problem, naming the first, and sets nothing" {
  queued_pr
  local clean trial later other
  clean=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD")
  group_refused "$clean" "Owner/Proj#5 is not in the merge queue"
  queue_entry "$QUEUE_HEAD"
  group_refused "$clean" "${clean:0:7} is not the trial commit of Owner/Proj#5's queue entry, which is ${QUEUE_HEAD:0:7}"
  queue_entry "$clean" UNMERGEABLE
  group_refused "$clean" "the queue entry of Owner/Proj#5 is UNMERGEABLE"
  trial=$(trial_commit "$QUEUE_BASE" '' "$clean")
  queue_entry "$trial"
  group_refused "$trial" "${trial:0:7} is a commit of its own, not a merge of the PR's head"
  # A second parent that is not the PR's head: a commit pushed after the review.
  other=$(git -C "${QUEUE_PRIMARY:?}" commit-tree "$(git -C "${QUEUE_PRIMARY:?}" rev-parse "$QUEUE_HEAD^{tree}")" -p "$QUEUE_HEAD" -m "feat: unreviewed")
  git -C "${QUEUE_PRIMARY:?}" push -q origin "$other:refs/heads/feat/unreviewed"
  trial=$(trial_commit "$QUEUE_BASE" "$other")
  queue_entry "$trial"
  group_refused "$trial" "${trial:0:7} merges ${other:0:7}, which is not the PR's head ${QUEUE_HEAD:0:7}"
  # A first parent that lacks the entry's base.
  later=$(push_to_dev "$QUEUE_ORIGIN" src/later.py)
  queue_entry "$clean" AWAITING_CHECKS "$later"
  group_refused "$clean" "${clean:0:7} merges the head onto ${QUEUE_BASE:0:7}, which does not hold the queue entry's base ${later:0:7}"
  # A tree that is not the merge of its parents.
  trial=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD" "$QUEUE_HEAD")
  queue_entry "$trial"
  group_refused "$trial" "${trial:0:7} changes more than the merge of its parents"
  # A project that does not merge with a merge commit.
  queue_entry "$clean"
  sed -i 's/^merge_method = "merge"/merge_method = "squash"/' "$TEAM_HOME/projects.toml"
  group_refused "$clean" "proj merges with squash, and a trial commit is proved only for merge"
  # An entry that cannot be read: exit 75, to try again.
  echo "HTTP 502: Bad Gateway" >"$GH_DIR/entry.error"
  GROUP_STATUS=75 group_refused "$clean" "the merge queue entry of Owner/Proj#5 cannot be read: gh api graphql: HTTP 502: Bad Gateway"
}

@test "--merge-group refuses a clean trial commit of a PR no task logged, or of a head whose latest review is not a pass" {
  queue_repo proj
  URL=https://github.com/owner/proj/pull/5
  local trial
  trial=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD")
  queue_entry "$trial"
  group_refused "$trial" "no task's pr event names $URL"
  assert_equal "$(stub_calls gh)" ""
  jq -cn --arg url "$URL" --arg head "$QUEUE_HEAD" '
    {task: "T9", event: "opened", project: "proj"},
    {task: "T9", event: "pr", url: $url, project: "proj", head: $head}' >>"$TEAM_HOME/ledger.jsonl"
  group_refused "$trial" "T9 logged no review of ${QUEUE_HEAD:0:7}"
  jq -cn --arg head "$QUEUE_HEAD" '{task: "T9", event: "review", verdict: "pass", head: $head, ts: "2026-11-14T09:00:00Z"},
    {task: "T9", event: "review", verdict: "findings", head: $head, ts: "2026-11-14T10:00:00Z"}' >>"$TEAM_HOME/ledger.jsonl"
  group_refused "$trial" "T9's latest review of ${QUEUE_HEAD:0:7}, at 2026-11-14T10:00:00Z, is findings"
}

@test "--merge-group takes a PR URL and a full sha, nothing more or less, and is refused as the head form is" {
  local url=https://github.com/owner/proj/pull/5
  local -a cases=(
    "--merge-group"
    "--merge-group $url"
    "--merge-group $url $HEAD_SHA success"
    "--merge-group $url ${HEAD_SHA:0:7}"
    "--merge-group $url/files $HEAD_SHA"
    "$url --merge-group $HEAD_SHA"
  )
  local args
  for args in "${cases[@]}"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 team-review-status $args
  done
  # A builder is refused before anything is read, and the App's own project sends to the coordinator.
  AGENT_TEAM_ROLE=builder run_bin -1 team-review-status --merge-group "$url" "$HEAD_SHA"
  assert_contains "$output" "a builder session sets no agent-review status"
  cat >>"$TEAM_HOME/projects.toml" <<'TOML'

[agent-team]
repo = "Owner/agent-team"
path = "projects/agent-team"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[agent-team.pool]
provider = "git"
slots = ["slots/agent-team/1"]
TOML
  run_bin -1 team-review-status --merge-group https://github.com/owner/agent-team/pull/5 "$HEAD_SHA"
  assert_contains "$output" "the reviewer App posts agent-review on agent-team"
  assert_equal "$(stub_calls gh)" ""
}
