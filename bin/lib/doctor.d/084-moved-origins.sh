# moved origins No checkout's origin names a repository that moved owner (bin/lib/repo-moves.json):
#               the code checkout's (its primary checkout, when the doctor runs from a linked
#               worktree) and the team home's on this line, and each other registered project's
#               primary checkout's on a line of its own, moved origin <project>, so the load
#               check judges it by project as the other per-project lines; an HTTPS or SSH URL, a
#               trailing .git or slash aside, compared in any case. A linked worktree shares its
#               checkout's config, so the primary checkouts alone are read, each once, and a
#               project whose primary checkout is the code checkout or the team home stays on
#               this line. A line fails naming each checkout, with its fix git -C <path> remote
#               set-url origin https://github.com/<to>.git, or for a treehouse project the pool
#               move, since treehouse names a pool from the origin URL (sops/portability.md, A
#               repository that moves owner); this line passes saying how many origins it read,
#               and a project's its origin. A checkout that is missing or has no origin is left
#               to the other lines, a project's with no line here, as are the team home while the
#               team home line fails and the projects while team-project refuses the registry.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, the doctor's; home_ok, from the team home check
# reads state from: 080-team-home.sh

# Each checkout to read: its path, its label, its project (empty for the code checkout and the
# team home, whose line is moved origins) and its project's pool provider (empty for none).
moved_paths=() moved_labels=() moved_projects=() moved_providers=()
# moved_add <path> <label> <project> <provider>: one checkout, unless an earlier one is the same
# directory, whose provider it gives when the earlier has none (the code checkout registered as a
# project, which stays on the code checkout's line).
moved_add() {
  local i
  for i in "${!moved_paths[@]}"; do
    if same_path "${moved_paths[i]}" "$1"; then
      [[ -n ${moved_providers[i]} ]] || moved_providers[i]=$4
      return 0
    fi
  done
  moved_paths+=("$1") moved_labels+=("$2") moved_projects+=("$3") moved_providers+=("$4")
}

moved_code=$(dirname "$bin")
moved_common=$(git -C "$moved_code" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
  [[ ${moved_common##*/} == .git ]] && moved_code=$(dirname "$moved_common")
moved_add "$moved_code" "the code checkout" '' ''
((!home_ok)) || moved_add "$TEAM_HOME" "the team home" '' ''
if project_registry --list 2>/dev/null; then
  while IFS= read -r moved_project; do
    [[ -n $moved_project ]] || continue
    project_registry "$moved_project" 2>/dev/null || continue
    mapfile -d '' -t moved_fields < <(jq --raw-output0 '.path, .pool.provider' <<<"$registry_reply")
    moved_add "${moved_fields[0]}" "$moved_project's checkout" "$moved_project" "${moved_fields[1]}:$moved_project"
  done <<<"$registry_reply"
fi

# moved_judge <i>: false when checkout <i> is missing or has no origin, which are the other lines';
# else true, with moved_url and moved_shown its origin and path, and moved_reason and moved_fix
# empty, or naming the move and its fix when the origin names a moved repository.
moved_judge() {
  local path=${moved_paths[$1]} to
  moved_reason='' moved_fix=''
  [[ -d $path ]] || return 1
  moved_url=$(git -C "$path" remote get-url origin 2>/dev/null) || return 1
  moved_shown=$(tilde "$path")
  to=$(moved_origin "$moved_url")
  [[ -n $to ]] || return 0
  moved_reason="${moved_labels[$1]} $moved_shown has origin $moved_url, a repository that moved to $to"
  if [[ ${moved_providers[$1]} == treehouse:* ]]; then
    moved_fix=$(pool_move_fix "${moved_providers[$1]#treehouse:}")
  else
    moved_fix="git -C $moved_shown remote set-url origin https://github.com/$to.git"
  fi
}

# The code checkout's and the team home's line.
moved_read=0 moved_reasons=() moved_fixes=()
for moved_i in "${!moved_paths[@]}"; do
  [[ -z ${moved_projects[moved_i]} ]] || continue
  moved_judge "$moved_i" || continue
  moved_read=$((moved_read + 1))
  [[ -z $moved_reason ]] || moved_reasons+=("$moved_reason") moved_fixes+=("$moved_fix")
done
if ((${#moved_reasons[@]})); then
  report "moved origins" FAIL "$(printf '%s; ' "${moved_reasons[@]}" | sed 's/; $//')" \
    "$(printf '%s; ' "${moved_fixes[@]}" | sed 's/; $//')"
else
  moved_count="$moved_read origins"
  ((moved_read != 1)) || moved_count="1 origin"
  report "moved origins" PASS "read $moved_count (the code checkout's and the team home's), and none names a moved repository of bin/lib/repo-moves.json"
fi

# Each other project's line, in the registry's order.
for moved_i in "${!moved_paths[@]}"; do
  moved_project=${moved_projects[moved_i]}
  [[ -n $moved_project ]] || continue
  moved_judge "$moved_i" || continue
  if [[ -n $moved_reason ]]; then
    report "moved origin $moved_project" FAIL "$moved_reason" "$moved_fix"
  else
    report "moved origin $moved_project" PASS "${moved_labels[moved_i]} $moved_shown has origin $moved_url, which names no moved repository of bin/lib/repo-moves.json"
  fi
done
