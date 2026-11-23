# {{task}} brief (reviewer): verify the notes fixed on {{title}}

Path: {{path}}; you are the reviewer of a fix round whose findings were all plain notes on lines the PR adds or changes.
Project: {{project}} (`{{repo}}`), base `{{base}}`.
Worktree: `{{worktree}}`, branch `{{branch}}`.
PR: {{pr}} against `{{base}}`, reviewed at `{{reviewed}}`, now at head `{{head}}`.
Task directory: `{{task_dir}}/` in the worktree: `review.md` with the last review's findings.
Sent back: the notes numbered {{findings}} in `{{task_dir}}/review.md`, each a plain `note` whose scope is `change`.

## Instruction and settings files

{{instruction_files}}

## Tests and dependencies

{{dropped_tests}}

An assertion, test or check the change loosens counts as dropped too (a wider match or tolerance, a test marked to fail, retry or run less, a check turned off), every commit on the branch included, whoever made it: name each dropped test and each loosening in `review.md` with the reason the change gives for it; one with no reason is **blocking**, and one an earlier review of this task named needs no new word.

{{dependencies}}

Name each listed dependency in `review.md` with its version; one `spec.md` does not name is a plain `note` of scope `change`, which goes back: the builder removes it, or the PR records Daniel's decision to keep it.

## Check

1. Run the project's local checks ({{local_checks}}) on `{{head}}` with `{{team_bin}}/team-checks {{project}} {{head}}`, which runs them as `team-merge` does, in a fresh detached worktree of that head; every one must pass, and `{{task_dir}}/rereview.md` says which local checks passed (they set no GitHub status).
   Start no wait on the PR's GitHub checks: deliver on `{{head}}`, the head you read, since the coordinator's script waits on the checks of a pass, and the merge needs every one green.
{{> rereview}}
   Read nothing else: not the rest of the PR, the spec's or the story's acceptance list, or the knowledge graph; run the UI check only when that diff touches a UI file and your session lists `ui-check`, on the states it touched and their siblings.
   A round with no new commit (`{{reviewed}}` is `{{head}}`) edited only the PR body: read the body against the notes and step 3's sentence fixes.
3. Every note sent back ({{findings}}) is fixed at `{{head}}`, and the builder's commits in that diff hold nothing but those fixes, their tests and the claims check's sentence fixes.
   A sentence fix changes a sentence in the PR body or a Markdown doc (never a template, role prompt or skill, which a session runs on) that a finding of `{{task_dir}}/claims-check.md` names and its `## Answers` line marks `fixed` or `cut`, in this round's report, whose `head:` is `{{head}}` or a commit of `git rev-list {{reviewed}}..{{head}}`: the report is the builder's list of them and the claims check's own evidence.
   Read each against the code at `{{head}}`: one that does not say what the code does is a new finding on its line.
   When they change more than that, a code file above all, its comments, docstrings and header included, this brief does not fit: send `{{task}} BLOCKED not a notes-only fix: <what else changed>` to `coordinator`, and write nothing to GitHub.
   Raise a new finding only on a line this diff adds or changes, so each new one's scope is `change`.
{{> review-rules}}

## Deliver

- Add the result to `{{task_dir}}/review.md` under a heading naming `{{head}}`, its new findings numbered on from the last, each with its file and line, one kind, `blocking`, `note: correctness`, `note: security`, `note: real-data` or `note`, and its scope, `change`; then write the same result alone to `{{task_dir}}/rereview.md`.
  Before its counts, `{{task_dir}}/rereview.md` holds a `## Not verified` section: each behaviour this change touches that neither your reading, a test, CI nor a check proved (on a platform CI does not run, against a real outside service or real data, or a step only Daniel can take), each with what would prove it, or the line `none`; it is no finding and moves no count, and `team-review-comment` refuses to post a file without it.
  Give in it the count of each kind among the findings that stand at `{{head}}`, its new ones and any note sent back and not fixed, the plain notes as `note-change` and `note-before` (0 for none), and the guarded areas the change touches, of `ci`, `migrations`, `deploy`, `permissions`, `secrets` and `guardrails`, by the paths `{{team_code}}/bin/lib/guarded` lists for the project or by what the code does in a file of any name (CI or the checks a PR must pass, a migration of production data, the deploy, auth or permission checks, secrets handling and, on agent-team, the team's guards), or none.
  Post that as one PR comment with this exact command, the only comment your settings allow: `{{team_bin}}/team-review-comment {{pr}} {{task_dir}}/rereview.md`.
{{> review-status}}
- Send `{{task}} DONE pass {{pr}} findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:0 before=none guarded=<areas, comma-separated, or none>` or `{{task}} DONE findings {{task_dir}}/review.md findings=blocking:<n>,correctness:<n>,security:<n>,real-data:<n>,note-change:<n>,note-before:0 before=none guarded=<areas, comma-separated, or none>` to `coordinator`, the counts and areas as `{{task_dir}}/rereview.md` gives them.

## Rules

Read `{{team_code}}/sops/platform-gotchas.md` before your first command.
Never the em dash; refer to Daniel with they/them.
