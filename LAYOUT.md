# Where things live

"Layout" has one line for each directory of the code repository and for each file in it that needs saying, and "The team home" one row for each path `bin/lib/records` lists.
A new path that no line here covers gets its line in its PR, and `bin/lib/code` or `bin/lib/records` lists it.

## Layout

One path per bullet and one thing per line, alphabetical within each list, so two PRs that add different things edit different lines.

- `assistant.settings.json`: the assistant's own settings, which `claude-assistant` fills in: its Discord state directory, its memory, its hooks and its denials.
- `bin/`: the team's commands, `team-*`, `claude-assistant` and `claude-coordinator`.
  - `bin/hooks/`: the sessions' hooks.
    - `git/`: git's hooks for the code checkout.
    - `records-git/`: git's hooks for the team home.
  - `bin/lib/`: the shared library.
    - `capacity.jq`: `team-capacity`'s settings of `capacity.json`, the worktrees held, a reading of the machine's load and the team's use per task, the cost samples and estimates, the reservations and the admission rule, the stow and resume plans, and their texts.
    - `channel-access.sh`: the bot's permissions in one Discord channel, worked out as Discord does from its roles and the channel's overwrites, and the doctor line reported from them, for the doctor's interview and assistant channel lines.
    - `chrome.sh`: the one lookup of a machine's Chrome, its executable and its app, which `team-doctor`'s `chrome` line and `team-tickets --graph` both take.
    - `code`: the paths every tracked path matches.
    - `command_rules.py`: `bin/hooks/command-guard`'s rule table, a row per guarded thing a call runs (an ops launch, the capture script, role and login variables, an emptied environment, a lease steal, the coordinator's commands, an upload, a force push, a cd to the keys), on each command walked.
    - `command_text.py`: a Bash command's code text (heredoc bodies out unless a shell may read one, `-c` strings and what is piped into a shell in) and the walk of each simple command it runs, past wrappers, into tools' strings, for `command_rules.py`; `team-tokens` takes its heredoc rule.
    - `compact-hold.sh`: the record of the coordinator's held auto-compaction, one file per session, written under its lock, and its log of each hold, tell, reminder, stow and release, for `bin/hooks/compact-hold` and `team-stowed`.
    - `confine-roots`: the roots every confined session has beside its own, one path per line: the team's machine state `~/.local/state/agent-team`, `~/.cargo` and `~/.cache/sccache`; a guarded path, and none may be in the team home, `~/.config/agent-team` or `~/.claude`.
    - `confine-session`: writes a confined session's directory, `~/.config/agent-team/confine/<task>/<stem>/`, at its launch: `session.json`, its roots, and the program `bash`, its shell and shell prefix, and records its job tmp once it has an id.
    - `confine-shell`: what a session's program `bash` runs, as its shell (`-c ...`, Claude Code's `CLAUDE_CODE_SHELL`) and as its prefix (one line, `CLAUDE_CODE_SHELL_PREFIX`): both hand the session's file to `confine.py`, so no shell runs before the domain.
    - `confine.py`: the kernel layer, which enters a Landlock domain and runs its command there, so a remove or a rename of a directory entry succeeds only under its roots (`--root`, and those of `--session <file>`, read from that file alone), and runs it unconfined, saying so, with no Landlock.
    - `data-check`: the one scan the CI's `data` job and the records' hook refuse with.
    - `delete_rules.py`: `command_rules.py`'s delete rows, refusing a recursive delete (`rm -r`, `find -delete`, `find -exec rm`) outside the worktree and the job's tmp, of either, its `.scratch/task` or what holds one, of a `.git`, an empty variable or no `find` start path, or of an unread path.
    - `doctor.d/`: `team-doctor`'s checks, one file each, which it sources in the order of their names (a new check is a new file, its number between its neighbours').
    - `drills.jq`: the drills module, the one place that says what a line of the team home's `drills.jsonl` is, when a drill is due and how `team-drill status` shows it.
    - `drills.json`: the drill registry, each drill's name, what it is, who runs it (`coordinator`, or `daniel` when it needs them present) and the code it proves, with the one age past which a drill is due.
    - `error-view.sh`: a sibling script's failure as the `{error}` a view holds in its place, its last stderr line with `~` for the home directory, for `team-queue`, `team-snapshot` and `team-sweep`.
    - `fence_rules.py`: `bin/hooks/lease-fence`'s reader, the classes of command the fence holds (a `git push`, `gh`, the team scripts that post, answer, wait or write) among those a Bash call runs, by `command_text.py`'s walk, never where a call only names one.
    - `gate-claude-settings.json`: the settings the gate's Claude takes with `--settings`, its commit attribution off and `command-guard` run on Bash from `~/agent-team`, since it loads no user settings.
    - `gate-config.awk`: reads and sets the one key the team writes in Daniel's no-mistakes config (`agent_path_override`'s opencode), and reads `agent_args_override`'s list for one agent.
    - `github-api.sh`: the one reader of GitHub's REST answers for the scripts that poll it, a cache every process shares, revalidated with ETags, the budget each answer reports, a rate-limit refusal held until it lifts, and a log of each request by the command that sent it.
    - `github-login.sh`: where the worker and owner logins live, sourced by `team.sh`: the worker login's constant read, its gh directory judged, a session's environment on it, gh or any command (`bounded` too) run on either login, and the team home's GitHub credential helpers on the owner login.
    - `guarded`: the short list, one extended regular expression per line with its area, `@<project>` or `@own` for one project's line, any changed path of which brings a merge on the default word, the approved plan, back to Daniel for the per-head word, read by `team-merge` from its own checkout.
    - `health.jq`: the health module, the one place that says what unhealthy means: the fold of each heartbeat run into the health record, the ledger's one-pass scan, every health threshold, and the view `team-timers health` prints, its problems and its line in markup and plain text.
    - `kill_rules.py`: `command_rules.py`'s kill rows, refusing a kill by name or pattern, tmux's `kill-*` off its `-S` socket, a kill of PIDs read from input, of a PID it cannot read, of a process group, every process or PID 0 or 1, or of a literal PID not proven its own, each with its allowed way.
    - `launch.sh`: the launchers' shared parts, which `claude-coordinator` and `claude-assistant` take: the launch lock, the check that no session of the name is live, the writer of the session's settings and MCP config, and the step that turns the user's personal skills off.
    - `ledger-contract.json` and `ledger.jq`: the ledger contract and its jq.
    - `lifecycle.json`: the task lifecycle's table, its statuses, phases, start states, what each kind may follow and does, the park causes and what ends each, and the `lifecycle_from` and `asked_parks_from` cutovers, which `ledger.jq` imports.
    - `messages.jq`: reads a worker's message into the events the coordinator's message table gives it, for `team-log --from-message`.
    - `notice.jq`: the notice module, the one lifecycle of every notice of a standing problem the heartbeat posts in `#coordinator`: the notice record `notices.json`, the table of each source's rules, the judging, its outcomes and the move from the old records.
    - `notices.sh`: the notice record's reads and locked writes, and the move of each old record into it, sourced after `team.sh` by `team-timers` and `team-uptime`.
    - `opencode-gate`: the gate's opencode wrapper, which `team-bootstrap` installs in `~/.no-mistakes/bin` and Daniel's no-mistakes config names on an opencode gate, and which loads `opencode-guard.js`.
    - `opencode-guard.js`: the opencode plugin that runs `command-guard` before each bash call of an opencode gate's agents, refusing the call on any exit but 0.
    - `outbound.py`: whether a Bash command's `curl` or `wget` sends a request body or a file to a literal host outside the team's own local ones, directly or through a proxy, decided on each command of `command_text.py`'s walk, for `command_rules.py`'s upload row.
    - `prices.json`: each model's list prices per million tokens with the date read and the source, the weights `team-tokens` gives each reply.
    - `probe.json`: the refusal probe's data: each attempt `team-load-check --probe` has a worker role or the assistant make and the layer that should refuse it, every deny rule of theirs in a family, their PreToolUse hooks, each with an attempt or why none, and its GitHub calls as the worker login.
    - `queue.jq`: the queue module, the one place that says an item's state, when its `after:` is met, how items rank, the room for one more task, the problems `team-queue index --check` names, the index's and the list's text, the sweep's findings and what `set`, `take` and `tidy` write.
    - `quota.sh`: the one Bash reader of `team-quota status --json`, its timeout and its reasons, which `team-capacity status` and the heartbeat's quota step take, and `team-tokens` keeps in Python.
    - `reading.sh`: one reading of the machine's load (its memory, its processes by directory and descent, the team's stacks), which `team-capacity sample` takes.
    - `records`: the team home's paths, which no tracked path matches.
    - `records-rewrite/`: `team-records-rewrite`'s drop list, message expression, S02 callback and `verify.py`.
    - `repo-moves.json`: the repositories that moved owner, each old `owner/name` to its new one with the date, a constant `ledger.jq` imports, so a PR URL under either owner is one PR to the ledger's event readers, and `team-project` reads for `--find repo` and `--check`.
    - `review-app`: the reviewer App's id and slug, one `id=<n>` and one `slug=<s>` line, a committed constant; with no such file the App is off and agent-team merges on the per-head word alone.
    - `review_facts.py`: the facts of a diff a review brief lists for its reviewer, the tests it drops and the direct dependencies it adds or changes, which `team-brief` derives as `dropped_tests` and `dependencies`.
    - `session-activity`: how long each live session's transcripts have gone unwritten, and the tool calls still running in a quiet one, for `team-sweep`'s stalled finding.
    - `stack.jq`: `team-stack`'s owner classes, Docker's sizes, the reaper's rules and the `stack.json` settings, with the keys no longer read since the level's budget admits a stack.
    - `stow.sh`: `team-stow`'s steps, which `team-handoff` takes through `team-stow`: each task's branches checked and pushed, its `stowing` logged, its sessions stopped, its ops session ended, its `stowed` logged, or its `stow-failed` when a later step refuses it or the run stops.
    - `threads.sh`: the archive of the team's Discord threads, sourced by `team-thread`, `team-close`, `team-assistant` and `lease-fence`: the 1-day idle time, the rule (archived only once a current `waiting.json` names nothing of it and its last message is a day old) and its one-thread pass.
    - `ticket_graph.py`: draws a task's ticket list, as `team-tickets --json` prints it, as the self-contained HTML page of its dependency graph that `team-tickets --html` writes.
    - `time.jq`: `team-time`'s split of each task's time into phases, and its counts.
    - `tmp-leftovers`: the names of what the team's test runs leave in `/tmp` and `/var/tmp`, one `<maker> <expression>` per line, the only names `team-janitor tmp` removes by, read from its own checkout.
    - `tmp.sh`: `team-janitor tmp`'s sweep of the stale leftovers in `/tmp` and `/var/tmp` and its warning: the rules (type, owner, a list, task or gate name, age, no live process), the removal, each removal's line and day file, the reading of `/tmp`, `status` and the `tmp` notice.
    - `tools.jq`: turns `tools.lock` into each tool's pin and install command for a machine.
    - `tools.lock`: the tools `team-doctor` checks, pinned or with a minimum, and their source per OS (for treehouse and no-mistakes, a GitHub release with each archive's checksum, or a fork's commit; for MongoDB's Database Tools, the publisher's archive with its checksum).
    - `uptime.jq`: `team-uptime`'s rules, the counting of each production check, when one is down, its outages judged as notices through `notice.jq`, each post's text, and the status line.
    - `vendor/git-filter-repo/`: git filter-repo 2.47.0, vendored with its MIT license.
    - `worker-login`: the worker login's GitHub account, one `login=<name>` line, a committed constant; with no such file the worker login is off and every session runs on the machine's own GitHub login.
    - `workers.jq`: `team-time`'s worker lifetimes, from each launch to its done, pr or ticket-done, review, replacement, stow or close, with their averages by role, path, project, model and toolkits, the longest, the running, and the classes and breakdown of their time rows.
    - `working-set.awk`: a cgroup's working set, its `memory.current` less the reclaimable page cache, the one measure of memory use `team-capacity`, `team-heavy` and `team-level` read a cgroup by.
- `CLAUDE.md`: the rules every session of this repository starts with, which `tests/repo.bats` holds to a byte cap.
- `coordinator.settings.json`: the coordinator's own settings: Discord, its hooks, its denials and the skills kept out of its listing.
- `LAYOUT.md`: this file, where the layout's lines and the team home's table live, which `CLAUDE.md` points to.
- `LICENSE`: the Apache License 2.0; vendored bats-core and git filter-repo keep their own.
- `plugins/coordinator-skills/`: skills loaded only into the coordinator by `bin/claude-coordinator`.
- `README.md`, `SETUP.md`: what a stranger reads first, with the sentence Daniel types on a new machine, and the agent's entry point for "set up as host".
- `roles/`: the role prompts each session's system prompt is appended with, one per role, the coordinator's and the assistant's included; `team-worker` follows a planner's, builder's or reviewer's with its project's root `CLAUDE.md` and `AGENTS.md` as `origin/<base>` has them.
- `rust-toolchain.toml`: the Rust toolchain every checkout builds with, its channel, profile and components, which rustup reads below the root and `team-doctor`'s `tool rust-toolchain` line checks.
- `servers/`: the MCP servers the toolkits and sessions run, the MCP client `ui-capture` speaks with, the `chrome-devtools-axi` client the browser toolkit's test runs, and the packages the effect toolkit's tests check its skill, hook and Foldkit DevTools server against.
  - `install`: puts them in the gitignored `servers/node_modules/`, as `team-bootstrap` does while `team-doctor`'s `servers` line fails.
  - `package.json` and `package-lock.json`: the packages and their pins, among them:
    - `@effect/platform-browser`: the Effect browser platform `foldkit` takes as a peer, for the effect toolkit's fixture Foldkit app.
    - `@effect/tsgo`: Effect's language service on TypeScript 7, whose `effect-tsgo` the effect toolkit's test runs its post-edit hook and the `effect-v4` skill's check against.
    - `@foldkit/devtools-mcp`: Foldkit's DevTools MCP server, the version released with the `foldkit` that the Foldkit app the team builds pins, which the effect toolkit's wrapper starts confined to the session's worktree.
    - `@foldkit/vite-plugin`: the Vite plugin whose relay `@foldkit/devtools-mcp` reaches, for the fixture app's dev servers.
    - `chrome-devtools-axi`: the client the browser toolkit's test runs, since CI's runner has no global install; sessions run the one `tools.lock` pins, at the same version.
    - `chrome-devtools-mcp`: the sessions' MCP server, which their settings name by `CHROME_DEVTOOLS_AXI_MCP_PATH`.
    - `effect`: the Effect version whose exports the effect toolkit's test holds the `effect-v4` skill's trap table to.
    - `foldkit`: the Foldkit version that app pins, the framework of the effect toolkit's fixture app.
    - `mongodb`: the driver the prod-mongo server counts and checks its dumps with, at the version the pinned MongoDB MCP server installs.
    - `typescript`: TypeScript 7, which `effect-tsgo diagnostics` needs installed beside it, though `@effect/tsgo` declares no peer.
    - `vite`: the Vite version that app pins, which runs the fixture app's dev servers.
  - `prod-mongo/`: the prod-mongo toolkit's server body: its start and tools, the backups root's rules, `childEnv` and `scrubbed`, a dump's counts, the throwaway MongoDB a drill or a rehearsal restores a dump into, the snapshots that say what changed, by ids, and the undo it prepares for Daniel.
- `settings/`: worker settings: `worker.json` shared, one file per role layered on it; with the user settings, all a planner, builder or reviewer loads (`--setting-sources user`), none of its worktree's `.claude/`.
- `sops/`: standing procedures.
  - `ci-only.md`: moving a project's whole test suite off the team's machine into required CI checks, only when its repository goes public on Daniel's word: the workflow's task, Daniel's steps at github.com, the proof and the registry edit.
  - `coordinator-manual.md`: what goes in a script, a coordinator skill, a brief template and the coordinator's manual, cheapest first, the manual's line and byte caps and what holds them down, and its no-task-number rule.
  - `docker.md`: the team's Docker stacks: labels, owner classes, the wrapper contract, `team-stack`'s subcommands, instances, admission, the idle sweep, the reaper, `team-janitor`'s daily report, the heartbeat's steps, the close teardown and the agents' rules.
  - `drills.md`: the drills, live runs of the paths the team's portability and guards rest on: the record in `drills.jsonl`, who runs one, and each drill's runbook, its steps, who takes each, its duration, what passes and how it is recorded.
  - `frontend-patterns.md`: rules that hold beyond one project for a UI's dev-only component library, combobox, large list, dialog, realistic fixture and bundle growth, each with its why.
  - `knowledge-graph.md`: a project's knowledge graph.
  - `machine-setup.md`: a new machine, driven by `SETUP.md`.
  - `merging.md`: merging on the per-head word and the default word, the approved plan: their events, the order `team-merge` tries them, what each holds a PR to, the plan approval, the short list, the withdrawals, what never merges, the coordinator's steps and the retired words.
  - `model-trials.md`: trialling a cheaper model on one role of one project, or a setup change that claims to save tokens: the registry's `models`, the effort check, the paired reviews, a toolkit's arm, the measures and their sources, the baseline by PR size and the note to Daniel.
  - `platform-gotchas.md`: general rules about the tools the team runs on, which every brief but the ops one points at in the code checkout, never the team home; the retro proposes keeping it short, and each change Daniel approves lands through a PR on this repository.
  - `portability.md`: moving the team between machines.
  - `records-rewrite.md`: the cutover that rewrites the records repository's history with `team-records-rewrite`, each step Daniel's or the coordinator's.
  - `resources.md`: the team's resources: its systemd user slice and each task's, `team-capacity install`, the placement of worker sessions and the gate in it, the checked assumptions, the readings per task, the learned costs, heavy runs' scopes, and the doctor's `resources` line.
  - `tmp.md`: the team's temporary files: `team-janitor tmp`'s roots, rules and list and how a line is added, the session tmp and task-named scratch, what a run says and where, the warning, the heartbeat's step, the doctor's `tmp` line and the test seams.
- `templates/`: the task plan and the worker briefs `team-open` and `team-brief` render.
  - `briefs/planner-walk.md`: a planner following Daniel's manual QC walk in its interview thread, capturing the page they drive.
- `tests/`: the bats suite, one `.bats` file per script (a long one split by topic, as `team-doctor-*.bats`).
  - `tests/bootstrap-drill`: runs `team-bootstrap` on a fresh runner for the by-hand Bootstrap workflow, and ends with the record line `team-drill import` reads from the job's log.
  - `tests/bootstrap-drill.bats`: runs `tests/bootstrap-drill` on a stub `team-bootstrap`.
  - `tests/bound-kills`: names each process search in the tests whose pids a kill may reach and that is not bound by both its owner and the test's own temporary directory.
  - `tests/compaction-drill`: run by hand by the coordinator, since it starts a real Claude session; it compacts a coordinator-shaped session in a sandbox team home built from `tests/fixtures/compaction-drill/`, checks it still knows each task's wait and every current item, and records its run.
  - `tests/compaction-drill.bats`: dry-runs `tests/compaction-drill` on a stub `claude`.
  - `tests/drill.bats`: the two-machine drill (handoff, steal, crash, outage, and the records rewrite's cutover on one machine).
  - `tests/fixtures/guard-corpus/allowed.jsonl`: the calls every guard hook must allow, one JSON object a line with the roles that make it, in the shapes of real ones with fixture values only.
  - `tests/guard-corpus.bats`: runs each role's PreToolUse hooks, as its settings files write them, on that corpus's calls, with the lease held and, for a call marked `local`, on a fenced machine and while the team holds offline.
  - `tests/guard-paths`: rewrites each unguarded path variable a test hands git or `rm -r` to `${var:?}`, and with `--check` names each one left.
  - `tests/helpers/`: the helpers, among them:
    - `confine-seams.py`: runs `bin/lib/confine.py`, which has no test seam, on another ABI or a domain that cannot be entered.
    - `discord-threads.bash`: the fake Discord of the thread archive's tests, its threads, the bot's user, their archiving and the team home's `waiting.json`.
    - `docker.bash`: the opt-in stub `docker`.
    - `shell_source.py`: the lexer of the tests' shell source that `tests/guard-paths` and `tests/bound-kills` share.
  - `tests/merge-queue-drill`: run by hand by the coordinator, since it merges real PRs; it lands two PRs at once through a scratch repository's merge queue with `team-land` in a sandbox team home, checks each trial commit, and records its run.
  - `tests/merge-queue-drill.bats`: dry-runs `tests/merge-queue-drill` on a stub `gh`, a stub `team-land` and a bare repository.
  - `tests/README.md`: the reference for writing a test, a test helper or a CI job: how `tests/run` runs, CI's jobs, the toolkit tests and the sandbox's seams, which `CLAUDE.md` points to.
  - `tests/shards`: splits the bats files into `tests/run bats --shard`'s shards by their seconds in `tests/timings.tsv`, and `tests/shards update` rewrites their Linux seconds from a CI run's shard jobs, keeping their macOS ones.
  - `tests/task-life.bats`: a whole task's life across the scripts.
  - `tests/timings.tsv`: each bats file's seconds on Linux in one CI run, and on macOS as the last CI run with macOS jobs had them, which `tests/shards` weighs it by.
  - `tests/toolkits/`: the toolkits' Node tests.
  - `tests/vendor/`: bats-core, vendored, with the one line its `VENDOR.md` patches.
- `toolkits/`: plugin directories a worker loads with `team-worker --toolkit <name>`: MCP config (`.mcp.json`) and the roles a server starts for when not every one (`mcp-roles.json`), skills, hooks (`hooks/hooks.json`), docs, scripts, and the skills' evals (`claude plugin eval`, on MCP mocks).
  - `browser/`: its session-start hook prints a banner for a UI task's builder and reviewer, whose `ui-check` skill captures and judges the screens a UI change touches.
  - `codegraph/`: for a setup trial's builders and reviewers, a session-start hook that, in a worktree with a `.codegraph/` directory, builds or syncs that worktree's CodeGraph index and prints a banner to locate code with `codegraph explore` first; no MCP server.
  - `coordinator/`: the coordinator's MCP servers and the claude.ai connectors it keeps, no worker's, the only ones `claude-coordinator` lets it load (its README says how the others are denied and how one is added).
  - `effect/`: for an Effect project's planner, builder and reviewer, the `effect-v4` skill (the installed `effect`'s sources, the v3 and beta traps, the check), a hook giving Effect's findings on each TypeScript file edited, and, but for a planner, Foldkit's DevTools server, held to the worktree.
  - `frontend/`: for Daniel's own session and the coordinator's intake, a walk's planner by `team-ui --capture` alone, never a build worker: the pinned Chrome DevTools MCP server on the Agent Chrome's localhost pages, `ui-capture` of Daniel's page and its selected element, and a skill to fix it.
  - `prod-mongo/`: for the ops role only, backups of Conventioner's production database into `~/conventioner-backups`, their restore drills, rehearsals of a release's migrations on a dump and undos prepared for Daniel, on the read user's connection string from 1Password.
  - `prod-read/`: for the ops role only, read-only access to Conventioner's production database through the pinned MongoDB MCP server, on a read-only Atlas user whose connection string comes from 1Password at server start.
  - `prod-write/`: for the ops role only, beside `prod-read`, document writes and index changes in Conventioner's production database through the pinned MongoDB MCP server, on a user that cannot drop or rename collections, every tool behind an ask rule.
  - `spec-review/`: the `spec-review` skill, two fresh readers of a task's spec and tickets, and `claims-check`, a fresh reader of a branch's prose against its code, which `team-worker` gives every delivering builder.
  - `vercel-read/`: for the ops role only, read-only access to Conventioner's two Vercel projects through the team's own MCP server, which sends only GET requests to a fixed set of endpoints on two project-scoped tokens from 1Password.

`.scratch/task/` is the task directory of a task on this repo, ignored by git.

## The team home

The team home holds:

| Path | What it holds |
| - | - |
| `ledger.jsonl` | The append-only record of every task's events |
| `level.jsonl` | The team's resource level and mode, one line per change (`team-level`), committed with the ledger so a level holds across restarts and handoffs |
| `drills.jsonl` | Each run of a drill, one line per run (`team-drill`): what ran, on which machine, code commit and Claude Code version, and its verdict, appended and never rewritten |
| `waiting.md` | What waits on Daniel, every open ask, PR ready to merge, interview and walk, and the asks and owed replies of the two kept lists, `tasks/current.md` and `assistant/current.md`, the assistant's marked, numbered and ranked by what each answer unblocks, as `team-inbox` last wrote it from the ledger and those files |
| `waiting.json` | The same list with each item's number, key and count and the latest post, which `team-inbox` reads to keep each number while its item stands |
| `projects.toml` | The project registry, read only through `bin/team-project`, whose `--help` documents every key |
| `tasks/` | Each task's plan, briefs and archived scratch; history, kept as written |
| `projects/` | Each project's planning (Conventioner's backlog) |
| `memory/` | Each registered project's Claude Code auto memory, `memory/<project>/`, which every machine and worktree of it shares once `team-config apply` points the project at it (a worker of it through `team-worker`'s settings), and the coordinator's, `memory/coordinator/`, the team home's own while it is no project's primary checkout, and the assistant's, `memory/assistant/`, which its settings name |
| `machine/` | What a machine needs to run the team, beyond the tools `bin/lib/tools.lock` pins: `claude/`, the Claude user config every machine shares (instructions, settings, skills, plugins), which `team-config` applies and captures; `secrets.json`, every secret file a machine needs, never a value, which `team-secrets` checks and restores from 1Password, described for Daniel in `secrets.md` |
| `usage/` | Each machine's Claude usage, `usage/<machine>/<YYYY-MM-DD>.jsonl`, one line per assistant reply (token counts, model, session, never content), and `usage/<machine>/time/<YYYY-MM-DD>.jsonl`, one row per launched worker session and day of where its time went (durations and tool or command names only), which `team-tokens export` writes from that machine's transcripts at each checkpoint and handoff, so they outlive Claude Code's 30-day transcript cleanup; and `usage/<machine>/quota/<YYYY-MM-DD>.jsonl`, each changed reading of the subscription's usage limits (the 5-hour and weekly windows) that `team-quota line` takes from a session's status line, which `team-quota status` reads |
| `manual-steps.md` | The steps only Daniel can take, which the assistant keeps |
| `assistant/` | The assistant's records: its hand-offs with the coordinator, `handoffs/H<n>.md` (one per hand-off) and their log `handoffs.jsonl`, which `team-assistant` writes; its list of what it asks or owes Daniel, `current.md`, which `team-current` keeps; its spikes' reports, `research/<YYYY-MM-DD>-<slug>.md`; the topics it closed, `topics.jsonl`, which `team-assistant thread --close` writes and `team-thread archive` reads; and its stow note, `handoff.md` |
