# {{task}} brief (reviewer): review {{title}}

Path: {{path}}; you are the reviewer.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`; review `origin/{{base}}...{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `spec.md`, `tickets/`, `build-notes/`.{{ui}}

## Instruction and settings files

{{instruction_files}}

## Tests and dependencies

{{dropped_tests}}

An assertion, test or check the change loosens counts as dropped too (a wider match or tolerance, a test marked to fail, retry or run less, a check turned off), every commit on the branch included, whoever made it: name each dropped test and each loosening in `review.md` with the reason the change gives for it; one with no reason is **blocking**.

## GitHub checks

{{> wait}}

## Check, beyond what every review covers

{{checks}}
{{> review-rules}}

## Deliver

- Local checks: {{local_checks}}.
  Run them on `{{head}}` with `{{team_bin}}/team-checks {{project}} {{head}}`, which runs them as `team-merge` does, in a fresh detached worktree of that head, and say in `{{task_dir}}/review.md` whether it passed; a failure is **blocking**, and they set no GitHub status.
{{> review}}

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
