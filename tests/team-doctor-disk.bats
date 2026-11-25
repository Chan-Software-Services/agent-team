#!/usr/bin/env bats
# team-doctor: one PASS, WARN or FAIL line per thing this machine needs, on the machine
# tests/helpers/doctor.bash builds: every tool a version stub, the OS a stubbed uname.
# This file: the disk line, what the Go build cache holds against its cap and how many job tmps
# team-janitor disk cleared today, as team-janitor disk status --json says it, on a fixture Go
# cache at the sandbox's ~/.cache/go-build (TEAM_GO_CACHE, as doctor_machine sets it) and the sandbox's disk.json, never the
# machine's own.

load helpers/common
load helpers/doctor

setup() {
  sandbox
  doctor_machine
  tools_at arch
  only_checks 251-disk.sh
  GC=$TEAM_GO_CACHE
  RECORD=$HOME/.local/state/agent-team/janitor/disk.json
}

FIX="fix: team-janitor disk trims it; team-janitor disk status names it"

# A Go build cache at $GC, its README Go's, with one entry of <kb> kilobytes: go_cache <kb>
go_cache() {
  mkdir -p "$GC/0a"
  echo 'This directory holds cached build artifacts from the Go build system.' >"$GC/README"
  head -c $(($1 * 1024)) /dev/zero >"$GC/0a/0a1b-a"
}

# The cache's size as the line says it, from du as the status measures it.
gc_size() {
  local kb
  kb=$(du -sk "$GC" | cut -f 1)
  echo "$(((kb + 512) / 1024)) MB"
}

# The record of a run today, as team-janitor disk writes it, with <count> job tmps of <kb>
# kilobytes cleared today: cleared_today <count> <kb>
cleared_today() {
  mkdir -p "${RECORD%/*}"
  jq -n --arg at "$(date -u +%FT%TZ)" --argjson count "$1" --argjson kb "$2" \
    '{schema: "team-disk/1", at: $at, ok: true,
      go: {path: null, kb: null, cap_kb: 10485760, trimmed_today: {entries: 0, kb: 0}, over_cap_said: null},
      jobs: {cleared_today: {count: $count, kb: $kb}}}' >"$RECORD"
}

# Put <body> (the lines of a script) in place of team-janitor: janitor_is <line>...
janitor_is() {
  printf '%s\n' '#!/usr/bin/env bash' "$@" >"$CODE_CHECKOUT/bin/team-janitor.new"
  chmod +x "$CODE_CHECKOUT/bin/team-janitor.new"
  mv "$CODE_CHECKOUT/bin/team-janitor.new" "$CODE_CHECKOUT/bin/team-janitor"
}

@test "the disk line passes with the status' line, the cache's path under ~" {
  run_bin -0 team-doctor
  assert_equal "$output" "PASS disk: no Go build cache at ~/.cache/go-build; 0 job tmps cleared today (0 MB)"
  TEAM_GO_CACHE='' run_bin -0 team-doctor
  assert_equal "$output" "PASS disk: no Go build cache (GOCACHE is off); 0 job tmps cleared today (0 MB)"
  go_cache 3072
  cleared_today 4 2202010
  run_bin -0 team-doctor
  assert_equal "$output" "PASS disk: Go build cache $(gc_size) of its 10.0 GiB cap at ~/.cache/go-build; 4 job tmps cleared today (2.1 GiB)"
  # It is the status' own line, the home directory as ~.
  run_bin -0 team-janitor disk status
  assert_equal "$output" "Go build cache $(gc_size) of its 10.0 GiB cap at $GC; 4 job tmps cleared today (2.1 GiB)"
  # A cache at its cap is not over it.
  TEAM_GO_CACHE_CAP_KB=$(du -sk "$GC" | cut -f 1) run_bin -0 team-doctor
  assert_equal "$(line_of disk)" "PASS disk: Go build cache $(gc_size) of its $(gc_size) cap at ~/.cache/go-build; 4 job tmps cleared today (2.1 GiB)"
}

@test "over its cap the disk line warns with the status' line and its fix" {
  go_cache 3072
  cleared_today 1 2048
  export TEAM_GO_CACHE_CAP_KB=2048
  local reason
  reason="Go build cache $(gc_size) of its 2 MB cap at ~/.cache/go-build, over its cap; 1 job tmp cleared today (2 MB)"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN disk: $reason; $FIX"
  # --json gives the verdict, the reason and the fix apart.
  run_bin -0 --separate-stderr team-doctor --json
  jq -e --arg reason "$reason" --arg fix "${FIX#fix: }" '.[] | select(.check == "disk")
    | .verdict == "WARN" and .reason == $reason and .fix == $fix' <<<"$output"
}

@test "when the status does not answer the disk line warns naming its first error" {
  local fix="fix: fix what it names, then run team-doctor again"
  TEAM_GO_CACHE_CAP_KB=lots run_bin -0 team-doctor
  assert_equal "$output" \
    "WARN disk: \`team-janitor disk status\` did not answer: TEAM_GO_CACHE_CAP_KB is 'lots', not a whole number of kilobytes; $fix"
  # A status that prints no reading is one that did not answer.
  janitor_is 'echo "{}"'
  run_bin -0 team-doctor
  assert_equal "$output" "WARN disk: \`team-janitor disk status\` did not answer: it printed no team-disk-status/1 reading; $fix"
  janitor_is "echo '{\"schema\": \"team-disk-status/1\", \"go\": {\"path\": \"/x\", \"cap_kb\": 1}}'"
  run_bin -0 team-doctor
  assert_equal "$output" "WARN disk: \`team-janitor disk status\` did not answer: it printed no team-disk-status/1 reading; $fix"
  # Nor does one that fails saying nothing.
  janitor_is 'exit 1'
  run_bin -0 team-doctor
  assert_equal "$output" "WARN disk: \`team-janitor disk status\` did not answer: it exited 1, naming no error; $fix"
}

@test "team-doctor --help documents the disk line" {
  run_bin -0 team-doctor --help
  grep -qE '^  disk +`team-janitor disk status --json`: what the Go build cache holds' <<<"$output"
}
