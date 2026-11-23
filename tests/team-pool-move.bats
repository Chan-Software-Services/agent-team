#!/usr/bin/env bats
# team-pool-move: a treehouse pool moved with its origin, on a pool of real git worktrees whose
# state file and key are built as treehouse 3.1.5 writes them, and a stub treehouse whose status
# reads that state the way treehouse does: an entry whose digest bin/lib/treehouse_state.py
# does not reproduce is listed quarantined under treehouse's recovered holder. The formula itself
# is pinned to a digest real treehouse 3.1.5 wrote.

load helpers/common

recovered="recovered: state file was corrupt or truncated; verify before reuse"

setup() {
  sandbox
  primary=$(make_repo proj)
  old_url=https://github.com/old-owner/proj.git
  new_url=https://github.com/owner/proj.git
  git -C "${primary:?}" remote set-url origin "$old_url"
  old_pool=$HOME/.treehouse/proj-$(printf '%s' "$old_url" | sha256sum | cut -c1-6)
  new_pool=$HOME/.treehouse/proj-$(printf '%s' "$new_url" | sha256sum | cut -c1-6)
  cat >"$TEAM_HOME/projects.toml" <<TOML
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "treehouse"
lease = "scripts/th-lease.sh"
return = "scripts/th-return.sh"
slots = [".treehouse/${old_pool##*/}/1/proj", ".treehouse/${old_pool##*/}/2/proj", ".treehouse/${old_pool##*/}/3/proj"]
TOML
  # Slot 1 leased to T7, a tracked change and an untracked file in it; slot 2 leased to ticket 02
  # of T8, a commit of its own on a branch; slot 3 available.
  local n
  for n in 1 2 3; do git -C "${primary:?}" worktree add -q --detach "$old_pool/$n/proj" main; done
  echo changed >"$old_pool/1/proj/README.md"
  echo "work in progress" >"$old_pool/1/proj/notes.txt"
  git -C "${old_pool:?}/2/proj" switch -q -c feat/T8-02
  git -C "${old_pool:?}/2/proj" commit -q --allow-empty -m "feat: ticket work"
  write_state "$old_pool" "1 T7" "2 T8--02" "3 "
  echo "$REPO_ROOT/bin/lib/treehouse_state.py" >"$BATS_TEST_TMPDIR/state-py"
  echo v3.1.5 >"$BATS_TEST_TMPDIR/version"
  touch "$BATS_TEST_TMPDIR/busy"
  stub_command treehouse
  stub_script treehouse <<'SH'
case $* in
  --version) cat "$BATS_TEST_TMPDIR/version" ;;
  'status --json')
    url=$(git remote get-url origin)
    pools=$HOME/.treehouse
    [[ ! -f $BATS_TEST_TMPDIR/pools ]] || pools=$(cat "$BATS_TEST_TMPDIR/pools")
    pool=$pools/${PWD##*/}-$(printf '%s' "$url" | sha256sum | cut -c1-6)
    [[ -d $pool ]] || { echo '[]'; exit 0; }
    if state=$(python3 -I "$(cat "$BATS_TEST_TMPDIR/state-py")" check "$pool" 2>/dev/null); then
      while IFS=$'\t' read -r name path holder; do
        [[ -n $name ]] || continue
        jq -cn --arg name "$name" --arg path "$path" --arg holder "$holder" --rawfile busy "$BATS_TEST_TMPDIR/busy" \
          '{name: $name, path: $path, status: (if $holder == "" then "available" else "leased" end), lease_holder: $holder,
            processes: (if ($busy | split("\n") | index($name)) then [{pid: 4242}] else [] end)}'
      done <<<"$state" | jq -cs .
    else
      for path in "$pool"/*/proj; do
        n=${path%/proj} n=${n##*/}
        jq -cn --arg name "$n" --arg path "$path" --arg holder "$RECOVERED" \
          '{name: $name, path: $path, status: "leased", lease_holder: $holder, processes: []}'
      done | jq -cs .
    fi
    ;;
  *) echo "treehouse stub: unplanned call: $*" >&2; exit 64 ;;
esac
SH
  export RECOVERED=$recovered
}

# write_state <pool> "<name> <holder>"...: the pool's key and its state, version 4, each entry at
# <pool>/<name>/proj with its digest, leased to <holder> when one is given.
write_state() {
  local pool=$1
  shift
  head -c 32 /dev/urandom >"$pool/treehouse-state.key"
  chmod 600 "$pool/treehouse-state.key"
  python3 -I - "$REPO_ROOT/bin/lib" "$pool" "$@" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import treehouse_state as ts
pool = sys.argv[2]
key = open(f"{pool}/treehouse-state.key", "rb").read()
worktrees = []
for spec in sys.argv[3:]:
    name, _, holder = spec.partition(" ")
    entry = {"name": name, "path": f"{pool}/{name}/proj", "created_at": "2026-11-01T00:00:00Z",
             "seed_backend": "git", "seed_inventory_known": True}
    if holder:
        entry.update(leased=True, lease_id="0" * 32, lease_holder=holder, leased_at="2026-11-15T00:00:00Z")
    entry["seed_inventory_digest"] = ts.digest(key, entry)
    worktrees.append(entry)
json.dump({"version": 4, "worktrees": worktrees}, open(f"{pool}/treehouse-state.json", "w"), indent=2)
PY
}

# pools_at <dir>: the pool moved, with its state, to the pools' root <dir>, which the stub
# treehouse reads its pools from, and old_pool and new_pool named under it.
pools_at() {
  mkdir -p "$(dirname "$1")"
  mv -T "$HOME/.treehouse" "$1"
  old_pool=$1/${old_pool##*/} new_pool=$1/${new_pool##*/}
  git -C "${primary:?}" worktree repair "$old_pool"/*/proj >/dev/null 2>&1
  write_state "$old_pool" "1 T7" "2 T8--02" "3 "
  echo "$1" >"$BATS_TEST_TMPDIR/pools"
}

# The pool's entries as treehouse_state.py check prints them, the pool's path as <pool>.
entries() {
  python3 -I "$REPO_ROOT/bin/lib/treehouse_state.py" check "$1" | sed "s|$1|<pool>|"
}

@test "the digest formula reproduces one real treehouse 3.1.5 wrote" {
  run python3 -I - "$REPO_ROOT/bin/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import treehouse_state as ts
# The pool's treehouse-state.key was written as bytes 0 to 31 before treehouse's first lease.
key = bytes(range(32))
entry = {"name": "1", "path": "/tmp/th-v2/r/.treehouse/proj-cea5ee/1/proj",
         "seeded_paths": [".env"], "seed_backend": "git", "seed_auth_identity": None}
print(ts.digest(key, entry))
PY
  assert_equal "$status $output" "0 74f2aac05d0b2788c0e43a877e4572f26c117757760befa60bcee3422e1a9c4a"
}

@test "the pool moves with the origin, every slot keeping its lease, its holder and its work" {
  chmod 640 "$old_pool/treehouse-state.json"
  run_bin -0 --separate-stderr team-pool-move proj "$new_url"
  assert_equal "$stderr" ""
  assert_equal "$output" "team-pool-move: proj's pool is ~/.treehouse/${new_pool##*/}, its origin $new_url
slot 1 ~/.treehouse/${new_pool##*/}/1/proj leased by T7
slot 2 ~/.treehouse/${new_pool##*/}/2/proj leased by T8--02
slot 3 ~/.treehouse/${new_pool##*/}/3/proj available
next: put proj's pool.slots in projects.toml under ~/.treehouse/${new_pool##*/}/, in a commit of the team home
then: team-open --task T7 --resume proj
then: team-open --task T8 --resume proj --ticket 02"
  [[ ! -e $old_pool && -d $new_pool ]]
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$new_url"
  assert_equal "$(entries "$new_pool")" "1	<pool>/1/proj	T7
2	<pool>/2/proj	T8--02
3	<pool>/3/proj	"
  assert_equal "$(git -C "${new_pool:?}/1/proj" status --porcelain)" " M README.md
?? notes.txt"
  assert_equal "$(git -C "${new_pool:?}/2/proj" log -1 --format='%D %s')" "HEAD -> feat/T8-02 feat: ticket work"
  assert_equal "$(git -C "${primary:?}" worktree list --porcelain | grep -c "^worktree $new_pool/")" 3
  assert_equal "$(stat -c %a "$new_pool/treehouse-state.json") $(stat -c %a "$new_pool/treehouse-state.key")" "640 600"
}

@test "a run again after the move only checks the moved pool" {
  run_bin -0 team-pool-move proj "$new_url"
  local before
  before=$(cat "$new_pool/treehouse-state.json")
  run_bin -0 --separate-stderr team-pool-move proj "$new_url"
  assert_equal "$(sed -n 2p <<<"$output")" "slot 1 ~/.treehouse/${new_pool##*/}/1/proj leased by T7"
  assert_equal "$(cat "$new_pool/treehouse-state.json")" "$before"
}

@test "a run stopped after the rename finishes, the state rewritten, the worktrees repaired and the origin set" {
  mv -T "$old_pool" "$new_pool"
  run_bin -0 team-pool-move proj "$new_url"
  assert_equal "$(entries "$new_pool" | cut -f1,3 | paste -sd ' ')" "1	T7 2	T8--02 3	"
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$new_url"
  assert_equal "$(git -C "${new_pool:?}/1/proj" status --porcelain | wc -l)" 2
}

@test "after a bare rename and set-url, it names the way back, which then finishes the move" {
  mv -T "$old_pool" "$new_pool"
  git -C "${primary:?}" remote set-url origin "$new_url"
  run_bin -1 --separate-stderr team-pool-move proj "$new_url"
  assert_equal "$stderr" "slot 1: $old_pool/1/proj is not under $new_pool
team-pool-move: the state of $new_pool is refused: if a bare rename left it holding the old folder's paths, set the old origin back (git -C $primary remote set-url origin <old url>) and run this again"
  git -C "${primary:?}" remote set-url origin "$old_url"
  run_bin -0 team-pool-move proj "$new_url"
  assert_equal "$(entries "$new_pool" | cut -f1,3 | paste -sd ' ')" "1	T7 2	T8--02 3	"
}

@test "a stored digest the formula does not reproduce is refused, with nothing changed" {
  jq '.worktrees[0].seed_inventory_digest = ("0" * 64)' "$old_pool/treehouse-state.json" >"$BATS_TEST_TMPDIR/state"
  cp "$BATS_TEST_TMPDIR/state" "$old_pool/treehouse-state.json"
  run_bin -1 --separate-stderr team-pool-move proj "$new_url"
  assert_equal "$stderr" "slot 1: its stored digest is not reproduced, so treehouse's state format is not the one this tool knows
team-pool-move: the state of $old_pool is refused: nothing was changed"
  [[ -d $old_pool && ! -e $new_pool ]]
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$old_url"
}

@test "an unknown treehouse version or state version is refused, with nothing changed" {
  echo v3.2.0 >"$BATS_TEST_TMPDIR/version"
  run_bin -1 team-pool-move proj "$new_url"
  assert_equal "$output" "treehouse 3.2.0 is not a version whose state format this tool was checked against (3.1.5): read its internal/pool/state.go, then add it to KNOWN_VERSIONS in bin/lib/treehouse_state.py"
  echo v3.1.5 >"$BATS_TEST_TMPDIR/version"
  jq '.version = 5' "$old_pool/treehouse-state.json" >"$BATS_TEST_TMPDIR/state"
  cp "$BATS_TEST_TMPDIR/state" "$old_pool/treehouse-state.json"
  run_bin -1 --separate-stderr team-pool-move proj "$new_url"
  assert_equal "$(head -n 1 <<<"$stderr")" "$old_pool/treehouse-state.json is not state version 4, the format this tool knows"
  [[ -d $old_pool && ! -e $new_pool ]]
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$old_url"
}

@test "a slot with a process in it is refused, with nothing changed" {
  echo 2 >"$BATS_TEST_TMPDIR/busy"
  run_bin -1 team-pool-move proj "$new_url"
  assert_equal "$output" "team-pool-move: slot 2 ($old_pool/2/proj) has 1 process(es) in it: stow or stop each session in a slot first"
  [[ -d $old_pool && ! -e $new_pool ]]
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$old_url"
}

@test "a pool already at the new name beside the old one is refused" {
  mkdir -p "$new_pool/1"
  run_bin -1 team-pool-move proj "$new_url"
  assert_equal "$output" "team-pool-move: both $old_pool and $new_pool exist: a lease after a bare set-url made the second; return and remove what it holds, then run this again"
  [[ -d $old_pool/1/proj ]]
  assert_equal "$(find "${new_pool:?}" | sed "s|$new_pool|<new>|" | sort | paste -sd ' ')" "<new> <new>/1"
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$old_url"
}

@test "a URL other than the registry repo's, a git pool and a wrong command line are refused" {
  run_bin -1 team-pool-move proj https://github.com/someone/proj.git
  assert_equal "$output" "team-pool-move: https://github.com/someone/proj.git is not https://github.com/owner/proj.git, the URL of proj's repo owner/proj (team-project proj repo, at the end of its moves)"
  sed -i -e 's/provider = "treehouse"/provider = "git"/' -e '/^lease = /d' -e '/^return = /d' -e '/^slots = /d' "$TEAM_HOME/projects.toml"
  run_bin -1 team-pool-move proj "$new_url"
  assert_equal "$output" "team-pool-move: proj's pool is git, not treehouse: only a treehouse pool is named by its origin"
  run_bin -2 team-pool-move proj
  assert_equal "$output" "team-pool-move: usage: team-pool-move <project> <new url>"
  [[ -d $old_pool && ! -e $new_pool ]]
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$old_url"
}

@test "a pool whose state lists no slot moves with the origin" {
  local n
  for n in 1 2 3; do git -C "${primary:?}" worktree remove --force "$old_pool/$n/proj"; done
  write_state "$old_pool"
  run_bin -0 --separate-stderr team-pool-move proj "$new_url"
  assert_equal "$stderr" ""
  assert_equal "$output" "team-pool-move: proj's pool is ~/.treehouse/${new_pool##*/}, its origin $new_url
next: put proj's pool.slots in projects.toml under ~/.treehouse/${new_pool##*/}/, in a commit of the team home"
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$new_url"
}

@test "a slot treehouse already quarantined is refused before the rename, with nothing changed" {
  jq --arg holder "$recovered" '.worktrees[1] |= (.lease_holder = $holder | .seed_inventory_known = false | .seed_inventory_digest = "")' \
    "$old_pool/treehouse-state.json" >"$BATS_TEST_TMPDIR/state"
  cp "$BATS_TEST_TMPDIR/state" "$old_pool/treehouse-state.json"
  run_bin -1 team-pool-move proj "$new_url"
  assert_equal "$output" "team-pool-move: slot 2 ($old_pool/2/proj) is quarantined, leased to treehouse's holder \"$recovered\": check the work in it, then clear it with treehouse return in $primary, and run this again; nothing was changed"
  [[ -d $old_pool && ! -e $new_pool ]]
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$old_url"
}

@test "an entry whose path leaves the pool by .. is refused, before the rename and after it, with nothing changed" {
  jq --arg path "$old_pool/../elsewhere/proj" '.worktrees[0].path = $path' "$old_pool/treehouse-state.json" >"$BATS_TEST_TMPDIR/state"
  cp "$BATS_TEST_TMPDIR/state" "$old_pool/treehouse-state.json"
  run_bin -1 --separate-stderr team-pool-move proj "$new_url"
  assert_equal "$stderr" "slot 1: $old_pool/../elsewhere/proj is not under $old_pool
team-pool-move: the state of $old_pool is refused: nothing was changed"
  [[ -d $old_pool && ! -e $new_pool ]]
  mv -T "$old_pool" "$new_pool"
  jq --arg path "$new_pool/../elsewhere/proj" '.worktrees[0].path = $path' "$new_pool/treehouse-state.json" >"$BATS_TEST_TMPDIR/state"
  cp "$BATS_TEST_TMPDIR/state" "$new_pool/treehouse-state.json"
  run_bin -1 --separate-stderr team-pool-move proj "$new_url"
  assert_equal "$(head -n 1 <<<"$stderr")" "slot 1: $new_pool/../elsewhere/proj is under neither $old_pool nor $new_pool"
  assert_equal "$(cat "$new_pool/treehouse-state.json")" "$(cat "$BATS_TEST_TMPDIR/state")"
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$old_url"
}

@test "a state that cannot be rewritten after the rename names the run again and the way back" {
  touch "$old_pool/treehouse-state.lock"
  chmod 555 "$old_pool"
  run_bin -1 --separate-stderr team-pool-move proj "$new_url"
  chmod 755 "$new_pool"
  assert_equal "$(tail -n 1 <<<"$stderr")" "team-pool-move: the pool is renamed to $new_pool, but its state is not rewritten and the origin is still $old_url: fix the cause above and run team-pool-move proj $new_url again, or put the old pool back with mv -T $new_pool $old_pool"
  [[ ! -e $old_pool ]]
  assert_equal "$(jq -r ".worktrees[0].path" "$new_pool/treehouse-state.json")" "$old_pool/1/proj"
  [[ ! -e $new_pool/treehouse-state.json.team-pool-move ]]
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$old_url"
  run_bin -0 team-pool-move proj "$new_url"
  assert_equal "$(entries "$new_pool" | cut -f1,3 | paste -sd ' ')" "1	T7 2	T8--02 3	"
}

# hold_lock <seconds>: another process holds the old pool's lock for <seconds>, its pid holder,
# returning once it holds it.
hold_lock() {
  python3 -I -c 'import fcntl, sys, time
f = open(sys.argv[1], "a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(float(sys.argv[3]))' "$old_pool/treehouse-state.lock" "$BATS_TEST_TMPDIR/held" "$1" >/dev/null 2>&1 3>&- &
  holder=$!
  for _ in $(seq 50); do [[ ! -e $BATS_TEST_TMPDIR/held ]] || break; sleep 0.1; done
  [[ -e $BATS_TEST_TMPDIR/held ]]
}

@test "the rename waits for the old pool's lock, and refuses with nothing changed when it is not freed" {
  local holder
  hold_lock 60
  TEAM_POOL_LOCK_SECONDS=0 run_bin -1 --separate-stderr team-pool-move proj "$new_url"
  kill "$holder"
  wait "$holder" || true
  assert_equal "$stderr" "$old_pool/treehouse-state.lock is held by another command: let it end, then run this again
team-pool-move: the state of $old_pool is refused: nothing was changed"
  [[ -d $old_pool && ! -e $new_pool ]]
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$old_url"
}

@test "the rename waits for the old pool's lock, and moves the pool once it is freed within the wait" {
  local holder
  hold_lock 1
  TEAM_POOL_LOCK_SECONDS=10 run_bin -0 team-pool-move proj "$new_url"
  wait "$holder"
  [[ ! -e $old_pool && -d $new_pool ]]
  assert_equal "$(entries "$new_pool" | cut -f1,3 | paste -sd ' ')" "1	T7 2	T8--02 3	"
  assert_equal "$(git -C "${primary:?}" remote get-url origin)" "$new_url"
}

@test "the pools' root is found as treehouse finds it: the user config with no treehouse.toml, its variables expanded" {
  export POOL_BASE=$HOME/base
  mkdir -p "$HOME/.config/treehouse"
  # shellcheck disable=SC2016 # treehouse expands it
  echo 'root = "${POOL_BASE}/shared"' >"$HOME/.config/treehouse/config.toml"
  pools_at "$POOL_BASE/shared/.treehouse"
  run_bin -0 team-pool-move proj "$new_url"
  assert_equal "$(sed -n 1p <<<"$output")" "team-pool-move: proj's pool is ~/base/shared/.treehouse/${new_pool##*/}, its origin $new_url"
  [[ ! -e $old_pool && -d $new_pool ]]
}

@test "the pools' root is the checkout's treehouse.toml over the user config, and a symlinked root is kept as written" {
  mkdir -p "$HOME/.config/treehouse" "$HOME/real"
  echo 'root = "/nowhere"' >"$HOME/.config/treehouse/config.toml"
  ln -s "$HOME/real" "$HOME/link"
  echo "root = \"$HOME/link\"" >"$primary/treehouse.toml"
  pools_at "$HOME/link/.treehouse"
  run_bin -0 team-pool-move proj "$new_url"
  assert_equal "$(sed -n 2p <<<"$output")" "slot 1 ~/link/.treehouse/${new_pool##*/}/1/proj leased by T7"
  [[ ! -e $old_pool && -d $HOME/real/.treehouse/${new_pool##*/} ]]
}
