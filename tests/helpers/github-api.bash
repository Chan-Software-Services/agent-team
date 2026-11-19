# One stub of GitHub's REST answers, in gh api -i's form, for the tests of the scripts that read
# GitHub through bin/lib/github-api.sh. A test calls github_stub_setup in its setup, which exports
# GITHUB_STUB (the stub's directory) and GITHUB_STUB_HELPER (this file), and its stub gh script
# (stub_script gh) sources the helper and answers each call:
#
#   source "$GITHUB_STUB_HELPER"
#   github_request "$@"
#   case $GITHUB_ENDPOINT in
#     repos/owner/proj/pulls/217) github_answer 200 '{"state": "open"}' ;;
#     rate_limit) github_rate_limit ;;
#     *) github_answer 404 '{"message": "Not Found"}' ;;
#   esac
#
# github_request <gh arguments...> reads the call: GITHUB_ENDPOINT the endpoint of a gh api call
# (its query kept), GITHUB_IF_NONE_MATCH its If-None-Match header, empty with none.
# Each answer below prints what gh api -i prints and exits as gh does: the status line with no
# carriage return, each header line ending in \r\n, a blank line, then the body; exit 0 on a 2xx,
# else exit 1 with gh's line on stderr ("gh: <message> (HTTP <code>)", "gh: HTTP 304").
# Every answer but a refusal carries an ETag, a hash of its body, and the X-RateLimit-* headers
# of the planned budget of its resource (github_budget; default 5000, 0 used, its reset an hour
# after the clock); each counted answer (not a 304, not a refusal) adds one to that budget's used.
# Each request is one line of $GITHUB_STUB/requests, "<endpoint> <status>", so a test counts the
# counted and the free ones; a connection failure's status is "none". A call with GH_CONFIG_DIR
# set to the worker login's directory, ~/.config/agent-team/gh-worker, is on the worker account:
# it reads and counts the worker account's budgets, and its request line ends " worker".
#   github_answer <status> <body> [<resource>]
#                      the answer, 304 with no body when <status> is 200 and the request's
#                      If-None-Match is the body's ETag; a body's message is gh's stderr reason.
#   github_limited primary | retry-after [<seconds>] | message-403 | message-429 | message-primary
#                  | message-primary-bare
#                      a refusal for the limit: a primary 403 with X-RateLimit-Remaining: 0, a
#                      secondary 403 with Retry-After (default 30), a secondary 403 with the
#                      message only, a secondary 429 with the message only, or a 403 whose message
#                      names the primary limit, with the budget's X-RateLimit-* headers but none
#                      at 0 remaining (message-primary) or with no X-RateLimit-* header at all
#                      (message-primary-bare).
#   github_offline     gh reached no GitHub: its connection error on stderr, nothing on stdout.
#   github_rate_limit  gh api rate_limit's JSON, every planned budget, unlogged and uncounted.
# In the test:
#   github_budget [--worker] <resource> <limit> <used> [<reset>]
#                      plans the budget of <resource> (core, graphql), the worker account's with
#                      --worker, else the owner's.
#   github_requests    prints the requests, one "<endpoint> <status>" per line.
#   github_clock <epoch seconds>
#                      sets the clock TEAM_GITHUB_CLOCK names, which github_stub_setup exports.
#   github_heartbeat_stub
#                      github_stub_setup, and a stub gh that answers gh api rate_limit alone,
#                      for a test of team-timers run (below).
# shellcheck shell=bash

github_stub_setup() {
  export GITHUB_STUB=$BATS_TEST_TMPDIR/github-stub
  export GITHUB_STUB_HELPER=${BASH_SOURCE[0]}
  export TEAM_GITHUB_CLOCK=$GITHUB_STUB/clock
  mkdir -p "$GITHUB_STUB"
  : >"$GITHUB_STUB/requests"
  [[ -e $TEAM_GITHUB_CLOCK ]] || echo 1795000000 >"$TEAM_GITHUB_CLOCK"
}

github_clock() {
  echo "$1" >"$TEAM_GITHUB_CLOCK"
}

github_budget() {
  local account=''
  [[ $1 != --worker ]] || { account=worker-; shift; }
  echo "$2 $3 ${4:-}" >"$GITHUB_STUB/budget-$account$1"
}

# github_account: the budget files' prefix of the call's account, worker- on the worker login.
github_account() {
  [[ ${GH_CONFIG_DIR:-} == "$HOME/.config/agent-team/gh-worker" ]] || return 0
  echo worker-
}

# github_logged <endpoint> <status>: the request's line, " worker" after it on the worker login.
github_logged() {
  local suffix=''
  [[ -z $(github_account) ]] || suffix=' worker'
  echo "$1 $2$suffix" >>"$GITHUB_STUB/requests"
}

github_requests() {
  cat "$GITHUB_STUB/requests"
}

github_request() {
  GITHUB_ENDPOINT='' GITHUB_IF_NONE_MATCH=''
  [[ ${1:-} == api ]] || return 0
  shift
  while (($#)); do
    case $1 in
      -H | --header)
        [[ ${2:-} != [Ii]f-[Nn]one-[Mm]atch:* ]] || { GITHUB_IF_NONE_MATCH=${2#*:}; GITHUB_IF_NONE_MATCH=${GITHUB_IF_NONE_MATCH# }; }
        shift 2
        continue
        ;;
      -X | --method | -f | -F | --field | --raw-field | --input | -q | --jq) shift 2; continue ;;
      -*) ;;
      *) [[ -n $GITHUB_ENDPOINT ]] || GITHUB_ENDPOINT=$1 ;;
    esac
    shift
  done
}

# github_now: the stub's clock.
github_now() {
  cat "$TEAM_GITHUB_CLOCK"
}

# github_read_budget <resource>: sets github_limit, github_used and github_reset from the plan.
github_read_budget() {
  local line='' file
  file=$GITHUB_STUB/budget-$(github_account)$1
  [[ ! -e $file ]] || line=$(<"$file")
  read -r github_limit github_used github_reset <<<"${line:-5000 0}" || true
  github_limit=${github_limit:-5000} github_used=${github_used:-0}
  [[ -n ${github_reset:-} ]] || github_reset=$(($(github_now) + 3600))
}

# github_headers <resource> <remaining or empty for the budget's>: the X-RateLimit-* lines.
github_headers() {
  github_read_budget "$1"
  local remaining=${2:-$((github_limit - github_used))}
  printf 'X-Ratelimit-Limit: %s\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Reset: %s\r\nX-Ratelimit-Resource: %s\r\nX-Ratelimit-Used: %s\r\n' \
    "$github_limit" "$remaining" "$github_reset" "$1" "$github_used"
}

# github_count <resource>: one more used of the resource's budget.
github_count() {
  github_read_budget "$1"
  echo "$github_limit $((github_used + 1)) $github_reset" >"$GITHUB_STUB/budget-$(github_account)$1"
}

github_status_text() {
  case $1 in
    200) echo OK ;; 304) echo 'Not Modified' ;; 403) echo Forbidden ;; 404) echo 'Not Found' ;;
    422) echo 'Unprocessable Entity' ;; 429) echo 'Too Many Requests' ;; 500) echo 'Internal Server Error' ;;
    *) echo Status ;;
  esac
}

github_answer() {
  local status=$1 body=$2 resource=${3:-core} etag
  etag="W/\"$(printf '%s' "$body" | sha256sum | cut -c1-40)\""
  if [[ $status == 200 && -n $GITHUB_IF_NONE_MATCH && $GITHUB_IF_NONE_MATCH == "$etag" ]]; then
    github_logged "$GITHUB_ENDPOINT" 304
    printf 'HTTP/2.0 304 Not Modified\nEtag: %s\r\n' "$etag"
    github_headers "$resource" ''
    printf '\r\n'
    echo "gh: HTTP 304" >&2
    exit 1
  fi
  github_logged "$GITHUB_ENDPOINT" "$status"
  github_count "$resource"
  printf 'HTTP/2.0 %s %s\nContent-Type: application/json; charset=utf-8\r\nEtag: %s\r\n' "$status" "$(github_status_text "$status")" "$etag"
  github_headers "$resource" ''
  printf '\r\n%s\n' "$body"
  [[ $status != 2[0-9][0-9] ]] || exit 0
  echo "gh: $(jq -r '.message // "error"' <<<"$body" 2>/dev/null || echo error) (HTTP $status)" >&2
  exit 1
}

github_limited() {
  local status=403 body extra='' remaining='' headers=true
  case $1 in
    primary)
      remaining=0
      body='{"message":"API rate limit exceeded for user ID 1. If you reach out to GitHub Support for help, please include the request ID.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}'
      ;;
    retry-after)
      extra="Retry-After: ${2:-30}"$'\r\n'
      body='{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits"}'
      ;;
    message-primary | message-primary-bare)
      [[ $1 != message-primary-bare ]] || headers=false
      body='{"message":"API rate limit exceeded for user ID 1.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}'
      ;;
    message-403 | message-429)
      [[ $1 != message-429 ]] || status=429
      body='{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits"}'
      ;;
    *) echo "github_limited: no refusal $1" >&2; exit 1 ;;
  esac
  github_logged "$GITHUB_ENDPOINT" "$status"
  printf 'HTTP/2.0 %s %s\nContent-Type: application/json; charset=utf-8\r\n%s' "$status" "$(github_status_text "$status")" "$extra"
  ! $headers || github_headers core "$remaining"
  printf '\r\n%s\n' "$body"
  echo "gh: $(jq -r .message <<<"$body") (HTTP $status)" >&2
  exit 1
}

github_offline() {
  github_logged "${GITHUB_ENDPOINT:-${*:-}}" none
  echo "error connecting to api.github.com" >&2
  echo "check your internet connection or https://githubstatus.com" >&2
  exit 1
}

github_rate_limit() {
  local resource out='{}'
  for resource in core graphql; do
    github_read_budget "$resource"
    out=$(jq -c --arg r "$resource" --argjson l "$github_limit" --argjson u "$github_used" --argjson reset "$github_reset" \
      '.[$r] = {limit: $l, used: $u, remaining: ($l - $u), reset: $reset}' <<<"$out")
  done
  jq -c '{resources: ., rate: .core}' <<<"$out"
  exit 0
}

# github_heartbeat_stub: the stub GitHub of a test of team-timers run that plans nothing else of
# it: gh api rate_limit answers the planned budgets (an idle hour unless github_budget plans one),
# and every other gh call fails as the sandbox's stub does with no fixture, so the heartbeat's
# github step reads a budget and posts nothing.
github_heartbeat_stub() {
  github_stub_setup
  stub_script gh <<'STUB'
source "$GITHUB_STUB_HELPER"
github_request "$@"
[[ $GITHUB_ENDPOINT != rate_limit ]] || github_rate_limit
echo "stub gh: no fixture for this call: $*" >&2
exit 127
STUB
}
