# guard hooks   Runs each guard hook of bin/hooks/ that the sessions' settings run on a Bash
#               call (scratch-only-edits, command-guard, lease-fence, lease-fence --coordinator,
#               lease-fence --assistant and session-records-guard) on one harmless call (ls),
#               the assistant's Discord guard (assistant-discord-guard) on a read of #assistant
#               itself (fetch_messages of ASSISTANT_CHANNEL, which asks Discord nothing), and
#               the workers' session records guard (session-records-guard) on a Read outside
#               the session records (of a file in the doctor's scratch directory) as well, each
#               within its settings' timeout, and fails on any exit but 0, naming the hook, its exit
#               code (a timeout's, 124, as "did not answer") and its first stderr line: since each
#               settings entry blocks on its hook's failure (onFailure block), a guard that fails
#               blocks every call it sees, the coordinator's and the assistant's Discord posts
#               included.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, scratch and the doctor's report

# Each guard's command line and its timeout in seconds, as the settings give it (tests/repo.bats
# holds the settings to these).
guard_hooks=("scratch-only-edits:30" "command-guard:10" "lease-fence:60" "lease-fence --coordinator:60"
  "lease-fence --assistant:60" "assistant-discord-guard:30" "session-records-guard:10")
guard_input=$(jq -cn --arg cwd "$scratch" '{session_id: "team-doctor", hook_event_name: "PreToolUse",
  tool_name: "Bash", tool_input: {command: "ls", description: "List files"}, cwd: $cwd}')
# The Discord guard judges only the Discord tools: its harmless call is a read of #assistant.
guard_assistant_input=$(jq -cn --arg cwd "$scratch" --arg chat "$ASSISTANT_CHANNEL" '{session_id: "team-doctor",
  hook_event_name: "PreToolUse", tool_name: "mcp__plugin_discord_discord__fetch_messages",
  tool_input: {channel: $chat, limit: 1}, cwd: $cwd}')
# The session records guard judges Read, Grep, Glob and Bash: it gets the harmless Bash call and a
# Read of a file outside the session records, since a failure on either blocks every such call.
guard_records_input=$(jq -cn --arg cwd "$scratch" '{session_id: "team-doctor", hook_event_name: "PreToolUse",
  tool_name: "Read", tool_input: {file_path: ($cwd + "/session-records-guard-probe")}, cwd: $cwd}')
guard_failed=()
for guard in "${guard_hooks[@]}"; do
  guard_seconds=${guard##*:} guard=${guard%:*}
  read -ra guard_words <<<"$guard"
  guard_calls=("$guard_input")
  [[ ${guard_words[0]} != assistant-discord-guard ]] || guard_calls=("$guard_assistant_input")
  [[ ${guard_words[0]} != session-records-guard ]] || guard_calls+=("$guard_records_input")
  for guard_call in "${guard_calls[@]}"; do
    guard_rc=0
    (cd "$scratch" && TEAM_HOME=$TEAM_HOME bounded "$guard_seconds" "$bin/hooks/${guard_words[0]}" "${guard_words[@]:1}" \
      >/dev/null 2>"$err" <<<"$guard_call") || guard_rc=$?
    if ((guard_rc == 0)); then
      continue
    elif ((guard_rc == 124)); then
      guard_failed+=("$guard did not answer within its $guard_seconds s")
    else
      guard_line=$(grep -m1 . "$err" || true)
      guard_failed+=("$guard exited $guard_rc${guard_line:+ (\"$guard_line\")}")
    fi
  done
done
if ((${#guard_failed[@]} == 0)); then
  report "guard hooks" PASS "scratch-only-edits, command-guard, lease-fence, lease-fence --coordinator, lease-fence --assistant and session-records-guard each pass a harmless Bash call (ls), assistant-discord-guard a read of #assistant, and session-records-guard a Read outside the session records"
else
  guard_reason=$(printf '%s; ' "${guard_failed[@]}" | sed 's/; $//')
  report "guard hooks" FAIL "on a harmless call (ls, a read of #assistant, or a Read outside the session records), $guard_reason, so each blocks every call it guards" \
    "fix each hook named in $(tilde "$bin/hooks"), then run team-doctor again"
fi
