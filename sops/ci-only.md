# SOP: moving a project to CI-only

No session runs a whole test suite on the team's machine (Daniel's rule, 2026-11-15): the whole suite runs in CI.
A project with no CI is the one exception: its builder runs the whole suite once at its end, or its reviews and merges run its `local_checks`, until it moves to CI-only by the steps below.
Each step says who takes it, and each rule why it holds.

## When

- A project moves only on Daniel's word that its repository is public or goes public, quoted with its message id in the task's plan.
  Why: CI is free only for a public repository, and the move is Daniel's call on what they pay for.
- Never on the team's own reading of the repository's visibility, from `gh` or the registry's `visibility`.
  Why: the registry's `visibility` defaults to "public" as the cautious reading of what is published, never as a fact, and a repository can go private again on Daniel's call alone.
- Never for a private repository.
  Why: its CI minutes are metered, and a whole suite on every PR spends them unasked.
- Until the move, the project keeps its whole-suite run at the builder's end, or its `local_checks`.
  Why: the suite must run somewhere before a merge, and until the move nothing else runs it.

## The workflow

- A task on the project gives it a workflow that runs the whole suite on every PR to its base.
  Why: the registry can require only checks that run on every PR's head.
- It runs on Linux runners only, with no macOS or Windows job until Daniel says otherwise.
  Why: Daniel's standing call is no macOS CI, and other-OS runners are slower and cost more where minutes are metered.
- Each job has a time limit (`timeout-minutes`).
  Why: a hung job with no limit holds the merge until GitHub's six hours run out.
- It has a `workflow_dispatch` trigger when the project's builders are to run CI on their branch.
  Why: `team-ci-run` starts a run that way when CI has no run of the branch's head, as on a branch with no PR yet.
- For a fork, the same task cuts the upstream workflow's other-OS jobs, and its notes list each upstream workflow that would release, deploy or fail on the fork.
  Why: turning Actions on runs every workflow the fork carries, so Daniel's steps below must disable each one that would release, deploy or fail.
- The fork's workflow then differs from upstream's, and the task's notes say so.
  Why: an update from upstream may conflict on it.

## Daniel's steps at github.com

These steps are Daniel's, since only they can change the repository's settings, and the assistant walks them through each one and keeps them in the team home's `manual-steps.md` until they are done.
The coordinator first says when no merge to the project's base is in flight, since a push to the base starts every enabled workflow, and the ones the task listed run until they are disabled.

1. Open `https://github.com/<owner>/<repo>/actions`.
   On a fork with Actions off the page says workflows are not being run on this fork: press the green button "I understand my workflows, go ahead and enable them".
2. If the page shows no such button, open `https://github.com/<owner>/<repo>/settings/actions`, and under "Actions permissions" choose "Allow all actions and reusable workflows", then "Save".
3. Back on the Actions page, in the left list of workflows, for each workflow the task listed: click its name, open the "..." menu at the top right of the runs list, and choose "Disable workflow".
4. Tell the assistant it is done; the left list should show those workflows as disabled and the suite's workflow as active.

The button's and the menu's wording are GitHub's as the team knows them, not read from the live page, so the assistant follows what Daniel says the page shows.

## The proof

- The coordinator confirms Actions is on with `gh api repos/<owner>/<repo>/actions/permissions` (`enabled: true`) and each listed workflow's state with `gh api repos/<owner>/<repo>/actions/workflows`.
  Why: Daniel's steps are by hand, and a workflow left enabled releases or deploys on the next push.
- The coordinator sees every job that is to be required pass on one PR's head before any registry edit.
  Why: a required check that never reports holds every merge of the project.
- An open PR gets its first run on its next push.
  Why: turning Actions on starts no run for a head already pushed.

## The registry

One records edit by the coordinator, after the proof:

- `required_checks`: the proven jobs' check names.
  Why: `team-merge` then merges only with each of them passed on the PR's exact head.
- `changed_tests`: the project's small set, the tests a change reaches.
  Why: a builder brief of a project with `changed_tests` names only those tests, and one without tells the builder to run the whole suite.
- `local_checks`: cut to the commands that are no suite, such as a format or lint check.
  Why: `team-checks` runs them at every review and merge, so a suite left there still runs on the team's machine.
- `branch_ci`: the workflow's file name, where the project's delivery is `direct-pr` and the workflow has `workflow_dispatch`.
  Why: builders then run CI on their branch with `team-ci-run` instead of any suite on the machine.
- The entry's comment says CI is required since this move.
  Why: the next reader of the registry learns where the suite runs without reading the history.
- Then `team-project --check`.
  Why: it refuses a key the registry does not know or a `branch_ci` without `changed_tests` and `direct-pr`.

## After

- The project's builder briefs name only the changed code's tests.
  Why: `team-brief` renders the registry's `changed_tests` into them, so no builder runs the whole suite on the machine.
- Its reviews and merges run no suite, only its remaining `local_checks`.
  Why: `team-checks` runs exactly those commands, and the suite runs in CI on every PR's head.
- Its merge waits on the required checks.
  Why: the suite no one ran on the machine must pass before the PR merges.

## Moves so far

None yet.
