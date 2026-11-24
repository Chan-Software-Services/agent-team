# shellcheck shell=bash
# shellcheck disable=SC2154 # wt is helpers/load-check.bash's
# The refusal probe's sandbox and readers, shared by the tests/team-load-check-probe-*.bats files
# of team-load-check --probe: load it with `load helpers/load-check-probe` after `load
# helpers/common`, `load helpers/load-check` and `load helpers/transcript`, and call
# probe_sandbox in setup. Each function below says what it does.
#
# team-load-check --probe launches one T0 session per worker role through team-worker in the load
# check's worktree (helpers/load-check), or the assistant's through claude-assistant --load-check,
# each told to make its role's attempts of bin/lib/probe.json, and prints a PASS or FAIL line per
# role and attempt from what its transcript shows refused each call.
#
# The sessions are a claude stub (planner 1a1a1a1a, builder 2b2b2b2b, reviewer 3c3c3c3c, assistant
# 4d4d4d4d, topic 5e5e5e5e), whose argv each launch also keeps in $BATS_TEST_TMPDIR/argv-<role>: claude --bg
# notes in $BATS_TEST_TMPDIR/launch-<role> where it started, whether .scratch/probe.git was a bare
# repository then, and its prompt, and in $BATS_TEST_TMPDIR/canary-<role> the role's canary
# directory, read from its prompt's kernel-delete line, and whether each kernel attempt's canary
# stood then; copies $STUB_FIXTURES/<role>.jsonl to its transcript (none when the file is absent),
# @CANARY@ in it replaced by that directory; removes the canary of each attempt
# $STUB_FIXTURES/uncanary-<role> names, one id per line, as an unconfined session would; writes
# .scratch/probe-done-<role>.txt unless $STUB_FIXTURES/undone-<role> exists; runs
# $STUB_FIXTURES/session-does when a test writes it; and fails when $STUB_FIXTURES/fail-<role>
# exists. claude agents lists each launched session until claude rm, in the state
# $STUB_FIXTURES/state-<role> holds (idle by default), and leaves out one whose state is gone;
# claude mcp list lists no server. The transcripts are built by probe_transcript from the data
# file's attempts and helpers/transcript's shapes, a hook's block from the real hook and a
# script's refusal from the real script.

# probe_sandbox: load_check_sandbox, then the claude stub above and each role's transcript, as
# probe_transcript makes it
probe_sandbox() {
  load_check_sandbox
  stub_script claude <<'SH'
declare -A ids=([planner]=1a1a1a1a [builder]=2b2b2b2b [reviewer]=3c3c3c3c [assistant]=4d4d4d4d [topic]=5e5e5e5e)
uuid() { echo "$1-0000-4000-8000-000000000001"; }
case $1 in
  --bg)
    argv=("$@")
    while [[ $1 != --name ]]; do shift; done
    role=${2#T0-} id=${ids[${2#T0-}]}
    printf '%s\n' "${argv[@]}" >"$BATS_TEST_TMPDIR/argv-$role"
    [[ ! -e $STUB_FIXTURES/fail-$role ]] || { echo "launch failed" >&2; exit 1; }
    { pwd -P; git -C .scratch/probe.git rev-parse --is-bare-repository 2>/dev/null || echo 'no probe.git'
      echo "${*: -1}"; } >"$BATS_TEST_TMPDIR/launch-$role"
    canary=$(sed -n 's|.*os\.rmdir("\(.*\)/kernel-delete").*|\1|p' <<<"${*: -1}" | head -n 1)
    { echo "$canary"; ls "$canary" 2>/dev/null || true; } >"$BATS_TEST_TMPDIR/canary-$role"
    if [[ -f $STUB_FIXTURES/$role.jsonl ]]; then
      mkdir -p "$HOME/.claude/projects/-wt"
      sed "s|@CANARY@|$canary|g" "$STUB_FIXTURES/$role.jsonl" >"$HOME/.claude/projects/-wt/$(uuid "$id").jsonl"
    fi
    if [[ -n $canary && -f $STUB_FIXTURES/uncanary-$role ]]; then
      while IFS= read -r gone; do rmdir "$canary/$gone"; done <"$STUB_FIXTURES/uncanary-$role"
    fi
    [[ -e $STUB_FIXTURES/undone-$role ]] || echo done >".scratch/probe-done-$role.txt"
    touch "$STUB_FIXTURES/launched-$role"
    # What a test has the session do once it runs, a script.
    [[ ! -f $STUB_FIXTURES/session-does ]] || bash "$STUB_FIXTURES/session-does"
    echo "Started background session $id ($2). Attach with: claude attach $id"
    ;;
  agents)
    for role in planner builder reviewer topic assistant; do
      id=${ids[$role]} state=idle
      [[ -f $STUB_FIXTURES/launched-$role && ! -f $STUB_FIXTURES/removed-$id ]] || continue
      [[ ! -f $STUB_FIXTURES/state-$role ]] || state=$(cat "$STUB_FIXTURES/state-$role")
      [[ $state != gone ]] || continue
      jq -cn --arg id "$id" --arg name "T0-$role" --arg state "$state" --arg uuid "$(uuid "$id")" \
        '{id: $id, name: $name, state: $state, sessionId: $uuid}'
    done | jq -s .
    ;;
  --setting-sources | --settings)
    # claude [--setting-sources user] --settings <file> auto-mode config, the first form a
    # planner's, builder's or reviewer's and the second ops's: the file's autoMode lists,
    # "$defaults" read as one built-in line, or $STUB_FIXTURES/automode.json when the test writes one
    if [[ $1 == --setting-sources ]]; then
      [[ ${2:-} == user ]] || exit 64
      shift 2
    fi
    [[ ${1:-} == --settings && ${3:-} == auto-mode && ${4:-} == config ]] || exit 64
    pwd -P >>"$BATS_TEST_TMPDIR/automode-cwd"
    if [[ -f $STUB_FIXTURES/automode.json ]]; then cat "$STUB_FIXTURES/automode.json"
    else jq '(.autoMode // {}) | map_values(map(if . == "$defaults" then "a built-in line" else . end))' "$2"; fi
    ;;
  --version) echo '2.1.321 (Claude Code)' ;;
  mcp) ;;
  stop) ;;
  rm) touch "$STUB_FIXTURES/removed-$2" ;;
  *) exit 64 ;;
esac
SH
  local role
  for role in planner builder reviewer topic assistant; do probe_transcript "$role"; done
}

# The data file the load check reads: the test's own checkout's when it made one.
data() { echo "${CODE_CHECKOUT:-$REPO_ROOT}/bin/lib/probe.json"; }

# login: the worker login the load check's checkout names, nothing while it is off
login() {
  local file=${CODE_CHECKOUT:-$REPO_ROOT}/bin/lib/worker-login
  [[ ! -f $file ]] || sed -n 's/^login=//p' "$file"
}

# attempts <role>: the role's attempts as the load check makes them, one JSON object per line, but
# for @CANARY@, which stands until the claude stub fills it in a transcript, since the load check
# names the canary directory only when it runs, and those expecting login, or whose marker is the
# worker login (@LOGIN@), only while the worker login is on
attempts() {
  jq -c --arg role "$1" --arg home "$HOME" --arg login "$(login)" '.attempts[]
    | select(any(.roles[]; . == $role)
      and ((.expect != "login" and ((.marker // "") | contains("@LOGIN@") | not)) or $login != ""))
    | .input |= (split("@HOME@") | join($home))
    | if .marker != null then .marker |= (split("@LOGIN@") | join($login)) else . end' "$(data)"
}

# probe_transcript <role> [<id>=<outcome>[,<outcome>]...]...: <role>'s transcript in
# $STUB_FIXTURES/<role>.jsonl: one call per attempt, in order, refused as it expects (hook: the
# block of the data file's first hook whose message holds the attempt's marker, on the call in the
# worktree, or a hook's block naming no marker for an attempt that has none; rule: a deny rule,
# file-rule's shape for a file tool; script: the script's own refusal, run for the role; kernel:
# it ran with the kernel's refusal as its result, after its marker when it has one, a background
# attempt's call made with run_in_background; allowed: it ran and printed its marker; refused: auto
# mode, or for the assistant, in bypass mode, a deny rule), or
# for an attempt named, one call per outcome given: hook, other-hook (a block by another hook's
# message), script (the script's own refusal, its input's bin/ dropped), marked (a call that ran and
# printed the attempt's marker), no-marker (a kernel attempt's refusal after its
# marker's name with no value), not-found (a call whose shell never found its command, exit 127,
# as bash words it), none (a call with no result), skip (no call at all), as-<text> (a
# call that ran and printed <text>, which a login attempt does by default with the worker login),
# or any outcome tool_result takes (ran, failed, rule, file-rule, automode, no-verdict,
# safety-check, user-rejected). A
# Write's or Read's relative input is made by its absolute path in the worktree, as Claude Code
# records it.
probe_transcript() {
  local role=$1 attempt id tool input expect marker outcomes outcome n=0 call hook result background
  local -A given=()
  shift
  while [[ $# -gt 0 ]]; do given[${1%%=*}]=${1#*=}; shift; done
  : >"$STUB_FIXTURES/$role.jsonl"
  while IFS= read -r attempt; do
    id=$(jq -r .id <<<"$attempt") tool=$(jq -r .tool <<<"$attempt") input=$(jq -r .input <<<"$attempt")
    expect=$(jq -r .expect <<<"$attempt") marker=$(jq -r '.marker // ""' <<<"$attempt")
    background=$(jq -c '.background == true' <<<"$attempt")
    case $tool in
      Bash) call=$(jq -cn --arg c "$input" --argjson bg "$background" \
        '{command: $c, description: "probe"} + (if $bg then {run_in_background: true} else {} end)') ;;
      Write) [[ $input == /* ]] || input=$wt/$input; call=$(jq -cn --arg p "$input" '{file_path: $p, content: "probe"}') ;;
      *) [[ $input == /* ]] || input=$wt/$input; call=$(jq -cn --arg p "$input" '{file_path: $p}') ;;
    esac
    case $role:$expect:$tool in
      *:hook:*) outcomes=hook ;; *:rule:Bash) outcomes=rule ;; *:rule:*) outcomes='file-rule' ;; *:script:*) outcomes=script ;;
      *:kernel:*) outcomes=refused-by-kernel ;; *:login:*) outcomes=as-$(login) ;; *:allowed:*) outcomes=marked ;;
      assistant:*) outcomes=rule ;; *) outcomes=automode ;;
    esac
    outcomes=${given[$id]:-$outcomes}
    for outcome in ${outcomes//,/ }; do
      [[ $outcome != skip ]] || continue
      n=$((n + 1))
      tool_call "toolu_$role$n" "$tool" "$call"
      case $outcome in
        hook)
          if [[ -z $marker ]]; then
            tool_result "toolu_$role$n" hook $'PreToolUse:Bash hook error: [command hook 1]: Blocked: a hook\n'
            continue
          fi
          result=''
          for hook in $(jq -r '.hooks[].hook' "$(data)"); do
            result=$(hook_result "toolu_$role$n" "$hook" "$tool" "$call" "$wt" "$role" 2>/dev/null) || continue
            [[ $result != *"$marker"* ]] || break
          done
          [[ $result == *"$marker"* ]] || { echo "probe_transcript: no hook blocked $id with its marker" >&2; return 1; }
          echo "$result" ;;
        other-hook) tool_result "toolu_$role$n" hook $'PreToolUse:Bash hook error: [command hook 1]: Blocked: something else\n' ;;
        as-*) tool_result "toolu_$role$n" ran "${outcome#as-}"$'\n' ;;
        script)
          result=$(script_result "toolu_$role$n" "${input#bin/}" "$role") || return 1
          [[ $expect != script || $result == *"$marker"* ]] ||
            { echo "probe_transcript: bin/ refused $id without its marker" >&2; return 1; }
          echo "$result" ;;
        marked) tool_result "toolu_$role$n" ran "$marker"$'\n' ;;
        not-found) tool_result "toolu_$role$n" failed "Exit code 127"$'\n'"/bin/bash: line 1: ${input%% *}: command not found" ;;
        none) ;;
        refused-by-kernel) tool_result "toolu_$role$n" ran "${marker:+$marker$'\n'}PermissionError: [Errno 13] Permission denied: 'kernel-delete'" ;;
        no-marker) tool_result "toolu_$role$n" ran "${marker%=*}="$'\n'"PermissionError: [Errno 13] Permission denied: 'kernel-delete'" ;;
        *) tool_result "toolu_$role$n" "$outcome" ;;
      esac
    done
  done < <(attempts "$role") >>"$STUB_FIXTURES/$role.jsonl"
}

# call_id <role> <pattern>: the id of the Bash call in <role>'s transcript whose command matches
# the regular expression <pattern>
call_id() {
  jq -r --arg re "$2" 'select(.type == "assistant") | .message.content[0]
    | select(.input.command? // "" | test($re)) | .id' "$STUB_FIXTURES/$1.jsonl"
}

# passes <role>...: the PASS line of each attempt of each role, refused as it expects (a refused
# attempt by auto mode, the assistant's by a deny rule, a login attempt answered with the worker
# login, an allowed attempt run), in order
passes() {
  local role
  for role; do
    attempts "$role" | jq -r --arg role "$role" --arg login "$(login)" '"PASS \($role) \(.id): " +
      (if .expect == "refused" then "refused by \(if $role == "assistant" then "rule" else "automode" end)"
        elif .expect == "login" then "the session'\''s GitHub login is \($login)"
        elif .expect == "allowed" then "ran"
        else "\(.expect) refused it" end)'
  done
}

# verdicts: the output's PASS and FAIL lines of attempts, in order
verdicts() { grep -E '^(PASS|FAIL) (planner|builder|reviewer|topic|assistant) [a-z-]+: ' <<<"$output" || true; }

# github_lines: the output's github lines, in order
github_lines() { grep -E '^(PASS|FAIL|WARN) github ' <<<"$output" || true; }

# launched: the roles claude --bg started, in order
launched() { stub_calls claude | jq -r 'select(.[0] == "--bg") | .[index("--name") + 1] | ltrimstr("T0-")'; }

# probe_checkout <attempts JSON array>: a code checkout of the test's own for run_bin, holding this
# one's bin/, roles/, settings/ and the assistant's settings, its data file's attempts replaced by
# <attempts>
probe_checkout() {
  export CODE_CHECKOUT=$BATS_TEST_TMPDIR/probe-code
  mkdir -p "$CODE_CHECKOUT"
  copy_bin "$CODE_CHECKOUT/bin"
  cp -R "$REPO_ROOT/roles" "$REPO_ROOT/settings" "$REPO_ROOT/assistant.settings.json" "$CODE_CHECKOUT/"
  # bin/'s files are links to the run's shared copy: replace the file, never write into it.
  rm "$CODE_CHECKOUT/bin/lib/probe.json"
  jq --argjson attempts "$1" '.attempts = $attempts' "$REPO_ROOT/bin/lib/probe.json" >"$CODE_CHECKOUT/bin/lib/probe.json"
}

# total: the attempts of the four roles together
total() { local role; for role in planner builder reviewer topic; do attempts "$role"; done | wc -l; }

# login_on: the worker login on (worker_login_on, as team-worker-bot) in a code checkout of the test's own
# holding the data file's own attempts, a registry that also names the team's own project,
# agent-team (own_registry: repo owner/agent-team, base main), the sessions' transcripts made again with their
# login attempts, and a stub gh answering as GitHub would by method and path: the repository read
# as $STUB_FIXTURES/repo-read says (an HTTP status, default 200) with GitHub's own spelling of its
# owner and name, Owner/Agent-Team; the open pull requests into the base as $STUB_FIXTURES/pulls
# lists them (default PR 7); and each github call as $STUB_FIXTURES/gh-<id> says (push: true or
# false, default false; the others an HTTP status, defaults 403, 403 and 405, the merge's refusal
# saying $STUB_FIXTURES/gh-merge-message, default the push restriction's). It logs each call's
# arguments and its three login variables to $STUB_CALLS/gh.env, and each body it reads on stdin
# to $STUB_CALLS/gh.bodies, one line each.
login_on() {
  probe_checkout "$(jq -c .attempts "$REPO_ROOT/bin/lib/probe.json")"
  worker_login_on
  committed_checkout
  own_registry
  local role
  for role in planner builder reviewer topic; do probe_transcript "$role"; done
  stub_script gh <<'SH'
printf '%s GH_CONFIG_DIR=<%s> GH_TOKEN=<%s> GITHUB_TOKEN=<%s>\n' "$*" "${GH_CONFIG_DIR-unset}" \
  "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" >>"$STUB_CALLS/gh.env"
[[ ${1:-} == api ]] || exit 0
shift
method=GET path='' include='' query='' input=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --include | -i) include=1 ;;
    --method | -X) method=$2; shift ;;
    --jq | -q) query=$2; shift ;;
    --input) input=$2; shift ;;
    *) path=$1 ;;
  esac
  shift
done
[[ $input != - ]] || cat >>"$STUB_CALLS/gh.bodies"
fixture() { if [[ -f $STUB_FIXTURES/$1 ]]; then cat "$STUB_FIXTURES/$1"; else echo "$2"; fi; }
status=200 body='{}'
case "$method $path" in
  'GET repos/owner/agent-team')
    status=$(fixture repo-read 200) body='{"name": "Agent-Team", "owner": {"login": "Owner"}}' ;;
  'GET repos/owner/agent-team/pulls?'*) body=$(fixture pulls '[{"number": 7}]') ;;
  'POST graphql')
    body="{\"data\": {\"repository\": {\"ref\": {\"refUpdateRule\": {\"viewerCanPush\": $(fixture gh-push false)}}}}}" ;;
  'POST repos/owner/agent-team/branches/main/protection/enforce_admins') status=$(fixture gh-protection 403) ;;
  'PATCH repos/owner/agent-team') status=$(fixture gh-setting 403) ;;
  'PUT repos/owner/agent-team/pulls/'*/merge) status=$(fixture gh-merge 405) ;;
  *) status=404 ;;
esac
message=refused
[[ $path != */merge ]] ||
  message=$(fixture gh-merge-message "You're not authorized to push to this branch. Visit https://docs.github.com/articles/about-protected-branches/ for more information.")
((status < 400)) || body=$(jq -cn --arg message "$message" '{message: $message}')
if [[ -n $include ]]; then printf 'HTTP/2.0 %s Status\r\nContent-Type: application/json\r\n\r\n' "$status"; fi
if [[ -n $query ]]; then jq -r "$query" <<<"$body"; else echo "$body"; fi
((status < 400)) || { echo "gh: refused (HTTP $status)" >&2; exit 1; }
SH
}

# committed_checkout: the test's code checkout committed as a git repository of its own, so
# team-drill records its runs, as checkout_drill_line gives them
committed_checkout() {
  git -C "${CODE_CHECKOUT:?}" init -q
  git -C "${CODE_CHECKOUT:?}" add -A
  git -C "${CODE_CHECKOUT:?}" commit -q -m "test: the load check's checkout"
}

# checkout_drill_line <verdict> <detail>: the one line a probe from the committed checkout records,
# but at
checkout_drill_line() {
  jq -cn --arg commit "$(git -C "${CODE_CHECKOUT:?}" rev-parse HEAD)" --arg verdict "$1" --arg detail "$2" \
    '{drill: "load-check-probe", machine: "home-pc", commit: $commit, dirty: false, claude: "2.1.321",
      verdict: $verdict, detail: $detail}'
}

# own_registry: the load check's registry, and the team's own project, agent-team
own_registry() {
  registry
  { project agent-team; printf '%s\n' '[agent-team.pool]' 'provider = "git"' 'slots = []'; } >>"$TEAM_HOME/projects.toml"
}

# refused_all: the github lines when GitHub refuses the worker login every call
refused_all() {
  printf '%s\n' 'PASS github push owner/agent-team: refused (false)' 'PASS github protection owner/agent-team: refused (403)' \
    'PASS github setting owner/agent-team: refused (403)' 'PASS github merge owner/agent-team: refused (405)'
}
