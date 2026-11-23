#!/usr/bin/env bats
# team-stack's network changes and the heavy-run lock, on the stub docker (tests/helpers/docker.bash):
# a step that makes or removes a stack's Docker network adds or deletes an address on the host,
# which fails every request a browser on the machine has in flight (net::ERR_NETWORK_CHANGED),
# so it takes the machine's heavy-run lock, ~/.local/state/agent-team/heavy.lock (the sandbox's),
# and a heavy run holding it makes it wait (up) or leave the network for the sweep (a takedown).
# The stub logs each compose call with the lock's holder line while one holds it (heavy).

load helpers/common
load helpers/docker

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stack_project shop
  docker_stub "$STACK_WORKTREE"
  capacity_room $((16 * 1073741824))
  HEAVY_LOCK=$HOME/.local/state/agent-team/heavy.lock
  mkdir -p "${HEAVY_LOCK%/*}" "$HOME/.config/agent-team"
  # The sweep reads the live session list while a team stack runs: one busy session in every
  # running team stack's worktree, so it stops none.
  stub_reply claude "$(jq -c --arg wt "$STACK_WORKTREE" '[.[] | .Config.Labels["io.github.chanjdaniel.team.worktree"] // empty
    | select(. != "")] + [$wt] | unique | map({pid: 4242, cwd: ., kind: "background", startedAt: 1761098400000,
      sessionId: "5e55a0b1-1111-4222-8333-444455556666", name: "T7-builder", status: "busy", id: "5e55a0b1", state: null})' \
    "$DOCKER_STATE/containers.json")"
}

teardown() {
  if [[ -n ${HEAVY_PID:-} ]]; then kill "$HEAVY_PID" 2>/dev/null || true; fi
}

PROJECT=stackfix-shop-1
NETWORK=${PROJECT}_default
HEAVY_LINE='tests/run (pid 4242, T9) since 2026-11-23 09:00:00 +0000'

# The ledger opens <task> in the fixture project with the fixture's worktree.
open_task() {
  jq -cn --arg t "$1" --arg wt "$STACK_WORKTREE" '{ts: "2026-11-23T09:00:00Z", task: $t, event: "opened",
    project: "shop", path: "bug", type: "fix", title: "A task", branch: "work", base: "main",
    base_sha: "0000000", worktree: $wt}' >>"$TEAM_HOME/ledger.jsonl"
}

# A heavy run holds the lock, as team-heavy run does, for <seconds> (default 600), its holder line
# HEAVY_LINE: hold_heavy [<seconds>]. HEAVY_PID is the one process that holds it (a sleep that
# took the lock on its own descriptor), so ending it lets the lock go; teardown ends it.
hold_heavy() {
  printf '%s\n' "$HEAVY_LINE" >"$HEAVY_LOCK"
  bash -c 'exec 9>>"$1" && flock -x 9 && exec sleep "$2"' hold "$HEAVY_LOCK" "${1:-600}" 3>&- &
  HEAVY_PID=$!
  local i
  for ((i = 0; i < 100; i++)); do
    ! flock -n -s "$HEAVY_LOCK" true || { sleep 0.05; continue; }
    return 0
  done
  echo "hold_heavy: the lock was never taken" >&2
  return 1
}

# The heavy run ends.
end_heavy() {
  kill "$HEAVY_PID"
  wait "$HEAVY_PID" 2>/dev/null || true
  HEAVY_PID=''
}

# The compose calls made, one "<call without -f> | <holder line or free>" per line.
compose_locks() {
  docker_compose_env | jq -r '"\(.call | sub(" -f [^ ]+"; "")) | \(.heavy // "free")"'
}

# The names of the fixture stack's objects left, one per line: containers, volumes, networks.
stack_left() {
  jq -r --arg p "$PROJECT" '.[] | select(.Config.Labels["com.docker.compose.project"] == $p) | .Name' "$DOCKER_STATE/containers.json"
  jq -r --arg p "$PROJECT" '.[] | select(.Labels["com.docker.compose.project"] == $p) | .Name' "$DOCKER_STATE/volumes.json"
  jq -r --arg p "$PROJECT" '.[] | select(.Labels["com.docker.compose.project"] == $p) | .Name' "$DOCKER_STATE/networks.json"
}

# The fixture stack's anonymous volume, the one its web container mounts at /cache.
stack_anonymous() {
  jq -r --arg name "/$PROJECT-web-1" '.[] | select(.Name == $name) | .Mounts[] | select(.Destination == "/cache") | .Name' \
    "$DOCKER_STATE/containers.json"
}

@test "up makes a new stack's network with the heavy-run lock held, and lets it go before it starts the stack" {
  open_task T22
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  local calls
  calls=$(compose_locks)
  assert_equal "$(wc -l <<<"$calls")" 3
  assert_equal "$(sed -n 1p <<<"$calls")" "compose config --format json | free"
  [[ $(sed -n 2p <<<"$calls") =~ ^compose\ up\ --no-start\ \|\ team-stack\ up\ \(pid\ [0-9]+,\ $PROJECT\)\ since\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9:]{8}\ [+-][0-9]{4}$ ]]
  assert_equal "$(sed -n 3p <<<"$calls")" "compose up -d --wait | free"
  assert_equal "$output" "team-stack: $PROJECT is up for T22, not seeded: --no-seed"
  # The holder line is not team-heavy's own form, so team-heavy stop never takes its pid for a run's.
  run_bin -0 team-heavy stop
  assert_equal "$output" "nothing to stop"
}

@test "an up of the task's running or stopped stack, its network there, takes no lock and waits for no heavy run" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  hold_heavy
  local before
  before=$(docker_compose_env | wc -l)
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 team-stack stop --worktree "$STACK_WORKTREE"
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$stderr" ""
  assert_equal "$(compose_locks | tail -n "+$((before + 1))" | grep -c -- '--no-start' || true)" 0
  [[ $(jq -r --arg n "/$PROJECT-web-1" '.[] | select(.Name == $n) | .State.Running' "$DOCKER_STATE/containers.json") == true ]]
}

@test "up of a new stack waits while a heavy run holds the lock, saying once for whom, and starts it when the run ends" {
  open_task T22
  printf '{"wait_minutes": 1}\n' >"$HOME/.config/agent-team/stack.json"
  hold_heavy 3
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$stderr" "team-stack: waiting up to 1 minutes for the heavy-run lock, held by $HEAVY_LINE, before $PROJECT's network is made: a network made or removed while a heavy run's browser loads a page fails its requests (net::ERR_NETWORK_CHANGED)"
  assert_equal "$output" "team-stack: $PROJECT is up for T22, not seeded: --no-seed"
  [[ $(compose_locks | sed -n 2p) == "compose up --no-start | team-stack up (pid "* ]]
}

@test "up of a new stack exits 75 naming the holder when the heavy run outlasts wait_minutes, and makes nothing" {
  open_task T22
  printf '{"wait_minutes": 0.03}\n' >"$HOME/.config/agent-team/stack.json"
  hold_heavy
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_contains "$stderr" "team-stack: the heavy-run lock is still held by $HEAVY_LINE after 0.03 minutes, so team-stack up stops before $PROJECT's network is made; run it again once the heavy run ends"
  assert_equal "$(compose_locks)" "compose config --format json | $HEAVY_LINE"
  assert_equal "$(stack_left)" ""
  # Its admission went with it.
  assert_equal "$(jq -c '.[]' "$HOME/.local/state/agent-team/capacity/admitted.json" 2>/dev/null || true)" ""
}

@test "up waits for the heavy run before it takes down another task's stack, and takes it down under the lock" {
  (cd "$STACK_WORKTREE" && TEAM_OWNER=agent-team TEAM_TASK=T7 TEAM_KIND=dev TEAM_WORKTREE="$STACK_WORKTREE" TEAM_EXPIRES='' \
    TH_DIR="$STACK_WORKTREE" scripts/compose.sh up -d --wait) >/dev/null
  open_task T22
  printf '{"wait_minutes": 0.03}\n' >"$HOME/.config/agent-team/stack.json"
  hold_heavy
  run_bin -75 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  # T7's stack is untouched.
  [[ $(jq -r --arg n "/$PROJECT-web-1" '.[] | select(.Name == $n) | .Config.Labels["io.github.chanjdaniel.team.task"]' "$DOCKER_STATE/containers.json") == T7 ]]
  end_heavy
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$(compose_locks | grep -E '^compose -p .* down|--no-start' | sed -E 's/\(pid [0-9]+/(pid <pid>/; s/ since .*//')" \
    "compose -p $PROJECT down -v --remove-orphans | team-stack up (pid <pid>, $PROJECT)
compose up --no-start | team-stack up (pid <pid>, $PROJECT)"
}

@test "down with the lock free takes it for compose down, which removes the network" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" ""
  [[ $(compose_locks | tail -n 1) =~ ^compose\ -p\ $PROJECT\ down\ -v\ --remove-orphans\ \|\ team-stack\ down\ \(pid\ [0-9]+,\ $PROJECT\)\ since\  ]]
  assert_equal "$(stack_left)" ""
}

@test "down while a heavy run holds the lock removes the containers and volumes now and leaves the network for the sweep" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  local anonymous id
  anonymous=$(stack_anonymous)
  id=$(jq -r --arg n "/$PROJECT-web-1" '.[] | select(.Name == $n) | .Id' "$DOCKER_STATE/containers.json")
  hold_heavy
  run_bin -0 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$output" "team-stack: $PROJECT is removed, its logs in $STACK_WORKTREE/.scratch/task/stack-logs"
  assert_equal "$stderr" "team-stack: $PROJECT's network $NETWORK is left for team-stack sweep to remove once the heavy-run lock is free: it is held by $HEAVY_LINE, and a network removed now would fail that run's browser requests (net::ERR_NETWORK_CHANGED)"
  assert_equal "$(docker_calls | grep -E '^compose -p [^ ]+ down' || true)" ""
  assert_contains "$(docker_calls)" "rm --force --volumes $id"
  assert_contains "$(docker_calls)" "volume rm ${PROJECT}_data"
  assert_equal "$(stack_left)" "$NETWORK"
  assert_equal "$(jq -r --arg n "$anonymous" '.[] | select(.Name == $n) | .Name' "$DOCKER_STATE/volumes.json")" ""
  # Its record is gone, as after any down.
  [[ ! -e $HOME/.local/state/agent-team/stacks/$PROJECT.json ]]
}

@test "under a heavy run (TEAM_HEAVY_HELD) up and down take no lock: the run holds it" {
  open_task T22
  hold_heavy
  TEAM_HEAVY_HELD=1 run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  assert_equal "$stderr" ""
  TEAM_HEAVY_HELD=1 run_bin -0 --separate-stderr team-stack down --worktree "$STACK_WORKTREE"
  assert_equal "$stderr" ""
  # Every call saw the run's own holder line.
  assert_equal "$(compose_locks | grep -E 'no-start|down' | sed 's/.* | //' | sort -u)" "$HEAVY_LINE"
  assert_equal "$(stack_left)" ""
}

@test "an up of the task's stack whose network a down left makes its stack on that network" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  hold_heavy
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  end_heavy
  run_bin -0 --separate-stderr team-stack up --worktree "$STACK_WORKTREE" --no-seed
  [[ $(jq -r --arg n "/$PROJECT-web-1" '.[] | select(.Name == $n) | .State.Running' "$DOCKER_STATE/containers.json") == true ]]
  assert_equal "$(jq -r --arg n "$NETWORK" '[.[] | select(.Name == $n)] | length' "$DOCKER_STATE/networks.json")" 1
}

@test "sweep removes a team stack's network no container uses once the heavy run ends, logging the line, and leaves it while one runs" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  hold_heavy
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$output" ""
  assert_equal "$stderr" ""
  assert_equal "$(stack_left)" "$NETWORK"
  end_heavy
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$stderr" ""
  [[ $output =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ removed\ network\ $NETWORK\ of\ $PROJECT:\ no\ container\ uses\ it$ ]]
  assert_equal "$(cat "$HOME/.local/state/agent-team/stacks/sweep.log")" "$output"
  assert_equal "$(stack_left)" ""
  assert_contains "$(docker_calls)" "network rm"
  assert_equal "$(jq -c . "$HOME/.local/state/agent-team/stacks/networks-left.json")" "[]"
}

@test "sweep removes only the networks a takedown left: never a team network nobody left, and not one a stack took up again" {
  # A team network of a Compose project no container uses, which no takedown left.
  docker_state networks '. + [{Name: "stackfix-old-1_default", Id: ("d" * 64), Created: "2026-10-24T09:00:00.000000000+00:00",
    Scope: "local", Driver: "bridge", Labels: {"com.docker.compose.network": "default", "com.docker.compose.project": "stackfix-old-1",
      "io.github.chanjdaniel.team.owner": "agent-team", "io.github.chanjdaniel.team.task": "T23", "io.github.chanjdaniel.team.kind": "dev"}}]'
  # With no network left, the sweep asks Docker nothing about networks.
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$output$stderr" ""
  assert_equal "$(docker_calls | grep -c '^network ' || true)" 0
  # The task's stack taken down during a heavy run, then up again on its network.
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  hold_heavy
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  end_heavy
  assert_equal "$(jq -r '.[].name' "$HOME/.local/state/agent-team/stacks/networks-left.json")" "$NETWORK"
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  run_bin -0 --separate-stderr team-stack sweep
  assert_equal "$output$stderr" ""
  assert_equal "$(docker_calls | grep -c '^network rm' || true)" 0
  assert_equal "$(jq -c . "$HOME/.local/state/agent-team/stacks/networks-left.json")" "[]"
  assert_equal "$(jq -r '[.[] | select(.Name == "stackfix-old-1_default" or .Name == $n)] | length' --arg n "$NETWORK" "$DOCKER_STATE/networks.json")" 2
}

@test "a network removal the sweep cannot make is named on stderr, and the sweep exits 1" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  hold_heavy
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  end_heavy
  docker_refuse "$(jq -r --arg n "$NETWORK" '.[] | select(.Name == $n) | .Id' "$DOCKER_STATE/networks.json")" "Error response from daemon: it would not go"
  run_bin -1 --separate-stderr team-stack sweep
  assert_equal "$stderr" "team-stack: could not remove network $NETWORK of $PROJECT: Error response from daemon: it would not go"
  assert_equal "$output" ""
  # It stays on the list for the next sweep.
  assert_equal "$(jq -r '.[].name' "$HOME/.local/state/agent-team/stacks/networks-left.json")" "$NETWORK"
}

@test "reap --apply leaves a team network while a heavy run holds the lock, neither removed nor failed, and removes it after" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  hold_heavy
  run_bin -0 team-stack down --worktree "$STACK_WORKTREE"
  TEAM_STACK_REAP_PROJECTS=$PROJECT run_bin -0 --separate-stderr team-stack reap --apply
  assert_contains "$output" "left network $NETWORK (team): no container uses it; a heavy run holds the heavy-run lock ($HEAVY_LINE), so a later reap --apply removes it once the run ends"
  assert_contains "$output" "team-stack: nothing to remove"
  assert_equal "$(stack_left)" "$NETWORK"
  end_heavy
  TEAM_STACK_REAP_PROJECTS=$PROJECT run_bin -0 team-stack reap --apply
  assert_contains "$output" "removed network $NETWORK (team): no container uses it"
  assert_equal "$(stack_left)" ""
}

@test "the reaper's removal of a team stack while a heavy run holds the lock leaves only its network" {
  open_task T22
  run_bin -0 team-stack up --worktree "$STACK_WORKTREE" --no-seed
  jq -cn '{ts: "2026-11-23T10:00:00Z", task: "T22", event: "closed"}' >>"$TEAM_HOME/ledger.jsonl"
  hold_heavy
  TEAM_STACK_REAP_PROJECTS=$PROJECT run_bin -0 --separate-stderr team-stack reap --apply
  assert_contains "$output" "removed stack $PROJECT (team"
  assert_contains "$stderr" "team-stack: $PROJECT's network $NETWORK is left for team-stack sweep to remove once the heavy-run lock is free"
  assert_equal "$(stack_left)" "$NETWORK"
}
