# The record of the coordinator's held auto-compaction, sourced after team.sh by
# bin/hooks/compact-hold and team-stowed:
#
#   # shellcheck source=bin/lib/compact-hold.sh
#   source "$TEAM_LIB/compact-hold.sh"
#
# A session's record is $COMPACT_HOLD_DIR/<session id>.json, one JSON object:
#   held_at      when its standing hold began, null with none standing
#   told_at      when the coordinator was told of that hold, null while untold
#   stowed_at    when team-stowed last ran in the session, null when never
#   released_at  when a hold of its was last released, null when never
#   blocks       how many auto-compactions the standing or the last hold refused
# each time in epoch seconds. Each write is whole, to a temporary file moved into place, under
# flock on <file>.lock, waited for 5 seconds. Each transition is a JSON line appended to
# $COMPACT_HOLD_LOG: {"at": "<UTC ISO time>", "session", "event": "held" | "told" | "reminded" |
# "stowed" | "released"}, a release with its "why": "stowed", "timeout" or "ceiling".
# It provides:
#   COMPACT_HOLD_DIR              ~/.local/state/agent-team/compact-hold
#   COMPACT_HOLD_LOG              ~/.local/state/agent-team/compact-hold.log
#   compact_hold_session <id>     whether <id> may name a record: letters, digits and dashes.
#   compact_hold_read <session>   prints the session's record, the empty one (every time null,
#                                 blocks 0) with no file; fails, saying so on stderr, for a file
#                                 that is not one JSON object.
#   compact_hold_update <session> <program> [jq arguments...]
#                                 under the lock, runs the jq <program> on the record as
#                                 compact_hold_read prints it, with $now the time in epoch seconds
#                                 (TEAM_COMPACT_HOLD_NOW when set, the tests' clock);
#                                 the program prints one object, whose record is the new record,
#                                 written when it differs from the one read, and whose log is a
#                                 list of {event} or {event, why}, each appended to the log with
#                                 the time and the session; the whole object is printed as one
#                                 line. Fails, writing nothing and saying why on stderr, when the
#                                 lock is not had in 5 seconds or the read or the program fails;
#                                 fails too, printing nothing, when the log cannot be opened
#                                 or the record's write fails, the record then as it was and
#                                 the log with no new line, or when the append itself fails,
#                                 after the write.
#   compact_hold_context <file>   prints the tokens the latest main-conversation reply of the
#                                 transcript <file> read (input, cache writes and cache reads, as
#                                 team.sh's session_context sums them), 0 when it has none or
#                                 cannot be read.
#   compact_hold_clock <seconds>  prints an epoch time as HH:MM, in UTC.
# shellcheck shell=bash

COMPACT_HOLD_DIR=$HOME/.local/state/agent-team/compact-hold
COMPACT_HOLD_LOG=$HOME/.local/state/agent-team/compact-hold.log

compact_hold_session() {
  [[ $1 =~ ^[A-Za-z0-9-]+$ ]]
}

compact_hold_read() {
  local hold_file=$COMPACT_HOLD_DIR/$1.json
  if [[ ! -e $hold_file ]]; then
    echo '{"held_at":null,"told_at":null,"stowed_at":null,"released_at":null,"blocks":0}'
  elif ! jq -ce '{held_at: null, told_at: null, stowed_at: null, released_at: null, blocks: 0} + objects' "$hold_file" 2>/dev/null; then
    echo "$hold_file is not a compact-hold record" >&2
    return 1
  fi
}

compact_hold_update() {
  local hold_session=$1 hold_program=$2 hold_file=$COMPACT_HOLD_DIR/$1.json
  shift 2
  mkdir -p "$COMPACT_HOLD_DIR" || return 1
  (
    flock -w 5 9 || { echo "another writer held $hold_file.lock for 5 s" >&2; exit 1; }
    hold_before=$(compact_hold_read "$hold_session") || exit 1
    hold_out=$(jq -c --argjson now "${TEAM_COMPACT_HOLD_NOW:-$(date +%s)}" "$@" "$hold_program" <<<"$hold_before") || exit 1
    hold_after=$(jq -ce '.record | objects' <<<"$hold_out") || exit 1
    # Each step ends the update itself: a caller's command substitution clears errexit.
    hold_lines=$(jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session "$hold_session" \
      '.log // [] | .[] | {at: $at, session: $session} + .' <<<"$hold_out") || exit 1
    if [[ $hold_after != "$hold_before" ]]; then
      # A log that cannot be opened leaves the record as it was.
      [[ -z $hold_lines ]] || : >>"$COMPACT_HOLD_LOG" || exit 1
      hold_new=$(mktemp "$hold_file.XXXXXX") || exit 1
      if ! { echo "$hold_after" >"$hold_new" && mv -f "$hold_new" "$hold_file"; }; then
        rm -f "$hold_new"
        exit 1
      fi
    fi
    if [[ -n $hold_lines ]]; then
      echo "$hold_lines" >>"$COMPACT_HOLD_LOG" || exit 1
    fi
    echo "$hold_out"
  ) 9>"$hold_file.lock"
}

compact_hold_context() {
  local hold_tokens=''
  if [[ -n $1 && -f $1 ]]; then
    # jq stops at the first reply it finds, so tac may end on a broken pipe.
    hold_tokens=$({ tac -- "$1" 2>/dev/null || true; } | jq -nR 'first(inputs | fromjson? | objects
      | select(.type == "assistant" and (.isSidechain | not)) | .message.usage | objects
      | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)
      | numbers | select(. > 0))' 2>/dev/null) || hold_tokens=''
  fi
  echo "${hold_tokens:-0}"
}

compact_hold_clock() {
  date -u -d "@$1" +%H:%M
}
