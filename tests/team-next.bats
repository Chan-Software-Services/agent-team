#!/usr/bin/env bats
# shellcheck disable=SC2154 # wt and sha are helpers/team-next.bash's
# team-next: a worker's message taken to the task's next step. Its checks refuse with nothing
# changed; it logs the message's events through team-log once, and a builder's DONE <NN> launches
# the next ready ticket's builder, or the deliverer once every ticket is done, through team-brief
# and team-worker. A ticket builder's DONE is tests/team-next-integrate.bats', the review hand-off
# tests/team-next-review.bats', the verdicts tests/team-next-verdicts.bats', the checks wait
# tests/team-next-ci.bats', what a passed wait prints tests/team-next-merge.bats', two repositories
# and the reviewer App tests/team-next-repos.bats', and --fill tests/team-next-tickets.bats'; the
# sandbox is helpers/team-next's.

load helpers/common
load helpers/github-api
load helpers/team-next

setup() {
  team_next_sandbox
}

@test "a builder's DONE logs the ticket and the done, renders the next ready ticket's brief and launches its builder" {
  local count
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 ${sha:0:8} team-log takes comma lists"
  assert_equal "$output" "logged ticket-done ticket=01 commits=[\"${sha:0:8}\"] note=team-log takes comma lists
logged done role=builder session=b0000001
brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder c0000001"
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event != "launch")')" \
    "{\"task\":\"T7\",\"event\":\"ticket-done\",\"ticket\":\"01\",\"commits\":[\"${sha:0:8}\"],\"note\":\"team-log takes comma lists\"}
{\"task\":\"T7\",\"event\":\"done\",\"role\":\"builder\",\"session\":\"b0000001\"}"
  # The launch: the next ready ticket (02; 03 waits for T171), in the worktree, with the latest
  # builder launch's toolkits, its brief logged.
  assert_equal "$(logged_from $((count + 1)) | jq -c 'select(.event == "launch") | {role, session, worktree, toolkits, brief}')" \
    "$(jq -cn --arg wt "$wt" '{role: "builder", session: "c0000001", worktree: $wt, toolkits: ["browser"], brief: "brief-build-02"}')"
  grep -qF 'Your ticket: number 02 in `.scratch/task/tickets/`.' "$TEAM_HOME/tasks/T7/brief-build-02.md"
  assert_equal "$(jq -c . "$TEAM_HOME/tasks/T7/brief-build-02.json")" '{"template":"builder-ticket","project":"proj","values":{"ticket":"02"}}'
  assert_equal "$(bg_calls | jq -r 'last')" "Read your brief at $(tail -n 2 <<<"$output" | head -n 1 | sed 's/^brief //')"
  assert_equal "$(bg_calls | jq -r 'index("--plugin-dir") as $i | .[$i + 1]')" "$REPO_ROOT/toolkits/browser"
  assert_equal "$(bg_calls | wc -l)" 1
}

@test "an ask that names tickets holds only those tickets, so the hand-off goes on to another" {
  # T193: the ask held only later tickets, yet ticket 01's DONE was refused.
  event asked '{id: "prune", text: "Prune 03?", tickets: ["03"]}'
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-build-02.md"
  assert_contains "$output" "launched T7-builder c0000001"
}

@test "a ticket an ask holds is neither the next ready one nor one --next may name, until the ask is answered" {
  event asked '{id: "prune", text: "Prune 02?", tickets: ["02"]}'
  refused "--next 02 is not ready once 01 is done: 02 held by the unanswered ask prune" T7 --next 02 -- "T7 DONE 01 $sha done"
  refused "tickets remain once 01 is done, but none is ready: 02 held by the unanswered ask prune" T7 -- "T7 DONE 01 $sha done"
  # Answered, it holds nothing.
  event answered '{id: "prune", answer: "keep it"}'
  run_bin -0 team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-build-02.md"
}

@test "the brief path in the prompt is the one team-brief printed, and team-worker reads it" {
  run_bin -0 team-next T7 -- "T7 DONE 01 $sha done"
  local brief
  brief=$(grep '^brief ' <<<"$output" | sed 's/^brief //')
  assert_equal "$(bg_calls | jq -r 'last')" "Read your brief at $brief"
  [[ -f ${brief/#\~/$HOME} ]]
}

@test "a ticket with a Waits for: line is launched only when --next names it" {
  run_bin -0 team-next T7 --next 03 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "launched T7-builder c0000001"
  [[ -f $TEAM_HOME/tasks/T7/brief-build-03.md ]]
  [[ ! -e $TEAM_HOME/tasks/T7/brief-build-02.md ]]
  assert_equal "$(jq -r 'select(.event == "launch") | .brief' "$TEAM_HOME/ledger.jsonl" | tail -n 1)" brief-build-03
}

@test "with only a waiting ticket left, it is refused, naming what each waits on, until --next names it" {
  event ticket-done '{ticket: "02", commits: ["0123456"]}'
  event ticket-done '{ticket: "04", commits: ["0123456"]}'
  refused "tickets remain once 01 is done, but none is ready: 03 waiting: T171 merged; --next <NN> launches a waiting one" \
    T7 -- "T7 DONE 01 $sha done"
  run_bin -0 team-next T7 --next 03 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "launched T7-builder c0000001"
}

@test "tickets blocked or running are named when none is ready" {
  ticket 02-second "Blocked by: 01" "Waits for: PR 9"
  ticket 04-fourth "Blocked by: 03"
  ticket 05-fifth "Blocked by: None"
  launched b0000005 brief-build-05
  launched b0000001 brief-build-01
  refused "tickets remain once 01 is done, but none is ready: 02 waiting: PR 9; 03 waiting: T171 merged; 04 blocked on 03; 05 running in session b0000005" \
    T7 -- "T7 DONE 01 $sha done"
}

@test "with every ticket done it renders builder-deliver with the plan's goal and launches the deliverer" {
  for n in 02 03 04; do event ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["0123456"]}')"; done
  run_bin -0 team-next T7 -- "T7 DONE 01 $sha the last one"
  assert_contains "$output" "brief-deliver.md"
  assert_contains "$output" "launched T7-builder c0000001"
  assert_equal "$(jq -c '{template, values}' "$TEAM_HOME/tasks/T7/brief-deliver.json")" \
    '{"template":"builder-deliver","values":{"goal":"Coordinator toil goes to the scripts.","tickets":"every ticket"}}'
  grep -qF 'Coordinator toil goes to the scripts.' "$TEAM_HOME/tasks/T7/brief-deliver.md"
  assert_equal "$(jq -r 'select(.event == "launch") | .brief' "$TEAM_HOME/ledger.jsonl" | tail -n 1)" brief-deliver
}

@test "a phase's last ticket done launches that phase's deliverer, deliver-p<n>, before any ticket of the next phase" {
  local brief=$TEAM_HOME/tasks/T7/brief-deliver-p1.md
  ticket 02-second "Blocked by: 01" "Phase: 2"
  ticket 03-third "Blocked by: None" "**Phase:** 2"
  ticket 04-fourth "Blocked by: 02" "Phase: 2"
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 $sha the last of phase 1"
  assert_equal "$(tail -n 2 <<<"$output")" "brief $brief
launched T7-builder c0000001"
  assert_equal "$(record deliver-p1 | jq -cS .)" \
    '{"template":"builder-deliver","values":{"goal":"Coordinator toil goes to the scripts.","tickets":"every ticket of phase 1 (01)"}}'
  grep -qF 'you are the builder who delivers: every ticket of phase 1 (01) is done and pushed on `feat/T7-toil`.' "$brief"
  grep -qF 'the boxes of every ticket of phase 1 (01) are ticked' "$brief"
  [[ ! -e $TEAM_HOME/tasks/T7/brief-build-03.md ]]
  assert_equal "$(bg_calls | wc -l)" 1
}

@test "while a phase has tickets not done, the next ticket is that phase's, and --next refuses a later phase's" {
  ticket 02-second "Blocked by: 01"
  ticket 03-third "Blocked by: None" "Phase: 2"
  ticket 04-fourth "Blocked by: 03" "Phase: 2"
  refused "--next 03 is in phase 2, but phase 1 has tickets not done: 02 ready" T7 --next 03 -- "T7 DONE 01 $sha done"
  run_bin -0 team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-build-02.md"
  # None of phase 1's left ready: refused naming phase 1's alone.
  ticket 05-fifth "Blocked by: None"
  launched b0000005 brief-build-05
  refused "tickets of phase 1 remain once 01 is done, but none is ready: 02 running in session c0000001; 05 running in session b0000005" \
    T7 --from b0000001 -- "T7 DONE 01 ${sha:0:9} again"
}

@test "a later phase's deliverer is deliver-p<n>, and --next is refused while a phase's deliverer is due" {
  ticket 02-second "Blocked by: 01" "Phase: 2"
  ticket 03-third "Blocked by: None" "Phase: 3"
  ticket 04-fourth "Blocked by: 03" "Phase: 3"
  refused "phase 1's tickets are all done once 01 is, so its deliverer comes next, not --next 03" \
    T7 --next 03 -- "T7 DONE 01 $sha done"
  event ticket-done '{ticket: "01", commits: ["0123456"]}'
  launched b0000002 brief-build-02 '["browser"]'
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 02 $sha phase 2 done"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-deliver-p2.md"
  assert_equal "$(record deliver-p2 | jq -r .values.tickets)" "every ticket of phase 2 (02)"
}

@test "a launch that failed finishes on the rerun without logging again; a rerun after the launch is refused" {
  local count
  # 04 waits on 01 alone, so after the hand-off to 02 a rerun would still find a ready ticket.
  ticket 04-fourth "Blocked by: 01"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  touch "$STUB_FIXTURES/fail-once"
  run_bin -1 team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "team-next: the launch failed; run the same command again to finish it, which logs nothing twice"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "ticket-done done "
  [[ -f $TEAM_HOME/tasks/T7/brief-build-02.md ]]

  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "already logged ticket-done ticket=01"
  assert_contains "$output" "already logged done role=builder session=b0000001"
  assert_contains "$output" "launched T7-builder c0000001"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "ticket-done done launch "

  refused "ticket 01 is already handed off: T7-builder c0000001 was launched at" T7 -- "T7 DONE 01 $sha done"
}

@test "a toolkit carried forward that the project no longer lists is team-worker's refusal, and no launch is logged" {
  local count
  sed -i 's/^toolkits = \["browser"\]$/toolkits = []/' "$TEAM_HOME/projects.toml"
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -1 team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "team-worker: toolkit 'browser' is not one of proj's toolkits in projects.toml (it lists none): a new toolkit for a project takes Daniel's yes, then its name in that project's toolkits line in projects.toml"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "ticket-done done "
  assert_equal "$(bg_calls)" ""
}

@test "a deliverer's brief a launch already read is kept, and the next deliverer takes the next free name" {
  # Every other ticket done and the deliverer launched once; then 01 is built again.
  for n in 02 03 04; do event ticket-done "$(jq -cn --arg n "$n" '{ticket: $n, commits: ["0123456"]}')"; done
  echo "# delivered" >"$TEAM_HOME/tasks/T7/brief-deliver.md"
  launched d0000001 brief-deliver
  launched b0000009 brief-build-01
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 $sha again"
  assert_contains "$output" "brief $TEAM_HOME/tasks/T7/brief-deliver-2.md"
  assert_equal "$(jq -r 'select(.event == "launch") | .brief' "$TEAM_HOME/ledger.jsonl" | tail -n 1)" brief-deliver-2
  assert_equal "$(cat "$TEAM_HOME/tasks/T7/brief-deliver.md")" "# delivered"
  # A one-phase task's deliverer says every ticket.
  grep -qF 'you are the builder who delivers: every ticket is done and pushed' "$TEAM_HOME/tasks/T7/brief-deliver-2.md"
}

@test "a running ticket is not ready for --next" {
  launched b0000002 brief-build-02
  launched b0000001 brief-build-01
  refused "--next 02 is not ready once 01 is done: 02 running in session b0000002" T7 --next 02 -- "T7 DONE 01 $sha done"
}

@test "refused with nothing changed, by launch_refusal's texts: a closed task, Daniel's hold, an unanswered ask; and no plan-approved" {
  # An old held reads as Daniel's hold (legacy_cause), and a typed one is refused alike.
  event held '{reason: "Daniel paused it"}'
  refused "T7 is on Daniel's hold since 2026-11-01T10:00:00Z (held-1): Daniel paused it; only Daniel's word lifts it: team-log T7 resumed id=held-1 discord_message=<their message id>" T7 -- "T7 DONE 01 $sha done"
  event resumed '{}'
  event held '{reason: "Daniel: not now", cause: "daniel-hold", discord_message: "1563000000000000044"}'
  # A message that launches nothing is refused too.
  refused "T7 is on Daniel's hold since 2026-11-01T10:00:00Z (held-2): Daniel: not now" T7 -- "T7 QUESTION which way? | options: a, b"
  event resumed '{id: "held-2", discord_message: "1563000000000000046"}'
  event asked '{id: "scope", text: "Which scope?"}'
  refused "T7 has an unanswered ask, scope, since 2026-11-01T10:00:00Z" T7 -- "T7 DONE 01 $sha done"
  event answered '{id: "scope", text: "This one.", discord_message: "1563000000000000045"}'
  grep -v plan-approved "$TEAM_HOME/ledger.jsonl" >"$BATS_TEST_TMPDIR/l" && cp "$BATS_TEST_TMPDIR/l" "$TEAM_HOME/ledger.jsonl"
  refused "T7 has no plan-approved, so no ticket hand-off" T7 -- "T7 DONE 01 $sha done"
  event plan-approved '{by: "coordinator"}'
  event closed '{archive: [], returned: [], kept: []}'
  refused "T7 is closed" T7 -- "T7 DONE 01 $sha done"
}

@test "refused with nothing changed while the plan approval is withdrawn, naming the withdrawal, until the plan is approved again" {
  event plan-approval-withdrawn '{discord_message: "1563000000000000047"}'
  local named="T7's plan approval was withdrawn at 2026-11-01T10:00:00Z in Discord message 1563000000000000047"
  refused "team-next: $named, so no ticket hand-off; approve the plan again first (step 3 of the manual)" T7 -- "T7 DONE 01 $sha done"
  refused "team-next: $named, so no review hand-off; approve the plan again first (step 3 of the manual)" T7 -- "T7 DONE review-ready $sha"
  refused "team-next: $named, so no fill hand-off; approve the plan again first (step 3 of the manual)" T7 --fill
  # A message that launches no one meets the same refusal once it would hand off.
  launched r0000001 brief-review '[]' reviewer
  refused "team-next: $named, so no verdict hand-off; approve the plan again first (step 3 of the manual)" T7 --from r0000001 -- \
    "T7 DONE pass $sha findings=blocking:0,correctness:0,security:0,real-data:0,note-change:0,note-before:0 before=none guarded=none"
  # A message that hands nothing off is logged as before.
  run_bin -0 team-next T7 --from b0000001 -- "T7 QUESTION which way? | options: a, b"
  event plan-approved '{by: "coordinator", plan: {"tasks/T7/plan.md": "ab12"}}'
  run_bin -0 team-next T7 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "launched T7-builder c0000001"
}

# The manual: a message team-next refuses for an open ask is logged with team-log --from-message,
# and team-next runs on it once the ask is settled, logging nothing twice.
@test "a DONE logged by team-log --from-message while an ask was open is handed off once it is answered, logged once" {
  event asked '{id: "scope", text: "Which scope?"}'
  refused "T7 has an unanswered ask, scope" T7 -- "T7 DONE 01 $sha done"
  run_bin -0 team-log T7 --from-message "T7 DONE 01 $sha done"
  event answered '{id: "scope", text: "This one.", discord_message: "1563000000000000045"}'
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE 01 $sha done"
  assert_equal "$output" "already logged ticket-done ticket=01 commits=[\"$sha\"] note=done
already logged done role=builder session=b0000001
brief $TEAM_HOME/tasks/T7/brief-build-02.md
launched T7-builder c0000001"
  assert_equal "$(jq -c 'select(.event == "ticket-done" or .event == "done")' "$TEAM_HOME/ledger.jsonl" | wc -l)" 2
}

@test "refused with nothing changed: an unknown ticket, a sha the worktree's HEAD lacks, an unknown --next" {
  refused "T7 has no ticket 09: its tickets are 01, 02, 03, 04" T7 -- "T7 DONE 09 $sha done"
  refused "abcdef0 is not a commit the HEAD of $wt holds, so ticket 01 is not handed off" T7 -- "T7 DONE 01 $sha abcdef0 done"
  # A commit on another branch, which HEAD does not hold.
  git -C "${wt:?}" checkout -q -b side
  local side
  side=$(commit two.txt "feat: elsewhere")
  git -C "${wt:?}" checkout -q feat/T7-toil
  refused "$side is not a commit the HEAD of $wt holds" T7 -- "T7 DONE 01 $side done"
  refused "--next 08 is none of T7's tickets: they are 01, 02, 03, 04" T7 --next 08 -- "T7 DONE 01 $sha done"
  refused "--next 04 is not ready once 01 is done: 04 blocked on 02" T7 --next 04 -- "T7 DONE 01 $sha done"
}

@test "a message team-log cannot read is refused with its reason, nothing changed" {
  refused "team-log: the message is for T8, not T7" T7 -- "T8 DONE 01 $sha done"
  refused "team-log: DONE 01 takes one or more shas" T7 -- "T7 DONE 01 nosha done"
}

@test "any other message is logged and reported as having no hand-off" {
  local count
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 team-next T7 -- "T7 PAUSED stowed"
  assert_equal "$output" "logged paused reason=stowed cause=stow role=builder session=b0000001
no hand-off for PAUSED stowed: no review's sent-back findings or failed checks wait for a round"
  # A stow with detail is a stow too, by park_cause, as every reader of a stow has it.
  run_bin -0 team-next T7 -- "T7 PAUSED stowed ad6520fc for shutdown; next: re-run the gate"
  assert_equal "${lines[1]}" "no hand-off for PAUSED stowed: no review's sent-back findings or failed checks wait for a round"
  run_bin -0 team-next T7 -- "T7 QUESTION Which file holds the goal?"
  assert_equal "$output" "logged question role=builder text=Which file holds the goal?
no hand-off for QUESTION"
  # The same message again holds nothing new since the launch.
  run_bin -0 team-next T7 -- "T7 QUESTION Which file holds the goal?"
  assert_equal "$output" "already logged question role=builder text=Which file holds the goal?
no hand-off for QUESTION"
  run_bin -0 team-next T7 -- "T7 DONE gate run=r1 head=0123456 outcome=pushed"
  assert_equal "$output" "logged gate-run run=r1 head=0123456 outcome=pushed
no hand-off for DONE gate"
  assert_equal "$(logged_from $((count + 1)) | jq -r .event | tr '\n' ' ')" "paused paused question gate-run "
  assert_equal "$(bg_calls)" ""
  # A gate run that re-gates a base merge says once that the brief asks for no such run, though
  # team-next reads the message before it logs it.
  run_bin -0 --separate-stderr team-next T7 -- "T7 DONE gate run=r2 head=0123456 outcome=pushed cause=base-merge"
  assert_equal "$output" "logged gate-run run=r2 head=0123456 outcome=pushed cause=base-merge
no hand-off for DONE gate"
  assert_equal "$(grep -c 're-gates a base merge' <<<"$stderr")" 1
}

@test "an ops session's DONE and QUESTION are logged once as their length, the DONE with --relay, and hand nothing on" {
  launched d0000001 "" '["prod-read"]' ops
  local count answer='42 orders; the newest is Jean Dupré, 1187'
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  # Its first word is a ticket's, but the sender is the ops session, so it is the answer.
  run_bin -0 team-next T7 --from T7-ops --relay 1564000000000000007 -- "T7 DONE $answer"
  assert_equal "$output" "logged done role=ops session=d0000001 report_chars=${#answer} relay=1564000000000000007
no hand-off for DONE"
  # A rerun, with the relay or without it, logs it once, as for every role.
  run_bin -0 team-next T7 --from T7-ops --relay 1564000000000000007 -- "T7 DONE $answer"
  assert_equal "$output" "already logged done role=ops session=d0000001 report_chars=${#answer} relay=1564000000000000007
no hand-off for DONE"
  run_bin -0 team-next T7 --from T7-ops -- "T7 DONE $answer"
  assert_equal "$output" "already logged done role=ops session=d0000001 report_chars=${#answer}
no hand-off for DONE"
  run_bin -0 team-next T7 --from T7-ops -- 'T7 QUESTION which store holds order 1187?'
  assert_equal "$output" "logged question role=ops chars=29
no hand-off for QUESTION"
  run_bin -0 team-next T7 --from T7-ops -- 'T7 QUESTION which store holds order 1187?'
  assert_equal "$output" "already logged question role=ops chars=29
no hand-off for QUESTION"
  assert_equal "$(logged_from $((count + 1)))" "{\"task\":\"T7\",\"event\":\"done\",\"role\":\"ops\",\"session\":\"d0000001\",\"report_chars\":${#answer},\"relay\":\"1564000000000000007\"}
{\"task\":\"T7\",\"event\":\"question\",\"role\":\"ops\",\"chars\":29}"
  if grep -E 'Dupré|1187' "$TEAM_HOME/ledger.jsonl"; then
    echo "the ledger holds the ops answer's text" >&2
    return 1
  fi
  # --relay with another message is team-log's refusal, and a malformed one a malformed command line, each changing nothing.
  refused "team-log: --relay is taken only with an ops session's DONE, the answer it points at in Discord, not T7-builder's DONE" \
    T7 --from T7-builder --relay 1564000000000000008 -- 'T7 DONE .scratch/task/notes.md'
  local before
  before=$(state)
  run_bin -2 team-next T7 --from T7-ops --relay 'the relay' -- "T7 DONE $answer"
  assert_contains "$output" "--relay takes the Discord id of the relay's message, got 'the relay'"
  assert_equal "$(state)" "$before"
  assert_equal "$(bg_calls)" ""
}

@test "an ops session's DONE of more than one line is logged with --relay as its length alone, and a PR of more than one line is refused saying a message is one line" {
  launched d0000001 "" '["prod-read"]' ops
  local count answer=$'42 orders match:\n- the newest is Jean Dupré, 1187\n- 41 older ones'
  count=$(wc -l <"$TEAM_HOME/ledger.jsonl")
  run_bin -0 team-next T7 --from T7-ops --relay 1564000000000000007 -- "T7 DONE $answer"
  assert_equal "$output" "logged done role=ops session=d0000001 report_chars=${#answer} relay=1564000000000000007
no hand-off for DONE"
  run_bin -0 team-next T7 --from T7-ops --relay 1564000000000000007 -- "T7 DONE $answer"
  assert_equal "$output" "already logged done role=ops session=d0000001 report_chars=${#answer} relay=1564000000000000007
no hand-off for DONE"
  assert_equal "$(logged_from $((count + 1)))" "{\"task\":\"T7\",\"event\":\"done\",\"role\":\"ops\",\"session\":\"d0000001\",\"report_chars\":${#answer},\"relay\":\"1564000000000000007\"}"
  if grep -E 'Dupré|1187' "$TEAM_HOME/ledger.jsonl"; then
    echo "the ledger holds the ops answer's text" >&2
    return 1
  fi
  launched b0000001 brief
  refused "team-log: a worker's message is one line, but for an ops session's DONE or QUESTION, and this PR has 2 lines; log it on one line" \
    T7 -- $'T7 PR https://github.com/owner/proj/pull/12\nwith what it changed'
  assert_equal "$(bg_calls)" ""
}

@test "--next with another message, and a malformed command line, are usage errors" {
  run_bin -2 team-next T7 --next 02 -- "T7 PAUSED stowed"
  assert_contains "$output" "--next is taken only with a builder's DONE <NN> message, not PAUSED"
  run_bin -2 team-next T7 -- ""
  assert_contains "$output" "missing the worker's message"
  run_bin -2 team-next T7 "T7 PAUSED stowed"
  assert_contains "$output" "missing '--' before the worker's message"
  run_bin -2 team-next 7 -- "T7 PAUSED stowed"
  assert_contains "$output" "usage: team-next T<n>"
  run_bin -2 team-next T7 --next 2 -- "T7 DONE 01 $sha done"
  assert_contains "$output" "--next takes a two-digit ticket number, got '2'"
  run_bin -2 team-next T7 --from x --from y -- "T7 PAUSED stowed"
  assert_contains "$output" "--from is given twice"
}

@test "--help prints the header, and the manual's step 4 names team-next" {
  run_bin -0 team-next --help
  assert_contains "$output" "Usage: team-next T<n> [--from <session>] [--sent-back <list>] [--relay <id>] [--next <NN>] [--checks <file>]"
  assert_contains "$output" "[--since <file>] [--template rereview|verify] -- '<the worker's message>'"
  local manual=$REPO_ROOT/roles/coordinator.md
  grep -E '^4\. \*\*Build\.\*\*' -A 1 "$manual" | grep -qF '`team-next T<n> -- '"'"'<the message>'"'"'`'
  grep -qF -- '`--next NN`' "$manual"
}

@test "refused in a worker session, whatever its role, before any read; --help and the coordinator are not" {
  worker_refused team-next "runs no team-next" T7 -- 'T7 DONE 01 abc1234 the ticket'
  AGENT_TEAM_ROLE=reviewer run_bin -0 team-next --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-next")"
  AGENT_TEAM_ROLE=coordinator run_bin -2 team-next 7
  assert_contains "$output" "usage: team-next T<n>"
}
