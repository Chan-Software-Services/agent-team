#!/usr/bin/env bats
# tests/run bats --clock-ahead <days> --touched <base>, the run CI's future-clock job makes: a
# fixture test comparing a date 30 days ahead with date +%s passes today and fails a year ahead, a
# test tagged wall-clock is not run there and is named, a jq whose now the shim does not move is
# refused, a change touching no bats file says so and passes, a changed fixture selects the bats files naming it (directly, by a directory, through a
# helper), the empty tree selects every file, and macOS, a missing cc and a malformed command line
# are refused. Each runs in a checkout of its own, with this checkout's bin/, tests/run,
# tests/shards and shim, and the vendored bats. The cases that build the shim need Linux and cc,
# and skip without them unless CLOCK_TESTS=require, which CI's future-clock job sets.

load helpers/common

setup() {
  sandbox
  unset TEAM_HOME
  export TEAM_JOBS=2
}

# Skips the test where the shim cannot be built (no Linux or no cc), unless CLOCK_TESTS=require.
needs_shim() {
  if [[ $(uname -s) == Linux ]] && command -v cc >/dev/null; then return 0; fi
  if [[ ${CLOCK_TESTS:-} == require ]]; then
    echo "CLOCK_TESTS=require, and this machine cannot build the shim: $(uname -s), cc $(command -v cc || echo missing)" >&2
    return 1
  fi
  skip "the clock shim needs Linux and cc"
}

# A checkout of its own at <copy>, committed and tagged base: this checkout's bin/, tests/run,
# tests/shards and tests/helpers/clockshift.c, the vendored bats by a link, a tests/later.bats
# whose one test compares a date 30 days ahead (written into the file) with date +%s, a
# tests/other.bats that passes on any date, and a fixture tests/fixtures/dates/due.json.
clock_checkout() {
  local copy=$1 due
  mkdir -p "$copy/tests/helpers" "$copy/tests/fixtures/dates"
  copy_bin "$copy/bin"
  link_shared tests-run "$REPO_ROOT/tests/run" "$copy/tests/run"
  link_shared tests-shards "$REPO_ROOT/tests/shards" "$copy/tests/shards"
  cp "$REPO_ROOT/tests/helpers/clockshift.c" "$copy/tests/helpers/clockshift.c"
  ln -s "$REPO_ROOT/tests/vendor" "$copy/tests/vendor"
  due=$(($(date +%s) + 30 * 86400))
  printf '@test "a date 30 days ahead is still to come" {\n  (($(date +%%s) < %d))\n}\n' "$due" >"$copy/tests/later.bats"
  printf '@test "any date" {\n  true\n}\n' >"$copy/tests/other.bats"
  echo '{"due": "in 30 days"}' >"$copy/tests/fixtures/dates/due.json"
  git -C "${copy:?}" init -q
  git -C "${copy:?}" add -A
  git -C "${copy:?}" commit -qm base
  git -C "${copy:?}" tag base
}

# A directory of links to every command on PATH but <names>, the first of each name as PATH finds
# it, printed, for a PATH with none of them (the machine's own cc is under /usr/bin).
path_without() {
  local links=$BATS_TEST_TMPDIR/path-without dir file name targets=()
  local -A seen=()
  for name; do seen[$name]=1; done
  mkdir -p "$links"
  local IFS=:
  for dir in $PATH; do
    [[ -d $dir ]] || continue
    for file in "$dir"/*; do
      name=${file##*/}
      [[ -z ${seen[$name]:-} && -x $file && ! -d $file ]] || continue
      seen[$name]=1
      targets+=("$file")
    done
  done
  ln -s -t "$links" -- "${targets[@]}"
  echo "$links"
}

# The usage line tests/run prints on a malformed command line.
clock_usage="run: usage: tests/run [shellcheck [--changed [<base>] [--list]]|bats [--shard <k>/<n> [--list]|--changed [<base>] [--list]|--clock-ahead <days> --touched <base> [--list]]|toolkits|rust [--changed [<base>] [--list]]]"

@test "a test comparing a date 30 days ahead with the clock passes with no shift and fails a year ahead" {
  needs_shim
  local copy=$BATS_TEST_TMPDIR/copy
  clock_checkout "$copy"
  run -0 "$REPO_ROOT/tests/vendor/bats-core/bin/bats" "$copy/tests/later.bats"
  echo '# touched' >>"$copy/tests/later.bats"
  run -1 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base
  assert_equal "$(head -n 2 <<<"$output")" $'clock-ahead 365 days: 1 of 2 files touched since base\n  tests/later.bats'
  assert_contains "$output" "not ok tests/later.bats ("
  assert_contains "$output" "not ok 1 a date 30 days ahead is still to come"
  assert_contains "$output" "bats: 0 tests passed; 1 of 1 files failed"
  # Twenty days ahead, the date is still to come.
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 20 --touched base
  assert_contains "$output" "bats: 1 tests passed; 0 of 1 files failed"
  # Its directory, the shim's build among it, is gone once it exits.
  assert_equal "$(ls -A "$TMPDIR")" ""
}

@test "a test tagged wall-clock is not run a year ahead, and is named after the file lines" {
  needs_shim
  local copy=$BATS_TEST_TMPDIR/copy
  clock_checkout "$copy"
  # Written by printf, since bats rewrites a line of the test file that begins with @test.
  printf '%s\n' '' '# bats test_tags=wall-clock' '@test "a file written now is new" {' \
    '  touch "$BATS_TEST_TMPDIR/new"' '  (($(date +%s) - $(stat -c %Y "$BATS_TEST_TMPDIR/new") < 60))' '}' '' \
    '# bats test_tags=slow, wall-clock' '@test "a tag among others" {' '  false' '}' >>"$copy/tests/other.bats"
  # Today the file-time test passes, and the last fails on any day.
  run -1 "$REPO_ROOT/tests/vendor/bats-core/bin/bats" "$copy/tests/other.bats"
  assert_contains "$output" "ok 2 a file written now is new"
  assert_contains "$output" "not ok 3 a tag among others"
  # A year ahead, only the untagged test runs, and the tagged ones are named.
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base
  assert_contains "$output" "ok tests/other.bats ("
  assert_contains "$output" "bats: 1 tests passed; 0 of 1 files failed"
  assert_equal "$(grep -F '# not run' <<<"$output")" \
    $'tests/other.bats: a file written now is new # not run: tagged wall-clock\ntests/other.bats: a tag among others # not run: tagged wall-clock'
}

# A static jq, as the jq release binary is, never loads the shim, so its now reads the real clock
# beside date's moved one, and every test mixing the two would fail on that alone.
@test "a jq whose now the shim does not move is refused, naming it, before any file runs" {
  needs_shim
  local copy=$BATS_TEST_TMPDIR/copy real_jq
  clock_checkout "$copy"
  echo '# touched' >>"$copy/tests/later.bats"
  real_jq=$(command -v jq)
  stub_command jq
  stub_script jq <<SH
if [[ \$* == "-n now | floor" ]]; then echo 1000; exit; fi
exec "$real_jq" "\$@"
SH
  run -1 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base
  assert_contains "$output" "clock-ahead: jq's now read 1000 under tests/helpers/clockshift.c, not 365 days past "
  assert_contains "$output" ": $BATS_TEST_TMPDIR/stubs/jq is a static binary or loads no shim, so a test reading its now beside date's would fail on the two clocks alone; put a dynamically linked jq first on PATH"
  [[ $output != *"tests passed"* ]]
}

@test "a change touching no bats file says so and passes, and --list prints nothing" {
  needs_shim
  local copy=$BATS_TEST_TMPDIR/copy
  clock_checkout "$copy"
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base
  assert_equal "$(head -n 1 <<<"$output")" "clock-ahead: no bats file touched since base"
  # A change to other files, a fixture no bats file names among them, touches none.
  echo '# the readme' >"$copy/README.md"
  echo '{}' >"$copy/tests/fixtures/unnamed.json"
  git -C "${copy:?}" add -A
  git -C "${copy:?}" commit -qm 'change no bats file'
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base
  assert_equal "$(head -n 1 <<<"$output")" "clock-ahead: no bats file touched since base"
  [[ $output != *"tests passed"* ]]
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base --list
  assert_equal "$output" ""
}

@test "the files touched are those committed since the base's merge base, changed in the working tree or untracked" {
  local copy=$BATS_TEST_TMPDIR/copy
  clock_checkout "$copy"
  git -C "${copy:?}" switch -qc work
  echo '# committed' >>"$copy/tests/other.bats"
  git -C "${copy:?}" commit -qam 'change other.bats'
  # A commit on the base's side after the branch point touches nothing here.
  git -C "${copy:?}" switch -q --detach base
  echo '@test "on dev" { true; }' >"$copy/tests/dev-only.bats"
  git -C "${copy:?}" add tests/dev-only.bats
  git -C "${copy:?}" commit -qm 'dev moves on'
  git -C "${copy:?}" tag -f base >/dev/null
  git -C "${copy:?}" switch -q work
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base --list
  assert_equal "$output" tests/other.bats
  echo '# in the working tree' >>"$copy/tests/later.bats"
  echo '@test "new" { true; }' >"$copy/tests/new.bats"
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base --list
  assert_equal "$output" $'tests/later.bats\ntests/new.bats\ntests/other.bats'
  # A deleted bats file is not run.
  git -C "${copy:?}" rm -q tests/other.bats
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base --list
  assert_equal "$output" $'tests/later.bats\ntests/new.bats'
}

@test "a changed fixture selects the bats files naming it, one of its directories, or a helper that does" {
  local copy=$BATS_TEST_TMPDIR/copy
  clock_checkout "$copy"
  echo '@test "reads it" { cat "$BATS_TEST_DIRNAME/fixtures/dates/due.json"; }' >"$copy/tests/by-file.bats"
  echo '@test "copies the directory" { cp -R "$BATS_TEST_DIRNAME/fixtures/dates" "$BATS_TEST_TMPDIR"; }' >"$copy/tests/by-dir.bats"
  echo '@test "globs it" { ls "$BATS_TEST_DIRNAME"/fixtures/dates/*.json; }' >"$copy/tests/by-glob.bats"
  printf 'load helpers/dates\n@test "through the helper" { true; }\n' >"$copy/tests/by-helper.bats"
  echo 'dates() { cat "$REPO_ROOT/tests/fixtures/dates/due.json"; }' >"$copy/tests/helpers/dates.bash"
  # A name that only begins like the fixture's directory, or another fixture, selects nothing.
  echo '@test "another" { cat "$BATS_TEST_DIRNAME/fixtures/dates-old/due.json" "$BATS_TEST_DIRNAME/fixtures/due.json"; }' >"$copy/tests/unrelated.bats"
  git -C "${copy:?}" add -A
  git -C "${copy:?}" commit -qm fixtures
  git -C "${copy:?}" tag -f base >/dev/null
  echo '{"due": "tomorrow"}' >"$copy/tests/fixtures/dates/due.json"
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base --list
  assert_equal "$output" $'tests/by-dir.bats\ntests/by-file.bats\ntests/by-glob.bats\ntests/by-helper.bats'
}

@test "the empty tree as the base touches every bats file" {
  local copy=$BATS_TEST_TMPDIR/copy empty
  clock_checkout "$copy"
  empty=$(git -C "${copy:?}" hash-object -t tree /dev/null)
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched "$empty" --list
  assert_equal "$output" $'tests/later.bats\ntests/other.bats'
}

@test "macOS, any other system but Linux, and a missing cc are refused with their reasons, before any file runs" {
  local copy=$BATS_TEST_TMPDIR/copy stubs
  clock_checkout "$copy"
  echo '# touched' >>"$copy/tests/later.bats"
  as_macos
  run -1 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base
  assert_equal "$stderr" "run: --clock-ahead runs only on Linux: macOS has no LD_PRELOAD to load tests/helpers/clockshift.c into every process"
  # --list runs nothing, so it lists on macOS too.
  run -0 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base --list
  assert_equal "$output" tests/later.bats
  stub_reply uname FreeBSD
  run -1 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base
  assert_equal "$stderr" "run: --clock-ahead runs only on Linux, whose LD_PRELOAD loads tests/helpers/clockshift.c into every process, not on FreeBSD"
  stub_reply uname Linux
  unset HOMEBREW_PREFIX
  stubs=$(path_without cc)
  PATH=$stubs run -1 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched base
  assert_equal "$stderr" "run: --clock-ahead builds tests/helpers/clockshift.c with cc, and no cc is on PATH: install a C compiler"
}

@test "a malformed --clock-ahead command line is a usage error, and a base that is no commit or tree is named" {
  local copy=$BATS_TEST_TMPDIR/copy args
  clock_checkout "$copy"
  for args in '--clock-ahead' '--clock-ahead 365' '--clock-ahead 0 --touched base' '--clock-ahead 365x --touched base' \
    '--clock-ahead 100000 --touched base' '--clock-ahead 365 --base base' '--clock-ahead 365 --touched' \
    '--clock-ahead 365 --touched base --list x' '--clock-ahead 365 --touched base --shard 1/3'; do
    # shellcheck disable=SC2086 # each case's words
    run -2 --separate-stderr "$copy/tests/run" bats $args
    assert_equal "$stderr" "$clock_usage"
  done
  run -2 --separate-stderr "$copy/tests/run" bats --clock-ahead 365 --touched nothing-here
  assert_equal "$stderr" "run: --touched: no commit or tree nothing-here; ${clock_usage#run: }"
}
