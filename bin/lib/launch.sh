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
#                                list names but its own denied, and the worker login's
#                                environment when bin/lib/worker-login names one; refuses, before
#                                writing anything, while that login is not on this machine.
#   launch_skills_off <settings> <plugin directory>
#                                turns off, in the written settings, each of the user's personal
#                                skills but one named as a skill of the plugin.
#   launch_models <category> <settings>
#                                resolves the category's line of the team home's models.toml
#                                (bin/team-models resolve), writes its subagent fields into the
#                                written settings' env, and sets LAUNCH_MODEL_ARGS, the --model
#                                and --effort to pass, and LAUNCH_CHOICE, what the launch runs
#                                on; a file that does not read is a warning, and the settings'
#                                word stands.
#   launch_log <name> <launch output>
#                                appends the launch's line to the team home's sessions.jsonl:
#                                {ts, machine, name}, LAUNCH_CHOICE's fields and the id the
#                                output names; a failed write is a warning.
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
# With the worker login on (bin/lib/github-login.sh), the settings' env gains worker_login_env's
# pairs, so gh and git in the session answer as that login; with it off, the settings are the
# template's alone. Before writing anything it refuses, with the reader's message, a malformed
# bin/lib/worker-login, and, naming the reason and the fix, a login whose file is not usable here,
# since gh and git would then answer as the machine's own login.
launch_settings() {
  local template=$1 mcp_template=$2 connectors=$3 settings=$4 mcp=$5 code listed line first='' empty='' pair subs
  local kept='[]' login_name login_env
  local -a servers=() named=()
  shift 5
  login_name=$(worker_login) || exit 1
  login_env=$(worker_login_settings_env "$login_name") || exit 1
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

  jq --argjson subs "$subs" --slurpfile mcp "$mcp" --argjson connectors "$kept" --argjson login "$login_env" \
    "$substitute"' as $settings
    | (($mcp[0].mcpServers // {} | keys) + $connectors) as $own
    | [$settings.enabledPlugins // {} | to_entries[] | select(.value == true) | "plugin:\(.key | split("@")[0]):"] as $plugins
    | $settings
    | .deniedMcpServers = [$ARGS.positional | unique[]
        | select(. as $name | (IN($own[]) | not) and all($plugins[]; . as $p | $name | startswith($p) | not))
        | {serverName: .}]
    | if $login == {} then . else .env = (.env // {}) + $login end' "$template" --args "${servers[@]}" >"$settings.$$"
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

# This library's own bin/, where team-models lives.
LAUNCH_BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# launch_models <category> <settings>: the model and effort the session of <category> launches
# on, from the team home's models.toml as `team-models resolve --category <category>` reads it
# (sops/models.md), for the settings launch_settings wrote at <settings>.
# Sets LAUNCH_MODEL_ARGS to --model <m> when a line names the model and --effort <e> when a line
# names the effort (a value of default names none); writes a line's subagent_model and
# subagent_effort, but default, into <settings>' env as CLAUDE_CODE_SUBAGENT_MODEL and
# CLAUDE_CODE_SUBAGENT_EFFORT, written whole and then moved into place; and sets LAUNCH_CHOICE to
# the JSON object {category, model, model_from, effort, effort_from}, with subagent_model and
# subagent_effort when written, for launch_log.
# An axis no line names is the settings' word, as Claude Code reads it, logged settings: the model
# an ANTHROPIC_MODEL in the env of <settings>, then of the user settings
# (${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json), then their model key in that order; the effort
# a CLAUDE_CODE_EFFORT_LEVEL in the env of each, then each one's modelSettings.<the model>.effortLevel,
# then each one's effortLevel; with none, Claude Code's own default, logged default.
# A missing file names nothing. A file that does not read (team-models exits non-zero) is a
# warning on stderr, "<script>: models.toml does not read: <its first line>; launching on the
# settings' model", and names nothing, so the session that fixes the file still starts.
# TEAM_HOME, when set, names the team home to team-models, else it finds it as every script does.
launch_models() {
  local category=$1 settings=$2 out status=0 user config_model='' config_effort='' sub='{}'
  LAUNCH_MODEL_ARGS=()
  out=$(TEAM_HOME=${TEAM_HOME:-} launch_unlocked "$LAUNCH_BIN/team-models" resolve --category "$category" 2>&1) || status=$?
  if ((status == 0)) && out=$(tail -n 1 <<<"$out" | jq -ce 'select(type == "object")' 2>/dev/null); then
    config_model=$(jq -r '.model // "" | select(. != "default")' <<<"$out")
    config_effort=$(jq -r '.effort // "" | select(. != "default")' <<<"$out")
    sub=$(jq -c '{subagent_model, subagent_effort} | with_entries(select(.value != null and .value != "default"))' <<<"$out")
  else
    echo "${0##*/}: models.toml does not read: $(head -n 1 <<<"$out"); launching on the settings' model" >&2
  fi
  [[ -z $config_model ]] || LAUNCH_MODEL_ARGS+=(--model "$config_model")
  [[ -z $config_effort ]] || LAUNCH_MODEL_ARGS+=(--effort "$config_effort")
  if [[ $sub != '{}' ]]; then
    jq --argjson sub "$sub" '.env = (.env // {})
      + ({CLAUDE_CODE_SUBAGENT_MODEL: $sub.subagent_model, CLAUDE_CODE_SUBAGENT_EFFORT: $sub.subagent_effort}
        | with_entries(select(.value != null)))' "$settings" >"$settings.$$"
    mv -f "$settings.$$" "$settings"
  fi
  user=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
  [[ -f $user ]] || user=/dev/null
  LAUNCH_CHOICE=$(jq -cn --arg category "$category" --arg model "$config_model" --arg effort "$config_effort" \
    --argjson sub "$sub" '[inputs] as $s
    | def word(f): [$s[] | f | strings | select(. != "")] | first;
    (if $model != "" then {model: $model, model_from: "config"}
      else (word(.env.ANTHROPIC_MODEL?) // word(.model?)) as $m
        | if $m then {model: $m, model_from: "settings"} else {model: "default", model_from: "default"} end
      end) as $chosen
    | (if $effort != "" then {effort: $effort, effort_from: "config"}
      else (word(.env.CLAUDE_CODE_EFFORT_LEVEL?) // word(.modelSettings?[$chosen.model]?.effortLevel?)
          // word(.effortLevel?)) as $e
        | if $e then {effort: $e, effort_from: "settings"} else {effort: "default", effort_from: "default"} end
      end) as $level
    | {category: $category} + $chosen + $level + $sub' "$settings" "$user" 2>/dev/null) ||
    LAUNCH_CHOICE=$(jq -cn --arg category "$category" --arg model "$config_model" --arg effort "$config_effort" \
      --argjson sub "$sub" '{category: $category}
      + (if $model != "" then {model: $model, model_from: "config"} else {model: "default", model_from: "default"} end)
      + (if $effort != "" then {effort: $effort, effort_from: "config"} else {effort: "default", effort_from: "default"} end)
      + $sub')
}

# launch_log <name> <launch output>: appends one line to the team home's sessions.jsonl, after
# claude --bg returned: {ts, machine, name, category, model, model_from, effort, effort_from},
# from LAUNCH_CHOICE (launch_models), with id, the output's first 8-character hex word, when it
# names one, and subagent_model and subagent_effort when LAUNCH_CHOICE has them. The session is
# already running, so a line it cannot write (no team name for this machine, a team home it
# cannot write) is a warning on stderr, "<script>: could not record the launch in <file>: <why>;
# the session runs on", and returns 0. team-checkpoint commits the file with the ledger.
launch_log() {
  local name=$1 out=$2 file=$TEAM_HOME/sessions.jsonl id machine line why
  id=$(grep -oE '\b[0-9a-f]{8}\b' <<<"$out" | head -n 1) || id=''
  if ! machine=$(machine_name 2>&1); then
    echo "${0##*/}: could not record the launch in $file: ${machine#"${0##*/}: "}; the session runs on" >&2
    return 0
  fi
  line=$(jq -cn --arg machine "$machine" --arg name "$name" --arg id "$id" --argjson choice "$LAUNCH_CHOICE" \
    '{ts: (now | floor | todate), machine: $machine, name: $name}
    + ($choice | {category, model, model_from, effort, effort_from})
    + (if $id == "" then {} else {id: $id} end)
    + ($choice | with_entries(select(.key == "subagent_model" or .key == "subagent_effort")))')
  if ! why=$({ printf '%s\n' "$line" >>"$file"; } 2>&1); then
    echo "${0##*/}: could not record the launch in $file: ${why##*: }; the session runs on" >&2
  fi
  return 0
}
