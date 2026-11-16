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
  local access=$HOME/.claude/channels/discord/access.json
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
  channel_report "interview channel" "$INTERVIEW_CHANNEL" "the interview channel" \
    "Daniel makes a text channel for interviews, with no access.json group, and a PR sets its id as INTERVIEW_CHANNEL in bin/lib/team.sh" \
    "" \
    "$INTERVIEW_CHANNEL has no access.json group, so the coordinator never hears an interview, and the bot may read it, open threads, post in them and attach images" \
    "${interview_names[@]}"
}

interview_check
