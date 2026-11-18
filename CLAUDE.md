# The agent team's code

This repo is the code of Daniel's agent team: the scripts that run a task's life, the prompts and settings each session starts with, the hooks, the toolkits and the tests.
The team's records live in the team home, a private repository of their own (see "The team home").
The team's own work on this repo goes through a task and a PR to `dev`, like any project's.

Before locating where something lives, or when adding, moving or removing a path, read `LAYOUT.md`: a line for each directory and each file that needs saying, and the team home's table; a new path that no line there covers gets its line in its PR.
Before writing or changing a test, a test helper or a CI job, read `tests/README.md`.

## The team home

The team home is the records the scripts read and write: a git checkout of a private repository of its own, never part of this repo.

- The scripts find it as `TEAM_HOME` when set, else the first line of `~/.config/agent-team/home` (a path relative to `$HOME`, or absolute); the library and `team-project` find it the same way, and refuse to start when neither names a directory, naming the fix (`echo agent-team-records > ~/.config/agent-team/home`), never falling back to the code checkout.
- Code never comes from the team home, and records never go into this repo: `bin/lib/records` lists the records paths, and the `pre-push` hook (below) keeps a tree holding any of them away from every repository but the team home's origin.

## Pull requests only

- The code repository changes only through pull requests to `dev`, and nothing is committed on `main`, which a release fast-forwards from `dev`.
  GitHub holds the rule: `dev`'s protection requires a pull request, refuses force pushes and deletion, and applies to administrators.
- The team's sessions push branches and open pull requests on the worker login when `bin/lib/worker-login` names one, while `team-merge` merges on the owner login (`sops/machine-setup.md`, "The worker login").
- `dev` also requires `agent-review`, the reviewer App's check run, which `team-review-check` posts and `team-merge` requires on the head of every agent-team PR while `bin/lib/review-app` names the App.
  The App's key, `~/.config/agent-team/review-app.pem`, is denied to the workers' and the coordinator's `Read` and Bash; `sops/merging.md` says what the App proves.
- Records never come here: every tracked path is code, listed in `bin/lib/code`, and none matches `bin/lib/records`; `tests/repo.bats` checks both, so a new path is listed as code in its PR.
- `bin/hooks/git/` holds the code checkout's git hooks, the local guard, which every worktree shares; each hook's header says how it decides.
  Its `pre-commit` (and `pre-merge-commit`) refuses every commit on `dev` and on `main`, and on any other branch a commit that adds or changes a records path.
  Its `pre-push` refuses every push to `dev`, a push to `main` that is not a fast-forward to a commit already on `origin/dev`, and on every remote a push whose tip tree holds a records path unless the remote is the team home's origin.
- The records repository's one hook, `bin/hooks/records-git/pre-commit`, refuses a records commit that adds an email address at a public provider or any image (a screenshot is never kept in git).
- One scan, `bin/lib/data-check`, holds both data rules: that hook runs its `records` policy, and CI's `data` job its `code` policy (no email address outside the fixture domains, no image, no `node_modules/` path), after gitleaks over the PR's commits.
  `team-post` holds a worker's post and a capture's text to its rule on addresses as well.
- Every session is denied skipping the hooks (`--no-verify`, `git commit -n`) and setting, unsetting or overriding `core.hooksPath` (reading it stays allowed), which is Daniel's to set.
  Those deny rules are a speed bump, never the guarantee: the hooks and `dev`'s protection are what hold the rule.

## Tests and shellcheck

- One file: `tests/vendor/bats-core/bin/bats tests/<name>.bats`; one test: add `-f '<part of its name>'`.
  A toolkit test file: `node --test tests/toolkits/<name>.test.mjs`; one test: add `--test-name-pattern '<part of its name>'`.
- No session runs a whole test suite on the team's machine (Daniel's rule, 2026-11-15): a worker runs only the tests of the code it changed and the whole suite runs in CI, but for a project with no CI, whose builder runs it once at its end until the project moves to CI-only (`sops/ci-only.md`).
- A builder runs on its machine only `tests/run shellcheck --changed` and the single test files it wrote or changed, and the suite on GitHub: at its round's end it pushes its branch, a ticket branch too, and runs `team-ci-run <project> <branch> <sha>` in the background, and it reports `DONE` or `PR` only once that exits 0.
- `dev`'s protection and `projects.toml`'s `required_checks` for `agent-team` require each CI job by its id, so renaming a job changes a required check.
- Tests run the real scripts in a sandbox (`load helpers/common`, then `sandbox` in `setup`): `TEAM_HOME` and `HOME` are temporary, `claude`, `gh`, `curl`, `op`, `systemctl`, `launchctl`, `busctl` and `systemd-run` are stubs, and git is real; `tests/helpers/common.bash` documents the helpers.
- The bats files run in parallel, so every file stays independent of the others.
- No test reaches 1Password or production, and none reads the records of the checkout it runs in: a test that needs a real-shaped registry or secrets manifest copies it from `tests/fixtures/`.
- A test that needs an address uses `example.com`, `example.invalid` or another fixture domain `bin/lib/data-check`'s header lists, and builds one at a real provider from a variable, so the file never holds one written out.
- A test runs `git -C`, `--git-dir`, `--work-tree`, `rm -r` or a git line's `cd` on a variable path only as `${var:?}`, so an empty variable stops its line instead of reaching the code checkout or the team home: `tests/guard-paths` rewrites them, and a single-quoted `bash -c` body or a quoted heredoc's stub is guarded by hand.
- A test kills the pids of a process search only when the search is bound by its owner (`-U` or `-u`) and by `$BATS_TEST_TMPDIR` or `$BATS_FILE_TMPDIR` (`own_pids`), which `tests/bound-kills` holds: a filter that matches every process ends the whole desktop session.
- A test waits on the processes it started, by their pids, never with a bare `wait`, which waits out bats' whole time limit.
- Scripts and tests run on Linux and macOS, where `bin/lib/platform.sh` puts Homebrew's GNU tools first on `PATH`, so GNU forms are fine and BSD-only ones are not; CI runs no macOS job, so a failure that only macOS shows is seen only when the suite runs on a Mac.
- Every PreToolUse hook entry, in `settings/*.json`, `coordinator.settings.json`, `assistant.settings.json`, `bin/lib/gate-claude-settings.json` and a toolkit's `hooks/hooks.json`, sets `"onFailure": "block"` and a whole-number `timeout` from 1 to 120 seconds beside its `command`, so a guard hook that fails or hangs blocks the call.
  Every hook entry of `settings/*.json` is in exec form, a `command` with no blank or quote and an `args` array, so the team's hooks run outside a confined session's shell prefix.
- Repo invariants are tests too, in `tests/repo.bats` and `tests/coordinator-manual.bats`: every executable in `bin/` answers `--help` with its header, every `bin/team-*` script is named in `roles/coordinator.md`, which is held to the caps in `tests/coordinator-manual.bats`, no tracked Markdown or template outside the records (`bin/lib/records`, kept as written) has an em dash, and `LAYOUT.md`'s Layout stays a list, one thing per line of at most 300 characters, alphabetical within each list.
  This file stays at most 12,000 bytes, and each role prompt in `roles/` but the coordinator's at most its own cap: when a cap fails, move material behind a pointer, and never raise the cap without Daniel's word.

## Script conventions

- Bash 5 (the library refuses older), `set -euo pipefail`, then the library: `source "$(dirname "${BASH_SOURCE[0]}")/lib/team.sh" "$@"`; `bin/lib/team.sh`'s header lists what it provides.
- The header (the comment block under the shebang) is the script's usage and its `--help`, which the library prints; exact commands live there and nowhere else.
- The team home is found as "The team home" says; `TEAM_HOME` is not exported, so pass it to a sibling script explicitly.
- The code checkout is the directory above `bin/` (`~/agent-team`): code (roles, settings, templates, plugins, hooks, toolkits) comes from the script's own checkout, never from the team home.
  In settings files and a toolkit's `.mcp.json`, `@TEAM_CODE@` names the code checkout, `@TASK_DIR@` the team home's `tasks/T<n>/` and `@WORKTREE@` the session's worktree by its real path; `team-worker` fills them in, and `claude-coordinator` fills `@TEAM_CODE@`.
- Exit codes: 0 done, 1 refused or a check failed (`die`), 2 a malformed command line (`usage_error`), 75 try again later.
- The ledger changes only through the library's `ledger_append`, which checks each event against `bin/lib/ledger-contract.json` and that the script is its kind's writer, or one of them, and, under the ledger's lock, a `refusing_writers` script's event against the task's state by `bin/lib/lifecycle.json`; a new kind or field goes in the contract first.
  A kind the contract marks `"push": true` (Daniel's word or an outside fact) is committed and pushed the moment it is logged by the library's `ledger_push`, which each of its writers calls once after its last event, as `tests/repo.bats` holds.
- A jq program that includes a module of `bin/lib` also includes, after it, every module that one includes, directly or not (`include "workers"; include "time"; include "ledger";`), which `tests/repo.bats` holds; `tests/README.md` has the jq 1.8.2 fault behind it.
- The registry is read only through `team-project`; a new key goes in its key lists and in its header, which documents every key.
- A script reaches Discord's API only through `discord_api` and GitHub through `gh`, but for the reviewer App's calls, which go through `review_app_api` and `curl`, since `gh` takes a token only from its environment or its login; and it never prints a secret.
- A script reaches GitHub as the session's login, the worker login when one is named, unless it is the owner's: `use_owner_login` for a script that is the owner's throughout, as `team-merge` is, or `owner_gh` (`with_owner_login` for a bounded call) for one call, all in `bin/lib/github-login.sh`.

## Markdown

- One sentence per line; keep normal Markdown structure.
- The plain dash "-", never the em dash.
- Daniel is "they".
