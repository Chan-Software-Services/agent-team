# SOP: a session's rare events

A role prompt holds only what most of its sessions need, so what a session does on an event few of them meet is here, and its role says when to read it.
Each section names the roles it is for; the coordinator's own steps for these events are in its manual and skills.

## A send finds two coordinators

For every role and the assistant.

When a send to `coordinator` fails with "N agents are named 'coordinator'", send it again at once to `coordinator [<ref>]`, the row "on this machine" most recently active, never one on another machine, and say nothing else, since the coordinator's sweep raises the twin.

## On STOW

For the builder:

- On `T<n> STOW`, finish or abandon the current step (with a no-mistakes run active, wait for it first and say so in `handoff.md`), then commit what is unfinished as `wip: <what is unfinished>` on the task branch and push it, unless a Disclosure section holds your pushes: then push nothing, and the checkpoint keeps it on the team home's `wip/` until the review passes.
- Then write `.scratch/task/handoff.md` (done, next, anything odd) and reply `T<n> PAUSED stowed`.
- In a ticket worktree, commit and reply without pushing: the checkpoint keeps the ticket branch.
- Never rewrite a `wip:` commit later: carry on from it with new commits.
- A test or gate run killed or aborted while a `T<n> STOW` waits is never a failure to fix: note it in `handoff.md` and run it again on resume.

For the planner and the reviewer, who have nothing to commit:

- On `T<n> STOW`, write `.scratch/task/handoff.md` (done, next, anything odd) and reply `T<n> PAUSED stowed`.

For the assistant:

- On `ASSISTANT STOW`, write `assistant/handoff.md` in the team home, your stow note: each open topic with its thread id and what it waits on, each message of Daniel's not yet answered with its id, and each hand-off in flight.
- Then reply `ASSISTANT PAUSED stowed` to `coordinator` and start nothing new.

An ops session is never stowed: `team-stow` and `team-handoff` end it.

## On a resume

For the builder, the planner and the reviewer: read `.scratch/task/handoff.md` first when it exists, and delete it once the work it describes is done.
The assistant's digest prints its stow note, with the same rule.

## When GitHub is unreachable

For the builder, the planner and the reviewer:

- On a GitHub network failure (a push, `gh` or a fetch that cannot reach GitHub, or the hook's "the team is holding" block), send `T<n> PAUSED offline <what failed>` and wait, without retrying; that block is the hold, not a denial to report as BLOCKED.
- On `T<n> HOLD`, do what STOW does, without pushing, and reply `T<n> PAUSED held`.
- On `T<n> RESUME`, the builder pushes what was held and goes on; the planner and the reviewer go on where `handoff.md` says.

The assistant's hold is in the hook's block itself: keep talking with Daniel, and touch no GitHub.
