# SOP: the coordinator's manual

The coordinator's manual is `roles/coordinator.md`, which the coordinator's session starts with and carries in its context from then on.
Every line of it is paid for in every coordinator session, and a rule written there holds only while the coordinator remembers to follow it.
So a new rule goes to the cheapest place that holds it, and the manual is held to caps that only come down.
This SOP is for whoever adds a rule for the coordinator: a builder, a planner, or the retro when it proposes one.

## Where a rule goes, cheapest first

Take the first place that fits.

1. **A script.**
   A step that always follows another, or a check, belongs in the script that runs first.
   The script then does it every time, and no session spends context on it.
   The example: the manual once said to run `team-inbox` after `team-log`, and now `team-log` brings `waiting.md` up to date itself after an event that changes what waits on Daniel, so no one runs `team-inbox` after logging.
2. **A coordinator skill.**
   A procedure run on a cue (a handoff, a stow, a retro, a status report) belongs in a skill under `plugins/coordinator-skills/skills/`.
   The manual names the skill and its cue, and the steps load only when the cue comes.
3. **A brief template.**
   What one worker needs for one piece of work belongs in its brief template under `templates/briefs/`, which `team-brief` renders.
   The coordinator passes the brief on and need not know its content.
4. **The manual.**
   The manual keeps only what the coordinator judges: which skill or script a cue calls for, and how to talk to Daniel.

## The caps

The caps are named constants at the top of `tests/coordinator-manual.bats`: `manual_lines`, `manual_bytes` and the slack, `manual_slack`.
One check in that file, `manual_size_check`, holds the manual to them and says which bound failed, with both numbers.

- The manual's lines equal `manual_lines`.
  A PR that adds a line removes one, and a PR that removes a line lowers `manual_lines` with it.
- The manual's bytes are at most `manual_bytes`, and at least `manual_bytes` less `manual_slack`.
  So the byte cap comes down as the manual shrinks, and never keeps more than the slack as room to grow into.
- A PR that changes the manual keeps its line count, adds no bytes, and sets `manual_lines` and `manual_bytes` to the manual's size at its head.

## What holds a cap down

The lines must equal the cap, so a raised `manual_lines` passes only beside a longer manual.
A `manual_bytes` raised past the slack passes only beside a bigger manual.
Every change to `roles/coordinator.md` matches the `roles/.*` line of `bin/lib/guarded`, the short list.
So a PR that grows the manual never merges on the approved plan: it comes back to Daniel for the word on its head (`sops/merging.md`).
A raised cap always comes back to Daniel because the manual's size is a cost every coordinator session pays, and only they decide that a rule is worth it.
A PR that raises either constant names the constant, its old value and its new one in its body, so Daniel sees the rise when they are asked for the word.

## No task number

The manual holds no task number: a `T` followed by digits as a word.
A placeholder such as `T<n>` is not one.
A rule that names a task is a condition scoped to that task, and it goes stale in the manual once the task closes.
Such a condition belongs in the task's own plan or brief.
A test in `tests/coordinator-manual.bats` fails on one and names each line.
