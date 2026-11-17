# The one reader of GitHub's REST answers for the scripts that poll GitHub (team-ci-wait,
# team-ci-run): a cache every process of the machine on one GitHub login shares, revalidated with
# ETags, so a read of an unchanged answer is a 304, which GitHub does not count against its limit;
# the budget each answer reports; a rate-limit refusal told apart from every other failure, and
# held until it lifts, so no process on that login asks again before then; and a log of every
# request, by the command that sent it. Sourced after team.sh:
#
#   # shellcheck source=bin/lib/github-api.sh
#   source "$TEAM_LIB/github-api.sh"
#
# Its state is $GITHUB_API_DIR, one directory per GitHub login, since GitHub's limits are per
# account: the owner login's ~/.local/state/agent-team/github (the one directory there was before
# the worker login, so what it recorded stands), the worker login's
# ~/.local/state/agent-team/github-worker; sourcing the library points it at the session's login,
# bin/lib/github-login.sh's session_login, and gh_use_login at another. Each is made on first use
# and holds:
#   cache/<key>.json   {endpoint, etag, fetched, status} of one endpoint's last 2xx answer,
#                      fetched in epoch seconds, <key> the sha256 of the endpoint as read;
#   cache/<key>.body   that answer's body; cache/<key>.lock its lock;
#   budget.json        {<resource>: {limit, remaining, used, reset, at}}, the latest reading of
#                      each resource (core, graphql, ...), reset and at in epoch seconds, from any
#                      answer's X-RateLimit-* headers or the heartbeat's gh api rate_limit;
#   limit.json         {resource, kind, until, seen, by, endpoint}, the limit last met: resource
#                      the limited one, or all for a secondary limit; kind primary or secondary;
#                      until and seen in epoch seconds; by the script and endpoint what was
#                      refused; it stands while until is ahead;
#   calls-<UTC date>.jsonl
#                      one line per request sent, {at (UTC time), by, for, method, endpoint (its
#                      query cut), status (the HTTP code, null with none), resource, used,
#                      counted}; counted is false for a 304, a refusal for the limit, a gh_read
#                      request GitHub never answered (status null) and gh_call's read of gh api
#                      rate_limit, and true for every other request, a gh_call that fails with
#                      no HTTP code in gh's stderr (status null) among them, since gh_call cannot
#                      tell whether GitHub answered it.
# Every write but the log's goes to a temporary file in the same directory, moved into place;
# budget.json's and limit.json's under state.lock. The log is appended a line at a time; the
# request that starts a day's log removes the logs of days more than 2 before it, the cache
# entries fetched more than a day ago, and the temporary files a writer killed mid-write left,
# last changed more than a day ago. A write that cannot be made (a full or unwritable home, say)
# is skipped and never fails a read: gh_read then reads GitHub direct, as below.
# Each request is logged with by from GH_BY, else the calling script's name, and for from
# GH_FOR, else null (team-ci-wait's <owner>/<name>#<n>, say).
#
# A refusal for the limit is an answer of 403 or 429 with X-RateLimit-Remaining: 0 (primary,
# until X-RateLimit-Reset), else with a Retry-After header (secondary, until now plus its
# seconds), else whose body's message says "secondary rate limit" (secondary, until now plus
# 60 s, GitHub's least wait) or "rate limit" (primary, until X-RateLimit-Reset, else now plus
# 60 s). Any other 403 is a plain failure.
#
# It provides:
#   gh_use_login owner | worker
#                      points GITHUB_API_DIR at that login's state, for every function below, for
#                      a script that reads GitHub on a login other than its session's (the
#                      heartbeat reads each login's budget).
#   gh_now             prints now in epoch seconds: the number in the file TEAM_GITHUB_CLOCK
#                      names when it is set (the tests' clock), else the machine's.
#   gh_utc <epoch seconds>
#                      prints that time in UTC as the log writes it (2026-11-16T07:27:14Z).
#   gh_read <dir> <name> <endpoint> [<fresh seconds>]
#                      reads one REST GET endpoint (repos/<owner>/<name>/..., query and all),
#                      its body JSON in <dir>/<name>. While a limit stands for core or all it
#                      sends nothing and returns 3. An entry fetched within <fresh seconds>
#                      (default TEAM_GITHUB_FRESH_SECONDS, else 20) is served with no request.
#                      Else, under the entry's lock (waited for 30 s; past that a failure,
#                      "another reader held <endpoint> for 30 s"), it serves an entry another
#                      process refreshed meanwhile, or sends gh api -i <endpoint>, with
#                      If-None-Match: <etag> when the entry has one, notes the budget and logs
#                      the request: a 2xx with a JSON body is stored and served (one with none
#                      is a failure, "not JSON"), a 304 serves the stored body
#                      and marks it fetched now, each returning 0 and removing a limit.json of
#                      the answer's resource or all; a refusal for the limit writes limit.json
#                      and returns 3; anything else returns 1. With no state directory it can
#                      make, or an entry's lock it cannot open, it reads direct (no ETag sent,
#                      nothing kept), and a 2xx whose entry cannot be written, or a 304 whose entry
#                      cannot be marked fetched, is served all the same. GH_STATUS is the served or
#                      failed answer's HTTP code (empty when gh got none). On a failure or a refusal
#                      <dir>/error says why: "gh api <endpoint>: <gh's first stderr line>", or the
#                      limit's text; on a refusal GH_LIMIT_UNTIL (epoch seconds), GH_LIMIT_RESOURCE
#                      and GH_LIMIT_KIND are the limit's.
#   gh_call <dir> <name> <gh arguments...>
#                      runs one uncached gh call as given (a gh workflow run, a gh api graphql,
#                      a --paginate read), its stdout in <dir>/<name> as gh prints it, after
#                      the same check of limit.json (resource graphql for api graphql, else
#                      core), logging it (status the code gh's stderr names, else 200 on exit 0,
#                      else null; endpoint graphql, the api path or the subcommand, as
#                      workflow run). A failure whose stderr says "rate limit" (for api
#                      graphql, or a call that is no api call, its output too) reads
#                      gh api rate_limit (which GitHub does not count) and takes the reset of
#                      the call's resource, or of the other, whose remaining is 0, else a
#                      secondary limit of 60 s, writes limit.json and returns 3, with the
#                      variables and <dir>/error as gh_read sets them; any other failure
#                      returns 1, <dir>/error in team.sh's github() form, "gh <first two
#                      arguments>: <gh's first stderr line, else exit n>".
#   gh_limited [<resource>...]
#                      prints the standing limit's until when limit.json stands for one of the
#                      resources (default core) or all; else fails.
#   gh_limit_record [<resource>...]
#                      prints the standing limit as one line, "<until> <resource> <kind>", when
#                      limit.json stands for one of the resources or all; else fails.
#   gh_note_budget <resource> <limit> <remaining> <used> <reset>
#                      writes budget.json's entry for <resource>, read now, as an answer's headers
#                      do (the heartbeat's gh api rate_limit reading); a write that cannot be made
#                      is skipped.
#   gh_limit_text <until> <resource> <kind>
#                      the one wording of a limit, until in this machine's local time.
#   gh_interval <base seconds> [<resource>...]
#                      prints the seconds to wait before the next look: the greatest of <base>
#                      and, for each resource (default core) whose budget.json reset is ahead,
#                      60 with remaining under half its limit, 120 under a quarter, 300 under a
#                      tenth.
#   gh_spenders <resource> <since epoch>
#                      prints one JSON array of the counted requests of <resource> logged since
#                      then, by by, each {by, calls, subjects} (subjects the distinct for),
#                      most calls first, then by name.
# Its seams are TEAM_GITHUB_CLOCK and TEAM_GITHUB_FRESH_SECONDS.
# shellcheck shell=bash

gh_use_login() {
  case $1 in
    owner) GITHUB_API_DIR=$HOME/.local/state/agent-team/github ;;
    worker) GITHUB_API_DIR=$HOME/.local/state/agent-team/github-worker ;;
    *) echo "gh_use_login: no login $1 (owner or worker)" >&2; return 1 ;;
  esac
}
gh_use_login "$(session_login)"
# How long a reader waits for another reading the same endpoint.
GITHUB_LOCK_SECONDS=30
# GitHub's least wait after a secondary limit with no Retry-After.
GITHUB_SECONDARY_SECONDS=60

gh_now() {
  local gh_clock
  if [[ -n ${TEAM_GITHUB_CLOCK:-} ]]; then
    IFS= read -r gh_clock <"$TEAM_GITHUB_CLOCK" || true
    [[ $gh_clock =~ ^[0-9]+$ ]] || { echo "TEAM_GITHUB_CLOCK's file $TEAM_GITHUB_CLOCK holds no epoch seconds" >&2; return 1; }
    echo "$gh_clock"
  else
    date +%s
  fi
}

# The UTC time of <epoch seconds>, as the log and the notices write it.
gh_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

gh_limit_text() {
  local gh_at gh_what
  gh_at=$(date -d "@$1" +%H:%M)
  if [[ $3 == secondary ]]; then
    echo "GitHub's secondary rate limit holds the team's requests until $gh_at; this is no outage"
    return
  fi
  case $2 in
    core) gh_what='core requests' ;;
    graphql) gh_what='GraphQL points' ;;
    *) gh_what="$2 requests" ;;
  esac
  echo "GitHub's API rate limit for $gh_what is used up until $gh_at, when it resets; this is no outage"
}

# gh_limit_record: prints limit.json's {resource, kind, until} as one line of three words when it
# stands for one of the resources given or all; else fails.
gh_limit_record() {
  local gh_file=$GITHUB_API_DIR/limit.json gh_now_s
  [[ -f $gh_file ]] || return 1
  gh_now_s=$(gh_now) || return 1
  jq -er --argjson now "$gh_now_s" '$ARGS.positional as $want
    | select(type == "object" and (.until | type) == "number" and .until > $now)
    | select(.resource == "all" or (.resource as $r | $want | index($r)))
    | "\(.until) \(.resource) \(.kind)"' "$gh_file" --args "$@" 2>/dev/null
}

gh_limited() {
  local gh_line
  (($#)) || set -- core
  gh_line=$(gh_limit_record "$@") || return 1
  echo "${gh_line%% *}"
}

# gh_refused <dir> <until> <resource> <kind>: sets the limit's variables and <dir>/error, and
# returns 3.
gh_refused() {
  GH_LIMIT_UNTIL=$2 GH_LIMIT_RESOURCE=$3 GH_LIMIT_KIND=$4
  gh_limit_text "$2" "$3" "$4" >"$1/error"
  return 3
}

# gh_standing <dir> <resource>: returns 3, as gh_refused, when a limit stands for <resource> or
# all; else 0.
gh_standing() {
  local gh_line
  gh_line=$(gh_limit_record "$2") || return 0
  GH_STATUS=''
  # shellcheck disable=SC2086 # the record's three words
  gh_refused "$1" $gh_line
}

# gh_state_write <file name> <jq program> [<jq arguments>...]: under state.lock, runs the program
# on the state file (null when it has none) and writes what it prints, whole, or removes the file
# when it prints null.
gh_state_write() {
  local gh_file=$GITHUB_API_DIR/$1 gh_program=$2 gh_fd gh_new gh_rc=0
  shift 2
  { exec {gh_fd}>>"$GITHUB_API_DIR/state.lock"; } 2>/dev/null || return 1
  if flock -w 5 "$gh_fd"; then
    gh_new=$(mktemp "$gh_file.XXXXXX" 2>/dev/null) || gh_rc=1
    if ((gh_rc == 0)); then
      if { if [[ -f $gh_file ]]; then cat "$gh_file"; else echo null; fi; } |
        jq -c "$@" "$gh_program" >"$gh_new" 2>/dev/null; then
        if [[ $(<"$gh_new") == null ]]; then
          rm -f -- "$gh_new" "$gh_file" 2>/dev/null || gh_rc=1
        else
          mv -f -- "$gh_new" "$gh_file" 2>/dev/null || gh_rc=1
        fi
      else
        gh_rc=1
      fi
      rm -f -- "$gh_new" 2>/dev/null
    fi
  else
    gh_rc=1
  fi
  exec {gh_fd}>&-
  return "$gh_rc"
}

# gh_note_budget <resource> <limit> <remaining> <used> <reset>: budget.json's entry for the
# resource, read now.
gh_note_budget() {
  [[ -n $1 && $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ && $4 =~ ^[0-9]+$ && $5 =~ ^[0-9]+$ ]] || return 0
  gh_state_write budget.json '(objects // {}) + {($r): {limit: $l, remaining: $rem, used: $u, reset: $reset, at: $now}}' \
    --arg r "$1" --argjson l "$2" --argjson rem "$3" --argjson u "$4" --argjson reset "$5" --argjson now "$(gh_now)" || true
}

# gh_note_limit <until> <resource> <kind> <endpoint>: limit.json, as met now.
gh_note_limit() {
  gh_state_write limit.json '{resource: $r, kind: $k, until: $until, seen: $now, by: $by, endpoint: $e}' \
    --arg r "$2" --arg k "$3" --argjson until "$1" --argjson now "$(gh_now)" --arg by "${GH_BY:-${0##*/}}" --arg e "$4" || true
}

# gh_lift_limit <resource>: removes a limit.json of <resource> or all, after a success.
gh_lift_limit() {
  [[ -f $GITHUB_API_DIR/limit.json ]] || return 0
  gh_state_write limit.json 'if type == "object" and (.resource == $r or .resource == "all") then null else . end' --arg r "$1" || true
}

# gh_log <method> <endpoint> <status> <resource> <used> <counted>: one line of today's log, an empty
# method, status, resource or used null; the line that starts a day's log prunes the old logs and
# cache entries first.
gh_log() {
  local gh_now_s gh_day gh_log_file
  gh_now_s=$(gh_now) || return 0
  gh_day=$(date -u -d "@$gh_now_s" +%F)
  gh_log_file=$GITHUB_API_DIR/calls-$gh_day.jsonl
  [[ -e $gh_log_file ]] || gh_prune "$gh_now_s"
  jq -cn --arg at "$(gh_utc "$gh_now_s")" --arg by "${GH_BY:-${0##*/}}" --arg for "${GH_FOR:-}" --arg method "$1" \
    --arg endpoint "${2%%\?*}" --arg status "$3" --arg resource "$4" --arg used "$5" --argjson counted "$6" \
    'def orNull: if . == "" then null else . end;
    {at: $at, by: $by, for: ($for | orNull), method: ($method | orNull), endpoint: $endpoint,
     status: ($status | orNull | if . == null then null else tonumber end), resource: ($resource | orNull),
     used: ($used | orNull | if . == null then null else tonumber end), counted: $counted}' 2>/dev/null >>"$gh_log_file" || true
}

# gh_prune <now>: removes the logs of days more than 2 before <now>'s, the cache entries fetched
# more than a day before it, each entry's under its lock when that is free, and the temporary files
# of a write (cache/<key>.json.XXXXXX, cache/<key>.body.XXXXXX, budget.json.XXXXXX,
# limit.json.XXXXXX) last changed more than a day before it, which only a writer killed mid-write
# leaves.
gh_prune() {
  local gh_oldest gh_file gh_day gh_fetched gh_fd gh_changed
  gh_oldest=$(date -u -d "@$(($1 - 2 * 86400))" +%F)
  for gh_file in "$GITHUB_API_DIR"/calls-*.jsonl; do
    [[ -e $gh_file ]] || continue
    gh_day=${gh_file##*/calls-} gh_day=${gh_day%.jsonl}
    [[ ! $gh_day < $gh_oldest ]] || rm -f -- "$gh_file"
  done
  for gh_file in "$GITHUB_API_DIR"/cache/*.json; do
    [[ -e $gh_file ]] || continue
    gh_fetched=$(jq -r '.fetched // 0' "$gh_file" 2>/dev/null) || gh_fetched=0
    [[ $gh_fetched =~ ^[0-9]+$ ]] || gh_fetched=0
    (($1 - gh_fetched > 86400)) || continue
    { exec {gh_fd}>>"${gh_file%.json}.lock"; } 2>/dev/null || continue
    if flock -n "$gh_fd"; then rm -f -- "$gh_file" "${gh_file%.json}.body" "${gh_file%.json}.lock" 2>/dev/null; fi
    exec {gh_fd}>&-
  done
  for gh_file in "$GITHUB_API_DIR"/cache/*.json.?????? "$GITHUB_API_DIR"/cache/*.body.?????? \
    "$GITHUB_API_DIR"/budget.json.?????? "$GITHUB_API_DIR"/limit.json.??????; do
    [[ -f $gh_file ]] || continue
    gh_changed=$(stat -c %Y -- "$gh_file" 2>/dev/null) || continue
    (($1 - gh_changed > 86400)) || continue
    rm -f -- "$gh_file" 2>/dev/null || true
  done
}

# gh_entry_fetched <key>: the cache entry's fetched, or nothing when it has no entry.
gh_entry_fetched() {
  local gh_entry=$GITHUB_API_DIR/cache/$1
  [[ -f $gh_entry.json && -f $gh_entry.body ]] || return 0
  jq -r '.fetched // empty | numbers' "$gh_entry.json" 2>/dev/null || true
}

# gh_serve <dir> <name> <key>: the cache entry's body in <dir>/<name>, GH_STATUS its status.
gh_serve() {
  local gh_entry=$GITHUB_API_DIR/cache/$3
  GH_STATUS=$(jq -r '.status // 200' "$gh_entry.json" 2>/dev/null) || GH_STATUS=200
  cp -- "$gh_entry.body" "$1/$2" || { echo "gh api: the cached answer could not be copied" >"$1/error"; return 1; }
}

gh_read() {
  local gh_dir=$1 gh_name=$2 gh_endpoint=$3 gh_fresh=${4:-${TEAM_GITHUB_FRESH_SECONDS:-20}}
  local gh_key gh_entry gh_before gh_after gh_now_s gh_fd gh_rc
  GH_STATUS='' GH_LIMIT_UNTIL='' GH_LIMIT_RESOURCE='' GH_LIMIT_KIND=''
  gh_standing "$gh_dir" core || return 3
  # With no cache to keep (its directory cannot be made), the read goes to GitHub direct.
  if ! mkdir -p "$GITHUB_API_DIR/cache" 2>/dev/null; then
    gh_fetch "$gh_dir" "$gh_name" "$gh_endpoint" '' ''
    return
  fi
  gh_key=$(printf '%s' "$gh_endpoint" | sha256sum) gh_key=${gh_key%% *}
  gh_entry=$GITHUB_API_DIR/cache/$gh_key
  gh_now_s=$(gh_now) || return 1
  gh_before=$(gh_entry_fetched "$gh_key")
  if [[ -n $gh_before ]] && ((gh_now_s - gh_before < gh_fresh)); then
    gh_serve "$gh_dir" "$gh_name" "$gh_key"
    return
  fi
  # Nor with an entry's lock that cannot be opened.
  if ! { exec {gh_fd}>>"$gh_entry.lock"; } 2>/dev/null; then
    gh_fetch "$gh_dir" "$gh_name" "$gh_endpoint" '' ''
    return
  fi
  if ! flock -w "$GITHUB_LOCK_SECONDS" "$gh_fd"; then
    exec {gh_fd}>&-
    echo "another reader held $gh_endpoint for $GITHUB_LOCK_SECONDS s" >"$gh_dir/error"
    return 1
  fi
  gh_rc=0
  # Another process may have read it, or met the limit, while this one waited; a fetched of 0 is a
  # write stopped partway, never a read.
  gh_after=$(gh_entry_fetched "$gh_key")
  [[ $gh_after != 0 ]] || gh_after=''
  gh_now_s=$(gh_now) || gh_rc=1
  if ((gh_rc != 0)); then
    :
  elif ! gh_standing "$gh_dir" core; then
    gh_rc=3
  elif [[ -n $gh_after ]] && { [[ $gh_after != "$gh_before" ]] || ((gh_now_s - gh_after < gh_fresh)); }; then
    gh_serve "$gh_dir" "$gh_name" "$gh_key" || gh_rc=$?
  else
    gh_fetch "$gh_dir" "$gh_name" "$gh_endpoint" "$gh_key" "$gh_fd" || gh_rc=$?
  fi
  exec {gh_fd}>&-
  return "$gh_rc"
}

# gh_fetch <dir> <name> <endpoint> <key> <lock fd>: sends the request, under the entry's lock,
# which gh does not inherit. With no key it reads direct: no ETag sent, nothing kept, a 2xx served
# from the answer itself; and an answer whose entry cannot be written is served so too.
gh_fetch() {
  local gh_dir=$1 gh_name=$2 gh_endpoint=$3 gh_entry=${4:+$GITHUB_API_DIR/cache/$4} gh_fd=${5:-}
  local gh_out=$1/$2.answer gh_err=$1/$2.stderr gh_etag='' gh_code='' gh_line gh_header gh_value gh_reason
  local gh_until gh_kind gh_resource gh_message gh_now_s gh_new gh_kept
  local -a gh_args=(api -i)
  local -A gh_h=()
  if [[ -n $gh_entry ]]; then
    gh_etag=$(jq -r '.etag // empty | strings' "$gh_entry.json" 2>/dev/null) || gh_etag=''
    [[ -f $gh_entry.body ]] || gh_etag=''
  fi
  [[ -z $gh_etag ]] || gh_args+=(-H "If-None-Match: $gh_etag")
  if [[ -n $gh_fd ]]; then
    gh "${gh_args[@]}" "$gh_endpoint" >"$gh_out" 2>"$gh_err" {gh_fd}>&- </dev/null || true
  else
    gh "${gh_args[@]}" "$gh_endpoint" >"$gh_out" 2>"$gh_err" </dev/null || true
  fi
  gh_now_s=$(gh_now) || return 1
  # The status line, the headers to the first blank line, \r cut, and the body after it.
  : >"$gh_out.body"
  {
    IFS= read -r gh_line || true
    gh_line=${gh_line%$'\r'}
    [[ ! $gh_line =~ ^HTTP/[0-9.]+\ ([0-9]{3}) ]] || gh_code=${BASH_REMATCH[1]}
    if [[ -n $gh_code ]]; then
      while IFS= read -r gh_line; do
        gh_line=${gh_line%$'\r'}
        [[ -n $gh_line ]] || break
        [[ $gh_line == *:* ]] || continue
        gh_header=${gh_line%%:*} gh_value=${gh_line#*:}
        gh_value=${gh_value#"${gh_value%%[! ]*}"}
        gh_h[${gh_header,,}]=$gh_value
      done
      cat >"$gh_out.body"
    fi
  } <"$gh_out"
  rm -f -- "$gh_out"
  GH_STATUS=$gh_code
  gh_resource=${gh_h[x-ratelimit-resource]:-}
  gh_note_budget "$gh_resource" "${gh_h[x-ratelimit-limit]:-}" "${gh_h[x-ratelimit-remaining]:-}" \
    "${gh_h[x-ratelimit-used]:-}" "${gh_h[x-ratelimit-reset]:-}"

  # A refusal for the limit.
  if [[ $gh_code == 403 || $gh_code == 429 ]]; then
    gh_message=$(jq -r '.message // empty | strings' "$gh_out.body" 2>/dev/null) || gh_message=''
    gh_kind='' gh_until=''
    if [[ ${gh_h[x-ratelimit-remaining]:-} == 0 ]]; then
      gh_kind=primary gh_until=${gh_h[x-ratelimit-reset]:-}
    elif [[ ${gh_h[retry-after]:-} =~ ^[0-9]+$ ]]; then
      gh_kind=secondary gh_until=$((gh_now_s + ${gh_h[retry-after]}))
    elif [[ ${gh_message,,} == *"secondary rate limit"* ]]; then
      gh_kind=secondary gh_until=$((gh_now_s + GITHUB_SECONDARY_SECONDS))
    elif [[ ${gh_message,,} == *"rate limit"* ]]; then
      gh_kind=primary gh_until=${gh_h[x-ratelimit-reset]:-}
    fi
    if [[ -n $gh_kind ]]; then
      [[ $gh_until =~ ^[0-9]+$ ]] || gh_until=$((gh_now_s + GITHUB_SECONDARY_SECONDS))
      if [[ $gh_kind == secondary ]]; then gh_resource=all; else gh_resource=${gh_resource:-core}; fi
      gh_log GET "$gh_endpoint" "$gh_code" "${gh_h[x-ratelimit-resource]:-}" "${gh_h[x-ratelimit-used]:-}" false
      gh_note_limit "$gh_until" "$gh_resource" "$gh_kind" "${gh_endpoint%%\?*}"
      rm -f -- "$gh_out.body" "$gh_err"
      gh_refused "$gh_dir" "$gh_until" "$gh_resource" "$gh_kind"
      return
    fi
  fi
  # GitHub counts neither a 304 nor a request it never answered.
  if [[ $gh_code == 304 || -z $gh_code ]]; then
    gh_log GET "$gh_endpoint" "$gh_code" "$gh_resource" "${gh_h[x-ratelimit-used]:-}" false
  else
    gh_log GET "$gh_endpoint" "$gh_code" "$gh_resource" "${gh_h[x-ratelimit-used]:-}" true
  fi

  gh_reason='' gh_new='' gh_kept=true
  if [[ $gh_code == 304 && -n $gh_etag ]]; then
    # Marked fetched now; one that cannot be is still served, and asked again at the next read.
    { gh_new=$(mktemp "$gh_entry.json.XXXXXX" 2>/dev/null) &&
      jq -c --argjson now "$gh_now_s" '.fetched = $now' "$gh_entry.json" >"$gh_new" 2>/dev/null &&
      mv -f -- "$gh_new" "$gh_entry.json" 2>/dev/null; } || true
  elif [[ $gh_code == 2[0-9][0-9] ]]; then
    if ! jq -e . "$gh_out.body" >/dev/null 2>&1; then
      gh_reason='not JSON'
    elif [[ -z $gh_entry ]]; then
      gh_kept=false
    # The entry with no ETag and never fresh first, so a write stopped before its last step never
    # pairs a body with an ETag it did not come with; then the body; then the entry whole.
    elif ! { gh_new=$(mktemp "$gh_entry.json.XXXXXX" 2>/dev/null) &&
      gh_entry_json "$gh_endpoint" '' 0 "$gh_code" >"$gh_new" && mv -f -- "$gh_new" "$gh_entry.json" 2>/dev/null &&
      gh_new=$(mktemp "$gh_entry.body.XXXXXX" 2>/dev/null) && cp -- "$gh_out.body" "$gh_new" 2>/dev/null &&
      mv -f -- "$gh_new" "$gh_entry.body" 2>/dev/null &&
      gh_new=$(mktemp "$gh_entry.json.XXXXXX" 2>/dev/null) &&
      gh_entry_json "$gh_endpoint" "${gh_h[etag]:-}" "$gh_now_s" "$gh_code" >"$gh_new" &&
      mv -f -- "$gh_new" "$gh_entry.json" 2>/dev/null; }; then
      gh_kept=false
    fi
  else
    gh_reason=$(grep -m1 . "$gh_err" 2>/dev/null) || gh_reason=${gh_code:+HTTP $gh_code}
    gh_reason=${gh_reason:-no answer}
  fi
  # A temporary file a failed write left.
  [[ -z $gh_new || ! -e $gh_new ]] || rm -f -- "$gh_new" 2>/dev/null
  rm -f -- "$gh_err"
  if [[ -n $gh_reason ]]; then
    rm -f -- "$gh_out.body"
    echo "gh api $gh_endpoint: $gh_reason" >"$gh_dir/error"
    return 1
  fi
  gh_lift_limit "${gh_resource:-core}"
  if ! $gh_kept; then
    mv -f -- "$gh_out.body" "$gh_dir/$gh_name"
    return
  fi
  rm -f -- "$gh_out.body"
  gh_serve "$gh_dir" "$gh_name" "$4"
}

# gh_entry_json <endpoint> <etag or empty> <fetched> <status>: a cache entry's .json.
gh_entry_json() {
  jq -cn --arg e "$1" --arg etag "$2" --argjson now "$3" --argjson s "$4" \
    '{endpoint: $e, etag: (if $etag == "" then null else $etag end), fetched: $now, status: $s}'
}

gh_call() {
  local gh_dir=$1 gh_name=$2 gh_resource=core gh_endpoint gh_method='' gh_rc=0 gh_code='' gh_arg gh_text
  local gh_until='' gh_kind=secondary gh_reading gh_line gh_now_s
  local -a gh_words
  shift 2
  # shellcheck disable=SC2034 # read by the scripts that source this file
  GH_STATUS='' GH_LIMIT_UNTIL='' GH_LIMIT_RESOURCE='' GH_LIMIT_KIND=''
  mkdir -p "$GITHUB_API_DIR/cache" 2>/dev/null || true
  # What the call reads, for the limit and the log.
  if [[ $1 == api ]]; then
    gh_endpoint='' gh_method=GET
    for ((gh_arg = 2; gh_arg <= $#; gh_arg++)); do
      case ${!gh_arg} in
        -X | --method) gh_line=$((gh_arg + 1)) gh_method=${!gh_line:-GET} gh_arg=$gh_line ;;
        -f | -F | --field | --raw-field | --input) [[ $gh_method != GET ]] || gh_method=POST; gh_arg=$((gh_arg + 1)) ;;
        -H | --header | -q | --jq | -t | --template | --hostname | --cache | -p | --preview) gh_arg=$((gh_arg + 1)) ;;
        -*) ;;
        *) [[ -n $gh_endpoint ]] || gh_endpoint=${!gh_arg} ;;
      esac
    done
    if [[ $gh_endpoint == graphql ]]; then gh_resource=graphql gh_method=POST; fi
  else
    gh_endpoint="$1 ${2:-}" gh_endpoint=${gh_endpoint% }
  fi
  gh_standing "$gh_dir" "$gh_resource" || return 3
  gh "$@" >"$gh_dir/$gh_name" 2>"$gh_dir/$gh_name.stderr" </dev/null || gh_rc=$?
  if [[ $(<"$gh_dir/$gh_name.stderr") =~ \(HTTP\ ([0-9]{3})\) ]]; then gh_code=${BASH_REMATCH[1]}; fi
  if ((gh_rc == 0)); then
    GH_STATUS=${gh_code:-200}
    gh_log "$gh_method" "$gh_endpoint" "$GH_STATUS" "$gh_resource" '' true
    gh_lift_limit "$gh_resource"
    return 0
  fi
  GH_STATUS=$gh_code
  # gh's own error text, and for GraphQL its answer too, whose errors carry RATE_LIMITED: a REST
  # read's stdout is GitHub's data (a --paginate read's earlier pages), whatever it says.
  if [[ $1 == api && $gh_resource != graphql ]]; then
    gh_text=$(cat -- "$gh_dir/$gh_name.stderr" 2>/dev/null) || gh_text=''
  else
    gh_text=$(cat -- "$gh_dir/$gh_name" "$gh_dir/$gh_name.stderr" 2>/dev/null) || gh_text=''
  fi
  if [[ ${gh_text,,} == *"rate limit"* || $gh_text == *RATE_LIMITED* ]]; then
    gh_log "$gh_method" "$gh_endpoint" "$gh_code" "$gh_resource" '' false
    gh_now_s=$(gh_now) || return 1
    # GitHub's own reading of the budget, which it does not count: the reset of the resource used up.
    if gh_reading=$(gh api rate_limit 2>/dev/null </dev/null) && jq -e '.resources | objects' <<<"$gh_reading" >/dev/null 2>&1; then
      gh_log GET rate_limit 200 '' '' false
      while read -r -a gh_words; do
        gh_note_budget "${gh_words[@]}"
      done < <(jq -r '.resources | to_entries[] | select(.key == "core" or .key == "graphql")
        | "\(.key) \(.value.limit) \(.value.remaining) \(.value.used) \(.value.reset)"' <<<"$gh_reading")
      gh_line=$(jq -r --arg r "$gh_resource" '.resources | [(.[$r] | objects | {key: $r} + .),
        (to_entries[] | select(.key == "core" or .key == "graphql") | {key} + .value)]
        | map(select(.remaining == 0 and (.reset | type) == "number")) | first // empty | "\(.key) \(.reset)"' <<<"$gh_reading")
      if [[ -n $gh_line ]]; then
        gh_kind=primary gh_resource=${gh_line%% *} gh_until=${gh_line#* }
      fi
    else
      gh_log GET rate_limit '' '' '' false
    fi
    if [[ $gh_kind == secondary ]]; then gh_resource=all gh_until=$((gh_now_s + GITHUB_SECONDARY_SECONDS)); fi
    gh_note_limit "$gh_until" "$gh_resource" "$gh_kind" "$gh_endpoint"
    gh_refused "$gh_dir" "$gh_until" "$gh_resource" "$gh_kind"
    return
  fi
  gh_log "$gh_method" "$gh_endpoint" "$gh_code" "$gh_resource" '' true
  {
    printf 'gh %s %s: ' "$1" "${2:-}"
    grep -m1 . "$gh_dir/$gh_name.stderr" || echo "exit $gh_rc"
  } >"$gh_dir/error"
  return 1
}

gh_interval() {
  local gh_base=$1 gh_now_s
  shift
  (($#)) || set -- core
  gh_now_s=$(gh_now) || { echo "$gh_base"; return 0; }
  [[ -f $GITHUB_API_DIR/budget.json ]] || { echo "$gh_base"; return 0; }
  jq -r --argjson base "$gh_base" --argjson now "$gh_now_s" '. as $b | [$base] + [$ARGS.positional[]
    | $b[.] | objects | select((.reset | type) == "number" and .reset > $now and (.limit | type) == "number"
      and (.remaining | type) == "number")
    | if .remaining * 10 < .limit then 300 elif .remaining * 4 < .limit then 120
      elif .remaining * 2 < .limit then 60 else 0 end] | max' "$GITHUB_API_DIR/budget.json" --args "$@" 2>/dev/null ||
    echo "$gh_base"
}

gh_spenders() {
  local -a gh_logs=()
  local gh_file
  for gh_file in "$GITHUB_API_DIR"/calls-*.jsonl; do [[ ! -e $gh_file ]] || gh_logs+=("$gh_file"); done
  ((${#gh_logs[@]})) || { echo '[]'; return 0; }
  cat -- "${gh_logs[@]}" | jq -cs --arg r "$1" --argjson since "$2" '[.[] | objects
    | select(.counted == true and .resource == $r and ((.at | fromdateiso8601?) // 0) >= $since)]
    | group_by(.by) | map({by: .[0].by, calls: length, subjects: ([.[].for | strings] | unique)})
    | sort_by(-.calls, .by)'
}
