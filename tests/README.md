# The tests

The reference for writing or changing a test, a test helper or a CI job.
`CLAUDE.md`, "Tests and shellcheck" and "Script conventions", has the rules every change keeps, in short; this file gives the reasons behind the sandbox, path variable, `wait`, jq include, macOS and hook entry rules, and says how the suite runs, what CI runs and what the sandbox gives a test.
The one-file and one-test commands, the fixture-address rule and the repo invariants with the byte caps are in `CLAUDE.md` alone.
Exact commands are in each script's header (`tests/run --help`).

## How `tests/run` runs

`tests/run` runs shellcheck (CI pins 0.11.0) on every shell script in `bin/`, `tests/`, `servers/` and `toolkits/`, then the whole bats suite, then the toolkit tests; `tests/run shellcheck`, `tests/run bats` and `tests/run toolkits` run one part each, as the CI jobs do; `tests/run bats --shard <k>/<n>` runs one shard of the bats files, as CI's `test-shards` jobs do, whose `test` job keeps the required id.
`tests/run bats --changed [<base>]` runs only the bats files a change reaches, by the repository's naming, from the paths changed since `<base>` (default `origin/dev`) and in the working tree; its header says which files each path reaches.
`tests/run shellcheck --changed [<base>]` checks only the shell scripts among those paths and each script that sources one of them, directly or through another, so a changed library is checked where it is read; it checks nothing, and says so, when the change reaches no shell script, and `--list` prints the scripts and checks none.
Its bats files run in parallel, one bats per file and as many at once as `TEAM_JOBS` says when set, else as the team's CPU budget allows when a team home is found (`team-capacity jobs`, 3 at minor on 12 cores), else as there are CPUs (CI, a fresh clone), so every file must stay independent of the others; its last line is the wall time and the most files it ran at once.
It stops a bats test that runs past `TESTS_TEST_SECONDS` (default 600) and a bats file that runs past `TESTS_FILE_MINUTES` (default 40), each failing with the test's or the file's name, so a hang names itself long before CI's job ends.
`team-checks` gives the commands it runs `TEAM_JOBS` from `team-capacity jobs` unless it is set.
`tests/shards` splits them by each file's seconds in CI (`tests/timings.tsv`, a file it lacks weighed by its bytes), so refresh the timings with `tests/shards update` when the shards' times drift apart, and a removed bats file takes its row with it, as `tests/repo.bats` holds.
Every part but `shellcheck` alone and a `--list` (a shard's or `--changed`'s) runs under the machine's heavy-run lock (`bin/team-heavy`, which `team-checks` takes for the local checks too), so two suites on one machine queue instead of overlapping, each in a process group (and on Linux a scope) of its own that leaves a cost sample, and the sandbox clears `TEAM_HEAVY_HELD`, `AGENT_TEAM_TASK` and `TEAM_JOBS` so the tests take their own.

## What runs where

A builder of a project whose `projects.toml` entry has `branch_ci`, as agent-team's has `ci.yml`, runs only `tests/run shellcheck --changed` and the single test files it wrote or changed on the machine, and the suite on GitHub, whose `shellcheck` job checks every script.
At its round's end it pushes its branch, a ticket branch too, and runs `team-ci-run <project> <branch> <sha>` in the background, which waits through `team-ci-wait --run` on `ci.yml`'s run of that exact head (one already there, as the PR's own is when a PR is open, else one it starts with `workflow_dispatch`), and it reports `DONE` or `PR` only once that exits 0.
So the heavy-run lock queues only what still runs here, a `tests/run` by hand, `team-checks`' local checks of a project that lists them and a gate's end-to-end run, and `tests/run bats --changed` stays a by-hand tool that no brief or role names.

## CI

A PR to `dev` is checked on GitHub: `.github/workflows/ci.yml` runs its jobs (`shellcheck`, `test`, `toolkits`, `data` and `zizmor`, with the shard job `test-shards`, which `test` waits for), all on Linux and none on macOS, on every PR to `dev` and to `main` and by hand (`workflow_dispatch`), which is how `team-ci-run` starts a run on a builder's branch when CI has none of its head.
Each job has a time limit (`timeout-minutes`), about twice its longest recent run, and each that runs bats one above `tests/run`'s file limit, which `tests/repo.bats` holds.
`dev`'s protection and `projects.toml`'s `required_checks` for `agent-team` require each job by its id, so renaming a job changes a required check, and `team-merge` merges only with every one passed on the PR's exact head.
`tests/repo.bats` holds the jobs but the shard jobs to the registry fixture's `required_checks`, and each shard job to the job that waits for it, and no workflow runs on a push, a schedule or `pull_request_target`.
The `zizmor` job audits the workflows offline with zizmor, pinned by version and sha256 as gitleaks is, and fails on any finding; an accepted one is ignored on its own line as `# zizmor: ignore[<audit>] <reason>`, which `tests/repo.bats` holds, with no zizmor config to ignore more.
`.github/workflows/zizmor-online.yml` runs the same zizmor on the same triggers with the run's read-only token, for its online audits (an impostor commit, a known-vulnerable action, ref confusion); it is never a required check, since it depends on GitHub's API, and `tests/repo.bats` holds its triggers and its zizmor pin to `ci.yml`'s.
A project that still lists `local_checks` in `projects.toml` has them run through `bin/team-checks`, in a fresh detached worktree of the head: by `team-merge` before it merges, and by reviewers on the head they review; `agent-team` lists none, so for it `team-checks` says so and passes.
The Bootstrap workflow (`.github/workflows/bootstrap.yml`) runs only by hand: `team-bootstrap` on a fresh macOS runner and in an Arch container, which installs real tools.

## The toolkit tests

The toolkit tests are `node --test` files in `tests/toolkits/`, run after `servers/install`: each starts a toolkit's server exactly as its `.mcp.json` declares, with `op` stubbed and a throwaway MongoDB in Docker (for `vercel-read`, a fake of Vercel's API on the loopback instead), and speaks MCP to it over stdio (`tests/toolkits/helpers/` documents the helpers).
Each test file's header comment says what it checks and against what.
No test reaches 1Password or production: the test `PATH` refuses to start if a real `op` is on it.

## The sandbox

Tests run the real scripts in a sandbox (`load helpers/common`, then `sandbox` in `setup`): `TEAM_HOME` and `HOME` are temporary, `claude`, `gh`, `curl`, `op`, `systemctl`, `launchctl`, `busctl` and `systemd-run` are stubs, and git is real.
The sandbox's `TEAM_CGROUP_ROOT` holds the cgroup tree and `/proc` that `team-capacity place` and `check` read, empty until a test writes them, so no test moves the machine's processes; `team-capacity sample` reads the machine through its seams, which the sandbox sets to an idle one (`TEAM_MEMINFO` 24 GiB available of 32, `TEAM_READING_PROCS` no process, `TEAM_READING_CPUS` 12) and a test may rewrite or unset.
The sandbox's `TEAM_SYSTEM_ROOT` puts the library's system tool directories (treehouse's `/usr/local/bin` on Arch) inside it, so a PATH a test trims never gets the machine's own tools back on it.
The sandbox refuses a TMPDIR under `/home` or `/Users` (a job's own tmp under HOME, say), whose paths the ledger reads as a machine's HOME: run the tests with one outside them, as the default is.
A script run from this checkout has the reviewer App on, since `bin/lib/review-app` names it, while a copy of `bin/` (`copy_bin`) has it off: a test that needs either says so, with `review_app_on` or `review_app_off`.
`tests/helpers/common.bash` documents the helpers.
No test reads the records of the checkout it runs in, so the suite passes on the code alone: a test that needs a real-shaped registry or secrets manifest copies it from `tests/fixtures/`, and `team-doctor`'s `records` line checks the team home's real ledger, registry and secrets description.

## macOS

macOS assesses each new executable file on its first run, about a quarter of a second each, so a test never writes or copies an executable it could share: `stub_command`, `copy_bin` and the doctor's version stubs hard-link a read-only copy made once per run (`shared` in `tests/helpers/common.bash`).
Scripts and tests run on Linux and macOS: on macOS `bin/lib/platform.sh` (sourced by the library and the test helpers) puts Homebrew's GNU coreutils, findutils, sed, grep and `flock` first on `PATH`, so GNU forms are fine and BSD-only ones are not.
CI runs no macOS job, so a failure that only macOS shows is seen only when the suite runs on a Mac.

## jq includes

A jq program that includes a module of `bin/lib` also includes, after it, every module that one includes, directly or not (`include "workers"; include "time"; include "ledger";`), which `tests/repo.bats` holds.
jq 1.8.2, Homebrew's on macOS, loads a module before the ones it includes unless the program loaded them first, and frees the definitions that only another module calls, so a call into one reads freed memory and may fail an assertion ("Unknown function type"); jq fixed it after 1.8.2 (jqlang/jq#3620), and a program's includes load last first.

## Path variables and `wait`

A test runs `git -C`, `--git-dir`, `--work-tree`, `rm -r` or a git line's `cd` on a variable path only as `${var:?}`, so an empty variable stops its line instead of reaching the code checkout or the team home, which `tests/guard-paths --check` holds through `tests/repo.bats`, and `tests/guard-paths` rewrites.
The check reads only what the test file's own shell expands, so a single-quoted `bash -c` body or a quoted heredoc's stub, which expands its variables when it runs, is guarded by hand.
No test file or helper runs a bare `wait`, which `tests/repo.bats` holds: bats runs a test's time limit countdown as a background job of the test's own shell, so a bare `wait` waits out the whole limit, and a test waits on the processes it started, by their pids.

## PreToolUse hook entries

Every PreToolUse hook entry, in `settings/*.json`, `coordinator.settings.json`, `assistant.settings.json`, `bin/lib/gate-claude-settings.json` and a toolkit's `hooks/hooks.json`, sets `"onFailure": "block"` and a whole-number `timeout` from 1 to 120 seconds beside its `command`, which `tests/repo.bats` holds, so a guard hook that fails or hangs blocks the call; `team-doctor`'s `guard hooks` line runs `scratch-only-edits`, `command-guard` and `lease-fence` in each of its modes on a harmless Bash call, and `assistant-discord-guard` on a read of `#assistant`, since a guard that always fails then blocks every call it sees.
