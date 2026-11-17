# The fake Discord of the thread archiving tests (bin/lib/threads.sh), loaded after helpers/common
# by their files, once sandbox has run: threads_discord makes it, as the curl stub.
#   GET channels/<id>             answers $DISCORD_DIR/channel-<id>.json (404 without one);
#                                 #coordinator's names the guild, GUILD.
#   GET guilds/GUILD/threads/active
#                                 {threads: [...]}, each channel file of a thread (type 11) not
#                                 archived, as Discord lists them, in no order.
#   PATCH channels/<id>           with {"archived":true}: marks the thread archived in its file and
#                                 adds its id to $DISCORD_DIR/archived; refused with a 403 once
#                                 $DISCORD_DIR/refuse-<id> exists, and answered once with a 429
#                                 (retry-after: 0, written to -D's file) while
#                                 $DISCORD_DIR/limit-<id> exists, which that answer removes.
#   anything else                 fails as curl -f does on a 404.

COORDINATOR=1562486564871995482
INTERVIEW=1565336720998928556
ASSISTANT=1570965039278596199
GUILD=1561884494120620152

threads_discord() {
  export DISCORD_DIR=$BATS_TEST_TMPDIR/discord
  mkdir -p "$DISCORD_DIR"
  export TEAM_ASSISTANT_CHANNEL=$ASSISTANT TEAM_INTERVIEW_CHANNEL=$INTERVIEW
  jq -n --arg id "$COORDINATOR" --arg g "$GUILD" '{id: $id, type: 0, guild_id: $g}' >"$DISCORD_DIR/channel-$COORDINATOR.json"
  stub_script curl <<'EOF'
url=${*: -1} method=GET headers='' data='' args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -X) method=${args[i + 1]} ;;
    -D) headers=${args[i + 1]} ;;
    -d) data=${args[i + 1]} ;;
  esac
done
cat >/dev/null
fail() {
  [[ -z $headers ]] || printf 'HTTP/2 %s\r\n%s' "$1" "${2:-}" >"$headers"
  echo "curl: (22) The requested URL returned error: $1" >&2
  exit 22
}
api=https://discord.com/api/v10
if [[ $method == GET && $url =~ ^$api/channels/([0-9]+)$ && -f $DISCORD_DIR/channel-${BASH_REMATCH[1]}.json ]]; then
  cat "$DISCORD_DIR/channel-${BASH_REMATCH[1]}.json"
elif [[ $method == GET && $url == "$api/guilds/1561884494120620152/threads/active" ]]; then
  jq -s '{threads: map(select(.type == 11 and .thread_metadata.archived != true)), members: []}' "$DISCORD_DIR"/channel-*.json
elif [[ $method == PATCH && $url =~ ^$api/channels/([0-9]+)$ && -f $DISCORD_DIR/channel-${BASH_REMATCH[1]}.json &&
  $data == '{"archived":true}' ]]; then
  id=${BASH_REMATCH[1]}
  [[ ! -e $DISCORD_DIR/refuse-$id ]] || fail 403
  if [[ -e $DISCORD_DIR/limit-$id ]]; then
    rm "$DISCORD_DIR/limit-$id"
    fail 429 $'retry-after: 0\r\n'
  fi
  jq '.thread_metadata.archived = true' "$DISCORD_DIR/channel-$id.json" >"$DISCORD_DIR/next" &&
    mv "$DISCORD_DIR/next" "$DISCORD_DIR/channel-$id.json"
  echo "$id" >>"$DISCORD_DIR/archived"
  cat "$DISCORD_DIR/channel-$id.json"
else
  fail 404
fi
EOF
}

# The Discord id of a moment <seconds> ago, made at that moment, its low bits <n> (0 to 4194303) so
# two of one moment differ: snowflake <seconds ago> [<n>]
snowflake() {
  echo $((((($(date +%s) - $1) * 1000 - 1420070400000) << 22) + ${2:-0}))
}

# A public thread <id> under <parent>, named <name>, whose last message was sent <seconds> ago, or
# with none when <seconds> is -: thread <id> <parent> <name> <seconds ago>
thread() {
  local last=null
  [[ $4 == - ]] || last="\"$(snowflake "$4" 7)\""
  jq -n --arg id "$1" --arg p "$2" --arg name "$3" --argjson last "$last" --arg g "$GUILD" \
    '{id: $id, type: 11, guild_id: $g, parent_id: $p, name: $name, last_message_id: $last,
      thread_metadata: {archived: false, auto_archive_duration: 1440, locked: false}}' >"$DISCORD_DIR/channel-$1.json"
}

# The ids of the threads archived, in the order they were: archived_threads
archived_threads() {
  cat "$DISCORD_DIR/archived" 2>/dev/null || true
}

# The team home's waiting.json, holding <items> and <owed> (JSON lists, empty when not given):
# waiting <items> [<owed>]
waiting() {
  jq -n --argjson items "${1:-[]}" --argjson owed "${2:-[]}" \
    '{schema: "team-waiting/1", items: $items, owed: $owed, posted: null, withdrawn: []}' >"$TEAM_HOME/waiting.json"
}
