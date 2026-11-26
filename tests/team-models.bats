#!/usr/bin/env bats
# team-models: reading, checking and resolving the model config, models.toml in the team home.

load helpers/common

setup() {
  sandbox
  cp "$REPO_ROOT/tests/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
}

# Replace the team home's models.toml with the TOML on stdin.
models() {
  cat >"$TEAM_HOME/models.toml"
}

# The one field of resolve's JSON, as jq -r prints it: field <name>
field() {
  jq -r ".$1" <<<"$output"
}

# The templates of the brief directory <dir> that the table does not map, one per line, the two
# resumes aside: unmapped_templates <dir>
unmapped_templates() {
  local template mapped
  mapped=$("$REPO_ROOT/bin/team-models" templates | cut -d' ' -f1)
  for template in "$1"/*.md; do
    template=$(basename "$template" .md)
    [[ $template == @(resume|resume-crash) ]] && continue
    grep -qxF "$template" <<<"$mapped" || echo "$template"
  done
}

@test "--help prints the header, which documents the line form, the categories, the templates and the precedence" {
  run_bin -0 team-models --help
  assert_equal "${lines[0]}" "Read the model config, models.toml in the team home: which model and effort each session category launches on."
  assert_contains "$output" '"builder path=small" = { model = "sonnet", effort = "high" }'
  assert_contains "$output" "reviewer.rereview          rereview"
  assert_contains "$output" "planner.retro              retro"
  assert_contains "$output" "Specificity is compared in order: the category's depth"
}

@test "--check passes the shipped file with no output" {
  cp "$REPO_ROOT/tests/fixtures/models.toml" "$TEAM_HOME/models.toml"
  run_bin -0 --separate-stderr team-models --check
  assert_equal "$output" ""
  assert_equal "$stderr" ""
}

@test "the shipped file is its header comment and Opus at high for default" {
  assert_equal "$(cat "$REPO_ROOT/tests/fixtures/models.toml")" '# The model and effort of every session category: sops/models.md.
"default" = { model = "opus", effort = "high" }'
}

@test "--check passes a file of every kind of line, a registered project included" {
  models <<'TOML'
"default" = { model = "opus", effort = "high" }
"reviewer.rereview" = { model = "sonnet" }
"builder path=small" = { model = "sonnet", effort = "high" }
"planner" = { subagent_model = "haiku", subagent_effort = "low" }
"default project=conventioner" = { model = "claude-sonnet-5-5[1m]" }
"builder.fix project=agent-team path=bug" = { model = "default", effort = "default" }
"coordinator" = { model = "fable", effort = "xhigh" }
TOML
  run_bin -0 --separate-stderr team-models --check
  assert_equal "$stderr" ""
}

@test "--check names a TOML syntax error with its line" {
  models <<'TOML'
"default" = { model = "opus" }
"reviewer" = { model = }
TOML
  run_bin -1 --separate-stderr team-models --check
  assert_equal "$output" ""
  assert_equal "$stderr" "models.toml: line 2, column 24: not valid TOML: Invalid value"
}

@test "--check names a bare dotted key, saying to quote it" {
  models <<'TOML'
"default" = { model = "opus" }
reviewer.rereview = { model = "sonnet" }
TOML
  run_bin -1 --separate-stderr team-models --check
  assert_equal "$stderr" 'models.toml: reviewer.rereview: quote the key: "reviewer.rereview"'
}

@test "--check names each problem on its own line, and exits 1" {
  models <<'TOML'
"default" = { model = "opus", effort = "high" }
"reviewr" = { model = "sonnet" }
"builder team=x" = { model = "sonnet" }
"builder path=small project=agent-team" = { model = "sonnet" }
"builder project=nowhere" = { model = "sonnet" }
"builder path=huge" = { model = "sonnet" }
"planner" = { modle = "sonnet" }
"reviewer" = { model = "sonet", effort = "hgh" }
"ops" = "opus"
"ops.load-check" = { subagent_model = "claude-", subagent_effort = 3 }
"builder  path=small" = { model = "sonnet" }
"coordinator project=agent-team" = { model = "sonnet" }
"builder.ticket" = {}
TOML
  run_bin -1 --separate-stderr team-models --check
  assert_equal "$output" ""
  local known="default, coordinator, coordinator.compaction-drill, assistant, assistant.load-check, planner, planner.feature, planner.research, planner.interview, planner.walk, planner.retro, planner.load-check, builder, builder.ticket, builder.deliver, builder.fix, builder.round, builder.merge-base, builder.load-check, reviewer, reviewer.review, reviewer.rereview, reviewer.verify, reviewer.load-check, ops, ops.load-check, topic, topic.load-check"
  assert_equal "$stderr" "models.toml: \"reviewr\": unknown category 'reviewr'; known: $known
models.toml: \"builder team=x\": unknown qualifier 'team'; one of project, path
models.toml: \"builder path=small project=agent-team\": the qualifiers go project= first, then path=, each at most once
models.toml: \"builder project=nowhere\": project 'nowhere' is not in the registry; known: conventioner, agent-team, no-mistakes
models.toml: \"builder path=huge\": unknown path 'huge'; one of feature, bug, small, research, retro, topic
models.toml: \"planner\": unknown field 'modle'; one of model, effort, subagent_model, subagent_effort
models.toml: \"reviewer\": model: 'sonet' is not opus, sonnet, haiku, fable or claude-<name>, each optionally with [1m], or default
models.toml: \"reviewer\": effort: 'hgh' is not one of low, medium, high, xhigh, max, default
models.toml: \"ops\": must be an inline table, such as { model = \"opus\", effort = \"high\" }
models.toml: \"ops.load-check\": subagent_model: 'claude-' is not opus, sonnet, haiku, fable or claude-<name>, each optionally with [1m], or default
models.toml: \"ops.load-check\": subagent_effort: must be a string
models.toml: \"builder  path=small\": single spaces between the category and each qualifier, none around them
models.toml: \"coordinator project=agent-team\": a coordinator launch has no project and no path, so this line would never match
models.toml: \"builder.ticket\": names no field; one of model, effort, subagent_model, subagent_effort"
}

@test "--check names a project= it cannot check when the registry does not read" {
  rm "$TEAM_HOME/projects.toml"
  models <<<'"builder project=agent-team" = { model = "sonnet" }'
  run_bin -1 --separate-stderr team-models --check
  assert_contains "$stderr" "models.toml: \"builder project=agent-team\": cannot check project 'agent-team': team-project --list failed: team-project: no registry at $TEAM_HOME/projects.toml"
}

@test "--check of a missing file is exit 1 naming the team home, and --file's names the file" {
  run_bin -1 --separate-stderr team-models --check
  assert_equal "$stderr" "team-models: no models.toml in $TEAM_HOME"
  run_bin -1 --separate-stderr team-models --check --file "$BATS_TEST_TMPDIR/staged.toml"
  assert_equal "$stderr" "team-models: no file $BATS_TEST_TMPDIR/staged.toml"
}

@test "--check --file reads that file, not the team home's" {
  models <<<'"reviewr" = { model = "sonnet" }'
  cp "$REPO_ROOT/tests/fixtures/models.toml" "$BATS_TEST_TMPDIR/staged.toml"
  run_bin -0 team-models --check --file "$BATS_TEST_TMPDIR/staged.toml"
  printf '"default" = { model = "sonet" }\n' >"$BATS_TEST_TMPDIR/staged.toml"
  run_bin -1 --separate-stderr team-models --check --file "$BATS_TEST_TMPDIR/staged.toml"
  assert_contains "$stderr" "models.toml: \"default\": model: 'sonet' is not"
}

@test "resolve prints every axis and the line that chose it, in the spec's order" {
  cp "$REPO_ROOT/tests/fixtures/models.toml" "$TEAM_HOME/models.toml"
  run_bin -0 team-models resolve --category reviewer.rereview
  assert_equal "$(jq -c . <<<"$output")" '{"category":"reviewer.rereview","present":true,"model":"opus","model_line":"default","effort":"high","effort_line":"default","subagent_model":null,"subagent_line":null,"subagent_effort":null,"subagent_effort_line":null}'
}

@test "resolve takes a category's own line over its parent's, and a parent's over default's" {
  models <<'TOML'
"default" = { model = "opus" }
"reviewer" = { model = "sonnet" }
"reviewer.rereview" = { model = "haiku" }
TOML
  run_bin -0 team-models resolve --category reviewer.rereview
  assert_equal "$(field model) $(field model_line)" "haiku reviewer.rereview"
  run_bin -0 team-models resolve --category reviewer.verify
  assert_equal "$(field model) $(field model_line)" "sonnet reviewer"
  run_bin -0 team-models resolve --category builder.ticket
  assert_equal "$(field model) $(field model_line)" "opus default"
}

@test "resolve takes project= over none and path= over none, and only for a launch of that project or path" {
  models <<'TOML'
"builder" = { model = "opus" }
"builder project=conventioner" = { model = "sonnet" }
"reviewer" = { model = "opus" }
"reviewer path=small" = { model = "haiku" }
TOML
  run_bin -0 team-models resolve --category builder.ticket --project conventioner
  assert_equal "$(field model) $(field model_line)" "sonnet builder project=conventioner"
  run_bin -0 team-models resolve --category builder.ticket --project agent-team
  assert_equal "$(field model_line)" "builder"
  run_bin -0 team-models resolve --category builder.ticket
  assert_equal "$(field model_line)" "builder"
  run_bin -0 team-models resolve --category reviewer.review --path small
  assert_equal "$(field model) $(field model_line)" "haiku reviewer path=small"
  run_bin -0 team-models resolve --category reviewer.review --path feature
  assert_equal "$(field model_line)" "reviewer"
}

@test "a topic session resolves as team-worker launches it, its template, project and the path topic, to the topic category" {
  models <<'TOML'
"default" = { model = "opus", effort = "high" }
"topic" = { model = "sonnet" }
"topic project=agent-team" = { effort = "medium" }
"topic.load-check" = { model = "haiku" }
TOML
  run_bin -0 team-models --check
  run_bin -0 team-models resolve --role topic --template topic --project agent-team --path topic
  assert_equal "$(field category) $(field model) $(field model_line) $(field effort) $(field effort_line)" \
    "topic sonnet topic medium topic project=agent-team"
  run_bin -0 team-models resolve --role topic --load-check
  assert_equal "$(field category) $(field model) $(field model_line)" "topic.load-check haiku topic.load-check"
}

@test "resolve takes the deeper category over a project, and a project over a path" {
  models <<'TOML'
"default project=conventioner" = { model = "sonnet", effort = "low" }
"builder" = { model = "opus" }
"builder path=small" = { model = "haiku", effort = "medium" }
"builder project=conventioner" = { effort = "max" }
TOML
  run_bin -0 team-models resolve --category builder.ticket --project conventioner --path small
  assert_equal "$(field model) $(field model_line)" "haiku builder path=small"
  assert_equal "$(field effort) $(field effort_line)" "max builder project=conventioner"
  run_bin -0 team-models resolve --category reviewer --project conventioner --path small
  assert_equal "$(field model_line) $(field effort_line)" "default project=conventioner default project=conventioner"
}

@test "resolve takes each axis from its own most specific line" {
  models <<'TOML'
"default" = { model = "opus", effort = "high" }
"planner" = { subagent_model = "haiku", subagent_effort = "low" }
"planner.research" = { model = "sonnet", subagent_effort = "medium" }
TOML
  run_bin -0 team-models resolve --category planner.research
  assert_equal "$(jq -c . <<<"$output")" '{"category":"planner.research","present":true,"model":"sonnet","model_line":"planner.research","effort":"high","effort_line":"default","subagent_model":"haiku","subagent_line":"planner","subagent_effort":"medium","subagent_effort_line":"planner.research"}'
}

@test "resolve gives a default value as default, with the line that says it" {
  models <<'TOML'
"default" = { model = "opus", effort = "high" }
"ops" = { model = "default", effort = "default" }
TOML
  run_bin -0 team-models resolve --role ops
  assert_equal "$(field model) $(field model_line) $(field effort) $(field effort_line)" "default ops default ops"
}

@test "resolve of a missing file gives present false and every axis null" {
  run_bin -0 team-models resolve --role builder --template builder-ticket --project agent-team --path small
  assert_equal "$(jq -c . <<<"$output")" '{"category":"builder.ticket","present":false,"model":null,"model_line":null,"effort":null,"effort_line":null,"subagent_model":null,"subagent_line":null,"subagent_effort":null,"subagent_effort_line":null}'
}

@test "resolve of an invalid file is exit 1 with --check's lines" {
  models <<<'"default" = { model = "sonet" }'
  run_bin -1 --separate-stderr team-models resolve --role builder
  assert_equal "$output" ""
  assert_equal "$stderr" "models.toml: \"default\": model: 'sonet' is not opus, sonnet, haiku, fable or claude-<name>, each optionally with [1m], or default"
}

@test "resolve --role maps each template through the table, and gives the role's own category alone" {
  local template category role
  cp "$REPO_ROOT/tests/fixtures/models.toml" "$TEAM_HOME/models.toml"
  while read -r template category; do
    role=${category%%.*}
    run_bin -0 team-models resolve --role "$role" --template "$template"
    assert_equal "$template $(field category)" "$template $category"
  done < <("$REPO_ROOT/bin/team-models" templates)
  for role in planner builder reviewer ops topic coordinator assistant; do
    run_bin -0 team-models resolve --role "$role"
    assert_equal "$(field category)" "$role"
  done
  run_bin -0 team-models resolve --role reviewer --template verify
  assert_equal "$(field category)" "reviewer.verify"
  run_bin -0 team-models resolve --role planner --template retro
  assert_equal "$(field category)" "planner.retro"
}

@test "resolve --load-check gives the role's load-check category, whatever the template" {
  local role
  for role in planner builder reviewer ops topic assistant; do
    run_bin -0 team-models resolve --role "$role" --load-check
    assert_equal "$(field category)" "$role.load-check"
  done
  run_bin -0 team-models resolve --role reviewer --template rereview --load-check
  assert_equal "$(field category)" "reviewer.load-check"
}

@test "a load-check line falls back to its role's" {
  models <<'TOML'
"default" = { model = "opus" }
"reviewer" = { model = "sonnet" }
TOML
  run_bin -0 team-models resolve --role reviewer --load-check
  assert_equal "$(field model) $(field model_line)" "sonnet reviewer"
}

@test "resolve refuses an unknown category, role or template, a resume template and a template of another role, exit 2" {
  run_bin -2 --separate-stderr team-models resolve --category reviewer.again
  assert_contains "$stderr" "unknown category 'reviewer.again'; known: default, coordinator,"
  run_bin -2 --separate-stderr team-models resolve --role tester
  assert_contains "$stderr" "unknown role 'tester'; one of coordinator, assistant, planner, builder, reviewer, ops, topic"
  run_bin -2 --separate-stderr team-models resolve --role builder --template builder-nap
  assert_contains "$stderr" "unknown template 'builder-nap'; known: planner-feature,"
  run_bin -2 --separate-stderr team-models resolve --role builder --template resume
  assert_contains "$stderr" "the template resume takes the category of the brief it resumes"
  run_bin -2 --separate-stderr team-models resolve --role builder --template rereview
  assert_contains "$stderr" "the template rereview is a reviewer's, not a builder's"
  run_bin -2 --separate-stderr team-models resolve --role coordinator --load-check
  assert_contains "$stderr" "the role coordinator has no load-check category"
  run_bin -2 --separate-stderr team-models resolve --category builder --role builder
  assert_contains "$stderr" "give --category or --role, not both"
  run_bin -2 --separate-stderr team-models resolve --role builder --path huge
  assert_contains "$stderr" "--path 'huge' is not one of feature, bug, small, research, retro, topic"
  run_bin -2 --separate-stderr team-models resolve
  assert_contains "$stderr" "give --category or --role, not both"
}

@test "a malformed command line is exit 2 with the usage" {
  run_bin -2 --separate-stderr team-models
  assert_contains "$stderr" "usage: team-models --check"
  run_bin -2 --separate-stderr team-models frobnicate
  assert_contains "$stderr" "unknown command 'frobnicate'"
  run_bin -2 --separate-stderr team-models --check --project agent-team
  assert_contains "$stderr" "--check takes only --file"
  run_bin -2 --separate-stderr team-models resolve --role builder --file
  assert_contains "$stderr" "--file needs a value"
}

@test "list prints one row per category in the table's order, each axis with its line, and subagent fields where set" {
  models <<'TOML'
"default" = { model = "opus", effort = "high" }
"reviewer.rereview" = { model = "sonnet" }
"planner" = { subagent_model = "haiku" }
TOML
  run_bin -0 team-models list
  assert_equal "${lines[0]}" "category                      model   from               effort  from"
  assert_equal "${lines[1]}" "default                       opus    default            high    default"
  assert_equal "${lines[6]}" "planner                       opus    default            high    default  subagent_model haiku from planner"
  assert_equal "${lines[22]}" "reviewer.rereview             sonnet  reviewer.rereview  high    default"
  assert_equal "${#lines[@]}" 29
  assert_equal "$(printf '%s\n' "${lines[@]:1}" | cut -d' ' -f1 | tr '\n' ' ')" \
    "default coordinator coordinator.compaction-drill assistant assistant.load-check planner planner.feature planner.research planner.interview planner.walk planner.retro planner.load-check builder builder.ticket builder.deliver builder.fix builder.round builder.merge-base builder.load-check reviewer reviewer.review reviewer.rereview reviewer.verify reviewer.load-check ops ops.load-check topic topic.load-check "
}

@test "list --json is the array of resolve's objects, for the project and path given" {
  local category
  models <<'TOML'
"default" = { model = "opus", effort = "high" }
"builder path=small" = { model = "sonnet" }
TOML
  run_bin -0 team-models list --json --project agent-team --path small
  local listed=$output
  assert_equal "$(jq length <<<"$listed")" 28
  while read -r category; do
    run_bin -0 team-models resolve --category "$category" --project agent-team --path small
    assert_equal "$(jq -c --arg c "$category" '.[] | select(.category == $c)' <<<"$listed")" "$(jq -c . <<<"$output")"
  done < <(jq -r '.[].category' <<<"$listed")
  assert_equal "$(jq -r '.[] | select(.category == "builder.ticket") | .model' <<<"$listed")" "sonnet"
}

@test "list of a missing file says so on stderr and shows every axis unset" {
  run_bin -0 --separate-stderr team-models list
  assert_equal "$stderr" "team-models: no models.toml at $TEAM_HOME/models.toml: every category on the user settings' model and effort"
  assert_equal "${lines[1]}" "default                       -      -     -       -"
}

@test "every brief template but the two resumes has a category in the table" {
  run -0 unmapped_templates "$REPO_ROOT/templates/briefs"
  assert_equal "$output" ""
}

@test "a brief template the table does not map is named" {
  local copy=$BATS_TEST_TMPDIR/briefs
  mkdir "$copy"
  cp "$REPO_ROOT"/templates/briefs/*.md "$copy/"
  touch "$copy/builder-nap.md"
  run -0 unmapped_templates "$copy"
  assert_equal "$output" "builder-nap"
}
