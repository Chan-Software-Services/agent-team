#!/usr/bin/env bats
# team-review-comment: the reviewer's only way to comment, a Markdown file from a task directory
# posted on a registered project's PR, so its allow rule posts no other file and on no other PR,
# and only one with a Not verified section.

load helpers/common

# A review file with a Not verified section that lists one thing: reviewed <file>.
reviewed() {
  printf '%s\n' '# Review' '' '## Not verified' '' '- the macOS run: a Mac run of the suite' '' 'findings=blocking:0' >"$1"
}

# What the refusal of <file> says.
no_section() {
  echo "team-review-comment: $1 has no Not verified section: before its counts, add a ## Not verified list of what this change touches that no reading, test, CI or check proved, or none; nothing was posted"
}

setup() {
  sandbox
  cat >"$TEAM_HOME/projects.toml" <<'TOML'
[proj]
repo = "Owner/Proj"
path = "projects/proj"
base = "dev"
delivery = "direct-pr"
merge_method = "merge"
required_checks = []
task_dir = ".scratch/task"
docs = []
toolkits = []

[proj.pool]
provider = "git"
slots = ["slots/proj/1"]
TOML
  wt=$BATS_TEST_TMPDIR/wt
  git init -q "$wt"
  mkdir -p "$wt/.scratch/task"
  reviewed "$wt/.scratch/task/review.md"
  stub_reply gh "https://github.com/Owner/Proj/pull/5#issuecomment-1"
}

@test "posts the task directory's file on the PR, in the registered repo's spelling" {
  run_bin -0 team-review-comment https://github.com/owner/proj/pull/5 "$wt/.scratch/task/review.md"
  assert_equal "$output" "https://github.com/Owner/Proj/pull/5#issuecomment-1"
  assert_equal "$(stub_calls gh)" \
    "$(jq -cn --arg file "$wt/.scratch/task/review.md" '["pr", "comment", "5", "--repo", "Owner/Proj", "--body-file", $file]')"
}

@test "a path relative to the worktree, as the briefs give it, works" {
  cd "$wt"
  run_bin -0 team-review-comment https://github.com/owner/proj/pull/5 .scratch/task/review.md
  assert_equal "$(stub_calls gh | jq -r '.[-1]')" "$wt/.scratch/task/review.md"
}

@test "a malformed command line is refused before any gh call" {
  local url=https://github.com/owner/proj/pull/5 file=$wt/.scratch/task/review.md
  run_bin -2 team-review-comment
  run_bin -2 team-review-comment "$url"
  run_bin -2 team-review-comment "$url" "$file" --repo someone/else
  run_bin -2 team-review-comment "$url" --body "x"
  assert_equal "$(stub_calls gh)" ""
}

@test "another PR, or a file from anywhere but a task directory, is refused" {
  local good=https://github.com/owner/proj/pull/5 file=$wt/.scratch/task/review.md
  echo "DISCORD_BOT_TOKEN=x" >"$wt/secret.md"
  ln -s "$HOME/.claude/channels/discord/.env" "$wt/.scratch/task/env.md"
  ln -s "$wt/secret.md" "$wt/.scratch/task/linked.md"
  reviewed "$wt/.scratch/task/notes.txt"
  : >"$wt/.scratch/task/empty.md"
  mkdir -p "$wt/.scratch/task/dir.md" "$BATS_TEST_TMPDIR/plain/.scratch/task"
  reviewed "$BATS_TEST_TMPDIR/plain/.scratch/task/review.md"
  local -a hostile=(
    "https://github.com/someone/else/pull/5|$file"
    "https://github.com/owner/proj/pull/5/merge|$file"
    "https://github.com/owner/proj/pull/5 --repo someone/else|$file"
    "$good|$HOME/.claude/channels/discord/.env"
    "$good|$wt/secret.md"
    "$good|$wt/.scratch/task/../../secret.md"
    "$good|$wt/.scratch/task/env.md"
    "$good|$wt/.scratch/task/linked.md"
    "$good|$wt/.scratch/task/notes.txt"
    "$good|$wt/.scratch/task/empty.md"
    "$good|$wt/.scratch/task/dir.md"
    "$good|$wt/.scratch/task/missing.md"
    "$good|$BATS_TEST_TMPDIR/plain/.scratch/task/review.md"
  )
  local case url path
  for case in "${hostile[@]}"; do
    IFS='|' read -r url path <<<"$case"
    run_bin team-review-comment "$url" "$path"
    [[ $status -ne 0 ]] || { echo "allowed: $case" >&2; return 1; }
    # Each is refused for what it is, before its text is read.
    [[ $output != *"Not verified"* ]] || { echo "refused for its section: $case" >&2; return 1; }
  done
  assert_equal "$(stub_calls gh)" ""
}

@test "a comment GitHub refuses is a failure" {
  stub_reply gh "" 1
  run_bin -1 team-review-comment https://github.com/owner/proj/pull/5 "$wt/.scratch/task/review.md"
  assert_contains "$output" "GitHub refused the comment"
}

@test "a Not verified section at ## or ###, with a list item or none, posts" {
  local url=https://github.com/owner/proj/pull/5 dir=$wt/.scratch/task
  local -a files=()
  # A first review's section, its item under a ### subsection of its own.
  printf '%s\n' '# Review' '## Not verified' '### Platforms' '* the macOS run' '## Counts' >"$dir/first.md"
  # A rereview's, under the heading naming its head, any case, trailing blanks, an ordered item.
  printf '%s\n' '## At abc1234' '### NOT VERIFIED  ' '1. the deploy: a production run' '#### Why' >"$dir/rereview.md"
  # The line none, any case, with a final period, the fence before it closed.
  printf '%s\n' '```' '## Not verified' '```' '## Not verified' '' 'None.' >"$dir/none.md"
  # One empty section does not refuse a later one that lists something.
  printf '%s\n' '## Not verified' '## Not verified' '+ real data' >"$dir/second.md"
  files=(first.md rereview.md none.md second.md)
  local file
  for file in "${files[@]}"; do
    run_bin -0 team-review-comment "$url" "$dir/$file"
    assert_equal "$(stub_calls gh | tail -n 1 | jq -r '.[-1]')" "$dir/$file"
  done
  assert_equal "$(stub_calls gh | wc -l)" 4
}

@test "a file with no Not verified section, an empty one or one only in a fence is refused, nothing posted" {
  local url=https://github.com/owner/proj/pull/5 dir=$wt/.scratch/task
  local -A cases=(
    [none.md]=$'# Review\n\n- the macOS run\nfindings=blocking:0'
    [empty.md]=$'# Review\n## Not verified\n## Counts\n- blocking: 0'
    [blank.md]=$'## Not verified\n\n   \n'
    [prose.md]=$'## Not verified\nThe macOS run was not made.\n-\n- \n*nothing*'
    [fenced.md]=$'# Review\n```\n## Not verified\n- the macOS run\n```'
    [fenced-item.md]=$'## Not verified\n~~~\n- the macOS run\nnone\n~~~'
    [level-one.md]=$'# Not verified\n- the macOS run'
    [level-four.md]=$'#### Not verified\n- the macOS run'
    [after.md]=$'### Not verified\n## Counts\n- the macOS run'
    [renamed.md]=$'## Not verified yet\n- the macOS run\n## Unverified\nnone'
    [indented.md]=$'  ## Not verified\n- the macOS run'
  )
  local file
  for file in "${!cases[@]}"; do
    printf '%s\n' "${cases[$file]}" >"$dir/$file"
    run_bin -1 team-review-comment "$url" "$dir/$file"
    assert_equal "$output" "$(no_section "$dir/$file")"
  done
  assert_equal "$(stub_calls gh)" ""
}

@test "the refusal names the file as given" {
  cd "$wt"
  echo "# Review" >.scratch/task/review.md
  run_bin -1 team-review-comment https://github.com/owner/proj/pull/5 .scratch/task/review.md
  assert_equal "$output" "$(no_section .scratch/task/review.md)"
  assert_equal "$(stub_calls gh)" ""
}

@test "--help documents the Not verified refusal" {
  run_bin -0 team-review-comment --help
  assert_contains "$output" "Not verified"
  assert_contains "$output" "## Not verified"
}
