#!/usr/bin/env bats
# bin/lib/temp-files.sh, sourced by the library: team_mktemp's files and directories, made in the
# script's own shell, a $(...) or a background job, and what team_tmp_add names, go when the
# script exits, however it ends (normally, on an error under set -e, by exit, on TERM, HUP or
# INT), with the run's list of them; the script's own exit action, set with team_exit_trap or as
# an EXIT trap before the library, runs as a trap of its own would: $? its exit status, errexit
# on, and an exit in it ending the shell with its status. Each test runs a script that sources
# the library from this checkout, made by script, in the sandbox, whose TMPDIR starts empty.

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
MAKE='file=$(team_mktemp)
dir=$(team_mktemp -d)
: >"$dir/inside"
team_tmp_add "$file.error"
: >"$file.error"'

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

@test "an EXIT trap set before the library is the script's action, and team_exit_trap takes its place or clears it" {
  # Set before the library, as hooks/denial-log sets its own.
  { printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "OUT=$out" "trap 'echo first >\"\$OUT/ran\"' EXIT" \
    "source $REPO_ROOT/bin/lib/team.sh"; echo "$MAKE"; echo false; } >"$BATS_TEST_TMPDIR/s.sh"
  chmod +x "$BATS_TEST_TMPDIR/s.sh"
  run -1 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(<"$out/ran"):$(leftovers)" first:
  script <<EOF
team_exit_trap 'echo first >"\$OUT/ran"'
$MAKE
team_exit_trap 'echo second >"\$OUT/ran"'
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(<"$out/ran"):$(leftovers)" second:
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

@test "files a \$(...) or a background job makes go when the script ends, and a subshell runs only its own action" {
  script <<'EOF'
team_exit_trap 'echo "main $BASHPID" >>"$OUT/acted"'
inner=$(team_mktemp)
( team_mktemp -d >"$OUT/background" ) &
wait "$!"
[[ -e $inner && -d $(<"$OUT/background") ]]
# A subshell's own action runs at its end, its parent's never.
( team_exit_trap 'echo "sub $BASHPID" >>"$OUT/acted"' )
( exit 0 )
[[ -e $inner ]]
echo "main $$" >"$OUT/main"
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(grep -c '^sub ' "$out/acted"):$(grep '^main ' "$out/acted")" "1:$(<"$out/main")"
  assert_equal "$(leftovers)" ""
}

@test "team_tmp_rm removes a path now, and one already moved into place is left alone" {
  script <<'EOF'
a=$(team_mktemp)
b=$(team_mktemp)
c=$(team_mktemp)
team_tmp_rm "$a"
[[ ! -e $a && -e $b ]]
mv "$c" "$OUT/placed"
team_tmp_rm "$c"
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  [[ -f $out/placed ]]
  assert_equal "$(leftovers)" ""
}

@test "a path the exit handler cannot remove is named on stderr, and the script keeps its exit status" {
  for end in true:0 'exit 3:3'; do
    script <<EOF
dir=\$(team_mktemp -d)
inner=\$(team_mktemp "\$dir/inner.XXXXXX")
gone=\$(team_mktemp)
printf '%s\n' "\$dir" "\$inner" >"\$OUT/paths"
chmod 500 "\$dir"
${end%:*}
EOF
    run "$BATS_TEST_TMPDIR/s.sh"
    mapfile -t paths <"$out/paths"
    chmod 700 "${paths[0]}"
    assert_equal "$end:$status:$output" "$end:${end##*:}:s.sh: could not remove ${paths[0]}
s.sh: could not remove ${paths[1]}"
    rm -rf -- "${paths[0]:?}"
    assert_equal "$(leftovers)" ""
  done
}

@test "a script that ends by exec removes its files first with team_tmp_clean" {
  script <<EOF
$MAKE
team_tmp_clean
exec true
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(leftovers)" ""
}

@test "team_mktemp fails as mktemp does" {
  script <<'EOF'
x=$(team_mktemp "$OUT/no-such-dir/t.XXXXXX" 2>/dev/null) || echo "failed '$x'" >"$OUT/said"
EOF
  run -0 "$BATS_TEST_TMPDIR/s.sh"
  assert_equal "$(<"$out/said")" "failed ''"
}
