# moved origins No checkout's origin names a repository that moved owner (bin/lib/repo-moves.json):
#               the code checkout's (its primary checkout, when the doctor runs from a linked
#               worktree), the team home's and each registered project's primary checkout's, an
#               HTTPS or SSH URL, a trailing .git or slash aside, compared in any case. A linked
#               worktree shares its checkout's config, so the primary checkouts alone are read,
#               each once. Fails naming each, with its fix git -C <path> remote set-url origin
#               https://github.com/<to>.git, or for a treehouse project the pool move, since
#               treehouse names a pool from the origin URL (sops/portability.md, A repository
#               that moves owner); passes saying how many origins it read. A checkout that is
#               missing or has no origin is the other lines', as is the team home while the team
#               home line fails, and the projects while team-project refuses the registry.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin, the doctor's; home_ok, from the team home check
# reads state from: 080-team-home.sh

# Each checkout to read: its path, its label, and its project's pool provider (empty for none).
moved_paths=() moved_labels=() moved_providers=()
# moved_add <path> <label> <provider>: one checkout, unless an earlier one is the same directory,
# whose provider it gives when the earlier has none (the code checkout registered as a project).
moved_add() {
  local i
  for i in "${!moved_paths[@]}"; do
    if same_path "${moved_paths[i]}" "$1"; then
      [[ -n ${moved_providers[i]} ]] || moved_providers[i]=$3
      return 0
    fi
  done
  moved_paths+=("$1") moved_labels+=("$2") moved_providers+=("$3")
}

moved_code=$(dirname "$bin")
moved_common=$(git -C "$moved_code" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
  [[ ${moved_common##*/} == .git ]] && moved_code=$(dirname "$moved_common")
moved_add "$moved_code" "the code checkout" ''
((!home_ok)) || moved_add "$TEAM_HOME" "the team home" ''
if project_registry --list 2>/dev/null; then
  while IFS= read -r moved_project; do
    [[ -n $moved_project ]] || continue
    project_registry "$moved_project" 2>/dev/null || continue
    mapfile -d '' -t moved_fields < <(jq --raw-output0 '.path, .pool.provider' <<<"$registry_reply")
    moved_add "${moved_fields[0]}" "$moved_project's checkout" "${moved_fields[1]}:$moved_project"
  done <<<"$registry_reply"
fi

moved_read=0 moved_reasons=() moved_fixes=()
for moved_i in "${!moved_paths[@]}"; do
  moved_path=${moved_paths[moved_i]}
  [[ -d $moved_path ]] || continue
  moved_url=$(git -C "$moved_path" remote get-url origin 2>/dev/null) || continue
  moved_read=$((moved_read + 1))
  moved_to=$(moved_origin "$moved_url")
  [[ -n $moved_to ]] || continue
  moved_shown=$(tilde "$moved_path")
  moved_reasons+=("${moved_labels[moved_i]} $moved_shown has origin $moved_url, a repository that moved to $moved_to")
  if [[ ${moved_providers[moved_i]} == treehouse:* ]]; then
    moved_fixes+=("$(pool_move_fix "${moved_providers[moved_i]#treehouse:}")")
  else
    moved_fixes+=("git -C $moved_shown remote set-url origin https://github.com/$moved_to.git")
  fi
done

if ((${#moved_reasons[@]})); then
  report "moved origins" FAIL "$(printf '%s; ' "${moved_reasons[@]}" | sed 's/; $//')" \
    "$(printf '%s; ' "${moved_fixes[@]}" | sed 's/; $//')"
else
  moved_count="$moved_read origins"
  ((moved_read != 1)) || moved_count="1 origin"
  report "moved origins" PASS "read $moved_count (the code checkout's, the team home's and each project's primary checkout's), and none names a moved repository of bin/lib/repo-moves.json"
fi
