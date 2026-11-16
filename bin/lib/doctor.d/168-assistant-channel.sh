# assistant channel
#               Fails unless #assistant (ASSISTANT_CHANNEL in bin/lib/team.sh) is set, has no group
#               in the coordinator's Discord access.json (so the coordinator never hears what Daniel
#               tells the assistant), is a text channel, and lets the bot see it, post there, read
#               its history, open public threads, post in them, attach files and add reactions: the
#               bot's roles and the channel's overwrites, read with the bot token through the
#               Discord API (bin/lib/channel-access.sh). Warns when Discord does not answer.
# shellcheck shell=bash
# shellcheck source=bin/lib/channel-access.sh
source "$TEAM_LIB/channel-access.sh"

# The permissions the assistant uses there: its replies, threads, attachments and reactions.
assistant_channel_names=("View Channel" "Send Messages" "Read Message History" "Create Public Threads"
  "Send Messages in Threads" "Attach Files" "Add Reactions")

assistant_channel_check() {
  local access=$HOME/.claude/channels/discord/access.json id=$ASSISTANT_CHANNEL
  if [[ -z $id ]]; then
    report "assistant channel" FAIL "no assistant channel is set (TEAM_ASSISTANT_CHANNEL is empty), so the assistant would hear nothing" \
      "unset TEAM_ASSISTANT_CHANNEL, so ASSISTANT_CHANNEL in bin/lib/team.sh names #assistant"
    return 0
  fi
  if jq -e --arg c "$id" '(.groups // {}) | has($c)' "$access" >/dev/null 2>&1; then
    report "assistant channel" FAIL "the coordinator would hear #assistant: access.json has a group for it ($id)" \
      "Daniel runs /discord:access group rm $id in the coordinator"
    return 0
  fi
  channel_report "assistant channel" "$id" "#assistant" \
    "Daniel makes #assistant a text channel, and a PR sets its id as ASSISTANT_CHANNEL in bin/lib/team.sh" \
    ", so the assistant cannot answer Daniel there in full" \
    "$id has no group in the coordinator's access.json, so only the assistant hears #assistant, and the bot may read it, post, open threads, post in them, attach files and react there" \
    "${assistant_channel_names[@]}"
}

assistant_channel_check
