#!/usr/bin/env bats
# team-brief: the facts of a diff each review brief lists under ## Tests and dependencies, which
# bin/lib/review_facts.py reads from git: the tests a head drops (dropped_tests) and the direct
# dependencies it adds or changes (dependencies). Projects home
# (direct-pr, base main) and conv (no-mistakes, base dev, so its briefs before the PR are the
# before-pr/ ones); each task's worktree is a clone of a bare origin, with real git.
# team-brief.bats holds the rest of team-brief's tests.

load helpers/common

setup() {
  sandbox
  export TEAM_HOME=$HOME/agent-team-records
  mkdir -p "$TEAM_HOME/tasks"
  : >"$TEAM_HOME/ledger.jsonl"
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[conv]
repo = "Chan-Software-Services/Conventioner"
path = "Documents/projects/personal/Conventioner"
base = "dev"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[conv.pool]
provider = "treehouse"
lease = "scripts/th-lease.sh"
return = "scripts/th-return.sh"
slots = [".treehouse/Conventioner-d4c77a/3/Conventioner", ".treehouse/Conventioner-d4c77a/4/Conventioner"]

[home]
repo = "Chan-Software-Services/agent-team"
path = "agent-team"
base = "main"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".work/task"
docs = []
toolkits = []

[home.pool]
provider = "git"
slots = ["agent-team/.claude/worktrees/1", "agent-team/.claude/worktrees/2"]
TOML
  pr=https://github.com/Chan-Software-Services/agent-team/pull/9
}

# event <task> <kind> '<jq object of the other fields>': append one ledger line.
event() {
  jq -cn --arg task "$1" --arg event "$2" "{ts: \"2026-10-22T10:00:00Z\", task: \$task, event: \$event} + $3" \
    >>"$TEAM_HOME/ledger.jsonl"
}

# open_task <task> <project> <branch> <worktree under $HOME>: the events team-open writes.
open_task() {
  mkdir -p "$TEAM_HOME/tasks/$1"
  event "$1" opened "$(jq -cn --arg p "$2" --arg b "$3" --arg wt "$HOME/$4" \
    '{project: $p, path: "feature", type: "feat", title: "the tooling", branch: $b, base: "dev",
      base_sha: "aba9d074", worktree: $wt}')"
  event "$1" thread '{discord_thread: "1563000000000000012"}'
}

open_t14() { open_task T14 home feat/T14-team-tooling agent-team/.claude/worktrees/2; }
open_t12() { open_task T12 conv fix/T12-rate-limit .treehouse/Conventioner-d4c77a/4/Conventioner; }

# put <file under wt> <line>...: write the lines to the file, making its directory.
put() {
  mkdir -p "$(dirname "$wt/$1")"
  printf '%s\n' "${@:2}" >"$wt/$1"
}

# commit_all <subject>: commit everything in wt, printing the commit's full sha.
commit_all() {
  git -C "${wt:?}" add -A
  git -C "${wt:?}" commit -q -m "$1"
  git -C "${wt:?}" rev-parse HEAD
}

# task_repo <task> <base>: the task's worktree (its opened event's) as a clone of a bare origin,
# <base> with one commit, and the task's branch checked out from it. Sets wt.
task_repo() {
  local branch origin
  wt=$(jq -r --arg t "$1" 'select(.task == $t and .event == "opened") | .worktree' "$TEAM_HOME/ledger.jsonl")
  branch=$(jq -r --arg t "$1" 'select(.task == $t and .event == "opened") | .branch' "$TEAM_HOME/ledger.jsonl")
  origin=$BATS_TEST_TMPDIR/origin/$1.git
  mkdir -p "${origin%/*}"
  git init -q --bare -b "$2" "$origin"
  git clone -q "$origin" "$wt" 2>/dev/null
  git -C "${wt:?}" checkout -q -B "$2"
  put base.txt start
  commit_all "chore: start" >/dev/null
  git -C "${wt:?}" push -q -u origin "$2"
  git -C "${wt:?}" checkout -q -b "$branch"
}

# on_base <task> <base>: what the caller wrote into wt since task_repo, committed on the task's
# branch, which has no commit of its own yet, and made <base> and origin's <base> too. Call it as
# "task_repo; put...; on_base".
on_base() {
  commit_all "chore: the base's tests" >/dev/null
  git -C "${wt:?}" push -q origin "HEAD:$2"
  git -C "${wt:?}" branch -q -f "$2" HEAD
}

# dropped <brief path>: the value the brief's record holds for dropped_tests.
dropped() {
  jq -r .values.dropped_tests "${1%.md}.json"
}

# deps <brief path>: the value the brief's record holds for dependencies.
deps() {
  jq -r .values.dependencies "${1%.md}.json"
}

# spec <line>...: write T14's spec.md, in the worktree's task directory, which git does not track.
spec() {
  mkdir -p "$wt/.work/task"
  printf '%s\n' "$@" >"$wt/.work/task/spec.md"
}

# review <head>: T14's reviewer brief of <head>, printing its path.
review() {
  run_bin -0 --separate-stderr team-brief T14 reviewer --force --set pr="$pr" --set head="$1" --set checks=c
  assert_equal "$stderr" ""
}

@test "bats: a removed test, a deleted file's and a skip marker added are listed; a test moved between files is not" {
  open_t14
  task_repo T14 main
  put tests/a.bats '@test "one" {' '  true' '}' '@test "two" {' '  true' '}' "@test 'moves' {" '  true' '}'
  put tests/b.bats '@test "stays" {' '  true' '}'
  put tests/gone.bats '@test "goes with its file" {' '  true' '}'
  on_base T14 main
  put tests/a.bats '@test "one" {' '  skip "flaky"' '  true' '}'
  put tests/b.bats '@test "stays" {' '  true' '}' "  @test 'moves' {" '  true' '}'
  rm "$wt/tests/gone.bats"
  head=$(commit_all "test: drop some")
  review "$head"
  assert_equal "$(dropped "$output")" "\`origin/main...$head\` drops these tests:

- \`tests/a.bats\`: \`two\`, removed
- \`tests/a.bats\`: 1 more skip marker, the first \`skip\`
- \`tests/gone.bats\`: \`goes with its file\`, removed with its file"
  assert_contains "$(<"$output")" "$(dropped "$output")"
}

@test "JavaScript and TypeScript: a removed test, a deleted file's, skip and focus markers added; a moved test and a non-test file are not listed" {
  open_t14
  task_repo T14 main
  put web/cart.test.ts 'describe("cart", () => {' '  test("totals the cart", () => {});' "  it('adds', () => {});" \
    '  it.each([1, 2])("moves %d", () => {});' '});'
  put web/list.spec.ts 'it("lists", () => {});'
  put src/old.test.js 'test(`goes`, () => {});'
  put web/cart.ts 'test("not a test file", () => {});'
  on_base T14 main
  put web/cart.test.ts 'describe("cart", () => {' "  it.skip('adds', () => {});" '  xit("waits", () => {});' '});'
  put web/list.spec.ts 'it.only("lists", () => {});' 'it.each([1, 2])("moves %d", () => {});'
  rm "$wt/src/old.test.js"
  put web/cart.ts ''
  head=$(commit_all "test: drop some")
  review "$head"
  assert_equal "$(dropped "$output")" "\`origin/main...$head\` drops these tests:

- \`src/old.test.js\`: \`goes\`, removed with its file
- \`web/cart.test.ts\`: \`totals the cart\`, removed
- \`web/cart.test.ts\`: 2 more skip markers, the first \`it.skip(\`
- \`web/list.spec.ts\`: 1 more focus marker, the first \`it.only(\`"
}

@test "Python: a removed test, a deleted file's and skip markers added are listed; a test moved between files is not" {
  open_t14
  task_repo T14 main
  put back-end/tests/test_auth.py 'def test_login():' '    pass' 'async def test_logout():' '    pass' \
    'def test_moves():' '    pass'
  put back-end/tests/test_other.py 'def test_stays():' '    pass'
  put back-end/legacy_test.py 'def test_legacy():' '    pass'
  on_base T14 main
  # The markers in double quotes: the data check reads a quote, @ and a dotted name as an address.
  put back-end/tests/test_auth.py "@pytest.mark.skip" 'async def test_logout():' '    pass' \
    "@pytest.mark.skipif(True, reason='slow')" 'def test_later():' '    pass'
  put back-end/tests/test_other.py 'def test_stays():' '    pass' '' 'def test_moves():' '    pass'
  rm "$wt/back-end/legacy_test.py"
  head=$(commit_all "test: drop some")
  review "$head"
  assert_equal "$(dropped "$output")" "\`origin/main...$head\` drops these tests:

- \`back-end/legacy_test.py\`: \`test_legacy\`, removed with its file
- \`back-end/tests/test_auth.py\`: \`test_login\`, removed
- \`back-end/tests/test_auth.py\`: 2 more skip markers, the first \`@pytest.mark.skip\`"
}

@test "Go: a removed test, a deleted file's and a skip marker added are listed; a test moved between files is not" {
  open_t14
  task_repo T14 main
  put pkg/cart_test.go 'package pkg' 'func TestTotal(t *testing.T) {}' 'func FuzzParse(f *testing.F) {' '}' \
    'func TestMoves(t *testing.T) {}'
  put pkg/list_test.go 'package pkg' 'func TestList(t *testing.T) {}'
  put pkg/old_test.go 'package pkg' 'func TestOld(t *testing.T) {}'
  on_base T14 main
  put pkg/cart_test.go 'package pkg' 'func FuzzParse(f *testing.F) {' '	t.Skip("flaky")' '}'
  put pkg/list_test.go 'package pkg' 'func TestList(t *testing.T) {}' 'func TestMoves(t *testing.T) {}'
  rm "$wt/pkg/old_test.go"
  head=$(commit_all "test: drop some")
  review "$head"
  assert_equal "$(dropped "$output")" "\`origin/main...$head\` drops these tests:

- \`pkg/cart_test.go\`: \`TestTotal\`, removed
- \`pkg/cart_test.go\`: 1 more skip marker, the first \`t.Skip(\`
- \`pkg/old_test.go\`: \`TestOld\`, removed with its file"
}

@test "a head that drops no test gets one line saying so, and the base's own removals are not the head's" {
  open_t14
  task_repo T14 main
  put tests/a.bats '@test "one" {' '  true' '}'
  on_base T14 main
  put tests/a.bats '@test "one" {' '  true' '}' '@test "two" {' '  true' '}'
  put work.txt work
  head=$(commit_all "test: add one")
  # The base drops its own test after the branch left it.
  git -C "${wt:?}" checkout -q main
  put tests/a.bats ''
  commit_all "test: the base's own removal" >/dev/null
  git -C "${wt:?}" push -q origin main
  git -C "${wt:?}" checkout -q feat/T14-team-tooling
  review "$head"
  assert_equal "$(dropped "$output")" \
    "\`origin/main...$head\` removes, skips and focuses no test it can read: no \`@test\` (bats), \`it(\` or \`test(\` (JavaScript and TypeScript), \`def test_\` (Python) or \`func Test\` (Go) is gone, and no skip or focus marker is added."
}

@test "the list holds 30 items, then one line naming how many more and their files" {
  open_t14
  task_repo T14 main
  local n lines=()
  for n in $(seq 1 30); do lines+=("@test \"a$n\" {" '}'); done
  put tests/a.bats "${lines[@]}"
  put tests/b.bats '@test "b1" {' '}'
  put tests/c.bats '@test "c1" {' '}'
  on_base T14 main
  put tests/a.bats ''
  put tests/b.bats ''
  put tests/c.bats ''
  head=$(commit_all "test: drop them all")
  review "$head"
  local value
  value=$(dropped "$output")
  [[ $(grep -c '^- `tests/a.bats`: `a[0-9]*`, removed$' <<<"$value") -eq 30 ]]
  [[ $(grep -c '^- ' <<<"$value") -eq 31 ]]
  assert_equal "$(tail -n 1 <<<"$value")" '- and 2 more in `tests/b.bats`, `tests/c.bats`'
}

@test "a name or path with a backtick is written as a JSON string, and a file that cannot be read is listed for reading by hand" {
  open_t14
  task_repo T14 main
  put tests/a.bats '@test "runs `team-next`" {' '}'
  put 'tests/odd`name.bats' '@test "plain" {' '}'
  put tests/test_bytes.py 'def test_one():' '    pass'
  on_base T14 main
  put tests/a.bats ''
  put 'tests/odd`name.bats' ''
  printf 'def test_one():\n    pass # \xff\n' >"$wt/tests/test_bytes.py"
  head=$(commit_all "test: odd ones")
  review "$head"
  assert_equal "$(dropped "$output")" "\`origin/main...$head\` drops these tests:

- \`tests/a.bats\`: \`\"runs \\u0060team-next\\u0060\"\`, removed
- \`\"tests/odd\\u0060name.bats\"\`: \`plain\`, removed
- \`tests/test_bytes.py\`: cannot be read at \`${head:0:8}\`: read its diff by hand"
}

@test "dropped_tests is never set, and a list git cannot give is refused with its reason, nothing written" {
  open_t14
  task_repo T14 main
  local head orphan before
  head=$(git -C "${wt:?}" rev-parse HEAD)
  run_bin -1 team-brief T14 reviewer --set pr="$pr" --set head="$head" --set checks=c --set "dropped_tests=none"
  assert_equal "$output" "team-brief: dropped_tests is derived by git from the base and the head the brief names; it cannot be set"
  # A head that shares no history with the base, in a template that lists only the dropped tests,
  # so the instruction files' own refusal does not come first.
  code=$BATS_TEST_TMPDIR/code
  mkdir -p "$code/templates/briefs"
  copy_bin "$code/bin"
  printf '%s\n' '{{head}}' '{{dropped_tests}}' >"$code/templates/briefs/x.md"
  git -C "${wt:?}" checkout -q --orphan elsewhere
  put other.txt other
  orphan=$(commit_all "chore: unrelated")
  git -C "${wt:?}" checkout -q -f feat/T14-team-tooling
  before=$(cd "$TEAM_HOME/tasks" && find . -type f -printf '%P %s\n' | sort)
  guard_sandbox
  run "$code/bin/team-brief" T14 x --set head="$orphan"
  assert_equal "$status" 1
  assert_contains "$output" "team-brief: cannot list the dropped tests origin/main...$orphan changes in ~/agent-team/.claude/worktrees/2 (fatal: "
  assert_contains "$output" "no merge base)"
  assert_equal "$(cd "$TEAM_HOME/tasks" && find . -type f -printf '%P %s\n' | sort)" "$before"
  # With the base in reach, the same template renders.
  run "$code/bin/team-brief" T14 x --set head="$head"
  assert_equal "$status" 0
}

@test "package.json: each section's added and changed dependencies are listed, named or not in spec.md; a move between sections with the same spec is not" {
  open_t14
  task_repo T14 main
  put front-end/package.json '{"name": "web", "version": "1.0.0",' \
    '  "dependencies": {"react": "^18.2.0", "moves": "1.0.0", "bumps-and-moves": "1.0.0"},' \
    '  "devDependencies": {"vitest": "^1.0.0"}}'
  on_base T14 main
  put front-end/package.json '{"name": "web", "version": "2.0.0", "scripts": {"test": "vitest"},' \
    '  "dependencies": {"react": "^18.3.0", "zod": "^3.23.0"},' \
    '  "devDependencies": {"vitest": "^1.0.0", "moves": "1.0.0", "bumps-and-moves": "2.0.0"},' \
    '  "peerDependencies": {"@types/react": "^18"},' \
    '  "optionalDependencies": {"fsevents": "2.3.3"}}'
  head=$(commit_all "feat: new dependencies")
  spec 'The cart validates with Zod, and React moves up a minor.' 'It types against @types/react.'
  review "$head"
  assert_equal "$(deps "$output")" "\`origin/main...$head\` adds or changes these direct dependencies:

- \`front-end/package.json\`: \`react\` \`^18.2.0\` to \`^18.3.0\` in \`dependencies\`, named in \`spec.md\`
- \`front-end/package.json\`: \`zod\` added at \`^3.23.0\` in \`dependencies\`, named in \`spec.md\`
- \`front-end/package.json\`: \`bumps-and-moves\` \`1.0.0\` to \`2.0.0\` in \`devDependencies\`, not named in \`spec.md\`
- \`front-end/package.json\`: \`@types/react\` added at \`^18\` in \`peerDependencies\`, named in \`spec.md\`
- \`front-end/package.json\`: \`fsevents\` added at \`2.3.3\` in \`optionalDependencies\`, not named in \`spec.md\`"
  assert_contains "$(<"$output")" "$(deps "$output")"
}

@test "requirements*.txt: names as PEP 503 normalizes them, extras and comments dropped, option lines skipped and an -e or URL line listed whole" {
  open_t14
  task_repo T14 main
  put back-end/requirements.txt '# the service' '-r base.txt' 'requests>=2.31  # http' 'Django_REST..framework==3.14'
  on_base T14 main
  put back-end/requirements.txt '# the service' '-r base.txt' '--index-url https://pypi.example.com/simple' \
    '-c constraints.txt' '' 'requests[security]>=2.32  # http' 'Django_REST..framework==3.14' 'PyYAML' \
    '-e ./libs/shared' 'wheel @ https://files.example.com/wheel-0.43.0-py3-none-any.whl'
  put back-end/requirements-dev.txt 'pytest==8.2.0'
  put back-end/notes.txt 'black==24.1.0'
  head=$(commit_all "feat: new dependencies")
  spec 'Parse the config with pyyaml; requests moves up.'
  review "$head"
  assert_equal "$(deps "$output")" "\`origin/main...$head\` adds or changes these direct dependencies:

- \`back-end/requirements-dev.txt\`: \`pytest\` added at \`==8.2.0\`, not named in \`spec.md\`
- \`back-end/requirements.txt\`: \`requests\` \`>=2.31\` to \`>=2.32\`, named in \`spec.md\`
- \`back-end/requirements.txt\`: \`pyyaml\` added with no version, named in \`spec.md\`
- \`back-end/requirements.txt\`: \`-e ./libs/shared\` added, not named in \`spec.md\`
- \`back-end/requirements.txt\`: \`wheel @ https://files.example.com/wheel-0.43.0-py3-none-any.whl\` added, not named in \`spec.md\`"
}

@test "requirements*.txt: an unchanged name keeps its line though its case or punctuation changes, and a URL line that changes is listed whole with its old one" {
  open_t14
  task_repo T14 main
  put requirements.txt 'Flask_Login==0.6.3' 'wheel @ https://files.example.com/wheel-0.42.0-py3-none-any.whl'
  on_base T14 main
  put requirements.txt 'flask-login==0.6.3' 'wheel @ https://files.example.com/wheel-0.43.0-py3-none-any.whl'
  head=$(commit_all "build: tidy")
  spec 'Nothing on dependencies.'
  review "$head"
  assert_equal "$(deps "$output")" "\`origin/main...$head\` adds or changes these direct dependencies:

- \`requirements.txt\`: \`wheel @ https://files.example.com/wheel-0.43.0-py3-none-any.whl\` changed from \`wheel @ https://files.example.com/wheel-0.42.0-py3-none-any.whl\`, not named in \`spec.md\`"
}

@test "go.mod: single and block require lines are listed, added or changed, but not those marked indirect" {
  open_t14
  task_repo T14 main
  put go.mod 'module example.com/gate' '' 'go 1.22' '' 'require golang.org/x/sync v0.7.0' '' 'require (' \
    '	github.com/spf13/cobra v1.8.0' '	golang.org/x/text v0.14.0 // indirect' ')'
  on_base T14 main
  put go.mod 'module example.com/gate' '' 'go 1.23' '' 'require golang.org/x/sync v0.8.0' '' 'require (' \
    '	github.com/spf13/cobra v1.8.0' '	github.com/stretchr/testify v1.9.0 // tests' \
    '	golang.org/x/text v0.15.0 // indirect' '	golang.org/x/mod v0.17.0 // indirect' ')'
  head=$(commit_all "build: bump sync")
  spec 'Bump golang.org/x/sync for errgroup.SetLimit.'
  review "$head"
  assert_equal "$(deps "$output")" "\`origin/main...$head\` adds or changes these direct dependencies:

- \`go.mod\`: \`golang.org/x/sync\` \`v0.7.0\` to \`v0.8.0\`, named in \`spec.md\`
- \`go.mod\`: \`github.com/stretchr/testify\` added at \`v1.9.0\`, not named in \`spec.md\`"
}

@test "a package.json that is not JSON at the head is listed for reading by hand, and with no spec.md each item says so" {
  open_t14
  task_repo T14 main
  put package.json '{"dependencies": {"left-pad": "1.0.0"}}'
  put tools/package.json '{"dependencies": {}}'
  on_base T14 main
  put package.json '{"dependencies": {"left-pad": "1.0.0",}}'
  put tools/package.json '{"dependencies": {"esbuild": "0.21.5"}}'
  head=$(commit_all "build: tools")
  review "$head"
  assert_equal "$(deps "$output")" "\`origin/main...$head\` adds or changes these direct dependencies:

- \`package.json\`: cannot be read at \`${head:0:8}\`: read its diff by hand
- \`tools/package.json\`: \`esbuild\` added at \`0.21.5\` in \`dependencies\`, not named: the task directory has no \`spec.md\`"
}

@test "a head that changes no direct dependency gets one line saying so: a lock file, a removal and the base's own changes are not the head's" {
  open_t14
  task_repo T14 main
  put package.json '{"dependencies": {"left-pad": "1.0.0", "goes": "1.0.0"}}'
  put package-lock.json '{"lockfileVersion": 3}'
  on_base T14 main
  put package.json '{"dependencies": {"left-pad": "1.0.0"}}'
  put package-lock.json '{"lockfileVersion": 3, "packages": {}}'
  head=$(commit_all "build: drop one")
  # The base adds its own dependency after the branch left it.
  git -C "${wt:?}" checkout -q main
  put go.mod 'module example.com/x' 'require golang.org/x/sync v0.8.0'
  commit_all "build: the base's own dependency" >/dev/null
  git -C "${wt:?}" push -q origin main
  git -C "${wt:?}" checkout -q feat/T14-team-tooling
  review "$head"
  assert_equal "$(deps "$output")" \
    "\`origin/main...$head\` adds and changes no direct dependency in a \`package.json\`, \`requirements*.txt\` or \`go.mod\`."
}

@test "the dependency list holds 30 items, then one line naming how many more and their manifests" {
  open_t14
  task_repo T14 main
  local n lines=()
  for n in $(seq 1 30); do lines+=("dep-$n==1.0"); done
  put requirements.txt "${lines[@]}"
  put web/package.json '{"dependencies": {"zod": "^3.23.0"}}'
  head=$(commit_all "build: many")
  review "$head"
  local value
  value=$(deps "$output")
  [[ $(grep -c '^- `requirements.txt`: `dep-[0-9]*` added at `==1.0`, not named' <<<"$value") -eq 30 ]]
  [[ $(grep -c '^- ' <<<"$value") -eq 31 ]]
  assert_equal "$(tail -n 1 <<<"$value")" '- and 1 more in `web/package.json`'
}

@test "dependencies is never set, and a list git cannot give is refused with its reason, nothing written" {
  open_t14
  task_repo T14 main
  local head orphan before
  head=$(git -C "${wt:?}" rev-parse HEAD)
  run_bin -1 team-brief T14 reviewer --set pr="$pr" --set head="$head" --set checks=c --set "dependencies=none"
  assert_equal "$output" "team-brief: dependencies is derived by git from the base and the head the brief names; it cannot be set"
  # A head that shares no history with the base, in a template that lists only the dependencies,
  # so the other derived values' refusals do not come first.
  code=$BATS_TEST_TMPDIR/code
  mkdir -p "$code/templates/briefs"
  copy_bin "$code/bin"
  printf '%s\n' '{{head}}' '{{dependencies}}' >"$code/templates/briefs/x.md"
  git -C "${wt:?}" checkout -q --orphan elsewhere
  put other.txt other
  orphan=$(commit_all "chore: unrelated")
  git -C "${wt:?}" checkout -q -f feat/T14-team-tooling
  before=$(cd "$TEAM_HOME/tasks" && find . -type f -printf '%P %s\n' | sort)
  guard_sandbox
  run "$code/bin/team-brief" T14 x --set head="$orphan"
  assert_equal "$status" 1
  assert_contains "$output" "team-brief: cannot list the dependencies origin/main...$orphan changes in ~/agent-team/.claude/worktrees/2 (fatal: "
  assert_contains "$output" "no merge base)"
  assert_equal "$(cd "$TEAM_HOME/tasks" && find . -type f -printf '%P %s\n' | sort)" "$before"
  run "$code/bin/team-brief" T14 x --set head="$head"
  assert_equal "$status" 0
}

@test "every review brief holds the Tests and dependencies section right after the instruction files, the re-reviews' sentence their own, ending with the dependencies and their rule" {
  open_t14
  open_t12
  task_repo T12 dev
  put tests/a.bats '@test "one" {' '}'
  on_base T12 dev
  put tests/a.bats ''
  local reviewed12 head12 reviewed14 head14 brief template next section
  reviewed12=$(commit_all "test: the first cut")
  put work.txt fix
  head12=$(commit_all "fix: finding 2")
  event T12 review "$(jq -cn --arg h "$reviewed12" '{verdict: "findings", head: $h, sent_back: [2]}')"
  task_repo T14 main
  reviewed14=$(git -C "${wt:?}" rev-parse HEAD)
  put work.txt fix
  head14=$(commit_all "fix: finding 2")
  event T14 review "$(jq -cn --arg h "$reviewed14" '{verdict: "findings", head: $h, sent_back: [2]}')"
  # T12's are a gated project's briefs before its PR, the before-pr/ ones; T14's a PR's.
  run_bin -0 team-brief T12 reviewer --name review --set head="$head12" --set checks=c
  run_bin -0 team-brief T12 rereview --name rereview --set head="$head12"
  run_bin -0 team-brief T12 verify --name verify --set head="$head12" --set findings=2
  run_bin -0 team-brief T14 reviewer --name review --set pr="$pr" --set head="$head14" --set checks=c
  run_bin -0 team-brief T14 rereview --name rereview --set pr="$pr" --set head="$head14"
  run_bin -0 team-brief T14 verify --name verify --set pr="$pr" --set head="$head14" --set findings=2
  assert_contains "$(<"$TEAM_HOME/tasks/T12/brief-rereview.md")" "No PR yet: reviewed at"
  assert_contains "$(<"$TEAM_HOME/tasks/T12/brief-verify.md")" "No PR yet: reviewed at"
  local rule="Name each listed dependency in \`review.md\` with its version; one \`spec.md\` does not name is a plain \`note\` of scope \`change\`, which goes back: the builder removes it, or the PR records Daniel's decision to keep it."
  local first="An assertion, test or check the change loosens counts as dropped too (a wider match or tolerance, a test marked to fail, retry or run less, a check turned off), every commit on the branch included, whoever made it: name each dropped test and each loosening in \`review.md\` with the reason the change gives for it; one with no reason is **blocking**"
  for brief in "$TEAM_HOME"/tasks/T1[24]/brief-*.md; do
    template=${brief##*brief-}
    # The next heading after the instruction files is this section, holding the value and the
    # sentence, the re-reviews' with their own ending.
    next=$(sed -n '/^## Instruction and settings files$/,${/^## /p}' "$brief" | sed -n 2p)
    assert_equal "$next" "## Tests and dependencies"
    assert_contains "$(sed -n '/^## Tests and dependencies$/,/^## [^T]/p' "$brief")" "$(dropped "$brief")

$first"
    if [[ $template == review.md ]]; then
      grep -qxF "$first." "$brief"
    else
      grep -qxF "$first, and one an earlier review of this task named needs no new word." "$brief"
    fi
    # The section ends with the dependencies and their rule.
    section=$(sed -n '/^## Tests and dependencies$/,/^## [^T]/p' "$brief" | sed '$d')
    [[ $section == *"$first"*"

$(deps "$brief")

$rule" ]]
  done
  assert_contains "$(dropped "$TEAM_HOME/tasks/T12/brief-review.md")" '- `tests/a.bats`: `one`, removed'
}

@test "--help documents dropped_tests and dependencies beside instruction_files" {
  run_bin -0 team-brief --help
  assert_contains "$output" "dropped_tests, in the same templates, is derived the same way and never set:"
  assert_contains "$output" "dependencies, in the same templates, is derived the same way and never set:"
  assert_contains "$output" "a --set of a task fact, of instruction_files, of dropped_tests or of
dependencies, and an existing brief without --force."
}
