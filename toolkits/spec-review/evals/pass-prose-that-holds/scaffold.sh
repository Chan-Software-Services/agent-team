#!/usr/bin/env bash
# The pass-prose-that-holds case's workspace: a git repository of a small made-up shell tool,
# notecat, with .scratch/ gitignored, one commit on main, and a branch feat/archive whose one
# commit adds `notecat archive`. Nothing is planted: the code bears out every sentence the branch
# adds, in bin/notecat's header, the comment on archive_notes, the README's line on archive and
# the usage text bin/notecat prints, and every sentence of the PR body in .scratch/task/pr-body.md.
# The branch's diff against main is written to .scratch/task/claims-check.diff, as the skill's
# step 2 would, since the run's sandbox has no git.
set -euo pipefail

mkdir -p bin lib .scratch/task

cat >.gitignore <<'EOF'
.scratch/
EOF

cat >README.md <<'EOF'
# notecat

A small shell tool for plain-text notes, each a `*.txt` file in the notes directory.

- `notecat list` prints each note's name, one per line.
- `notecat show <name>` prints one note's text.
EOF

cat >bin/notecat <<'EOF'
#!/usr/bin/env bash
# Usage: notecat list | notecat show <name>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/notecat.sh"

case ${1:-} in
  list) list_notes ;;
  show) show_note "${2:?usage: notecat show <name>}" ;;
  *) echo "usage: notecat list | notecat show <name>" >&2; exit 2 ;;
esac
EOF
chmod +x bin/notecat

cat >lib/notecat.sh <<'EOF'
# notecat's functions.

# The notes directory: $NOTECAT_DIR when set, else ~/notes.
notes_dir() {
  echo "${NOTECAT_DIR:-$HOME/notes}"
}

# Each note's name, one per line, in the order the directory gives them.
list_notes() {
  local note
  for note in "$(notes_dir)"/*.txt; do
    [[ -e $note ]] || continue
    basename "$note" .txt
  done
}

# One note's text.
show_note() {
  cat "$(notes_dir)/$1.txt"
}
EOF

git init -q -b main
git add -A
git -c user.name=eval -c user.email=eval@example.com commit -q -m "notecat"

git checkout -q -b feat/archive

cat >>README.md <<'EOF'
- `notecat archive` moves every note into `archive/` under the notes directory.
EOF

cat >bin/notecat <<'EOF'
#!/usr/bin/env bash
# Usage: notecat list | notecat show <name> | notecat archive
# archive moves every note into archive/ under the notes directory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/notecat.sh"

case ${1:-} in
  list) list_notes ;;
  show) show_note "${2:?usage: notecat show <name>}" ;;
  archive) archive_notes ;;
  *) echo "usage: notecat list | notecat show <name> | notecat archive" >&2; exit 2 ;;
esac
EOF

cat >>lib/notecat.sh <<'EOF'

# Moves every note into the archive directory under the notes directory.
archive_notes() {
  mkdir -p "$(notes_dir)/archive"
  local note
  for note in "$(notes_dir)"/*.txt; do
    [[ -e $note ]] || continue
    mv "$note" "$(notes_dir)/archive/"
  done
}
EOF

git add -A
git -c user.name=eval -c user.email=eval@example.com commit -q -m "feat: notecat archive"

cat >.scratch/task/pr-body.md <<'EOF'
Adds `notecat archive`, which moves every note into `archive/` under the notes directory.

- `archive_notes` in `lib/notecat.sh` does the move, and creates the archive directory when it is missing.
- `bin/notecat` runs it for `archive`, and its usage line names the new subcommand.
- The README has a line for it.
EOF

# The run's sandbox gives its session no git, so the skill's step 2 is done here.
git diff --no-color --no-ext-diff main...HEAD --output=.scratch/task/claims-check.diff
