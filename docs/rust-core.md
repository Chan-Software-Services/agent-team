# The Rust core: design and port map

The team's core (the scripts in `bin/`, their library and their hooks) is being ported to Rust, step by step, as Daniel decided on 2026-11-15.
This doc is the one place that says where each part of today's team lands in that core: its crates, its two seams, what was decided since the first design, and the port map.
It is kept by hand: there is no check that it is complete, so each change keeps its own lines true.

## How it is kept

- An agent-team spec has a `## Rust core` section (`team-tickets --check` refuses one without it): where the change lands (crate, seam, config) and the lines of this doc it adds or changes, or `none`.
- A PR that adds, renames or removes a `bin/` script, a ledger event kind or a config file changes its line here in the same PR; the reviewer checks that the spec's section, this doc and the change agree.
- A step of the port reads this doc first; when it replaces a script, it deletes the bash and the script's line here together, and the crate's own docs take over.
- The port map is a proposal: each port step confirms or changes the lines it reaches, and a choice still open is listed under "Open", never written as decided.

## Sources

The design comes from these records, in the team home, which this doc summarises and never replaces:

- The consolidation design, `assistant/handoffs/H1.md`: section 10 (why Rust, the toolkit) and section 11 (the order of work).
- Step 1's plan, `tasks/T370/plan.md`, with Daniel's decisions for it.
- The interface options, `assistant/research/2026-11-23-agent-team-interfaces.md`, its section "The core's two seams", and Daniel's interface requirements, `assistant/research/2026-11-23-interfaces-requirements.md`.

## The order of work

H1's steps, each of which deletes the bash it replaces in the same step, so no part has two paths for good:

| Step | What | Ends when |
| - | - | - |
| 0 | Sort the open and queued agent-team work against the port | Daniel has a list to approve |
| 1 | The Rust toolkit, the build setup, CI (T370) | A builder with the toolkit passes its evals |
| 2 | The first crate: the log's append and contract, the read model, with the domain model's kinds and states | It agrees with the jq fold on the real ledger |
| 3 | The engine service, and workers' reports as claims, kind by kind | The coordinator pastes no worker message |
| 4 | Requests and the one inbox; proposals in place of queue files; findings that can expire | `current.md` holds no request |
| 5 | Lifecycle steps move into the engine one at a time; the attention queue; judgment sessions | The manual holds judgment only |
| 6 | The assistant's commands and researchers; interviews as lists | No session waits on a thread |
| 7 | The lease, the fence and the platform seam, the macOS backend, the drills on both machines | A handoff and a steal drill pass on the two machines |
| 8 | Confinement, then the deny rules deleted | The shell-reading hook is gone on Linux |

## The crates

A Cargo workspace at the repository's root, its crates under `crates/` (T370's spec); the names below are the interface research's, and step 2 may rename them.

| Crate | Holds | Depends on |
| - | - | - |
| `team-model` | Ledger events (one closed enum of the kinds below), the lifecycle table, the read model (the jq fold, ported), the registry's types, `Attestation`; no I/O | nothing platform |
| `team-core` | The engine: append, derive, lifecycle actions, the verifier of Daniel's words, the lease and the fence, sessions, the queue and the inbox, over traits only | `team-model` |
| `team-platform` | The `Platform` trait and its types, and the sibling `Vcs` trait (git, GitHub), no OS implementation | `team-model` |
| `team-platform-linux`, `team-platform-macos` (`-windows` later) | One implementation each, behind `cfg(target_os)` and a cargo feature | `team-platform` |
| `team-guard` | The guards run before each tool call and git's hooks: fast to start, no interpreter (open: its own binary or `team-cli`'s) | `team-model`, `team-platform` |
| `team-api` | Wire types, the schema (the contract, as `ledger-contract.json` is today), the client library | `team-model` |
| `teamd` | The engine service: wires `team-core` to one platform crate and the server transport; replaces the heartbeat timer and the polling loops | all of the above |
| `team-cli` | The `team` command, a thin client of `team-api`, with a direct read of the records when `teamd` is down | `team-api` |
| `adapter-discord`, `adapter-web` (later) | One UI each, a client process of `team-api` | `team-api` only |

- `team-core` and `team-model` never name an OS or a UI, and an adapter never depends on `team-core`.
- So the Discord fields of today's events (`discord_thread`, `discord_message`, 22 kinds carry one, the kinds of three of the four first-hand words among them) cannot stay as they are in `team-model`: how such a reference crosses the interface seam is open (below).
- What stays outside Rust: the MCP servers and toolkits in JavaScript (`servers/`, `toolkits/`), the vendored tools, and the role prompts, templates and SOPs, which are text.

## The platform seam

The `Platform` trait, one implementation per OS, so no command asks which system it runs on:

- Process supervision: spawn a session in a directory, environment and confinement; track, signal, wait and reap it (process groups on Unix).
- Confinement: file-system roots and denies (Landlock on Linux; the macOS backend is open), with an honest `Capabilities` report of what a platform cannot enforce.
- Resource limits and the heavy-run lock (cgroups and slices on Linux, launchd limits on macOS).
- Service lifecycle: install, start, stop and status of `teamd` (systemd user units, launchd agents).
- IPC endpoints: the local socket, with the peer's credentials.
- Paths: config, data, state, runtime and temp directories.
- Secrets: a `SecretStore` over the OS keychain, with the 1Password restore as a separate provider.
- Locks and file semantics: atomic append and rename for the ledger, advisory locks, `fsync`, watching a file.
- The sibling `Vcs` trait: everything a script now does by running `git` or `gh` or calling GitHub's API, so tests use fakes as the bats suite uses stubs.

The port map's seam `platform` means a line reaches the `Platform` trait, and `vcs` the `Vcs` trait.

## The interface seam

- `teamd` is the only writer of the ledger; the `team` command, the Discord adapter and any later web app are clients of its API and hold no state.
- The API has a command side (typed requests with typed refusals: `answer_ask`, `approve_plan`, `give_merge_word`, `withdraw_approval`, `hand_off`, `status`, `list_waiting`, `send_to_session` and the task verbs) and an event side (a resumable stream of ledger events by sequence number).
- Daniel's four first-hand words each carry an `Attestation` that the core verifies, so a UI can present evidence and never grants a word.
- The core pushes out through two traits the adapters implement, `Notifier` (a notice) and `AskPresenter` (an ask with its choices), so one ask is buttons in Discord, a numbered list in the terminal and a card in a web app.
- Transport: HTTP and JSON with Server-Sent Events over a Unix socket, with a per-client token; a confined worker cannot reach it unless its sandbox maps the socket.
- The Discord plugin stays a conversation door into the coordinator's session, not a client of `teamd`.
- From Daniel's interface requirements, the API carries from the start: a session list and a session's stream, Daniel's verified message as its own kind, file transfer to and from a session, the event push, and signed actions for the four words.
  The interfaces are built after the core.

The port map's seam `interface` means a line reaches `team-api`, `Notifier` or `AskPresenter`, or is an adapter; `none` means it is the model or the engine alone.

## Decided since H1

1. No macOS test run on a Mac and no macOS CI until Daniel says, but for the one job of decision 14; the core still keeps the platform seam, so it is meant to build for macOS (Daniel, 2026-11-15, T370's decision 1; it overrides H1's "both in CI from the first crate").
2. The core is a Cargo workspace inside this repository, so one PR replaces a bash script and its tests together (T370's decision 2).
3. Rust is installed under the home directory with rustup, the toolchain and its rust-analyzer component pinned by `rust-toolchain.toml`, and cargo-nextest and sccache pinned in `bin/lib/tools.lock` with a `team-doctor` line and a `team-bootstrap` step (T370's decision 3).
4. A crate is added only by a ticket that names it; `cargo-deny` gates licenses, advisories and sources (crates.io only); `Cargo.lock` is committed (T370's decision 4).
5. The port runs one task at a time at queue priority 1 (T370's decision 5).
6. The workspace sits at the repository's root, a virtual workspace with its crates under `crates/`, its first a skeleton `crates/team-core` that step 2 may rename (T370's spec).
7. The Rust core comes first, then the team working on macOS by 2026-12-18, and the core keeps two clean seams: the platform (Linux, macOS, Windows later) and the interface (the CLI, Discord, a web app or whatever the UI becomes) (Daniel, 2026-11-23, H168).
8. Daniel's interface requirements (any session, typed or dictated input; a dashboard of all active tasks; a secure shell; files and images both ways) are built after the core, and the interface seam carries them from the start (Daniel, 2026-11-23, the interface requirements' research note).
9. The model and effort of every session category come from one easy-to-change config, now in bash and in the core (Daniel, 2026-11-23, H173; T513).
10. Topic sessions, and the assistant's digest three times a day on a schedule given as an IANA zone and three local times (Daniel, 2026-11-23, H175 to H177; T514).
11. This doc and its port map, kept by hand, with no CI check (Daniel, 2026-11-23, H178).
12. Toolkits and playbooks become domain objects, data in `team-model`: access becomes a grant apart from toolkits, which never carry authority; a playbook run is a task on a `playbook` path with its steps as checkpoints; a toolkit's OS-specific parts go through the platform seam; decided, not built, since its design task waits until the core is done (Daniel, 2026-11-23, H179).
13. A link inbox: Daniel shares links into a `#inbox` channel, each starting a full research task; fetchers by kind, sandboxed, with no login anywhere; it runs on the team's host and moves with it; decided, not built, since it waits until the core is done (Daniel, 2026-11-23, H180).
  It lands as an input of the interface seam, its fetchers behind the platform seam where the tools differ (the assistant's sketch: faster-whisper on Linux, whisper.cpp on the Mac).
14. One macOS job in CI for the Rust workspace, on GitHub's runners, so long as nothing requires it to merge: neither a required check nor a job a required check depends on; its findings are fixed without blocking a merge, and if it cannot be kept so, there is none (Daniel, 2026-11-23, H194).

## Open

- Where `team-guard` lives: its own small binary, for the start time a PreToolUse hook needs, or a subcommand of the `team` binary.
- Where the `Vcs` trait's implementation lives: in `team-platform` beside the trait, or a crate of its own.
- How macOS workers are confined (H1's open question 8).
- How an event's Discord reference (a thread, Daniel's message) stays behind the interface seam: an adapter-opaque reference, its adapter's kind and its id, inside the event or the `Attestation`, is one shape.
- Where a guard of one adapter's tools lives, as `bin/hooks/assistant-discord-guard` is of Discord's: in `team-guard` behind the same kind of reference, or with its adapter.
- Which of the 16 interface proposals Daniel keeps.

## Planned, not built

The open plans' Rust core lines, taken from their plans; each moves into the map when its PR merges.

| Plan | What | Crate | Seam |
| - | - | - | - |
| T514 | The topic role and its script (`team-topic open`) | `team-core` (sessions) | `platform`, `interface` |
| T514 | The digest's schedule and its config line (an IANA zone and three local times) | `teamd` (a timer), `team-model` (its type) | `interface` (`Notifier`) |

## The port map

Each `team-<name>` command becomes `team <name>` of `team-cli` unless its line says otherwise, a client of the `team-api` command that does the work in the crate named.

### Commands

| Script | Crate | Seam | Note |
| - | - | - | - |
| `bin/claude-assistant` | `team-core` | `platform` | Starts the assistant's session |
| `bin/claude-coordinator` | `team-core` | `platform` | Starts the coordinator's session |
| `bin/team-answer` | `team-core` | `interface` | `answer_ask`, with Daniel's `Attestation` |
| `bin/team-ask` | `team-core` | `interface` | Requests (step 4), shown through `AskPresenter` |
| `bin/team-assistant` | `team-core` | `interface` | Hand-offs between the assistant and the coordinator |
| `bin/team-bootstrap` | `team-cli` | `platform` | A fresh machine |
| `bin/team-brief` | `team-core` | `none` | Briefs from `templates/` |
| `bin/team-capacity` | `team-core` | `platform` | The admission rule; the slices are the platform's |
| `bin/team-catch-up` | `team-core` | `vcs` | |
| `bin/team-checkpoint` | `team-core` | `vcs` | Pushes the records |
| `bin/team-checks` | `team-core` | `vcs`, `platform` | A detached worktree, under the heavy-run lock |
| `bin/team-ci-run` | `team-core` | `vcs` | |
| `bin/team-ci-wait` | `team-core` | `vcs` | |
| `bin/team-clean-messages` | `team-core` | `vcs` | |
| `bin/team-close` | `team-core` | `platform`, `vcs`, `interface` | |
| `bin/team-config` | `team-cli` | `platform` | The machine's Claude user config |
| `bin/team-current` | `team-core` | `none` | Step 4 moves its requests into the one inbox |
| `bin/team-doctor` | `team-cli` | `platform`, `vcs` | |
| `bin/team-drill` | `team-core` | `none` | |
| `bin/team-handoff` | `team-core` | `platform`, `vcs` | The lease (step 7) |
| `bin/team-heavy` | `team-platform` | `platform` | The heavy-run lock and its scope: the trait here, each OS's body (systemd's or launchd's scope) in its own crate |
| `bin/team-inbox` | `team-core` | `interface` | The one inbox (step 4); `list_waiting` |
| `bin/team-janitor` | `team-core` | `platform` | Docker and `/tmp` |
| `bin/team-land` | `team-core` | `vcs` | The merge queue |
| `bin/team-lease` | `team-core` | `vcs`, `platform` | The lease, the epoch and the fence (step 7) |
| `bin/team-level` | `team-core` | `platform` | |
| `bin/team-load-check` | `team-cli` | `platform` | Probes what a worker reaches |
| `bin/team-log` | `team-core` | `interface` | The append; reports become claims (step 3) |
| `bin/team-merge` | `team-core` | `vcs`, `interface` | `give_merge_word`, the verifier |
| `bin/team-models` | `team-model` | `none` | The model and effort config's reader (`sops/models.md`): its categories, each falling back through its parent to `default`, the most specific line winning; stays the reader until the port replaces it |
| `bin/team-next` | `team-core` | `interface` | Lifecycle actions (step 5) |
| `bin/team-open` | `team-core` | `vcs`, `interface` | |
| `bin/team-ops-end` | `team-core` | `platform` | |
| `bin/team-post` | `adapter-discord` | `interface` | `Notifier` |
| `bin/team-proc` | `team-platform` | `platform` | |
| `bin/team-project` | `team-model` | `none` | The registry's types and reader |
| `bin/team-queue` | `team-core` | `none` | Proposals in place of queue files (step 4) |
| `bin/team-quota` | `team-core` | `platform` | |
| `bin/team-records-rewrite` | `team-cli` | `vcs` | A one-off cutover; may retire instead |
| `bin/team-resume` | `team-core` | `platform`, `vcs` | The lease (step 7) |
| `bin/team-retro` | `team-core` | `none` | |
| `bin/team-review-check` | `team-core` | `vcs` | The reviewer App's check |
| `bin/team-review-comment` | `team-cli` | `vcs` | |
| `bin/team-review-status` | `team-cli` | `vcs` | |
| `bin/team-run-approved` | `team-core` | `platform`, `interface` | Bound to the approved bytes, with an `Attestation` |
| `bin/team-secrets` | `team-platform` | `platform` | `SecretStore` and the 1Password provider |
| `bin/team-snapshot` | `team-core` | `interface` | A read model view; `status` |
| `bin/team-stack` | `team-core` | `platform` | Docker behind the platform |
| `bin/team-state` | `team-core` | `interface` | A read model view |
| `bin/team-stow` | `team-core` | `platform` | |
| `bin/team-stowed` | `team-core` | `none` | |
| `bin/team-sweep` | `team-core` | `none` | The attention queue (step 5) |
| `bin/team-thread` | `adapter-discord` | `interface` | |
| `bin/team-tickets` | `team-cli` | `none` | The planner's ticket and spec rules |
| `bin/team-time` | `team-core` | `none` | A read model view |
| `bin/team-timers` | `teamd` | `platform` | The heartbeat becomes the service (step 3) |
| `bin/team-tokens` | `team-cli` | `platform` | Reads the sessions' transcripts |
| `bin/team-ui` | `team-cli` | `interface` | |
| `bin/team-uptime` | `teamd` | `interface` | `Notifier` |
| `bin/team-worker` | `team-core` | `platform` | Spawn and confinement |

### Hooks

| Script | Crate | Seam | Note |
| - | - | - | - |
| `bin/hooks/assistant-digest` | `team-cli` | `none` | A read model view |
| `bin/hooks/assistant-discord-guard` | `team-guard` | `interface` | Discord-specific: its place is open |
| `bin/hooks/assistant-stop` | `team-cli` | `none` | |
| `bin/hooks/axi-banner` | `team-cli` | `none` | |
| `bin/hooks/command-guard` | `team-guard` | `platform` | The rule table confinement does not hold (step 8) |
| `bin/hooks/compact-hold` | `team-cli` | `none` | |
| `bin/hooks/denial-log` | `team-cli` | `none` | Logs `denied` |
| `bin/hooks/git/pre-commit` | `team-guard` | `vcs` | |
| `bin/hooks/git/pre-merge-commit` | `team-guard` | `vcs` | |
| `bin/hooks/git/pre-push` | `team-guard` | `vcs` | |
| `bin/hooks/lease-fence` | `team-guard` | `none` | The fence (step 7) |
| `bin/hooks/ops-log` | `team-cli` | `none` | |
| `bin/hooks/records-git/pre-commit` | `team-guard` | `vcs` | |
| `bin/hooks/scratch-only-edits` | `team-guard` | `platform` | Confinement's roots (step 8) |
| `bin/hooks/session-digest` | `team-cli` | `none` | A read model view |
| `bin/hooks/session-records-guard` | `team-guard` | `platform` | |
| `bin/hooks/stop-sweep` | `team-cli` | `none` | The attention queue |

### The library

| Path | Crate | Seam | Note |
| - | - | - | - |
| `bin/lib/capacity.jq` | `team-core` | `platform` | The admission rule and its readings |
| `bin/lib/channel-access.sh` | `adapter-discord` | `interface` | |
| `bin/lib/chrome.sh` | `team-platform` | `platform` | The trait here, each OS's path in its own crate |
| `bin/lib/code` | `team-guard` | `none` | Config: the code paths |
| `bin/lib/command_rules.py` | `team-guard` | `platform` | |
| `bin/lib/command_text.py` | `team-guard` | `none` | |
| `bin/lib/compact-hold.sh` | `team-cli` | `none` | |
| `bin/lib/confine-roots` | `team-platform-linux` | `platform` | Config: the shared roots |
| `bin/lib/confine-session` | `team-platform-linux` | `platform` | |
| `bin/lib/confine-shell` | `team-platform-linux` | `platform` | |
| `bin/lib/confine.py` | `team-platform-linux` | `platform` | Landlock |
| `bin/lib/data-check` | `team-guard` | `none` | |
| `bin/lib/delete_rules.py` | `team-guard` | `platform` | |
| `bin/lib/doctor.d/` | `team-cli` | `platform`, `vcs` | One check per file |
| `bin/lib/drills.jq` | `team-model` | `none` | |
| `bin/lib/drills.json` | `team-model` | `none` | Config: the drill registry |
| `bin/lib/error-view.sh` | `team-cli` | `interface` | |
| `bin/lib/fence_rules.py` | `team-guard` | `none` | |
| `bin/lib/gate-claude-settings.json` | stays | `none` | Config: the gate's Claude settings |
| `bin/lib/gate-config.awk` | `team-cli` | `none` | |
| `bin/lib/github-api.sh` | `team-platform` or a `Vcs` crate (open) | `vcs` | |
| `bin/lib/github-login.sh` | `team-platform` or a `Vcs` crate (open) | `vcs` | |
| `bin/lib/guarded` | `team-model` | `none` | Config: the short list |
| `bin/lib/health.jq` | `team-model` | `none` | |
| `bin/lib/kill_rules.py` | `team-guard` | `platform` | |
| `bin/lib/launch.sh` | `team-core` | `platform` | |
| `bin/lib/ledger-contract.json` | `team-model` | `none` | Config: becomes the event enum and its schema |
| `bin/lib/ledger.jq` | `team-model` | `none` | The read model (step 2) |
| `bin/lib/lifecycle.json` | `team-model` | `none` | Config: the lifecycle table |
| `bin/lib/messages.jq` | `team-model` | `none` | Retires once reports are claims (step 3); its `message_carried`, the tickets a PR carried, moves to the PR claim's handling |
| `bin/lib/notice.jq` | `team-model` | `none` | |
| `bin/lib/notices.sh` | `team-core` | `interface` | `Notifier` |
| `bin/lib/opencode-gate` | stays | `none` | The gate's opencode wrapper |
| `bin/lib/opencode-guard.js` | stays | `none` | An opencode plugin |
| `bin/lib/outbound.py` | `team-guard` | `platform` | |
| `bin/lib/platform.sh` | `team-platform` | `platform` | Retires: Rust needs no GNU tools on macOS |
| `bin/lib/prices.json` | `team-model` | `none` | Config: model prices |
| `bin/lib/probe.json` | `team-cli` | `platform` | Config: the refusal probe |
| `bin/lib/queue.jq` | `team-model` | `none` | |
| `bin/lib/quota.sh` | `team-core` | `none` | |
| `bin/lib/reading.sh` | `team-platform` | `platform` | The trait here, each OS's body (`/proc` on Linux) in its own crate |
| `bin/lib/records` | `team-guard` | `none` | Config: the records paths |
| `bin/lib/records-rewrite/` | `team-cli` | `vcs` | With `team-records-rewrite` |
| `bin/lib/repo-moves.json` | `team-model` | `none` | Config |
| `bin/lib/review-app` | `team-platform` or a `Vcs` crate (open) | `vcs` | Config: the reviewer App |
| `bin/lib/review_facts.py` | `team-core` | `vcs` | |
| `bin/lib/session-activity` | `team-core` | `platform` | |
| `bin/lib/session_records.py` | `team-guard` | `platform` | |
| `bin/lib/stack.jq` | `team-core` | `platform` | |
| `bin/lib/stow.sh` | `team-core` | `platform`, `vcs` | |
| `bin/lib/team.sh` | every crate | all | The shared library, split by what each function does |
| `bin/lib/temp-files.sh` | `team-platform` | `platform` | |
| `bin/lib/threads.sh` | `adapter-discord` | `interface` | |
| `bin/lib/ticket_graph.py` | `team-cli` | `none` | |
| `bin/lib/time.jq` | `team-model` | `none` | |
| `bin/lib/tmp-leftovers` | `team-core` | `platform` | Config |
| `bin/lib/tmp.sh` | `team-core` | `platform` | |
| `bin/lib/tools.jq` | `team-cli` | `platform` | |
| `bin/lib/tools.lock` | `team-cli` | `platform` | Config: the pinned tools |
| `bin/lib/uptime.jq` | `team-model` | `none` | |
| `bin/lib/vendor/` | stays | `none` | Vendored: git filter-repo |
| `bin/lib/worker-login` | `team-platform` or a `Vcs` crate (open) | `vcs` | Config: the worker login, absent while it is off |
| `bin/lib/workers.jq` | `team-model` | `none` | |
| `bin/lib/working-set.awk` | `team-platform-linux` | `platform` | |

### Ledger event kinds

Every kind is a variant of `team-model`'s event enum; the column says which command writes it in the core.

| Kind | Written today by | Written in the core by | Seam |
| - | - | - | - |
| `answered` | `team-log`, `team-answer` | `answer_ask` | `interface` |
| `asked` | `team-log`, `team-ask` | requests (step 4) | `interface` |
| `blocked` | `team-log` | a worker's claim (step 3) | `none` |
| `branch-renamed` | `team-log` | `team-core` | `vcs` |
| `caught-up` | `team-catch-up` | `team-core` | `vcs` |
| `ci` | `team-log` | `team-core` | `vcs` |
| `ci-rerun` | `team-log` | `team-core` | `vcs` |
| `closed` | `team-close` | `team-core` | `none` |
| `denied` | `team-log`, `denial-log` | `team-cli`'s hook | `none` |
| `dequeued` | `team-merge` | `team-core` | `vcs` |
| `done` | `team-log` | a worker's claim (step 3) | `none` |
| `failed` | `team-log` | a worker's claim (step 3) | `none` |
| `gate-lane-cleared` | `team-clean-messages` | `team-core` | `vcs` |
| `gate-run` | `team-log` | `team-core` | `none` |
| `handoff` | `team-assistant` | `hand_off` | `interface` |
| `held` | `team-log` | `team-core`, on Daniel's word | `interface` |
| `history-rewritten` | `team-clean-messages` | `team-core` | `vcs` |
| `image-posted` | `team-post` | `adapter-discord` through `team-api` | `interface` |
| `image-retracted` | `team-post` | `adapter-discord` through `team-api` | `interface` |
| `injection` | `team-log` | a worker's claim (step 3) | `none` |
| `interview-thread` | `team-thread` | `adapter-discord` through `team-api` | `interface` |
| `launch` | `team-worker` | `team-core` (sessions) | `platform` |
| `merge-approved` | `team-log` | `give_merge_word` | `interface` |
| `merge-default-restored` | `team-log` | `team-core`, on Daniel's word | `interface` |
| `merge-default-withdrawn` | `team-log` | `withdraw_approval` | `interface` |
| The four retired merge-word kinds, which `sops/merging.md` names under "The retired words" | none: retired, `team-log` refuses a new one | none: retired, read only | `none` |
| `merged` | `team-merge` | `team-core` | `vcs` |
| `opened` | `team-open` | `team-core` | `none` |
| `paused` | `team-log`, `team-worker` | `team-core` | `none` |
| `plan-approval-withdrawn` | `team-log` | `withdraw_approval` | `interface` |
| `plan-approved` | `team-log` | `approve_plan` | `interface` |
| `pr` | `team-log` | a worker's claim (step 3) | `vcs` |
| `queued` | `team-merge` | `team-core` | `vcs` |
| `question` | `team-log`, `team-ask` | a worker's claim (step 3) | `none` |
| `ran` | `team-run-approved` | `team-core` | `platform` |
| `rehome-failed` | `team-resume` | `team-core` | `vcs` |
| `rehomed` | `team-open` | `team-core` | `vcs` |
| `resumed` | `team-log`, `team-answer` | `team-core` | `none` |
| `retro-change` | `team-log` | `team-core` | `none` |
| `retro-schedule` | `team-log` | `team-core`, on Daniel's word | `interface` |
| `review` | `team-log` | a reviewer's claim (step 3) | `none` |
| `stow-failed` | `team-stow` | `team-core` | `platform` |
| `stowed` | `team-stow` | `team-core` | `platform` |
| `stowing` | `team-stow` | `team-core` | `platform` |
| `thread` | `team-thread` | `adapter-discord` through `team-api` | `interface` |
| `ticket-done` | `team-log` | a worker's claim, the first kind (step 3), and one for each ticket a builder's PR claim carried, built with no claim of its own (`message_carried`) | `none` |
| `waiting` | `team-log` | `team-core` | `none` |
| `walk` | `team-ui` | `team-core` | `interface` |
| `walk-note` | `team-thread`, `team-ui` | `adapter-discord` through `team-api` | `interface` |
| `worktree-added` | `team-open` | `team-core` | `vcs` |
| `worktree-moved` | `team-open` | `team-core` | `vcs` |
| `worktree-returned` | `team-close` | `team-core` | `vcs` |

### Config files and records

The config in `bin/lib/` is in the library's table above; the rest, with the team home's records the scripts read:

| File | Where | Crate | Seam | Note |
| - | - | - | - | - |
| `ledger.jsonl` | the team home | `team-model` (events), `team-core` (the append) | `none` | The log the read model folds |
| `projects.toml` | the team home | `team-model` | `none` | The registry, read through `team-project` today |
| `models.toml` | the team home | `team-model` | `none` | The model and effort of every session category, read through `team-models` today; its format is the contract |
| `level.jsonl` | the team home | `team-core` | `platform` | The resource level |
| `sessions.jsonl` | the team home | `team-core` (sessions) | `none` | The coordinator's and the assistant's launches, each with what it runs on |
| `drills.jsonl` | the team home | `team-model` | `none` | |
| `waiting.json`, `waiting.md` | the team home | `team-core` | `interface` | The one inbox (step 4) |
| `tasks/current.md`, `assistant/current.md` | the team home | `team-core` | `none` | Step 4 moves their requests into the inbox |
| `tasks/queued/` | the team home | `team-core` | `none` | Proposals (step 4) |
| `machine/secrets.json` | the team home | `team-platform` | `platform` | `SecretStore`'s manifest |
| `machine/claude/` | the team home | `team-cli` | `platform` | `team-config` |
| `projects/<project>/review-rules.md` | the team home | `team-core` | `none` | A review brief's standing lines |
| `usage/` | the team home | `team-cli` | `platform` | `team-tokens` and `team-quota` |
| `assistant/handoffs.jsonl`, `assistant/topics.jsonl` | the team home | `team-core` | `interface` | The assistant's hand-offs and closed topics |
| `manual-steps.md` | the team home | stays | `none` | Text the assistant keeps |
| `memory/` | the team home | stays | `none` | Claude Code's auto memory |
| `~/.claude/channels/discord/access.json` | the machine | `adapter-discord` | `interface` | The Discord plugin's access |
| `~/.claude/channels/discord/.env` | the machine | `adapter-discord` | `interface` | The bot token, a secret |
| `~/.claude/channels/discord-assistant/` | the machine | `adapter-discord` | `interface` | The assistant's plugin state |
| `~/.claude.json` | the machine | `team-cli` | `platform` | Claude Code's user state |
| `~/.claude/settings.json` | the machine | `team-cli` | `platform` | Claude Code's user settings |
| `~/.config/agent-team/home` | the machine | `team-platform` | `platform` | Paths |
| `~/.config/agent-team/machine` | the machine | `team-platform` | `platform` | The machine's name |
| `~/.config/agent-team/capacity.json` | the machine | `team-core` | `platform` | |
| `~/.config/agent-team/stack.json` | the machine | `team-core` | `platform` | |
| `~/.config/agent-team/review-app.pem` | the machine | `team-platform` or a `Vcs` crate (open) | `vcs` | A secret |
| `~/.config/agent-team/gh-worker/` | the machine | `team-platform` or a `Vcs` crate (open) | `vcs` | The worker login |
| `~/.config/agent-team/confine/` | the machine | `team-platform-linux` | `platform` | Each confined session's roots |
| `~/.local/state/agent-team/` | the machine | `team-platform` (paths), `teamd` | `platform` | The machine's state: the lease, health, notices, the inbox, quota and uptime readings, locks and logs |
| `settings/*.json` | the code | stays | `platform` | Workers' Claude Code settings, with `team-guard`'s hooks |
| `coordinator.settings.json`, `assistant.settings.json` | the code | stays | `platform` | |
| `rust-toolchain.toml` | the code | the workspace | `none` | |
| `Cargo.toml` | the code | the workspace | `none` | The virtual workspace: its members under `crates/`, its shared package keys and lints |
| `Cargo.lock` | the code | the workspace | `none` | Committed; `tests/run rust` builds with `--locked` |
| `clippy.toml` | the code | the workspace | `none` | Where a test may unwrap, expect and panic |
| `deny.toml` | the code | the workspace | `none` | The dependency policy `tests/run rust` holds the workspace to with `cargo-deny` |
| `.github/workflows/*.yml` | the code | stays | `vcs` | |
| `toolkits/*/.mcp.json`, `mcp-roles.json`, `hooks/hooks.json` | the code | stays | `platform` | |
| `~/.no-mistakes/` config | the machine | `team-cli` | `none` | The gate's, read and set by `gate-config.awk` |
