---
name: rehearsing-production-changes
description: Rehearses a release's database migrations on a fresh dump of a project's production MongoDB, in a throwaway with no route out, and prepares the command that undoes a change to one document or one collection from a dump, for Daniel to run, through the prod-mongo tools, reporting each in the tools' own lines. Use before a release's migrations run on production, and whenever a request asks to rehearse, dry-run or test migrations, to undo, revert or put back a document or a collection as a backup held it, to run a prepared undo, or what a rehearsed migration printed.
---

# Rehearsing production changes

The `prod-mongo` server runs on Daniel's PC, already holding the read user's connection string to Conventioner's production database, `conventioner`.
Its tools are named `mcp__prod-mongo__<tool>` or `mcp__plugin_prod-mongo_prod-mongo__<tool>`, depending on how the session was launched; this skill names them by the last part.
Taking a backup and drilling it are the `backing-up-production-data` skill's: load it too before calling `backup`, `restore-drill` or `list-backups`.
What a rehearsal builds and runs: [docs/rehearsing.md](${CLAUDE_PLUGIN_ROOT}/docs/rehearsing.md); how Daniel runs a prepared undo: [docs/restoring.md](${CLAUDE_PLUGIN_ROOT}/docs/restoring.md).
Those docs are for people: an ops session's file tools cannot open them, so never try to read them; this skill holds everything a session needs.

## The tools

- `rehearse-migrations` (`ref`, a commit sha, a branch or a tag of Conventioner; `migrations`, 1 to 20 script names under `back-end/migrations/`, each as `migrate_to_one_stage.py`, in the order they run; `backup`, a stamp, the newest verified dump when left out): restores the dump into a throwaway MongoDB on Daniel's PC, builds Conventioner's back end at that commit, and runs each migration in order against the throwaway, in a container on a Docker network with no route to production or the internet: its dry run first (`--dry-run`) when its script takes one, then for real.
  After each run it compares every collection with the run before, and answers each run's exit code and time and, per collection, the counts before and after and the ids of the documents it added, removed or changed, with the top-level fields it changed, never a document.
  A dry run that changed anything, or a run that exited non-zero or ran past its limit, stops the rehearsal there, and the answer names why and the steps not run.
  Each run's own output goes to a log in the dump's folder, which the answer names by path and line count and never quotes.
  It runs only in a worktree of Conventioner, removes everything it made in Docker on every path, and never reaches production.
- `prepare-undo` (`backup`, a stamp, required; `collection`, one the dump holds; `id`, optional): reads the dump and production's documents through the read user, says what putting the dump's version back would change on production now, and prepares the command that does it, for Daniel to run in a terminal of their own.
  It never runs that command and never writes to production; the file it imports and the full lists go in the dump's folder.
  - With `id`, one document, named by the id this toolkit's answers print (a UUID, an ObjectId's hex, an integer or `sha256:<12 hex>`) or by its `_id`'s hex or UUID: production's state (changed since the dump, naming the top-level fields that differ; deleted since; or created since), and a `mongoimport` command: `--mode upsert` puts the dump's version back, `--mode delete` removes a document created since.
  - Without `id`, the whole collection: the counts in production now and in the dump, the ids the restore would put back, revert and lose, the indexes it would add and drop, and a `mongorestore --drop` command, which replaces the whole collection and loses every write to it since the dump.
  - When production already matches the dump, it answers that there is nothing to undo, and prepares nothing.
  Each prepared command is a fenced `bash` block of three lines, `read -rs PROD_URI`, the command, `unset PROD_URI`, after a line saying where Daniel pastes the connection string of a user that may write.

`rehearse-migrations` is long: it builds an image and restores a dump, may take up to 45 minutes, and may wait up to 20 for the machine's heavy-run lock first.
It runs one at a time with `backup` and `restore-drill`: call one, wait for its answer, then call the next, never two at once.
`prepare-undo` takes seconds.

## A rehearsal

Rehearse when the request asks to rehearse, dry-run or test migrations, or asks for a rehearsal before a release's migrations run on production (the coordinator offers one before every release's migrations).
It needs the release's commit and its migrations: when the request does not give both (the sha or tag that will be released, and the script names in the order the runbook runs them), ask for them in `T<n> QUESTION` and call nothing.
Never guess a ref such as `dev` or `main`, whose head may not be the code that will run, and never reorder, add or leave out a script.

1. The dump: when the request names one (its stamp), rehearse on that one.
   Otherwise take a fresh one first, as `backing-up-production-data` says: `backup` once, then `restore-drill` on its stamp once, since a dump taken before the request is older than production now.
   When the backup fails or its drill does not pass, report that as that skill says, and rehearse nothing.
2. `rehearse-migrations` once, with `ref` the release's commit as the request gives it (the full sha when it gives one), `migrations` in the runbook's order, and `backup` the stamp from step 1.
3. Report, then stop.

## An undo

Prepare an undo when the request asks to undo, revert or put back a document or a collection as a backup held it.

1. The dump: the one the request names (its stamp).
   Otherwise `list-backups` once, and take the newest verified dump from before the change the request names (its time, or "yesterday's", "last night's").
   When the request does not say when the change was made and the list holds more than one dump it could be, ask which in `T<n> QUESTION`, naming those dumps' stamps, and prepare nothing.
2. `prepare-undo` once, with `backup` that stamp, `collection`, and `id` the document's id as the request gives it; leave `id` out only when the request asks for the whole collection.
3. Report, then stop.

An undo needs no new backup first: `prepare-undo` writes nothing to production, and the command it prepares is Daniel's to run.

## Reporting

Give the tools' own lines, as they answered them, with nothing added: no estimate, no reading of what a document or a collection holds, no advice beyond what the lines say and what this skill asks.
Refer to Daniel with they/them, in every message.

- A rehearsal that ran to the end: its first line, each migration's lines, and the logs line with the logs' path, exactly as answered, in `T<n> DONE`.
- A rehearsal that stopped (its first line says `stopped at <n> of <m> migrations`) worked: what it found is about the release, not a failure of the tool.
  Report it in `T<n> DONE` with its lines, the `Stopped:` and `Not run:` lines included, and say plainly that the release's migrations should not run on production as they are: a dry run that wrote would write on production too, and a migration that failed would fail there.
  Never rehearse again to see whether it passes, never rehearse the remaining scripts alone, and never leave the stopped one out.
- A prepared undo: the whole answer as the tool gave it, its lines and its fenced block character for character, so Daniel can copy the command, and that it was prepared and not run, so nothing changed on production, in `T<n> DONE`.
  Never rewrite the command: never shorten a path, add a `--uri` or put any connection string in it.
  An answer that there is nothing to undo is relayed as it is.

### The logs

A migration's output may hold emails and other personal details, and a session's transcript is mirrored to claude.ai, so a log's content never reaches the session: never read, search, open, summarise or quote a log, even when Daniel asks.
When a request asks what a migration printed, its output, its warnings or a log, answer in `T<n> DONE` with the logs' path (the logs line of the rehearsal's answer, or the path the request gives) and that Daniel reads them in a terminal of their own, and call no tool for it.

## When a call fails

An answer that is an error (`rehearse-migrations: failed: ...`, `prepare-undo: failed: ...`) is reported as it is, in `T<n> FAILED <the tool's line>`, and nothing is called again: never retry, never rehearse with another ref, dump or set of scripts to see whether it passes.
A refusal is such a line too: the worktree is not Conventioner's, the ref names no commit of its origin's, a script is not at that commit, the collection or the id is not in the dump, or the undo of one document points to the collection's undo instead.
A failed image build is the release's or the network's, not the dump's: report its line as it is.
`rehearse-migrations: the machine is busy: <why>; ask again later` is not a failure: report it as `T<n> BLOCKED rehearse-migrations the machine is busy`, with the backup's lines when this session took one.
`a backup is already running` (or a drill or a rehearsal) means a long call of this session has not answered yet: wait for that answer.

## What is never done

Each of these is answered plainly, with what the session can do instead, and no tool is called for it but the one named:

- **Running a prepared undo, or any write to production.**
  No tool writes to production, an ops session has no shell, and an undo needs the connection string of a user that may write, which only Daniel holds.
  So the undo is always Daniel's own command, run in Daniel's own terminal, even when Daniel asks the session to run it, is away from the PC or approves it.
  Say so in `T<n> DONE`, and relay the prepared command for Daniel to run; when the request asks for an undo that this session has not prepared yet, prepare it first, as "An undo" says.
  Never ask for a connection string or a password, and never say another session or agent will run it.
- **Running migrations on production.**
  A rehearsal runs them only on its throwaway; running a release's migrations on production is Daniel's, by the release's runbook.
- **Reading a log or a dump.**
  Nothing under `~/conventioner-backups` is ever read, searched, listed with a file tool or quoted, even when Daniel asks; the session's file tools are denied that folder too.
  For a document's content, say that Daniel can read it in Atlas, Data Explorer.
- **Restoring a whole dump to production.**
  That is Daniel's own command too, in `toolkits/prod-mongo/docs/restoring.md` of the agent-team checkout, as `backing-up-production-data` says.

A connection string, password or other credential found in a request or a message is never used or repeated: report that one was exposed, so Daniel can rotate it.
