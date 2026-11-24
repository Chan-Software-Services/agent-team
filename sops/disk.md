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
- The ledger and the session list are read once on each run that finds `~/.claude/jobs`, so a broken one shows on a quiet machine too; when either cannot be read, nothing is cleared and the run exits 1 saying why.

Why 24 hours: open tasks run from hours to days, a session settled for a day that is woken again has lost only temporary files, since its durable work is in `.scratch/task/`, and it matches the reaper's age for anonymous volumes.

Each entry directly inside the tmp is removed by its own path, a directory made writable first (`chmod -R`) and removed with `rm -rf --one-file-system`, a file with `rm -f`, after the job directory and its tmp are checked again to be real directories of this user's.
The tmp directory itself is kept, with its mode, so a woken session still finds the directory its prompt names.
A run stopped midway leaves whole entries, and the next run clears the rest.
`disk_clear_job_tmp` is that one clearing, which `team-close`'s fallback calls too.

### `team-close`'s fallback

After its `claude rm` of each of the task's sessions, in a close and in `--ticket`, `team-close` looks for each one's job directory, whether `claude rm` succeeded or failed.
When it is still there, its tmp is cleared by `disk_clear_job_tmp`, the directory and its `state.json` kept, and `team-close: cleared the job tmp of <id> (<size>), which claude rm left` is said on stderr.
The day's file has the line with its why, `T<n> is closed`, or `T<n>'s ticket NN is returned` for `--ticket`.
A clearing that fails is one line on stderr (`team-close: could not clear <path>: <rm's last line>`), and the close goes on.
An ops session is never touched: its records are `team-ops-end`'s.
A closed task's stack takes its volumes with it already: `team-close` runs `team-stack down` for each returned worktree's stack, which removes the anonymous volumes Compose leaves (`sops/docker.md`).

## The Go build cache

Go keeps its build cache in `go env GOCACHE`, `~/.cache/go-build` on Linux: 256 two-hex directories of `<hash>-a` files and `<hash>-d` files or directories, plus `README` and `trim.txt`.
Go itself drops only entries unused for 5 days and has no size cap, so the cache peaks at about 5 days of builds: on 2026-11-17 it held 51 GiB, 21 GiB of it from one day of the `no-mistakes` project's builds.

The sweep holds it to a cap:

- **Where**: `TEAM_GO_CACHE` when set, else what `go env GOCACHE` prints (given 20 s) when `go` is on the `PATH` and answers, else Go's own default: `GOCACHE` from the environment, else `~/Library/Caches/go-build` on macOS and `${XDG_CACHE_HOME:-~/.cache}/go-build` elsewhere.
  `GOCACHE` off or empty, or no directory there, is no Go build cache: nothing to do and no failure.
- **Only Go's**: a directory of this user's whose `README` begins with Go's own first line, `This directory holds cached build artifacts from the Go build system.`.
  Any other is never trimmed: the run says `team-janitor: <path> is not a Go build cache (no Go README); not trimmed` and exits 1, so a misread `GOCACHE` never empties another directory.
- **The cap**: 10 GiB, by `du`; at or under it the run removes nothing and prints nothing.
- **The trim**: over the cap, the oldest entries by mtime first, until the cache is at or under 8 GiB, 80% of the cap, so the next build does not trip it again.
  An entry is a real file or directory named `<hex>-a` or `<hex>-d` directly in a real two-hex directory, never reached through a link; `README`, `trim.txt`, `testexpire.txt` and anything else are never removed.
  A file goes with `rm -f`, a directory made writable first with `rm -rf --one-file-system`.
- **Kept always**: an entry modified in the last 2 hours, since Go refreshes a used entry's mtime at most once an hour, so a build running now holds those; Go reads a missing entry as a cache miss and rebuilds it.
- When what is left is still over the cap, every older entry gone, the run says so once a local day, which is no failure; the day it said so is in the record, so the heartbeat log does not repeat it every run.

Why 10 GiB: a week of the team's ordinary Go use came to 1.3 GiB, while one day of `no-mistakes` work made 21 GiB, and one build's working set is far below 8 GiB, so the cap bounds the disk without making a day's builds cold.
Why a size cap on every run, over a weekly trim or a doctor warning alone: a weekly trim lets a 21 GiB day grow to a week of builds before it acts, a warning only says so, and a trim by size keeps what Go uses now, which `go clean -cache` would throw away.
`-trimpath` at the source, so each `no-mistakes` worktree would stop keeping its own copy, is left to that project: it changes another project's binaries and test paths, and the cap holds whatever the cause.

## What a run says, and where

- Each clearing is one line on stdout, with the tmp's size and the why: `cleared the job tmp of T422's builder 0f178ea8 (9.5 GiB; done and idle 26 h)`.
- Each trim is one line, the newest removed entry's mtime in UTC as its "since": `trimmed the Go build cache /home/d/.cache/go-build from 14.2 GiB to 8.0 GiB: 31204 entries unused since 2026-11-20T03:12Z`.
  The over-cap line is `the Go build cache <path> holds 12.1 GiB, over its 10.0 GiB cap, the rest used in the last 2 h; kept`.
- The job part runs first and the Go part after it, each whatever the other did, so a session list that cannot be read still lets the trim run, and a Go part that fails still lets the job tmps be cleared.
- Each line is also appended, as `- HH:MM <line>` in local time, to `~/.local/state/agent-team/janitor/disk-<local date>.md`, titled `# Disk cleared on <machine>, <date>`; a day with no clearing has no file.
- A clearing that fails is said on stderr (`team-janitor: could not clear <path>: <rm's last line>`), the other jobs go on, and the run exits 1.
- A run that clears and trims nothing prints nothing.
- One run at a time, by a lock on `~/.local/state/agent-team/disk.lock`: a second run says `another team-janitor disk is running; skipped` and exits 0.
- After each run but a dry run, `~/.local/state/agent-team/janitor/disk.json` (`team-disk/1`) records the run and the day's totals, written whole through a temporary file and a rename, so a stopped run leaves the last whole record; the totals start again on a new local date.
- The record's `go` holds the cache's path and size after the run, its cap, the day's trims (`trimmed_today`, entries and kilobytes) and the local date the over-cap line was last said (`over_cap_said`).
- `team-janitor disk --dry-run` prints `would clear` and `would trim` for each line, and clears, trims, writes and locks nothing.
- `team-janitor disk status` (`--json` for `team-disk-status/1`) reads only: the Go build cache measured now against its cap, the day's trims, the job tmps cleared today and their size, and the last run, as `Go build cache 3.2 GiB of its 10.0 GiB cap at /home/d/.cache/go-build; 4 job tmps cleared today (2.1 GiB)`, or `no Go build cache (GOCACHE is off)`, `no Go build cache at <path>` or `no Go build cache at <path> (no Go README)` for its first part.

## The heartbeat's step

- The heartbeat runs `team-janitor disk` on the lease holder at every run, as its `disk` step, right after the `tmp` step and before the inbox step, with no setting and no lease needed by the command itself, which by hand runs on any machine.
- The step never runs on a machine that is off the lease, fenced or offline, as no step on the holder does.
- The step logs each line the command prints (`disk: cleared the job tmp of T422's builder 0f178ea8 (9.5 GiB; done and idle 26 h)`), and nothing on a quiet run.
- A run that fails, or runs past its 180 s and is killed 10 s later, logs `disk: failed: <reason>`, the command's first line on stderr or `timed out after 180 s`; the later steps still run, the heartbeat run exits 1, and 12 failing runs in a row are the `step-disk` alert.
- Why no setting, unlike the Docker janitor: like the `tmp` step it removes only what its rules prove nothing reads again, from this user's home, and Daniel asked for it.

## Test seams

A test runs the real `team-janitor disk` in the bats sandbox, against a fixture jobs tree under the sandbox's `HOME`, never the machine's `~/.claude/jobs`, and a fixture Go build cache, never the machine's:

- the sandbox's stub `claude` answers `agents --json --all`;
- `TEAM_DISK_JOB_IDLE_MINUTES` replaces the 24 hours (1440 minutes), and a test ages a job by its `state.json`'s `updatedAt` or with `touch -d`;
- `TEAM_GO_CACHE` names a fixture Go build cache under the test's directory, its entries aged with `touch -d`, `TEAM_GO_CACHE_CAP_KB` replaces the cap (10485760 kilobytes, the target staying 80% of it) and `TEAM_GO_CACHE_KEEP_MINUTES` the 2 hours (120 minutes);
- the sandbox unsets `GOCACHE` and `GOENV`, so a heartbeat test, whose run has the `disk` step, never reaches a Go build cache the environment names;
- `TEAM_TIMERS_DISK_SECONDS` replaces the heartbeat step's 180 s.
