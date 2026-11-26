#!/usr/bin/env bats
# tests/run rust, the Rust part of the code's checks: its six steps in order with their flags,
# the stop at a failing step, the missing tool's line, the jobs and compiler wrapper it sets, that
# it takes no heavy-run lock, its --changed and --list forms, and plain tests/run running all four
# parts. Every Rust tool is a logging stub in a checkout of its own; tests/run rust itself runs the
# real ones on the repository, on a builder's machine.

load helpers/common

# Every test runs cargo at 2 jobs but the one that unsets it.
setup() {
  sandbox
  export TEAM_JOBS=2
}

# link_script <name> <dest>: <dest> a hard link to the run's shared executable <name>, made the
# first time from stdin, so no test writes an executable of its own, as CLAUDE.md's tests section
# says; ln -f replaces a link already there, never writing into the shared file.
link_script() {
  shared_make "tests-run-rust/$1"
  ln -f "$BATS_RUN_TMPDIR/shared/tests-run-rust/$1" "$2"
}

# A checkout of its own at <copy>, committed and tagged base: this checkout's bin/ and tests/run,
# with a bin/team-heavy that logs to $STUB_CALLS/team-heavy and refuses, so a part that takes the
# lock shows, and a bin/team-capacity whose jobs is 7. The Rust tools are stubs: cargo and
# cargo-deny log each call, and the jobs and wrapper each step sees, to $STUB_CALLS/rust-env;
# cargo-deny refuses the fixture's crate as the real one does (exit 4, naming it and its license)
# when run --offline, and passes otherwise.
rust_checkout() {
  local copy=$1
  mkdir -p "$copy/tests" "$copy/crates/team-core/src"
  copy_bin "$copy/bin"
  link_shared tests-run "$REPO_ROOT/tests/run" "$copy/tests/run"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >>"$STUB_CALLS/team-heavy"' 'exit 1' |
    link_script team-heavy-refusing "$copy/bin/team-heavy"
  printf '%s\n' '#!/usr/bin/env bash' '[[ $1 == jobs ]] && echo 7' | link_script team-capacity "$copy/bin/team-capacity"
  echo '# the readme' >"$copy/README.md"
  echo 'pub fn version() {}' >"$copy/crates/team-core/src/lib.rs"
  git -C "${copy:?}" init -q
  git -C "${copy:?}" add -A
  git -C "${copy:?}" commit -qm base
  git -C "${copy:?}" tag base
  stub_command cargo cargo-nextest cargo-deny
  local env_line='echo "${0##*/} $1 jobs=${CARGO_BUILD_JOBS-unset} threads=${NEXTEST_TEST_THREADS-unset} wrapper=${RUSTC_WRAPPER-unset}" >>"$STUB_CALLS/rust-env"'
  echo "$env_line" | stub_script cargo
  stub_script cargo-deny <<SH
$env_line
if [[ \$1 == --offline ]]; then
  echo 'error[rejected]: failed to satisfy license requirements'
  echo 'license = "GPL-3.0-only"'
  echo '├ refused-license v0.1.0'
  echo 'licenses FAILED'
  exit 4
fi
echo 'advisories ok, bans ok, licenses ok, sources ok'
SH
}

# A directory of links to every command on PATH but <names>, the first of each name as PATH finds
# it, printed, for a PATH with none of them (the machine's own cargo is under /usr/bin on Arch).
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

@test "tests/run rust runs its six steps in order, each named first, with their flags, and takes no heavy-run lock" {
  local copy=$BATS_TEST_TMPDIR/copy
  rust_checkout "$copy"
  run -0 --separate-stderr "$copy/tests/run" rust
  assert_equal "$(grep '^rust: ' <<<"$output")" "rust: cargo fmt --all --check
rust: cargo clippy --workspace --all-targets --locked -- -D warnings
rust: cargo nextest run --workspace --locked --no-tests=pass
rust: cargo test --doc --workspace --locked
rust: cargo-deny --locked --config deny.toml check
rust: the policy refuses tests/fixtures/rust-deny's refused-license (GPL-3.0-only)"
  assert_equal "$(cat "$STUB_CALLS/cargo.log")" '["fmt","--all","--check"]
["clippy","--workspace","--all-targets","--locked","--","-D","warnings"]
["nextest","run","--workspace","--locked","--no-tests=pass"]
["test","--doc","--workspace","--locked"]'
  assert_equal "$(cat "$STUB_CALLS/cargo-deny.log")" '["--locked","--config","deny.toml","check"]
["--offline","--manifest-path","tests/fixtures/rust-deny/Cargo.toml","--config","deny.toml","check","licenses"]'
  [[ $(tail -n 1 <<<"$output") =~ ^tests/run\ rust:\ 0m\ [0-9]{2}s$ ]]
  [[ ! -e $STUB_CALLS/team-heavy ]]
}

@test "tests/run rust stops at the first failing step, naming it, and fails" {
  local copy=$BATS_TEST_TMPDIR/copy
  rust_checkout "$copy"
  echo '[[ $1 != clippy ]] || { echo "error: a lint"; exit 101; }' >>"$STUB_FIXTURES/cargo.sh"
  run -1 --separate-stderr "$copy/tests/run" rust
  assert_contains "$output" "error: a lint
rust: cargo clippy --workspace --all-targets --locked -- -D warnings failed"
  assert_equal "$(jq -r '.[0]' "$STUB_CALLS/cargo.log")" $'fmt\nclippy'
  [[ ! -e $STUB_CALLS/cargo-deny.log ]]
  [[ $output != *"rust: cargo nextest"* ]]
}

# The last step passes only when cargo-deny refuses the fixture naming its crate and its license,
# so a policy that lets GPL-3.0-only through, or a refusal for another reason, fails it.
@test "tests/run rust fails the policy step when cargo-deny lets the fixture through or refuses it for another reason" {
  local copy=$BATS_TEST_TMPDIR/copy
  rust_checkout "$copy"
  stub_script cargo-deny <<<'echo "licenses ok: refused-license v0.1.0"'
  run -1 --separate-stderr "$copy/tests/run" rust
  assert_contains "$output" "rust: the policy refuses tests/fixtures/rust-deny's refused-license (GPL-3.0-only) failed: cargo-deny exited 0, naming refused-license: yes, GPL-3.0-only: no; its output:
licenses ok: refused-license v0.1.0"
  stub_script cargo-deny <<<'[[ $1 != --offline ]] || { echo "error: failed to read Cargo.lock"; exit 1; }'
  run -1 --separate-stderr "$copy/tests/run" rust
  assert_contains "$output" "rust: the policy refuses tests/fixtures/rust-deny's refused-license (GPL-3.0-only) failed: cargo-deny exited 1, naming refused-license: no, GPL-3.0-only: no; its output:
error: failed to read Cargo.lock"
}

@test "tests/run rust names each missing tool and team-doctor before any step, and runs nothing" {
  local copy=$BATS_TEST_TMPDIR/copy links
  rust_checkout "$copy"
  rm "$BATS_TEST_TMPDIR/stubs/cargo" "$BATS_TEST_TMPDIR/stubs/cargo-deny"
  links=$(path_without cargo cargo-deny)
  PATH=$links run -1 --separate-stderr "$copy/tests/run" rust
  assert_equal "$(grep '^rust' <<<"$output")" "rust: cargo and cargo-deny are not on PATH: run team-doctor, whose tool lines name each fix"
  [[ ! -e $STUB_CALLS/cargo-deny.log && ! -e $STUB_CALLS/cargo.log ]]
  stub_command cargo
  PATH=$BATS_TEST_TMPDIR/stubs:$links run -1 --separate-stderr "$copy/tests/run" rust
  assert_equal "$(grep '^rust' <<<"$output")" "rust: cargo-deny is not on PATH: run team-doctor, whose tool lines name each fix"
  [[ ! -e $STUB_CALLS/cargo-deny.log && ! -e $STUB_CALLS/cargo.log ]]
}

# Jobs: TEAM_JOBS, else team-capacity jobs with a team home, else cargo's own default (unset).
@test "tests/run rust holds cargo's jobs and nextest's threads to TEAM_JOBS, else team-capacity jobs, else leaves them" {
  local copy=$BATS_TEST_TMPDIR/copy
  rust_checkout "$copy"
  stub_command sccache
  TEAM_JOBS=3 run -0 --separate-stderr "$copy/tests/run" rust
  assert_equal "$(cut -d' ' -f3,4 "$STUB_CALLS/rust-env" | sort -u)" "jobs=3 threads=3"
  rm "$STUB_CALLS/rust-env"
  run -0 --separate-stderr env -u TEAM_JOBS "$copy/tests/run" rust
  assert_equal "$(cut -d' ' -f3,4 "$STUB_CALLS/rust-env" | sort -u)" "jobs=7 threads=7"
  rm "$STUB_CALLS/rust-env"
  run -0 --separate-stderr env -u TEAM_JOBS -u TEAM_HOME "$copy/tests/run" rust
  assert_equal "$(cut -d' ' -f3,4 "$STUB_CALLS/rust-env" | sort -u)" "jobs=unset threads=unset"
  TEAM_JOBS=0 run -1 --separate-stderr "$copy/tests/run" rust
  assert_contains "$stderr" "TEAM_JOBS is the count of bats files or cargo jobs to run at once, a whole number above 0, not '0'"
}

@test "tests/run rust sets RUSTC_WRAPPER to sccache only when it is unset and sccache is on PATH" {
  local copy=$BATS_TEST_TMPDIR/copy links
  rust_checkout "$copy"
  stub_command sccache
  run -0 --separate-stderr "$copy/tests/run" rust
  assert_equal "$(cut -d' ' -f5 "$STUB_CALLS/rust-env" | sort -u)" "wrapper=sccache"
  rm "$STUB_CALLS/rust-env"
  RUSTC_WRAPPER=/opt/other run -0 --separate-stderr "$copy/tests/run" rust
  assert_equal "$(cut -d' ' -f5 "$STUB_CALLS/rust-env" | sort -u)" "wrapper=/opt/other"
  rm "$STUB_CALLS/rust-env" "$BATS_TEST_TMPDIR/stubs/sccache"
  links=$(path_without sccache)
  PATH=$links run -0 --separate-stderr env -u RUSTC_WRAPPER "$copy/tests/run" rust
  assert_equal "$(cut -d' ' -f5 "$STUB_CALLS/rust-env" | sort -u)" "wrapper=unset"
}

@test "tests/run rust --changed runs nothing on a change to no Rust path, the steps on one, and --list prints the Rust paths" {
  local copy=$BATS_TEST_TMPDIR/copy
  rust_checkout "$copy"
  run -0 --separate-stderr "$copy/tests/run" rust --changed base
  assert_contains "$output" "rust: no Rust path changed, nothing to check"
  echo 'more' >>"$copy/README.md"
  run -0 --separate-stderr "$copy/tests/run" rust --changed base
  assert_equal "$(head -n 1 <<<"$output")" "rust: no Rust path changed, nothing to check"
  run -0 --separate-stderr "$copy/tests/run" rust --changed base --list
  assert_equal "$output" ""
  [[ ! -e $STUB_CALLS/cargo.log && ! -e $STUB_CALLS/team-heavy ]]
  # A Rust path among others: --list prints it alone, and runs nothing.
  echo 'pub fn more() {}' >>"$copy/crates/team-core/src/lib.rs"
  mkdir -p "$copy/toolkits/rust" "$copy/toolkits/other"
  echo x >"$copy/toolkits/rust/README.md"
  echo x >"$copy/toolkits/other/README.md"
  git -C "${copy:?}" switch -qc work
  git -C "${copy:?}" add -A
  git -C "${copy:?}" commit -qm 'change the crate'
  run -0 --separate-stderr "$copy/tests/run" rust --changed base --list
  assert_equal "$output" $'crates/team-core/src/lib.rs\ntoolkits/rust/README.md'
  [[ ! -e $STUB_CALLS/cargo.log ]]
  # The base defaults to origin/dev, and the steps run after the paths.
  git -C "${copy:?}" update-ref refs/remotes/origin/dev base
  run -0 --separate-stderr "$copy/tests/run" rust --changed
  assert_equal "$(head -n 4 <<<"$output")" "rust --changed origin/dev: 2 Rust paths changed
  crates/team-core/src/lib.rs
  toolkits/rust/README.md
rust: cargo fmt --all --check"
  assert_equal "$(wc -l <"$STUB_CALLS/cargo.log")" 4
  [[ ! -e $STUB_CALLS/team-heavy ]]
}

@test "tests/run rust --changed takes each Rust path of the list, and refuses a base that is no commit and any other word" {
  local copy=$BATS_TEST_TMPDIR/copy path
  rust_checkout "$copy"
  for path in Cargo.toml Cargo.lock clippy.toml deny.toml rust-toolchain.toml .github/workflows/ci.yml \
    .github/workflows/rust-macos.yml crates/new/Cargo.toml tests/fixtures/rust-deny/Cargo.toml toolkits/rust/x \
    tests/toolkits/fixtures/rust-crate/src/lib.rs; do
    mkdir -p "$copy/$(dirname "$path")"
    echo x >"$copy/$path"
  done
  mkdir -p "$copy/tests/fixtures/rust-denied" "$copy/toolkits/rusty" "$copy/crates-old"
  echo x >"$copy/tests/fixtures/rust-denied/Cargo.toml"
  echo x >"$copy/toolkits/rusty/x"
  echo x >"$copy/crates-old/x"
  echo x >"$copy/Cargo.toml.bak"
  run -0 --separate-stderr "$copy/tests/run" rust --changed base --list
  assert_equal "$output" ".github/workflows/ci.yml
.github/workflows/rust-macos.yml
Cargo.lock
Cargo.toml
clippy.toml
crates/new/Cargo.toml
deny.toml
rust-toolchain.toml
tests/fixtures/rust-deny/Cargo.toml
tests/toolkits/fixtures/rust-crate/src/lib.rs
toolkits/rust/x"
  run -2 --separate-stderr "$copy/tests/run" rust --changed nocommit
  assert_contains "$stderr" "--changed: no commit nocommit"
  run -2 --separate-stderr "$copy/tests/run" rust --changed base --list more
  run -2 --separate-stderr "$copy/tests/run" rust --list
  run -2 --separate-stderr "$copy/tests/run" rust --shard 1/2
}

# tests/run with no part runs all four, shellcheck, bats, toolkits and rust, under the heavy-run
# lock, here a team-heavy that runs it in place.
@test "plain tests/run runs all four parts, rust last" {
  local copy=$BATS_TEST_TMPDIR/copy
  rust_checkout "$copy"
  printf '%s\n' '#!/usr/bin/env bash' 'while [[ $1 != -- ]]; do shift; done' 'shift' 'TEAM_HEAVY_HELD=1 exec "$@"' |
    link_script team-heavy-in-place "$copy/bin/team-heavy"
  mkdir -p "$copy/tests/vendor/bats-core/bin" "$copy/servers"
  link_shared tests-shards "$REPO_ROOT/tests/shards" "$copy/tests/shards"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "ok 1 a test"' | link_script bats "$copy/tests/vendor/bats-core/bin/bats"
  printf '%s\n' '#!/usr/bin/env bash' 'echo installed' | link_script servers-install "$copy/servers/install"
  echo '@test "one" { true; }' >"$copy/tests/one.bats"
  stub_command shellcheck node
  stub_script shellcheck <<<'[[ $1 != --version ]] || echo "version: 9.9.9"'
  stub_reply node 'node ran'
  run -0 --separate-stderr "$copy/tests/run"
  assert_equal "$(grep -oE '^(shellcheck 9\.9\.9: [0-9]+ scripts|bats: 1 tests passed|installed|node ran|rust: cargo [a-z]+|rust: cargo-deny|rust: the policy)' <<<"$output")" "shellcheck 9.9.9: $(grep -oE '[0-9]+ scripts' <<<"$output")
bats: 1 tests passed
installed
node ran
rust: cargo fmt
rust: cargo clippy
rust: cargo nextest
rust: cargo test
rust: cargo-deny
rust: the policy"
  [[ $(tail -n 1 <<<"$output") =~ ^tests/run\ all: ]]
}
