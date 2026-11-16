#!/usr/bin/env bats
# team-doctor's confine line (bin/lib/doctor.d/093-confine.sh), on the machine
# tests/helpers/doctor.bash builds: it runs the real pair, bin/lib/confine-session and the program
# it writes, which runs bin/lib/confine-shell and bin/lib/confine.py, on this machine's kernel
# for the pass, which is skipped, naming the ABI, where the kernel's Landlock is below 2, and,
# since the wrapper has no seam, through tests/helpers/confine-seams.py in the wrapper's place
# (CONFINE_TEST_ABI, CONFINE_TEST_FAIL) and a stubbed macOS for the warning and the failure.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
  only_checks 093-confine.sh
}

# The kernel's Landlock ABI, as the wrapper reads it.
abi() { python3 -I "$REPO_ROOT/bin/lib/confine.py" --abi; }

# Skip a test that needs the domain on a machine without it.
needs_landlock() {
  local n
  n=$(abi)
  ((n >= 2)) || skip "this kernel's Landlock ABI is $n, below 2"
}

# Puts tests/helpers/confine-seams.py where the doctor's checkout has the wrapper, loading the real
# one, so CONFINE_TEST_ABI and CONFINE_TEST_FAIL decide what the doctor's run of it reads.
seams() {
  rm "$CODE_CHECKOUT/bin/lib/confine.py"
  cp "$BATS_TEST_DIRNAME/helpers/confine-seams.py" "$CODE_CHECKOUT/bin/lib/confine.py"
  export CONFINE_REAL=$REPO_ROOT/bin/lib/confine.py
}

FIX="fix: bin/lib/confine-session's, bin/lib/confine-shell's and bin/lib/confine.py's own --help say what each needs"

@test "the confine line passes with the kernel's ABI where the real pair runs a session's shell and prefix confined, and leaves no directory behind" {
  needs_landlock
  tools_at arch
  # A task or a session named in the doctor's environment names no session tmp for its run.
  local task="T$((7100000000 + $$))"
  AGENT_TEAM_TASK=$task CLAUDE_CODE_SESSION_ID=abcdef0123456789 run_bin -0 team-doctor
  assert_equal "$(line_of confine)" "PASS confine: Landlock ABI $(abi); a worker's shell commands can run confined (a session's shell and prefix ran true in a sandbox worktree); no project has confine on, so every worker runs on the text guard alone"
  [[ ! -e /tmp/agent-team-$task && ! -e /tmp/agent-team-gate-abcdef01 && ! -e /tmp/agent-team-doctor ]]
  # Nothing under the home directory's ~/.config, and nothing left of the doctor's own scratch.
  [[ ! -e $HOME/.config/agent-team/confine ]]
  assert_equal "$(find "${TMPDIR:-/tmp}" -maxdepth 4 -name confine-home -user "$(id -un)" 2>/dev/null)" ""
  run_bin -0 --separate-stderr team-doctor --json
  jq -e '.[] | select(.check == "confine") | .verdict == "PASS" and .fix == ""' <<<"$output"
}

@test "the confine line's pass names the projects whose workers run confined, those with confine on" {
  needs_landlock
  tools_at arch
  local project
  for project in $(TEAM_HOME=$TEAM_HOME "$CODE_CHECKOUT/bin/team-project" --list); do
    sed -i "s/^\\[$project\\]\$/&\\nconfine = \"on\"/" "$TEAM_HOME/projects.toml"
  done
  run_bin -0 team-doctor
  assert_equal "$(line_of confine)" "PASS confine: Landlock ABI $(abi); a worker's shell commands can run confined (a session's shell and prefix ran true in a sandbox worktree); confine is on for $(TEAM_HOME=$TEAM_HOME "$CODE_CHECKOUT/bin/team-project" --list | paste -sd, | sed 's/,/, /g')"
}

@test "the confine line warns, with no fix, on macOS and on a kernel with no Landlock or ABI 1" {
  tools_at arch
  seams
  CONFINE_TEST_ABI=0 run_bin -0 team-doctor
  assert_equal "$(line_of confine)" "WARN confine: this machine has no Landlock (ABI 0), so its workers run on the text guard alone (sops/platform-gotchas.md)"
  CONFINE_TEST_ABI=1 run_bin -0 team-doctor
  assert_equal "$(line_of confine)" "WARN confine: this machine has no Landlock (ABI 1), so its workers run on the text guard alone (sops/platform-gotchas.md)"
  CONFINE_TEST_ABI=0 run_bin -0 --separate-stderr team-doctor --json
  jq -e '.[] | select(.check == "confine") | .verdict == "WARN" and .fix == ""' <<<"$output"
  # macOS, whatever the kernel under the test.
  on_macos
  tools_at macos
  run_bin -0 team-doctor
  assert_equal "$(line_of confine)" "WARN confine: this machine has no Landlock (ABI 0), so its workers run on the text guard alone (sops/platform-gotchas.md)"
  grep -qF 'on a machine with no Landlock' "$REPO_ROOT/sops/platform-gotchas.md"
}

@test "the confine line fails with the wrapper's last line when it cannot enter the domain where Landlock is" {
  needs_landlock
  tools_at arch
  seams
  CONFINE_TEST_FAIL=restrict run_bin -1 team-doctor
  assert_equal "$(line_of confine)" "FAIL confine: confine: cannot enter the domain: Operation not permitted; $FIX"
}

@test "the confine line fails with the prefix's own line when it finds no python3 where a session's commands look" {
  needs_landlock
  tools_at arch
  # The doctor's copy of the prefix looks where no python3 is, as on a machine whose only one is
  # elsewhere on PATH.
  sed -i 's|^for candidate in .*; do$|for candidate in /no-such-directory/python3; do|' "$CODE_CHECKOUT/bin/lib/confine-shell"
  grep -q '^for candidate in /no-such-directory/python3; do$' "$CODE_CHECKOUT/bin/lib/confine-shell"
  run_bin -1 team-doctor
  assert_equal "$(line_of confine)" "FAIL confine: confine-shell: no python3 in /usr/bin, /usr/local/bin or /opt/homebrew/bin, so the command does not run; $FIX"
}

@test "the confine line fails, naming the last stderr line, when confine-session cannot write the session directory or cannot run" {
  needs_landlock
  tools_at arch
  # No bash where confine-session looks for the session's shell.
  sed -i 's|^for candidate in /opt/homebrew/bin/bash .*; do$|for candidate in /no-such-directory/bash; do|' "$CODE_CHECKOUT/bin/lib/confine-session"
  grep -q '^for candidate in /no-such-directory/bash; do$' "$CODE_CHECKOUT/bin/lib/confine-session"
  run_bin -1 team-doctor
  assert_equal "$(line_of confine)" "FAIL confine: confine-session: no bash in /opt/homebrew/bin, /usr/local/bin, /usr/bin or /bin; $FIX"
  rm "$CODE_CHECKOUT/bin/lib/confine-session"
  run_bin -1 team-doctor
  assert_contains "$(line_of confine)" "FAIL confine: "
  assert_contains "$(line_of confine)" "confine-session: No such file or directory; $FIX"
  assert_equal "$(find "${TMPDIR:-/tmp}" -maxdepth 4 -name confine-home -user "$(id -un)" 2>/dev/null)" ""
}

@test "the confine line fails when the wrapper cannot say the ABI" {
  tools_at arch
  rm "$CODE_CHECKOUT/bin/lib/confine.py"
  run_bin -1 team-doctor
  assert_contains "$(line_of confine)" "FAIL confine: confine.py --abi exited 2: "
  assert_contains "$(line_of confine)" "; $FIX"
}

@test "team-doctor --help lists the confine line after the guard hooks line" {
  run_bin -0 team-doctor --help
  assert_contains "$output" "  confine       Whether this machine's workers can have the kernel layer under the text guard:"
  local guard confine records
  guard=$(grep -n '^  guard hooks ' <<<"$output" | cut -d: -f1)
  confine=$(grep -n '^  confine ' <<<"$output" | cut -d: -f1)
  records=$(grep -n '^  records hooks ' <<<"$output" | cut -d: -f1)
  ((guard < confine && confine < records))
}
