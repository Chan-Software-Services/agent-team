# The bot's access to one Discord channel, as Discord works it out, for the doctor's channel lines
# (bin/lib/doctor.d/167-interview-channel.sh and 168-assistant-channel.sh), sourced after team.sh:
#
#   # shellcheck source=bin/lib/channel-access.sh
#   source "$TEAM_LIB/channel-access.sh"
#
# It provides:
#   CHANNEL_BITS               each permission a line may ask for, by Discord's name, to its bit
#   channel_access <channel id> <permission name>...
#                              reads, with the bot token through discord_api, the channel, the bot
#                              (users/@me), its member in the channel's server and the server's
#                              roles, and sets channel_access_result to one of:
#                                ok          the bot holds every named permission there
#                                missing     it lacks some: channel_missing lists them, in order
#                                not-text    the channel is no text channel: channel_type is its type
#                                refused     Discord refused a read (curl's (22), a 4xx or 5xx)
#                                unanswered  Discord did not answer, or its answer was not JSON
#                                unnamed     Discord named no server for the channel or no bot id
#                              with channel_path the read that failed and channel_why its first
#                              error line, for refused and unanswered. It always returns 0.
#   channel_report <line> <channel id> <label> <not-text fix> <missing tail> <pass text>
#                  <permission name>...
#                              the doctor line <line> for that channel, called <label> in its texts
#                              (as "#assistant"): FAIL with no bot token, on a refused read, on a
#                              channel that is no text channel (its fix <not-text fix>) and on each
#                              named permission the bot lacks (its text ending <missing tail>),
#                              WARN when Discord does not answer or names no server or bot, else
#                              PASS with <pass text>. It calls the doctor's report.
# Only permissions and ids are read; no secret is printed.
# shellcheck shell=bash

# Discord's permission bits, by the names Discord's settings show.
# shellcheck disable=SC2034 # read by the doctor's channel lines
declare -A CHANNEL_BITS=([Add Reactions]=6 [View Channel]=10 [Send Messages]=11 [Attach Files]=15
  [Read Message History]=16 [Create Public Threads]=35 [Send Messages in Threads]=38)

# channel_get <path> [<name>=<filter>...]: GET <path> into channel_reply, or set channel_access_result,
# channel_path and channel_why and fail; in the same jq run that checks it is a JSON object or array,
# each <name>=<filter> is read from it into <name> (json_vars).
channel_get() {
  local ok='' err
  err=$(mktemp)
  if channel_reply=$(discord_api "$1" --max-time 20 2>"$err") &&
    json_vars ok='type == "object" or type == "array"' "${@:2}" <<<"$channel_reply" 2>/dev/null && [[ $ok == true ]]; then
    rm -f "$err"
    return 0
  fi
  channel_path=$1
  channel_why=$(grep -m1 . "$err" || echo "no JSON in its answer")
  rm -f "$err"
  channel_access_result=unanswered
  [[ $channel_why != *"(22)"* ]] || channel_access_result=refused
  return 1
}

channel_access() {
  local id=$1 channel guild='' bot='' text='' member base=0 kind a d admin=$((1 << 3)) name
  shift
  channel_access_result='' channel_missing=() channel_type='' channel_path='' channel_why=''
  channel_get "channels/$id" text='try (.type == 0) catch false' \
    channel_type='try (.type // "none" | tostring) catch empty' \
    guild='try (.guild_id | strings | select(test("^[0-9]+$"))) catch empty' || return 0
  channel=$channel_reply
  if [[ $text != true ]]; then
    channel_access_result=not-text
    return 0
  fi
  channel_get "users/@me" bot='try (.id | strings | select(test("^[0-9]+$"))) catch empty' || return 0
  if [[ -z $guild || -z $bot ]]; then
    channel_access_result=unnamed
    return 0
  fi
  channel_get "guilds/$guild/members/$bot" || return 0
  member=$channel_reply
  channel_get "guilds/$guild/roles" || return 0
  # Discord's order: @everyone's role (the guild's id) and the bot's roles together; then the
  # channel's overwrites for @everyone, for the bot's roles together, and for the bot itself, each
  # denying, then allowing; Administrator allows everything.
  local -A allows=() denies=()
  while read -r kind a d; do
    # Bash arithmetic would run an expression, so only digits reach it.
    [[ $a =~ ^[0-9]{1,18}$ && $d =~ ^[0-9]{1,18}$ ]] || continue
    if [[ $kind == role ]]; then
      base=$((base | a))
    else
      allows[$kind]=$((${allows[$kind]:-0} | a)) denies[$kind]=$((${denies[$kind]:-0} | d))
    fi
  done < <(jq -rn --argjson channel "$channel" --argjson member "$member" --argjson roles "$channel_reply" \
    --arg guild "$guild" --arg bot "$bot" '
    ([$guild] + $member.roles) as $mine
    | ($roles[] | select(.id | IN($mine[])) | "role \(.permissions) 0"),
      ($channel.permission_overwrites // [] | .[]
        | if .id == $guild then "everyone \(.allow) \(.deny)"
          elif .type == 0 and (.id | IN($member.roles[])) then "roles \(.allow) \(.deny)"
          elif .type == 1 and .id == $bot then "bot \(.allow) \(.deny)"
          else empty end)')
  if ! ((base & admin)); then
    for kind in everyone roles bot; do
      base=$(((base & ~${denies[$kind]:-0}) | ${allows[$kind]:-0}))
    done
  fi
  for name; do
    ((base & admin || base & (1 << ${CHANNEL_BITS[$name]}))) || channel_missing+=("$name")
  done
  channel_access_result=ok
  ((${#channel_missing[@]} == 0)) || channel_access_result=missing
}

channel_report() {
  local line=$1 id=$2 label=$3 make=$4 tail=$5 pass=$6 names
  shift 6
  names=$(printf '%s, ' "$@" | sed 's/, $//')
  if ! discord_token >/dev/null; then
    report "$line" FAIL "no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env, so the bot's access to $label cannot be checked" \
      "the secret discord-bot-env line's fix"
    return 0
  fi
  channel_access "$id" "$@"
  case $channel_access_result in
    refused)
      report "$line" FAIL "Discord refused the bot's read of $channel_path ($channel_why), so the bot cannot reach $label $id" \
        "Daniel gives the bot's role $names in $label's permissions" ;;
    unanswered)
      report "$line" WARN "Discord did not answer ($channel_why), so the bot's access to $label is unchecked" \
        "check the network, then run team-doctor again" ;;
    not-text)
      report "$line" FAIL "$id is not a text channel (type $channel_type), so no thread opens under it" "$make" ;;
    unnamed)
      report "$line" WARN "Discord named no server for the channel or no id for the bot, so the bot's access to $label is unchecked" \
        "run team-doctor again" ;;
    missing)
      names=$(printf '%s, ' "${channel_missing[@]}" | sed 's/, $//')
      report "$line" FAIL "the bot lacks $names in $label $id$tail" \
        "Daniel gives the bot's role $names in $label's permissions" ;;
    *)
      report "$line" PASS "$pass" ;;
  esac
}
