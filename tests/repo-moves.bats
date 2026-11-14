#!/usr/bin/env bats
# The repositories that moved owner (bin/lib/repo-moves.json) across the ledger's readers: a PR
# logged under the old owner and under the new one is one PR, under the new, for team-state,
# merge_authority and team-inbox, with the ledger's own lines kept as written; and the rule of a
# table's chain of moves, on a table of the test's own in a copy of bin/.

load helpers/common
load helpers/inbox

old=https://github.com/chanjdaniel/Conventioner/pull/7
new=https://github.com/Chan-Software-Services/Conventioner/pull/7

setup() {
  sandbox
  inbox_discord
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[conv]
repo = "Chan-Software-Services/Conventioner"
path = "projects/conv"
base = "dev"
delivery = "no-mistakes"
merge_method = "merge"
required_checks = ["test"]
task_dir = ".scratch/task"
docs = []
toolkits = []

[conv.pool]
provider = "git"
slots = ["slots/conv/1"]
TOML
  stub_reply claude '[]'
  head=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
  # gh answers PR #7 only on the new owner's repo, open on dev at the head with its check green.
  export GH_HEAD=$head
  stub_script gh <<'EOF'
case "$*" in
  "pr view 7 --repo Chan-Software-Services/Conventioner "*)
    echo "{\"number\": 7, \"state\": \"OPEN\", \"baseRefName\": \"dev\", \"headRefOid\": \"$GH_HEAD\"}" ;;
  "pr checks 7 --repo Chan-Software-Services/Conventioner --required "*) echo '[]' ;;
  "pr checks 7 --repo Chan-Software-Services/Conventioner "*) echo '[{"name": "test", "bucket": "pass", "state": "SUCCESS"}]' ;;
  "api repos/Chan-Software-Services/Conventioner/compare/"*) echo 0 ;;
  *) echo "unplanned gh call: $*" >&2; exit 1 ;;
esac
EOF
}

# event <task> <kind> [<jq object of more fields>], at 02:00, as its writer logs it.
event() {
  jq -cn --arg t "$1" --arg e "$2" "{ts: \"2026-11-14T02:00:00Z\", task: \$t, event: \$e} + (${3:-{\}})" \
    >>"$TEAM_HOME/ledger.jsonl"
}

# Task <task> of conv, opened, with its thread and a builder's launch.
opened() {
  event "$1" opened '{project: "conv", path: "feature", type: "feat", title: "The move",
    branch: "feat/'"$1"'-move", base: "dev", base_sha: "0123456", worktree: "/w/1"}'
  event "$1" thread '{discord_thread: "1563"}'
  event "$1" launch '{role: "builder", session: "59709d99", worktree: "/w/1", toolkits: [],
    project: "conv", branch: "feat/'"$1"'-move"}'
}

# T14's PR #7 across the move: its pr, review and merge-approved under the old owner, then the
# builder's pr and the checks wait's ci under the new, all at one head.
across_the_move() {
  opened T14
  event T14 pr "{url: \"$old\", head: \"$head\", project: \"conv\"}"
  event T14 review "{head: \"$head\", verdict: \"pass\"}"
  event T14 merge-approved "{url: \"$old\", discord_message: \"1562661774950400000\", head: \"$head\"}"
  event T14 pr "{url: \"$new\", head: \"$head\", project: \"conv\"}"
  event T14 ci "{url: \"$new\", head: \"$head\", outcome: \"passed\"}"
}

# The sandbox ledger with every old-owner URL written under the new owner, as if logged so.
all_new_owner() {
  sed -i "s#https://github.com/chanjdaniel/Conventioner/#https://github.com/Chan-Software-Services/Conventioner/#g" \
    "$TEAM_HOME/ledger.jsonl"
}

@test "team-state reads a PR logged under both owners as one PR under the new, with the merge authority it has under one owner" {
  across_the_move
  cp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  run_bin -0 team-state T14 --json
  local mixed=$output
  assert_equal "$(jq -c '.pr | [.url, .repo, .number, .ledger_head]' <<<"$mixed")" \
    "[\"$new\",\"Chan-Software-Services/Conventioner\",7,\"$head\"]"
  assert_equal "$(jq -c '[.pr.merge_authority.words[] | select(.word == "head") | .holds]' <<<"$mixed")" '[true]'
  # Read by team-state, the ledger keeps its old lines as written.
  cmp "$TEAM_HOME/ledger.jsonl" "$BATS_TEST_TMPDIR/ledger.before"
  # The same ledger logged under the new owner alone reads the same in every field.
  all_new_owner
  run_bin -0 team-state T14 --json
  assert_equal "$(jq -S 'del(.now)' <<<"$mixed")" "$(jq -S 'del(.now)' <<<"$output")"
}

@test "team-inbox lists a PR logged under both owners once, under the new, and an ask naming the old URL is settled by the new one's word" {
  # T14: ready to merge, its pr logged under both owners.
  opened T14
  event T14 pr "{url: \"$old\", head: \"$head\", project: \"conv\"}"
  event T14 review "{head: \"$head\", verdict: \"pass\"}"
  event T14 pr "{url: \"$new\", head: \"$head\", project: \"conv\"}"
  # T15: Daniel's word, logged under the new owner, on a PR logged under the old.
  opened T15
  event T15 pr "{url: \"${old%7}8\", head: \"$head\", project: \"conv\"}"
  event T15 review "{head: \"$head\", verdict: \"pass\"}"
  event T15 merge-approved "{url: \"${new%7}8\", discord_message: \"1562661774950400001\", head: \"$head\"}"
  # T16: an ask naming the old URL, answered by a merge-approved of the new.
  opened T16
  event T16 asked "{id: \"merge\", text: \"Merge ${old%7}9 at ${head:0:7}?\"}"
  event T16 merge-approved "{url: \"${new%7}9\", discord_message: \"1562661774950400002\"}"
  run_bin -0 team-inbox
  assert_equal "$output" "wrote waiting.md: 1 item"
  assert_equal "$(jq -r '.items[] | "\(.n) \(.key)"' "$TEAM_HOME/waiting.json")" "1 pr $new"
  assert_equal "$(grep -c 'pull/7' "$TEAM_HOME/waiting.md")" 1
  [[ $(<"$TEAM_HOME/waiting.md") != *chanjdaniel* ]]
  local mixed
  mixed=$(<"$TEAM_HOME/waiting.md")
  all_new_owner
  run_bin -0 team-inbox
  assert_equal "$(<"$TEAM_HOME/waiting.md")" "$mixed"
}

@test "canonical_repo, canonical_url and canonical_text follow a chain of moves, compare from in any case, and leave anything else alone" {
  copy_bin "$BATS_TEST_TMPDIR/bin"
  rm -f "$BATS_TEST_TMPDIR/bin/lib/repo-moves.json"
  echo '{"moves": [{"from": "a/x", "to": "B/x", "on": "2026-11-14"}, {"from": "b/X", "to": "C/x.y", "on": "2026-11-15"}]}' \
    >"$BATS_TEST_TMPDIR/bin/lib/repo-moves.json"
  run jq -nc -L "$BATS_TEST_TMPDIR/bin/lib" 'include "ledger";
    (["A/X", "b/x", "C/x.y", "d/x", null] | map(canonical_repo)),
    (["https://github.com/a/x/pull/1", "https://github.com/A/x.git", "https://github.com/a/x",
      "https://github.com/a/xy/pull/1", "http://github.com/a/x/pull/1", "a/x", 7] | map(canonical_url)),
    ("PRs https://github.com/A/X/pull/1, https://github.com/b/x. https://github.com/a/x.git"
      + " but not https://github.com/a/xy or https://github.com/a/x.gitz" | canonical_text)'
  assert_equal "$status" 0
  assert_equal "$output" '["C/x.y","C/x.y","C/x.y","d/x",null]
["https://github.com/C/x.y/pull/1","https://github.com/C/x.y.git","https://github.com/C/x.y","https://github.com/a/xy/pull/1","http://github.com/a/x/pull/1","a/x",7]
"PRs https://github.com/C/x.y/pull/1, https://github.com/C/x.y. https://github.com/C/x.y.git but not https://github.com/a/xy or https://github.com/a/x.gitz"'
}

@test "registered_pr takes either owner's URL and prints the repo under the new owner, the registry under either" {
  local url repo
  for repo in Chan-Software-Services/Conventioner chanjdaniel/Conventioner; do
    sed -i "s#^repo = .*#repo = \"$repo\"#" "$TEAM_HOME/projects.toml"
    for url in "$old" "$new" "https://github.com/CHANJDANIEL/conventioner/pull/7"; do
      run bash -c 'source "$1/bin/lib/team.sh" && registered_pr "$2"' _ "$REPO_ROOT" "$url"
      assert_equal "$status" 0
      assert_equal "$output" "conv
Chan-Software-Services/Conventioner
7"
    done
  done
  run bash -c 'source "$1/bin/lib/team.sh" && canonical_url "$2"' _ "$REPO_ROOT" "$old"
  assert_equal "$output" "$new"
}

@test "own_project reads the code checkout as the team's own while its origin and the registry name a moved repo under different owners" {
  code_checkout
  own() {
    run bash -c 'source "$1/bin/lib/team.sh" && own_project conv' _ "$CODE_CHECKOUT"
  }
  # <origin> <registry's repo>, each direction and each URL form, then the same owner.
  local -a cases=(
    "https://github.com/chanjdaniel/Conventioner.git Chan-Software-Services/Conventioner"
    "git@github.com:chanjdaniel/conventioner Chan-Software-Services/Conventioner"
    "https://github.com/Chan-Software-Services/Conventioner.git chanjdaniel/Conventioner"
    "git@github.com:Chan-Software-Services/Conventioner.git/ CHANJDANIEL/Conventioner"
    "https://github.com/chanjdaniel/Conventioner.git chanjdaniel/Conventioner"
  )
  local line origin repo
  for line in "${cases[@]}"; do
    read -r origin repo <<<"$line"
    git -C "$CODE_CHECKOUT" remote set-url origin "$origin"
    sed -i "s#^repo = .*#repo = \"$repo\"#" "$TEAM_HOME/projects.toml"
    own
    assert_equal "$status" 0
  done
  # A repo no move joins to the origin's is not the team's own.
  git -C "$CODE_CHECKOUT" remote set-url origin https://github.com/chanjdaniel/agent-team.git
  own
  assert_equal "$status" 1
  git -C "$CODE_CHECKOUT" remote set-url origin https://github.com/chanjdaniel/Conventioner-x.git
  own
  assert_equal "$status" 1
}
