#!/usr/bin/env bats
# A queued item's waits: line and its age: when that line last changed in the team home's git
# history (a file git does not know yet, or a line not yet committed, reads the file's own time,
# and a history that cannot be read is said),
# shown by team-queue list beside each wait and never in the index; and team-queue waits, the
# count of the waits older than N days with their files.

load helpers/common

setup() {
  sandbox
  queued=$TEAM_HOME/tasks/queued
  mkdir -p "$queued"
  printf 'ledger.jsonl.lock\n' >"$TEAM_HOME/.gitignore"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "owner/proj"
path = "projects/proj"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1"]
TOML
  printf '# Current items\n' >"$TEAM_HOME/tasks/current.md"
  make_team_home >/dev/null
  # list runs its sibling team-capacity, so the test's own code checkout has a stub in its place;
  # its plan and costs cannot be read, which is no room and no failure.
  CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  shared_make stub "$REPO_ROOT/tests/helpers/stub"
  ln -f "$BATS_RUN_TMPDIR/shared/stub" "$CODE_CHECKOUT/bin/team-capacity"
  stub_script team-capacity <<'SH'
echo "no plan here" >&2
exit 1
SH
  export TEAM_QUEUE_TODAY=2026-11-13
}

# Write tasks/queued/<name>, a waiting item of project proj, with the front matter lines given:
# item <name> [<key>: <value>]...
item() {
  local name=$1
  shift
  { echo ---; printf '%s\n' "summary: the ${name%.md}" "project: proj" "priority: 1" "size: S" "$@"; echo ---; echo "# ${name%.md}"; } \
    >"$queued/$name"
}

# Commit the changes to the queued files named (default every one) as written <days> days ago:
# committed <days> [<file>...]
committed() {
  local at
  local -a paths=(tasks/queued)
  at=$(date -u -d "-$1 days" +%FT%TZ)
  (($# < 2)) || paths=("${@/#/tasks/queued/}") paths=("${paths[@]:1}")
  git -C "${TEAM_HOME:?}" add -A -- "${paths[@]}"
  GIT_AUTHOR_DATE=$at GIT_COMMITTER_DATE=$at git -C "${TEAM_HOME:?}" commit -q -m "chore: queue as of $1 days ago" -- "${paths[@]}"
}

# list --json's waiting items, each as {file, days, source}, one compact line.
ages() {
  guard_sandbox && "$CODE_CHECKOUT/bin/team-queue" list --json |
    jq -c '[.waiting[] | {file, days: .waited.days, source: .waited.source}]'
}

@test "a waits: line's age is when that line last changed in the team home's history" {
  item a-kept.md "waits: Daniel's word"
  item b-changed.md "waits: the vendor's reply"
  committed 20
  # Another line of a-kept changes later, and b-changed's waits: is rewritten.
  sed -i 's/^summary: .*/summary: the kept one, reworded/' "$queued/a-kept.md"
  sed -i "s/^waits: .*/waits: the vendor's second reply/" "$queued/b-changed.md"
  committed 3
  assert_equal "$(ages)" '[{"file":"a-kept.md","days":20,"source":"git"},{"file":"b-changed.md","days":3,"source":"git"}]'
  # A file git does not know yet, and a waits: line not yet committed, read the file's own time.
  item c-new.md "waits: Daniel's word"
  touch -d "-10 days" "$queued/c-new.md"
  sed -i "s/^waits: .*/waits: Daniel's word on the price/" "$queued/a-kept.md"
  touch -d "-1 days" "$queued/a-kept.md"
  assert_equal "$(ages)" \
    '[{"file":"a-kept.md","days":1,"source":"file"},{"file":"b-changed.md","days":3,"source":"git"},{"file":"c-new.md","days":10,"source":"file"}]'
  # The text shows each age beside its wait, before the conditions not met.
  opened_task T7
  item d-both.md "waits: the vendor's reply" "after: T7 merged"
  committed 2 d-both.md
  run_bin -0 --separate-stderr team-queue list
  assert_equal "$stderr" ""
  assert_contains "$output" "- c-new.md (proj, priority 1, S): the c-new; waits for Daniel's word (10 days)"
  assert_contains "$output" "- d-both.md (proj, priority 1, S): the d-both; waits for the vendor's reply (2 days), T7 merged"
  item e-today.md "waits: Daniel's word"
  committed 0 e-today.md
  run_bin -0 team-queue list
  assert_contains "$output" "- e-today.md (proj, priority 1, S): the e-today; waits for Daniel's word (under a day)"
  # --json gives waited as {since, days, source}, and null for an item that waits on nothing.
  item f-ready.md
  run_bin -0 team-queue list --json
  assert_equal "$(jq -c '.waiting[] | select(.file == "c-new.md") | .waited | {days, source, since: (.since | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))}' <<<"$output")" \
    '{"days":10,"source":"file","since":true}'
  assert_equal "$(jq -c '.ready[] | {file, waited}' <<<"$output")" '{"file":"f-ready.md","waited":null}'
}

@test "the index never shows a wait's age, so it does not change from day to day" {
  item a-old.md "waits: Daniel's word"
  committed 20
  run_bin -0 team-queue index
  assert_contains "$(cat "$queued/index.md")" "- a-old.md (proj, priority 1, S): the a-old; waits for Daniel's word"
  [[ $(cat "$queued/index.md") != *"days)"* ]]
  run_bin -0 team-queue index --check
}

@test "waits counts the waits older than N days with their files, never an item with only after: or an opened one" {
  opened_task T5
  item a-old.md "waits: Daniel's word"
  item b-after.md "after: T7 merged"
  item c-opened.md "waits: the vendor's reply" "opened: T5"
  item d-older.md "waits: the vendor's reply"
  committed 30
  sed -i "s/^waits: .*/waits: Daniel's word on the price/" "$queued/a-old.md"
  committed 12
  item e-new.md "waits: the outside event"
  committed 2
  run_bin -0 --separate-stderr team-queue waits
  assert_equal "$stderr" ""
  assert_equal "$output" "2 waits older than 7 days
- d-older.md: 30 days: the vendor's reply
- a-old.md: 12 days: Daniel's word on the price"
  run_bin -0 team-queue waits --older 1
  assert_equal "$output" "3 waits older than 1 day
- d-older.md: 30 days: the vendor's reply
- a-old.md: 12 days: Daniel's word on the price
- e-new.md: 2 days: the outside event"
  run_bin -0 team-queue waits --older 20
  assert_equal "$output" "1 wait older than 20 days
- d-older.md: 30 days: the vendor's reply"
  run_bin -0 team-queue waits --json
  assert_equal "$(jq -c '{schema, days, count, says, waits: [.waits[] | {file, waits, days, source}]}' <<<"$output")" \
    '{"schema":"team-queue-waits/1","days":7,"count":2,"says":"2 waits older than 7 days","waits":[{"file":"d-older.md","waits":"the vendor'"'"'s reply","days":30,"source":"git"},{"file":"a-old.md","waits":"Daniel'"'"'s word on the price","days":12,"source":"git"}]}'
  # None older is the count's line alone; so is a queue with nothing in it.
  run_bin -0 team-queue waits --older 40
  assert_equal "$output" "0 waits older than 40 days"
  rm "$queued"/*.md
  run_bin -0 team-queue waits
  assert_equal "$output" "0 waits older than 7 days"
}

# wall-clock: with no history each wait's age is its file's own time, which the kernel writes from
# the real clock, so with the clock moved ahead a wait written now is a year old.
# bats test_tags=wall-clock
@test "a history that cannot be read is said, on stderr and in the count's line, never read as the files' times alone" {
  item a-old.md "waits: Daniel's word"
  committed 20
  # The file's time is its checkout's, so only the history knows the wait is old.
  touch "$queued/a-old.md"
  fails_on_call git log
  run_bin -0 --separate-stderr team-queue waits
  assert_equal "$stderr" "team-queue: cannot read the team home's history of tasks/queued/ (git log exited 5 with no reason given), so each wait's age is its file's own time"
  assert_equal "$output" "0 waits older than 7 days (each age its file's own time: the team home's history cannot be read)"
  run_bin -0 --separate-stderr team-queue waits --json
  assert_equal "$(jq -c '{count, says, history_error}' <<<"$output")" \
    '{"count":0,"says":"0 waits older than 7 days (each age its file'"'"'s own time: the team home'"'"'s history cannot be read)","history_error":"git log exited 5 with no reason given"}'
  run_bin -0 --separate-stderr team-queue list
  assert_equal "$stderr" "team-queue: cannot read the team home's history of tasks/queued/ (git log exited 5 with no reason given), so each wait's age is its file's own time"
  assert_contains "$output" "- a-old.md (proj, priority 1, S): the a-old; waits for Daniel's word (under a day)"
  # A git diff that fails once the log has read is said as the diff's.
  fails_on_call git diff
  run_bin -0 --separate-stderr team-queue waits
  assert_equal "$stderr" "team-queue: cannot read the team home's history of tasks/queued/ (git diff exited 5 with no reason given), so each wait's age is its file's own time"
  assert_equal "$output" "0 waits older than 7 days (each age its file's own time: the team home's history cannot be read)"
  # A history read is no history_error.
  echo no-call-holds-this >"$STUB_FIXTURES/git.fail-on"
  run_bin -0 --separate-stderr team-queue waits --json
  assert_equal "$stderr" ""
  assert_equal "$(jq -c '{count, history_error}' <<<"$output")" '{"count":1,"history_error":null}'
}

@test "a team home with no git history says so, naming git's reason, and reads each file's own time" {
  rm -rf "${TEAM_HOME:?}/.git"
  item a-old.md "waits: Daniel's word"
  touch -d "-9 days" "$queued/a-old.md"
  run_bin -0 --separate-stderr team-queue waits
  assert_contains "$stderr" "team-queue: cannot read the team home's history of tasks/queued/ (fatal: not a git repository"
  assert_equal "$output" "1 wait older than 7 days (each age its file's own time: the team home's history cannot be read)
- a-old.md: 9 days: Daniel's word"
}

@test "waits runs in an assistant session as for the coordinator, writing nothing, and refuses a worker" {
  item a-old.md "waits: Daniel's word"
  committed 20
  assistant_reads 0 team-queue waits
  assert_equal "${lines[0]}" "1 wait older than 7 days"
  assistant_reads 0 team-queue waits --older 3 --json
  assert_equal "$(jq -r .says <<<"$output")" "1 wait older than 3 days"
  worker_refused team-queue "reads no queue" waits
  worker_refused team-queue "reads no queue" waits --json
}

@test "waits refuses a malformed command line" {
  run_bin -2 team-queue waits --older
  run_bin -2 team-queue waits --older x
  run_bin -2 team-queue waits --older -1
  run_bin -2 team-queue waits --older 3 --older 4
  run_bin -2 team-queue waits --json --json
  run_bin -2 team-queue waits extra
}
