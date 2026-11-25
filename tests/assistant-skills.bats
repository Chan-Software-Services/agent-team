#!/usr/bin/env bats
# The assistant's skills plugin (plugins/assistant-skills): its manifest, its one skill, walk, as
# Claude Code is given them (frontmatter, steps in order, the commands each step runs, checked
# against bin/'s --help), the role sections it points at and restates none of, the commands its
# guard refuses and it never names, its prose rules, and team-load-check failing a worker that
# sees the plugin.
load helpers/common

setup() {
  sandbox
  plugin=$REPO_ROOT/plugins/assistant-skills
  skill=$plugin/skills/walk/SKILL.md
  role=$REPO_ROOT/roles/assistant.md
}

# The role's lines under its "## <heading>", up to the next heading, blank lines dropped.
role_section() {
  awk -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } on && NF' "$role"
}

# The skill's code spans, one per line, without their backticks.
code_spans() {
  grep -oE '`[^`]+`' "$skill" | tr -d '`'
}

@test "the manifest is named assistant-skills, takes ./skills/, and names bin/claude-assistant as its loader" {
  local manifest=$plugin/.claude-plugin/plugin.json
  assert_equal "$(jq -r .name "$manifest")" assistant-skills
  assert_equal "$(jq -r .version "$manifest")" 1.0.0
  assert_equal "$(jq -r .skills "$manifest")" ./skills/
  jq -r .description "$manifest" | grep -qF 'Loaded only by bin/claude-assistant.'
}

@test "skills/ holds walk alone, its frontmatter named walk with a trigger description and both invokers left on" {
  assert_equal "$(cd "$plugin/skills" && find . -mindepth 1 -maxdepth 1 -printf '%P\n' | sort | paste -sd ' ')" walk
  [[ -d $plugin/skills/walk ]]
  assert_equal "$(sed -n 1p "$skill")" ---
  assert_equal "$(sed -n 2p "$skill")" 'name: walk'
  local description
  description=$(sed -n '3s/^description: //p' "$skill")
  assert_contains "$description" /walk
  assert_contains "$description" "walk me through what's waiting"
  assert_equal "$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$skill")" 4
  if grep -nE '^(disable-model-invocation|user-invocable):' "$skill"; then
    echo "the skill turns an invoker off" >&2
    return 1
  fi
}

@test "its first sentence says the walk goes through what waits on Daniel, apart from a manual QC walk" {
  local first
  first=$(awk '/^# Walk$/ { on = 1; next } on && NF { print; exit }' "$skill")
  assert_contains "$first" 'Daniel through every item waiting on them'
  assert_contains "$first" 'no manual QC walk'
}

@test "its numbered bold steps are, in order, Sync, Collect, Order, Present, Route and Track" {
  local steps
  steps=$(grep -oE '^[0-9]+\. \*\*[A-Za-z ]+\.\*\*' "$skill" | sed -E 's/^[0-9]+\. \*\*(.*)\.\*\*$/\1/' | paste -sd ,)
  assert_equal "$steps" Sync,Collect,Order,Present,Route,Track
  assert_equal "$(grep -oE '^[0-9]+\.' "$skill" | paste -sd ' ')" '1. 2. 3. 4. 5. 6.'
}

@test "the steps hold the commands and fields the spec gives them, and the Order step's fallback" {
  local span spans missing=()
  spans=$(code_spans)
  for span in 'team-snapshot --json' 'team-state T<n> --json' 'team-current reconcile' 'team-current list' \
    'team-assistant thread --from' 'team-assistant send decision' '--daniel <their message id>' \
    "--channel <the walk's thread id>" 'team-assistant show H<n>' 'team-current add ask' 'team-current add owe' \
    '--until handoff H<n> answered' 'team-current done' 'team-assistant thread --close' 'ASSISTANT H<n> decision' \
    pending_asks pr.state pr.merge_approved unblocks fetch_messages; do
    grep -qF -- "$span" <<<"$spans" || missing+=("$span")
  done
  assert_equal "$(printf '%s\n' "${missing[@]}")" ""
  grep -qxF "   With no readable \`waiting.json\`, the coordinator's items go oldest first." "$skill"
  grep -qF "one hand-off per message of Daniel's: a message answering items of two tasks is one hand-off" "$skill"
  grep -qx '## Starting again' "$skill"
  grep -qF 'over Remote Control gets the answer to say it in `#assistant`' "$skill"
  grep -qF 'With no item, reply where Daniel wrote that nothing waits on them' "$skill"
}

@test "it points at roles/assistant.md's four sections and holds no line of them" {
  local heading line found=()
  grep -qF '`roles/assistant.md`' "$skill"
  for heading in "Daniel's words" Hand-offs "Your list" Discord; do
    grep -qF "\"$heading\"" "$skill" || found+=("names no \"$heading\"")
    [[ -n $(role_section "$heading") ]] || found+=("the role has no section \"$heading\"")
    while IFS= read -r line; do
      line=${line#- }
      grep -qF -- "$line" "$skill" && found+=("$heading: $line")
    done < <(role_section "$heading")
  done
  assert_equal "$(printf '%s\n' "${found[@]}")" ""
}

@test "every team-* command in a code span is a script in bin/ whose --help names each option the span gives it" {
  local span cmd option checked=0 problems=()
  while IFS= read -r span; do
    cmd=${span%% *}
    if [[ ! -x $REPO_ROOT/bin/$cmd ]]; then
      problems+=("$cmd is no script in bin/")
      continue
    fi
    run_bin -0 "$cmd" --help
    checked=$((checked + 1))
    while IFS= read -r option; do
      [[ -z $option ]] || grep -qF -- "$option" <<<"$output" ||
        problems+=("\`$span\`: $cmd --help names no $option")
    done < <(grep -oE -- '(^| )--[a-z]+(-[a-z]+)*' <<<"$span" | tr -d ' ')
  done < <(grep -oE '`team-[a-z]+(-[a-z]+)*( [^`]*)?`' "$skill" | tr -d '`')
  assert_equal "$(printf '%s\n' "${problems[@]}")" ""
  ((checked > 10))
}

@test "it names none of the commands the assistant's guard refuses, and team-inbox only as team-inbox --item <n>" {
  local refused inbox
  refused=$(grep -nE '(^|[^[:alnum:]_/-])team-(ask|answer|log|run-approved|merge|thread)([^[:alnum:]_-]|$)' "$skill" || true)
  assert_equal "$refused" ""
  inbox=$(grep -oE 'team-inbox.{0,12}' "$skill" | grep -vxF 'team-inbox --item <n>' || true)
  assert_equal "$inbox" ""
}

@test "it puts one sentence on each line, uses the plain dash and calls Daniel they" {
  # A sentence ends in ". " after a word and before a capital, outside code spans; the
  # description is one YAML value, so it may hold two.
  local joined
  joined=$(sed -E 's/`[^`]*`//g' "$skill" | grep -vE '^description: ' | grep -nE '[a-z)][.!?] +[A-Z]' || true)
  assert_equal "$joined" ""
  joined=$(grep -nEiw 'he|him|his|she|her|hers' "$skill" || true)
  assert_equal "$joined" ""
  joined=$(grep -n $'—' "$skill" "$plugin/.claude-plugin/plugin.json" || true)
  assert_equal "$joined" ""
}

@test "team-load-check's worker check fails a worker that sees assistant-skills" {
  # The forbidden pattern is the one grep -Ei line that fails a production or role-only plugin.
  grep -E "grep -Eiq '[^']*\bassistant-skills\b[^']*'" "$REPO_ROOT/bin/team-load-check"
}
