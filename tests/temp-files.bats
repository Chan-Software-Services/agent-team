#!/usr/bin/env bats
# bin/lib/temp-files.sh, sourced by the library: team_mktemp's files and directories, and what
# team_tmp_add names, go when the shell that made them exits, however it ends (normally, on an
# error under set -e, by exit, on TERM, HUP or INT), and the script's own exit action, set with
# team_exit_trap or as an EXIT trap before the library took it, runs as a trap of its own would:
# $? its exit status, errexit on, and an exit in it ending the shell with its status. A subshell
# has its own files and never removes its parent's. Each test runs a script that sources the
# library from this checkout, made by script, in the sandbox, whose TMPDIR starts empty.

load helpers/common
load helpers/signals

setup() {
  sandbox
  out=$BATS_TEST_TMPDIR/out
  mkdir -p "$out"
}

# A script at $BATS_TEST_TMPDIR/s.sh: set -euo pipefail, the library, then the body read from
# stdin; it writes what it wants a test to see under $OUT: script
script() {
  { printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "OUT=$out" "source $REPO_ROOT/bin/lib/team.sh"; cat; } \
    >"$BATS_TEST_TMPDIR/s.sh"
  chmod +x "$BATS_TEST_TMPDIR/s.sh"
}

# The body's files: a file, a directory with a file in it, and a name built on the file.
MAKE='team_mktemp file
team_mktemp dir -d
: >"$dir/inside"
team_tmp_add "$file.error"
: >"$file.error"
echo "$file $dir" >"$OUT/made"'

@test "a script's files go on a normal exit, an error under set -e and an exit, and its action sees the status" {
  for end in true:0 false:1 'exit 4:4'; do
    script <<EOF
team_exit_trap 'echo "\$?" >"\$OUT/seen"; ls "\$file" "\$dir/inside" >"\$OUT/listed"'
$MAKE
${end%:*}
EOF
    run "$BATS_TEST_TMPDIR/s.sh"
    assert_equal "$end:$status:$(<"$out/seen"):$(leftovers)" "$end:${end##*:}:${end##*:}:"
    # The action could still read them.
    assert_equal "$(wc -l <"$out/listed")" 2
  done
}

@test "an action that exits, dies or fails under errexit ends the script so, and the files still go" {
  for action in 'exit 7:7' 'die no:1' 'false; echo on >"$OUT/on":1'; do
    script <<EOF
team_exit_trap '${action%:*}'
$MAKE
EOF
    run "$BATS_TEST_TMPDIR/s.sh"
    assert_equal "$action:$status:$(leftovers)" "$action:${action##*:}:"
  done
  # errexit ended the action at its failing command, as a trap of its own would end.
  [[ ! -e $out/on ]]
}

@test "TERM, HUP and INT end the script by the signal, its action runs and its files go" {
  for sig in TERM:143 HUP:129 INT:130; do
    rm -f "$out/acted" "$BATS_TEST_TMPDIR/started"
    script <<EOF
team_exit_trap ': >"\$OUT/acted"'
$MAKE
$(stalled "$BATS_TEST_TMPDIR/started")
EOF
    signalled "${sig%:*}" "$BATS_TEST_TMPDIR/started" "$BATS_TEST_TMPDIR/s.sh"
    assert_equal "$sig:$status:$(leftovers)" "$sig:${sig#*:}:"
    [[ -e $out/acted ]]
  done
}

@test "an EXIT trap set before the first file is the script's action, and a later team_exit_trap takes its place" {
  script <<EOF
trap 'echo first >"\$OUT/ran"' EXIT
$MAKE
false
EOF
  run -1 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(<"$out/ran"):$(leftovers)" first:
  script <<EOF
trap 'echo first >"\$OUT/ran"' EXIT
$MAKE
team_exit_trap 'echo second >"\$OUT/ran"'
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(<"$out/ran"):$(leftovers)" second:
  # team_exit_trap - clears the action, and the files still go.
  rm "$out/ran"
  script <<EOF
team_exit_trap 'echo action >"\$OUT/ran"'
$MAKE
team_exit_trap -
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$([[ ! -e $out/ran ]] && echo none):$(leftovers)" none:
}

@test "a guard hook's refusal of its own failure holds with files of its own" {
  script <<EOF
$MAKE
false
EOF
  run --separate-stderr env team_guard=a-guard "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$status:$(leftovers)" 2:
  assert_contains "$stderr" "Blocked by a-guard: it failed with exit 1 before it could decide"
}

@test "a subshell's files go when it ends, it never removes its parent's nor runs its parent's action" {
  script <<'EOF'
team_exit_trap 'echo "$BASHPID" >>"$OUT/acted"'
team_mktemp mine
inner=$(team_exit_trap 'echo "sub $BASHPID" >>"$OUT/sub"'; team_mktemp f; echo "$f"; ls "$mine" >/dev/null)
[[ ! -e $inner && -e $mine ]]
( team_mktemp g; echo "$g" >"$OUT/g" )
[[ ! -e $(<"$OUT/g") && -e $mine ]]
# A subshell that makes none runs neither its parent's action nor its removal.
( exit 0 )
[[ -e $mine ]]
echo "$$" >"$OUT/pid"
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(<"$out/acted")" "$(<"$out/pid")"
  [[ $(<"$out/sub") == "sub "* ]]
  assert_equal "$(leftovers)" ""
}

@test "team_tmp_rm removes a path now and forgets it, so a script that runs on keeps no list of gone files" {
  script <<'EOF'
team_mktemp a
team_mktemp b
team_tmp_rm "$a"
[[ ! -e $a && -e $b ]]
printf '%s\n' "${_team_tmp_paths[@]}" >"$OUT/kept"
echo "$b" >"$OUT/b"
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(<"$out/kept")" "$(<"$out/b")"
  assert_equal "$(leftovers)" ""
}

@test "team_mktemp fails as mktemp does, setting nothing" {
  script <<'EOF'
x=unset
team_mktemp x "$OUT/no-such-dir/t.XXXXXX" 2>/dev/null || echo "failed $x" >"$OUT/said"
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(<"$out/said")" "failed unset"
}
