#!/usr/bin/env bats
# team-review-check: the coordinator's post of agent-review as the reviewer App's check run, on a
# head whose review the ledger holds, with a one-repository, checks-only token minted from the
# App's key and revoked after, the JWT and the token given to curl on stdin alone. The App is on
# only in a copy of bin/ that holds a bin/lib/review-app, and its key is made at run time, never
# committed, since gitleaks reads every commit. Its --merge-group form, on the merge queue's trial
# commit, runs on a real origin and primary checkout (helpers/queue).

load helpers/common
load helpers/queue

HEAD_SHA=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
URL=https://github.com/owner/agent-team/pull/5

setup_file() {
  openssl genrsa -out "$BATS_FILE_TMPDIR/key.pem" 2048 2>/dev/null
  openssl rsa -in "$BATS_FILE_TMPDIR/key.pem" -pubout -out "$BATS_FILE_TMPDIR/public.pem" 2>/dev/null
}

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[agent-team]
repo = "Owner/agent-team"
path = "projects/agent-team"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[agent-team.pool]
provider = "git"
slots = ["slots/agent-team/1"]
TOML
  # The App is on: a copy of bin/ with the App's id and slug, run in place of this checkout's.
  export CODE_CHECKOUT=$BATS_TEST_TMPDIR/code
  mkdir "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  rm -f "$CODE_CHECKOUT/bin/lib/review-app"
  printf 'id=123456\nslug=team-reviewer\n' >"$CODE_CHECKOUT/bin/lib/review-app"
  KEY=$HOME/.config/agent-team/review-app.pem
  mkdir -p "$HOME/.config/agent-team"
  cp "$BATS_FILE_TMPDIR/key.pem" "$KEY"
  chmod 600 "$KEY"
  export HEAD_SHA
  # T9's PR, its head reviewed and passed.
  ledger_line '{"task":"T9","event":"opened","project":"agent-team"}'
  ledger_line "{\"task\":\"T9\",\"event\":\"pr\",\"url\":\"$URL\",\"project\":\"agent-team\",\"head\":\"$HEAD_SHA\"}"
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$HEAD_SHA\",\"ts\":\"2026-11-12T09:00:00Z\"}"
  stub_reply gh "$HEAD_SHA"
  # curl answers as GitHub would, each call by its method and path: its stdin (the config), its
  # environment and its body file are kept per call, numbered by its line in curl.log. The repo it
  # answers on is APP_REPO, Owner/agent-team by default. A fixture
  # curl.<call> (installation, mint, check-run or revoke) holds "<http code> <body>" to answer
  # instead, or "exit <n>" for a call curl cannot make.
  stub_script curl <<'SH'
method=GET url='' out='' body=''
n=$(wc -l <"$STUB_CALLS/curl.log")
printf '%s\n' "${1-}" >"$STUB_CALLS/curl.first.$n"
# With TOKEN_WATCH set, every file under it that holds the minted token, at each call.
if [[ -n ${TOKEN_WATCH:-} ]]; then grep -rlF -- "$(<"$STUB_FIXTURES/token")" "$TOKEN_WATCH" >>"$STUB_CALLS/curl.disk" || true; fi
while (($#)); do
  case $1 in
    --request) method=$2; shift ;;
    --output) out=$2; shift ;;
    --data-binary) body=${2#@}; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
config=''
IFS= read -r -d '' config || true
printf '%s' "$config" >"$STUB_CALLS/curl.config.$n"
env >"$STUB_CALLS/curl.env.$n"
if [[ -n $body ]]; then cp "$body" "$STUB_CALLS/curl.body.$n"; fi
path=${url#https://api.github.com/}
printf '%s %s\n' "$method" "$path" >>"$STUB_CALLS/curl.calls"
case "$method $path" in
  "GET repos/${APP_REPO:-Owner/agent-team}/installation") call=installation answer='200 {"id": 777}' ;;
  "POST app/installations/777/access_tokens") call=mint answer="201 {\"token\": \"$(<"$STUB_FIXTURES/token")\", \"expires_at\": \"2026-11-12T13:00:00Z\"}" ;;
  "POST repos/${APP_REPO:-Owner/agent-team}/check-runs")
    call=check-run answer='201 {"id": 4242, "name": "agent-review"}'
    # With CHECK_RUN_HOLD set, the post says it started and waits for the test's go, up to 10 s.
    if [[ -n ${CHECK_RUN_HOLD:-} ]]; then
      : >"$CHECK_RUN_HOLD.started"
      for _ in $(seq 100); do [[ ! -e $CHECK_RUN_HOLD.go ]] || break; sleep 0.1; done
    fi
    ;;
  "DELETE installation/token") call=revoke answer='204 ' ;;
  *) echo "curl stub: no answer for $method $url" >&2; exit 99 ;;
esac
if [[ -f $STUB_FIXTURES/curl.$call ]]; then answer=$(<"$STUB_FIXTURES/curl.$call"); fi
if [[ $answer == exit\ * ]]; then
  echo "curl: (7) Failed to connect to api.github.com port 443: Connection refused" >&2
  exit "${answer#exit }"
fi
if [[ -n $out && $out != - ]]; then
  printf '%s' "${answer#* }" >"$out"
  printf '%s' "${answer%% *}"
else
  # The body to stdout, then the HTTP code on a line of its own, as --write-out '\n%{http_code}'.
  printf '%s\n%s' "${answer#* }" "${answer%% *}"
fi
SH
  # The installation token GitHub mints, made at run time.
  TOKEN=fake-installation-token-$RANDOM$RANDOM
  printf '%s' "$TOKEN" >"$STUB_FIXTURES/token"
}

ledger_line() {
  printf '%s\n' "$1" >>"$TEAM_HOME/ledger.jsonl"
}

# The bearer curl was given on call <n>, from its config on stdin.
bearer() {
  sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p' "$STUB_CALLS/curl.config.$1"
}

# A base64url text decoded to stdout.
unbase64url() {
  local text=${1//-/+}
  text=${text//_//}
  while ((${#text} % 4)); do text+='='; done
  printf '%s' "$text" | openssl base64 -d -A
}

curl_calls() {
  cat "$STUB_CALLS/curl.calls" 2>/dev/null || true
}

# PR 5 on a real origin (helpers/queue), its head logged, reviewed and passed, and carrying the
# App's own agent-review success, as a PR that may join the merge queue does.
queued_pr() {
  queue_repo agent-team
  ledger_line "{\"task\":\"T9\",\"event\":\"pr\",\"url\":\"$URL\",\"project\":\"agent-team\",\"head\":\"$QUEUE_HEAD\"}"
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$QUEUE_HEAD\",\"ts\":\"2026-11-14T09:00:00Z\"}"
  head_check 123456 success
}

# --merge-group on <sha> is refused, exit 1 (or GROUP_STATUS), with <text> in what it says, and no call as the App.
group_refused() {
  run_bin "-${GROUP_STATUS:-1}" team-review-check --merge-group "$URL" "$1"
  assert_contains "$output" "$2"
  assert_contains "$output" "nothing posted"
  assert_equal "$(curl_calls)" ""
}

@test "posts agent-review as the App's check run on the reviewed head, with a token for one repository, then revokes it" {
  run_bin --separate-stderr -0 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" 4242
  assert_equal "$stderr" ""
  # The installation read, the mint, the check run and the revoke, in order.
  assert_equal "$(curl_calls)" "GET repos/Owner/agent-team/installation
POST app/installations/777/access_tokens
POST repos/Owner/agent-team/check-runs
DELETE installation/token"
  # The mint names the one repository and checks: write, nothing more.
  assert_equal "$(jq -c . "$STUB_CALLS/curl.body.2")" '{"repositories":["agent-team"],"permissions":{"checks":"write"}}'
  # The check run: agent-review on the exact head, completed, with the conclusion and the summary.
  assert_equal "$(jq -c 'del(.completed_at)' "$STUB_CALLS/curl.body.3")" "$(jq -cn --arg head "$HEAD_SHA" '{name: "agent-review",
    head_sha: $head, status: "completed", conclusion: "success",
    output: {title: "no blocking findings", summary: "no blocking findings"}}')"
  [[ $(jq -r .completed_at "$STUB_CALLS/curl.body.3") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  # The installation read and the mint carry the App's JWT, the check run and the revoke the token.
  local jwt
  jwt=$(bearer 1)
  assert_equal "$(bearer 2)" "$jwt"
  assert_equal "$(bearer 3)" "$TOKEN"
  assert_equal "$(bearer 4)" "$TOKEN"
  # Neither is in any argument of any call, nor in curl's environment.
  run ! grep -qF -e "$jwt" -e "$TOKEN" "$STUB_CALLS/curl.log" "$STUB_CALLS/gh.log" "$STUB_CALLS"/curl.env.*
}

@test "the JWT is RS256, signed by the App's key, issued by the App 60 seconds back and expiring 9 minutes on" {
  local before after jwt header payload
  before=$(date +%s)
  run_bin -0 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  after=$(date +%s)
  jwt=$(bearer 1)
  IFS=. read -r header payload signature <<<"$jwt"
  assert_equal "$(unbase64url "$header" | jq -c .)" '{"alg":"RS256","typ":"JWT"}'
  assert_equal "$(unbase64url "$payload" | jq -r .iss)" 123456
  local iat exp
  iat=$(unbase64url "$payload" | jq .iat) exp=$(unbase64url "$payload" | jq .exp)
  ((iat >= before - 60 && iat <= after - 60 && exp == iat + 600))
  unbase64url "$signature" >"$BATS_TEST_TMPDIR/signature"
  printf '%s.%s' "$header" "$payload" |
    openssl dgst -sha256 -verify "$BATS_FILE_TMPDIR/public.pem" -signature "$BATS_TEST_TMPDIR/signature"
}

@test "failure posts the check run with conclusion failure on a head whose latest review found something" {
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$HEAD_SHA\"}"
  run_bin -0 team-review-check "$URL" "$HEAD_SHA" failure "2 blocking"
  assert_equal "$(jq -r .conclusion "$STUB_CALLS/curl.body.3")" failure
  assert_equal "$(jq -r .output.summary "$STUB_CALLS/curl.body.3")" "2 blocking"
}

@test "a head team-catch-up made stands on the review of the head it was made from" {
  local merge=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  ledger_line "{\"task\":\"T9\",\"event\":\"caught-up\",\"url\":\"$URL\",\"from\":\"$HEAD_SHA\",\"head\":\"$merge\",\"base\":\"cccccccccccccccccccccccccccccccccccccccc\"}"
  stub_reply gh "$merge"
  run_bin -0 team-review-check "$URL" "$merge" success "clean merge of dev onto a1b2c3d, reviewed"
  assert_equal "$(jq -r .head_sha "$STUB_CALLS/curl.body.3")" "$merge"
}

@test "a worker session is refused before anything is read" {
  worker_refused team-review-check "posts no agent-review check" "$URL" "$HEAD_SHA" success "no blocking findings"
}

@test "a malformed command line is refused, exit 2, before any call" {
  local -a cases=(
    "$URL $HEAD_SHA success"
    "$URL ${HEAD_SHA:0:7} success x"
    "$URL $HEAD_SHA pass x"
    "$URL $HEAD_SHA success "
  )
  local line
  for line in "${cases[@]}"; do
    read -r -a args <<<"$line"
    [[ $line != *' ' ]] || args+=('')
    run_bin -2 team-review-check "${args[@]}"
  done
  run_bin -2 team-review-check "$URL" "$HEAD_SHA" success $'two\nlines'
  assert_equal "$output" "team-review-check: the summary is one non-empty line"
  run_bin -2 team-review-check "$URL" "$HEAD_SHA" success "$(printf 'x%.0s' {1..141})"
  assert_equal "$output" "team-review-check: the summary is at most 140 characters, got 141"
  run_bin -2 team-review-check https://example.com/owner/agent-team/pull/5 "$HEAD_SHA" success x
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "with no bin/lib/review-app the App is off, and nothing is posted" {
  rm "$CODE_CHECKOUT/bin/lib/review-app"
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: the reviewer App is off: no bin/lib/review-app names it, so there is no App to post agent-review as"
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a bin/lib/review-app of any other form is refused, naming the file" {
  local -a bodies=('id=123456' 'id=0\nslug=team-reviewer' 'id=12x\nslug=team-reviewer' 'slug=team-reviewer\nid=123456'
    'id=123456\nslug=team-reviewer\nid=7' 'id=123456\nslug=Team Reviewer' '# the App\nid=123456\nslug=team-reviewer')
  local body
  for body in "${bodies[@]}"; do
    printf '%b\n' "$body" >"$CODE_CHECKOUT/bin/lib/review-app"
    run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
    assert_equal "$output" "team-review-check: $CODE_CHECKOUT/bin/lib/review-app is not one id=<n> line and one slug=<s> line"
  done
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a missing key, or one not mode 600, is refused before any call" {
  chmod 644 "$KEY"
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: the reviewer App's key ~/.config/agent-team/review-app.pem is mode 644, not 600: Daniel restores it with team-secrets restore"
  rm "$KEY"
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: the reviewer App's key ~/.config/agent-team/review-app.pem is missing: Daniel restores it with team-secrets restore"
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a sha that is not the PR's head is refused, and nothing is minted" {
  stub_reply gh dddddddddddddddddddddddddddddddddddddddd
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: $URL moved past $HEAD_SHA: its head is now dddddddddddddddddddddddddddddddddddddddd; nothing posted"
  assert_equal "$(stub_calls curl)" ""
}

@test "a verdict the ledger's latest review of the head does not hold is refused, and nothing is read from GitHub" {
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" failure "2 blocking"
  assert_equal "$output" "team-review-check: T9's latest review of a1b2c3d, at 2026-11-12T09:00:00Z, is pass, so agent-review on it is success, not failure; nothing posted"
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$HEAD_SHA\",\"ts\":\"2026-11-12T10:00:00Z\"}"
  run_bin -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: T9's latest review of a1b2c3d, at 2026-11-12T10:00:00Z, is findings, so agent-review on it is failure, not success; nothing posted"
  # A head no review names, and no catch-up made, has none.
  local other=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  run_bin -1 team-review-check "$URL" "$other" success "no blocking findings"
  assert_equal "$output" "team-review-check: T9 logged no review of eeeeeee, so no reviewer's verdict is there to post; nothing posted"
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a PR no task's pr event names is refused" {
  run_bin -1 team-review-check https://github.com/owner/agent-team/pull/6 "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" "team-review-check: no task's pr event names https://github.com/owner/agent-team/pull/6, so no review of it is logged; nothing posted"
  assert_equal "$(stub_calls gh)$(stub_calls curl)" ""
}

@test "a failed installation read or mint posts nothing and has no token to revoke" {
  echo '404 {"message": "Not Found"}' >"$STUB_FIXTURES/curl.installation"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: reading the App's installation on Owner/agent-team failed: GitHub answered HTTP 404: Not Found (the reviewer App is not installed for Owner, or Owner/agent-team moved and bin/lib/repo-moves.json lacks the move); nothing posted"
  assert_equal "$(curl_calls)" "GET repos/Owner/agent-team/installation"
  # A moved repository's redirect, which is never followed, has the same two causes; any other
  # answer has GitHub's alone.
  echo '301 {"message": "Moved Permanently"}' >"$STUB_FIXTURES/curl.installation"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: reading the App's installation on Owner/agent-team failed: GitHub answered HTTP 301: Moved Permanently (the reviewer App is not installed for Owner, or Owner/agent-team moved and bin/lib/repo-moves.json lacks the move); nothing posted"
  echo '401 {"message": "Bad credentials"}' >"$STUB_FIXTURES/curl.installation"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: reading the App's installation on Owner/agent-team failed: GitHub answered HTTP 401: Bad credentials; nothing posted"
  rm "$STUB_FIXTURES/curl.installation" "$STUB_CALLS/curl.calls"
  echo 'exit 7' >"$STUB_FIXTURES/curl.mint"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: minting the App's token for Owner/agent-team failed: curl: (7) Failed to connect to api.github.com port 443: Connection refused; nothing posted"
  assert_equal "$(curl_calls)" "GET repos/Owner/agent-team/installation
POST app/installations/777/access_tokens"
}

@test "a failed check run still revokes the token, and says the post failed" {
  echo '422 {"message": "No commit found for SHA"}' >"$STUB_FIXTURES/curl.check-run"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" ""
  assert_equal "$stderr" "team-review-check: posting the agent-review check run on Owner/agent-team@$HEAD_SHA failed: GitHub answered HTTP 422: No commit found for SHA; nothing posted"
  assert_equal "$(curl_calls | tail -n 1)" "DELETE installation/token"
  assert_equal "$(bearer 4)" "$TOKEN"
  rm "$STUB_FIXTURES/curl.check-run" "$STUB_CALLS/curl.calls"
  echo 'exit 28' >"$STUB_FIXTURES/curl.check-run"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: posting the agent-review check run on Owner/agent-team@$HEAD_SHA failed: curl: (7) Failed to connect to api.github.com port 443: Connection refused; whether GitHub took it is unknown: read the head's agent-review check runs before posting again"
  assert_equal "$(curl_calls | tail -n 1)" "DELETE installation/token"
}

@test "a failed revoke after the post prints the check run and says the token was not revoked" {
  echo '500 {"message": "Server Error"}' >"$STUB_FIXTURES/curl.revoke"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" 4242
  assert_equal "$stderr" "team-review-check: revoking the App's token failed: GitHub answered HTTP 500: Server Error; it expires on its own within the hour"
}

@test "a token GitHub answers in any other form is refused, and nothing is posted or sent with it" {
  printf '%s' 'bad token' >"$STUB_FIXTURES/token"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: minting the App's token for Owner/agent-team failed: GitHub's answer holds no token of the expected form; nothing posted"
  assert_equal "$(curl_calls | tail -n 1)" "POST app/installations/777/access_tokens"
}

@test "the minted token is written to no file while the script runs" {
  export TOKEN_WATCH=$BATS_TEST_TMPDIR/tmp
  mkdir "$TOKEN_WATCH"
  TMPDIR=$TOKEN_WATCH run_bin -0 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$(curl_calls | wc -l)" 4
  assert_equal "$(cat "$STUB_CALLS/curl.disk" 2>/dev/null)" ""
}

@test "curl reads no user config: -q is its first argument on every call" {
  run_bin -0 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$(cat "$STUB_CALLS"/curl.first.* | sort -u)" "-q"
}

@test "a review logged on a short head does not stand for a full sha that shares its prefix" {
  local ground=a1b2c3d999999999999999999999999999999999
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"a1b2c3d\",\"ts\":\"2026-11-12T10:00:00Z\"}"
  stub_reply gh "$ground"
  run_bin -1 team-review-check "$URL" "$ground" success "no blocking findings"
  assert_equal "$output" "team-review-check: T9's review of a1b2c3d, at 2026-11-12T10:00:00Z, names its head by a prefix, not in full, so it stands for no full sha; nothing posted"
  assert_equal "$(stub_calls curl)" ""
}

@test "a TERM while the check run is posted still revokes the token" {
  export CHECK_RUN_HOLD=$BATS_TEST_TMPDIR/hold
  "$CODE_CHECKOUT/bin/team-review-check" "$URL" "$HEAD_SHA" success "no blocking findings" \
    >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err" 3>&- &
  local pid=$!
  for _ in $(seq 100); do [[ ! -e $CHECK_RUN_HOLD.started ]] || break; sleep 0.1; done
  [[ -e $CHECK_RUN_HOLD.started ]]
  kill -TERM "$pid"
  : >"$CHECK_RUN_HOLD.go"
  wait "$pid" || true
  assert_equal "$(curl_calls | tail -n 1)" "DELETE installation/token"
  assert_equal "$(bearer "$(($(curl_calls | wc -l) - 1))")" "$TOKEN"
}

@test "GitHub's message is read from a pretty-printed answer, as its REST API answers" {
  printf '404 {\n  "message": "Not Found"\n}\n' >"$STUB_FIXTURES/curl.installation"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: reading the App's installation on Owner/agent-team failed: GitHub answered HTTP 404: Not Found (the reviewer App is not installed for Owner, or Owner/agent-team moved and bin/lib/repo-moves.json lacks the move); nothing posted"
  rm "$STUB_FIXTURES/curl.installation"
  printf '500 {\n  "message": "Server Error"\n}\n' >"$STUB_FIXTURES/curl.revoke"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$output" 4242
  assert_equal "$stderr" "team-review-check: revoking the App's token failed: GitHub answered HTTP 500: Server Error; it expires on its own within the hour"
}

@test "a PR logged under one owner of a moved repo is found by the other's URL, and the App reads, mints and posts on the new owner's repo" {
  local old=https://github.com/chanjdaniel/agent-team/pull/5 new=https://github.com/Chan-Software-Services/agent-team/pull/5
  export APP_REPO=Chan-Software-Services/agent-team
  # <ledger's url> <given url> <registry's repo>: the registry under either owner.
  local -a cases=(
    "$old $new Chan-Software-Services/agent-team"
    "$new $old Chan-Software-Services/agent-team"
    "$old $new chanjdaniel/agent-team"
    "$new $old chanjdaniel/agent-team"
    "$old $old chanjdaniel/agent-team"
  )
  local line logged given registry
  for line in "${cases[@]}"; do
    read -r logged given registry <<<"$line"
    sed -i "s#^repo = .*#repo = \"$registry\"#" "$TEAM_HOME/projects.toml"
    : >"$TEAM_HOME/ledger.jsonl"
    ledger_line '{"task":"T9","event":"opened","project":"agent-team"}'
    ledger_line "{\"task\":\"T9\",\"event\":\"pr\",\"url\":\"$logged\",\"project\":\"agent-team\",\"head\":\"$HEAD_SHA\"}"
    ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$HEAD_SHA\",\"ts\":\"2026-11-12T09:00:00Z\"}"
    rm -f "$STUB_CALLS/curl.calls" "$STUB_CALLS/gh.log"
    run_bin --separate-stderr -0 team-review-check "$given" "$HEAD_SHA" success "no blocking findings"
    assert_equal "$output" 4242
    assert_equal "$(curl_calls)" "GET repos/Chan-Software-Services/agent-team/installation
POST app/installations/777/access_tokens
POST repos/Chan-Software-Services/agent-team/check-runs
DELETE installation/token"
    assert_equal "$(stub_calls gh | jq -r '.[4]')" Chan-Software-Services/agent-team
  done
}

@test "a redirect from GitHub is never followed: a 301 is reported as GitHub's answer, with its causes on the installation read, and nothing is posted" {
  echo '301 {"message": "Moved Permanently", "url": "https://api.github.com/repositories/42/installation"}' \
    >"$STUB_FIXTURES/curl.installation"
  run_bin --separate-stderr -1 team-review-check "$URL" "$HEAD_SHA" success "no blocking findings"
  assert_equal "$stderr" "team-review-check: reading the App's installation on Owner/agent-team failed: GitHub answered HTTP 301: Moved Permanently (the reviewer App is not installed for Owner, or Owner/agent-team moved and bin/lib/repo-moves.json lacks the move); nothing posted"
  assert_equal "$(curl_calls)" "GET repos/Owner/agent-team/installation"
  # curl is never told to follow one.
  assert_equal "$(stub_calls curl | jq -c '[.[] | select(test("^(-L|--location(-trusted)?)$"))]')" "[]"
  assert_equal "$(stub_calls curl | wc -l)" 1
}

@test "--merge-group posts success on the queue's trial commit that is the reviewed head merged cleanly onto the entry's base" {
  queued_pr
  local trial
  trial=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD")
  queue_entry "$trial"
  # The primary checkout holds neither the base nor the trial commit until the script fetches them.
  run ! git -C "${QUEUE_PRIMARY:?}" cat-file -e "$trial"
  run_bin --separate-stderr -0 team-review-check --merge-group "$URL" "$trial"
  assert_equal "$output" 4242
  assert_equal "$stderr" ""
  assert_equal "$(curl_calls)" "GET repos/Owner/agent-team/installation
POST app/installations/777/access_tokens
POST repos/Owner/agent-team/check-runs
DELETE installation/token"
  assert_equal "$(jq -c 'del(.completed_at)' "$STUB_CALLS/curl.body.3")" "$(jq -cn --arg trial "$trial" --arg head "${QUEUE_HEAD:0:7}" '
    "the merge queue'"'"'s clean merge of the reviewed head \($head)" as $summary
    | {name: "agent-review", head_sha: $trial, status: "completed", conclusion: "success",
       output: {title: $summary, summary: $summary}}')"
  # GitHub is read for the PR's queue entry and the head's agent-review check runs, nothing else.
  assert_equal "$(stub_calls gh | jq -c 'if .[1] == "graphql" then [.[0, 1], .[4:][]] else . end')" "$(jq -cn --arg head "$QUEUE_HEAD" '
    ["api", "graphql", "-f", "owner=Owner", "-f", "name=agent-team", "-F", "number=5"],
    ["api", "repos/Owner/agent-team/commits/\($head)/check-runs?check_name=agent-review&filter=latest&per_page=100"]')"
  assert_contains "$(stub_calls gh | jq -r 'select(.[1] == "graphql") | .[3]')" "mergeQueueEntry { state headCommit { oid } baseCommit { oid } }"
  # No ref of the primary checkout moved, and its worktree is as it was.
  assert_equal "$(git -C "${QUEUE_PRIMARY:?}" for-each-ref --format='%(refname)' | grep -c queue || true)" 0
  assert_equal "$(git -C "${QUEUE_PRIMARY:?}" status --porcelain)" ""
}

@test "--merge-group posts on a trial commit built on the trial commit ahead of it, which holds the entry's base" {
  queued_pr
  local ahead other trial
  # Another PR's head, merged ahead of this one in the queue.
  other=$(git -C "${QUEUE_PRIMARY:?}" commit-tree "$(git -C "${QUEUE_PRIMARY:?}" rev-parse "dev^{tree}")" -p dev -m "feat: another PR")
  git -C "${QUEUE_PRIMARY:?}" push -q origin "$other:refs/heads/feat/other"
  ahead=$(trial_commit "$QUEUE_BASE" "$other")
  trial=$(trial_commit "$ahead" "$QUEUE_HEAD")
  queue_entry "$trial"
  run_bin -0 team-review-check --merge-group "$URL" "$trial"
  assert_equal "$output" 4242
  assert_equal "$(jq -r .head_sha "$STUB_CALLS/curl.body.3")" "$trial"
}

@test "--merge-group refuses a trial commit with any problem, naming the first, and posts nothing" {
  queued_pr
  local clean trial later other
  clean=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD")
  # The PR in no queue, and an entry with another trial commit, or none yet.
  group_refused "$clean" "Owner/agent-team#5 is not in the merge queue"
  queue_entry "$QUEUE_HEAD"
  group_refused "$clean" "${clean:0:7} is not the trial commit of Owner/agent-team#5's queue entry, which is ${QUEUE_HEAD:0:7}"
  jq '.data.repository.pullRequest.mergeQueueEntry.headCommit = null' "$GH_DIR/entry.json" >"$GH_DIR/entry.next"
  mv "$GH_DIR/entry.next" "$GH_DIR/entry.json"
  group_refused "$clean" "the queue entry of Owner/agent-team#5 has no trial commit yet"
  # An entry GitHub cannot merge.
  queue_entry "$clean" UNMERGEABLE
  group_refused "$clean" "the queue entry of Owner/agent-team#5 is UNMERGEABLE"
  # One parent, and three.
  trial=$(trial_commit "$QUEUE_BASE" '' "$clean")
  queue_entry "$trial"
  group_refused "$trial" "${trial:0:7} is a commit of its own, not a merge of the PR's head"
  local clone=$BATS_TEST_TMPDIR/queue-clone
  trial=$(git -C "${clone:?}" commit-tree "$(git -C "${clone:?}" rev-parse "$clean^{tree}")" \
    -p "$QUEUE_BASE" -p "$QUEUE_HEAD" -p "$QUEUE_BASE~1" -m "Merge three")
  git -C "${clone:?}" push -q origin "$trial:refs/heads/gh-readonly-queue/dev/three"
  queue_entry "$trial"
  group_refused "$trial" "${trial:0:7} merges 3 parents at once, not the PR's head alone"
  # A second parent that is not the PR's head: a commit pushed after the review.
  other=$(git -C "${QUEUE_PRIMARY:?}" commit-tree "$(git -C "${QUEUE_PRIMARY:?}" rev-parse "$QUEUE_HEAD^{tree}")" -p "$QUEUE_HEAD" -m "feat: unreviewed")
  git -C "${QUEUE_PRIMARY:?}" push -q origin "$other:refs/heads/feat/unreviewed"
  trial=$(trial_commit "$QUEUE_BASE" "$other")
  queue_entry "$trial"
  group_refused "$trial" "${trial:0:7} merges ${other:0:7}, which is not the PR's head ${QUEUE_HEAD:0:7}"
  # The parents the other way round: the head first.
  trial=$(trial_commit "$QUEUE_HEAD" "$QUEUE_BASE")
  queue_entry "$trial"
  group_refused "$trial" "${trial:0:7} merges ${QUEUE_BASE:0:7}, which is not the PR's head ${QUEUE_HEAD:0:7}"
  # A first parent that lacks the entry's base: the base moved on, the trial commit did not.
  later=$(push_to_dev "$QUEUE_ORIGIN" src/later.py)
  queue_entry "$clean" AWAITING_CHECKS "$later"
  group_refused "$clean" "${clean:0:7} merges the head onto ${QUEUE_BASE:0:7}, which does not hold the queue entry's base ${later:0:7}"
  # A tree that is not the merge of its parents: the head's alone, which drops the base's change.
  trial=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD" "$QUEUE_HEAD")
  queue_entry "$trial"
  group_refused "$trial" "${trial:0:7} changes more than the merge of its parents"
  # Parents that conflict: the base adds the file the head adds.
  later=$(push_to_dev "$QUEUE_ORIGIN" src/tool.py)
  trial=$(trial_commit "$later" "$QUEUE_HEAD" "$QUEUE_HEAD")
  queue_entry "$trial" AWAITING_CHECKS "$later"
  group_refused "$trial" "${trial:0:7} is no clean merge: ${QUEUE_HEAD:0:7} conflicts with ${later:0:7}"
  # A project that does not merge with a merge commit, on the clean trial commit.
  queue_entry "$clean"
  sed -i 's/^merge_method = "merge"/merge_method = "squash"/' "$TEAM_HOME/projects.toml"
  group_refused "$clean" "agent-team merges with squash, and a trial commit is proved only for merge"
  # And with the method back, the same trial commit posts.
  sed -i 's/^merge_method = "squash"/merge_method = "merge"/' "$TEAM_HOME/projects.toml"
  run_bin -0 team-review-check --merge-group "$URL" "$clean"
  assert_equal "$output" 4242
}

@test "--merge-group refuses a clean trial commit of a head that is not reviewed and passed, or lacks the App's own agent-review success" {
  queue_repo agent-team
  local trial
  trial=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD")
  queue_entry "$trial"
  head_check 123456 success
  # The head is logged, but no review of it is.
  ledger_line "{\"task\":\"T9\",\"event\":\"pr\",\"url\":\"$URL\",\"project\":\"agent-team\",\"head\":\"$QUEUE_HEAD\"}"
  group_refused "$trial" "T9 logged no review of ${QUEUE_HEAD:0:7}"
  # No check run is read for a head the ledger does not pass.
  assert_equal "$(stub_calls gh | jq -c 'select(.[1] != "graphql")')" ""
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"findings\",\"head\":\"$QUEUE_HEAD\",\"ts\":\"2026-11-14T09:00:00Z\"}"
  group_refused "$trial" "T9's latest review of ${QUEUE_HEAD:0:7}, at 2026-11-14T09:00:00Z, is findings"
  ledger_line "{\"task\":\"T9\",\"event\":\"review\",\"verdict\":\"pass\",\"head\":\"$QUEUE_HEAD\",\"ts\":\"2026-11-14T10:00:00Z\"}"
  # Reviewed and passed, but the head's agent-review is missing, a failure, or another App's.
  echo '{"check_runs": []}' >"$GH_DIR/runs.json"
  group_refused "$trial" "head $QUEUE_HEAD carries no agent-review success of the reviewer App 123456"
  head_check 123456 failure
  group_refused "$trial" "head $QUEUE_HEAD carries no agent-review success of the reviewer App 123456"
  head_check 15368 success
  group_refused "$trial" "head $QUEUE_HEAD carries no agent-review success of the reviewer App 123456"
  # A success of the App's on another commit is not the head's.
  jq --arg other "$QUEUE_BASE" '.check_runs[0] |= (.app.id = 123456 | .head_sha = $other)' "$GH_DIR/runs.json" >"$GH_DIR/runs.next"
  mv "$GH_DIR/runs.next" "$GH_DIR/runs.json"
  group_refused "$trial" "head $QUEUE_HEAD carries no agent-review success of the reviewer App 123456"
  head_check 123456 success
  run_bin -0 team-review-check --merge-group "$URL" "$trial"
}

@test "--merge-group posts nothing, exit 75 to try again, when the queue entry or the trial commit cannot be read" {
  queued_pr
  local trial
  trial=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD")
  queue_entry "$trial"
  echo "HTTP 502: Bad Gateway" >"$GH_DIR/entry.error"
  GROUP_STATUS=75 group_refused "$trial" "the merge queue entry of Owner/agent-team#5 cannot be read: gh api graphql: HTTP 502: Bad Gateway"
  rm "$GH_DIR/entry.error"
  echo '{"data": {"repository": {"pullRequest": null}}}' >"$GH_DIR/entry.json"
  GROUP_STATUS=75 group_refused "$trial" "the merge queue entry of Owner/agent-team#5 cannot be read: gh api graphql: no such pull request"
  # A trial commit origin does not hold.
  local gone=1111111111111111111111111111111111111111
  queue_entry "$gone"
  GROUP_STATUS=75 group_refused "$gone" "the trial commit 1111111 and the head ${QUEUE_HEAD:0:7} cannot be fetched into $QUEUE_PRIMARY: "
  # The head's check runs unread.
  queue_entry "$trial"
  echo "not json" >"$GH_DIR/runs.json"
  group_refused "$trial" "carries no agent-review success"
}

@test "--merge-group ends with exit 75, to try again, when a call as the App fails with no check run posted" {
  queued_pr
  local trial
  trial=$(trial_commit "$QUEUE_BASE" "$QUEUE_HEAD")
  queue_entry "$trial"
  echo "exit 7" >"$STUB_FIXTURES/curl.mint"
  run_bin -75 team-review-check --merge-group "$URL" "$trial"
  assert_contains "$output" "minting the App's token for Owner/agent-team failed"
  assert_contains "$output" "nothing posted"
  # The head's form still ends such a failure with exit 1.
  run_bin -1 team-review-check "$URL" "$QUEUE_HEAD" success "no blocking findings"
}

@test "--merge-group takes a PR URL and a full sha, nothing more or less" {
  local -a cases=(
    "--merge-group"
    "--merge-group $URL"
    "--merge-group $URL $HEAD_SHA success"
    "--merge-group $URL $HEAD_SHA success x"
    "--merge-group $URL ${HEAD_SHA:0:7}"
    "--merge-group https://github.com/owner/agent-team/pull/5/files $HEAD_SHA"
    "$URL --merge-group $HEAD_SHA"
  )
  local args
  for args in "${cases[@]}"; do
    # shellcheck disable=SC2086 # each case is its words
    run_bin -2 team-review-check $args
  done
  assert_equal "$(curl_calls)" ""
  assert_equal "$(stub_calls gh)" ""
}
