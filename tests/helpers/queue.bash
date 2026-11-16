# A merge queue's trial commits on a real origin, and the gh that answers for them, for the tests
# of queue_commit_problems (bin/lib/team.sh) through the scripts that call it. Load after
# helpers/common, and call queue_repo once the test's sandbox and registry are made.

# queue_repo <project>: <project>'s origin and primary checkout (make_repo, on dev) with PR 5's
# branch pushed and dev moved on after it on origin alone, so the primary checkout holds neither
# the base nor a trial commit until a script fetches them. Sets QUEUE_ORIGIN, QUEUE_PRIMARY,
# QUEUE_HEAD (the PR's head), QUEUE_BASE (origin's dev, the queue entry's base) and GH_DIR, whose
# files queue_gh's gh answers from, with the PR in no queue yet.
queue_repo() {
  QUEUE_PRIMARY=$(make_repo "$1" dev)
  QUEUE_ORIGIN=$BATS_TEST_TMPDIR/origin/$1.git
  git -C "${QUEUE_PRIMARY:?}" checkout -q -b feat/T9-tooling
  mkdir -p "$QUEUE_PRIMARY/src"
  echo tool >"$QUEUE_PRIMARY/src/tool.py"
  git -C "${QUEUE_PRIMARY:?}" add src/tool.py
  git -C "${QUEUE_PRIMARY:?}" commit -q -m "feat: the tool"
  git -C "${QUEUE_PRIMARY:?}" push -q origin feat/T9-tooling
  git -C "${QUEUE_PRIMARY:?}" checkout -q dev
  QUEUE_HEAD=$(git -C "${QUEUE_PRIMARY:?}" rev-parse feat/T9-tooling)
  QUEUE_BASE=$(push_to_dev "$QUEUE_ORIGIN" src/other.py)
  export GH_DIR=$BATS_TEST_TMPDIR/gh
  mkdir -p "$GH_DIR"
  echo '{"check_runs": []}' >"$GH_DIR/runs.json"
  queue_entry
  queue_gh
}

# trial_commit <first parent> <second parent or ''> [<tree-ish>]: a commit of those parents on
# origin, made in a clone of its own and pushed to a branch of the queue's, as GitHub builds a
# trial commit; its tree is the clean merge of the two unless <tree-ish> gives another. Prints it.
trial_commit() {
  local clone=$BATS_TEST_TMPDIR/queue-clone tree sha
  local -a parents=(-p "$1")
  [[ -d $clone ]] || git clone -q "$QUEUE_ORIGIN" "$clone" 2>/dev/null
  git -C "${clone:?}" fetch -q origin
  [[ -z $2 ]] || parents+=(-p "$2")
  if [[ -n ${3:-} ]]; then
    tree=$(git -C "${clone:?}" rev-parse "$3^{tree}")
  else
    tree=$(git -C "${clone:?}" merge-tree --write-tree "$1" "$2")
  fi
  sha=$(git -C "${clone:?}" commit-tree "$tree" "${parents[@]}" -m "Merge pull request #5")
  git -C "${clone:?}" push -q origin "$sha:refs/heads/gh-readonly-queue/dev/pr-5-$sha"
  echo "$sha"
}

# queue_entry [<trial sha> [<state> [<base>]]]: PR 5's queue entry as GraphQL answers it, its
# head commit <trial sha>, its state AWAITING_CHECKS and its base QUEUE_BASE by default; with no
# argument the PR is in no queue.
queue_entry() {
  jq -n --arg head "$QUEUE_HEAD" --arg trial "${1:-}" --arg state "${2:-AWAITING_CHECKS}" --arg base "${3:-$QUEUE_BASE}" '
    {data: {repository: {pullRequest: {headRefOid: $head, mergeQueueEntry: (if $trial == "" then null
      else {state: $state, headCommit: {oid: $trial}, baseCommit: {oid: $base}} end)}}}}' >"$GH_DIR/entry.json"
}

# head_check <app id> <conclusion>: the PR's head carries an agent-review check run of that App.
head_check() {
  jq -n --arg head "$QUEUE_HEAD" --argjson app "$1" --arg conclusion "$2" '{check_runs: [{id: 9, name: "agent-review",
    head_sha: $head, status: "completed", conclusion: $conclusion, app: {id: $app, slug: "an-app"}}]}' >"$GH_DIR/runs.json"
}

# gh answers from GH_DIR: the GraphQL read of the queue entry (entry.json, or a failure with
# entry.error's text once that exists), the agent-review check runs of a commit (runs.json), a
# status POST ({"state": "success"}), and PR 5's head for gh pr view.
queue_gh() {
  export QUEUE_HEAD
  stub_script gh <<'SH'
case "$1 $2" in
  "api graphql")
    if [[ -e $GH_DIR/entry.error ]]; then cat "$GH_DIR/entry.error" >&2; exit 1; fi
    cat "$GH_DIR/entry.json"
    ;;
  "api --method") echo '{"state": "success"}' ;;
  "api repos/"*/check-runs\?*) cat "$GH_DIR/runs.json" ;;
  "pr view") echo "$QUEUE_HEAD" ;;
  *) echo "gh stub: no answer for $*" >&2; exit 99 ;;
esac
SH
}
