#!/usr/bin/env bats
# team-timers' github step: on the holder after the quota step, gh api rate_limit (which GitHub
# does not count), its core and graphql written to bin/lib/github-api.sh's budget.json, and each of
# them past 70% or 90% of its hour's limit a notice of the github source (bin/lib/notice.jq), posted
# once to #coordinator with the top spenders of the reader's call log and what no log accounts for,
# and closed with no post once its reset passes. The heartbeat suite's setup, as
# team-timers-quota.bats has it: home-pc holds the lease on a bare origin, the stub claude lists the
# coordinator and the assistant, and Discord is the inbox helper's fake. GitHub is
# helpers/github-api.bash's stub on its own clock, which the step reads as now.

load helpers/common
load helpers/inbox
load helpers/github-api

setup() {
  sandbox
  cp "$BATS_TEST_DIRNAME/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  stub_reply claude '[{"id": "c0ffee00", "name": "coordinator", "status": "idle"}, {"id": "a5515700", "name": "assistant", "status": "idle"}]'
  hold_lease home-pc >/dev/null
  fake_service_managers
  stub_command uname
  stub_reply uname Linux
  state=$HOME/.local/state/agent-team
  log=$state/heartbeat.log
  github=$state/github
  inbox_discord alerts
  inbox_guild_kept
  # GitHub's answers: its rate_limit reading of the planned budgets, and nothing else.
  github_heartbeat_stub
  # The posts' times are this machine's local time: a zone off UTC by a half hour shows it.
  export TZ=Asia/Kolkata
  export TEAM_TIMERS_RUN_SECONDS=120
  now=$(github_now)
  reset=$((now + 1800))
}

# The texts of the alerts the fake Discord was sent, one per line, in order.
alerts_posted() {
  local id
  [[ -f $STUB_FIXTURES/inbox/alerts ]] || return 0
  while read -r id; do jq -r .content "$STUB_FIXTURES/inbox/$id.json"; done <"$STUB_FIXTURES/inbox/alerts"
}

# The github notices the record holds, their keys sorted.
github_keys() {
  jq -c '[.notices[] | select(.source == "github") | .key] | sort' "$state/notices.json"
}

# An epoch time as the notice keys write it, and as the posts show it.
utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
local_clock() { date -d "@$1" +%H:%M; }

# One line of the reader's call log: logged <seconds before now> <by> <for or ""> <resource>
# [<counted>], in the day's file of its time, as bin/lib/github-api.sh's gh_log writes it, in
# $github, the owner login's state unless the call sets it to another login's.
logged() {
  local at=$((now - $1))
  mkdir -p "$github"
  jq -cn --arg at "$(utc "$at")" --arg by "$2" --arg for "$3" --arg r "$4" --argjson counted "${5:-true}" \
    '{at: $at, by: $by, for: (if $for == "" then null else $for end), method: "GET", endpoint: "repos/owner/proj/pulls/1",
      status: 200, resource: $r, used: null, counted: $counted}' >>"$github/calls-$(date -u -d "@$at" +%F).jsonl"
}

# The calls the stub gh received, as its arguments joined by spaces, one per line.
gh_calls() {
  [[ -f $STUB_CALLS/gh.log ]] || return 0
  jq -r 'join(" ")' "$STUB_CALLS/gh.log"
}

@test "notice.jq's table has the github source: its open post retried, no end action, never reminded" {
  run -0 jq -cn -L "$REPO_ROOT/bin/lib" 'include "notice"; notice_sources.github'
  assert_equal "$output" '{"retry_open":true,"end":null,"unposted_end":false,"retry_end":false}'
}

@test "health.jq's steps have github after quota, before inbox" {
  run -0 jq -cn -L "$REPO_ROOT/bin/lib" 'include "health"; health_steps | .[index("quota"):index("inbox") + 1]'
  assert_equal "$output" '["quota","github","inbox"]'
}

@test "a reading under 70% writes budget.json, posts nothing, logs nothing and passes" {
  github_budget core 5000 3400 "$reset"
  github_budget graphql 5000 10 "$reset"
  run_bin -0 team-timers run
  assert_equal "$(gh_calls)" "api rate_limit"
  assert_equal "$(alerts_posted)" ""
  run grep ' github: ' "$log"
  assert_equal "$status" 1
  jq -e --argjson reset "$reset" --argjson now "$now" '
    .core == {limit: 5000, remaining: 1600, used: 3400, reset: $reset, at: $now}
    and .graphql == {limit: 5000, remaining: 4990, used: 10, reset: $reset, at: $now}' "$github/budget.json"
}

@test "core past 70% posts once with its local reset, the top three spenders with their subjects counted, and the rest not logged" {
  github_budget core 5000 3600 "$reset"
  logged 600 team-ci-wait owner/proj#1 core
  logged 500 team-ci-wait owner/proj#2 core
  logged 400 team-ci-wait owner/proj#2 core
  logged 300 team-ci-run "owner/proj fix/a" core
  logged 200 team-ci-run "owner/proj fix/a" core
  logged 100 team-next "" core
  # A fourth with as many calls as the third, which a tie puts after it by name.
  logged 90 team-state owner/proj#3 core
  # Uncounted, another resource, and before the hour's window: none of them is spent here.
  logged 80 team-ci-wait owner/proj#4 core false
  logged 70 team-ci-wait owner/proj#5 graphql
  logged 4000 team-ci-wait owner/proj#6 core
  run_bin -0 team-timers run
  local key text
  key=core/70/$(utc "$reset")
  text="GitHub's API: core requests at 72% of 5,000 for the hour, past 70%; it resets at $(local_clock "$reset"). Most: team-ci-wait 3 (2), team-ci-run 2 (1), team-next 1 (0); 3,593 not logged (workers' own gh and other scripts)."
  assert_equal "$(alerts_posted)" "$text"
  assert_equal "$(github_keys)" "[\"$key\"]"
  grep -E "^[0-9T:-]+Z github: $key: posted to #coordinator \(message [0-9]+\)$" "$log"
  jq -e '.allowed_mentions == {parse: []}' "$STUB_FIXTURES/inbox/$(head -n 1 "$STUB_FIXTURES/inbox/alerts").json"

  # The same window at a higher reading below 90% posts nothing more.
  github_budget core 5000 4000 "$reset"
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" "$text"
}

@test "past 90% in the same window posts again, a lower reading after posts nothing, and the reset closes both with no post" {
  github_budget core 5000 3600 "$reset"
  run_bin -0 team-timers run
  github_budget core 5000 4600 "$reset"
  run_bin -0 team-timers run
  local at
  at=$(local_clock "$reset")
  assert_equal "$(alerts_posted)" "GitHub's API: core requests at 72% of 5,000 for the hour, past 70%; it resets at $at. 3,600 not logged (workers' own gh and other scripts).
GitHub's API: core requests at 92% of 5,000 for the hour, past 90%; it resets at $at. 4,600 not logged (workers' own gh and other scripts)."
  assert_equal "$(github_keys)" "[\"core/70/$(utc "$reset")\",\"core/90/$(utc "$reset")\"]"

  # A lower reading of the same window, as a later one never is but a stale one may be.
  github_budget core 5000 3700 "$reset"
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted | wc -l)" 2

  # The reset passes: the new hour reads low, and both notices close with no post.
  github_clock $((reset + 1))
  now=$((reset + 1))
  github_budget core 5000 100 $((now + 3600))
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted | wc -l)" 2
  assert_equal "$(github_keys)" "[]"
  grep -E "github: core/70/$(utc "$reset"): closed with no post \(its window reset\)$" "$log"
  grep -E "github: core/90/$(utc "$reset"): closed with no post \(its window reset\)$" "$log"
  assert_equal "$(grep -c '^PATCH ' "$STUB_FIXTURES/inbox/calls" || true)" 0
}

@test "a first reading already past 90% posts that one crossing alone, GraphQL points worded so, the rest left out when 0" {
  github_budget graphql 10 10 "$reset"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do logged "$((i * 10))" team-ci-run "owner/proj fix/b" graphql; done
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" "GitHub's API: GraphQL points at 100% of 10 for the hour, past 90%; it resets at $(local_clock "$reset"). Most: team-ci-run 10 (1)."
  assert_equal "$(github_keys)" "[\"graphql/90/$(utc "$reset")\"]"
}

@test "a crossing whose post failed is dropped with no post once a higher one of its window is wanted" {
  github_budget core 5000 3600 "$reset"
  echo "1 503" >"$STUB_FIXTURES/inbox/fail-post"
  run_bin -0 team-timers run
  rm "$STUB_FIXTURES/inbox/fail-post"
  github_budget core 5000 4600 "$reset"
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted)" "GitHub's API: core requests at 92% of 5,000 for the hour, past 90%; it resets at $(local_clock "$reset"). 4,600 not logged (workers' own gh and other scripts)."
  assert_equal "$(github_keys)" "[\"core/90/$(utc "$reset")\"]"
  grep -E "github: core/70/$(utc "$reset"): closed with no post \(a higher threshold of its window was crossed before it was posted\)$" "$log"
}

@test "with the worker login on, each login's reading goes to its own budget, and each crossing posts under its own key and spenders" {
  worker_login_on
  local worker=$state/github-worker at
  at=$(local_clock "$reset")
  github_budget core 5000 1000 "$reset"
  github_budget --worker core 5000 3600 "$reset"
  github_budget --worker graphql 5000 10 "$reset"
  logged 300 team-ci-run "owner/proj fix/a" core
  github=$worker logged 200 team-ci-wait owner/proj#1 core
  github=$worker logged 100 team-ci-wait owner/proj#2 core
  run_bin -0 team-timers run
  assert_equal "$(gh_calls)" "api rate_limit
api rate_limit"
  jq -e '.core.used == 1000 and .graphql.used == 0' "$github/budget.json"
  jq -e '.core.used == 3600 and .graphql.used == 10' "$worker/budget.json"
  assert_equal "$(alerts_posted)" "GitHub's API on the worker login team-worker-bot: core requests at 72% of 5,000 for the hour, past 70%; it resets at $at. Most: team-ci-wait 2 (2); 3,598 not logged (workers' own gh and other scripts)."
  assert_equal "$(github_keys)" "[\"worker/core/70/$(utc "$reset")\"]"
  grep -E "github: worker/core/70/$(utc "$reset"): posted to #coordinator \(message [0-9]+\)$" "$log"

  # The owner login crossing the same threshold of the same window is a notice of its own.
  github_budget core 5000 3700 "$reset"
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted | tail -n 1)" "GitHub's API: core requests at 74% of 5,000 for the hour, past 70%; it resets at $at. Most: team-ci-run 1 (1); 3,699 not logged (Daniel's own gh and other scripts)."
  assert_equal "$(github_keys)" "[\"core/70/$(utc "$reset")\",\"worker/core/70/$(utc "$reset")\"]"
  # Neither posts again in its window, and the reset closes both.
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted | wc -l)" 2
  github_clock $((reset + 1))
  now=$((reset + 1))
  github_budget core 5000 0 $((now + 3600))
  github_budget --worker core 5000 0 $((now + 3600))
  run_bin -0 team-timers run
  assert_equal "$(github_keys)" "[]"
  grep -E "github: worker/core/70/$(utc "$reset"): closed with no post \(its window reset\)$" "$log"
  jq -e '.steps | has("github") | not' "$state/health.json"
}

@test "a worker login named but not on this machine, or whose read fails, fails the step, the owner's reading still written and judged" {
  worker_login_on
  rm "$HOME/.config/agent-team/gh-worker/hosts.yml"
  github_budget core 5000 3600 "$reset"
  run_bin -0 team-timers run
  assert_equal "$(gh_calls)" "api rate_limit"
  grep -E "github: failed: the worker login team-worker-bot is not on this machine \(~/.config/agent-team/gh-worker/hosts.yml is missing\)$" "$log"
  jq -e '.core.used == 3600' "$github/budget.json"
  assert_equal "$(github_keys)" "[\"core/70/$(utc "$reset")\"]"
  jq -e '.steps.github.runs == 1' "$state/health.json"

  # Its file back, a read on it that fails is the step failing, named so.
  worker_login_on
  stub_script gh <<'STUB'
source "$GITHUB_STUB_HELPER"
github_request "$@"
[[ -z $(github_account) ]] || github_offline
github_rate_limit
STUB
  run_bin -0 team-timers run
  grep -E "github: failed: gh api rate_limit on the worker login team-worker-bot: error connecting to api.github.com$" "$log"
  [[ ! -e $state/github-worker/budget.json ]]
  jq -e '.steps.github.runs == 2' "$state/health.json"
}

@test "a post Discord refuses fails the step alone, never the run, and is tried again at the next run" {
  github_budget core 5000 3600 "$reset"
  echo "1 503" >"$STUB_FIXTURES/inbox/fail-post"
  run_bin -0 team-timers run
  grep -E "github: core/70/$(utc "$reset"): the post to #coordinator failed \(.*\); it is tried again next run$" "$log"
  grep -E "github: failed: the post of core/70/$(utc "$reset") to #coordinator failed \(.*\)$" "$log"
  jq -e '.steps.github.runs == 1' "$state/health.json"
  rm "$STUB_FIXTURES/inbox/fail-post"
  run_bin -0 team-timers run
  assert_equal "$(alerts_posted | wc -l)" 1
  jq -e '.steps | has("github") | not' "$state/health.json"
}

@test "a failing read is the step failing alone, and 12 runs in a row raise step-github in the health view" {
  stub_script gh <<'EOF'
source "$GITHUB_STUB_HELPER"
github_request "$@"
github_offline
EOF
  run_bin -0 team-timers run
  grep -E "^[0-9T:-]+Z github: failed: gh api rate_limit: error connecting to api.github.com$" "$log"
  [[ ! -e $github/budget.json ]]
  run_bin -1 team-timers health --json
  jq -e '.problems | map(select(.key == "step-github")) | length == 1 and (.[0].text | test("^github failing since .* \\(1 run\\): gh api rate_limit: error connecting to api.github.com$")) and (.[0].alerting | not)' <<<"$output"

  jq '.steps.github.runs = 11' "$state/health.json" >"$state/health.json.new"
  mv "$state/health.json.new" "$state/health.json"
  run_bin -0 team-timers run
  run_bin -1 team-timers health --json
  jq -e 'first(.problems[] | select(.key == "step-github")) | .alerting and (.text | contains("(12 runs)"))' <<<"$output"
  assert_contains "$(alerts_posted)" "The heartbeat's github step has failed 12 runs in a row on home-pc"
}

@test "a read that hangs is stopped after the step's limit, and one that prints no reading fails the step" {
  stub_script gh <<'EOF'
exec 3>&-
exec sleep 30
EOF
  TEAM_TIMERS_GITHUB_SECONDS=1 TEAM_TIMERS_KILL_SECONDS=1 run_bin -0 team-timers run
  grep -E "github: failed: gh api rate_limit timed out after 1 s$" "$log"

  stub_script gh <<'EOF'
echo "not json"
EOF
  run_bin -0 team-timers run
  grep -E "github: failed: gh api rate_limit printed no rate limit reading$" "$log"
}

@test "a notice record it cannot write is the step failing" {
  # A first run moves the old records in, so the next needs the record's lock only to judge.
  run_bin -0 team-timers run
  github_budget core 5000 3600 "$reset"
  # Another writer holds the record's lock past the wait for it.
  (
    exec 9>>"$state/notices.lock"
    flock 9
    exec sleep 30
  ) 3>&- &
  local holder=$! tries=0
  while flock -n "$state/notices.lock" true && ((++tries < 300)); do command -p sleep 0.1; done
  TEAM_NOTICES_LOCK_SECONDS=1 run_bin team-timers run
  kill "$holder"
  wait "$holder" || true
  grep -E "github: failed: cannot judge the github notices in $state/notices.json: another writer held $state/notices.lock for 1 s$" "$log"
  assert_equal "$(alerts_posted)" ""
}

@test "an offline run and one off the lease make no read" {
  github_budget core 5000 4600 "$reset"
  run -0 "$REPO_ROOT/bin/team-lease" release
  run_bin -0 team-timers run
  assert_equal "$(gh_calls)" ""

  run -0 "$REPO_ROOT/bin/team-lease" take
  mkdir -p "$state"
  jq -cn --arg since "$(date -u +%FT%TZ)" '{since: $since}' >"$state/offline"
  git -C "${TEAM_HOME:?}" remote set-url origin https://127.0.0.1:9/agent-team.git
  run_bin -75 team-timers run
  assert_equal "$(gh_calls)" ""
  assert_equal "$(alerts_posted)" ""
}
