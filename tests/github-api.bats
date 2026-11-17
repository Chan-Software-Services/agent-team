#!/usr/bin/env bats
# bin/lib/github-api.sh: the one reader of GitHub's REST answers. Each test runs the library's
# functions from a script that sources team.sh and the library, as team-ci-wait does, against a
# stub gh that answers in gh api -i's form (tests/helpers/github-api.bash) from a plan of answers
# by endpoint, on the stub's clock; it checks what a caller sees: the return code, GH_STATUS and
# the limit's variables, the body and error files, the state files and the requests gh received.

load helpers/common
load helpers/github-api

ep=repos/owner/proj/pulls/217

setup() {
  sandbox
  github_stub_setup
  export TZ=UTC
  state=$HOME/.local/state/agent-team/github
  out=$BATS_TEST_TMPDIR/out
  mkdir -p "$out"
  : >"$GITHUB_STUB/plan"
  reader=$(shared github-api-reader <<EOF
#!/usr/bin/env bash
# reader <dir> <function> [<argument>...]: runs one function of the library, then prints its
# return code, GH_STATUS and the limit's variables as one last line.
set -euo pipefail
source "$REPO_ROOT/bin/lib/team.sh"
# shellcheck source=bin/lib/github-api.sh
source "$REPO_ROOT/bin/lib/github-api.sh"
rc=0
"\$@" || rc=\$?
echo "rc=\$rc status=\${GH_STATUS-} until=\${GH_LIMIT_UNTIL-} resource=\${GH_LIMIT_RESOURCE-} kind=\${GH_LIMIT_KIND-}"
EOF
  )
  # gh answers each gh api call from the plan's latest line for its endpoint.
  stub_script gh <<'EOF'
source "$GITHUB_STUB_HELPER"
github_request "$@"
[[ $GITHUB_ENDPOINT != rate_limit ]] || github_rate_limit
[[ ! -e $GITHUB_STUB/delay ]] || command sleep "$(<"$GITHUB_STUB/delay")"
line=$(awk -F '\t' -v e="$GITHUB_ENDPOINT" '$1 == e {l = $0} END {print l}' "$GITHUB_STUB/plan")
[[ -n $line ]] || { echo "no answer planned for gh $*" >&2; exit 1; }
IFS=$'\t' read -r _ what body resource <<<"$line"
case $what in
  primary | message-403 | message-429 | message-primary | message-primary-bare) github_limited "$what" ;;
  retry-after:*) github_limited retry-after "${what#*:}" ;;
  offline) github_offline ;;
  *) github_answer "$what" "$body" "${resource:-core}" ;;
esac
EOF
}

# Let bats remove what a test made read-only.
teardown() {
  [[ ! -d ${state:-} ]] || chmod -R u+w "$state"
}

# plan <endpoint> <answer> [<body> [<resource>]]: from now on gh answers <endpoint> with <answer>:
# an HTTP status with <body>, a refusal (primary, retry-after:<seconds>, message-403, message-429,
# message-primary, message-primary-bare) or offline.
plan() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}" >>"$GITHUB_STUB/plan"
}

# api <function> [<argument>...]: run one function of the library, its last line its report.
api() {
  run_reader -0 "$@"
}

run_reader() {
  local opts=()
  while [[ $1 == -* ]]; do opts+=("$1"); shift; done
  guard_sandbox
  run "${opts[@]}" "$reader" "$@"
}

# read_ep [<endpoint> [<fresh seconds>]]: gh_read of <endpoint> (default the PR) into $out/body.
read_ep() {
  api gh_read "$out" body "${1:-$ep}" ${2:+"$2"}
}

now() { github_now; }
tick() { github_clock $(($(now) + $1)); }
key() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
calls_log() { cat "$state"/calls-*.jsonl; }

@test "a fresh entry is served with no request and no log line" {
  plan "$ep" 200 '{"number":217}'
  read_ep
  assert_equal "$output" "rc=0 status=200 until= resource= kind="
  assert_equal "$(cat "$out/body")" '{"number":217}'
  tick 19
  rm "$out/body"
  read_ep
  assert_equal "$output" "rc=0 status=200 until= resource= kind="
  assert_equal "$(cat "$out/body")" '{"number":217}'
  assert_equal "$(github_requests)" "$ep 200"
  assert_equal "$(calls_log | wc -l)" 1
  # A caller's own fresh seconds win over the default.
  read_ep "$ep" 10
  assert_equal "$(github_requests | wc -l)" 2
}

@test "a stale entry is revalidated with its ETag and served from a 304, logged uncounted" {
  plan "$ep" 200 '{"number":217}'
  read_ep
  etag=$(jq -r .etag "$state/cache/$(key "$ep").json")
  [[ $etag == W/* ]]
  tick 20
  rm "$out/body"
  read_ep
  assert_equal "$output" "rc=0 status=200 until= resource= kind="
  assert_equal "$(cat "$out/body")" '{"number":217}'
  assert_equal "$(github_requests)" "$ep 200
$ep 304"
  assert_equal "$(stub_calls gh | tail -1)" "$(jq -cn --arg e "$ep" --arg t "If-None-Match: $etag" '["api", "-i", "-H", $t, $e]')"
  assert_equal "$(jq -r .fetched "$state/cache/$(key "$ep").json")" "$(now)"
  assert_equal "$(calls_log | jq -c '[.method, .endpoint, .status, .resource, .used, .counted]')" \
    "[\"GET\",\"$ep\",200,\"core\",1,true]
[\"GET\",\"$ep\",304,\"core\",1,false]"
  # The 304 left the budget's use where it was.
  assert_equal "$(jq -c '.core | [.used, .remaining]' "$state/budget.json")" '[1,4999]'
}

@test "a changed answer is stored and served, and the log cuts the query" {
  e="repos/owner/proj/actions/runs?status=in_progress&per_page=1"
  plan "$e" 200 '{"total_count":1}'
  GH_BY=team-ci-wait GH_FOR='owner/proj#217' api gh_read "$out" runs "$e"
  plan "$e" 200 '{"total_count":2}'
  tick 30
  api gh_read "$out" runs "$e"
  assert_equal "$(cat "$out/runs")" '{"total_count":2}'
  assert_equal "$(github_requests)" "$e 200
$e 200"
  assert_equal "$(jq -c '[.endpoint, .fetched, .status, (.etag | startswith("W/"))]' "$state/cache/$(key "$e").json")" \
    "[\"$e\",$(now),200,true]"
  assert_equal "$(cat "$state/cache/$(key "$e").body")" '{"total_count":2}'
  assert_equal "$(calls_log | jq -c '[.by, .for, .endpoint]')" '["team-ci-wait","owner/proj#217","repos/owner/proj/actions/runs"]
["github-api-reader",null,"repos/owner/proj/actions/runs"]'
  assert_equal "$(calls_log | jq -r .at | tail -1)" "$(date -u -d "@$(now)" +%Y-%m-%dT%H:%M:%SZ)"
}

@test "four readers started at once on one endpoint make one request among them" {
  plan "$ep" 200 '{"number":217}'
  echo 1 >"$GITHUB_STUB/delay"
  guard_sandbox
  pids=()
  for i in 1 2 3 4; do
    mkdir "$out/$i"
    "$reader" gh_read "$out/$i" body "$ep" >"$out/$i/report" 2>&1 &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  for i in 1 2 3 4; do
    assert_equal "$(cat "$out/$i/report")" "rc=0 status=200 until= resource= kind="
    assert_equal "$(cat "$out/$i/body")" '{"number":217}'
  done
  assert_equal "$(github_requests)" "$ep 200"
}

@test "a reader that waited on the lock of an entry another's write left stopped partway reads again, never serving the old body" {
  plan "$ep" 200 '{"number":217,"head":"A"}'
  read_ep
  tick 60
  plan "$ep" 200 '{"number":217,"head":"B"}'
  lock=$state/cache/$(key "$ep").lock
  guard_sandbox
  # Another reader holds the entry's lock until the test releases it.
  # shellcheck disable=SC2016
  bash -c 'exec 9>>"$1" && flock -n 9 && : >"$2/held" &&
    while [[ ! -e $2/release ]]; do sleep 0.05; done' _ "$lock" "$out" >/dev/null 2>&1 3>&- &
  holder=$!
  while [[ ! -e $out/held ]]; do kill -0 "$holder"; sleep 0.05; done
  "$reader" gh_read "$out" body "$ep" >"$out/report" 2>&1 3>&- &
  waiter=$!
  # The waiter has read the entry's fetched and blocks on the lock.
  until pgrep -P "$waiter" -x flock >/dev/null; do kill -0 "$waiter"; sleep 0.05; done
  # What the other's write leaves when it stops after its first step: no ETag, fetched 0.
  jq -cn --arg e "$ep" '{endpoint: $e, etag: null, fetched: 0, status: 200}' >"$state/cache/$(key "$ep").json"
  : >"$out/release"
  wait "$holder"
  wait "$waiter"
  assert_equal "$(cat "$out/report")" "rc=0 status=200 until= resource= kind="
  assert_equal "$(cat "$out/body")" '{"number":217,"head":"B"}'
  assert_equal "$(github_requests)" "$ep 200
$ep 200"
}

@test "a primary refusal writes limit.json, and no read is sent until the clock passes its until" {
  reset=$(($(now) + 600))
  github_budget core 5000 5000 "$reset"
  plan "$ep" primary
  read_ep
  assert_equal "$output" "rc=3 status=403 until=$reset resource=core kind=primary"
  assert_equal "$(cat "$out/error")" "GitHub's API rate limit for core requests is used up until $(date -d "@$reset" +%H:%M), when it resets; this is no outage"
  assert_equal "$(jq -c . "$state/limit.json")" \
    "{\"resource\":\"core\",\"kind\":\"primary\",\"until\":$reset,\"seen\":$(now),\"by\":\"github-api-reader\",\"endpoint\":\"$ep\"}"
  assert_equal "$(calls_log | jq -c '[.status, .counted]')" '[403,false]'
  assert_equal "$(jq -c '.core | [.remaining, .reset]' "$state/budget.json")" "[0,$reset]"
  # Another endpoint, and the same, read nothing while it stands, its until included.
  plan repos/owner/proj/pulls/218 200 '{"number":218}'
  api gh_read "$out" other repos/owner/proj/pulls/218
  assert_equal "$output" "rc=3 status= until=$reset resource=core kind=primary"
  github_clock $((reset - 1))
  read_ep
  assert_equal "${output%% *}" rc=3
  assert_equal "$(github_requests)" "$ep 403"
  # Past it, the read goes, and its success lifts the limit.
  github_clock "$reset"
  github_budget core 5000 0 $((reset + 3600))
  plan "$ep" 200 '{"number":217}'
  read_ep
  assert_equal "$output" "rc=0 status=200 until= resource= kind="
  [[ ! -e $state/limit.json ]]
  api gh_limited
  assert_equal "$output" "rc=1 status= until= resource= kind="
}

@test "a secondary refusal stands for every resource: Retry-After's seconds, else 60" {
  plan "$ep" retry-after:45
  read_ep
  assert_equal "$output" "rc=3 status=403 until=$(($(now) + 45)) resource=all kind=secondary"
  assert_equal "$(cat "$out/error")" "GitHub's secondary rate limit holds the team's requests until $(date -d "@$(($(now) + 45))" +%H:%M); this is no outage"
  assert_equal "$(jq -c '[.resource, .kind]' "$state/limit.json")" '["all","secondary"]'
  api gh_limited graphql
  assert_equal "${lines[0]}" $(($(now) + 45))
  rm "$state/limit.json"
  plan "$ep" message-403
  read_ep
  assert_equal "$output" "rc=3 status=403 until=$(($(now) + 60)) resource=all kind=secondary"
  rm "$state/limit.json"
  plan "$ep" message-429
  read_ep
  assert_equal "$output" "rc=3 status=429 until=$(($(now) + 60)) resource=all kind=secondary"
  assert_equal "$(calls_log | jq -c '[.status, .counted]' | sort -u)" '[403,false]
[429,false]'
}

@test "a refusal whose message alone names the primary limit holds until its X-RateLimit-Reset, else 60 s" {
  reset=$(($(now) + 900))
  github_budget core 5000 4000 "$reset"
  plan "$ep" message-primary
  read_ep
  assert_equal "$output" "rc=3 status=403 until=$reset resource=core kind=primary"
  assert_equal "$(cat "$out/error")" "GitHub's API rate limit for core requests is used up until $(date -d "@$reset" +%H:%M), when it resets; this is no outage"
  assert_equal "$(jq -c '[.resource, .kind, .until]' "$state/limit.json")" "[\"core\",\"primary\",$reset]"
  rm "$state/limit.json"
  plan "$ep" message-primary-bare
  read_ep
  assert_equal "$output" "rc=3 status=403 until=$(($(now) + 60)) resource=core kind=primary"
  assert_equal "$(jq -c '[.resource, .kind, .until]' "$state/limit.json")" "[\"core\",\"primary\",$(($(now) + 60))]"
  assert_equal "$(calls_log | jq -c '[.status, .counted]' | sort -u)" '[403,false]'
}

@test "a 403 for a permission, a 404 and a connection failure are plain failures with GH_STATUS" {
  plan "$ep" 403 '{"message":"Resource not accessible by integration"}'
  read_ep
  assert_equal "$output" "rc=1 status=403 until= resource= kind="
  assert_equal "$(cat "$out/error")" "gh api $ep: gh: Resource not accessible by integration (HTTP 403)"
  [[ ! -e $state/limit.json ]]
  e="repos/owner/proj/branches/feat%2Fgone"
  plan "$e" 404 '{"message":"Branch not found"}'
  api gh_read "$out" branch "$e"
  assert_equal "$output" "rc=1 status=404 until= resource= kind="
  assert_equal "$(cat "$out/error")" "gh api $e: gh: Branch not found (HTTP 404)"
  plan "$ep" offline
  tick 60
  read_ep
  assert_equal "$output" "rc=1 status= until= resource= kind="
  assert_equal "$(cat "$out/error")" "gh api $ep: error connecting to api.github.com"
  # GitHub counts nothing for a request it never answered.
  assert_equal "$(calls_log | jq -c '[.status, .counted]')" '[403,true]
[404,true]
[null,false]'
  # A failure stored nothing to serve.
  [[ ! -e $state/cache/$(key "$e").body ]]
}

@test "budget.json keeps the latest reading of each resource from the answers' headers" {
  github_budget core 5000 1200 1795003000
  github_budget graphql 5000 300 1795002000
  plan "$ep" 200 '{"number":217}'
  plan repos/owner/proj/other 200 '{}' graphql
  read_ep
  tick 5
  api gh_read "$out" other repos/owner/proj/other
  assert_equal "$(jq -c . "$state/budget.json")" \
    "{\"core\":{\"limit\":5000,\"remaining\":3799,\"used\":1201,\"reset\":1795003000,\"at\":$(($(now) - 5))},\"graphql\":{\"limit\":5000,\"remaining\":4699,\"used\":301,\"reset\":1795002000,\"at\":$(now)}}"
}

# budget <resource> <limit> <remaining> <reset>: budget.json's entry, as a reading writes it.
budget() {
  mkdir -p "$state"
  [[ -e $state/budget.json ]] || echo '{}' >"$state/budget.json"
  jq -c --arg r "$1" --argjson l "$2" --argjson rem "$3" --argjson reset "$4" \
    '.[$r] = {limit: $l, remaining: $rem, used: ($l - $rem), reset: $reset, at: 0}' "$state/budget.json" >"$state/b"
  mv "$state/b" "$state/budget.json"
}

@test "gh_interval lengthens the base as the budget falls, until its reset" {
  api gh_interval 30
  assert_equal "${lines[0]}" 30
  later=$(($(now) + 1800))
  for pair in 5000:30 2500:30 2499:60 1250:60 1249:120 500:120 499:300 0:300; do
    budget core 5000 "${pair%%:*}" "$later"
    api gh_interval 30
    assert_equal "${pair%%:*} ${lines[0]}" "${pair%%:*} ${pair#*:}"
  done
  api gh_interval 600
  assert_equal "${lines[0]}" 600
  api gh_interval 10 core
  assert_equal "${lines[0]}" 300
  # Each resource asked for counts, and only those.
  budget core 5000 5000 "$later"
  budget graphql 5000 100 "$later"
  api gh_interval 30
  assert_equal "${lines[0]}" 30
  api gh_interval 30 core graphql
  assert_equal "${lines[0]}" 300
  # A reading whose reset has passed says nothing of the budget now.
  github_clock "$later"
  api gh_interval 30 core graphql
  assert_equal "${lines[0]}" 30
}

@test "gh_call takes a limit from gh's text and gh api rate_limit's reset of the used-up resource" {
  reset=$(($(now) + 900))
  github_budget core 5000 5000 "$reset"
  stub_script gh <<'EOF'
source "$GITHUB_STUB_HELPER"
github_request "$@"
[[ $GITHUB_ENDPOINT != rate_limit ]] || github_rate_limit
echo "could not create workflow dispatch event: HTTP 403: API rate limit exceeded for user ID 1." >&2
exit 1
EOF
  api gh_call "$out" dispatch workflow run ci.yml --repo owner/proj --ref feat/x
  assert_equal "$output" "rc=3 status= until=$reset resource=core kind=primary"
  assert_equal "$(cat "$out/error")" "GitHub's API rate limit for core requests is used up until $(date -d "@$reset" +%H:%M), when it resets; this is no outage"
  assert_equal "$(jq -c '[.resource, .kind, .until, .endpoint]' "$state/limit.json")" "[\"core\",\"primary\",$reset,\"workflow run\"]"
  assert_equal "$(jq -c '.core | [.remaining, .reset]' "$state/budget.json")" "[0,$reset]"
  assert_equal "$(calls_log | jq -c '[.method, .endpoint, .counted]')" '[null,"workflow run",false]
["GET","rate_limit",false]'
  # While it stands, gh_call sends nothing.
  calls_before=$(stub_calls gh | wc -l)
  api gh_call "$out" dispatch workflow run ci.yml --repo owner/proj --ref feat/x
  assert_equal "$output" "rc=3 status= until=$reset resource=core kind=primary"
  assert_equal "$(stub_calls gh | wc -l)" "$calls_before"
}

@test "gh_call: a GraphQL RATE_LIMITED error limits graphql alone, and a limit the reading cannot place is secondary" {
  reset=$(($(now) + 1200))
  github_budget graphql 5000 5000 "$reset"
  stub_script gh <<'EOF'
source "$GITHUB_STUB_HELPER"
github_request "$@"
[[ $GITHUB_ENDPOINT != rate_limit ]] || github_rate_limit
[[ $GITHUB_ENDPOINT != graphql ]] || { echo '{"errors":[{"type":"RATE_LIMITED","message":"API rate limit already exceeded for user ID 1."}]}'; echo 'gh: API rate limit already exceeded for user ID 1.' >&2; exit 1; }
github_answer 200 '{"number":217}'
EOF
  api gh_call "$out" queue api graphql -f query='{ viewer { login } }'
  assert_equal "$output" "rc=3 status= until=$reset resource=graphql kind=primary"
  assert_equal "$(cat "$out/error")" "GitHub's API rate limit for GraphQL points is used up until $(date -d "@$reset" +%H:%M), when it resets; this is no outage"
  assert_equal "$(calls_log | head -1 | jq -c '[.method, .endpoint, .resource]')" '["POST","graphql","graphql"]'
  # REST reads still go.
  read_ep
  assert_equal "$output" "rc=0 status=200 until= resource= kind="
  api gh_call "$out" queue api graphql -f query='{ viewer { login } }'
  assert_equal "${output%% *}" rc=3
  assert_equal "$(stub_calls gh | jq -r '.[1]' | grep -c graphql)" 1
  # No resource used up: a secondary limit of 60 s.
  rm "$state/limit.json"
  github_budget graphql 5000 10 "$reset"
  api gh_call "$out" queue api graphql -f query='{ viewer { login } }'
  assert_equal "$output" "rc=3 status= until=$(($(now) + 60)) resource=all kind=secondary"
}

@test "gh_call keeps gh's stdout, logs its endpoint, and writes a plain failure as github() does" {
  stub_script gh <<'EOF'
case $* in
  "api --paginate repos/owner/proj/commits/abc/check-runs?per_page=100") echo '{"total_count":0}' ;;
  "workflow run ci.yml --repo owner/proj --ref feat/x") echo "could not create workflow dispatch event: HTTP 422: Workflow does not have 'workflow_dispatch' trigger" >&2; exit 1 ;;
  *) echo "unplanned gh $*" >&2; exit 1 ;;
esac
EOF
  api gh_call "$out" checks api --paginate "repos/owner/proj/commits/abc/check-runs?per_page=100"
  assert_equal "$output" "rc=0 status=200 until= resource= kind="
  assert_equal "$(cat "$out/checks")" '{"total_count":0}'
  api gh_call "$out" dispatch workflow run ci.yml --repo owner/proj --ref feat/x
  assert_equal "$output" "rc=1 status= until= resource= kind="
  assert_equal "$(cat "$out/error")" "gh workflow run: could not create workflow dispatch event: HTTP 422: Workflow does not have 'workflow_dispatch' trigger"
  [[ ! -e $state/limit.json ]]
  assert_equal "$(calls_log | jq -c '[.method, .endpoint, .status, .resource, .counted]')" '["GET","repos/owner/proj/commits/abc/check-runs",200,"core",true]
[null,"workflow run",null,"core",true]'
}

@test "gh_call: a failed REST read whose stdout says rate limit, and whose stderr does not, is a plain failure" {
  stub_script gh <<'STUB'
echo '{"total_count":101,"check_runs":[{"name":"rate limit guard","output":{"title":"API rate limit exceeded test"}}]}'
echo 'gh: Server Error (HTTP 502)' >&2
exit 1
STUB
  api gh_call "$out" checks api --paginate "repos/owner/proj/commits/abc/check-runs?per_page=100"
  assert_equal "$output" "rc=1 status=502 until= resource= kind="
  assert_equal "$(cat "$out/error")" "gh api --paginate: gh: Server Error (HTTP 502)"
  [[ ! -e $state/limit.json ]]
}

@test "gh_spenders counts each command's counted requests of one resource since a time, with their subjects" {
  mkdir -p "$state"
  day=$(date -u -d "@$(now)" +%F)
  at() { date -u -d "@$(($(now) - $1))" +%Y-%m-%dT%H:%M:%SZ; }
  {
    jq -cn --arg at "$(at 100)" '{at: $at, by: "team-ci-wait", for: "owner/proj#1", resource: "core", counted: true}'
    jq -cn --arg at "$(at 90)" '{at: $at, by: "team-ci-wait", for: "owner/proj#2", resource: "core", counted: true}'
    jq -cn --arg at "$(at 80)" '{at: $at, by: "team-ci-wait", for: "owner/proj#2", resource: "core", counted: true}'
    jq -cn --arg at "$(at 70)" '{at: $at, by: "team-ci-wait", for: "owner/proj#2", resource: "core", counted: false}'
    jq -cn --arg at "$(at 60)" '{at: $at, by: "team-ci-run", for: "owner/proj feat/x", resource: "core", counted: true}'
    jq -cn --arg at "$(at 50)" '{at: $at, by: "team-ci-run", for: "owner/proj feat/x", resource: "core", counted: true}'
    jq -cn --arg at "$(at 40)" '{at: $at, by: "team-next", for: null, resource: "core", counted: true}'
    jq -cn --arg at "$(at 40)" '{at: $at, by: "team-land", for: null, resource: "graphql", counted: true}'
    jq -cn --arg at "$(at 5000)" '{at: $at, by: "team-next", for: null, resource: "core", counted: true}'
  } >"$state/calls-$day.jsonl"
  api gh_spenders core $(($(now) - 3600))
  assert_equal "${lines[0]}" '[{"by":"team-ci-wait","calls":3,"subjects":["owner/proj#1","owner/proj#2"]},{"by":"team-ci-run","calls":2,"subjects":["owner/proj feat/x"]},{"by":"team-next","calls":1,"subjects":[]}]'
  api gh_spenders graphql 0
  assert_equal "${lines[0]}" '[{"by":"team-land","calls":1,"subjects":[]}]'
  rm "$state/calls-$day.jsonl"
  api gh_spenders core 0
  assert_equal "${lines[0]}" '[]'
}

@test "the request that starts a day's log prunes the logs of days more than 2 back and the entries fetched a day ago" {
  mkdir -p "$state/cache"
  day() { date -u -d "@$(($(now) - $1 * 86400))" +%F; }
  for d in 1 2 3 4; do echo '{}' >"$state/calls-$(day "$d").jsonl"; done
  for age in 90000 3600; do
    echo "{\"endpoint\":\"e$age\",\"etag\":null,\"fetched\":$(($(now) - age)),\"status\":200}" >"$state/cache/e$age.json"
    echo '{}' >"$state/cache/e$age.body"
    : >"$state/cache/e$age.lock"
  done
  plan "$ep" 200 '{"number":217}'
  read_ep
  [[ -e $state/calls-$(day 0).jsonl && -e $state/calls-$(day 1).jsonl && -e $state/calls-$(day 2).jsonl ]]
  [[ ! -e $state/calls-$(day 3).jsonl && ! -e $state/calls-$(day 4).jsonl ]]
  [[ ! -e $state/cache/e90000.json && ! -e $state/cache/e90000.body && ! -e $state/cache/e90000.lock ]]
  [[ -e $state/cache/e3600.json && -e $state/cache/e3600.body ]]
  # Later requests of the day prune nothing.
  echo '{}' >"$state/calls-$(day 5).jsonl"
  plan repos/owner/proj/pulls/218 200 '{}'
  api gh_read "$out" other repos/owner/proj/pulls/218
  [[ -e $state/calls-$(day 5).jsonl ]]
}

@test "the day's first request also prunes the temporary files a killed writer left more than a day ago" {
  mkdir -p "$state/cache"
  for f in cache/k.json.Ab12Cd cache/k.body.Ef34Gh budget.json.Ij56Kl limit.json.Mn78Op; do
    : >"$state/$f"
    touch -d "@$(($(now) - 90000))" "$state/$f"
  done
  : >"$state/cache/n.json.Qr90St"
  touch -d "@$(($(now) - 3600))" "$state/cache/n.json.Qr90St"
  plan "$ep" 200 '{"number":217}'
  read_ep
  [[ ! -e $state/cache/k.json.Ab12Cd && ! -e $state/cache/k.body.Ef34Gh && ! -e $state/budget.json.Ij56Kl && ! -e $state/limit.json.Mn78Op ]]
  [[ -e $state/cache/n.json.Qr90St ]]
}

@test "a state directory that cannot be written reads GitHub direct, never failing the read" {
  # The cache read-only: an endpoint with no entry is read and served with no entry kept, and an
  # entry whose 304 cannot be marked fetched is served all the same.
  plan repos/owner/proj/pulls/218 200 '{"number":218}'
  api gh_read "$out" other repos/owner/proj/pulls/218
  tick 60
  chmod 555 "$state/cache"
  plan "$ep" 200 '{"number":217}'
  read_ep
  assert_equal "$output" "rc=0 status=200 until= resource= kind="
  assert_equal "$(cat "$out/body")" '{"number":217}'
  [[ ! -e $state/cache/$(key "$ep").json ]]
  api gh_read "$out" other repos/owner/proj/pulls/218
  assert_equal "$output" "rc=0 status=200 until= resource= kind="
  assert_equal "$(cat "$out/other")" '{"number":218}'
  assert_equal "$(github_requests | tail -2)" "$ep 200
repos/owner/proj/pulls/218 304"
  chmod 755 "$state/cache"
  # No state directory can be made, a file in its place: a plain read, with no ETag.
  mv "$state" "$BATS_TEST_TMPDIR/state-aside"
  echo 'not a directory' >"$state"
  read_ep
  assert_equal "$output" "rc=0 status=200 until= resource= kind="
  assert_equal "$(cat "$out/body")" '{"number":217}'
  assert_equal "$(stub_calls gh | tail -1)" "$(jq -cn --arg e "$ep" '["api", "-i", $e]')"
  # A refusal for the limit is still told, though nothing can hold it.
  github_budget core 5000 5000
  plan "$ep" primary
  read_ep
  assert_equal "${output%% *}" rc=3
}

@test "gh_limit_text words each limit in local time, and gh_limited names the limit standing for a resource" {
  api gh_limit_text 1795002420 core primary
  assert_equal "${lines[0]}" "GitHub's API rate limit for core requests is used up until 11:47, when it resets; this is no outage"
  TZ=XST+8 api gh_limit_text 1795002420 graphql primary
  assert_equal "${lines[0]}" "GitHub's API rate limit for GraphQL points is used up until 03:47, when it resets; this is no outage"
  api gh_limit_text 1795002420 all secondary
  assert_equal "${lines[0]}" "GitHub's secondary rate limit holds the team's requests until 11:47; this is no outage"
  mkdir -p "$state"
  echo "{\"resource\":\"graphql\",\"kind\":\"primary\",\"until\":$(($(now) + 60)),\"seen\":$(now),\"by\":\"x\",\"endpoint\":\"graphql\"}" >"$state/limit.json"
  run_reader -0 gh_limited
  assert_equal "$output" "rc=1 status= until= resource= kind="
  api gh_limited core graphql
  assert_equal "${lines[0]}" $(($(now) + 60))
}
