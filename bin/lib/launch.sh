# The launchers' shared parts, for the scripts that start one long-lived session of the team
# (claude-coordinator and claude-assistant), sourced after team.sh:
#
#   # shellcheck source=bin/lib/launch.sh
#   source "$TEAM_LIB/launch.sh"
#
# Each refusal is the library's die (exit 1, prefixed with the script's name). It provides:
#   launch_lock <name>           takes a non-blocking flock on
#                                ~/.local/state/agent-team/<name>-launch.lock, held on the fd
#                                LAUNCH_LOCK_FD until the script exits, refusing at once while
#                                another launch holds it; LAUNCH_LOCK is its path.
#   launch_unlocked <command...> runs the command with the lock's file closed, so nothing it
#                                starts holds the next launch's lock; with no lock taken, runs it
#                                as it is.
#   launch_singleton <name>      refuses while `claude agents --json --all` lists a session named
#                                <name> in any state but stopped, naming its id.
#   launch_settings <template> <mcp template or ""> <connectors or ""> <out settings> <out mcp>
#                   [@<KEY>@=<value>...]
#                                writes the session's MCP config and settings, the servers its
#                                list names but its own denied.
#   launch_skills_off <settings> <plugin directory>
#                                turns off, in the written settings, each of the user's personal
#                                skills but one named as a skill of the plugin.
#
# The lock only serialises launches: `claude --bg` returns at once, so the session list, not the
# lock, says whether a session is alive. Each function after launch_lock runs what it calls with
# the lock's file closed.
# shellcheck shell=bash

# The team's state directory, where the locks and the written settings live.
LAUNCH_STATE=$HOME/.local/state/agent-team

# launch_lock <name>: takes ~/.local/state/agent-team/<name>-launch.lock without waiting, on the
# fd LAUNCH_LOCK_FD, kept open until the script exits; dies "another <script> is launching right
# now (it holds <lock>)" while another launch holds it.
launch_lock() {
  LAUNCH_LOCK=$LAUNCH_STATE/$1-launch.lock
  mkdir -p "$LAUNCH_STATE"
  exec {LAUNCH_LOCK_FD}>"$LAUNCH_LOCK"
  flock -n "$LAUNCH_LOCK_FD" || die "another ${0##*/} is launching right now (it holds $LAUNCH_LOCK)"
}

# launch_unlocked <command...>: runs the command, a function or a program, with the lock's file
# closed, so no process it leaves running (a git helper, the session itself) holds the lock.
launch_unlocked() {
  if [[ -n ${LAUNCH_LOCK_FD:-} ]]; then
    "$@" {LAUNCH_LOCK_FD}>&-
  else
    "$@"
  fi
}

# launch_singleton <name>: dies "a(n) <name> is already live: session <id>; stop it with claude
# stop <id> first" while a session named exactly <name> is in any state but stopped, and "cannot
# read the session list (claude agents --json --all)" when the list is not a JSON array.
# Without --all, the list leaves out a background session with no process that is neither
# working nor blocked, as one is once its turn ends (done) or it failed and the daemon settles its
# process, though a message or a finished shell of its wakes it. --all lists every job the daemon
# still keeps, so only a stopped one, which nothing wakes on its own, is gone. The id is the
# job's, else the first 8 characters of its session id.
launch_singleton() {
  local name=$1 sessions live article=a
  sessions=$(launch_unlocked claude agents --json --all | jq -ce 'select(type == "array")' 2>/dev/null) ||
    die "cannot read the session list (claude agents --json --all)"
  live=$(jq -r --arg name "$name" 'map(select(.name == $name and .state != "stopped")) | first
    | if . then .id // ((.sessionId // "")[:8]) else empty end' <<<"$sessions")
  [[ $name != [aeiouAEIOU]* ]] || article=an
  [[ -z $live ]] || die "$article $name is already live: session $live; stop it with claude stop $live first"
}

# launch_settings <template> <mcp template or ""> <connectors or ""> <out settings> <out mcp>
# [@<KEY>@=<value>...]: writes <out mcp>, the MCP template (an empty one names no server), and
# <out settings>, the settings template with deniedMcpServers set, each written whole and then
# moved into place. In every string of both, @TEAM_CODE@ names this checkout, and each extra
# @<KEY>@ its value.
# The servers denied are every one that `claude mcp list`, run in the working directory, names,
# but the MCP template's own, those of a plugin the settings enable (plugin:<plugin>:<server>),
# and the claude.ai connectors <connectors> keeps, a JSON list of names, by exact name (none when
# it is empty). Dies when <connectors> is named but is not such a list, so a missing file never
# denies every connector unsaid. Each line of the list is "<name>: <what it runs> - <health>", and a name
# holds no ": ". Dies when the list fails, and when it printed a line but named no server in its
# format, naming its first line, since a changed format would deny nothing; an empty list, or
# Claude Code's "No MCP servers configured." line, denies none. The list's health check starts
# the servers, so they get no lock.
launch_settings() {
  local template=$1 mcp_template=$2 connectors=$3 settings=$4 mcp=$5 code listed line first='' empty='' pair subs
  local kept='[]'
  local -a servers=() named=()
  shift 5
  if [[ -n $connectors ]]; then
    kept=$(jq -ce 'if type == "array" and all(type == "string") then . else empty end' "$connectors" 2>/dev/null) ||
      die "cannot read the connectors to keep, $connectors (a JSON list of names), so the connectors to deny are unknown"
  fi
  code=$(dirname "$(dirname "$TEAM_LIB")")
  named=(--arg @TEAM_CODE@ "$code")
  for pair; do
    [[ $pair =~ ^(@[A-Z_]+@)=(.*)$ ]] || die "launch_settings: not a substitution @<KEY>@=<value>: $pair"
    named+=(--arg "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
  done
  # {placeholder: value}, each placeholder replaced as written, not as a pattern.
  subs=$(jq -cn '$ARGS.named' "${named[@]}")
  local substitute='walk(if type == "string"
    then reduce ($subs | to_entries[]) as $s (.; split($s.key) | join($s.value)) else . end)'

  if [[ -n $mcp_template ]]; then
    jq --argjson subs "$subs" "$substitute" "$mcp_template" >"$mcp.$$"
  else
    echo '{"mcpServers": {}}' >"$mcp.$$"
  fi
  mv -f "$mcp.$$" "$mcp"

  listed=$(launch_unlocked claude mcp list) || die "claude mcp list failed, so the servers to deny are unknown"
  while IFS= read -r line; do
    if [[ $line =~ ^(([^:]|:[^ ])+):\ .+\ -\ .+$ ]]; then servers+=("${BASH_REMATCH[1]}"); fi
    [[ -n $first || $line != *[![:space:]]* ]] || first=$line
    [[ $line != 'No MCP servers configured.'* ]] || empty=1
  done <<<"$listed"
  # A list whose lines name no server is one this parse cannot read, unless it says it is empty.
  [[ ${#servers[@]} -gt 0 || -z $first || -n $empty ]] ||
    die "claude mcp list printed lines but named no server in its format (\"<name>: <what it runs> - <health>\"), so the servers to deny are unknown; its first line: $first"

  jq --argjson subs "$subs" --slurpfile mcp "$mcp" --argjson connectors "$kept" \
    "$substitute"' as $settings
    | (($mcp[0].mcpServers // {} | keys) + $connectors) as $own
    | [$settings.enabledPlugins // {} | to_entries[] | select(.value == true) | "plugin:\(.key | split("@")[0]):"] as $plugins
    | $settings
    | .deniedMcpServers = [$ARGS.positional | unique[]
        | select(. as $name | (IN($own[]) | not) and all($plugins[]; . as $p | $name | startswith($p) | not))
        | {serverName: .}]' "$template" --args "${servers[@]}" >"$settings.$$"
  mv -f "$settings.$$" "$settings"
}

# launch_skills_off <settings> <plugin directory>: sets, in the settings launch_settings wrote,
# skillOverrides.<name> to "off" for each personal skill of the user, so the session's skill
# listing holds none of them and one the user adds later is off at the next launch. A personal
# skill is a directory of ${CLAUDE_CONFIG_DIR:-~/.claude}/skills that holds a SKILL.md, and its
# names are the directory's and, when its frontmatter has a name line, that one's too, so it is
# off whichever of the two Claude Code lists it by. A name the settings already override keeps its
# value, and a name <plugin directory>/skills holds gets no entry, since an override by a bare
# name may reach the plugin's skill of that name. Written whole, then moved into place.
launch_skills_off() {
  local settings=$1 plugin=$2 dir line skill_name
  local -a skill_names=() found=()
  local -A skills_kept=()
  for dir in "$plugin"/skills/*/; do
    [[ ! -d $dir ]] || skills_kept[$(basename "$dir")]=1
  done
  for dir in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/skills/*/; do
    [[ -f ${dir}SKILL.md ]] || continue
    found=("$(basename "$dir")")
    {
      IFS= read -r line && [[ $line == --- ]] && while IFS= read -r line && [[ $line != --- ]]; do
        [[ $line =~ ^name:[[:space:]]*[\"\']?([^\"\']*[^\"\'[:space:]]) ]] || continue
        found+=("${BASH_REMATCH[1]}")
        break
      done
    } <"${dir}SKILL.md" || true
    for skill_name in "${found[@]}"; do
      [[ -n ${skills_kept[$skill_name]:-} ]] || skill_names+=("$skill_name")
    done
  done
  jq '.skillOverrides = (reduce $ARGS.positional[] as $name ({}; .[$name] = "off")) + (.skillOverrides // {})' \
    "$settings" --args "${skill_names[@]}" >"$settings.$$"
  mv -f "$settings.$$" "$settings"
}
