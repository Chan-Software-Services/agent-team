# SOP: merging on Daniel's word

Built by T186 (2026-11-02), to Daniel's standing order of 2026-11-01, and rebuilt by T276 (2026-11-12) on the approved plan.
`team-merge --help` is the exact reference for what each word holds the PR to, and `team-log --help` for each event's fields; this SOP says what the words are, how they are given and withdrawn, and what the coordinator does under each.

## The two words

A PR merges only through `team-merge T<n>` (`--pr <url>` for each PR of a task in two repos), and only on one of two words, each a ledger event of the task.

| Word | Its event | Its fields | What it covers |
| - | - | - | - |
| Per head | `merge-approved` | `url`, `discord_message`, `head` | One PR at the head the coordinator asked on, and through a merge of the base whose `rereview` passed, a clean one (`team-catch-up`), or the two in turn |
| Default | `plan-approved`, withdrawn by `plan-approval-withdrawn` | `by` (`Daniel` or `coordinator`), Daniel's `ask` and `discord_message`, and `plan` and `scope`, which `team-log` records itself; the withdrawal's `discord_message` | The task's PRs, any head whose review passed, while the approval stands, the plan's files are unchanged and the default is not withdrawn for the task, its project or every project |

The per-head word is Daniel's word on one head; the default word is the task's approved plan, which needs no word at merge time.
`merge_authority` in `bin/lib/ledger.jq` derives both from the ledger, once, for `team-merge` and for every reader that says what `team-merge` would do: `team-next`, `team-state`, `team-sweep` and `team-inbox`.

## The order `team-merge` tries them

1. The per-head word, when a `merge-approved` names the PR's URL.
2. The default word, when none does, or when the per-head word does not hold for a reason of its own.

The first word that holds is the one merged on, and the `merged` event's `approval` says which: `head` or `default`.
A per-head word that holds never reads the default word, and one on an old head falls to the default word instead of hiding it.
A word that does not hold falls to the next only for its own reasons, never for the checks every merge gets: a red check refuses the merge whatever the word.

## What each word holds the PR to

Every merge, on either word, needs the checks every merge gets: the PR open, not a draft, not conflicting and on the project's base; every required check present and passed on the head, none failing or pending (a check no merge waits on aside, see "The checks no merge waits on"); `agent-review` success on the head, which on agent-team with the reviewer App on is the App's own check run (see "agent-team behind the reviewer App"); no agent attribution line in its commits; and the project's local checks passing on the head through `team-checks`.

GitHub holds one more thing once `bin/lib/worker-login` names the worker login and a base's protection restricts who can push to the owner alone (`sops/machine-setup.md`, "The worker login"): that restriction refuses a merge into the base by a session's login, the worker login, so a PR merges only through `team-merge`, which runs on the owner login whatever session runs it.

The per-head word needs Daniel's message read back from Discord, in the task's thread or `#coordinator`, from an author in `allowFrom`, sent no earlier than the head was first logged, and the PR's head the approval's head, or one that adds only merges of the base since it, either with a passing review logged after the word, or made by `team-catch-up` from a head whose latest review is a pass logged after the word (git showing it adds only clean merges of the base to that head), or each clean (a merge of the base whose tree is `git merge-tree`'s of its parents, as `team-catch-up` makes it) with no review logged after the word that found something.

The default word, the unattended one, needs:

- the task's plan approval standing: its latest `plan-approved` or `plan-approval-withdrawn` an approval (`plan_approval` in `bin/lib/ledger.jq`);
- the default not withdrawn for the task, its project or every project, and a giving back that decides it read back from Discord (see "Withdrawing and giving back the default word");
- the plan's files hashing as the approval recorded them (`plan_files` in `bin/lib/team.sh`), each one that differs, is new or is gone named: "the plan changed since its approval at <ts> (<files>): approve it again";
- for an approval of Daniel's, their message sent no earlier than the ask it answers, read back from Discord in the task's thread or `#coordinator`, from an author in `allowFrom`;
- the PR from the task's own branch for the project;
- the latest review of the head passed and logged `guarded` naming none of the six areas, where a head `team-catch-up` made (its `caught-up` event) and no review names stands on the review of the head it was made from, once git shows it adds only clean merges of the base to it;
- no review of the task counted a security or real-data finding, fixed or not, or left out its finding counts;
- GitHub's paged list of the PR's files read in full, every changed path within the approval's `scope` when it has one, and no changed path (or a rename's old path) on the short list for the PR's project.

A legacy approval, a `plan-approved` logged before T276 with no `plan`, has no hash to compare and no scope, and reads as the coordinator's whatever its `by` says.

For agent-team, the team's own project (`own_project` in `bin/lib/team.sh`: by name, by its path being the code checkout, or by its repo being the code checkout's origin), the default word needs more, as "agent-team behind the reviewer App" says; while the App is off it has one reason, "the team's own project merges unattended only behind the reviewer App's check, which is not set up", and `team-merge` reads nothing more for it, so its PRs merge on the per-head word alone.

## The checks no merge waits on

`bin/lib/advisory-checks` names the checks of the team's own project that block nothing: today `rust-macos`, the job of `.github/workflows/rust-macos.yml`, which runs the Rust check on macOS on every PR to `dev` and to `main` and by hand.

- No merge waits on one, red or pending: `team-merge`, `team-catch-up` and, through `team-merge --holds`, `team-land` leave it out of the checks they hold a head to, and `team-ci-wait` neither waits on it nor fails on it, on a head or on a trial commit.
  The workflow never runs on a merge queue's trial commit.
- A name the project's `required_checks`, the PR's server-required checks or the base's rules require is never left out of a merge's checks, and no other project's check of the name is.
  `team-ci-wait` counts the project's `required_checks`, and the base's rules only with `--merge-group`, so a wait on a head passes over a name only the rules require, which `team-merge` still holds.
- A red one is a finding fixed in the background: the coordinator opens a task of its own for it, and it never holds the PR that showed it, nor becomes a round of that PR's builder.
- The coordinator reads it in `team-next T<n> --ci`'s merge line, as `team-ci-wait`'s passing or pending end names it too; for one that line said was still running, the coordinator reads its end later with `gh run list --repo <owner>/<name> --workflow rust-macos.yml`, which lists the job's runs.
- Changing the list is a PR on this repository: the list is code, on the short list as a guardrail.

## Through the merge queue

On a base whose rules have a merge queue (`queue` in `base_rules` of `bin/lib/team.sh`), GitHub merges only what its queue built and checked, so `team-merge` lands the PR through the queue in place of `gh pr merge`.

- The words and the checks every merge gets are the same, with two more: the project's `merge_method` is `merge`, and the PR's queue entry can be read.
  A PR only behind its base needs no catch-up there: the queue merges it onto what is ahead of it, `team-next T<n> --ci` prints the merge line for it as for a PR up to date, and `team-catch-up` refuses it, naming `team-merge`; a PR that conflicts still takes the `builder-merge-base` round.
  A head that lacks a check the base newly requires is caught up there all the same, as "What the coordinator does" says, since `team-merge` queues no head lacking a required check.
  Its refusal says so: on a head behind its base, each missing required check ends with the step to run `team-catch-up T<n>`, unless a required `agent-review` is missing too, for which `team-catch-up` refuses the head.
- CodeQL on a trial commit: the code scanning roll-up `CodeQL`, which GitHub Advanced Security posts, appears only on a pull request, never on a trial commit, so a queued base where CodeQL runs requires its CodeQL workflow's own `Analyze (<language>)` checks in its place, which the workflow runs on `merge_group`, and holds a PR with a new alert out of the queue by its ruleset's `code_scanning` rule.
  That workflow is CodeQL's advanced setup, so the repository's default setup is off, since it runs nothing on a trial commit and refuses the workflow's uploads.
  agent-team runs no CodeQL, so its queue requires its CI's five checks and `agent-review` alone.
- The queue's settings, the same on every queued base and on the drill's scratch repository: the merge method `MERGE`, the grouping `ALLGREEN`, at most 2 entries built and 5 merged at once, a minimum of 1 with no wait, and a check timeout of 120 minutes.
  - `ALLGREEN`, since `team-land` proves and posts `agent-review` on each entry's own trial commit and waits on its checks, so every entry must pass on its own commit, where `HEADGREEN` would land one whose own commit failed.
  - 2 built, since the organization's GitHub Free plan runs 20 jobs at once across all its repositories and one Conventioner trial commit asks for 19, so a third trial built at once only waits for runners while each failure ahead of it rebuilds it.
  - 5 merged and a minimum of 1 with no wait, since the team merges in bursts while Daniel waits on fixes, so a lone green entry lands at once and several green ones land together.
  - 120 minutes, since the slowest successful CI run of the last 80 took 98 minutes on Conventioner and 66 on agent-team, and it stays under `team-land`'s 4-hour deadline, so `team-land` sees the drop, though a required check that never reports is taken out far sooner as a `rules` failure.
- `team-merge` logs `queued` (`url`, `head`, `project`) and runs `team-land --task T<n>`, which enqueues the PR at the reviewed head (GraphQL's `enqueuePullRequest` with `expectedHeadOid`, never `gh pr merge`, which would turn auto-merge on), posts `agent-review` on each trial commit the queue builds for it, and waits on that commit's checks with `team-ci-wait --merge-group`.
- The proof on a trial commit (`queue_commit_problems` in `bin/lib/team.sh`): `agent-review` is posted there only when the commit is the head commit of the PR's queue entry as GitHub answers at the call, the entry not `UNMERGEABLE`; it has exactly two parents, the second the PR's head and the first a commit holding the entry's base; its tree is `git merge-tree`'s clean merge of the two, made as GitHub makes it, with no merge driver the project's checkout or the user's git configuration registers (`host_merge` there), so a path a project merges with a driver of its own is merged as text; and the head's latest review passed, with, where the App posts, the App's own `agent-review` success on the head.
  So what the queue lands is the reviewed head merged cleanly onto what was ahead of it, which is what a clean `team-catch-up` claims on a base with no queue.
  A trial commit the poster refuses (its exit 1), the entry read again and still on it, has the PR taken out of the queue by `team-land`, which ends `dequeued`; what could not be read or posted now (exit 75) is tried again at each look.
- A trial commit `team-land` cannot mark is said, since it holds the PR and every PR behind it until the queue's check timeout.
  Each look that did not end in a post is one line of the PR's look log, `~/.local/state/agent-team/merge/land/<owner>/<name>/<n>.log`: the time, the trial commit, the step (`hold` or `post`), the exit and the reason line.
  As a run starts, it cuts the PR's log to its last 1000 lines and removes every look log untouched for 30 days.
  Once the same trial commit has stood unmarked with one reason for 10 minutes of looks, `team-land` takes one look at its other checks (`team-ci-wait --merge-group <trial> --look --no-agent-review`), says so once in the task's thread with `team-post`, and logs `trial-unmarked` (`url`, `head`, `trial`, `reason`, `since`, `checks`: `passed`, `pending`, `failed` or `unknown`); while they were logged pending or unknown it looks again at each unmarked look, with one read, and logs `trial-unmarked` once more, with no post, when they first show passed.
  Its next post on any trial commit logs `trial-marked`, which ends them.
- A merge that no longer holds leaves the queue, since a trial commit that carries `agent-review` lands whatever a later run says.
  Before each trial commit's `agent-review`, `team-land` has `team-merge T<n> --pr <url> --holds <head>` judge the word and the checks again, the local checks aside: a merge that does not hold (the default word withdrawn, a later review with findings, a per-head word that no longer reads back) takes the PR out of the queue with GraphQL's `dequeuePullRequest` and ends `dequeued` with the reasons, and one that cannot be told now (GitHub unread, the plan's files unread) posts nothing and is held again at each look.
  A conflict GitHub has not worked out (`mergeable` UNKNOWN) is no reason for a PR in the queue, since GitHub does not work it out again for a PR that stands in the queue when its base moves: the queue is the proof there, unless the entry is `UNMERGEABLE`, which is a merge that does not hold; a conflict GitHub did work out refuses wherever the PR stands.
  A `team-merge T<n>` that refuses a PR in the queue takes it out the same way and logs `dequeued`, unless every reason is one that cannot be told now: GitHub unread, the plan's files unread, the head not fetched for the local checks, or local checks that could not run (`team-checks` exit 75).
  Every other reason takes it out, a Discord message that does not read back among them, which fails closed at the cost of a second enqueue.
  When that run takes the PR out while another `team-merge` waits on it, the waiting run ends on the drop and logs no second `dequeued`, unless `team-land` names failures on the trial commit, which its own `dequeued` then carries.
  A withdrawal logged after a trial commit got its `agent-review` is not seen until the next trial commit or the next `team-merge T<n>`, so after withdrawing a word for a queued PR the coordinator runs `team-merge T<n>`, which takes it out.
- `team-land` is the landing alone and holds no word of its own, so the coordinator never runs it: `coordinator.settings.json` denies its Bash call of it, and `lease-fence` blocks it on a machine that lost the lease, as it blocks `team-merge`; `team-merge` and the drill start it themselves.
- The run ends when the queue does, so the coordinator runs `team-merge T<n>` with Bash `run_in_background` there.
  - Merged: `merged` is logged with the queue's merge commit, and the story, the posts and the code checkout's fast-forward follow as after any merge.
  - Dropped: `dequeued` is logged (`url`, `head`, `reason`, and `failed`, the failures `team-ci-wait` classed on the trial commit), and it exits 1 naming the next step: for a failure of the PR's own, the `builder-merge-base` brief and then a `rereview`, the coordinator sending the builder each failed check and its link, since the trial merge failed what the head passed, even beside a `rules` failure, since the queue cancels the rest of a trial commit it gives up, so a roll-up whose shards it cancelled reads as the rules' once no run is open, and a rules gap that is real shows alone on the round's new head; else for a `rules` failure, to run `team-doctor` (its `merge queue` line), fix the workflow's `merge_group` trigger or ask Daniel to change the repository's ruleset, then run `team-merge T<n>` again (for a check the project's `required_checks` alone require, to fix the workflow's trigger or those `required_checks` in the registry), since the trial merge cannot be judged until every required check runs there; else, when GitHub's reason is `checks_timed_out` (the queue's check timeout) or at least one failure is `infrastructure` of kind `queued` or `missing` and every other is one too or a roll-up, that the runners are behind: tell Daniel, who may raise the check timeout of the repository's merge queue while the backlog stands, and run `team-merge T<n>` again once they say the runners are back, ending as `team-next T<n> --ci`'s infrastructure end does, since a plain run again meets the same wait (the runner backlog, which `runner_backlog` in `bin/lib/ledger.jq` alone defines, its step `runner_step`); otherwise `team-merge T<n>` again once what dropped it is fixed.
    `team-ci-wait --merge-group` reads the base's rules once at its start and holds every check they require but `agent-review`, which `team-land` posts itself, beside the registry's `required_checks`; a read that fails is said on one line, which `team-land` prints under the wait's result, and it holds the registry's alone.
    A check it holds that no check of the trial commit lists once the reading has stood for the settle, 2 minutes of looks with no new check listed, is a failure of class `rules`, never the PR's own, also beside a check that failed, and its classes sort `pr`, `rules`, `infrastructure`, `rollup`.
    While a workflow run of the trial commit is still open (queued, waiting or in progress), such a check is `infrastructure` instead, since GitHub lists a job only once the jobs it needs have run: a roll-up such as Conventioner's `e2e`, whose shards wait for a runner, is listed nowhere until they run, and its run may yet make it.
    GitHub names no job it has not listed, so any open run of the trial commit counts: a check no workflow makes there reads as `infrastructure` too while another run is open, and is a `rules` failure only on a trial commit whose runs all completed.
    Each `rules` failure carries its `source`: `rules` when the base's rules require the check, else `required_checks`, the project's alone.
    A wait that ends with any `rules` failure, whatever else failed, has `team-land` take the PR out of the queue at once, rather than leave it to the check's timeout, and end it `dequeued` with the reason "<names> never reported on the trial commit, which <base>'s rules require" (or "which the project's required_checks require", a clause for each source), never enqueuing it again.
    A drop whose failures are all infrastructure is enqueued once more by `team-land` before it counts as dropped.
    A drop of any class leaves Daniel's per-head word and the default word standing on the same head, since `merge_authority` in `bin/lib/ledger.jq` reads no queue event: what the drop changes is the next step, never the word.
    The coordinator learns of a drop from `team-merge`'s exit and `team-sweep`'s finding, and tells Daniel of a `rules` one whose check the base's rules require, since its fix is their ruleset or a workflow, and of a runner backlog, since they may raise the queue's check timeout and say when the runners are back.
  - Still queued at `team-land`'s deadline of 4 hours, or with the team holding offline: it exits 75; run it again to go on waiting.
    Nothing more is logged while the PR, read again, is in the queue; one in no queue and not merged is logged `dequeued`, as it is after a `team-land` that refused or gave no result, so a `queued` never stands for a PR known to be in no queue.
- The lock and the resume: `team-merge` holds `~/.local/state/agent-team/merge/T<n>.lock` while it lands, taken after the local checks and let go once `merged` or `dequeued` is logged, and a second run meanwhile says "team-merge is already landing <url> (pid <n>)" and exits 0.
  Under the lock it reads the task's events again, so a `merged` another run logged meanwhile is not logged twice, and a `dequeued` another run logged meanwhile is followed by a new `queued` before the PR is enqueued.
  Run again on a PR already in the queue, it holds the word and the checks again, logs no second `queued` and goes on waiting; run on a PR GitHub shows merged at the head its standing `queued` names, which the queue landed while nothing waited, it logs the `merged`.
- The readers: `team-state` shows "in the merge queue since <ts>" with whether a `team-merge` waits on it; `team-sweep` raises no `merge-due` for a queued PR, `queue-wait` for one whose lock no process holds, to run `team-merge T<n>` again, and `trial-unmarked` for one whose latest `trial-unmarked` since its `queued` says the trial commit passed every other check, with no `trial-marked` since, to fix what its reason names; `team-inbox` leaves a queued PR out of the PRs ready to merge.
  A `queued` stands only for its head: once the task logs another head, by a `pr` event of the PR or by any review of the task, a push having dropped it from the queue, every reader takes it as in no queue.
  A `queued` whose PR is found merged at another head than it names is ended by a `dequeued` of the head the `queued` names at the next `team-merge T<n>`, which refuses the PR as merged.
  A PR dropped for a failure of its own on the trial merge, whatever else failed, until a `pr` event of it or a review of the task follows, is `team-sweep`'s `trial-failed`, never `merge-due`, is left out of `team-inbox`'s PRs ready to merge, and `team-next T<n> --ci` prints the `builder-merge-base` step for it in place of the merge line.
  A PR dropped for a `rules` failure and none of its own, until a `queued`, a `pr` event of it or a review of the task follows (`queue_state`'s `rules_due` in `bin/lib/ledger.jq`), is `team-sweep`'s `trial-rules`, to run `team-doctor`, tell Daniel and run `team-merge T<n>` once the rules or the workflow are fixed (for a check the project's `required_checks` alone require, once they or the workflow are), never `merge-due` or `trial-failed`, is left out of `team-inbox`'s PRs ready to merge, and `team-next T<n> --ci` prints `team-merge`'s rules step for it, its line starting `merge rules:`, in place of the merge line, and no merge-base or catch-up step.
  A PR dropped for a runner backlog, until a `queued`, a `pr` event of it or a review of the task follows (`queue_state`'s `runners_due`), keeps its `merge-due` while the default word holds, which then says the queue dropped it and names `team-merge`'s runners step (with `--pr <url>` in a task with more than one PR), and `team-next T<n> --ci` prints that step, its line starting `merge runners:`, in place of the merge line, a merge-base step coming first, and the merge line staying after a `team-catch-up` line, for the merge it makes.
- `team-doctor`'s `merge queue` line holds each queued base's rules to this, naming the first problem of each base: the queue's merge method not the registry's, the strict rule on, classic protection left beside the ruleset, the roll-up `CodeQL` required (from GitHub Advanced Security, integration 57789, or from no integration), which never posts on a trial commit, a required `Analyze (<language>)` check while the repository's CodeQL default setup is configured (read on the owner login only for such a base), and on agent-team `agent-review` not pinned to the App.
  Each fix is Daniel's step 6 below on the repository; a base's rules or a default setup that cannot be read fails it too, with the `github login` line's fix.
  It passes naming each queued project with its queue's settings, as "conventioner (dev on Chan-Software-Services/Conventioner: merge, build 2, merge 5, timeout 120 min)", the team's own adding the App's pin.
- `tests/merge-queue-drill` proves the path on a scratch repository (`sops/drills.md`, the merge queue drill), which is run before a base first gets a queue.

## The plan approval

- Daniel approves a plan through the plan ask, which lists `scope.txt` and says the approval is the merge word, and the coordinator logs their yes with `team-log T<n> plan-approved by=Daniel ask=<id> discord_message=<id>`.
- The coordinator approves a small plan itself with `team-log T<n> plan-approved by=coordinator`; on a product project that is the merge word, and on agent-team it starts the build alone.
- `team-log` records what was approved itself, never from the command line: `plan`, each of `tasks/T<n>/plan.md` in the team home, and `spec.md` and `scope.txt` in the task directory of the worktree of the task's first project, each that exists there, to its sha256; and `scope`, `scope.txt`'s non-blank lines, each a clean repository path, a directory ending in `/`.
- `team-log` refuses a `by` but the two, Daniel's approval with no `ask` or `discord_message`, an ask the task never logged or a message sent before it, the coordinator's with either, a closed task, no `plan.md`, a task whose first project's worktree is not a directory on this machine, since its `spec.md` and `scope.txt` could not be hashed, and a second approval whose `by` and `plan` equal the one standing.
- Once any of the files changes after the approval, the default word lapses, and `team-merge` names each file, until the plan is approved again, which on a product project the coordinator may do itself once it has read the change.
  A worktree that is not on this machine reads as a changed plan, so the merge runs on the machine that holds it.
- Daniel withdraws a task's plan approval with a message, logged `team-log T<n> plan-approval-withdrawn discord_message=<id>`, which `team-log` refuses when no approval stands: it stops the task's build, every hand-off of `team-next` and every builder or reviewer launch of `team-worker` refused naming it, and the default word with it, until Daniel approves the plan again, since `team-log` then refuses the coordinator's approval.
  It is a separate act from withdrawing the default word, which stops merges alone.

## The short list

- `bin/lib/guarded` holds what still comes back to Daniel for the per-head word when a PR would merge on the default word; `team-merge` reads it from its own checkout, so a PR cannot loosen its own check.
- Its six areas, in its order: `ci`, `migrations`, `deploy`, `permissions`, `secrets` and `guardrails` (`guarded_areas` in `bin/lib/ledger.jq`).
- A line's area may be followed by `@<project>`, the registry name of the one project it applies to (Conventioner's auth code is `permissions@conventioner`), or `@own`, the team's own project (every agent-team line is `guardrails@own`); a line with no `@` applies to every project.
- Each pattern is matched case-insensitively against the whole path, and again with its camelCase humps split off, each rename's old path too.
- Test configs, `scripts/`, dependencies, the agents' instruction files and names that merely hold an auth word are left off on purpose; the reviewer still names an area by what the code does, in a file of any name, and a review naming one of the six holds the PR back.
- A review logged before T276 that names the retired areas `dependencies` or `settings` holds nothing back.
- A project whose auth code moves to a file of another name has it added to the list by an agent-team PR.

## Withdrawing and giving back the default word

- Daniel withdraws the default word in one message, in `#coordinator` or a task's thread, for one task, one project or every project, and gives it back the same way.
- The coordinator logs the withdrawal, a `merge-default-withdrawn`, with `team-log T<n> merge-default-withdrawn scope=<task|project|all> discord_message=<id> discord_channel=<id>`, and the giving back, a `merge-default-restored`, with `team-log T<n> merge-default-restored scope=<task|project|all> discord_message=<id> discord_channel=<id>`.
- `scope=task` covers the PRs of the task it is logged under; a registered project's name, every task's PRs in that project; `all`, every project.
- `T<n>` is the task in whose thread Daniel said it, or, said in `#coordinator`, the task it came up in or any open task; `discord_channel` is where the message is.
- For a PR, the latest of the two kinds whose scope covers it decides, over the whole ledger, and the default stands unless that is a withdrawal.
  So a giving back of `all` gives back every task and project withdrawn by name before it, and a withdrawal of `all` withdraws every project, whatever was given back before; to give back all but one project, give back `all`, then withdraw that one.
- A withdrawal holds whatever message it names, since it only stops merges: `team-merge` never reads it back.
- A giving back holds only when Discord shows its message from an author in `allowFrom`, in `#coordinator` or the thread of the task it was logged under; while the latest event that covers a PR is a giving back that does not read back, the default word does not hold for it.
- `team-log` refuses a scope that is neither `task`, `all` nor a registered project, `task` on a closed task, a message or channel that is no Discord id, a channel that is neither `#coordinator`'s nor the task's latest thread, and a giving back when no PR it covers has a withdrawal as its latest covering event; a second withdrawal is logged, since it is harmless.
- `team-project --check` refuses a project named `task`, `all` or `own`.
- Nothing checks what Daniel's message says, so the coordinator logs only a message that withdraws or gives back the default word, and asks in one line when it leaves the scope unclear.

## What never merges on any word

- A release to `main`: it stays Daniel's own, outside `team-merge`.
- A merge by a session's own login, with the worker login on, into a base whose protection restricts pushes to the owner: GitHub refuses it, and only `team-merge`, on the owner login, merges.
- A PR with a required check missing or not passed, any check failing or pending (a check no merge waits on aside), or any other check every merge gets unmet.
- On the default word, a PR of agent-team, the team's own project, until the reviewer App is set up and `dev`'s protection pins its check, or on a plan the coordinator approved, or one approved before T276: it merges on the per-head word.
- On any word, a PR of agent-team with the reviewer App on whose head lacks the App's own `agent-review` check run passed.
- On the default word, a PR that touches the short list for its project, or whose reviewer named one of its six areas (CI, migrations, the deploy, permissions, secrets, or the team's own guardrails), or whose task ever counted a security or real-data finding, or that changes a path outside the approval's scope: these come back to Daniel for the per-head word.
- On the default word, a PR whose plan changed since its approval, until it is approved again.

## What the coordinator does

- On a reviewer's pass on a PR, `team-next` says to arm the checks wait, `team-next T<n> --ci` with Bash `run_in_background`; once the checks pass, that wait prints "merge on the default word: run team-merge T<n> for ..." when the default word holds on the ledger for the reviewed head, else the merge ask's facts, naming each of the six areas the review found and each review of the task that counted a security or real-data finding or logged no counts, with ", so the default word does not hold" while the plan stands approved on a project not the team's own, or on agent-team with the reviewer App on.
- A failure of the PR's own goes back to the builder from that wait as a fix round, and an infrastructure failure is rerun once (a check with no runner for 20 minutes never), then named in a `blocked:` line.
  A round that reruns the failed check green on the same head ends with the builder's `DONE`, after which the checks wait waits on that head again, so arm `team-next T<n> --ci` once more.
  After each `team-catch-up`, the first or a later one, the wait is on the merge that catch-up made.
- A check the base newly requires strands no reviewed PR behind its base: GitHub runs a check only on a commit pushed since the base required it, so a head lacks it until a merge of the base, and `team-merge` refuses a head lacking a required check on any base.
  `team-catch-up T<n>` makes that merge when the merge is clean, every check the head has passed and none is failing or pending (a check no merge waits on aside), on a base with a merge queue too, and names each required check the head lacked; only a missing `agent-review`, when the base or the project requires it, still refuses it, since no run of the merge makes that one.
  The checks wait then waits on the merge's checks, a red one going back as a round as any failure does, and `team-merge` refuses the merge while a required check is still missing on it.
  So once a repository requires a new check, the coordinator catches up each open, reviewed PR behind its base that `team-merge` refuses as missing it.
- With the review passed and every check green, it queues each plain `before` note as a follow-up, then:
  - when `team-next` says to merge on the default word, or `team-state T<n>` says `default word covers it`, runs `team-merge T<n>` with no ask and tells Daniel where each note went;
  - otherwise asks Daniel in the task's thread to merge, with the full PR URL and where each note went, and on their "merge it" logs `team-log T<n> merge-approved url=<PR url> discord_message=<id> head=<the full sha it asked on>` and runs `team-merge T<n>`.
- `team-state`'s line, shown while the task awaits merge with its plan approved, says `default word covers it`, `default word withdrawn` or `default word does not cover it: <the first reason>`; it adds GitHub's branch and files to the ledger's reasons, but reads neither the plan's files nor Daniel's message nor the checks, so it is the cue to try, never the merge's guarantee.
- `team-sweep`'s `merge-due` finding wakes the coordinator for a task awaiting merge with no ask open, no pause and no wait, the checks of its latest pass logged passed by the checks wait, no merge-base round in flight (a builder launch or `resumed` naming a merge-base brief, with no review since and a worker on it live), and a PR not merged whose default word holds on the ledger at the latest head the task logged; it reads no GitHub, so a short-list path no reviewer named, a changed plan or a message that does not read back is `team-merge`'s to find.
- Its `ci-due` finding names a pass whose checks no wait has ended, and none of them was rerun, for 100 minutes, to arm `team-next T<n> --ci` again unless it is running.
  A second `--ci` armed beside a running one says the wait is already running and ends, waiting on nothing (`team-next`'s per-task lock).
- On a merge on the default word, `team-merge` posts it in the task's thread and in `#coordinator`, with the approval it merged on, "on the plan you approved, <link>" or "on the plan the coordinator approved at <ts>", the merge commit and how to revert it; the coordinator posts with `team-post` the text of any post it says failed.
  A per-head merge posts nothing.
- On a refusal, `team-merge` names every reason it cannot merge, each once, and merges nothing.
  When the default word does not hold, it lists the per-head word's reasons when a `merge-approved` names the PR (or the task logged no plan approval either), then the default word's, then the checks every merge gets, and ends with the ask: "(Daniel's default word does not hold: ask them for the per-head word on the head <short head> with team-ask, naming <url>)"; the coordinator asks Daniel for the per-head word with `team-ask`, its text naming the PR's URL, or approves a changed plan again, as "The plan approval" says.
  On a word that holds, only the checks every merge gets are listed, with no ask line: the coordinator fixes what they name.
  A refusal for attribution lines is fixed first: `team-clean-messages <worktree>` strips them, its push, which the coordinator's settings deny it by hand, is the one line of a script it puts to Daniel with `team-ask --script` and runs on their yes with `team-run-approved`, and the new head is reviewed again.
  On a branch the gate's mirror holds, it prints a second step after the push, `team-clean-messages <worktree> --clear-gate-lane`, which runs with the same OK once the push has landed, since the gate's next run would otherwise refuse the old commits.
  That step and the mirrors under `~/.no-mistakes/repos` are the coordinator's: `settings/worker.json` denies every worker the flag and any Bash call naming that path, and `coordinator.settings.json` denies neither.
- After logging a merge word, a plan approval, or a withdrawal or giving back of either, `team-log` runs `team-inbox`, so the team home's `waiting.md` is current, and the list `team-inbox --post` posts with it: it shows each withdrawal of the default word that stands ("-# Default merge word withdrawn for <T<n>, project <name> or every project> since <link>") and leaves out of its PRs ready to merge a PR the default word covers on the ledger, whose refusal comes back as an ask.
  It also leaves out a PR whose per-head word stands on the ledger (`word_stands` in `bin/lib/ledger.jq`: the latest `merge-approved` naming its URL names a head the ledger logged for it, and no review logged since found something), so the word is not asked for again after a merge of the base whose re-review passed; that the new head adds only merges of the base stays `team-merge`'s to check, and `team-time` stops counting Daniel's wait on the same rule.
- `team-snapshot` gives at session start one line per withdrawal of the default word that stands: "Default merge word withdrawn for <T<n>, project <name> or every project> since <ts> (Discord message <id>, <task>)".
- While the reviewer App is off, no reader offers the default word for agent-team: `merge_authority` gives it the one reason above, so `team-next` prints the merge ask for its PRs, the sweep raises no `merge-due` for them, and `waiting.md` lists them.
  With the App on, the readers offer it on a plan Daniel approved, as for a product project, and `team-merge` alone reads the App's check and the pin.

## agent-team behind the reviewer App

T243 found that any session can write a passing `review` ledger event and post the `agent-review` commit status with Daniel's own token, so agent-team, whose PRs change the guards themselves, merges unattended only behind a check no session's token can post.

- The reviewer App is one GitHub App owned by `chanjdaniel`, with Checks read and write and Metadata read and no webhook, installed on the organization `Chan-Software-Services` for all its repositories.
- `bin/lib/review-app` names it, one `id=<n>` and one `slug=<s>` line, a committed constant read by `review_app` in `bin/lib/team.sh`, never a registry key, since the registry is a record any session can edit; with no such file the App is off, and agent-team merges on the per-head word alone.
- Its key is `~/.config/agent-team/review-app.pem`, mode 600, the `review-app-key` entry of the team home's `machine/secrets.json`, restored by `team-secrets`; the worker and coordinator settings deny it to the `Read` and `Edit` tools and deny a Bash command naming its path (`*agent-team/review-app*`, `*.config/agent-team/*.pem*`, and a `cd` or `pushd` into `~/.config/agent-team`), and the load check's refusal probe tries the `Read` tool, two `cat` spellings, a `cd` and a `pushd` on it.
- `team-review-check <pr url> <sha> <success|failure> <summary>`, the coordinator's alone (a worker session is refused), posts `agent-review` as the App's check run on a PR's head, only when the task's latest review of that head has the verdict it posts, pass for success and findings for failure, and, as `team-review-check --merge-group <pr url> <trial sha>`, a success on the merge queue's trial commit for the PR, only under the proof of "Through the merge queue", since the queue requires the pinned check again on the commit it lands; it signs a JWT with the key, mints an installation token for the one repository with `checks: write` alone, posts and revokes the token, handing the JWT and the token to `curl` only on stdin.
- `team-next` runs it on a reviewer's `DONE pass` or `DONE findings`, which it takes only with `--from` naming the session of the latest reviewer launch in the verdict's project (its PR's, else its sender's launch's), so the reviews of a task's PRs in two repositories run beside each other, after logging the review; a failed post exits 1 with the command to run again, the review staying logged.
  `team-catch-up` runs it on its clean merge of the base, in place of `team-review-status`, which refuses on agent-team while the App is on; `team-land` runs its `--merge-group` form on each trial commit; the reviewer sends its verdict only.
- `team-merge`, on every word, refuses an agent-team PR unless the App's latest `agent-review` check run on the exact head is `success`, and names a commit status or another App's check of that name as such ("agent-review on the head is a commit status by <creator>, not the reviewer App's check").
  On the default word it also needs a plan Daniel approved (the coordinator's approval and a legacy one are refused, naming Daniel's approval) and `dev`'s rules, its classic protection and its rulesets as `base_rules` in `bin/lib/team.sh` reads them, requiring `agent-review` from the App's id, with classic protection enforcing its required checks for everyone and no ruleset with a bypass actor, and the `merged` event logs the App's check run id as `check_run`.
- `team-doctor`'s `review app` line passes saying the App is off with no `bin/lib/review-app`, and otherwise fails, naming the first thing wrong, unless the key is in place with mode 600 and the base's rules of each project that is the team's own pin `agent-review` to the committed id, in its classic protection or a ruleset, with classic protection's `enforcement_level` `everyone` and no bypass actor on a ruleset.

What the App proves: that the coordinator's own scripts took a reviewer's verdict on that exact head, and GitHub then holds it, since a required check pinned to an App is met by no other source, administrators included.
The ledger still says what the review found (its `guarded` areas, its security and real-data counts), so `team-merge` needs both, and neither alone merges.
What it does not prove, each a speed bump against a steered session of the same OS user, behind the deny rules and the classifier alone:

- a session that reads the key can forge the check;
- a session that writes `~/agent-team/bin/` directly changes the scripts with no merge at all;
- a session that writes the ledger or the live checkout's `bin/lib/review-app` changes what `team-merge` reads on this machine, though GitHub's pin still refuses the merge, which is why `team-merge` checks the pin;
- a script run with `AGENT_TEAM_ROLE` cleared is not refused as a worker's;
- while the worker login is off, a merge by the raw API, around `team-merge`, skips its other rules (the approved plan, the short list, the findings rule), which GitHub does not hold.

A second App check, posted by `team-merge` itself just before it merges and required by the protection, would put those rules behind the key too; it is a small follow-up, not part of T276.

### Daniel's steps, in order

Until step 6, agent-team merges on the per-head word as before; no other project is touched.

1. After T276's second PR merges: create the App (github.com, Settings, Developer settings, GitHub Apps; no webhook; Checks read and write, Metadata read; installable on any account, since the organization installs it) and note its id.
2. Generate its private key and install the App on the organization `Chan-Software-Services`, for all its repositories.
3. Move the key to `~/.config/agent-team/review-app.pem` with mode 600, run `team-secrets save review-app-key` once the coordinator has added the manifest entry, delete the download, and restore it on the laptop.
4. Give the App's id in the task's thread; T276's third PR commits `bin/lib/review-app` and merges on the per-head word.
5. The coordinator posts the App's check with `team-review-check` on every open agent-team PR reviewed before.
6. Require `agent-review`, pinned to the App's id, on `dev`: in its ruleset's `required_status_checks`, as `{"context": "agent-review", "integration_id": <the App's id>}`, with the strict rule off (`strict_required_status_checks_policy` false), no bypass actor on the ruleset, and no classic protection left on `dev` beside it; the coordinator hands the `gh api` calls (the ruleset's `POST` or `PUT`, then the `DELETE` of the classic protection) with `team-ask --script`.
   The ruleset is also where `dev`'s merge queue is set, once the merge queue drill has passed, with the settings "Through the merge queue" gives and why: the merge method `MERGE`, the grouping `ALLGREEN`, at most 2 entries built and 5 merged at once, a minimum of 1 with no wait and a check timeout of 120 minutes.
   On a base where CodeQL runs, as Conventioner's, the repository's CodeQL default setup is turned off first, and the ruleset requires the CodeQL workflow's `Analyze (<language>)` checks from GitHub Actions in place of the roll-up `CodeQL`, with a `code_scanning` rule for the tool `CodeQL` holding the alert thresholds the base had (on Conventioner, security alerts `medium_or_higher` and alerts `errors`).
   The ruleset bodies and the calls T464 gave the drill's repository, Conventioner and agent-team are in the team home's `tasks/T464/` (`daniel-steps.md` and its ruleset files), which this SOP never copies.
7. The coordinator runs the drill once and records it: a commit status `agent-review` success posted with Daniel's token on a scratch PR leaves it blocked on GitHub, and `team-merge` refuses it.
8. `team-doctor`'s `review app` line passes on both machines.

## The retired words

- T276 retired the plan-time word (`merge-preapproved`, withdrawn by `merge-preapproval-withdrawn`, for a project that opted in with the registry's `merge_with_plan`) and the standing word (`merge-standing`, withdrawn by `merge-standing-withdrawn`, for one project or all), and the default word stands in their place.
- `team-log` refuses a new line of any of the four kinds, naming the default word and its withdrawal; the contract keeps them, so `--check` still passes the lines logged before.
- Those lines are history: `team-merge` reads none of them and no reader takes one for a merge word; a `merge-preapproved` still settles the ask of its id (`settles` in `bin/lib/ledger.jq`, read wherever an ask's state is), and `team-time` still reads the plan-time word's two kinds.
- `team-project --check` refuses `merge_with_plan` as retired, naming T276.
- A `merged` event's `approval` of `plan` or `standing` names one of them.
