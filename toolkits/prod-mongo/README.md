# prod-mongo

Verified backups of Conventioner's production database, drills that prove they restore, rehearsals of a release's migrations on a dump, and undos of one document or one collection prepared for Daniel to run, for the `ops` role only.
The backups, and everything derived from them, land in `~/conventioner-backups` on Daniel's machine, and every answer is counts, sizes, ids, field names and paths, never a document.
`team-worker` refuses it, the ops load check's launch included, in a worktree of a project whose `toolkits` in `projects.toml` do not list it, so it runs in a worktree of Conventioner, whose database it backs up, once Daniel's yes has put it in that project's line.

## What loads

The MCP tools, from the server's own `tools/list` (`evals/mocks/prod-mongo/_tools.json`), as an ops launch names them:

```text
mcp__prod-mongo__backup
mcp__prod-mongo__list-backups
mcp__prod-mongo__prepare-undo
mcp__prod-mongo__rehearse-migrations
mcp__prod-mongo__restore-drill
```

Nothing else: no tool writes to the database, restores to production, or takes a path or a connection string; `prepare-undo` reads production and prepares the `mongoimport` or `mongorestore` Daniel runs, never running it, and writes the document it would import only into the dump's folder.
The skills are `backing-up-production-data`, for `backup`, `restore-drill` and `list-backups`, and `rehearsing-production-changes`, for `rehearse-migrations` and `prepare-undo` (`skills/`), the only ones this toolkit adds.
This list is the server's, not yet a live session's: the ops load check's inventory (`team-load-check --role ops --toolkit prod-mongo`), once it has run on Daniel's real credential, replaces it.
`docs/access.md` says what the toolkit can and cannot reach; `docs/rehearsing.md` what a rehearsal builds and runs, where its logs are and what its report holds; and `docs/restoring.md`, for Daniel, where the dumps are, how to drill one by hand, how to restore one to production or delete it, and how to run a prepared undo.

## Its credential

The read user's connection string, the same as `prod-read`'s, lives only in 1Password, at `op://agent-team/conventioner-prod-read/uri` (vault `agent-team`, item `conventioner-prod-read`, field `uri`); this toolkit holds the reference, never the value.
Each launch raises one 1Password prompt, even for a session that only drills, lists or rehearses.

## What it runs

- One stdio MCP server, `prod-mongo`, declared in `.mcp.json`: `node @TEAM_CODE@/toolkits/prod-mongo/scripts/start-server.mjs`, with a 90-minute `timeout`, which raises Claude Code's 30-minute idle limit for a long call.
  `team-worker` replaces `@TEAM_CODE@` with its checkout, since Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT}` under `--mcp-config`.
- The launcher holds only the settings (`scripts/settings.mjs`: the name, the reference, the database `conventioner`, the folder `~/conventioner-backups` and the repository whose migrations a rehearsal runs), and calls the body, `servers/prod-mongo/prod-mongo-mcp.mjs`.
  Before it reads the secret, the body checks `mongodump` is on `PATH` (the lock's MongoDB Database Tools, which `team-doctor` names the install of), so no prompt is spent on a launch that cannot back up; it then reads the reference with `op read`, signs `op` out, and keeps the value in its own memory only.
- `backup` connects with the pinned MongoDB driver (`servers/package.json`), counts every collection before and after, and runs `mongodump --config=<fifo> --db conventioner --gzip`, the connection string written once to a FIFO inside the dump's own 0700 folder and unlinked at once, so it is never in an argument list, an environment, a file at rest or a log.
  It then counts the documents in each dumped file and reads its index names, and removes a dump that does not match.
- `list-backups` reads only the folder: no database, no child process.
- `restore-drill` runs `bin/team-heavy run --wait 20 --kind restore-drill -- node scripts/restore-drill.mjs <stamp>`, so a drill queues behind the machine's other heavy runs; the script starts the throwaway MongoDB with `docker` (`servers/prod-mongo/throwaway.mjs`), restores the dump into it with `mongorestore --config=<fifo>`, compares, records, and removes the throwaway, naming each step on its stderr, which the server relays as a progress notification.
  The script reads no credential and takes no connection string.
- `rehearse-migrations` runs only where the server's working directory, the session's worktree, is a checkout of Conventioner: it fetches, resolves the ref to a commit, checks each script is a file under `back-end/migrations/` at it, marks each whose text there holds `--dry-run` as taking a dry run, then runs `bin/team-heavy run --wait 20 --kind rehearsal -- node scripts/rehearse.mjs <stamp> <sha> <script>...` there, and stops it 45 minutes after it starts.
  The script builds the back-end image from `git archive <sha>:back-end` piped to `docker build -` (stopped after 15 minutes), starts the throwaway on an `--internal` Docker network under the alias `mongodb`, restores the dump, and runs each script in order in a container on that network alone, under `timeout 600`, the throwaway's URI in `docker run`'s own environment: with `--dry-run` first where it takes one, then for real; after each run it compares hashes of every collection's documents with those before it (`servers/prod-mongo/changes.mjs`).
  A dry run that changed anything stops the rehearsal before that script's real run, naming the collections and counts it wrote, a run that exits non-zero stops it with its exit code (124 when its `timeout 600` ended it), and one whose `docker run` is still going 30 seconds past that is killed and stops it too; the answer names the steps not run.
  It writes each run's output to `rehearsals/<at>/<n>-<script>.<dry-run|run>.log` and the comparisons to `rehearsals/<at>/report.json` in the dump's folder (mode 0600), answers with counts, ids and field names only, and removes the throwaway, the network and the image, at a stop and on SIGINT, SIGTERM and SIGHUP too.
- `prepare-undo` connects with the driver as `backup` does and only reads: for one document it scans the dump's `.bson.gz` for the id and reads production's document of that `_id` (or scans production's collection for it when the dump has none), and for a collection it hashes every document and reads the index names on both sides (`servers/prod-mongo/undo.mjs`).
  It writes the dump's document as canonical Extended JSON (or its `_id` alone, for a delete) to `undo/<at>/<collection>.json` and the full comparison to `undo/<at>/report.json` in the dump's folder, and answers with a `mongoimport --mode upsert` or `--mode delete`, or a `mongorestore --drop` of the one collection, in a fenced block that reads Daniel's own connection string at a `read -rs` prompt; it starts neither tool, and when production already matches the dump it writes nothing.
- Every child process gets an environment built from a short list (`childEnv`, `servers/prod-mongo/children.mjs`), never the server's own, and every child's error reaches an answer only scrubbed of connection strings, the secret and its hosts.
- Only an ops launch starts it: every other session's settings deny a shell command that runs a `start-server.mjs` (with `node`, `bun`, `deno` or `env`, or by its path, though no file here is executable), one that names the server's body (`servers/prod-mongo/prod-mongo-mcp.mjs`, whose start a `node -e` import could call), the launcher's settings (`scripts/settings.mjs`) or the 1Password read every server body shares (`servers/op-secret.mjs`, whose `readSecrets` takes any reference) after `node`, or behind `env`, `bun` or `deno`, and a `claude` given a production toolkit by `--plugin-dir` or `--mcp-config`; reading the files stays allowed, and the refusal probe (`team-load-check --probe`) proves each worker role's shell is refused the body's import and the 1Password read's.
  These are speed bumps (`tests/repo.bats`): Daniel's rule of approving a 1Password prompt only right after an announced launch is what holds.
- An ops launch takes it alone, beside `prod-read`, or beside `prod-read` and `prod-write`, never beside `vercel-read` (`bin/team-worker`).
  The ops settings (`settings/ops.json`) allow its tools with no prompt.
  The ops-log hook (`bin/hooks/ops-log`) logs each call's requested, ran or failed line in the task's ops log, and blocks a call whose requested line it cannot write, as it does a write.
- Every session's settings (`settings/worker.json`, which every role's layer on, `coordinator.settings.json` and `assistant.settings.json`) deny its file tools the backups folder itself (`Read(~/conventioner-backups/**)` and `Edit(~/conventioner-backups/**)`), and, as a speed bump, its shell a command that names a path in it (`*/conventioner-backups/*`, `*/conventioner-backups` and `*/conventioner-backups *`); the refusal probe proves each worker role's Read in it is refused, and the ops load check the ops role's.
  Whether a Grep from above the folder lists the files in it is not proven by the rules: the ops load check runs one, and a WARN line counts the folder's files it listed, a finding rather than a failure.

## What it leaves behind

- On disk, only under `~/conventioner-backups` (mode 0700): each dump's folder, `<stamp>/`, holding `manifest.json`, `dump/conventioner/` (each collection's `.bson.gz` and `.metadata.json.gz`), `drills/<at>.json`, each drill's verdict, `rehearsals/<at>/`, each rehearsal's logs and `report.json`, and `undo/<at>/`, each prepared undo's `report.json` and, for one document, the file it imports, every directory 0700 and every file 0600.
  A dump that fails its check leaves nothing; a server killed mid-dump may leave a `.<stamp>.partial/`, which `list-backups` names as left unfinished.
  The toolkit never deletes a dump: `backup` and `list-backups` name those past the rule that keeps the 5 newest verified ones, for Daniel to delete by hand.
- In Docker, nothing once a drill ends: its throwaway (`prod-mongo-drill-<hex>`, labelled `owner=agent-team`, `kind=drill`, `toolkit=prod-mongo` and an `expires` an hour on) is removed on every path, on SIGINT, SIGTERM and SIGHUP too, and one whose drill was killed outright ends itself within the hour; the next drill or rehearsal removes any container, network or image of the toolkit past its `expires` (`sops/docker.md`).
  Nothing once a rehearsal ends either: its throwaway (`prod-mongo-rehearsal-<hex>`), its network, its migration containers and its image (`agent-team-rehearsal:<sha12>`) carry the same labels and are removed on the same paths; one the server stops past its 45 minutes is sent TERM, KILL 30 seconds later when it is still running, and then the server removes, by id, each labelled object of the names the script gave before it made them; a rehearsal killed outright otherwise leaves them for the next run to remove once past their `expires`.

## The scripts by hand

`scripts/restore-drill.mjs <stamp> [--text]` is the drill the tool runs, for Daniel or the coordinator, through the same lock:

```bash
~/agent-team/bin/team-heavy run --kind restore-drill -- node ~/agent-team/toolkits/prod-mongo/scripts/restore-drill.mjs <stamp> --text
```

`--text` prints the tool's answer; without it, one JSON object.
`docs/restoring.md` has the rest, and the restore to production and the prepared undo, which only Daniel runs.
`scripts/rehearse.mjs <stamp> <sha> <script>... [--text]` is the rehearsal, run the same way from a Conventioner checkout; `docs/rehearsing.md` has its command.

## Tests and evals

`tests/run toolkits` starts this server exactly as `.mcp.json` declares it, with `op` stubbed, a throwaway MongoDB 8.0 in Docker for production and another to restore into, the lock's Database Tools from the test's own `PATH` (CI's `toolkits` job installs them), and spies on `mongodump`, `mongorestore` and `docker` first on the server's `PATH` (`tests/toolkits/prod-mongo.test.mjs`).
It checks the tool set, each tool's answers and files with their modes, that the connection string never reaches an argument list, an environment, a file or an answer, the backups folder's rules, the drill's container and its removal on every path, and the scripts by hand.
The rehearsal's tests run on a fixture Conventioner repository (a pinned Python back end and migrations that change, leak, write in a dry run, fail and probe the network) and check the answer quotes no log line, that a migration reaches nothing but its throwaway, each stop, and that nothing is left in Docker; the undo's run each prepared command with bash against the "production" MongoDB, as Daniel would, and check it then matches the dump, and that the tool's own call wrote nothing there.
`evals/` holds the skill's eval cases (`claude plugin eval`): each prompt is a rendered ops brief, and every `prod-mongo` call is answered by a fixed mock (`evals/mocks/prod-mongo/`, one case's own under `evals/<case>/mocks/`), never by the real server, which a run starts only with `--allow-real-servers` or `--mocks off`.
`evals/mocks/prod-mongo/_tools.json` is the server's own `tools/list`, which the toolkit test above keeps in step.
Run them against this directory, keeping the report local: `claude plugin eval toolkits/prod-mongo --no-publish`.
Results go to `evals/results/`, which is gitignored.
