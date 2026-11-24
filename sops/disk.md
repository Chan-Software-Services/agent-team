# SOP: the team's disk

What the team clears from its home directory so its disk does not fill, by what and when.
A cache in use is fine; what nothing reads again is not: a finished session's scratch, the volumes of containers that are gone, a build cache past a size.
`team-janitor disk` is the sweep: `~/agent-team/bin/team-janitor --help` is its exact reference, and `bin/lib/disk.sh` holds its logic.
`/tmp` and `/var/tmp` are `team-janitor tmp`'s (`sops/tmp.md`), and the reaper's anonymous volumes and stacks are in `sops/docker.md`.

## The job tmps

Each Claude Code background job has a directory, `~/.claude/jobs/<id>/`, whose `tmp` is the session's scratch: screenshots, test output, a background shell's log.
`team-close` and `team-stow` remove a closed session's whole job directory with `claude rm`, but each round of a task is a fresh launch, so a long task's finished sessions piled up until its close: on 2026-11-17 the open tasks' finished sessions held 20 GiB.

The sweep empties the tmp of a team session that nothing will wake again or that has been quiet for a day, while its task is still open:

- **Whose**: an entry of `~/.claude/jobs` named by 8 lowercase hex digits, a real directory of this user's, never a link, whose id the ledger has a launch of a planner, builder or reviewer with (its `session`).
  The coordinator's, the assistant's, an ops session's and Daniel's own sessions have no such launch, so they are never touched; an ops session's records are `team-ops-end`'s.
- **What**: its `tmp`, a real directory, never a link, holding at least one entry.
- **Kept always**: a job with no readable `state.json`; a session the list gives a `pid`; a tmp a live process of this user names, by its working directory, open files, command line or environment, read as `team-janitor tmp`'s not-live rule reads them.
- **Cleared** when the first of these holds, which gives its why:
  - its task is not open in the ledger: `T<n> is closed`;
  - `claude agents --json --all` does not list it: `not listed by Claude Code`, since `--all` lists every job directory with a readable `state.json` (read in Claude Code 2.1.331's `printAgentsJson`), so nothing can wake it;
  - its listed state is `stopped`: `stopped`, which Claude Code never wakes;
  - its listed state is `done` or `failed`, and its job's last change (`state.json`'s `updatedAt`, or that file's mtime) is more than 24 hours ago: `done and idle 26 h`.
- A listed state of `working` or `blocked`, or any state Claude Code adds later, is kept.
- The ledger and the session list are read once, and only when some job's tmp holds an entry; when either cannot be read, nothing is cleared and the run exits 1 saying why.

Why 24 hours: open tasks run from hours to days, a session settled for a day that is woken again has lost only temporary files, since its durable work is in `.scratch/task/`, and it matches the reaper's age for anonymous volumes.

Each entry directly inside the tmp is removed by its own path, a directory made writable first (`chmod -R`) and removed with `rm -rf --one-file-system`, a file with `rm -f`, after the job directory and its tmp are checked again to be real directories of this user's.
The tmp directory itself is kept, with its mode, so a woken session still finds the directory its prompt names.
A run stopped midway leaves whole entries, and the next run clears the rest.
`disk_clear_job_tmp` is that one clearing, which `team-close`'s fallback calls too.

## What a run says, and where

- Each clearing is one line on stdout, with the tmp's size and the why: `cleared the job tmp of T422's builder 0f178ea8 (9.5 GiB; done and idle 26 h)`.
- Each line is also appended, as `- HH:MM <line>` in local time, to `~/.local/state/agent-team/janitor/disk-<local date>.md`, titled `# Disk cleared on <machine>, <date>`; a day with no clearing has no file.
- A clearing that fails is said on stderr (`team-janitor: could not clear <path>: <rm's last line>`), the other jobs go on, and the run exits 1.
- A run that clears nothing prints nothing.
- One run at a time, by a lock on `~/.local/state/agent-team/disk.lock`: a second run says `another team-janitor disk is running; skipped` and exits 0.
- After each run but a dry run, `~/.local/state/agent-team/janitor/disk.json` (`team-disk/1`) records the run and the day's totals, written whole through a temporary file and a rename, so a stopped run leaves the last whole record; the totals start again on a new local date.
- `team-janitor disk --dry-run` prints `would clear` for each line, and clears, writes and locks nothing.
- `team-janitor disk status` (`--json` for `team-disk-status/1`) reads only: the job tmps cleared today and their size, and the last run.

## Test seams

A test runs the real `team-janitor disk` in the bats sandbox, against a fixture jobs tree under the sandbox's `HOME`, never the machine's `~/.claude/jobs`:

- the sandbox's stub `claude` answers `agents --json --all`;
- `TEAM_DISK_JOB_IDLE_MINUTES` replaces the 24 hours (1440 minutes), and a test ages a job by its `state.json`'s `updatedAt` or with `touch -d`.
