# Rehearsing a release's migrations

For Daniel and the coordinator: what the `rehearse-migrations` tool builds and runs, why a migration in it has no route out, where its logs are and why no session sees them, and what its report holds.
A rehearsal runs a release's migrations on a copy of production restored from a dump, never on production, so you see what they change on the real data before you run them there yourself.

## What you ask for

- `ref`: the Conventioner commit you will release, as a full sha (or a branch or a tag of origin's, resolved to its commit at the call).
- `migrations`: the scripts under `back-end/migrations/` in the order the release's runbook runs them, 1 to 20, each named as `migrate_to_one_stage.py`.
- `backup`: the dump to rehearse on, by its stamp; the newest verified dump when left out.
  The ops skill takes a fresh backup and its drill first unless the request names one, since an older dump is older than production now.

## What it checks first

The ops session's worktree, the server's working directory, must be a checkout of Conventioner (its `origin` names `Chan-Software-Services/Conventioner` or `chanjdaniel/Conventioner` on GitHub).
The check reads `origin`'s URL as the checkout's git config holds it, not where a `url.<base>.insteadOf` rule may send the fetch.
The server fetches `origin` (a failed fetch is a line in the answer, and a branch is then read as the checkout last fetched it), and resolves `ref` as origin has it: a branch of origin's, else a tag of origin's, else a commit's hex, never a local branch or tag, so a stale local `dev` or a moved local tag cannot stand in for origin's.
A tag is read from origin at the call (`git ls-remote`, since git keeps no remote-tracking copy of origin's tags), so it needs origin to be reachable: when origin's tags cannot be listed, a ref that names no branch of origin's is refused, saying so.
It refuses a commit that no branch of origin's holds, so a commit never pushed is not rehearsed, and checks each script is a file under `back-end/migrations/` at that commit.
A script whose text at that commit holds `--dry-run` is marked as taking a dry run.
Each refusal here comes before the heavy-run lock and before Docker is touched.

## What it builds and runs

The server runs `scripts/rehearse.mjs <stamp> <sha> <script>...` through the machine's heavy-run lock (`bin/team-heavy`), waiting up to 20 minutes for it and stopping the run 45 minutes after it starts.
The script reads no credential and takes no connection string, so it cannot reach production.

1. It removes whatever an earlier drill or rehearsal left in Docker past its expiry.
2. It builds the back end's image from the commit's own files, `git archive <sha>:back-end` piped to `docker build -`, so no file is written and the directory's `.dockerignore` applies; the image is `agent-team-rehearsal:<sha12>`, and the build is stopped after 15 minutes.
   The build fetches the image's Python packages, so it needs the network; no data is in it.
3. It creates a Docker network with `--internal`, and starts a throwaway `mongo:8.0` on the default bridge (for its own loopback connection) and on that network under the alias `mongodb`: its data on tmpfs, on a random loopback port only, behind a password of its own.
4. It restores the dump into the throwaway, as a restore drill does, and snapshots every collection: a hash of each document and of each of its top-level fields, and the index names.
5. For each script in order: when it takes a dry run, it runs it with `--dry-run`, snapshots and compares; then it runs it for real, snapshots and compares again.
   Each run is a container of the image on the internal network alone, `timeout 600 python migrations/<script> [--dry-run]`, with 1 GiB of memory, through the image's own entrypoint, and the throwaway's connection string (host `mongodb`) in the `docker` command's environment, never its arguments.
6. It writes the report and removes the throwaway, the network, the migration containers and the image, on every path: at the end, at a stop, on an error, and on Ctrl-C, SIGTERM and SIGHUP.
   Docker's build cache and the base image the build pulled stay: they hold no data, only the back end's layers and Python packages, but take disk space for each new set of requirements, and the toolkit never prunes them.

What stops the rehearsal, at that step, with the steps after it named as not run:

- a dry run that changed anything (it would write on production too), named with the collections and counts it wrote;
- a run that exits non-zero, with its exit code (124 when its `timeout 600` ended it);
- a run whose `docker run` is still going 30 seconds past that limit, which is killed.

Past 45 minutes the server stops the whole run (TERM, then KILL 30 seconds on) and removes, by id, what the script said it would make.
Every object is labelled `owner=agent-team`, `kind=drill`, `toolkit=prod-mongo` and an `expires` an hour on, so a rehearsal killed outright leaves none of them past the next drill or rehearsal (`sops/docker.md`).

## No route out

A migration's container is on the `--internal` network only, which Docker gives no route off the machine: it reaches the throwaway as `mongodb`, and nothing else, not the internet, not the host's loopback ports, not the default bridge, and so never production or another local MongoDB.
The toolkit test proves it with a migration that tries the host's port of its "production" MongoDB, `host.docker.internal`, the bridge's gateway, a public address and a public name, beside a control run of the same probe on the default bridge that reaches its target.

## The logs

Each run's stdout and stderr go to its own log in the dump's folder, `~/conventioner-backups/<stamp>/rehearsals/<at>/<n>-<script>.<dry-run|run>.log`, `<at>` the rehearsal's own UTC start, every directory mode 0700 and every file 0600.
A migration may print emails, names or whole documents, and a session's transcript is mirrored to claude.ai, so a log's content never reaches the session: the answer names each log by its file and its line count, the ops skill never reads or quotes one, and every session's file tools are denied `~/conventioner-backups`.
Read them in a terminal of your own:

```bash
less ~/conventioner-backups/<stamp>/rehearsals/<at>/2-migrate_to_one_stage.py.run.log
```

## The answer

Its first line names the commit, the dump, how many migrations ran (or where it stopped), whether anything was left running and the time taken.
Each migration has a line per run, its exit code and time ("wrote nothing" for a dry run that changed nothing, "changed nothing" for a run), and under it a line per collection that changed: its counts before and after, then the documents added, removed and changed, with the top-level fields changed and how many documents each, the ids of each kind (at most 50, "and <n> more" past that), and the indexes added or removed.
A field whose name is not a plain identifier is counted as "other fields", never named.
Each id is printable: a document's top-level `id` when it is a UUID, else its `_id` when that is an ObjectId's hex, a UUID, an integer or a small document of those; anything else, an email used as a key say, is `sha256:<12 hex>`.
After a stop come a `Stopped:` line and, when steps were left, a `Not run:` line naming them; then the logs' path with each log's line count, and a line for each object of an earlier run removed past its expiry, or for a failed fetch.

## The report

`rehearsals/<at>/report.json` (mode 0600) holds the whole run, with every id list in full:

- `at`, `stamp`, `sha`: the rehearsal's start, the dump and the commit;
- `started`, `ended`: its times, in ISO 8601;
- `mongorestore`: the version that restored the dump, and `image`, the throwaway's MongoDB image;
- `steps`: each run in order, `{ n, script, mode, exit, signal, timedOut, seconds, log, lines, collections }`, `mode` `dry-run` or `run`, `log` its log's file name and `lines` its line count, and `collections` every collection's comparison with the snapshot before it: `{ collection, before, after, added, removed, changed, fields, otherFields, indexesAdded, indexesRemoved }`, plus `created` or `dropped` when the run created or dropped the collection or view;
- `stopped`, when a step stopped the rehearsal: `{ n, script, mode, exit, signal, timedOut, wrote }`, `wrote` true for a dry run that changed something;
- `notRun`: the steps after it, each `{ n, script, mode }`.

`list-backups` counts each dump's rehearsals; deleting the dump (`docs/restoring.md`) deletes them with it.

## By hand

`scripts/rehearse.mjs` is the script the tool runs, for you or the coordinator, from a Conventioner checkout, through the same lock:

```bash
cd <a Conventioner checkout>
~/agent-team/bin/team-heavy run --kind rehearsal -- node ~/agent-team/toolkits/prod-mongo/scripts/rehearse.mjs <stamp> <full sha> <script>... --text
```

It takes the full sha only, never a branch, and does not fetch; `--text` prints the tool's answer, and without it the script prints one JSON object.
It names each step on stderr as it starts (`rehearse-migrations: restoring the dump`), and exits 0 when every migration ran, none stopped it and nothing was left in Docker, 1 otherwise.
