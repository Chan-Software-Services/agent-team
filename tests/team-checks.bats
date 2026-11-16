#!/usr/bin/env bats
# team-checks: a project's local checks, run in a fresh detached worktree of a head, as team-merge runs them.

load helpers/common

setup() {
  sandbox
  primary=$(make_repo proj dev)
  cat >"$primary/check.sh" <<'SH'
#!/usr/bin/env bash
echo "$PWD $(git rev-parse HEAD) $TMPDIR" >>"$CHECKS_DIR/ran"
echo "checking the head"
[[ -f needed.txt ]] || { echo "needed.txt is missing"; exit 3; }
SH
  chmod +x "$primary/check.sh"
  git -C "${primary:?}" add check.sh
  git -C "${primary:?}" commit -q -m "test: the local check"
  head=$(git -C "${primary:?}" rev-parse HEAD)
  export CHECKS_DIR=$BATS_TEST_TMPDIR/checks
  mkdir -p "$CHECKS_DIR"
  registry '["./check.sh"]'
}

# registry <local_checks as a TOML list, or empty for none>
registry() {
  {
    cat <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "dev"
delivery = "direct-pr"
merge_method = "squash"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []
TOML
    [[ -z $1 ]] || echo "local_checks = $1"
    printf '\n[proj.pool]\nprovider = "git"\nslots = ["slots/proj/1"]\n'
  } >"$TEAM_HOME/projects.toml"
}

# commit_file <file> <message>: commit <file> of proj's primary checkout, and make head that commit.
commit_file() {
  git -C "${primary:?}" add "$1"
  git -C "${primary:?}" commit -q -m "$2"
  head=$(git -C "${primary:?}" rev-parse HEAD)
}

# The worktrees of proj's primary checkout, one path per line.
proj_worktrees() {
  git -C "${primary:?}" worktree list --porcelain | sed -n 's/^worktree //p'
}

@test "--help prints the header" {
  run_bin -0 team-checks --help
  assert_equal "${lines[0]}" "$(sed -n '2s/^# //p' "$REPO_ROOT/bin/team-checks")"
  assert_contains "$output" "Usage: team-checks <project> <head> [--from <checkout>] [--label <text>]"
}

@test "a check that needs an untracked file fails although the calling checkout has it, and its last lines are printed" {
  echo "left by earlier work" >"$primary/needed.txt"
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_contains "$stderr" "team-checks: running ./check.sh on ${head:0:7}"
  assert_contains "$output" "local check './check.sh' failed on the head ${head:0:7} (exit 3); its whole log is "
  assert_contains "$output" "      needed.txt is missing"
  assert_equal "$(proj_worktrees)" "$primary"
}

@test "a passing check exits 0 from a detached worktree of the head, with TMPDIR outside the home directory, and leaves no worktree behind" {
  echo "needed" >"$primary/needed.txt"
  commit_file needed.txt "test: what the check needs"
  # The calling checkout has moved on: the check runs on the head it is given.
  git -C "${primary:?}" commit -q --allow-empty -m "chore: later"
  run_bin -0 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_equal "$output" "local check './check.sh' passed on the head ${head:0:7}"
  local where sha tmp
  read -r where sha tmp <"$CHECKS_DIR/ran"
  assert_equal "$sha" "$head"
  [[ $where != "$primary" && ! -e $where ]]
  [[ $tmp != "$HOME"/* && $tmp != /home/* && $tmp != /Users/* && ! -e $tmp ]]
  assert_equal "$(proj_worktrees)" "$primary"
  assert_equal "$(git -C "${primary:?}" branch --show-current)" dev
}

@test "the checkout defaults to the repository of the current directory, and a head is given in full or short" {
  echo "needed" >"$primary/needed.txt"
  commit_file needed.txt "test: what the check needs"
  mkdir -p "$primary/sub"
  cd "$primary/sub"
  run_bin -0 --separate-stderr team-checks proj "${head:0:12}"
  assert_equal "$output" "local check './check.sh' passed on the head ${head:0:7}"
  assert_equal "$(cut -d' ' -f2 "$CHECKS_DIR/ran")" "$head"
}

@test "every check runs, each one's result printed, and any failure exits 1" {
  registry '["./check.sh", "true", "echo fine && exit 4"]'
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_equal "$(grep -v '^    ' <<<"$output" | sed 's/; its whole log is .*//')" "local check './check.sh' failed on the head ${head:0:7} (exit 3)
local check 'true' passed on the head ${head:0:7}
local check 'echo fine && exit 4' failed on the head ${head:0:7} (exit 4)"
  assert_contains "$output" "      fine"
}

@test "the checks run under the heavy-run lock with the label given, as heavy:checks:<project>, and one that cannot take it exits 75" {
  printf '#!/usr/bin/env bash\n"$HEAVY" status >>"$CHECKS_DIR/heavy"\nsleep 1\n' >"$primary/heavy.sh"
  chmod +x "$primary/heavy.sh"
  commit_file heavy.sh "test: a check that reads the lock"
  registry '["./heavy.sh"]'
  HEAVY=$REPO_ROOT/bin/team-heavy run_bin -0 team-checks proj "$head" --from "$primary" --label "team-merge T14"
  [[ $(cat "$CHECKS_DIR/heavy") =~ ^held\ by\ team-merge\ T14:\ ./heavy.sh\ on\ ${head:0:7}\ \(pid\ [0-9]+\)\ since\  ]]
  # Its cost sample is the project's checks'.
  assert_equal "$(jq -r .kind "$HOME/.local/state/agent-team/capacity/costs.jsonl")" heavy:checks:proj

  mkdir -p "$HOME/.local/state/agent-team"
  exec {held}<>"$HOME/.local/state/agent-team/heavy.lock"
  echo "first (pid 1) since 2026-10-25 10:00:00 +0000" >"$HOME/.local/state/agent-team/heavy.lock"
  flock -x "$held"
  TEAM_HEAVY_WAIT_MINUTES=0 run_bin -75 team-checks proj "$head" --from "$primary"
  assert_contains "$output" "could not run on the head ${head:0:7} yet (exit 75, try again later); its whole log is ~/.cache/agent-team/checks/proj/$head/1-heavy-sh.log"
  assert_contains "$output" "team-heavy: the heavy-run lock is held by first (pid 1) since 2026-10-25 10:00:00 +0000"
  exec {held}<&-
  assert_equal "$(proj_worktrees)" "$primary"
}

@test "the checks get TEAM_JOBS, team-capacity jobs' floor of the level's CPU budget, unless it is set" {
  registry "['echo \"\$TEAM_JOBS\" >>\"\$CHECKS_DIR/jobs\"']"
  # No reading to size the budget by: nproc's, for which the sandbox's TEAM_READING_CPUS stands.
  run_bin -0 team-checks proj "$head" --from "$primary"
  # Minor's 30% of 12 cores.
  capacity_room $((16 * 1073741824)) minor
  TEAM_READING_CPUS=12 run_bin -0 team-checks proj "$head" --from "$primary"
  # One set already is passed on as it is.
  TEAM_JOBS=5 run_bin -0 team-checks proj "$head" --from "$primary"
  assert_equal "$(cat "$CHECKS_DIR/jobs")" "$TEAM_READING_CPUS
3
5"
}

@test "a project with no local checks exits 0 and makes no worktree" {
  registry ''
  run_bin -0 team-checks proj "$head" --from "$primary"
  assert_equal "$output" "team-checks: proj has no local checks"
  [[ ! -e $CHECKS_DIR/ran ]]
  assert_equal "$(proj_worktrees)" "$primary"
}

@test "a head that is not a commit in the checkout, or a checkout that is not a repository, is refused" {
  run_bin -1 team-checks proj 5555555555555555555555555555555555555555 --from "$primary"
  assert_contains "$output" "team-checks: 5555555555555555555555555555555555555555 is not a commit in $primary"
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run_bin -1 team-checks proj "$head" --from "$BATS_TEST_TMPDIR/plain"
  assert_contains "$output" "team-checks: $BATS_TEST_TMPDIR/plain is not a git checkout"
  run_bin -1 team-checks nosuch "$head" --from "$primary"
  [[ ! -e $CHECKS_DIR/ran ]]
}

@test "a malformed command line is a usage error" {
  run_bin -2 team-checks
  assert_contains "$output" "usage: team-checks <project> <head> [--from <checkout>] [--label <text>]"
  run_bin -2 team-checks proj
  run_bin -2 team-checks proj "$head" extra
  run_bin -2 team-checks proj "$head" --from
  run_bin -2 team-checks proj "$head" --label
  run_bin -2 team-checks proj "$head" --bogus
}

# go_check <exit>: commit go.sh, a check shaped like go test -race ./...: a failing test and its
# package, then 30 passing packages and a bare FAIL, with the exit given; the log it prints is in
# $CHECKS_DIR/go.log.
go_check() {
  cat >"$primary/go.sh" <<'SH'
#!/usr/bin/env bash
{
  for n in 1 2 3; do printf 'ok  \tproj/early%s\t0.01s\n' "$n"; done
  echo "--- FAIL: TestKept (0.00s)"
  echo "    kept_test.go:12: the log was removed"
  printf 'FAIL\tproj/kept\t0.02s\n'
  for n in $(seq 30); do printf 'ok  \tproj/late%s\t0.01s\n' "$n"; done
  echo FAIL
} | tee "$CHECKS_DIR/go.log"
SH
  echo "exit $1" >>"$primary/go.sh"
  chmod +x "$primary/go.sh"
  commit_file go.sh "test: a check shaped like go test"
  registry '["./go.sh"]'
}

# Without team-heavy's own notes, which a check's log holds beside the check's lines and differ by machine.
check_lines() {
  grep -v '^ *team-heavy: ' || true
}

# kept_log <output>: the path of the whole log a failed check's result names, ~ expanded.
kept_log() {
  local path
  path=$(sed -n 's/^local check .*; its whole log is //p' <<<"$1")
  echo "${path/#\~/$HOME}"
}

@test "a failed check names its failure lines above its last 20, and keeps its whole log where its result says" {
  go_check 1
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_equal "$(grep -v '^      ' <<<"$output")" "local check './go.sh' failed on the head ${head:0:7} (exit 1); its whole log is ~/.cache/agent-team/checks/proj/$head/1-go-sh.log
    its earlier lines that name a failure:
    its last lines:"
  assert_contains "$output" "      --- FAIL: TestKept (0.00s)
      FAIL	proj/kept	0.02s
    its last lines:
      ok  	proj/late1"
  # The last lines are named once, as the tail.
  assert_equal "$(grep -c '^      FAIL$' <<<"$output")" 1
  cmp <(check_lines <"$(kept_log "$output")") "$CHECKS_DIR/go.log"
}

@test "a check with no failure line above its last 20 prints its last lines alone, under its log's path" {
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_equal "$(check_lines <<<"$output")" "local check './check.sh' failed on the head ${head:0:7} (exit 3); its whole log is ~/.cache/agent-team/checks/proj/$head/1-check-sh.log
    its last lines:
      checking the head
      needed.txt is missing"
  assert_equal "$(check_lines <"$(kept_log "$output")")" "checking the head
needed.txt is missing"
}

@test "the failure lines named are capped at 20, each cut at 300 characters, with how many there were" {
  cat >"$primary/many.sh" <<'SH'
#!/usr/bin/env bash
for n in $(seq 45); do echo "not ok $n it holds"; done
printf 'panic: %0400d\n' 7
echo "WARNING: DATA RACE"
for n in $(seq 25); do echo "ok $n"; done
exit 1
SH
  chmod +x "$primary/many.sh"
  commit_file many.sh "test: a check that floods"
  registry '["./many.sh"]'
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_contains "$output" "    the first 20 of its 47 earlier lines that name a failure:
      not ok 1 it holds"
  assert_equal "$(grep -c '^      not ok ' <<<"$output")" 20
  assert_equal "$(check_lines <"$(kept_log "$output")" | grep -c .)" 72

  # A long line is cut, and a race is named.
  printf '#!/usr/bin/env bash\nprintf "panic: %%0400d\\n" 7\necho "WARNING: DATA RACE"\nseq 25\nexit 1\n' >"$primary/many.sh"
  commit_file many.sh "test: a long line"
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_contains "$output" "      WARNING: DATA RACE"
  assert_equal "$(grep '^      panic: ' <<<"$output" | awk '{ print length($0) }')" 306
}

@test "each check of a head keeps a log of its own, the next run of it overwrites it, and one that passes keeps none" {
  cat >"$primary/flip.sh" <<'SH'
#!/usr/bin/env bash
cat "$CHECKS_DIR/says"
[[ ! -e $CHECKS_DIR/fails ]]
SH
  chmod +x "$primary/flip.sh"
  commit_file flip.sh "test: a check that flips"
  registry '["./flip.sh", "./flip.sh && exit 4"]'
  local kept=$HOME/.cache/agent-team/checks/proj/$head
  echo first >"$CHECKS_DIR/says"
  touch "$CHECKS_DIR/fails"
  run_bin -1 team-checks proj "$head" --from "$primary"
  assert_equal "$(cd "$kept" && echo *)" "1-flip-sh.log 2-flip-sh-exit-4.log"
  echo second >"$CHECKS_DIR/says"
  run_bin -1 team-checks proj "$head" --from "$primary"
  assert_equal "$(check_lines <"$kept/1-flip-sh.log")" second
  # Only its owner reads a kept log.
  assert_equal "$(stat -c %a "$kept/1-flip-sh.log" "$kept")" "600
700"
  rm "$CHECKS_DIR/fails"
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_equal "$(head -n 1 <<<"$output")" "local check './flip.sh' passed on the head ${head:0:7}"
  assert_equal "$(cd "$kept" && echo *)" "2-flip-sh-exit-4.log"
}

@test "a run removes the project's kept logs older than 30 days, and leaves the newer and another project's" {
  local root=$HOME/.cache/agent-team/checks
  mkdir -p "$root/proj/old" "$root/proj/new" "$root/other/old"
  touch -d '31 days ago' "$root/proj/old/1-check.log" "$root/other/old/1-check.log"
  touch -d '29 days ago' "$root/proj/new/1-check.log"
  echo "needed" >"$primary/needed.txt"
  commit_file needed.txt "test: what the check needs"
  run_bin -0 team-checks proj "$head" --from "$primary"
  assert_equal "$(cd "$root" && find . -type f -o -type d -empty | sort)" "./other/old/1-check.log
./proj/new/1-check.log"
}

@test "a log that cannot be kept is said, and the check's result and last lines still print" {
  mkdir -p "$HOME/.cache/agent-team"
  echo "a file" >"$HOME/.cache/agent-team/checks"
  run_bin -1 --separate-stderr team-checks proj "$head" --from "$primary"
  assert_equal "$(check_lines <<<"$output")" "local check './check.sh' failed on the head ${head:0:7} (exit 3); its whole log could not be kept at ~/.cache/agent-team/checks/proj/$head/1-check-sh.log
    its last lines:
      checking the head
      needed.txt is missing"
}

@test "a passing check whose kept log cannot be removed still passes, and the checks after it run" {
  cat >"$primary/flip.sh" <<'SH'
#!/usr/bin/env bash
[[ ! -e $CHECKS_DIR/fails ]]
SH
  chmod +x "$primary/flip.sh"
  commit_file flip.sh "test: a check that flips"
  registry '["./flip.sh", "echo after"]'
  local kept=$HOME/.cache/agent-team/checks/proj/$head
  touch "$CHECKS_DIR/fails"
  run_bin -1 team-checks proj "$head" --from "$primary"
  [[ -f $kept/1-flip-sh.log ]]
  rm "$CHECKS_DIR/fails"
  chmod 500 "$kept"
  run_bin --separate-stderr team-checks proj "$head" --from "$primary"
  chmod 700 "$kept"
  assert_equal "$status" 0
  assert_equal "$output" "local check './flip.sh' passed on the head ${head:0:7}
local check 'echo after' passed on the head ${head:0:7}"
}

# A check that leaves a read-only tree in its TMPDIR, as go's module cache is: the next check's
# fresh TMPDIR and the scratch's removal at the end both take it.
@test "a check that leaves a read-only tree in its TMPDIR leaves no scratch behind, passed or failed, nor a worktree" {
  local tree='mkdir -p "$TMPDIR/mod/cache" && echo x >"$TMPDIR/mod/cache/f" && chmod -R a-w "$TMPDIR/mod"' left
  local expected
  for expected in 0 1; do
    if ((expected == 0)); then
      registry "['$tree', '$tree']"
    else
      registry "['$tree', '$tree && exit 4']"
    fi
    run_bin --separate-stderr team-checks proj "$head" --from "$primary"
    left=$(find "$TMPDIR" -maxdepth 1 -name 'team-checks.*')
    find "$TMPDIR" -maxdepth 1 -name 'team-checks.*' -exec chmod -R u+w {} +
    assert_equal "$status" "$expected"
    assert_equal "$left" ""
    assert_equal "$(grep -c ' passed on the head ' <<<"$output")" $((2 - expected))
    assert_equal "$(proj_worktrees)" "$primary"
  done
}
