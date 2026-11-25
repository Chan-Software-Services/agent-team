# models        The team home's models.toml, the model and effort of every session category
#               (sops/models.md): passes when `team-models --check` finds no problem, counting
#               its lines and naming the default line's model and effort (the settings' word
#               where no line names one, or one says default); warns with no file, since every
#               session then runs on the user settings' model; fails naming --check's first
#               problem.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and err, the doctor's

if [[ ! -f $TEAM_HOME/models.toml ]]; then
  report models WARN "no models.toml in the team home, so every session runs on the user settings' model" \
    "write it as sops/models.md says"
elif ! TEAM_HOME=$TEAM_HOME "$bin/team-models" --check 2>"$err" </dev/null; then
  report models FAIL "$(first_error)" "fix that line of models.toml, then team-models --check"
elif ! models_default=$(TEAM_HOME=$TEAM_HOME "$bin/team-models" resolve --category default 2>"$err" </dev/null) ||
  ! models_lines=$(python3 -I -c 'import sys, tomllib; print(len(tomllib.load(open(sys.argv[1], "rb"))))' \
    "$TEAM_HOME/models.toml" 2>"$err" </dev/null); then
  report models FAIL "models.toml passes team-models --check but does not resolve: $(first_error)" \
    "fix that line of models.toml, then team-models --check"
else
  # Each axis of the default line, or the settings' word where none names it.
  models_default=$(jq -r '[(.model // "default" | if . == "default" then "the settings'\'' model" else . end),
    (.effort // "default" | if . == "default" then "the settings'\'' effort" else . end)] | "\(.[0]) at \(.[1])"' \
    <<<"$models_default")
  models_noun=lines
  ((models_lines != 1)) || models_noun=line
  report models PASS "models.toml reads: $models_lines $models_noun; default $models_default"
fi
