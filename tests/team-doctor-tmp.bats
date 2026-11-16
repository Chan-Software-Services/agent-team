#!/usr/bin/env bats
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the tmp line, how full /tmp is and what team-janitor tmp removed today, as
# team-janitor tmp status --json says it, on the reading TEAM_TMP_DF names (tmp_reading) and the
# /tmp root under the sandbox's TEAM_SYSTEM_ROOT, never the machine's own.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
  tools_at arch
  only_checks 249-tmp.sh
  DAY_FILE=$HOME/.local/state/agent-team/janitor/tmp-$(date +%F).md
}

FIX="fix: team-janitor tmp status names the largest entries; team-janitor tmp removes the team's stale leftovers"

# The day's file of removals with <n> of them, as team-janitor tmp writes it: removed_today <n>
removed_today() {
  mkdir -p "${DAY_FILE%/*}"
  {
    echo "# /tmp leftovers removed on $(date +%F)"
    echo
    local i
    for ((i = 1; i <= $1; i++)); do echo "- $(date +%H:%M) removed /tmp/nm-cli-home-$i (no-mistakes, 300 MB, 2 h old)"; done
  } >"$DAY_FILE"
}

@test "under half full the tmp line passes with the fill and the day's removals" {
  run_bin -0 team-doctor
  assert_equal "$output" "PASS tmp: /tmp is 10% full (1.6 GiB of 16.0 GiB); 0 leftovers removed today"
  removed_today 3
  tmp_reading 12
  run_bin -0 team-doctor
  assert_equal "$output" "PASS tmp: /tmp is 12% full (1.9 GiB of 16.0 GiB); 3 leftovers removed today"
  removed_today 1
  tmp_reading 49
  run_bin -0 team-doctor
  assert_equal "$output" "PASS tmp: /tmp is 49% full (7.8 GiB of 16.0 GiB); 1 leftover removed today"
}

@test "at half full and over the tmp line warns with the status' first line and its fix" {
  removed_today 2
  tmp_reading 50
  run_bin -0 team-doctor
  assert_equal "$output" "WARN tmp: /tmp is 50% full (8.0 GiB of 16.0 GiB), past 50%; $FIX"
  tmp_reading 97
  run_bin -0 team-doctor
  assert_equal "$output" "WARN tmp: /tmp is 97% full (15.5 GiB of 16.0 GiB), past 50%; $FIX"
  # It is the status' own first line.
  run_bin -0 team-janitor tmp status
  assert_equal "$(head -n 1 <<<"$output")" "/tmp is 97% full (15.5 GiB of 16.0 GiB), past 50%"
  # --json gives the verdict, the reason and the fix apart.
  run_bin -0 --separate-stderr team-doctor --json
  jq -e --arg fix "${FIX#fix: }" '.[] | select(.check == "tmp")
    | .verdict == "WARN" and .reason == "/tmp is 97% full (15.5 GiB of 16.0 GiB), past 50%" and .fix == $fix' <<<"$output"
}

@test "on a file system that is not tmpfs the tmp line passes, not judging it, however full" {
  tmp_reading 90 ext4
  run_bin -0 team-doctor
  assert_equal "$output" "PASS tmp: /tmp is on ext4, not a memory file system, so it is not judged"
}

@test "when the status does not answer the tmp line warns naming its first error" {
  local fix="fix: fix what it names, then run team-doctor again"
  echo 'tmpfs nonsense' >"$TEAM_TMP_DF"
  run_bin -0 team-doctor
  assert_equal "$output" \
    "WARN tmp: \`team-janitor tmp status\` did not answer: could not read the file system of /tmp: the file system of $TEAM_SYSTEM_ROOT/tmp gave no type, size and use; $fix"
  tmp_reading 10
  rmdir "$TEAM_SYSTEM_ROOT/tmp"
  run_bin -0 team-doctor
  assert_equal "$output" \
    "WARN tmp: \`team-janitor tmp status\` did not answer: could not read the file system of /tmp: $TEAM_SYSTEM_ROOT/tmp does not exist; $fix"
  # A status that prints no reading is one that did not answer.
  mkdir "$TEAM_SYSTEM_ROOT/tmp"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "{}"' >"$CODE_CHECKOUT/bin/team-janitor.new"
  chmod +x "$CODE_CHECKOUT/bin/team-janitor.new"
  mv "$CODE_CHECKOUT/bin/team-janitor.new" "$CODE_CHECKOUT/bin/team-janitor"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN tmp: \`team-janitor tmp status\` did not answer: it printed no team-tmp/1 reading; $fix"
}

@test "team-doctor --help documents the tmp line" {
  run_bin -0 team-doctor --help
  grep -qE '^  tmp +`team-janitor tmp status --json`: how full /tmp is' <<<"$output"
}
