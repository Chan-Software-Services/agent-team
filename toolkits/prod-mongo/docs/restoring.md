# Restoring a prod-mongo backup

For Daniel: where the toolkit's dumps are, how to prove one restores, and how to put one, or one document or collection of one, back on production yourself.
No agent restores to production or runs an undo: the toolkit has no tool that writes there, and the commands below, and the ones `prepare-undo` prepares, are yours to run in your own terminal.

## Where the dumps are

Every dump the `backup` tool takes is a folder of its own under `~/conventioner-backups/`, named for the UTC time it started (`2026-11-08T142305Z`).
The folder and everything in it are yours alone: every directory is mode 0700 and every file 0600.

```text
~/conventioner-backups/<stamp>/
  manifest.json                  the backup's counts before, after and in the dump, its sizes and index names
  dump/conventioner/             mongodump's output: <collection>.bson.gz and <collection>.metadata.json.gz
  drills/<at>.json               each restore drill's verdict (PASS or FAIL) and its counts, named for its own start
  rehearsals/<at>/               each rehearsal's logs, <n>-<script>.<dry-run|run>.log, and its report.json (rehearsing.md)
  undo/<at>/                     each prepared undo's report.json, and for one document the file it imports, <collection>.json
```

A folder holds a `manifest.json` with `verified: true` only when the dump passed its backup's check, each collection's count in the dump matching the database's or the collection changing during the dump; a dump that failed it was removed by the backup that took it.
Anything else in `~/conventioner-backups/` (a dump you made by hand, a `.<stamp>.partial/` a killed backup left) is listed by `list-backups` by name and size, as "not taken by this toolkit" or "left unfinished".

The dump is not one moment in time: Atlas Flex refuses `mongodump --oplog`, so a collection written during the dump may hold writes from its middle.
The manifest says which: a collection whose counts before and after differ is `changed`.

## Proving a dump restores

The `restore-drill` tool, or the same script by hand, restores a dump into a throwaway local MongoDB and compares each collection's document count and index names (and each view's being there) with the manifest.
The throwaway is the pinned `mongo:8.0` image, its data on tmpfs (never a Docker volume or the disk), on a random loopback port only, behind a password the drill makes up and never puts in an argument list.
It is removed at the drill's end, on an error and on Ctrl-C; one whose drill was killed outright ends itself within the hour.
The verdict is recorded as `drills/<at>.json` in the dump's folder, and `list-backups` shows each dump's newest.

By hand, through the machine's heavy-run lock, with Docker running and the lock's Database Tools on your `PATH` (`team-doctor` names their install):

```bash
~/agent-team/bin/team-heavy run --kind restore-drill -- node ~/agent-team/toolkits/prod-mongo/scripts/restore-drill.mjs <stamp> --text
```

`--text` prints the tool's answer; without it the script prints one JSON object.
Either way it names each step on stderr as it starts (`restore-drill: restoring the dump`).
It exits 0 on `PASS` and 1 on `FAIL` or a refusal; stopped by Ctrl-C, it removes its throwaway and records no verdict.
It takes only the stamp, never a path or a connection string, and never reaches production.
A dump whose database held more than 512 MiB of data and indexes, uncompressed, when it was taken (its manifest's `restoredBytes`) is refused, since the throwaway's 2 GiB memory could not hold it restored; the gzipped dump on disk is smaller.

## Restoring to production

Restoring overwrites production with the dump: every write since the dump in the collections it restores is lost.
Run it only with the release or the fix it rolls back understood, and from a terminal of your own.

The command takes the connection string of a user that may write (the read user the toolkit uses cannot), which you type or paste at the `read -rs` prompt.
`printf` is bash's own, and `<(...)` is a pipe, so the string is never in a process's argument list, where `ps` could read it, and never in a file:

```bash
read -rs PROD_URI
mongorestore --config=<(printf 'uri: %s\n' "$PROD_URI") --nsInclude 'conventioner.*' --drop --gzip --dir ~/conventioner-backups/<stamp>/dump
unset PROD_URI
```

To restore one collection only, name it in `--nsInclude`: `--nsInclude 'conventioner.<collection>'`.
To see what it would do first, add `--dryRun`, which reads the dump and restores nothing.

What `--drop` does and does not do:

- It drops each collection the dump holds (that `--nsInclude` matches) before restoring it, so that collection ends exactly as it was dumped, its indexes included.
- It does not drop a collection the dump does not hold: one created since the dump stays as it is.
- Without `--drop`, `mongorestore` only inserts: a document whose `_id` is already there is not overwritten, so a changed document keeps its change.
- A dump restores only into the same major version (MongoDB 8.0, as the manifest's `server` says).

## Running a prepared undo

The `prepare-undo` tool takes a dump, a collection and, for one document, its id, and prepares the command that puts that document or that whole collection back as the dump holds it.
It reads production through the read user to say what the command would change there, and writes nothing to production; the ops session relays its answer, the command in a fenced block, and never runs it.
The command takes the connection string of a user that may write, at the same `read -rs` prompt as the restore above, and names every file from `~/`, so you paste the block as it is:

```bash
read -rs PROD_URI
mongoimport --config=<(printf 'uri: %s\n' "$PROD_URI") --db conventioner --collection markets --mode upsert --file ~/conventioner-backups/<stamp>/undo/<at>/markets.json
unset PROD_URI
```

The answer says what production holds as the tool read it: when production may have changed since, ask for the undo again before you run it, rather than running an old one.
Each undo's `undo/<at>/report.json` holds its whole comparison and its command; `list-backups` counts each dump's undos.
`mongoimport` is one of the lock's Database Tools, which `team-doctor` names the install of, beside `mongodump` and `mongorestore`.

### One document

The tool finds the document in the dump by its id (the id the toolkit's answers print, or its `_id`'s hex or UUID) and compares it with production's document of the same `_id`:

- **Changed since the dump** (the answer names the top-level fields that differ) or **deleted since**: it writes the dump's document to `undo/<at>/<collection>.json` as canonical Extended JSON, every type spelled out, and prepares `mongoimport --mode upsert` from it, which replaces production's document of that `_id` with the dump's whole document, or inserts it when it is gone.
- **Created since the dump** (in production, not in the dump): it writes `{"_id": ...}` alone to that file and prepares `mongoimport --mode delete`, which deletes production's document of that `_id`.
- **The same in both**: it answers that there is nothing to undo, and prepares and writes nothing.

It refuses, preparing and writing nothing, when the id names more than one document in the dump or in production, and when putting the dump's document back would not leave production as the dump holds it, pointing to the collection's undo instead:

- production has no collection of that name now, so an import would make it with none of the dump's indexes but `_id`'s;
- production holds the document's top-level `id` under another `_id` (it was deleted and created again), so an upsert would leave two documents with that `id`.

Only that one document changes: a write since the dump to any other document stays.

### A whole collection

Without an id, the tool compares the whole collection in production with the dump's and prepares the restore of that one collection:

```bash
read -rs PROD_URI
mongorestore --config=<(printf 'uri: %s\n' "$PROD_URI") --nsInclude 'conventioner.<collection>' --drop --gzip --dir ~/conventioner-backups/<stamp>/dump
unset PROD_URI
```

The answer gives the counts in production and in the dump, and the ids the restore would put back (in the dump only), revert (changed since the dump) and lose (in production only, written since the dump), at most 50 of each, with the full lists in its `report.json`, and the index names it would add and drop.
`--drop` replaces the whole collection, as "What `--drop` does and does not do" says: every write to it since the dump is lost, the ones the answer names and any made before you run it.
When production's collection already matches the dump, documents and index names, the answer says there is nothing to undo.

## Deleting a dump

The toolkit never deletes a dump; you do, by hand:

```bash
rm -r ~/conventioner-backups/<stamp>
```

Everything derived from the dump lives in its folder, so this deletes its drills, rehearsals and undos too.

## Retention

The toolkit keeps the 5 newest verified dumps.
`backup` and `list-backups` end with how many dumps the folder holds and name each one past that rule (an unverified one included), for you to delete as above.
