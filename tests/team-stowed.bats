#!/usr/bin/env bats
# team-stowed: the stow skill's last step records the coordinator's stow in its session's
# compact-hold record, which tests/compact-hold.bats shows releasing a held auto-compaction.

load helpers/common

session=3169fcbd-0000-4000-8000-000000000000

setup() {
  sandbox
  state=$HOME/.local/state/agent-team
  record=$state/compact-hold/$session.json
  log=$state/compact-hold.log
}

@test "it records the stow, logs it and says no auto-compaction is held" {
  local before after
  # The real clock, which the stow is recorded at outside the tests.
  unset TEAM_COMPACT_HOLD_NOW
  before=$(date +%s)
  CLAUDE_CODE_SESSION_ID=$session run_bin -0 --separate-stderr team-stowed
  after=$(date +%s)
  assert_equal "$stderr" ""
  assert_equal "$output" "stowed at $(date -u -d "@$(jq .stowed_at "$record")" +%H:%M) UTC; no auto-compaction is held"
  assert_equal "$(jq -c 'del(.stowed_at)' "$record")" '{"held_at":null,"told_at":null,"released_at":null,"blocks":0}'
  (($(jq .stowed_at "$record") >= before && $(jq .stowed_at "$record") <= after))
  assert_equal "$(jq -c 'del(.at)' "$log")" "{\"session\":\"$session\",\"event\":\"stowed\"}"
  jq -e '.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$log"
  assert_equal "$(find "$state" -type f | LC_ALL=C sort)" "$log"$'\n'"$record"$'\n'"$record.lock"
}

@test "with a hold standing it says the held auto-compaction runs at its next check, and keeps the hold" {
  mkdir -p "${record%/*}"
  echo '{"held_at":1763200000,"told_at":1763200005,"stowed_at":1763100000,"released_at":null,"blocks":2}' >"$record"
  CLAUDE_CODE_SESSION_ID=$session run_bin -0 team-stowed
  assert_equal "$output" "stowed at $(date -u -d "@$(jq .stowed_at "$record")" +%H:%M) UTC; the held auto-compaction runs at its next check"
  assert_equal "$(jq -c 'del(.stowed_at)' "$record")" '{"held_at":1763200000,"told_at":1763200005,"released_at":null,"blocks":2}'
  (($(jq .stowed_at "$record") > 1763200000))
}

@test "a second stow moves the time and logs again" {
  CLAUDE_CODE_SESSION_ID=$session run_bin -0 team-stowed
  jq -c '.stowed_at = 5' "$record" >"$record.old"
  mv "$record.old" "$record"
  CLAUDE_CODE_SESSION_ID=$session run_bin -0 team-stowed
  (($(jq .stowed_at "$record") > 5))
  assert_equal "$(jq -r .event "$log")" $'stowed\nstowed'
}

@test "it is refused for a worker" {
  CLAUDE_CODE_SESSION_ID=$session worker_refused team-stowed "records no stow"
  [[ ! -e $state/compact-hold && ! -e $log ]]
}

@test "it is refused without a session id, and with a malformed one" {
  local id
  run_bin -1 --separate-stderr team-stowed
  assert_equal "$output" ""
  assert_equal "$stderr" "team-stowed records the coordinator's own stow: run it in the coordinator's session, where CLAUDE_CODE_SESSION_ID names it"
  for id in '' '../x' 'a b' 'a/b' 'a.json'; do
    CLAUDE_CODE_SESSION_ID=$id run_bin -1 --separate-stderr team-stowed
    assert_equal "$stderr" "team-stowed records the coordinator's own stow: run it in the coordinator's session, where CLAUDE_CODE_SESSION_ID names it"
  done
  [[ ! -e $state/compact-hold && ! -e $log ]]
}

@test "the coordinator itself may run it, and an argument is a usage error" {
  AGENT_TEAM_ROLE=coordinator CLAUDE_CODE_SESSION_ID=$session run_bin -0 team-stowed
  CLAUDE_CODE_SESSION_ID=$session run_bin -2 team-stowed now
  assert_equal "$output" "team-stowed: it takes no argument"
}

@test "a record that is no JSON object is refused and left as it is" {
  mkdir -p "${record%/*}"
  echo '[]' >"$record"
  CLAUDE_CODE_SESSION_ID=$session run_bin -1 team-stowed
  assert_equal "$output" "$record is not a compact-hold record"
  assert_equal "$(cat "$record")" '[]'
  [[ ! -e $log ]]
}
