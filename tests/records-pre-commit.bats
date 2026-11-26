#!/usr/bin/env bats
# hooks/records-git/pre-commit: with the team home's core.hooksPath set to it by absolute path, a
# records commit that adds an email address at a public provider or any image is refused, naming
# the path. tests/data-check.bats covers the scan itself.
# No address at a real provider is written out here (ci.yml's data job would refuse this file):
# each is built from $provider.

load helpers/common

setup() {
  sandbox
  make_team_home >/dev/null
  git -C "${TEAM_HOME:?}" config core.hooksPath "$REPO_ROOT/bin/hooks/records-git"
  provider=gmail.com
}

# Write <content> to the team home's <path>: record <path> <content>
record() {
  mkdir -p "$(dirname "$TEAM_HOME/$1")"
  printf '%s\n' "$2" >"$TEAM_HOME/$1"
}

# Commit in the team home with bats' run, stderr apart: commit <status> [git commit arguments...]
commit() {
  run "$1" --separate-stderr git -C "${TEAM_HOME:?}" commit -q -m "chore: records" "${@:2}"
}

@test "a records commit adding an address at a public provider is refused, naming the path, never the address" {
  local head
  head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  record tasks/T1/plan.md "Discord: reply to ann.applicant@$provider"
  record tasks/T1/brief.md "nothing private"
  git -C "${TEAM_HOME:?}" add tasks
  commit -1
  assert_equal "$stderr" "data-check: refused: tasks/T1/plan.md adds an email address at a public \
provider or an image, which the records never take: other people's addresses and screenshots stay \
out of git; take each out, then commit again:
  tasks/T1/plan.md: 1 email address at a public provider"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
  # Taken out, the commit goes ahead.
  record tasks/T1/plan.md "Discord: reply to the applicant"
  git -C "${TEAM_HOME:?}" add tasks
  commit -0
  assert_equal "$stderr" ""
}

@test "a commit of named paths only (commit_records' --only) is scanned through its own index" {
  record ledger.jsonl '{"kind": "note"}'
  record tasks/T1/notes.md "bo@$provider"
  git -C "${TEAM_HOME:?}" add tasks
  # The staged notes stay out of a commit of the ledger alone, as commit_records makes it.
  commit -0 --only -- ledger.jsonl
  record ledger.jsonl "{\"from\": \"cy@$provider\"}"
  commit -1 --only -- ledger.jsonl
  assert_contains "${stderr%%$'\n'*}" "refused: ledger.jsonl adds an email address at a public provider"
  [[ $stderr != *notes.md* ]]
}

@test "a commit made with literal pathspecs (commit_records' GIT_LITERAL_PATHSPECS) is scanned all the same" {
  record tasks/T1/notes.md "write to bo@$provider"
  git -C "${TEAM_HOME:?}" add tasks
  run -1 --separate-stderr env GIT_LITERAL_PATHSPECS=1 git -C "${TEAM_HOME:?}" commit -q -m "chore: records" --only -- tasks/T1/notes.md
  assert_contains "${stderr%%$'\n'*}" "refused: tasks/T1/notes.md adds an email address at a public provider"
}

@test "a minified bundle of one long line is scanned whole, as the checkpoint commits it" {
  # T76's shape: a vite bundle whose library header names its author's address mid-line.
  local line
  line="$(printf 'var a%d=1;' {1..20000})/*! @author ow <ow@$provider> */$(printf 'var b%d=2;' {1..20000})"
  record tasks/T1/scratch/baseline/dist/assets/index-Bgg7i7NB.js "$line"
  git -C "${TEAM_HOME:?}" add tasks
  run -1 --separate-stderr env GIT_LITERAL_PATHSPECS=1 git -C "${TEAM_HOME:?}" commit -q -m "chore: checkpoint" \
    --only -- tasks/T1/scratch/baseline/dist/assets/index-Bgg7i7NB.js
  assert_contains "${stderr%%$'\n'*}" "refused: tasks/T1/scratch/baseline/dist/assets/index-Bgg7i7NB.js adds an email address at a public provider"
}

@test "a screenshot is refused, and git's own address is not" {
  git -C "${TEAM_HOME:?}" config user.email "Daniel@$provider"
  record tasks/T1/notes.md "signed in as daniel@$provider"
  git -C "${TEAM_HOME:?}" add tasks
  commit -0
  mkdir -p "$TEAM_HOME/tasks/T1/scratch"
  printf '\x89PNG\r\n\x1a\n%s' "$RANDOM" >"$TEAM_HOME/tasks/T1/scratch/shot.png"
  git -C "${TEAM_HOME:?}" add tasks
  commit -1
  assert_contains "$stderr" "commit again:
  tasks/T1/scratch/shot.png: an image"
}

@test "a staged models.toml that does not read is refused with team-models --check's lines" {
  local head
  head=$(git -C "${TEAM_HOME:?}" rev-parse HEAD)
  record models.toml '"default" = { model = "gpt-5" }
"reviewr" = { model = "sonnet" }'
  git -C "${TEAM_HOME:?}" add models.toml
  commit -1
  assert_equal "$stderr" "pre-commit: refused: the staged models.toml does not read, so every worker launch from it would be refused; fix each line team-models --check names, then commit again:
  models.toml: \"default\": model: 'gpt-5' is not opus, sonnet, haiku, fable or claude-<name>, each optionally with [1m], or default
  models.toml: \"reviewr\": unknown category 'reviewr'; known: default, coordinator, coordinator.compaction-drill, assistant, assistant.load-check, planner, planner.feature, planner.research, planner.interview, planner.walk, planner.retro, planner.load-check, builder, builder.ticket, builder.deliver, builder.fix, builder.round, builder.merge-base, builder.load-check, reviewer, reviewer.review, reviewer.rereview, reviewer.verify, reviewer.load-check, ops, ops.load-check, topic, topic.load-check"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
  # The staged blob is what is read: a good file on disk does not let a broken one through.
  git -C "${TEAM_HOME:?}" add models.toml
  record models.toml '"default" = { model = "opus" }'
  commit -1
  assert_contains "${stderr%%$'\n'*}" "refused: the staged models.toml does not read"
  # A commit of named paths only (commit_records' --only, GIT_LITERAL_PATHSPECS) reads its own index.
  record models.toml '"default" = { model = "opus", effort = "huge" }'
  run -1 --separate-stderr env GIT_LITERAL_PATHSPECS=1 git -C "${TEAM_HOME:?}" commit -q -m "chore: records" --only -- models.toml
  assert_equal "$stderr" "pre-commit: refused: the staged models.toml does not read, so every worker launch from it would be refused; fix each line team-models --check names, then commit again:
  models.toml: \"default\": effort: 'huge' is not one of low, medium, high, xhigh, max, default"
  assert_equal "$(git -C "${TEAM_HOME:?}" rev-parse HEAD)" "$head"
}

@test "a staged models.toml that reads passes, its project= checked against the team home's own registry" {
  cp "$REPO_ROOT/tests/fixtures/models.toml" "$TEAM_HOME/models.toml"
  git -C "${TEAM_HOME:?}" add models.toml
  commit -0
  assert_equal "$stderr" ""
  cp "$REPO_ROOT/tests/fixtures/projects.toml" "$TEAM_HOME/projects.toml"
  git -C "${TEAM_HOME:?}" add projects.toml
  commit -0
  record models.toml '"default" = { model = "opus", effort = "high" }
"builder project=conventioner" = { model = "sonnet" }'
  git -C "${TEAM_HOME:?}" add models.toml
  commit -0
  assert_equal "$stderr" ""
  record models.toml '"default" = { model = "opus", effort = "high" }
"builder project=nowhere" = { model = "sonnet" }'
  git -C "${TEAM_HOME:?}" add models.toml
  commit -1
  assert_contains "$stderr" '
  models.toml: "builder project=nowhere": '
}

@test "an unstaged or deleted models.toml is never read, and a refused one still has its addresses named" {
  record tasks/T1/notes.md "nothing private"
  record models.toml 'not toml at all ='
  git -C "${TEAM_HOME:?}" add tasks
  commit -0
  assert_equal "$stderr" ""
  # A broken file committed before the hook (with git's plumbing, which runs no hook), then
  # deleted, is not read either.
  git -C "${TEAM_HOME:?}" add models.toml
  local before
  before=$(git -C "${TEAM_HOME:?}" commit-tree -p HEAD -m "chore: before the hook" "$(git -C "${TEAM_HOME:?}" write-tree)")
  git -C "${TEAM_HOME:?}" update-ref HEAD "$before"
  git -C "${TEAM_HOME:?}" rm -q models.toml
  commit -0
  assert_equal "$stderr" ""
  # Both checks run, so one commit names both problems.
  record models.toml '"defualt" = { model = "opus" }'
  record tasks/T1/notes.md "write to bo@$provider"
  git -C "${TEAM_HOME:?}" add models.toml tasks
  commit -1
  assert_contains "${stderr%%$'\n'*}" "refused: the staged models.toml does not read"
  assert_contains "$stderr" "data-check: refused: tasks/T1/notes.md adds an email address at a public provider"
}
