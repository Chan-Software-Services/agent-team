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
  local access=$HOME/.claude/channels/discord/access.json names id=$ASSISTANT_CHANNEL
  local make="Daniel makes #assistant a text channel, and a PR sets its id as ASSISTANT_CHANNEL in bin/lib/team.sh"
  names=$(printf '%s, ' "${assistant_channel_names[@]}" | sed 's/, $//')
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
  if ! discord_token >/dev/null; then
    report "assistant channel" FAIL "no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, so the bot's access to #assistant cannot be checked" \
      "the secret discord-bot-env line's fix"
    return 0
  fi
  channel_access "$id" "${assistant_channel_names[@]}"
  case $channel_access_result in
    refused)
      report "assistant channel" FAIL "Discord refused the bot's read of $channel_path ($channel_why), so the bot cannot reach #assistant $id" \
        "Daniel gives the bot's role $names in #assistant's permissions" ;;
    unanswered)
      report "assistant channel" WARN "Discord did not answer ($channel_why), so the bot's access to #assistant is unchecked" \
        "check the network, then run team-doctor again" ;;
    not-text)
      report "assistant channel" FAIL "$id is not a text channel (type $channel_type), so no thread opens under it" "$make" ;;
    unnamed)
      report "assistant channel" WARN "Discord named no server for the channel or no id for the bot, so the bot's access to #assistant is unchecked" \
        "run team-doctor again" ;;
    missing)
      names=$(printf '%s, ' "${channel_missing[@]}" | sed 's/, $//')
      report "assistant channel" FAIL "the bot lacks $names in #assistant $id, so the assistant cannot answer Daniel there in full" \
        "Daniel gives the bot's role $names in #assistant's permissions" ;;
    *)
      report "assistant channel" PASS "$id has no group in the coordinator's access.json, so only the assistant hears #assistant, and the bot may read it, post, open threads, post in them, attach files and react there" ;;
  esac
}

assistant_channel_check
