# SOP: the team's temporary files

How the team keeps what its test runs and sessions leave in `/tmp` and `/var/tmp` from filling them.
On Linux `/tmp` is often a memory file system (tmpfs), and on home-pc systemd holds each user to 80% of it, so a few gigabytes of leftovers fail every merge check and test run with "disk quota exceeded".
`team-janitor tmp` is the net: it removes the team's stale leftovers and warns when a memory `/tmp` passes half full.
`~/agent-team/bin/team-janitor --help` is its exact reference, and `bin/lib/tmp.sh` holds its logic.

## The roots

- The sweep reads two roots, `/tmp` and `/var/tmp`, each resolved once with `realpath` (on macOS `/tmp` is a link to `/private/tmp`); a root that is missing is skipped.
- Nothing outside them is ever removed: on macOS the per-user `TMPDIR` under `/var/folders` is left to macOS, which clears it itself.
- A candidate is an entry directly under a root, or directly inside a session tmp (below); the sweep reads no deeper.

## What is removed

An entry is removed only when every rule holds, each checked again on the entry itself (`lstat`) just before the removal:

- **Type**: a real directory or a regular file; a symbolic link, a socket, a device or a pipe never is, whatever it points at.
- **Owner**: the user running the sweep.
- **Name**: one of three rules names it whole.
  - The list: a line of `bin/lib/tmp-leftovers` (below).
  - The task rule: `agent-team-T<n>`, or `t<n>` or `T<n>` followed by `-`, `.` or `_` and at least one more character, when the ledger knows task `T<n>` and it is not open.
    A number the ledger does not know is kept, and so is every such entry when the ledger cannot be read, which the run says once on stderr and which fails nothing.
  - The gate rule: `agent-team-gate-<8 letters, digits or dashes>`, a gate session's tmp.
- **Age**: last modified at least 60 minutes ago, or 24 hours for the gate rule.
  `tests/run` stops a bats file at 40 minutes, and the next rule covers a longer run.
- **Not live**: no process of this user names it, by its full path followed by `/`, a space, a `:`, a line break or the end, in its working directory, its open files (a lock, a pid file), its command line or its environment (`/proc` on Linux, `lsof` and `ps` on macOS).
  The processes are read once, only when an entry passed the rules above; when they cannot be read, nothing is removed and the run exits 1 saying why.
  Each variable of an environment is a line of its own (on macOS each `ps` line is cut at the start of each ` <NAME>=` word), and only the lines that name a path under a root are kept in the run's scratch, so no other value of a process's environment is written there.

A directory is made writable first (`chmod -R`, which changes no link), so a read-only tree such as a Go module cache goes too, then removed with `rm -rf --one-file-system`; a file with `rm -f`.
A removal that fails is said on stderr, the rest of the run goes on, and the run exits 1.
Mktemp's default names (`tmp.XXXXXXXXXX`) are never removed: any program makes them, so they are not provably the team's, and a leak of them is fixed where it is made.
The team's scripts make theirs with `team_mktemp` (`bin/lib/temp-files.sh`), whose one exit handler removes them however the script ends, on TERM, HUP and INT too, so only a kill no trap sees (KILL) leaves one; a script that ends by `exec`, which runs no EXIT trap, removes them first with `team_tmp_clean`.

## The list, and adding a line

`bin/lib/tmp-leftovers` holds the names only the team's test runs make, one line per name: the maker (a project's registry name, or `bats`), one space, then an extended regular expression matched against the whole name, case-sensitively.
`team-janitor` reads it from its own checkout, so the names the net may remove change only through a reviewed PR, never a records edit.

To add a source, add one line to that file in a PR on this repository:

- its expression begins with a literal of at least 6 characters and holds no `|`, since an alternation would match past that literal (`team-janitor tmp` refuses to run with such a line);
- it never matches mktemp's default, nor what systemd, Claude Code, Chrome, Node or pytest keep there (`pytest-of-<user>` keeps three runs by design);
- `tests/repo.bats` holds every line to both, and `tests/team-janitor-tmp.bats` removes a sample of every line.

## The session tmp and task-named scratch

- A session tmp is `agent-team-T<n>`, a task's own session `TMPDIR`, or `agent-team-gate-<8 characters>`, a gate session's, a real directory of this user's directly under the `/tmp` root, never a link.
- A closed task's session tmp is removed whole, read-only trees included, and a gate session's once it is a day old.
- An open task's session tmp is never removed whole: the list alone applies to the entries directly inside it.
- A worker's scratch that must be outside the home directory (a bats `TMPDIR`, a reviewer's test directory) goes under `$TMPDIR` in a confined session, whose `$TMPDIR` is its task's session tmp, since the kernel refuses its removals outside its roots (`$TMPDIR` among them), so bats could not clean up a run directory made anywhere else; that session tmp is removed whole once the task is closed.
- On a machine with no confinement (no Landlock) such scratch is made as `mktemp -d /tmp/T<n>-<what>.XXXXXX`, which the task rule removes once the task is closed, though the worker itself cannot, since `command-guard` refuses its recursive delete outside its worktree and job tmp.
  While the task is open it is kept, so a resumed session finds its files.

## What a run says, and where

- Each removal is one line on stdout, with its size and age and why: `removed /tmp/nm-cli-home-123 (373 MB, untouched 5 h; no-mistakes)`; the last part is the list line's maker, `T367 is closed` for the task rule, or `a gate session's tmp`.
- Each such line is also appended, as `- HH:MM <line>` in local time, to `~/.local/state/agent-team/janitor/tmp-<local date>.md`, whose title names the machine and the date; a day with no removal has no file.
- A run that removes nothing and has no warning to post prints nothing.
- One run at a time, by a lock on `~/.local/state/agent-team/tmp.lock`: a second run says it skipped and exits 0.
- `team-janitor tmp --dry-run` prints `would remove` for each line, and removes, writes and posts nothing.
- `team-janitor tmp status` (`--json` for `team-tmp/1`) reads only: how full `/tmp` is, its five largest entries of this user's, and the day's removals with the day's file.

## The warning

- After its removals, a run reads the `/tmp` root's file system (`findmnt` and `df`) and judges one notice of the `tmp` source in the notice record (`bin/lib/notice.jq`).
- It is judged only on a tmpfs, never on macOS, where `/tmp` is on the disk the janitor's daily disk alert already watches.
- It is wanted at 50% full and over, the file system's own use, well under the 80% quota, and, once it stands, while the use is at least 45%, so a reading that hovers at 50% posts once.
- Its post in `#coordinator` names how full `/tmp` is, the quota when the mount options hold `usrquota`, the largest entries of this user's, and the day's file, mentioning no one.
- It is reminded every 4 hours while it stands, as `/tmp on <machine> is still 61% full ...`, and closes with no post once it is no longer wanted.
- A post Discord refuses fails the run and is tried again at the next.
- To answer it, run `team-janitor tmp status`, look at the largest entries, and add a line to the list for a team source it shows that the net does not yet remove.

## The heartbeat's step

- The heartbeat runs `team-janitor tmp` on the lease holder at every run, as its `tmp` step, after the github step and before the inbox step, with no setting and no lease needed by the command itself.
- The step logs each line the command prints, nothing on a quiet run, and `tmp: failed: <reason>` when it fails or runs past its 120 s, which fails the heartbeat run; 12 failing runs in a row are the `step-tmp` alert.
- By hand it runs on any machine.

## The doctor's line

- `team-doctor`'s `tmp` line reads `team-janitor tmp status --json`: PASS with how full `/tmp` is and the leftovers removed today, or that it is not a memory file system and so not judged.
- It is WARN at 50% and over, with the fix to run `team-janitor tmp status` for the largest entries and `team-janitor tmp` to remove the team's stale leftovers, and WARN when the status does not answer.
- So a nearly full `/tmp` shows on a machine with no heartbeat.

## Test seams

A test runs the real `team-janitor tmp` in the bats sandbox, never against the machine's `/tmp`:

- `TEAM_SYSTEM_ROOT` stands for `/` in both roots;
- `TEAM_TMP_UID` stands for the user's uid, so another owner's entry is shown left alone without root;
- `TEAM_TMP_AGE_MINUTES` replaces the 60 minutes (never the gate rule's 24 hours), and a test ages an entry with `touch -d`;
- `TEAM_TMP_DF` names a file whose one line, `<type> <size bytes> <used bytes> <options>`, is read in place of `findmnt` and `df`;
- `TEAM_TIMERS_TMP_SECONDS` replaces the heartbeat step's 120 s.
