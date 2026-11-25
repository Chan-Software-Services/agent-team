# The deletion of what a background session left on this machine, which team-ops-end and the
# read session's end share, sourced after team.sh:
#
#   # shellcheck source=bin/lib/session-purge.sh
#   source "$TEAM_LIB/session-purge.sh"
#
# It provides:
#   purge_sessions <name>   ends every session named <name> that claude agents --json --all
#                           lists, in any state, and deletes what each left. It first resolves
#                           every one to its full uuid, refusing (die), nothing stopped or
#                           deleted, when the list cannot be read ("cannot read the session list
#                           (claude agents --json --all)"), when none is listed ("no session
#                           named <name> is listed"), or when one has no full uuid that starts
#                           with its id ("cannot resolve the full session uuid of <name> (<id>);
#                           nothing deleted"). Then, for each in turn: claude stop (a session that
#                           already finished has nothing to stop), claude rm, refusing (die) when
#                           it fails ("claude rm <id> failed; its transcript is kept"), with that
#                           session's files and every later session kept; then it deletes its
#                           transcript, <config>/projects/<project slug>/<uuid>.jsonl, and the
#                           <uuid>/ directory beside it, its own MCP logs (own_mcp_logs), its
#                           session directory <config>/session-env/<uuid>/ and its file
#                           checkpoints <config>/file-history/<uuid>/, printing "deleted <path>"
#                           for each, <config> being $CLAUDE_CONFIG_DIR or ~/.claude.
#                           It sets PURGED_IDS to each ended session's id and PURGED_CWDS to its
#                           working directory as listed (empty when none is), in the same order,
#                           and PURGED_UNREAD_LOGS to 1 when an MCP log could not be read, else 0:
#                           such a log is named on stderr and kept, and the caller fails once it
#                           has done the rest, since the session is removed by then.
#   own_mcp_logs <uuid>     sets session_logs to the files of every project's mcp-logs-*/
#                           directory under Claude Code's cache (claude_cache_dir) with a JSON line
#                           whose sessionId is the uuid, so a log of another session that quotes
#                           the uuid is kept; a file it cannot read sets PURGED_UNREAD_LOGS to 1.
#
# Each path is found only by the session's full uuid, never by a pattern over names.
# shellcheck shell=bash

own_mcp_logs() {
  local dir log_dirs=() file found_logs status=0 cache
  session_logs=()
  cache=$(claude_cache_dir)
  for dir in "$cache"/*/mcp-logs-*/; do
    [[ -d $dir && ! -L ${dir%/} ]] && log_dirs+=("${dir%/}")
  done
  ((${#log_dirs[@]})) || return 0
  found_logs=$(team_mktemp)
  # grep finds the files that hold the uuid at all, and jq keeps those whose own lines name it.
  grep -rlZF -- "$1" "${log_dirs[@]}" >"$found_logs" || status=$?
  ((status < 2)) || PURGED_UNREAD_LOGS=1
  while IFS= read -r -d '' file; do
    [[ -f $file && ! -L $file ]] || continue
    status=0
    jq -nRe --arg u "$1" 'any(inputs | fromjson? | objects | .sessionId; . == $u)' "$file" >/dev/null || status=$?
    if ((status == 0)); then
      session_logs+=("$file")
    elif ((status != 1)); then
      PURGED_UNREAD_LOGS=1
    fi
  done <"$found_logs"
  team_tmp_rm "$found_logs"
}

purge_sessions() {
  local purge_name=$1 purge_list purge_entry purge_id purge_uuid purge_cwd purge_path purge_config
  local purge_found=()
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  # shellcheck disable=SC2034 # PURGED_UNREAD_LOGS is the caller's to read
  PURGED_IDS=() PURGED_CWDS=() PURGED_UNREAD_LOGS=0
  purge_list=$(claude agents --json --all | jq -ce 'select(type == "array")' 2>/dev/null) ||
    die "cannot read the session list (claude agents --json --all)"
  # One line per session: its id, full uuid and working directory, split by the unit separator.
  mapfile -t purge_found < <(jq -r --arg name "$purge_name" '.[] | select(.name == $name)
    | [.id, .sessionId // "", .cwd // ""] | join("\u001f")' <<<"$purge_list")
  [[ ${#purge_found[@]} -gt 0 ]] || die "no session named $purge_name is listed"

  # Every session must resolve to its full uuid before anything is stopped or deleted.
  for purge_entry in "${purge_found[@]}"; do
    IFS=$'\x1f' read -r purge_id purge_uuid purge_cwd <<<"$purge_entry"
    [[ $purge_uuid =~ $uuid_re && $purge_uuid == "$purge_id"* ]] ||
      die "cannot resolve the full session uuid of $purge_name ($purge_id); nothing deleted"
  done

  purge_config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  for purge_entry in "${purge_found[@]}"; do
    IFS=$'\x1f' read -r purge_id purge_uuid purge_cwd <<<"$purge_entry"
    claude stop "$purge_id" >/dev/null 2>&1 || true
    claude rm "$purge_id" >/dev/null || die "claude rm $purge_id failed; its transcript is kept"
    while IFS= read -r -d '' purge_path; do
      rm -rf -- "$purge_path"
      echo "deleted $purge_path"
    done < <(find "$purge_config/projects" -mindepth 2 -maxdepth 2 \( -name "$purge_uuid.jsonl" -o -name "$purge_uuid" \) -print0 2>/dev/null)
    own_mcp_logs "$purge_uuid"
    for purge_path in "${session_logs[@]}"; do
      rm -f -- "$purge_path"
      echo "deleted $purge_path"
    done
    for purge_path in "$purge_config/session-env/$purge_uuid" "$purge_config/file-history/$purge_uuid"; do
      if [[ -e $purge_path || -L $purge_path ]]; then
        rm -rf -- "$purge_path"
        echo "deleted $purge_path"
      fi
    done
    PURGED_IDS+=("$purge_id")
    PURGED_CWDS+=("$purge_cwd")
  done
}
