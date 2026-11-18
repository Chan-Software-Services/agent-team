# The archiving of the Discord threads the team makes, sourced after team.sh by team-thread,
# team-close, team-assistant and the lease-fence hook (for THREAD_FENCE):
#
#   # shellcheck source=bin/lib/threads.sh
#   source "$TEAM_LIB/threads.sh"
#
# Discord no longer archives a thread on its auto_archive_duration, which now says only how long a
# quiet thread stays in the channel list, so the team archives its own threads once their work is
# done, under one rule: a thread is archived only when the team home's waiting.json (the list
# waiting.md shows, its owed replies included) names nothing of it and its last message is at
# least a day old. An archived thread stays readable and searchable, and a new message opens it
# again. It provides:
#   THREAD_ARCHIVE_MINUTES  the auto_archive_duration of each thread the team opens: 1 day (Discord
#                           allows 60, 1440, 4320 or 10080).
#   THREAD_QUIET_SECONDS    how old a thread's last message must be before it is archived: a day.
#   THREAD_FENCE            what a machine that is fenced or lost the lease does not do here, for
#                           lease_refusal: "archives no thread; the coordinator on the holder does."
#   THREAD_LATER            what becomes of a thread kept in view: "the heartbeat archives it once
#                           the rule allows (team-thread archive)".
#   thread_waiting          reads waiting.json's items and owed replies into THREAD_WAITING, one
#                           JSON list; fails, saying why on stderr, when the file is missing, is no
#                           team-waiting/1 record or cannot be read, or is older than a file
#                           team-inbox writes it from (the ledger, tasks/current.md,
#                           assistant/current.md), as it is when team-inbox failed after that file
#                           changed: "waiting.json is older than <file>, so what waits on Daniel may
#                           have changed since it was written: team-inbox writes it afresh". So
#                           nothing is archived on a list that cannot be known, or may be stale.
#   thread_hold <thread> <task or ""> <last message id or "">
#                           prints why the thread stays in view, or fails when the rule archives
#                           it: "item <n> of waiting.md waits on Daniel in it" for an item of its
#                           task (a task's thread) or one holding its id as a whole run of digits
#                           (a thread, a where, a link), "a reply owed to Daniel in waiting.md is
#                           of it" for an owed reply so, or "its last message is <n> h old, under
#                           a day", the age read from the message's id (the thread's own, the time
#                           it was made, with none). Reads THREAD_WAITING.
#   thread_read <thread>    prints Discord's channel object of the thread.
#   thread_bot              prints the bot's user id (GET users/@me), the owner_id of each thread
#                           the team opens; fails with the reason on stderr.
#   thread_archive <thread> sets the thread archived (PATCH channels/<thread>, archived true),
#                           waiting Discord's Retry-After on a 429, at most 3 tries; fails with
#                           the reason on stderr.
#   thread_settle <thread> <task or ""> [<channel JSON>]
#                           archives one thread whose work is done when the rule allows it now:
#                           prints "archived", or "archived already" when Discord has it so, and
#                           succeeds; else prints why it stays in view and fails: the fence's
#                           refusal (lease_refusal, THREAD_FENCE), or, each followed by
#                           "; THREAD_LATER", no token, a thread Discord could not read
#                           ("Discord could not be read: <why>"), a waiting.json thread_waiting
#                           refuses, thread_hold's why, or "Discord refused archiving it: <why>".
#                           Reads the thread from Discord unless <channel JSON> is given.
# Each Discord call goes through discord_api with a 20 s limit; the callers check the fence
# (lease_refusal) before any of them, as thread_settle does itself.

# shellcheck shell=bash
# shellcheck disable=SC2034 # read by the scripts that source this file
THREAD_ARCHIVE_MINUTES=1440
THREAD_QUIET_SECONDS=86400
THREAD_CALL_SECONDS=20
THREAD_FENCE="archives no thread; the coordinator on the holder does."
THREAD_LATER="the heartbeat archives it once the rule allows (team-thread archive)"

thread_waiting() {
  local file=$TEAM_HOME/waiting.json read source
  [[ -e $file ]] || {
    echo "there is no waiting.json, so what waits on Daniel is not known: team-inbox writes it" >&2
    return 1
  }
  if ! read=$(jq -sc 'if length == 1 and (.[0] | type == "object" and .schema == "team-waiting/1")
    then .[0] | [(.items // [])[] | {item: .}] + [(.owed // [])[] | {owed: .}] else "its schema is not team-waiting/1" end' \
    "$file" 2>&1); then
    read="it is not JSON: $(grep -m 1 . <<<"$read" | sed -E 's/^jq: error \(at [^)]*\): //')"
  fi
  if [[ $read != \[* ]]; then
    echo "waiting.json cannot be read, so what waits on Daniel is not known: $(jq -r 'strings // .' <<<"$read" 2>/dev/null || echo "$read")" >&2
    return 1
  fi
  # team-inbox writes waiting.json on every run, so one older than a file it reads may miss what
  # that file added since. A file's time is only as fine as the kernel's clock tick, so a file of
  # the same time as waiting.json is taken as read by it.
  for source in ledger.jsonl tasks/current.md assistant/current.md; do
    if [[ $TEAM_HOME/$source -nt $file ]]; then
      echo "waiting.json is older than $source, so what waits on Daniel may have changed since it was written: team-inbox writes it afresh" >&2
      return 1
    fi
  done
  THREAD_WAITING=$read
}

thread_hold() {
  local thread=$1 task=$2 last=${3:-$1} why age
  [[ $thread =~ ^[1-9][0-9]{0,18}$ ]] || {
    echo "its id $thread is no Discord id"
    return 0
  }
  why=$(jq -r --arg id "$thread" --arg task "$task" '
    def names: ($task != "" and .task? == $task)
      or any(.. | strings; test("(^|[^0-9])" + $id + "([^0-9]|$)"));
    [(.[] | select(.item and (.item | names)) | "item \(.item.n) of waiting.md waits on Daniel in it"),
      (.[] | select(.owed and (.owed | names)) | "a reply owed to Daniel in waiting.md is of it")]
    | first // empty' <<<"$THREAD_WAITING" 2>/dev/null) || why="waiting.json's list cannot be read"
  if [[ -n $why ]]; then
    echo "$why"
    return 0
  fi
  [[ $last =~ ^[1-9][0-9]{0,18}$ ]] || last=$thread
  age=$(($(date +%s) - ((last >> 22) / 1000 + 1420070400)))
  ((age >= THREAD_QUIET_SECONDS)) && return 1
  echo "its last message is $((age / 3600)) h old, under a day"
}

thread_read() {
  discord_api "channels/$1" --max-time "$THREAD_CALL_SECONDS"
}

thread_bot() {
  local id
  id=$(discord_api users/@me --max-time "$THREAD_CALL_SECONDS" | jq -r 'objects | .id | strings | select(test("^[0-9]+$"))') &&
    [[ -n $id ]] || {
    echo "Discord named no user for the bot" >&2
    return 1
  }
  echo "$id"
}

thread_archive() {
  local tries=0 headers status retry
  headers=$(team_mktemp)
  team_tmp_add "$headers.error"
  while true; do
    tries=$((tries + 1))
    if discord_api "channels/$1" -X PATCH -H "Content-Type: application/json" -d '{"archived":true}' \
      --max-time "$THREAD_CALL_SECONDS" -D "$headers" >/dev/null 2>"$headers.error"; then
      team_tmp_rm "$headers" "$headers.error"
      return 0
    fi
    status=$(sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' "$headers" | tail -n 1)
    retry=$(sed -nE 's/^retry-after:[[:space:]]*([0-9.]+).*/\1/Ip' "$headers" | tail -n 1)
    if [[ $status == 429 ]] && ((tries < 3)); then
      sleep "$(jq -n --arg r "${retry:-1}" '$r | tonumber | ceil | [., 1] | max')"
      continue
    fi
    grep -m 1 . "$headers.error" >&2 || echo "Discord refused it (HTTP ${status:-unknown})" >&2
    team_tmp_rm "$headers" "$headers.error"
    return 1
  done
}

thread_settle() {
  local id=$1 task=$2 channel=${3:-} why error
  if why=$(lease_refusal "$THREAD_FENCE"); then
    echo "$why"
    return 1
  fi
  if ! discord_token >/dev/null; then
    echo "no DISCORD_BOT_TOKEN in ~/.claude/channels/discord/.env; $THREAD_LATER"
    return 1
  fi
  error=$(team_mktemp)
  if [[ -z $channel ]] && ! channel=$(thread_read "$id" 2>"$error"); then
    channel=''
  fi
  if ! jq -e '.thread_metadata | type == "object"' <<<"$channel" >/dev/null 2>&1; then
    why="Discord could not be read: $(grep -m 1 . "$error" || echo "its answer is no thread"); $THREAD_LATER"
  elif jq -e '.thread_metadata.archived == true' <<<"$channel" >/dev/null; then
    team_tmp_rm "$error"
    echo "archived already"
    return 0
  elif ! thread_waiting 2>"$error"; then
    why="$(<"$error"); $THREAD_LATER"
  elif why=$(thread_hold "$id" "$task" "$(jq -r '.last_message_id // empty | tostring' <<<"$channel")"); then
    why="$why; $THREAD_LATER"
  elif thread_archive "$id" 2>"$error"; then
    team_tmp_rm "$error"
    echo "archived"
    return 0
  else
    why="Discord refused archiving it: $(grep -m 1 . "$error" || echo "no reason given"); $THREAD_LATER"
  fi
  team_tmp_rm "$error"
  echo "$why"
  return 1
}
