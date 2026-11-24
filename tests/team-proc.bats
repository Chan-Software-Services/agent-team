#!/usr/bin/env bats
# team-proc: a process's io, cgroup, status, stat and smaps_rollup, and nothing else of it, for the
# coordinator and the assistant; every other name and path shape is refused before anything is
# read, /proc/<pid>/task/<tid>/ too, and so is a link and a worker session. A fake /proc
# (TEAM_PROC) holds a process whose environ and cmdline carry a secret no output may show, and
# the machine's own /proc proves the real files read.

load helpers/common

SECRET=fixture-secret-value

setup() {
  sandbox
  export TEAM_PROC=$BATS_TEST_TMPDIR/proc
  local dir name
  for dir in "$TEAM_PROC/4242" "$TEAM_PROC/4242/task/4243"; do
    mkdir -p "$dir/fd"
    for name in io cgroup status stat smaps_rollup; do
      printf '%s of %s\nline 2\n' "$name" "${dir#"$TEAM_PROC"/}" >"$dir/$name"
    done
    for name in environ cmdline mem maps; do echo "$SECRET" >"$dir/$name"; done
    echo "$SECRET" >"$dir/fd/0"
    ln -s "$BATS_TEST_TMPDIR" "$dir/cwd"
    ln -s / "$dir/root"
    ln -s /bin/sh "$dir/exe"
  done
}

# <text> does not hold <part>: refute_contains <text> <part>
refute_contains() {
  [[ $1 != *"$2"* ]] || { printf 'holds %s:\n%s\n' "$2" "$1" >&2; return 1; }
}

# The five counters of <dir> as team-proc prints them, or those named: printed <dir> [<counter>...]
printed() {
  local dir=$1 name
  shift
  (($#)) || set -- io cgroup status stat smaps_rollup
  for name; do printf '== /proc/%s/%s\n%s of %s\nline 2\n' "$dir" "$name" "$name" "$dir"; done
}

@test "it prints each counter of a process or a thread, all five or those named, and never its secrets" {
  run_bin -0 --separate-stderr team-proc 4242
  assert_equal "$output" "$(printed 4242)"
  assert_equal "$stderr" ""
  run_bin -0 team-proc /proc/4242/
  assert_equal "$output" "$(printed 4242)"
  run_bin -0 team-proc 4242 io smaps_rollup
  assert_equal "$output" "$(printed 4242 io smaps_rollup)"
  run_bin -0 team-proc /proc/4242/cgroup
  assert_equal "$output" "$(printed 4242 cgroup)"
  run_bin -0 team-proc 4242/task/4243
  assert_equal "$output" "$(printed 4242/task/4243)"
  run_bin -0 team-proc /proc/4242/task/4243/status
  assert_equal "$output" "$(printed 4242/task/4243 status)"
  run_bin -0 team-proc /proc/4242/task/4243 stat io
  assert_equal "$output" "$(printed 4242/task/4243 stat io)"
}

@test "every other name and path shape is refused before anything is read, a thread's too" {
  local name target
  for name in environ cmdline mem maps fd cwd root exe auxv pagemap task; do
    for target in "/proc/4242/$name" "4242/$name" "/proc/4242/task/4243/$name"; do
      run_bin -1 team-proc "$target"
      assert_equal "$output" "team-proc: team-proc prints only io cgroup status stat smaps_rollup; '$name' is none of them (a process's environ, cmdline, memory, maps, files and links may hold a secret)"
    done
    run_bin -1 team-proc 4242 io "$name"
    refute_contains "$output" "$SECRET"
    refute_contains "$output" "== /proc"
  done
  for target in /proc/self/io /proc/thread-self/io self /proc/4242/../4242/io /proc/4242/task/4243/fd/0 \
    4242/root/etc/passwd /proc//4242/io /proc/4242/./io ./4242 -1 x/4242 "4242/task/4243/task/4244" \
    /sys/4242/io /proc/4242/io/x; do
    run_bin -1 team-proc "$target"
    assert_equal "$output" "team-proc: team-proc reads /proc/<pid> or /proc/<pid>/task/<tid>, of digits, or one counter there; got '$target'"
  done
  run_bin -2 team-proc /proc/4242/io stat
  assert_contains "$output" "the path names its counter, io, so no other is taken"
  run_bin -2 team-proc
  assert_contains "$output" "usage: team-proc"
}

@test "a counter that is a link, or a process directory that is one, is read as unreadable" {
  ln -sf environ "$TEAM_PROC/4242/io"
  ln -s 4242 "$TEAM_PROC/4244"
  run_bin -1 --separate-stderr team-proc 4242 io status
  assert_equal "$stderr" "team-proc: cannot read /proc/4242/io"
  assert_equal "$output" "$(printed 4242 status)"
  run_bin -1 --separate-stderr team-proc 4244
  refute_contains "$output$stderr" "$SECRET"
  assert_contains "$stderr" "team-proc: cannot read /proc/4244/status"
  # A /proc that is itself a link is read where it leads.
  ln -s "$TEAM_PROC" "$BATS_TEST_TMPDIR/proc-link"
  TEAM_PROC=$BATS_TEST_TMPDIR/proc-link run_bin -0 team-proc /proc/4242/stat
  assert_equal "$output" "$(printed 4242 stat)"
  # A process that ended, and a machine with no /proc.
  run_bin -1 --separate-stderr team-proc 4250 io
  assert_equal "$output:$stderr" ":team-proc: cannot read /proc/4250/io"
  TEAM_PROC=$BATS_TEST_TMPDIR/none run_bin -1 team-proc 4242
  assert_equal "$output" "team-proc: this machine has no $BATS_TEST_TMPDIR/none"
}

@test "a worker session is refused; the coordinator, the assistant and a session with no role read" {
  local role
  for role in builder planner reviewer ops topic; do
    AGENT_TEAM_ROLE=$role run_bin -1 team-proc 4242
    assert_equal "$output" "team-proc: a $role session runs no team-proc: it is the coordinator's and the assistant's, and a worker's deny rules keep /proc"
  done
  for role in coordinator assistant ""; do
    AGENT_TEAM_ROLE=$role run_bin -0 team-proc 4242 io
    assert_equal "$output" "$(printed 4242 io)"
  done
}

@test "on a machine with /proc it prints the test shell's own counters" {
  [[ -r /proc/$$/io ]] || skip "this machine has no readable /proc"
  unset TEAM_PROC
  run_bin -0 team-proc "$$"
  assert_contains "$output" "== /proc/$$/io"$'\n'"rchar:"
  assert_contains "$output" "== /proc/$$/cgroup"
  assert_contains "$output" "== /proc/$$/status"$'\n'"Name:"
  assert_contains "$output" "== /proc/$$/smaps_rollup"
  refute_contains "$output" "== /proc/$$/environ"
}
