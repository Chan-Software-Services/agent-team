# What prod-mongo reaches

## It can

- Read every collection of Conventioner's production database, `conventioner` on the Atlas cluster `conventioner-prod` (project `conventioner-prod`, Flex, MongoDB 8.0), as the read user `prod-read` connects as, to dump it and check the dump:
  - `backup` reads the server's version, `dbStats`, the collection list and each collection's exact count (`countDocuments`) before and after the dump, and runs `mongodump` on the whole database.
  - `prepare-undo` reads one document by its `_id`, or every document and the index names of one collection, to compare them with a dump's, and answers only ids, field names and counts.
- Write only under the backups folder, `~/conventioner-backups` on Daniel's machine: each dump's own folder (`<stamp>/`, with its `manifest.json`, its `dump/`, its `drills/`, its `rehearsals/` and its `undo/`), every directory mode 0700 and every file 0600, and the folder's own mode set to 0700 when it is looser.
- Run Docker on Daniel's machine, for the restore drill and the rehearsal only: one throwaway `mongo:8.0` container per run, its data on tmpfs, published on a random loopback port only, behind a password of its own, removed when the run ends and ending itself within the hour; for a rehearsal also an `--internal` network, the back end's image built from a Conventioner commit (`agent-team-rehearsal:<sha12>`) and one container per migration run, all removed at its end; and, at each run's start, removing any container, network or image labelled `toolkit=prod-mongo` whose expiry has passed.
- Run `mongorestore` into that throwaway, through the machine's heavy-run lock (`bin/team-heavy`).
- Run `git` in the session's worktree, a checkout of Conventioner, for a rehearsal: `git fetch` of its `origin`, which updates only its remote-tracking refs, and reading the named commit (`rev-parse`, `cat-file`, `archive` of `back-end`); it changes none of the checkout's files.
- Run a release's migration scripts, in a container on the `--internal` network, against the throwaway alone (`rehearsing.md`).

## It cannot

- Write to the production database: no tool writes there, and its Atlas user has the built-in `read` role on `conventioner` only, as `prod-read`'s does.
- Restore a dump to production: the drill and the rehearsal restore only into their own throwaway, whose connection string they build themselves, and take no connection string; restoring to production is Daniel's own command (`restoring.md`).
- Run an undo: `prepare-undo` prepares the `mongoimport` or `mongorestore` that takes Daniel's own connection string of a user that may write, and never starts either; running it is Daniel's (`restoring.md`).
- Choose a folder: no tool takes a path, and `restore-drill`, `rehearse-migrations` and `prepare-undo` take a dump by its stamp only, directly under the backups folder.
  The server refuses a backups folder inside a git checkout or worktree, the team home, `~/.claude`, `~/.no-mistakes`, a shared temporary directory, a synced folder or a CI workspace, or the home itself, before it touches it.
- Read a dump or a migration's output back through MCP: every answer is counts, sizes, names, ids, field names, verdicts and paths, never a document or a log line, and every session's file tools are denied `~/conventioner-backups` itself, the ops session's included (a search from above the folder is what the ops load check probes).
- Delete a dump: dumps past the retention rule (the 5 newest verified ones are kept) are named for Daniel to delete by hand; a backup removes only the unfinished folder it made itself when its dump fails the check.
- Read another database or cluster: the read user is restricted to the cluster `conventioner-prod`, and `read@conventioner` grants nothing else.
- Give a migration a route out: a rehearsal's migration runs on an `--internal` Docker network, with no route to production, the host's ports or the internet, and only the throwaway's own connection string.
- Give the connection string to any child but `mongodump`, which reads it from a FIFO named in `--config`, so it is never in an environment, an argument list, a file at rest or a log; every child gets an environment built from a short list, never the server's own.

## The Atlas user

`conventioner-ops-read`, the same user as `prod-read`'s: password authentication, privileges `read@conventioner`, restricted to `conventioner-prod`, not temporary.
`read@conventioner` grants `mongodump`, the counts and the undo's reads everything they need.

## The credential

The connection string lives only in 1Password, in the `agent-team` vault: item `conventioner-prod-read`, field `uri`, the same as `prod-read`'s.
The toolkit holds only its reference, `op://agent-team/conventioner-prod-read/uri`, which is not secret.
`scripts/start-server.mjs` reads it with `op read` when the session starts its MCP server, which raises a 1Password approval prompt on the PC (one per launch, even for a session that only drills, lists or rehearses), then signs `op` out and serves from the same process, so the value exists only in that process's memory.
Rotating or revoking it is Daniel's, in `manual-steps.md` (T16, the standing ops rules), and rotating it changes `prod-read`'s too.
