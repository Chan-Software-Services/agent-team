# spec-review

Two skills, each run by a session on its own work before someone else reads it: `spec-review`, for a planner whose spec and tickets are about to go to the coordinator for approval, and `claims-check`, for a builder about to send its branch as a PR.

`spec-review` first.
A planner writes `spec.md` and the tickets with everything it learned in its head, so the first readers without that context are the builders, and a choice the spec left open stops a builder at the most expensive place to settle it.
The skill has two fresh readers, who get only paths, read the spec and tickets before anyone builds: one as a stranger who says in its own words what the spec changes and how the system works today, one as the builder who checks each ticket against the code.
Their findings go to `spec-review.md` in the task directory, where the spec's author sorts each one as fixed, contested with a line a reader could have read, or escalated to the coordinator.

`claims-check` is for the sentences a branch adds about its own code: a doc, a comment, a script header, help text or the PR body that says something the code at the head does not do, or says more than it does.
The builder who wrote them reads its own intent into them, so the skill has one fresh reader, who gets only the code root, the branch's diff and the PR body, check each added or changed sentence against the code.
Its findings go to `claims-check.md` in the task directory, where the builder answers each one as fixed, cut, or kept with a line of the code that shows the sentence holds.

## When the coordinator gives it

Every delivering builder gets it with nothing given: `team-worker` adds the toolkit to each builder launch whose brief's template is `builder-deliver`, `builder-round` or `builder-fix`, on every project, and step 2 of both delivery templates (`templates/briefs/delivery/`) has that builder run `/claims-check`.
No project lists it in its `toolkits` line in the registry, and none needs to: a skills-only toolkit needs no line in a project's allow list, on any launch, since the list keeps MCP servers and production access per project and such a toolkit starts no MCP server and reaches no production.
Skills-only is read from the toolkit's own files at each launch (nothing but a plain manifest, a README, agents, skills and evals, with no hook or server declared in any of them), as `bin/team-worker`'s header defines it, so a toolkit that gains a server, a hook or a script comes back under the allow list on its own.
So the exemption also covers the launches a deliverer's toolkits are carried to, and a `--toolkit spec-review` given by hand.

For `spec-review`, only when the coordinator chooses to: T240's replay said `stop` (below), so no brief names that skill and no planner step runs it.
A session that wants it, a planner reviewing its own spec or a later replay, is launched with `team-worker T<n> <role> <worktree> --toolkit spec-review -- ...`, now with no registry line; a session that did not write the spec, as a replay's builder, gets only the readers' part, since the skill stops before the sort.
`team-worker` loads it from the code checkout `~/agent-team`, so a session can list it only once the PR that adds it is merged.
Before the first launch that loads a new or changed skill of it, the coordinator runs `team-load-check --toolkit spec-review` and `team-load-check --context --toolkit spec-review`.

## What loads

- The skill `skills/spec-review/SKILL.md`: its description in the session's starting context, its body only when the session invokes it as `/spec-review [<task dir>] [<code root>] [--model sonnet|opus]`.
  The task directory defaults to `.scratch/task` and the code root to the session's working directory, so a planner runs it with no arguments and a replay names an archived spec's copy and the project's tree at its base commit.
  It dispatches both readers in one message, retries a reader that fails once and records a second failure as `not run`, writes `spec-review.md` (the paraphrase verbatim, then a findings table and an `escalated:` last line), and, when the session wrote the spec, has it add the paraphrase's misreadings and sort every finding.
- The agent `agents/spec-paraphrase.md`, dispatched as `spec-review:spec-paraphrase`: it reads only `spec.md` and the tickets and returns "What this changes", "How the system works today, per this spec" and "Could not follow".
- The agent `agents/spec-readiness.md`, dispatched as `spec-review:spec-readiness`: it reads the code root's `CLAUDE.md` and `AGENTS.md`, `spec.md`, `scope.txt` and each ticket with the files it names, checks with Grep and Glob that each name the spec says exists does, and returns its findings (`open-decision`, `missing`, `contradiction` or `too-large`, each `blocking` or `note`, each on a line) and the files it read.
- The skill `skills/claims-check/SKILL.md`: its description in the session's starting context, its body only when the session invokes it as `/claims-check [<code root>] [<base>] [--pr-body <file>]`.
  The code root defaults to the session's working directory and the base to what `refs/remotes/origin/HEAD` names there; `--pr-body` names a file holding the PR body, or on a gated project the intent the gate drafts the body from.
  It checks its inputs, among them that `git status --porcelain` prints nothing, so the files the reader reads are the code at `HEAD`, writes the branch's diff against its merge base to `claims-check.diff` in the task directory (the directory that holds the `--pr-body` file when one is named, else `.scratch/task/` under the session's working directory), dispatches the one reader with those paths alone (none when the diff is empty and no PR body is named), and retries a reader that fails once.
  It writes `claims-check.md` beside it (the `reader:` line, the code root, the base with its merge base, the head, the PR body's path, then the reader's findings numbered and what it checked), has the session answer every finding under `## Answers` as `fixed`, `cut` or `kept:` with a path and line, and replies in one line.
  A check that could not run (an input that fails, a reader that failed twice) is written and reported as `not run: <why>`, never as a clean one, and the reader is not run again after the fixes.
- The agent `agents/claims-reader.md`, dispatched as `spec-review:claims-reader`: its prompt is a `Code root:`, a `Diff:` and, when the skill was given one, a `PR body:` line.
  It reads the diff and the PR body, then the code under the code root, and checks every sentence of the PR body and each sentence a `+` line adds or changes in a doc, a comment, a script's header, help, usage or error text, or a `description` field of a skill, agent or plugin.
  It returns "Findings" (one line per sentence the code does not bear out, with the path and line, the sentence, what the code does and `cut` or a narrowed sentence, or `none`) and "Checked" (each file with the count of sentences it checked there).
  It passes over style, wording and claims about anything outside the repository.
- All three agents have only Read, Grep and Glob, and `omitClaudeMd: true`, since the session's `CLAUDE.md` is the worktree's, which in a replay is not the archived project's: the readiness reader reads the code root's own instead, and the claims reader reads it only when a sentence makes a claim about it.
  All three are pinned to `model: opus`, since each one's reading is a judgment, so neither the calling session's model nor a `models.toml` line's `subagent_model` moves them off Opus.
  The `spec-review` skill may still give its two another with `--model`; T240's replay named no model for it, since neither passed.
  All three are told never to read the task directory beyond their inputs: no plan, brief, interview, memory, handoff, build note or other review, and for the claims reader no spec, ticket or earlier `claims-check.md` either.
  The readiness reader and the claims reader keep their searches out of the task directory when it lies under the code root.
- No MCP server, hook or script.

## What it costs

- Each skill's description, about 60 tokens, in the starting context of every session that lists the toolkit, and the three agents' descriptions, about 60 to 70 tokens each, in its Agent tool's list.
  Since `team-worker` adds the toolkit to every delivering builder, each of those sessions holds all five descriptions, as does a later launch its toolkits are carried to.
- Per claims check, one subagent's read of the branch's diff, the PR body and the code they speak of, each time a delivering builder runs its delivery's step 2.
  Not yet measured: the next retro reads it from each task's archived `claims-check.md` and the usage export.
- Per spec review, as T240's replay measured it (`tasks/T240/scratch/replay.md` in the team home once T240 closes) on six archived specs (five tasks whose builders asked 14 questions, 5 of them a spec could have settled, and a control whose builder asked none), each reviewed once per model:
  - Each spec, its tickets and its `scope.txt` were taken as the task's builders first read them, from the team home's history at the earliest checkpoint with no ticket box ticked, since the final archive's tickets carry the builders' ticks and notes and would show the readers the answers.
  - Opus readers (`high` effort): 1 of the 5 questions found (20%), $w 1.60 and 3.4 minutes per spec on average.
  - Sonnet readers (`medium`, Sonnet 5.5's default): 1 of the 5 found (20%), $w 0.20 and 0.5 minutes per spec.
  - Neither reached the third of the questions the go line asked for, so the replay said `stop`: no brief names the `spec-review` skill, and the replay chose no model for its readers.
    The sample is 5 questions, so one judgment moves the rate by 20 points: counting as hits one task's near misses, findings on where a setting is read from when the builder asked for the value it holds, would give both models 2 of 5 (40%) and `go sonnet`; the replay's file gives the reasoning for counting them as misses.
  - Neither model raised a `blocking` finding on the control spec.
    Opus's readiness reader raised seven `blocking` gaps that the builders settled alone or that reviews caught later, which the go line does not count; Sonnet's raised none of those.

## Credits

Its method is adapted from google/elephant-goldfish-model (https://github.com/google/elephant-goldfish-model, commit e9e1f06), Apache License 2.0.
That repository's `LICENSE` at `e9e1f06` is the stock Apache 2.0 text with its copyright placeholder unfilled, and its files carry no copyright line (read 2026-11-09), so the attribution names no holder.
No file or text of it is vendored or installed: the skill's and the agents' prompts are the team's own, and only the method (a reader with no context, a paraphrase read against the author's intent, findings the author sorts with evidence a reader could check) comes from it.

## Tests

`tests/toolkits/spec-review.test.mjs` checks the plugin's layout (its manifest, three agents, two skills, each the only skill of its name in any toolkit or the coordinator's plugin, and no `.mcp.json`, `hooks/` or `scripts/`), that the toolkit is skills-only by the launch rule's property, every agent's frontmatter (`tools` exactly Read, Grep and Glob, `omitClaudeMd: true`, `model: opus`), the task files they are told never to read and their return shapes, each skill's description under 250 characters and its file under 8 kB, that the `spec-review` skill's eight steps and the `claims-check` skill's seven come in order, this README's sections, its "When the coordinator gives it" and its attribution line, and each eval case's graders.
Its test "check a scaffolded branch's inputs and write the diff its eval case reads" takes each `git -C <code root> ...` command from the `claims-check` skill's text and runs it on the `name-a-false-header` scaffold's repository.
`tests/team-worker.bats` holds that `--toolkit spec-review` adds the plugin directory and no MCP server, that a delivering builder's launch gets the toolkit its project does not list, once, that a ticket builder's, a reviewer's and a launch with no brief record add none, that a toolkit launches unlisted only while it is skills-only, and that `--toolkit` refuses a name that is no plain directory name, so none reaches a directory outside `toolkits/`.
`tests/team-brief.bats` holds that step 2 of each delivery, in a `builder-deliver`, `builder-round` and `builder-fix` brief, ends with the `/claims-check` sentence of its project's delivery.
`evals/` holds six cases, each a `case.yaml` whose `scaffold.sh` writes its fixture into the run's empty workspace: `review-a-spec` plants an open choice and a function the code does not have in a small spec, and passes when the skill fires, both readers are dispatched and the reply has both faults as `blocking` findings of the right kinds; `review-a-code-diff` asks for a review of a shell diff and passes when neither skill fires.
`planner-notes-stay-out` puts a planner's `memory.md` and `plan.md` beside its spec in a git checkout's gitignored `.scratch/task/`, and passes when no reader's own message in the trace holds their paths or their text, since Glob lists gitignored files.
`replay-an-ignored-tree` reviews an archived spec against a project copied under that gitignored `.scratch/`, as T240's replay does, and passes when the readiness reader finds the function the copy has in a file no line names, and reports missing only the one it lacks.
`name-a-false-header` gives a branch whose script header documents a flag the code does not have, beside a README line and a PR body that hold, and passes when the skill fires, the reader is dispatched, a finding names the header's `--all` line and none names the README's line or a sentence of the PR body; `pass-prose-that-holds` gives a branch of the same shape with nothing false, and passes when the findings are `none`.
Those two start at the skill's step 3: the eval's sandbox gives its session no `git`, so each scaffold writes the branch's diff with the skill's own `git diff` command and the prompt has the session go on from the dispatch and reply with the `claims-check.md` it would write.
The test of the skill's git commands above covers steps 1 and 2 instead, and no test has a session follow steps 1 and 2, step 5's file write and step 6 end to end.
Run them from the code checkout with `claude plugin eval toolkits/spec-review --no-publish --scaffold --ablation none --trust-plugin`, and check the plugin with `claude plugin validate --strict toolkits/spec-review`.
Results go to `evals/results/`, which is gitignored.
