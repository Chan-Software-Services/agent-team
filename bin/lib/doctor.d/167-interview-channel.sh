# interview channel
#               Fails unless the interview channel (INTERVIEW_CHANNEL in bin/lib/team.sh) is set,
#               has no group in the Discord plugin's access.json (so the plugin delivers none of
#               its threads' messages to the coordinator), is a text channel, and lets the bot see
#               it, read its history, open public threads, post in them and attach images: the
#               bot's roles and the channel's overwrites, read with the bot token through the
#               Discord API (bin/lib/channel-access.sh). Warns when Discord does not answer.
# shellcheck shell=bash
# shellcheck source=bin/lib/channel-access.sh
source "$TEAM_LIB/channel-access.sh"

# The permissions team-thread and team-post use there.
interview_names=("View Channel" "Read Message History" "Create Public Threads" "Send Messages in Threads" "Attach Files")

interview_check() {
  local access=$HOME/.claude/channels/discord/access.json names
  names=$(printf '%s, ' "${interview_names[@]}" | sed 's/, $//')
  if [[ -z $INTERVIEW_CHANNEL ]]; then
    report "interview channel" FAIL "no interview channel is set, so no planner can interview Daniel" \
      "Daniel makes a text channel for interviews, with no access.json group, and a PR sets its id as INTERVIEW_CHANNEL in bin/lib/team.sh"
    return 0
  fi
  if jq -e --arg c "$INTERVIEW_CHANNEL" '(.groups // {}) | has($c)' "$access" >/dev/null 2>&1; then
    report "interview channel" FAIL "access.json has a group for the interview channel $INTERVIEW_CHANNEL, so the plugin delivers every interview to the coordinator" \
      "Daniel runs /discord:access group rm $INTERVIEW_CHANNEL in their own Claude Code session"
    return 0
  fi
  if ! discord_token >/dev/null; then
    report "interview channel" FAIL "no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, so the bot's access to the interview channel cannot be checked" \
      "the secret discord-bot-env line's fix"
    return 0
  fi
  channel_access "$INTERVIEW_CHANNEL" "${interview_names[@]}"
  case $channel_access_result in
    refused)
      report "interview channel" FAIL "Discord refused the bot's read of $channel_path ($channel_why), so the bot cannot reach the interview channel $INTERVIEW_CHANNEL" \
        "Daniel gives the bot's role $names in the interview channel's permissions" ;;
    unanswered)
      report "interview channel" WARN "Discord did not answer ($channel_why), so the bot's access to the interview channel is unchecked" \
        "check the network, then run team-doctor again" ;;
    not-text)
      report "interview channel" FAIL "$INTERVIEW_CHANNEL is not a text channel (type $channel_type), so no thread opens under it" \
        "Daniel makes a text channel for interviews, with no access.json group, and a PR sets its id as INTERVIEW_CHANNEL in bin/lib/team.sh" ;;
    unnamed)
      report "interview channel" WARN "Discord named no server for the channel or no id for the bot, so the bot's access to the interview channel is unchecked" \
        "run team-doctor again" ;;
    missing)
      names=$(printf '%s, ' "${channel_missing[@]}" | sed 's/, $//')
      report "interview channel" FAIL "the bot lacks $names in the interview channel $INTERVIEW_CHANNEL" \
        "Daniel gives the bot's role $names in the interview channel's permissions" ;;
    *)
      report "interview channel" PASS "$INTERVIEW_CHANNEL has no access.json group, so the coordinator never hears an interview, and the bot may read it, open threads, post in them and attach images" ;;
  esac
}

interview_check
