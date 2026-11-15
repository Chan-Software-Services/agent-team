#!/usr/bin/env bats
# team-current: the coordinator's current items in the team home's tasks/current.md and the
# assistant's in assistant/current.md, added with a close condition or a review date, listed and
# removed by a short id, renewed, closed and moved over by reconcile, checked against the manual's
# rules, each change committed alone.

load helpers/common

# Now, as TEAM_CURRENT_NOW gives it to every run, and the ends it makes.
NOW=2026-11-15T10:00:00Z
ADDED="added $NOW"
# --review's end, 3 days out, and the tail of a line added with it.
REVIEW="review 2026-11-18"
TAIL=" | $REVIEW | $ADDED"

setup() {
  sandbox
  export TEAM_CURRENT_NOW=$NOW
  mkdir -p "$TEAM_HOME/tasks/queued" "$TEAM_HOME/tasks/T4" "$TEAM_HOME/assistant"
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  echo "# Node pin" >"$TEAM_HOME/tasks/queued/node-pin.md"
  echo "# Plan" >"$TEAM_HOME/tasks/T4/plan.md"
  printf '# Current items\n' >"$TEAM_HOME/tasks/current.md"
  team_origin=$(make_team_home)
  current=$TEAM_HOME/tasks/current.md
  mine=$TEAM_HOME/assistant/current.md
  # The team home under HOME, as ~/team, for a where in the ~/ form.
  ln -s "$TEAM_HOME" "$HOME/team"
  # A where as the coordinator types it, starting with a literal ~/.
  tilde='~'
}

# The id of an item line: the first 6 hex digits of the sha256 of the line without its "- ".
id_of() {
  printf '%s' "${1#- }" | sha256sum | cut -c1-6
}

# The subject of the team home's last commit, and the paths it changed, on one line each.
last_commit() {
  git -C "${TEAM_HOME:?}" log -1 --format=%s
  git -C "${TEAM_HOME:?}" show --name-only --format= HEAD
}

# Commit what the test wrote in the team home.
commit_all() {
  git -C "${TEAM_HOME:?}" add -A
  git -C "${TEAM_HOME:?}" commit -q -m "chore: items"
}

# The team home's commit subjects since <rev>, oldest first: subjects_since <rev>
subjects_since() {
  git -C "${TEAM_HOME:?}" log --reverse --format=%s "$1..HEAD"
}

@test "add prints the item's id and appends its line with its end and added; list prints each item with its id" {
  run_bin -0 --separate-stderr team-current add owe - the T4 summary, my move --where https://discord.com/channels/1/2/3 --review
  local first="- owe - the T4 summary, my move | https://discord.com/channels/1/2/3$TAIL"
  assert_equal "${lines[0]}" "$(id_of "$first")"
  [[ ${lines[0]} =~ ^[0-9a-f]{6}$ ]]
  run_bin -0 team-current add next T4 "once it merges, open the Node pin task" --until "task T4 merged" --where tasks/queued/node-pin.md
  local second="- next T4 once it merges, open the Node pin task | tasks/queued/node-pin.md | until task T4 merged | $ADDED"
  run_bin -0 team-current add watch - the CI wait --where "ledger 2026-11-01T07:08:11Z" --review-by 2026-11-22
  local third="- watch - the CI wait | ledger 2026-11-01T07:08:11Z | review 2026-11-22 | $ADDED"
  assert_equal "$(cat "$current")" "# Current items
$first
$second
$third"
  run_bin -0 team-current list
  assert_equal "$output" "$(id_of "$first") ${first#- }
$(id_of "$second") ${second#- }
$(id_of "$third") ${third#- }"
}

@test "add takes exactly one end, refusing none, two, a review date out of range and each malformed condition" {
  local before head
  before=$(cat "$current") head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  check_refusal() {
    local reason=$1
    shift
    run_bin -1 --separate-stderr team-current add next - a thing --where tasks/queued/node-pin.md "$@"
    assert_contains "$stderr" "$reason"
    assert_equal "$(cat "$current")" "$before"
    assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
  }
  local needs="an item needs a close condition (--until) or a review date (--review, 3 days out, or --review-by, at most 7)"
  check_refusal "$needs"
  check_refusal "$needs" --review --until "task T4 merged"
  check_refusal "$needs" --review --review-by 2026-11-16
  check_refusal "$needs" --until "task T4 merged" --until "task T4 closed"
  check_refusal "the review date 2026-11-23 is more than 7 days out (at most 2026-11-22)" --review-by 2026-11-23
  check_refusal "the review date 2026-11-14 is before today (2026-11-15)" --review-by 2026-11-14
  check_refusal "the review date 'tomorrow' is not a YYYY-MM-DD date" --review-by tomorrow
  check_refusal "the review date '2026-11-31' is not a YYYY-MM-DD date" --review-by 2026-11-31
  local grammar="is not one of: handoff H<n> answered, task T<n> opened|closed|merged, ledger T<n> <kind>, pr <GitHub PR URL> merged, or file <path>"
  check_refusal "the condition 'task T4 done' $grammar" --until "task T4 done"
  check_refusal "the condition 'task 4 merged' $grammar" --until "task 4 merged"
  check_refusal "the condition 'handoff 3 answered' $grammar" --until "handoff 3 answered"
  check_refusal "the condition 'handoff H3 sent' $grammar" --until "handoff H3 sent"
  check_refusal "the condition 'pr https://gitlab.com/o/r/pull/7 merged' $grammar" --until "pr https://gitlab.com/o/r/pull/7 merged"
  check_refusal "the condition 'pr https://github.com/o/r/pull/7 closed' $grammar" --until "pr https://github.com/o/r/pull/7 closed"
  check_refusal "the condition 'soon' $grammar" --until soon
  check_refusal "the condition's kind 'reviewed' is not a ledger kind (team-log --help lists them)" --until "ledger T4 reviewed"
  check_refusal "the condition's path 'tasks/../../etc/hosts' is not in the team home: it holds '..'" --until "file tasks/../../etc/hosts"
  check_refusal "the condition's path '/etc/hosts' is not relative to the team home" --until "file /etc/hosts"
  check_refusal "the condition's path '$tilde/team/x' is not relative to the team home" --until "file $tilde/team/x"
  # Each form of the grammar is taken, and a review date from today to 7 days out.
  local end
  for end in "handoff H3 answered" "task T4 opened" "task T4 closed" "task T4 merged" "ledger T4 review" \
    "pr https://github.com/owner/proj/pull/7 merged" "file tasks/T4/review.md"; do
    run_bin -0 team-current add next - "wait for $end" --where tasks/queued/node-pin.md --until "$end"
  done
  run_bin -0 team-current add next - due today --where tasks/queued/node-pin.md --review-by 2026-11-15
  run_bin -0 team-current add next - due in a week --where tasks/queued/node-pin.md --review-by 2026-11-22
  assert_equal "$(grep -c '^- ' "$current")" 9
  run_bin -0 team-current check
}

@test "done with the id or a unique 4-digit prefix removes exactly that line" {
  local a="- ask - which domain for the docs site, Daniel's move | 1563000000000000045$TAIL"
  local b="- watch T4 the CI wait on PR 7, re-arm with team-ci-wait | ledger 2026-11-01T07:08:11Z$TAIL"
  local c="- next - the Node pin | ~/team/tasks/queued/node-pin.md | until task T4 closed | $ADDED"
  printf '%s\n' "# Current items" "" "$a" "$b" "$c" >"$current"
  commit_all
  run_bin -0 team-current "done" "$(id_of "$b")"
  assert_contains "$output" "removed $(id_of "$b") ${b#- }"
  assert_equal "$(cat "$current")" "$(printf '%s\n' "# Current items" "" "$a" "$c")"
  local prefix
  prefix=$(id_of "$a")
  run_bin -0 team-current "done" "${prefix:0:4}"
  assert_equal "$(cat "$current")" "$(printf '%s\n' "# Current items" "" "$c")"
}

@test "add refuses each line the manual does not allow, file unchanged and nothing committed" {
  local before head long
  printf '%s\n' "# Current items" "- next T4 open the Node pin task | tasks/queued/node-pin.md$TAIL" >"$current"
  commit_all
  before=$(cat "$current") head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  long=$(printf 'x%.0s' {1..280})
  mkdir -p "$BATS_TEST_TMPDIR/job"
  echo out >"$BATS_TEST_TMPDIR/job/out.md"
  check_refusal() {
    local reason=$1
    shift
    run_bin -1 --separate-stderr team-current add "$@" --review
    assert_contains "$stderr" "$reason"
    assert_equal "$(cat "$current")" "$before"
    assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
    assert_equal "$(git -C "${TEAM_HOME:?}" status --porcelain)" ""
  }
  check_refusal "kind 'todo' is not ask, owe, next or watch" todo - a thing --where tasks/queued/node-pin.md
  check_refusal "queued work is a file in tasks/queued/ with front matter, which team-queue index lists, never a current item" \
    queued - the Node pin --where tasks/queued/node-pin.md
  check_refusal "task 'T4a' is not T<n> or -" next T4a a thing --where tasks/queued/node-pin.md
  check_refusal "task '-:' is not T<n> or -" next -: a thing --where tasks/queued/node-pin.md
  check_refusal "the text holds ' | '" next - "a | b" --where tasks/queued/node-pin.md
  check_refusal "the text holds a newline" next - "a
b" --where tasks/queued/node-pin.md
  # 300 characters up to the where; the end and added are not counted.
  check_refusal "the line is 316 characters, over 300" next - "$long" --where tasks/queued/node-pin.md
  check_refusal "the where '/tmp/notes.md' is a temp path" next - a thing --where /tmp/notes.md
  check_refusal "the where '/var/tmp/x' is a temp path" next - a thing --where /var/tmp/x
  check_refusal "the where '/var/folders/ab/T/x' is a temp path" next - a thing --where /var/folders/ab/T/x
  check_refusal "the where '/private/var/folders/ab/T/x' is a temp path" next - a thing --where /private/var/folders/ab/T/x
  check_refusal "the where '$tilde/.claude/jobs/0a0b0c0d/tmp/x.md' is a temp path" next - a thing --where "$tilde/.claude/jobs/0a0b0c0d/tmp/x.md"
  check_refusal "the where '$BATS_TEST_TMPDIR/job/out.md' is a temp path" next - a thing --where "$BATS_TEST_TMPDIR/job/out.md"
  # /etc/hosts is a file outside the team home and every temp directory, unless TMPDIR names /etc.
  check_refusal "the where '/etc/hosts' is not a file in the team home" next - a thing --where /etc/hosts
  check_refusal "the where 'tasks/queued/gone.md' is not a file in the team home" next - a thing --where tasks/queued/gone.md
  check_refusal "the where 'tasks/queued' is not a file in the team home" next - a thing --where tasks/queued
  local up=tasks/../../../../../../../../../../../../../../../etc/hosts
  check_refusal "the where '$up' is not a file in the team home" next - a thing --where "$up"
  check_refusal "the where 'ledger' is not a file in the team home" next - a thing --where ledger
  check_refusal "the where 'ledger yesterday' is not a file in the team home" next - a thing --where "ledger yesterday"
  check_refusal "the where holds ' | '" next - a thing --where "tasks/queued/node-pin.md | x"
  # The same item up to its where is a duplicate, whatever its end.
  check_refusal "the item is already in tasks/current.md, at line 2" next T4 open the Node pin task --where tasks/queued/node-pin.md
}

@test "add takes each where the manual allows: a URL, a Discord id, a ledger time and a team-home path in each form" {
  local where
  for where in https://github.com/owner/proj/pull/7 "https://discord.com/channels/1/2/3" 1563000000000000045 \
    "Discord 1563000000000000045" "ledger 2026-11-01T07:08:11Z" tasks/queued/node-pin.md \
    "$TEAM_HOME/tasks/queued/node-pin.md" "$tilde/team/tasks/queued/node-pin.md"; do
    run_bin -0 team-current add next - "pin Node for $where" --where "$where" --review
  done
  assert_equal "$(grep -c '^- ' "$current")" 8
  # 300 characters up to the where, counted as characters, not bytes.
  local text='' i
  for ((i = 0; i < 264; i++)); do text+=$'\xc3\xa9'; done
  run_bin -0 team-current add next - "$text" --where tasks/queued/node-pin.md --review
  run_bin -1 team-current add next - "${text}x" --where tasks/queued/node-pin.md --review
  run_bin -0 team-current check
}

@test "done refuses an id that matches no item or two, file unchanged" {
  local item="- next T4 open the Node pin task | tasks/queued/node-pin.md$TAIL"
  printf '%s\n' "# Current items" "$item" "$item" "- owe - a reply | 1563000000000000045$TAIL" >"$current"
  commit_all
  local before
  before=$(cat "$current")
  run_bin -1 --separate-stderr team-current "done" "$(id_of "$item")"
  assert_contains "$stderr" "$(id_of "$item") matches 2 items:"
  assert_equal "$(cat "$current")" "$before"
  run_bin -1 --separate-stderr team-current "done" 000000
  assert_contains "$stderr" "000000 matches no item"
  assert_equal "$(cat "$current")" "$before"
  run_bin -2 team-current "done" abc
  run_bin -2 team-current "done" 12345g
  assert_equal "$(git -C "${TEAM_HOME:?}" status --porcelain)" ""
}

@test "check names each bad line with its reason and exits 1, never writing; a clean file passes" {
  cat >"$current" <<EOF
# Current items

- next T4 open the Node pin task | tasks/queued/node-pin.md$TAIL
- next -: branch cleanup | tasks/queued/node-pin.md$TAIL
- next T4 a progress line | ledger$TAIL
- todo - something | tasks/queued/node-pin.md$TAIL
- ask - two wheres | tasks/queued/node-pin.md | ledger 2026-11-01T07:08:11Z | $REVIEW | $ADDED
- owe - no where at all
- watch - the scratch | /tmp/watch.log$TAIL
- next T4 open the Node pin task | tasks/queued/node-pin.md | until task T4 merged | $ADDED
Not an item: a note under the list.
- owe - the old form | 1563000000000000045
- owe - no added | 1563000000000000045 | $REVIEW
- owe - no end | 1563000000000000045 | $ADDED
- owe - an unknown condition | 1563000000000000045 | until it is done | $ADDED
- owe - a bad end | 1563000000000000045 | soon | $ADDED
- owe - a bad added | 1563000000000000045 | $REVIEW | added yesterday
- owe - a review too far | 1563000000000000045 | review 2026-11-23 | $ADDED
- owe - a review a week out | 1563000000000000045 | review 2026-11-22 | $ADDED
- owe - a review long past | 1563000000000000045 | review 2026-10-02 | added 2026-09-30T08:00:00Z
EOF
  commit_all
  run_bin -1 team-current check
  assert_equal "$output" "tasks/current.md:4: task '-:' is not T<n> or -
tasks/current.md:5: the where 'ledger' is not a file in the team home
tasks/current.md:6: kind 'todo' is not ask, owe, next or watch
tasks/current.md:7: the line holds ' | ' more than 3 times
tasks/current.md:8: the line has no ' | <where>'
tasks/current.md:9: the where '/tmp/watch.log' is a temp path
tasks/current.md:10: the item is already in tasks/current.md, at line 3
tasks/current.md:11: not an item line (- <kind> <task or -> <text> | <where> | <end> | added <UTC time>)
tasks/current.md:12: the line is in the old form, with no end and no added time: team-current reconcile moves it over
tasks/current.md:13: the line has no added time (| added <UTC time>)
tasks/current.md:14: the line has no end (| until <condition> or | review <YYYY-MM-DD>)
tasks/current.md:15: the condition 'it is done' is not one of: handoff H<n> answered, task T<n> opened|closed|merged, ledger T<n> <kind>, pr <GitHub PR URL> merged, or file <path>
tasks/current.md:16: the end 'soon' is not until <condition> or review <YYYY-MM-DD>
tasks/current.md:17: the added 'added yesterday' is not added <UTC time>
tasks/current.md:18: the review date 2026-11-23 is more than 7 days after the item was added (2026-11-15)"
  assert_equal "$(git -C "${TEAM_HOME:?}" status --porcelain)" ""
  printf '%s\n' "# Current items" "" "- next T4 open the Node pin task | tasks/queued/node-pin.md$TAIL" >"$current"
  run_bin -0 team-current check
  assert_equal "$output" ""
  printf '%s\n' "# Current items" "- next - the hosts | /etc/hosts$TAIL" >"$current"
  run_bin -1 team-current check
  assert_equal "$output" "tasks/current.md:2: the where '/etc/hosts' is not a file in the team home"
  # A path under TMPDIR is a temp path, wherever TMPDIR is.
  TMPDIR=/etc run_bin -1 team-current check
  assert_equal "$output" "tasks/current.md:2: the where '/etc/hosts' is a temp path"
  rm "$current"
  run_bin -0 team-current check
  run_bin -0 team-current list
  assert_equal "$output" ""
}

# Close task <T<n>> at <ts> in the sandbox's ledger, after its opened: closed_task <T<n>> <ts>
closed_task() {
  opened_task "$1"
  jq -cn --arg task "$1" --arg ts "$2" '{ts: $ts, task: $task, event: "closed"}' >>"$TEAM_HOME/ledger.jsonl"
}

@test "check names each item whose task closed, with its id, and exits 1; an open task's item and a - item pass" {
  closed_task T181 2026-11-02T01:31:49Z
  opened_task T4
  closed_task T9 2026-11-05T10:00:00Z
  local a="- next T181 open the rest of the refactor | tasks/queued/node-pin.md$TAIL"
  local b="- watch T4 the CI wait on PR 7 | ledger 2026-11-01T07:08:11Z$TAIL"
  local c="- owe - a reply | 1563000000000000045$TAIL"
  local d="- watch T9 the scratch | /tmp/watch.log$TAIL"
  local e="- ask T77 a task the ledger does not hold | 1563000000000000045$TAIL"
  printf '%s\n' "# Current items" "" "$a" "$b" "$c" "$d" "$e" >"$current"
  commit_all
  run_bin -1 team-current check
  assert_equal "$output" "tasks/current.md:3: T181 closed at 2026-11-02T01:31:49Z; done it (team-current done $(id_of "$a")) or add it again under an open task
tasks/current.md:6: the where '/tmp/watch.log' is a temp path
tasks/current.md:6: T9 closed at 2026-11-05T10:00:00Z; done it (team-current done $(id_of "$d")) or add it again under an open task"
  assert_equal "$(git -C "${TEAM_HOME:?}" status --porcelain)" ""
  # With no closed task named, the file passes.
  printf '%s\n' "# Current items" "$b" "$c" "$e" >"$current"
  run_bin -0 team-current check
  assert_equal "$output" ""
  # With no ledger at all, no task is closed.
  rm "$TEAM_HOME/ledger.jsonl"
  printf '%s\n' "# Current items" "$a" >"$current"
  run_bin -0 team-current check
}

@test "check --json prints team-current-check/1, its problems and closed items, exiting as the text form does" {
  closed_task T181 2026-11-02T01:31:49Z
  opened_task T4
  local a="- next T181 open the rest of the refactor | tasks/queued/node-pin.md$TAIL"
  local b="- todo T4 something | tasks/queued/node-pin.md$TAIL"
  printf '%s\n' "# Current items" "$a" "$b" "Not an item." "- ask - no where" >"$current"
  commit_all
  run_bin -1 --separate-stderr team-current check --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg a "${a#- }" --arg ida "$(id_of "$a")" \
    --arg b "${b#- }" --arg idb "$(id_of "$b")" --arg e "ask - no where" --arg ide "$(id_of "- ask - no where")" '
    {schema: "team-current-check/1",
     problems: [
       {line: 3, id: $idb, item: $b, reasons: ["kind '\''todo'\'' is not ask, owe, next or watch"]},
       {line: 4, id: null, item: "Not an item.", reasons: ["not an item line (- <kind> <task or -> <text> | <where> | <end> | added <UTC time>)"]},
       {line: 5, id: $ide, item: $e, reasons: ["the line has no '\'' | <where>'\''"]}],
     closed: [{line: 2, id: $ida, item: $a, task: "T181", closed_at: "2026-11-02T01:31:49Z"}]}')"
  # Two reasons on one line are two entries of its reasons.
  printf '%s\n' "# Current items" "- todo T4a something | /etc/hosts" >"$current"
  run_bin -1 team-current check --json
  assert_equal "$(jq -c '.problems[0].reasons' <<<"$output")" \
    "[\"kind 'todo' is not ask, owe, next or watch\",\"task 'T4a' is not T<n> or -\",\"the where '/etc/hosts' is not a file in the team home\",\"the line is in the old form, with no end and no added time: team-current reconcile moves it over\"]"
  # A clean file, and no file, print empty lists and exit 0.
  printf '%s\n' "# Current items" "- next T4 open the Node pin task | tasks/queued/node-pin.md$TAIL" >"$current"
  run_bin -0 team-current check --json
  assert_equal "$(jq -c . <<<"$output")" '{"schema":"team-current-check/1","problems":[],"closed":[]}'
  rm "$current"
  run_bin -0 team-current check --json
  assert_equal "$(jq -c . <<<"$output")" '{"schema":"team-current-check/1","problems":[],"closed":[]}'
  assert_equal "$(git -C "${TEAM_HOME:?}" status --porcelain)" " D tasks/current.md"
}

@test "add and done commit tasks/current.md alone and push it, another changed record left uncommitted" {
  echo "# Plan, changed" >"$TEAM_HOME/tasks/T4/plan.md"
  echo "a staged note" >"$TEAM_HOME/README.md"
  git -C "${TEAM_HOME:?}" add README.md
  run_bin -0 team-current add next T4 open the Node pin task --where tasks/queued/node-pin.md --review
  local id=${lines[0]}
  assert_contains "$output" "team home: committed"
  assert_equal "$(last_commit)" "chore: current next T4
tasks/current.md"
  assert_equal "$(git -C "${team_origin:?}" log -1 --format=%s dev)" "chore: current next T4"
  run_bin -0 team-current "done" "${id:0:4}"
  assert_equal "$(last_commit)" "chore: current done $id
tasks/current.md"
  assert_equal "$(git -C "${team_origin:?}" log -1 --format=%s dev)" "chore: current done $id"
  assert_equal "$(git -C "${TEAM_HOME:?}" status --porcelain)" "A  README.md
 M tasks/T4/plan.md"
}

@test "a commit the team home's hooks refuse undoes the change and fails" {
  local before head
  before=$(cat "$current") head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  printf '#!/bin/sh\necho "pre-commit: refused" >&2\nexit 1\n' >"$TEAM_HOME/.git/hooks/pre-commit"
  chmod +x "$TEAM_HOME/.git/hooks/pre-commit"
  run_bin -1 --separate-stderr team-current add next T4 open the Node pin task --where tasks/queued/node-pin.md --review
  assert_contains "$stderr" "pre-commit: refused"
  assert_contains "$stderr" "not committed, so the change is undone"
  assert_equal "$(cat "$current")" "$before"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
  assert_equal "$(git -C "${TEAM_HOME:?}" status --porcelain)" ""
}

@test "a push that fails keeps the commit for the next checkpoint and succeeds" {
  git -C "${TEAM_HOME:?}" remote set-url origin "$BATS_TEST_TMPDIR/no-such-origin.git"
  run_bin -0 --separate-stderr team-current add next T4 open the Node pin task --where tasks/queued/node-pin.md --review
  assert_contains "$stderr" "cannot push dev"
  assert_equal "$(last_commit)" "chore: current next T4
tasks/current.md"
}

@test "add creates the file with its title when there is none, each list's own" {
  rm "$current"
  run_bin -0 team-current add owe - the T4 summary --where 1563000000000000045 --review
  assert_equal "$(cat "$current")" "# Current items
- owe - the T4 summary | 1563000000000000045$TAIL"
  rm -r "${TEAM_HOME:?}/assistant"
  AGENT_TEAM_ROLE=assistant run_bin -0 team-current add owe - the login walkthrough --where 1563000000000000045 --review
  assert_equal "$(cat "$mine")" "# Assistant items
- owe - the login walkthrough | 1563000000000000045$TAIL"
  assert_equal "$(last_commit)" "chore: current owe -
assistant/current.md"
}

@test "--list picks the list, defaulting by role, and each session is refused edits of the other's" {
  local theirs="- next T4 open the Node pin task | tasks/queued/node-pin.md$TAIL"
  local own="- owe - the login walkthrough | 1563000000000000045$TAIL"
  printf '%s\n' "# Current items" "$theirs" >"$current"
  printf '%s\n' "# Assistant items" "$own" >"$mine"
  commit_all
  # The assistant's role reads its own list unless --list names the coordinator's; any other its.
  AGENT_TEAM_ROLE=assistant run_bin -0 team-current list
  assert_equal "$output" "$(id_of "$own") ${own#- }"
  AGENT_TEAM_ROLE=assistant run_bin -0 team-current list --list coordinator
  assert_equal "$output" "$(id_of "$theirs") ${theirs#- }"
  run_bin -0 team-current list
  assert_equal "$output" "$(id_of "$theirs") ${theirs#- }"
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-current --list assistant list
  assert_equal "$output" "$(id_of "$own") ${own#- }"
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-current check --list assistant
  local before_c before_a head
  before_c=$(cat "$current") before_a=$(cat "$mine") head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  local to_theirs="tasks/current.md is the coordinator's list: the assistant keeps its own, assistant/current.md (--list assistant), and hands the coordinator a note for its"
  local to_mine="assistant/current.md is the assistant's list, which only the assistant edits; the coordinator keeps tasks/current.md (--list coordinator)"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-current add next - a thing --where tasks/queued/node-pin.md --review --list coordinator
  assert_contains "$stderr" "$to_theirs"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-current "done" "$(id_of "$theirs")" --list coordinator
  assert_contains "$stderr" "$to_theirs"
  AGENT_TEAM_ROLE=assistant run_bin -1 --separate-stderr team-current renew "$(id_of "$theirs")" --review --reason x --list coordinator
  assert_contains "$stderr" "$to_theirs"
  local role
  for role in coordinator ""; do
    AGENT_TEAM_ROLE=$role run_bin -1 --separate-stderr team-current add next - a thing --where tasks/queued/node-pin.md --review --list assistant
    assert_contains "$stderr" "$to_mine"
    AGENT_TEAM_ROLE=$role run_bin -1 --separate-stderr team-current "done" "$(id_of "$own")" --list assistant
    assert_contains "$stderr" "$to_mine"
    AGENT_TEAM_ROLE=$role run_bin -1 --separate-stderr team-current renew "$(id_of "$own")" --review --reason x --list assistant
    assert_contains "$stderr" "$to_mine"
  done
  assert_equal "$(cat "$current")" "$before_c"
  assert_equal "$(cat "$mine")" "$before_a"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
  # Each edits its own.
  AGENT_TEAM_ROLE=assistant run_bin -0 team-current "done" "$(id_of "$own")"
  assert_equal "$(cat "$mine")" "# Assistant items"
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-current "done" "$(id_of "$theirs")"
  assert_equal "$(cat "$current")" "# Current items"
}

@test "renew sets a new review date, added now, with its reason in the commit; it refuses an until item, an old-form one and no reason" {
  local item="- owe - the T4 summary | 1563000000000000045 | review 2026-11-14 | added 2026-11-11T09:00:00Z"
  local until="- next T4 open the Node pin task | tasks/queued/node-pin.md | until task T4 merged | $ADDED"
  local old="- watch - the CI wait | ledger 2026-11-01T07:08:11Z"
  printf '%s\n' "# Current items" "$item" "$until" "$old" >"$current"
  commit_all
  run_bin -0 --separate-stderr team-current renew "$(id_of "$item")" --review --reason "Daniel is away until Tuesday"
  local renewed="- owe - the T4 summary | 1563000000000000045$TAIL"
  assert_contains "$output" "renewed $(id_of "$item") as $(id_of "$renewed"): ${renewed#- }"
  assert_equal "$(last_commit)" "chore: current renew $(id_of "$item") to 2026-11-18: Daniel is away until Tuesday
tasks/current.md"
  assert_equal "$(cat "$current")" "$(printf '%s\n' "# Current items" "$renewed" "$until" "$old")"
  run_bin -0 team-current renew "$(id_of "$renewed")" --review-by 2026-11-22 --reason "a week more"
  renewed="- owe - the T4 summary | 1563000000000000045 | review 2026-11-22 | $ADDED"
  assert_equal "$(sed -n 2p "$current")" "$renewed"
  local before head
  before=$(cat "$current") head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  run_bin -1 --separate-stderr team-current renew "$(id_of "$until")" --review --reason x
  assert_contains "$stderr" "$(id_of "$until") closes on its condition (until task T4 merged), so it takes no review date; done it once it is done"
  run_bin -1 --separate-stderr team-current renew "$(id_of "$old")" --review --reason x
  assert_contains "$stderr" "$(id_of "$old") is in the old form, with no end: team-current reconcile moves it over first"
  run_bin -1 --separate-stderr team-current renew "$(id_of "$renewed")" --review-by 2026-11-23 --reason x
  assert_contains "$stderr" "the review date 2026-11-23 is more than 7 days out (at most 2026-11-22)"
  run_bin -1 --separate-stderr team-current renew "$(id_of "$renewed")" --review-by 2026-11-10 --reason x
  assert_contains "$stderr" "the review date 2026-11-10 is before today (2026-11-15)"
  run_bin -1 --separate-stderr team-current renew "$(id_of "$renewed")" --review --reason "  "
  assert_contains "$stderr" "the reason is empty"
  run_bin -1 --separate-stderr team-current renew "$(id_of "$renewed")" --review --reason "a
b"
  assert_contains "$stderr" "the reason holds a newline"
  run_bin -1 --separate-stderr team-current renew "$(id_of "$renewed")" --review --review-by 2026-11-20 --reason x
  assert_contains "$stderr" "renew takes one new review date"
  run_bin -2 team-current renew "$(id_of "$renewed")" --review
  run_bin -2 team-current renew
  run_bin -2 team-current renew xyz --review --reason x
  assert_equal "$(cat "$current")" "$before"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
}

@test "due lists the items whose review date has come, as list prints them, and --json says them" {
  local past="- owe - the T4 summary | 1563000000000000045 | review 2026-11-12 | added 2026-11-11T09:00:00Z"
  local today="- ask - which domain | 1563000000000000045 | review 2026-11-15 | added 2026-11-12T09:00:00Z"
  local later="- next - the Node pin | tasks/queued/node-pin.md$TAIL"
  local until="- next T4 open it | tasks/queued/node-pin.md | until task T4 merged | added 2026-11-01T09:00:00Z"
  local old="- watch - the CI wait | ledger 2026-11-01T07:08:11Z"
  printf '%s\n' "# Current items" "$past" "$today" "$later" "$until" "$old" >"$current"
  run_bin -0 team-current due
  assert_equal "$output" "$(id_of "$past") ${past#- }
$(id_of "$today") ${today#- }"
  run_bin -0 team-current due --json
  assert_equal "$(jq -c . <<<"$output")" "$(jq -cn --arg p "${past#- }" --arg ip "$(id_of "$past")" --arg t "${today#- }" --arg it "$(id_of "$today")" '
    {schema: "team-current-due/1", list: "coordinator", file: "tasks/current.md", today: "2026-11-15",
     items: [{line: 2, id: $ip, item: $p, review: "2026-11-12"}, {line: 3, id: $it, item: $t, review: "2026-11-15"}]}')"
  # Nothing due, and no list, print nothing and pass.
  TEAM_CURRENT_NOW=2026-11-11T00:00:00Z run_bin -0 team-current due
  assert_equal "$output" ""
  run_bin -0 team-current due --list assistant
  assert_equal "$output" ""
  run_bin -0 team-current due --list assistant --json
  assert_equal "$(jq -c .items <<<"$output")" "[]"
  run_bin -2 team-current due extra
}

@test "reconcile closes each until item whose condition holds, one commit each, and keeps each that does not" {
  opened_task T4
  opened_task T5
  jq -cn '{ts: "2026-11-14T09:00:00Z", task: "T4", event: "review", head: "abc", verdict: "pass"},
    {ts: "2026-11-15T11:00:00Z", task: "T5", event: "review", head: "abc", verdict: "pass"},
    {ts: "2026-11-15T12:00:00Z", task: "T4", event: "merged", url: "https://github.com/owner/proj/pull/4"}' >>"$TEAM_HOME/ledger.jsonl"
  mkdir -p "$TEAM_HOME/assistant/handoffs"
  jq -cn '{ts: "2026-11-15T09:00:00Z", id: "H1", event: "sent", kind: "task", from: "assistant", to: "coordinator"},
    {ts: "2026-11-15T09:00:00Z", id: "H2", event: "sent", kind: "task", from: "assistant", to: "coordinator"},
    {ts: "2026-11-15T10:30:00Z", id: "H1", event: "answered", by: "coordinator"}' >"$TEAM_HOME/assistant/handoffs.jsonl"
  echo report >"$TEAM_HOME/tasks/T4/review.md"
  stub_script gh <<'EOF'
case $3 in
  */pull/7) echo MERGED ;;
  */pull/8) echo OPEN ;;
esac
EOF
  # Each condition kind, holding (first) and not (second).
  local -a holding=("handoff H1 answered" "task T4 opened" "task T4 merged" "ledger T5 review"
    "pr https://github.com/owner/proj/pull/7 merged" "file tasks/T4/review.md")
  local -a open=("handoff H2 answered" "task T6 opened" "task T5 closed" "ledger T4 review"
    "pr https://github.com/owner/proj/pull/8 merged" "file tasks/T4/gone.md")
  local condition
  local -a items=("# Current items")
  for condition in "${holding[@]}" "${open[@]}"; do
    items+=("- next - wait for $condition | tasks/queued/node-pin.md | until $condition | $ADDED")
  done
  printf '%s\n' "${items[@]}" >"$current"
  commit_all
  local head
  head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  run_bin -0 --separate-stderr team-current reconcile
  assert_equal "$stderr" ""
  local expected='' subjects=''
  for condition in "${holding[@]}"; do
    local line="- next - wait for $condition | tasks/queued/node-pin.md | until $condition | $ADDED"
    expected+="closed $(id_of "$line"): $condition"$'\n'
    subjects+="chore: current closed $(id_of "$line"): $condition"$'\n'
  done
  assert_equal "$(grep -v '^team home:' <<<"$output")" "${expected%$'\n'}"
  assert_equal "$(subjects_since "$head")" "${subjects%$'\n'}"
  local kept=("# Current items")
  for condition in "${open[@]}"; do
    kept+=("- next - wait for $condition | tasks/queued/node-pin.md | until $condition | $ADDED")
  done
  assert_equal "$(cat "$current")" "$(printf '%s\n' "${kept[@]}")"
  assert_equal "$(git -C "${team_origin:?}" rev-parse dev)" "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)"
  # A run with nothing to close changes nothing.
  head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  run_bin -0 --separate-stderr team-current reconcile
  assert_equal "$output" ""
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
}

@test "reconcile keeps a pr item while GitHub is unreachable, naming it on stderr, and one whose condition does not parse" {
  stub_script gh <<'EOF'
echo "error connecting to api.github.com" >&2
exit 1
EOF
  local pr="- owe - the merge news | https://github.com/owner/proj/pull/7 | until pr https://github.com/owner/proj/pull/7 merged | $ADDED"
  local bad="- owe - a bad one | 1563000000000000045 | until soon | $ADDED"
  printf '%s\n' "# Current items" "$pr" "$bad" >"$current"
  commit_all
  local head
  head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  run_bin -0 --separate-stderr team-current reconcile
  assert_equal "$output" ""
  assert_equal "$stderr" "team-current: kept $(id_of "$pr"): cannot check pr https://github.com/owner/proj/pull/7 merged: GitHub did not answer (gh exit 1: error connecting to api.github.com)
team-current: kept $(id_of "$bad"): cannot check soon: the condition 'soon' is not one of: handoff H<n> answered, task T<n> opened|closed|merged, ledger T<n> <kind>, pr <GitHub PR URL> merged, or file <path>"
  assert_equal "$(cat "$current")" "$(printf '%s\n' "# Current items" "$pr" "$bad")"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
}

@test "reconcile moves each list's old-form lines over once, one commit per list, and brings waiting.md up to date" {
  local a="- ask - which domain for the docs site | https://discord.com/channels/1/2/3"
  local b="- next T4 open the Node pin task | tasks/queued/node-pin.md"
  local c="- owe - a reply | 1563000000000000045$TAIL"
  local d="- owe - the login walkthrough | 1563000000000000046"
  printf '%s\n' "# Current items" "$a" "$b" "$c" >"$current"
  printf '%s\n' "# Assistant items" "$d" >"$mine"
  commit_all
  local head
  head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  run_bin -0 --separate-stderr team-current reconcile
  assert_equal "$stderr" ""
  assert_equal "$(grep -v '^team home:' <<<"$output")" "migrated $(id_of "$a") as $(id_of "$a$TAIL"): $REVIEW
migrated $(id_of "$b") as $(id_of "$b$TAIL"): $REVIEW
migrated $(id_of "$d") as $(id_of "$d$TAIL"): $REVIEW"
  assert_equal "$(subjects_since "$head")" "chore: current migrated 2 items
chore: current migrated 1 item"
  assert_equal "$(cat "$current")" "$(printf '%s\n' "# Current items" "$a$TAIL" "$b$TAIL" "$c")"
  assert_equal "$(cat "$mine")" "$(printf '%s\n' "# Assistant items" "$d$TAIL")"
  assert_contains "$(cat "$TEAM_HOME/waiting.md")" "which domain for the docs site"
  run_bin -0 team-current check
  # A second run finds nothing to move.
  head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  TEAM_CURRENT_NOW=2026-11-16T10:00:00Z run_bin -0 team-current reconcile
  assert_equal "$output" ""
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
}

@test "reconcile --list reads and edits that list alone, whatever the role" {
  local a="- next T4 open the Node pin task | tasks/queued/node-pin.md"
  local d="- owe - the login walkthrough | 1563000000000000046"
  printf '%s\n' "# Current items" "$a" >"$current"
  printf '%s\n' "# Assistant items" "$d" >"$mine"
  commit_all
  AGENT_TEAM_ROLE=coordinator run_bin -0 team-current reconcile --list assistant
  assert_equal "$(last_commit)" "chore: current migrated 1 item
assistant/current.md"
  assert_equal "$(cat "$current")" "$(printf '%s\n' "# Current items" "$a")"
  rm "$mine"
  commit_all
  AGENT_TEAM_ROLE=assistant run_bin -0 team-current reconcile
  assert_equal "$(cat "$current")" "$(printf '%s\n' "# Current items" "$a$TAIL")"
}

@test "team-snapshot reads the items team-current writes, as before" {
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
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1"]
TOML
  stub_reply claude '[]'
  stub_reply gh '[]'
  run_bin -0 team-current add owe - the T4 summary --where 1563000000000000045 --review
  run_bin -0 team-current add next T4 open the Node pin task --where tasks/queued/node-pin.md --review
  run_bin -0 team-snapshot
  # The owed reply is the waiting list's, which team-current brought up to date.
  assert_contains "$output" "Waiting on Daniel: nothing
  Owed you: the T4 summary
Current items (1):
  - next T4 open the Node pin task | tasks/queued/node-pin.md$TAIL"
  run_bin -0 team-snapshot --json
  assert_equal "$(jq -c .items <<<"$output")" "[\"owe - the T4 summary | 1563000000000000045$TAIL\",\"next T4 open the Node pin task | tasks/queued/node-pin.md$TAIL\"]"
}

@test "it refuses a malformed command line" {
  run_bin -2 team-current
  run_bin -2 team-current frob
  run_bin -2 team-current add next T4 no where --review
  run_bin -2 team-current add next T4 --where tasks/queued/node-pin.md --review
  run_bin -2 team-current add next --where tasks/queued/node-pin.md --review
  run_bin -2 team-current add next T4 a thing --where
  run_bin -2 team-current add next T4 a thing --where tasks/queued/node-pin.md --until
  run_bin -2 team-current add next T4 a thing --where tasks/queued/node-pin.md --review-by
  run_bin -2 team-current "done"
  run_bin -2 team-current "done" 123456 7890
  run_bin -2 team-current list extra
  run_bin -2 team-current check extra
  run_bin -2 team-current check --json extra
  run_bin -2 team-current check --frob
  run_bin -2 team-current reconcile extra
  run_bin -2 team-current list --list
  run_bin -2 team-current list --list ops
  run_bin -2 team-current list --list assistant --list coordinator
  TEAM_CURRENT_NOW=today run_bin -2 team-current list
}

@test "an ask or owe item added or done brings waiting.md up to date, and a next or watch item leaves it" {
  run_bin -0 team-current add next T4 open the Node pin task --where tasks/queued/node-pin.md --review
  [[ ! -e $TEAM_HOME/waiting.md ]]
  run_bin -0 --separate-stderr team-current add ask - which domain for the docs site --where https://discord.com/channels/1/2/3 --review
  local id=${lines[0]}
  assert_equal "$stderr" ""
  assert_contains "$(cat "$TEAM_HOME/waiting.md")" "- **1** which domain for the docs site <https://discord.com/channels/1/2/3> - unblocks 0"
  run_bin -0 team-current "done" "$id"
  assert_equal "$(cat "$TEAM_HOME/waiting.md")" "**Waiting on you**
Nothing waits on you."
}
