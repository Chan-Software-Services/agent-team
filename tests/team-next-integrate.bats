#!/usr/bin/env bats
# team-next on a ticket builder's DONE <NN> from its ticket worktree: the task branch fast-forwarded
# to it under the task's lock, its ticket and notes copied back, the worktree returned and the
# fill run, or the line to send when it cannot be; and a task worktree builder's DONE at a cap
# above 1. The sandbox is helpers/team-next's.

load helpers/common
load helpers/github-api
load helpers/team-next

setup() {
  team_next_sandbox
}

@test "a task worktree builder's DONE <NN> in a phase whose cap is above 1 is logged, then hands off to the fill" {
  fill_ready 2
  # fill_ready logged 01 done; this DONE is 01's own, so take that line back out.
  grep -v '"ticket-done"' "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/ledger"
  cp "$BATS_TEST_TMPDIR/ledger" "$TEAM_HOME/ledger.jsonl"
  ticket 02-second "Blocked by: 01" "Touches: two.txt"
  ticket 03-third "Blocked by: 01" "Touches: three.txt"
  ticket 04-fourth "Blocked by: 02, 03" "Touches: four.txt"
  sha=$(git -C "${wt:?}" rev-parse HEAD)
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 ${sha:0:8} the first"
  assert_equal "$output" "logged ticket-done ticket=01 commits=[\"${sha:0:8}\"] note=the first
logged done role=builder session=b0000001
worktree $HOME/slots/proj/2 for ticket 02
brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder-02 c0000001
worktree $HOME/slots/proj/3 for ticket 03
brief $TEAM_HOME/tasks/T7/brief-build-03.md
launched T7-builder-03 c0000002"
  # A DONE with others running and none ready is logged, not refused, and launches nothing.
  launched b0000009 brief-build-09
  ticket 09-ninth "Blocked by: None" "Touches: nine.txt"
  ticket 04-fourth "Blocked by: 02, 03, 09" "Touches: four.txt"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 09 ${sha:0:8} the ninth"
  assert_equal "$output" "logged ticket-done ticket=09 commits=[\"${sha:0:8}\"] note=the ninth
logged done role=builder session=b0000009
nothing to launch: 02 running in session c0000001; 03 running in session c0000002; 04 blocked on 02, 03"
  assert_equal "$(bg_calls | wc -l)" 2
}

# Integration: a ticket builder's DONE <NN> from its ticket worktree lands as a fast-forward of the
# task branch in the task worktree, under T7's lock.

# integrate_ready [<NN-slug> <lines>...]: T7 at cap 2 with 02 and 03 ready and 04 blocked on both,
# then --fill having launched 02 (c0000001, slots/proj/2) and 03 (c0000002, slots/proj/3).
integrate_ready() {
  fill_ready 2
  ticket 02-second "Blocked by: 01" "Touches: two.txt"
  ticket 03-third "Blocked by: 01" "Touches: three.txt"
  ticket 04-fourth "Blocked by: 02, 03" "Touches: four.txt"
  run_bin -0 team-next T7 --fill
}

# built <NN> <file>: ticket NN's work in its worktree, <file> committed, its ticket's box ticked
# and its build note written; prints its head.
built() {
  local tw
  tw=$(ticket_wt "$1")
  echo "$1" >"$tw/$2"
  git -C "${tw:?}" add "$2"
  git -C "${tw:?}" commit -q -m "feat: ticket $1"
  sed -i 's/- \[ \] it works/- [x] it works/' "$tw/.scratch/task/tickets/$1"-*.md
  mkdir -p "$tw/.scratch/task/build-notes"
  echo "note $1" >"$tw/.scratch/task/build-notes/$1.md"
  git -C "${tw:?}" rev-parse HEAD
}

# tip_merged <NN>: ticket NN's builder merges the task branch's tip; prints the merged head.
tip_merged() {
  local tw
  tw=$(ticket_wt "$1")
  git -C "${tw:?}" merge -q --no-edit feat/T7-toil
  git -C "${tw:?}" rev-parse HEAD
}

# The refs of proj's repository, which a refusal leaves as they were.
refs() {
  git -C "${primary:?}" for-each-ref --format='%(refname) %(objectname)'
}

@test "a ticket builder's DONE fast-forwards the task branch, copies back its ticket and notes, logs head, returns the worktree and fills" {
  local old head tw count
  integrate_ready
  old=$(git -C "${wt:?}" rev-parse HEAD) tw=$(ticket_wt 02)
  head=$(built 02 two.txt)
  echo "more" >"$tw/.scratch/task/build-notes/02-more.md"
  echo "not 02's" >"$tw/.scratch/task/build-notes/03.md"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 02 ${head:0:8} the second"
  assert_equal "$output" "integrated ticket 02: feat/T7-toil ${old:0:8}..${head:0:8} in $wt
copied back $wt/.scratch/task/tickets/02-second.md
copied back $wt/.scratch/task/build-notes/02.md
copied back $wt/.scratch/task/build-notes/02-more.md
logged ticket-done ticket=02 commits=[\"${head:0:8}\"] note=the second head=$head
logged done role=builder session=c0000001
returned $tw for ticket 02
nothing to launch: 03 running in session c0000002; 04 blocked on 03"
  assert_equal "$(git -C "${wt:?}" rev-parse HEAD)" "$head"
  grep -qF -- '- [x] it works' "$wt/.scratch/task/tickets/02-second.md"
  assert_equal "$(cat "$wt/.scratch/task/build-notes/02.md")" "note 02"
  [[ ! -e $wt/.scratch/task/build-notes/03.md ]]
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "ticket-done" or .event == "worktree-returned")
    | del(.worktree)')" \
    "{\"task\":\"T7\",\"event\":\"ticket-done\",\"ticket\":\"02\",\"commits\":[\"${head:0:8}\"],\"note\":\"the second\",\"head\":\"$head\"}
{\"task\":\"T7\",\"event\":\"worktree-returned\",\"project\":\"proj\",\"branch\":\"feat/T7-toil--02\",\"ticket\":\"02\"}"
  # The worktree is gone with its branch, which the task branch holds, and the archive kept.
  [[ ! -d $tw ]]
  [[ -z $(git -C "${primary:?}" branch --list 'feat/T7-toil--02') ]]
  assert_contains "$stderr" "deleted feat/T7-toil--02"
  [[ -f $TEAM_HOME/tasks/T7/scratch--02/build-notes/02.md ]]
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "rm")')" '["rm","c0000001"]'
  assert_equal "$(bg_calls | wc -l)" 2
  run_bin -0 team-log --check
}

@test "a DONE whose base moved, whose last sha is not its HEAD, or from a dirty worktree prints the line to send, changing nothing" {
  local h2 h3 tip merged tw before
  integrate_ready
  h2=$(built 02 two.txt)
  run_bin -0 team-next T7 -- "T7 DONE 02 $h2 two"
  h3=$(built 03 three.txt) tw=$(ticket_wt 03) tip=$(git -C "${wt:?}" rev-parse HEAD)
  before=$(state)$'\n'$(refs)

  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 03 $h3 three"
  assert_equal "$output" "send to T7-builder-03 (c0000002): T7 the task branch moved: merge feat/T7-toil at ${tip:0:8} into your branch, run your checks again on the merged head and send DONE 03 again with that head last"
  assert_equal "$(state)"$'\n'"$(refs)" "$before"

  merged=$(tip_merged 03)
  before=$(state)$'\n'$(refs)
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 03 ${h3:0:8} three"
  assert_equal "$output" "send to T7-builder-03 (c0000002): T7 your DONE 03 must list the head you tested last, the HEAD of your worktree, ${merged:0:8}; run your checks on it and send DONE 03 again"
  assert_equal "$(state)"$'\n'"$(refs)" "$before"
  refused "abcdef1 is not a commit the HEAD of $tw holds, so ticket 03 is not handed off" \
    T7 -- "T7 DONE 03 abcdef1 $merged three"

  echo "edited" >"$tw/three.txt"
  echo "stray" >"$tw/stray.txt"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 03 $merged three"
  assert_equal "$output" "send to T7-builder-03 (c0000002): T7 your worktree has uncommitted changes (three.txt, stray.txt): commit or remove them, run your checks again and send DONE 03 again with your head last"
  assert_equal "$(state)"$'\n'"$(refs)" "$before"

  # Clean, merged and listed last, it lands, and the fill launches 04 in the slot 02 gave back.
  git -C "${tw:?}" checkout -q -- three.txt
  rm "$tw/stray.txt"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 03 $h3 $merged three"
  assert_equal "$(head -n 1 <<<"$output")" "integrated ticket 03: feat/T7-toil ${h2:0:8}..${merged:0:8} in $wt"
  assert_equal "$(tail -n 3 <<<"$output")" "worktree $HOME/slots/proj/2 for ticket 04
brief $TEAM_HOME/tasks/T7/brief-build-04.md
launched T7-builder-04 c0000003"
  # The task branch's history holds each ticket's commit and the builder's merge of the tip.
  assert_equal "$(git -C "${wt:?}" log --format=%s "${tip}..HEAD")" "Merge branch 'feat/T7-toil' into feat/T7-toil--03
feat: ticket 03"
  run_bin -0 team-log --check
}

@test "a DONE refused before the lock's work: the ticket worktree off its branch, the task worktree moved or edited, another ticket's sender" {
  local h2 tw2 before
  integrate_ready
  h2=$(built 02 two.txt) tw2=$(ticket_wt 02)
  before=$(refs)

  git -C "${tw2:?}" checkout -q -b side
  refused "ticket 02's worktree $tw2 is on side, not its ticket branch feat/T7-toil--02, so nothing is integrated" \
    T7 -- "T7 DONE 02 $h2 two"
  git -C "${tw2:?}" checkout -q feat/T7-toil--02
  git -C "${tw2:?}" branch -q -D side

  echo "edited" >>"$wt/one.txt"
  refused "the task worktree $wt has changes to one.txt, so nothing fast-forwards it" T7 -- "T7 DONE 02 $h2 two"
  git -C "${wt:?}" checkout -q -- one.txt
  git -C "${wt:?}" checkout -q -b elsewhere
  refused "the task worktree $wt is on elsewhere, so nothing fast-forwards it" T7 -- "T7 DONE 02 $h2 two"
  git -C "${wt:?}" checkout -q feat/T7-toil
  git -C "${wt:?}" branch -q -D elsewhere

  refused "T7-builder-03 (c0000002) is ticket 03's builder, so its DONE 02 is not integrated" \
    T7 --from T7-builder-03 -- "T7 DONE 02 $h2 two"
  mv "$tw2" "$BATS_TEST_TMPDIR/away"
  refused "ticket 02's worktree $tw2 is not on this machine, so nothing is integrated" T7 -- "T7 DONE 02 $h2 two"
  mv "$BATS_TEST_TMPDIR/away" "$tw2"
  assert_equal "$(refs)" "$before"
}

@test "a rerun after the fast-forward finishes the integration; a builder still busy keeps its worktree until a later run returns it" {
  local h2 tw count
  integrate_ready
  h2=$(built 02 two.txt) tw=$(ticket_wt 02)
  # A run that ended after its fast-forward.
  git -C "${wt:?}" merge -q --ff-only "$h2"
  jq -cn '[{id: "c0000001", sessionId: "c0000001-0000", name: "T7-builder-02", kind: "background", status: "busy", state: "working"},
    {id: "c0000002", sessionId: "c0000002-0000", name: "T7-builder-03", kind: "background", status: "idle", state: "blocked"}]' \
    >"$STUB_FIXTURES/agents"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  TEAM_CLOSE_IDLE_SECONDS=0 run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 02 $h2 two"
  assert_equal "$output" "already integrated ticket 02: feat/T7-toil is at ${h2:0:8} in $wt
copied back $wt/.scratch/task/tickets/02-second.md
copied back $wt/.scratch/task/build-notes/02.md
logged ticket-done ticket=02 commits=[\"$h2\"] note=two head=$h2
logged done role=builder session=c0000001
kept $tw: T7-builder-02 c0000001 is still busy; run this again once it is idle; the next team-next run of T7 returns it
nothing to launch: 03 running in session c0000002; 04 blocked on 03"
  [[ -d $tw ]]

  # Idle now: the same DONE again logs nothing twice and returns the worktree.
  jq -cn '[{id: "c0000001", sessionId: "c0000001-0000", name: "T7-builder-02", kind: "background", status: "idle", state: "blocked"},
    {id: "c0000002", sessionId: "c0000002-0000", name: "T7-builder-03", kind: "background", status: "idle", state: "blocked"}]' \
    >"$STUB_FIXTURES/agents"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 02 $h2 two"
  assert_equal "$output" "already logged ticket-done ticket=02 commits=[\"$h2\"] note=two
already logged done role=builder session=c0000001
returned $tw for ticket 02
nothing to launch: 03 running in session c0000002; 04 blocked on 03"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event)" "ticket-done
done
worktree-returned"
  assert_equal "$(stub_calls claude | jq -c 'select(.[0] == "stop")')" '["stop","c0000001"]'
}

@test "the deliverer is launched after the phase's last integration, once, and a rerun says it is already handed off" {
  local h2 h3
  fill_ready 2
  ticket 02-second "Blocked by: 01" "Touches: two.txt"
  ticket 03-third "Blocked by: 01" "Touches: three.txt"
  rm "$wt/.scratch/task/tickets/04-fourth.md"
  run_bin -0 team-next T7 --fill
  h2=$(built 02 two.txt)
  run_bin -0 team-next T7 -- "T7 DONE 02 $h2 two"
  assert_equal "$(tail -n 1 <<<"$output")" "nothing to launch: 03 running in session c0000002"
  built 03 three.txt >/dev/null
  h3=$(tip_merged 03)
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 03 $h3 three"
  assert_equal "$(tail -n 3 <<<"$output")" "returned $HOME/slots/proj/3 for ticket 03
brief $TEAM_HOME/tasks/T7/brief-deliver.md
launched T7-builder c0000003"
  assert_equal "$(jq -c 'select(.event == "launch" and .session == "c0000003") | {brief, ticket, worktree}' "$TEAM_HOME/ledger.jsonl")" \
    "$(jq -cn --arg wt "$wt" '{brief: "brief-deliver", ticket: null, worktree: $wt}')"

  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 03 $h3 three"
  assert_equal "$(head -n 2 <<<"$output")" "already logged ticket-done ticket=03 commits=[\"$h3\"] note=three
already logged done role=builder session=c0000002"
  [[ $(tail -n 1 <<<"$output") =~ ^"already handed off: T7-builder c0000003 was launched at "[0-9T:-]+Z" on brief-deliver"$ ]]
  assert_equal "$(bg_calls | wc -l)" 3
  run_bin -0 team-log --check
}

@test "a rerun after the fast-forward finishes the integration though another ticket landed on top since" {
  local h2 h3 tw2 count
  integrate_ready
  h2=$(built 02 two.txt) tw2=$(ticket_wt 02)
  # A run that ended after its fast-forward, then ticket 03 landing on top of it.
  git -C "${wt:?}" merge -q --ff-only "$h2"
  built 03 three.txt >/dev/null
  h3=$(tip_merged 03)
  run_bin -0 team-next T7 -- "T7 DONE 03 $h3 three"
  assert_contains "$output" "integrated ticket 03: feat/T7-toil ${h2:0:8}..${h3:0:8} in $wt"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 02 $h2 two"
  assert_equal "$(sed -n 1,5p <<<"$output")" "already integrated ticket 02: feat/T7-toil at ${h3:0:8} holds ${h2:0:8} in $wt
copied back $wt/.scratch/task/tickets/02-second.md
copied back $wt/.scratch/task/build-notes/02.md
logged ticket-done ticket=02 commits=[\"$h2\"] note=two head=$h2
logged done role=builder session=c0000001"
  assert_contains "$output" "returned $tw2 for ticket 02"
  assert_contains "$output" "launched T7-builder-04 "
  assert_equal "$(git -C "${wt:?}" rev-parse HEAD)" "$h3"
  assert_equal "$(tail -n +$((count + 1)) "$TEAM_HOME/ledger.jsonl" | jq -r 'select(.event == "ticket-done") | .head')" "$h2"
}

@test "a DONE whose ticket worktree was returned is refused naming the ticket's worktree, not the task's" {
  local h2 tw2
  integrate_ready
  h2=$(built 02 two.txt) tw2=$(ticket_wt 02)
  event worktree-returned "$(jq -cn --arg wt "$tw2" '{project: "proj", worktree: $wt, ticket: "02"}')"
  refused "T7 has no open worktree of ticket 02, so nothing is integrated" T7 -- "T7 DONE 02 $h2 two"
}

@test "an integration finding the task's lock held past its wait is exit 75 with nothing changed, and a malformed wait exit 2" {
  local h2 lock before pid
  integrate_ready
  h2=$(built 02 two.txt)
  lock=$HOME/.local/state/agent-team/integrate/T7.lock
  mkdir -p "${lock%/*}"
  # The holder keeps the lock until the test releases it, at most 60 seconds, so a slow start of
  # team-next under load still finds it held.
  flock "$lock" -c "touch '$BATS_TEST_TMPDIR/held'
    for _ in \$(seq 600); do [[ -e '$BATS_TEST_TMPDIR/release' ]] && break; sleep 0.1; done" 3>&- &
  pid=$!
  until [[ -e $BATS_TEST_TMPDIR/held ]]; do sleep 0.1; done
  before=$(state)$'\n'$(refs)
  TEAM_NEXT_LOCK_SECONDS=0 run_bin -75 --separate-stderr team-next T7 -- "T7 DONE 02 $h2 two"
  touch "$BATS_TEST_TMPDIR/release"
  wait "$pid"
  assert_equal "$(tail -n 1 <<<"$stderr")" "team-next: another team-next is integrating a ticket of T7 ($lock); run this again"
  assert_equal "$(state)"$'\n'"$(refs)" "$before"
  TEAM_NEXT_LOCK_SECONDS=soon run_bin -2 team-next T7 -- "T7 DONE 02 $h2 two"
  assert_contains "$output" "TEAM_NEXT_LOCK_SECONDS takes a whole number of seconds, got 'soon'"
}

@test "two integrations of one DONE wait on the lock while it is held, then take it in turn, the second reading the first's ticket-done" {
  local h2 lock before holder first second
  integrate_ready
  h2=$(built 02 two.txt)
  lock=$HOME/.local/state/agent-team/integrate/T7.lock
  mkdir -p "${lock%/*}"
  # Held until the marker goes.
  touch "$BATS_TEST_TMPDIR/hold"
  flock "$lock" -c "touch '$BATS_TEST_TMPDIR/held'; while [[ -e '$BATS_TEST_TMPDIR/hold' ]]; do sleep 0.1; done" 3>&- &
  holder=$!
  until [[ -e $BATS_TEST_TMPDIR/held ]]; do sleep 0.1; done
  before=$(state)$'\n'$(refs)
  "$REPO_ROOT/bin/team-next" T7 -- "T7 DONE 02 $h2 two" >"$BATS_TEST_TMPDIR/first" 2>&1 3>&- &
  first=$!
  "$REPO_ROOT/bin/team-next" T7 -- "T7 DONE 02 $h2 two" >"$BATS_TEST_TMPDIR/second" 2>&1 3>&- &
  second=$!
  # Both wait while it is held: nothing integrated, nothing logged, both still running.
  sleep 2
  assert_equal "$(state)"$'\n'"$(refs)" "$before"
  kill -0 "$first"
  kill -0 "$second"
  rm "$BATS_TEST_TMPDIR/hold"
  wait "$holder"
  wait "$first"
  wait "$second"
  # One integrated it; the other, taking the lock after, read its ticket-done and logged nothing twice.
  assert_equal "$(cat "$BATS_TEST_TMPDIR/first" "$BATS_TEST_TMPDIR/second" | grep -c '^integrated ticket 02: ')" 1
  assert_equal "$(cat "$BATS_TEST_TMPDIR/first" "$BATS_TEST_TMPDIR/second" | grep -c '^already logged ticket-done ')" 1
  assert_equal "$(jq -c 'select(.event == "ticket-done" and .ticket == "02") | .head' "$TEAM_HOME/ledger.jsonl")" "\"$h2\""
  assert_equal "$(git -C "${wt:?}" rev-parse HEAD)" "$h2"
}

@test "every run of team-next returns each open ticket worktree whose ticket is done before its hand-off" {
  local tw2 tw3
  integrate_ready
  tw2=$(ticket_wt 02) tw3=$(ticket_wt 03)
  event ticket-done '{ticket: "03", commits: ["0123456"]}'
  run_bin -0 --separate-stderr team-next T7 --from T7-builder-02 -- "T7 QUESTION which file?"
  assert_equal "$(tail -n 2 <<<"$output")" "returned $tw3 for ticket 03
no hand-off for QUESTION"
  [[ ! -d $tw3 ]]
  # A fill returns a done ticket's worktree before it launches into the slot it frees.
  event ticket-done '{ticket: "02", commits: ["0123456"]}'
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "returned $tw2 for ticket 02
worktree $tw2 for ticket 04
brief $TEAM_HOME/tasks/T7/brief-build-04.md
launched T7-builder-04 c0000003"
  # Nothing open is done now, so a run returns nothing.
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "nothing to launch: 04 running in session c0000003"
}
