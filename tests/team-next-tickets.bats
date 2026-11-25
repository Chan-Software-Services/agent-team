#!/usr/bin/env bats
# shellcheck disable=SC2154 # primary and sha are helpers/team-next.bash's
# team-next T7 --fill: a phase's ready tickets launched up to its cap, the task branch brought to
# its base before a merged part's next phase, the task's builder model held, and each stowed or
# crashed ticket builder relaunched. The sandbox is helpers/team-next's.

load helpers/common
load helpers/github-api
load helpers/team-next

setup() {
  team_next_sandbox
}

# --fill: a phase's ready tickets launched up to its cap, each in a ticket worktree of its own
# (team-open --task T7 --ticket NN) at a cap above 1, in the task worktree at cap 1.

# The launches' facts a fill reads, one a line.
fill_launches() {
  jq -c --arg home "$HOME/" 'select(.event == "launch" and .session != "b0000001")
    | {session, ticket, worktree: (.worktree | ltrimstr($home)), branch, brief, toolkits}' "$TEAM_HOME/ledger.jsonl"
}

@test "--fill at cap 2 launches the two lowest ready tickets, each in a ticket worktree of its own, and a rerun launches none" {
  fill_ready 2
  ticket 02-second "Blocked by: 01" "Touches: two.txt"
  ticket 03-third "Blocked by: None" "Touches: three.txt"
  ticket 04-fourth "Blocked by: None" "Touches: four.txt"
  ticket 05-fifth "Blocked by: 02" "Touches: five.txt"
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "worktree $HOME/slots/proj/2 for ticket 02
brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder-02 c0000001
worktree $HOME/slots/proj/3 for ticket 03
brief $TEAM_HOME/tasks/T7/brief-build-03.md
launched T7-builder-03 c0000002
full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  assert_equal "$(fill_launches)" \
    '{"session":"c0000001","ticket":"02","worktree":"slots/proj/2","branch":"feat/T7-toil--02","brief":"brief-build-02","toolkits":["browser"]}
{"session":"c0000002","ticket":"03","worktree":"slots/proj/3","branch":"feat/T7-toil--03","brief":"brief-build-03","toolkits":["browser"]}'
  assert_equal "$(record build-02)" '{"template":"builder-ticket","values":{"ticket":"02"}}'
  grep -qF 'You build in a ticket worktree of your own' "$TEAM_HOME/tasks/T7/brief-build-02.md"
  assert_equal "$(bg_calls | tail -n 1 | jq -r 'last')" "Read your brief at $TEAM_HOME/tasks/T7/brief-build-03.md"
  # The ticket worktrees hold the task branch's tip and the task directory's copy.
  assert_equal "$(git -C "${HOME:?}/slots/proj/2" rev-parse HEAD)" "$(git -C "${wt:?}" rev-parse HEAD)"
  [[ -f $HOME/slots/proj/3/.scratch/task/tickets/03-third.md ]]

  # Both run, so a rerun launches nothing, and says so.
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  assert_equal "$(bg_calls | wc -l)" 2
  # One done frees its slot for the next ready ticket.
  event ticket-done '{ticket: "03", commits: ["0123456"]}'
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$(tail -n 1 <<<"$output")" "launched T7-builder-04 c0000003"
  run_bin -0 team-log --check
}

@test "--fill launches nothing beside a running ticket with no Touches: line, and such a ticket only when none runs" {
  fill_ready 3
  ticket 02-second "Blocked by: 01"
  ticket 03-third "Blocked by: None" "Touches: three.txt"
  ticket 04-fourth "Blocked by: None" "Touches: four.txt"
  # 02 has no Touches: line and none runs, so it is launched, alone.
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "worktree $HOME/slots/proj/2 for ticket 02
brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder-02 c0000001
full: 1 of phase 1's cap 3 build (02), and 02 builds alone (no Touches: line); ready and waiting for a slot: 03, 04"
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "full: 1 of phase 1's cap 3 build (02), and 02 builds alone (no Touches: line); ready and waiting for a slot: 03, 04"
  assert_equal "$(bg_calls | wc -l)" 1

  # Once 02 is done, a ready ticket with no Touches: line waits while another runs.
  event ticket-done '{ticket: "02", commits: ["0123456"]}'
  ticket 03-third "Blocked by: None"
  ticket 05-fifth "Blocked by: None" "Touches: five.txt"
  launched b0000004 brief-build-04
  # 02's worktree is returned first, so 05 takes its slot.
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "returned $HOME/slots/proj/2 for ticket 02
worktree $HOME/slots/proj/2 for ticket 05
brief $TEAM_HOME/tasks/T7/brief-build-05.md
launched T7-builder-05 c0000002
full: 2 of phase 1's cap 3 build (04, 05); ready and waiting for a slot: 03 (no Touches: line, so it builds alone)"
}

@test "--fill --next adds a waiting ticket first, within the cap, and refuses one not ready or of another phase with today's texts" {
  fill_ready 2
  ticket 02-second "Blocked by: 01" "Touches: two.txt"
  ticket 03-third "Blocked by: 01" "Waits for: T171 merged" "Touches: three.txt"
  ticket 04-fourth "Blocked by: None" "Touches: four.txt"
  ticket 05-fifth "Blocked by: 02" "Touches: five.txt"
  ticket 06-sixth "Blocked by: None" "Phase: 2" "Touches: six.txt"
  refused "--next 09 is none of T7's tickets: they are 01, 02, 03, 04, 05, 06" T7 --fill --next 09
  refused "--next 05 is not ready: 05 blocked on 02" T7 --fill --next 05
  refused "--next 06 is in phase 2, but phase 1 has tickets not done: 02 ready; 03 waiting: T171 merged; 04 ready; 05 blocked on 02" \
    T7 --fill --next 06
  # Without --next a waiting ticket is never launched.
  run_bin -0 --separate-stderr team-next T7 --fill --next 03
  assert_equal "$(grep '^launched' <<<"$output")" "launched T7-builder-03 c0000001
launched T7-builder-02 c0000002"
  assert_equal "$(tail -n 1 <<<"$output")" "full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  # A running ticket is not ready either.
  refused "--next 02 is not ready: 02 running in session c0000002" T7 --fill --next 02
}

@test "--fill launches no ticket an ask holds, names it held, and refuses it as --next, until the ask is answered" {
  fill_ready 2
  ticket 02-second "Blocked by: 01" "Touches: two.txt"
  ticket 03-third "Blocked by: None" "Touches: three.txt"
  ticket 04-fourth "Blocked by: None" "Touches: four.txt"
  event asked '{id: "prune", text: "Prune 03?", tickets: ["03"]}'
  refused "--next 03 is not ready: 03 held by the unanswered ask prune" T7 --fill --next 03
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$(grep '^launched' <<<"$output")" "launched T7-builder-02 c0000001
launched T7-builder-04 c0000002"
  # With a slot free and only the held ticket left, nothing is launched, and the line says why.
  event ticket-done '{ticket: "04", commits: ["0123456"]}'
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$(tail -n 1 <<<"$output")" "nothing to launch: 02 running in session c0000001; 03 held by the unanswered ask prune"
  assert_equal "$(bg_calls | wc -l)" 2
  # Answered, it is ready again.
  event answered '{id: "prune", answer: "keep it"}'
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$(grep '^launched' <<<"$output")" "launched T7-builder-03 c0000003"
}

@test "a launch refused for room stops --fill with exit 75 and its line, keeping the worktree, and a rerun launches the rest" {
  fill_ready 2
  ticket 02-second "Blocked by: 01" "Touches: two.txt"
  ticket 03-third "Blocked by: None" "Touches: three.txt"
  # Room for one builder of 0.5 GiB and not two.
  capacity_room $((768 * 1048576))
  run_bin -75 --separate-stderr team-next T7 --fill
  assert_equal "$output" "worktree $HOME/slots/proj/2 for ticket 02
brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder-02 c0000001
worktree $HOME/slots/proj/3 for ticket 03
brief $TEAM_HOME/tasks/T7/brief-build-03.md"
  assert_contains "$stderr" "team-worker: no room for session:builder"
  assert_equal "$(tail -n 1 <<<"$stderr")" "team-next: no room for build-03: the launch said $(grep '^team-worker: no room' <<<"$stderr"); ready and waiting for room: 03; run team-next T7 --fill once there is room"
  assert_equal "$(fill_launches | jq -r .ticket)" "02"
  [[ -d $HOME/slots/proj/3/.scratch/task ]]

  # With room, a rerun reuses the kept worktree and its unlaunched brief, and launches 03.
  capacity_room $((16 * 1073741824))
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "worktree $HOME/slots/proj/3 for ticket 03
brief $TEAM_HOME/tasks/T7/brief-build-03.md
launched T7-builder-03 c0000002"
  assert_contains "$stderr" "team-open: T7's ticket 03 already has its worktree $HOME/slots/proj/3"
  assert_equal "$(jq -c 'select(.event == "worktree-added") | .ticket' "$TEAM_HOME/ledger.jsonl")" '"02"
"03"'
}

@test "a ticket worktree team-open cannot make now stops --fill with exit 75 and team-open's reason" {
  fill_ready 3
  ticket 02-second "Blocked by: 01" "Touches: two.txt"
  ticket 03-third "Blocked by: None" "Touches: three.txt"
  ticket 04-fourth "Blocked by: None" "Touches: four.txt"
  # Another run holds the pool's lock, a git pool's only exit 75.
  local lock=$primary/.git/team-open-pool.lock fd
  exec {fd}<>"$lock"
  flock -x "$fd"
  TEAM_OPEN_POOL_WAIT_SECONDS=1 run_bin -75 --separate-stderr team-next T7 --fill
  exec {fd}>&-
  assert_equal "$output" ""
  assert_equal "$(tail -n 1 <<<"$stderr")" "team-next: no worktree for ticket 02: team-open: another run held the pool lock $lock of $primary for 1 seconds; run this again; ready and waiting for room: 02, 03, 04; run team-next T7 --fill once there is room"
  assert_equal "$(bg_calls | wc -l)" 0
}

@test "cap 1's --fill launches the lowest ready ticket in the task worktree only when none runs, and each idle case says why" {
  # 01 runs, so nothing is launched.
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "nothing to launch: 01 running in session b0000001; 02 blocked on 01; 03 blocked on 01; 04 blocked on 02"
  fill_ready
  ticket 05-fifth "Blocked by: None"
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder c0000001
full: 1 of phase 1's cap 1 build (02); ready and waiting for a slot: 05"
  assert_equal "$(fill_launches)" \
    "{\"session\":\"c0000001\",\"ticket\":null,\"worktree\":\"slots/proj/1\",\"branch\":\"feat/T7-toil\",\"brief\":\"brief-build-02\",\"toolkits\":[\"browser\"]}"
  assert_equal "$(record build-02)" '{"template":"builder-ticket","values":{"ticket":"02"}}'
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "full: 1 of phase 1's cap 1 build (02); ready and waiting for a slot: 05"
  # A later plan-approved with no parallel returns a parallel task to cap 1.
  event plan-approved '{by: "Daniel", parallel: "3"}'
  event plan-approved '{by: "Daniel"}'
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "full: 1 of phase 1's cap 1 build (02); ready and waiting for a slot: 05"

  # Every ticket done: the phase's deliverer comes from the last DONE, never from the fill.
  for n in 02 03 04 05; do event ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["0123456"]}')"; done
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "phase 1's tickets are all done: its deliverer comes from the last ticket's DONE"
  assert_equal "$(bg_calls | wc -l)" 1
}

@test "--fill reads each phase's cap from parallel, the last for a later phase, and builds the earliest phase with a ticket not done" {
  fill_ready 1,2
  ticket 02-second "Blocked by: 01" "Phase: 2" "Touches: two.txt"
  ticket 03-third "Blocked by: None" "Phase: 2" "Touches: three.txt"
  ticket 04-fourth "Blocked by: None" "Phase: 3" "Touches: four.txt"
  ticket 05-fifth "Blocked by: None" "Phase: 3" "Touches: five.txt"
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$(grep '^launched' <<<"$output")" "launched T7-builder-02 c0000001
launched T7-builder-03 c0000002"
  for n in 02 03; do event ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["0123456"]}')"; done
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$(grep '^launched' <<<"$output")" "launched T7-builder-04 c0000003
launched T7-builder-05 c0000004"
  # Phase 3's tickets blocked or waiting: nothing ready, each named.
  event ticket-done '{ticket: "04", commits: ["0123456"]}'
  event ticket-done '{ticket: "05", commits: ["0123456"]}'
  ticket 06-sixth "Blocked by: None" "Phase: 3" "Waits for: PR 9" "Touches: six.txt"
  ticket 07-seventh "Blocked by: 06" "Phase: 3" "Touches: seven.txt"
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "returned $HOME/slots/proj/2 for ticket 04
returned $HOME/slots/proj/3 for ticket 05
nothing to launch: 06 waiting: PR 9; 07 blocked on 06"
}

# phase_merged [<parallel>]: T7's phase 1 merged into origin's main with a merge commit, and main
# moved on origin since (another task's merge, pushed from a clone of its own, so T7's repository
# has not fetched it); tickets 02, 03 and 04 are phase 2's, ready but for 02's done blocker.
# Sets merge_tip (the merge) and base_tip (origin's main now).
phase_merged() {
  local other=$BATS_TEST_TMPDIR/other
  fill_ready "${1:-}"
  ticket 02-second "Blocked by: 01" "Phase: 2" "Touches: two.txt"
  ticket 03-third "Blocked by: None" "Phase: 2" "Touches: three.txt"
  ticket 04-fourth "Blocked by: None" "Phase: 2" "Touches: four.txt"
  git -C "${primary:?}" merge -q --no-ff -m "Merge pull request #9 from owner/feat/T7-toil" feat/T7-toil
  git -C "${primary:?}" push -q origin main
  merge_tip=$(git -C "${primary:?}" rev-parse HEAD)
  git clone -q "$BATS_TEST_TMPDIR/origin/proj.git" "$other"
  echo t9 >"$other/t9.txt"
  git -C "${other:?}" add t9.txt
  git -C "${other:?}" commit -q -m "feat: another task's change"
  git -C "${other:?}" push -q origin main
  base_tip=$(git -C "${other:?}" rev-parse HEAD)
  event merged "$(jq -cn --arg m "$merge_tip" '{pr: 9, merge: $m, head: "h0", by: "team-merge", project: "proj", phases_left: [2]}')"
}

# base_moves <file>: another commit on origin's main of proj, pushed from the clone phase_merged made.
base_moves() {
  echo "$1" >"$BATS_TEST_TMPDIR/other/$1"
  git -C "${BATS_TEST_TMPDIR:?}/other" add "$1"
  git -C "${BATS_TEST_TMPDIR:?}/other" commit -q -m "feat: $1"
  git -C "${BATS_TEST_TMPDIR:?}/other" push -q origin main
}

# other_phase_ready: a second repository, other, with a free slot for a ticket worktree, its
# task directory ignored, its phase 1 merged (phases_left [2]) and its base moved since, so its task
# branch is an ancestor of origin's main; sets other_tip (origin's main of other now).
other_phase_ready() {
  local clone=$BATS_TEST_TMPDIR/other-clone
  second_repo
  sed -i 's|slots = \["slots/other/1"\]|slots = ["slots/other/1", "slots/other/2"]|' "$TEAM_HOME/projects.toml"
  echo ".scratch/" >>"$(git -C "${wt_other:?}" rev-parse --git-common-dir)/info/exclude"
  mkdir -p "$wt_other/.scratch/task/tickets"
  event merged '{pr: 4, merge: "m1", head: "h1", by: "team-merge", project: "other", phases_left: [2]}'
  git clone -q "$BATS_TEST_TMPDIR/origin/other.git" "$clone"
  echo o >"$clone/o.txt"
  git -C "${clone:?}" add o.txt
  git -C "${clone:?}" commit -q -m "feat: another task's change in other"
  git -C "${clone:?}" push -q origin main
  other_tip=$(git -C "${clone:?}" rev-parse HEAD)
}

# other_ticket <NN-slug> <lines>...: a ticket file of those lines in other's task directory.
other_ticket() {
  printf '%s\n' "# ${1%%-*}: ${1#*-}" "" "${@:2}" "" "- [ ] it works" >"$wt_other/.scratch/task/tickets/$1.md"
}

# The task branch's tip.
task_tip() {
  git -C "${wt:?}" rev-parse refs/heads/feat/T7-toil
}

@test "--fill at cap 2 brings the task branch to origin's base before a merged part's next phase, so its ticket worktrees hold it" {
  phase_merged 2
  local old
  old=$(task_tip)
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$(head -n 1 <<<"$output")" \
    "brought phase 2's task branch to origin/main: feat/T7-toil ${old:0:8}..${base_tip:0:8} in $wt"
  assert_equal "$(grep '^launched' <<<"$output")" "launched T7-builder-02 c0000001
launched T7-builder-03 c0000002"
  assert_equal "$(task_tip)" "$base_tip"
  assert_equal "$(git -C "${HOME:?}/slots/proj/2" rev-parse HEAD)" "$base_tip"
  assert_equal "$(git -C "${HOME:?}/slots/proj/3" rev-parse HEAD)" "$base_tip"

  # Once the phase has started, the fill leaves the branch alone, though the base moved again.
  echo again >"$BATS_TEST_TMPDIR/other/again.txt"
  git -C "${BATS_TEST_TMPDIR:?}/other" add again.txt
  git -C "${BATS_TEST_TMPDIR:?}/other" commit -q -m "feat: a third change"
  git -C "${BATS_TEST_TMPDIR:?}/other" push -q origin main
  event ticket-done '{ticket: "03", commits: ["0123456"]}'
  run_bin -0 --separate-stderr team-next T7 --fill
  [[ $output != *brought* ]]
  assert_equal "$(tail -n 1 <<<"$output")" "launched T7-builder-04 c0000003"
  assert_equal "$(task_tip)" "$base_tip"

  # Nor once every launched ticket of the phase is done and none runs.
  base_moves again2.txt
  event ticket-done '{ticket: "02", commits: ["0123456"]}'
  event ticket-done '{ticket: "04", commits: ["0123456"]}'
  ticket 05-fifth "Blocked by: None" "Phase: 2" "Touches: five.txt"
  run_bin -0 --separate-stderr team-next T7 --fill
  [[ $output != *brought* ]]
  assert_equal "$(tail -n 1 <<<"$output")" "launched T7-builder-05 c0000004"
  assert_equal "$(task_tip)" "$base_tip"
  run_bin -0 team-log --check
}

@test "cap 1's --fill brings the task branch to origin's base before a merged part's next phase, and launches its first ticket in the task worktree" {
  phase_merged
  local old
  old=$(task_tip)
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "brought phase 2's task branch to origin/main: feat/T7-toil ${old:0:8}..${base_tip:0:8} in $wt
brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder c0000001
full: 1 of phase 2's cap 1 build (02); ready and waiting for a slot: 03, 04"
  assert_equal "$(task_tip)" "$base_tip"
  assert_equal "$(git -C "${wt:?}" rev-parse HEAD)" "$base_tip"
  assert_equal "$(fill_launches | jq -r .worktree)" "slots/proj/1"
}

@test "--fill brings nothing to the task branch before a phase that follows no merged part" {
  # Phase 1 not merged: a phase 2 after it starts where the task branch is.
  fill_ready 2
  ticket 02-second "Blocked by: 01" "Phase: 2" "Touches: two.txt"
  ticket 03-third "Blocked by: None" "Phase: 2" "Touches: three.txt"
  ticket 04-fourth "Blocked by: None" "Phase: 2" "Touches: four.txt"
  local old
  old=$(task_tip)
  run_bin -0 --separate-stderr team-next T7 --fill
  [[ $output != *brought* ]]
  assert_equal "$(task_tip)" "$old"
}

@test "--fill at a merged part's next phase brings nothing to a task branch that holds origin's base already" {
  phase_merged 2
  git -C "${wt:?}" fetch -q origin
  git -C "${wt:?}" merge -q --ff-only origin/main
  run_bin -0 --separate-stderr team-next T7 --fill
  [[ $output != *brought* ]]
  assert_equal "$(grep -c '^launched' <<<"$output")" 2
  assert_equal "$(task_tip)" "$base_tip"
}

@test "--fill refuses a merged part's next phase, changing nothing, on a dirty task worktree, one off its branch, a base it cannot fetch and a branch that left the base" {
  phase_merged 2
  local old before
  old=$(task_tip)
  # A change to a tracked file, then an untracked file git does not ignore.
  echo changed >>"$wt/one.txt"
  refused "phase 2 starts after a merged part, but the task worktree $wt has uncommitted changes (one.txt), so feat/T7-toil is not brought to origin/main and no ticket of phase 2 is launched: commit or remove them, then run team-next T7 --fill again" \
    T7 --fill
  git -C "${wt:?}" checkout -q -- one.txt
  echo stray >"$wt/stray.txt"
  refused "has uncommitted changes (stray.txt)" T7 --fill
  rm "$wt/stray.txt"
  assert_equal "$(task_tip)" "$old"

  # Off the task branch.
  git -C "${wt:?}" checkout -q --detach
  refused "phase 2 starts after a merged part, but the task worktree $wt is on a detached HEAD, not feat/T7-toil, so it is not brought to origin/main and no ticket of phase 2 is launched: check out feat/T7-toil there, then run team-next T7 --fill again" \
    T7 --fill
  git -C "${wt:?}" checkout -q feat/T7-toil

  # A base that cannot be fetched: exit 75, nothing changed.
  git -C "${wt:?}" remote set-url origin "$BATS_TEST_TMPDIR/no-such-origin.git"
  before=$(state)
  run_bin -75 --separate-stderr team-next T7 --fill
  assert_contains "$stderr" "team-next: phase 2 starts after a merged part, but origin's main cannot be fetched into $wt ("
  assert_contains "$stderr" "), so feat/T7-toil is not brought to it and no ticket of phase 2 is launched: run team-next T7 --fill again once it can be"
  assert_equal "$(state)" "$before"
  git -C "${wt:?}" remote set-url origin "$BATS_TEST_TMPDIR/origin/proj.git"
  assert_equal "$(task_tip)" "$old"

  # A commit on the task branch that the base does not hold: never a merge or a force.
  local own
  own=$(commit own.txt "fix: after the merge")
  refused "phase 2 starts after a merged part, but feat/T7-toil at ${own:0:8} holds commits origin/main at ${base_tip:0:8} does not, so it is not brought to origin/main and no ticket of phase 2 is launched: have a builder merge origin/main into feat/T7-toil in $wt (a merge commit, never a rebase), then run team-next T7 --fill again" \
    T7 --fill
  assert_equal "$(task_tip)" "$own"
}

@test "--fill brings each project's task branch to its base before that project's first launch of the phase, though another project's started it" {
  phase_merged 2
  other_phase_ready
  local old_other
  old_other=$(git -C "${wt_other:?}" rev-parse HEAD)
  other_ticket 05-fifth "Blocked by: 03" "Phase: 2" "Touches: five.txt"
  echo five.txt >"$wt_other/.scratch/task/scope.txt"
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_contains "$output" "brought phase 2's task branch to origin/main: feat/T7-toil"
  [[ $output != *"in $wt_other"* ]]
  event ticket-done '{ticket: "03", commits: ["0123456"]}'
  run_bin -0 --separate-stderr team-next T7 --fill --next 05
  assert_equal "$(head -n 1 <<<"$output")" \
    "brought phase 2's task branch to origin/main: feat/T7-toil ${old_other:0:8}..${other_tip:0:8} in $wt_other"
  assert_contains "$output" "launched T7-builder-05"
  assert_equal "$(git -C "${HOME:?}/slots/other/2" rev-parse HEAD)" "$other_tip"
}

@test "--fill brings a project's task branch to its base before its next phase with a ticket of it, past a phase all another project's" {
  phase_merged 2
  other_phase_ready
  # proj's phase 1 merged with phases 2 and 3 left; phase 2 was all other's, done and merged.
  event merged "$(jq -cn --arg m "$merge_tip" '{pr: 9, merge: $m, head: "h0", by: "team-merge", project: "proj", phases_left: [2, 3]}')"
  other_ticket 05-fifth "Blocked by: None" "Phase: 2"
  event ticket-done '{ticket: "05", commits: ["0123456"]}'
  event merged '{pr: 5, merge: "m2", head: "h2", by: "team-merge", project: "other", phases_left: [3]}'
  ticket 02-second "Blocked by: 01" "Phase: 3" "Touches: two.txt"
  ticket 03-third "Blocked by: None" "Phase: 3" "Touches: three.txt"
  ticket 04-fourth "Blocked by: None" "Phase: 3" "Touches: four.txt"
  local old
  old=$(task_tip)
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$(head -n 1 <<<"$output")" \
    "brought phase 3's task branch to origin/main: feat/T7-toil ${old:0:8}..${base_tip:0:8} in $wt"
  assert_equal "$(git -C "${HOME:?}/slots/proj/2" rev-parse HEAD)" "$base_tip"
}

@test "--fill brings nothing to a task branch whose project has a ticket in an earlier phase left by its merged part" {
  phase_merged 2
  # Phase 2's tickets all done in proj, its PR not merged yet, and phase 3 ready.
  event merged "$(jq -cn --arg m "$merge_tip" '{pr: 9, merge: $m, head: "h0", by: "team-merge", project: "proj", phases_left: [2, 3]}')"
  for n in 02 03 04; do event ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["0123456"]}')"; done
  ticket 05-fifth "Blocked by: None" "Phase: 3" "Touches: five.txt"
  local old
  old=$(task_tip)
  run_bin -0 --separate-stderr team-next T7 --fill
  [[ $output != *brought* ]]
  assert_equal "$(task_tip)" "$old"
}

@test "--fill checks every ready ticket's project before it moves a task branch, so a refusal in one moves none" {
  phase_merged 2
  second_repo
  echo ".scratch/" >>"$(git -C "${wt_other:?}" rev-parse --git-common-dir)/info/exclude"
  mkdir -p "$wt_other/.scratch/task/tickets"
  printf '%s\n' "# 05: fifth" "" "Blocked by: None" "Phase: 2" "" "- [ ] it works" >"$wt_other/.scratch/task/tickets/05-fifth.md"
  event merged '{pr: 4, merge: "m1", head: "h1", by: "team-merge", project: "other", phases_left: [2]}'
  echo stray >"$wt_other/stray.txt"
  local old
  old=$(task_tip)
  refused "phase 2 starts after a merged part, but the task worktree $wt_other has uncommitted changes (stray.txt)" T7 --fill
  assert_equal "$(task_tip)" "$old"
}

@test "--fill takes the message forms' task checks, needs plan-approved and takes only --next" {
  run_bin -2 team-next T7 --fill -- "T7 DONE 01 $sha done"
  assert_contains "$output" "--fill takes no message"
  run_bin -2 team-next T7 --fill --from b0000001
  assert_contains "$output" "--fill takes only --next"
  run_bin -2 team-next T7 --next 02
  assert_contains "$output" "missing '--' before the worker's message"
  run_bin -2 team-next T7 --fill --fill
  assert_contains "$output" "--fill is given twice"
  grep -v '"plan-approved"' "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/ledger"
  cp "$BATS_TEST_TMPDIR/ledger" "$TEAM_HOME/ledger.jsonl"
  # A builder launched once moves the task past planning, so --fill's own check refuses it.
  refused "T7 has no plan-approved, so no ticket is launched; approve the plan first (step 3 of the manual)" T7 --fill
  # Still planning, with no builder launched, the shared guard refuses --fill as a builder's launch.
  local planning=$BATS_TEST_TMPDIR/planning
  cp "$TEAM_HOME/ledger.jsonl" "$planning"
  grep -v '"event":"launch"' "$planning" >"$TEAM_HOME/ledger.jsonl"
  refused "T7 is a feature task with no approved plan (no plan-approved), so it takes no builder yet" T7 --fill
  cp "$planning" "$TEAM_HOME/ledger.jsonl"
  # Caps team-log would refuse, written by hand, refuse the fill and leave other messages as they are.
  event plan-approved '{by: "coordinator", parallel: "5"}'
  refused "T7's latest plan-approved has parallel '5', which is not a cap from 1 to 3 per phase joined by commas; log the approval again as step 3 of the manual logs it, with parallel=<caps>" \
    T7 --fill
  run_bin -0 team-next T7 -- "T7 QUESTION which file?"
  assert_equal "$(tail -n 1 <<<"$output")" "no hand-off for QUESTION"
  event plan-approved '{by: "coordinator"}'
  event held '{reason: "offline"}'
  refused "T7 is on Daniel's hold since 2026-11-01T10:00:00Z (held-1): offline; only Daniel's word lifts it" T7 --fill
  event closed '{archive: [], returned: [], kept: []}'
  refused "T7 is closed" T7 --fill
}

# Relaunch: after a stow or a crash, --fill relaunches each running ticket's gone builder in its
# own ticket worktree before it launches a ready ticket.

# relaunch_ready: T7 at cap 2 with 02, 03 and 04 ready, then --fill having launched 02
# (c0000001, slots/proj/2) and 03 (c0000002, slots/proj/3), their sessions gone (the session list
# is empty, and later launches join it only as a test says with live).
relaunch_ready() {
  fill_ready 2
  ticket 02-second "Blocked by: 01" "Touches: two.txt"
  ticket 03-third "Blocked by: 01" "Touches: three.txt"
  ticket 04-fourth "Blocked by: 01" "Touches: four.txt"
  run_bin -0 team-next T7 --fill
  rm "$STUB_FIXTURES/launches-live" "$STUB_FIXTURES/agents"
}

# stowed_here <cause>: T7 stowed on home-pc for <cause>, its task worktree and both ticket
# worktrees kept, as team-stow logs it.
stowed_here() {
  event stowing "$(jq -cn --arg c "$1" '{machine: "home-pc", cause: $c, roles: ["builder"]}')"
  event stowed "$(jq -cn --arg c "$1" --arg h "$(git -C "${wt:?}" rev-parse HEAD)" '{machine: "home-pc",
    worktrees: [{project: "proj", branch: "feat/T7-toil", head: $h},
      {project: "proj", branch: "feat/T7-toil--02", head: $h, ticket: "02"},
      {project: "proj", branch: "feat/T7-toil--03", head: $h, ticket: "03"}],
    roles: ["builder"], sessions: ["builder"], cause: $c}')"
}

# tilde <path>: <path> as a brief writes it, ~/ for $HOME/.
tilde() {
  echo "${1/#"$HOME/"/"~/"}"
}

@test "T287: --fill relaunches each stowed ticket builder in its ticket worktree on resume-build-NN before any ready ticket, counting it against the cap" {
  relaunch_ready
  stowed_here level
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "ticket 02's builder c0000001 was stowed at 2026-11-01T10:00:00Z: it resumes in $HOME/slots/proj/2
brief $TEAM_HOME/tasks/T7/brief-resume-build-02.md
launched T7-builder-02 c0000003
ticket 03's builder c0000002 was stowed at 2026-11-01T10:00:00Z: it resumes in $HOME/slots/proj/3
brief $TEAM_HOME/tasks/T7/brief-resume-build-03.md
launched T7-builder-03 c0000004
full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  assert_equal "$(fill_launches | tail -n 2)" \
    '{"session":"c0000003","ticket":"02","worktree":"slots/proj/2","branch":"feat/T7-toil--02","brief":"brief-resume-build-02","toolkits":["browser"]}
{"session":"c0000004","ticket":"03","worktree":"slots/proj/3","branch":"feat/T7-toil--03","brief":"brief-resume-build-03","toolkits":["browser"]}'
  assert_equal "$(record resume-build-02 | jq -cS .)" "$(jq -cnS --arg b "$(tilde "$TEAM_HOME/tasks/T7/brief-build-02.md")" \
    '{template: "resume", values: {role: "builder", brief: $b, from: "the stow for the level at 2026-11-01T10:00:00Z",
      snapshot: "none: your worktree stayed in place, as you left it"}}')"
  grep -qF 'Worktree: `~/slots/proj/2`, branch `feat/T7-toil--02`: the one you left' "$TEAM_HOME/tasks/T7/brief-resume-build-02.md"
  grep -qF 'You build in a ticket worktree of your own' "$TEAM_HOME/tasks/T7/brief-resume-build-02.md"
  assert_equal "$(bg_calls | tail -n 1 | jq -r 'last')" "Read your brief at $TEAM_HOME/tasks/T7/brief-resume-build-03.md"
  assert_equal "$(bg_calls | tail -n 1 | jq -r '.[index("--name") + 1]')" "T7-builder-03"

  # Both live now, a rerun relaunches nothing.
  live c0000003 1000 c0000004 1000
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  # Stowed again with 02 gone, 02 resumes on the next free name, beside the live 03.
  stowed_here handoff
  live c0000004 1000
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "ticket 02's builder c0000003 was stowed at 2026-11-01T10:00:00Z: it resumes in $HOME/slots/proj/2
brief $TEAM_HOME/tasks/T7/brief-resume-build-02-2.md
launched T7-builder-02 c0000005
full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  assert_equal "$(jq -r .values.from "$TEAM_HOME/tasks/T7/brief-resume-build-02-2.json")" "the handoff from home-pc at 2026-11-01T10:00:00Z"
  run_bin -0 team-log --check
}

# builder_model <model>: T7's opened event names <model> as its builder model, as team-open
# --builder-model logs it, and the setup's builder launches ran on it, as team-worker logs them.
builder_model() {
  jq -c --arg m "$1" 'if .event == "opened" then .builder_model = $m
    elif .event == "launch" and .role == "builder" and .model_from == null then .model = $m | .model_from = "task"
    else . end' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/ledger.next"
  mv "$TEAM_HOME/ledger.next" "$TEAM_HOME/ledger.jsonl"
}

# Each session claude started, by its name, with the --model it was given, if any.
launch_models() {
  bg_calls | jq -c '[.[index("--name") + 1], ((index("--model") // empty) as $i | .[$i + 1])]'
}

# Each launch team-worker logged after the setup's b0000001, its brief and model, and where the
# model came from.
logged_models() {
  jq -c 'select(.event == "launch" and .session != "b0000001") | [.brief, .model, .model_from]' "$TEAM_HOME/ledger.jsonl"
}

@test "a task's builder model holds through each builder launch team-next makes: the next ticket's, a stow's round, the fill's and its relaunches" {
  # Before a task kept its builder model, each of these launched with no --model and logged no
  # model, so the builder fell back to the settings' model.
  local head
  head=$(git -C "${wt:?}" rev-parse HEAD)
  builder_model sonnet
  run_bin -0 team-next T7 -- "T7 DONE 01 ${head:0:8} done"
  # The round after a findings review, its builder stowed.
  reviewing "$head"
  review_logged findings "$head" '[3]' '{"blocking": 1}'
  event 'done' '{role: "reviewer", session: "r0000002"}'
  echo "# review" >"$wt/.scratch/task/review.md"
  run_bin -0 team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$(launch_models)" $'["T7-builder","sonnet"]\n["T7-builder","sonnet"]'
  assert_equal "$(logged_models | jq -c 'select(.[0] != "brief-review")')" \
    $'["brief-build-02","sonnet","task"]\n["brief-round-1","sonnet","task"]'
}

@test "a builder launched on --model keeps that model through team-next's next builder launch" {
  # The setup's builder b0000001 launched on --model fable, which is its task's builder model
  # from then on, over the opened event's.
  builder_model sonnet
  jq -c 'if .event == "launch" and .session == "b0000001" then .model = "fable" | .model_from = "launch" else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/ledger.next"
  mv "$TEAM_HOME/ledger.next" "$TEAM_HOME/ledger.jsonl"
  local head
  head=$(git -C "${wt:?}" rev-parse HEAD)
  run_bin -0 team-next T7 -- "T7 DONE 01 ${head:0:8} done"
  assert_equal "$(launch_models)" '["T7-builder","fable"]'
  assert_equal "$(logged_models)" '["brief-build-02","fable","task"]'
  run_bin -0 team-log --check
}

@test "a task's builder model holds through --fill's ticket builders and their relaunches after a stow" {
  builder_model sonnet
  relaunch_ready
  stowed_here level
  run_bin -0 team-next T7 --fill
  assert_equal "$(launch_models)" \
    $'["T7-builder-02","sonnet"]\n["T7-builder-03","sonnet"]\n["T7-builder-02","sonnet"]\n["T7-builder-03","sonnet"]'
  assert_equal "$(logged_models)" \
    $'["brief-build-02","sonnet","task"]\n["brief-build-03","sonnet","task"]\n["brief-resume-build-02","sonnet","task"]\n["brief-resume-build-03","sonnet","task"]'
  run_bin -0 team-log --check
}

@test "T287: --fill relaunches a crashed ticket builder on resume-crash, with the resume report's checkpoint and snapshot" {
  relaunch_ready
  # Both builders ran on laptop, which stopped with no handoff; this machine's resume re-made
  # their worktrees, its report saying what became of each snapshot.
  jq -c 'if .event == "launch" and .ticket != null then .machine = "laptop" else . end' "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/ledger.next"
  mv "$TEAM_HOME/ledger.next" "$TEAM_HOME/ledger.jsonl"
  local n
  for n in 02 03; do
    event worktree-moved "$(jq -cn --arg n "$n" --arg wt "$(ticket_wt "$n")" '{project: "proj", branch: "feat/T7-toil--\($n)",
      from: "/home/x/slots/proj/9", worktree: $wt, machine: "home-pc", ticket: $n}')"
  done
  jq -cn --arg at "$(date -u +%FT%TZ)" '{machine: "home-pc", epoch: 3, stolen_from: "laptop", written_at: $at,
    tasks: [{task: "T7", here: false, stowed: null, crashed: {machine: "laptop", checkpoint: "2026-11-01T09:40:00Z", roles: ["builder"]},
      worktrees: [{project: "proj", ticket: "02", snapshot: {ref: "wip/proj/T7--02", commit: "abc", parent: "def", at: "2026-11-01T09:35:00Z", applied: true, reason: null}},
        {project: "proj", ticket: "03", snapshot: {ref: "wip/proj/T7--03", commit: "abc", parent: "def", at: null, applied: false, reason: "feat/T7-toil--03 is past it"}}],
      failures: []}]}' >"$TEAM_HOME/tasks/resume-2026-11-01-100000.json"
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "ticket 02's builder c0000001 crashed on laptop: it resumes in $HOME/slots/proj/2
brief $TEAM_HOME/tasks/T7/brief-resume-build-02.md
launched T7-builder-02 c0000003
ticket 03's builder c0000002 crashed on laptop: it resumes in $HOME/slots/proj/3
brief $TEAM_HOME/tasks/T7/brief-resume-build-03.md
launched T7-builder-03 c0000004
full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  assert_equal "$(record resume-build-02 | jq -cS .)" "$(jq -cnS --arg b "$(tilde "$TEAM_HOME/tasks/T7/brief-build-02.md")" \
    '{template: "resume-crash", values: {role: "builder", brief: $b, machine: "laptop", checkpoint: "2026-11-01T09:35:00Z",
      snapshot: "applied as uncommitted changes in your worktree"}}')"
  assert_equal "$(jq -c '.values | [.checkpoint, .snapshot]' "$TEAM_HOME/tasks/T7/brief-resume-build-03.json")" \
    '["2026-11-01T09:40:00Z","not applied: feat/T7-toil--03 is past it; they are on `team-home/wip/proj/T7--03`"]'
  grep -qF 'You build in a ticket worktree of your own' "$TEAM_HOME/tasks/T7/brief-resume-build-03.md"
  assert_equal "$(fill_launches | tail -n 2 | jq -r '[.ticket, .brief] | join(" ")')" "02 brief-resume-build-02
03 brief-resume-build-03"

  # A report older than the launch says nothing of it: the checkpoint and snapshot are unknown.
  jq -c 'if .event == "launch" and .session == "c0000003" then .machine = "laptop" | .ts = "2099-01-01T00:00:00Z" else . end' \
    "$TEAM_HOME/ledger.jsonl" >"$TEAM_HOME/ledger.next"
  mv "$TEAM_HOME/ledger.next" "$TEAM_HOME/ledger.jsonl"
  live c0000004 1000
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$(sed -n 2p <<<"$output")" "brief $TEAM_HOME/tasks/T7/brief-resume-build-02-2.md"
  assert_equal "$(jq -c '.values | [.machine, .checkpoint, .snapshot]' "$TEAM_HOME/tasks/T7/brief-resume-build-02-2.json")" \
    '["laptop","an unknown time: no resume report since its last launch names it","none: your worktree stayed in place, as you left it"]'
  run_bin -0 team-log --check
}

@test "T287: --fill names a gone ticket builder that was neither stowed nor crashed, or whose worktree is not here, and relaunches none" {
  relaunch_ready
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "ticket 02's builder c0000001 is gone: recover it (the recover-worker skill)
ticket 03's builder c0000002 is gone: recover it (the recover-worker skill)
full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  assert_equal "$(bg_calls | wc -l)" 2
  # A live one is not named.
  live c0000002 1000
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "ticket 02's builder c0000001 is gone: recover it (the recover-worker skill)
full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  # Stowed, with its worktree no longer on this machine, it waits for team-open to make it.
  stowed_here handoff
  git -C "${primary:?}" worktree remove --force "$HOME/slots/proj/2"
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "ticket 02's builder c0000001 is gone, and its worktree $HOME/slots/proj/2 is not on this machine: make it with team-open --task T7 --resume proj --ticket 02, then run team-next T7 --fill again
full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
  assert_equal "$(bg_calls | wc -l)" 2
}

@test "T287: a relaunch refused for room stops --fill with exit 75 and its line, and a rerun relaunches the rest" {
  relaunch_ready
  stowed_here level
  # The two first launches' reservations still stand: room for one more builder of 0.5 GiB, not two.
  capacity_room $((1792 * 1048576))
  run_bin -75 --separate-stderr team-next T7 --fill
  assert_equal "$(tail -n 1 <<<"$output")" "brief $TEAM_HOME/tasks/T7/brief-resume-build-03.md"
  assert_equal "$(sed -n 3p <<<"$output")" "launched T7-builder-02 c0000003"
  assert_equal "$(tail -n 1 <<<"$stderr")" "team-next: no room for resume-build-03: the launch said $(grep '^team-worker: no room' <<<"$stderr"); ready and waiting for room: 03, 04; run team-next T7 --fill once there is room"
  capacity_room $((16 * 1073741824))
  live c0000003 1000
  run_bin -0 --separate-stderr team-next T7 --fill
  assert_equal "$output" "ticket 03's builder c0000002 was stowed at 2026-11-01T10:00:00Z: it resumes in $HOME/slots/proj/3
brief $TEAM_HOME/tasks/T7/brief-resume-build-03.md
launched T7-builder-03 c0000004
full: 2 of phase 1's cap 2 build (02, 03); ready and waiting for a slot: 04"
}
