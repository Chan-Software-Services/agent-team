# Integrity checks

For Conventioner's builders, who write and keep the invariants, and for Daniel and the coordinator: where the invariants file lives, its format, the read-only rule every invariant is held to, how the `check-integrity` tool runs them and what its answer gives.
An invariant is a rule the database must always keep, such as "every application names a market that exists" or "no seat is held twice", written as a MongoDB aggregation pipeline whose output documents are the ones that break it.

## Where the file lives

The invariants live in Conventioner's own repository, at `back-end/integrity/invariants.json`, beside the code whose schema they check.
A schema change and the invariants it changes then land in one PR, and the checks follow the code a release deploys.
The toolkit owns the format, the runner and the read-only rule (this page and `servers/prod-mongo/integrity.mjs`); Conventioner owns the invariants.

The tool reads the file at a commit of Conventioner, `origin/main` (what production runs) unless the call names another `ref`, a branch, a tag or a commit's sha.
The ops session's worktree must be a checkout of Conventioner, and the server resolves the ref there as a rehearsal does (`docs/rehearsing.md`, "What it checks first"): it fetches `origin` (a failed fetch is a line in the answer, and a branch is then read as the checkout last fetched it), reads a branch or a tag as origin has it, never a local one, and takes only a commit a branch of origin's holds.
It reads the file with `git show <sha>:back-end/integrity/invariants.json`, so it reads the commit, never the worktree's own files.
A commit that has no such file is answered "No invariants at <sha> (<ref>)", not as a failure.

## The format

JSON, so no Conventioner code ever runs in the server:

```json
{
  "version": 1,
  "invariants": [
    {
      "name": "application-market-exists",
      "description": "Every application names a market that exists.",
      "collection": "applications",
      "pipeline": [
        {"$lookup": {"from": "markets", "localField": "market_id", "foreignField": "id", "as": "market"}},
        {"$match": {"market": {"$size": 0}}}
      ]
    }
  ]
}
```

- `version` is `1`, the one format this toolkit reads.
- `invariants` lists at most 50 invariants, each with exactly these four keys:
  - `name`: 1 to 64 of `a-z`, `0-9` and `-`, unique in the file; the call and the answer name an invariant by it.
  - `description`: one line of 1 to 200 characters, for the people who read the file.
  - `collection`: the collection the pipeline runs on, of letters, digits and `.`, `_` and `-`, never a `system.` one.
  - `pipeline`: 1 to 100 aggregation stages, in Extended JSON v2 (`{"$oid": "..."}`, `{"$date": "2020-01-01T00:00:00Z"}`, `{"$numberLong": "..."}`), so a value of any BSON type can be written.
- No other key is taken, at the top or in an invariant, so a misspelt key is refused rather than ignored.

Each document the pipeline outputs is one violation, so the pipeline ends with the documents that break the rule, not a count of them: a pipeline ending in `$count` fails, with one document, whenever any document reaches that stage.
The tool appends `{"$project": {"_id": 1, "id": 1}}` and `{"$limit": 10001}` to it, so a violation is named by its `_id` and its top-level `id`, and nothing else of it is read.
A violation keeps its own `_id` for its name, so a pipeline that groups documents should give each one back (as the second worked invariant below does) rather than end with the group.

## The read-only rule

The read user cannot write, so this rule is the second guard, not the only one: the tool refuses the whole file, before it connects to production, when any invariant:

- uses a stage, at the top or in a `$lookup`'s, a `$unionWith`'s or a `$facet`'s pipeline, that is not on this allowlist: `$match`, `$lookup`, `$unwind`, `$group`, `$project`, `$addFields`, `$set`, `$unset`, `$count`, `$sort`, `$limit`, `$skip`, `$facet`, `$unionWith`, `$replaceRoot`, `$replaceWith`, `$sortByCount`, `$bucket`;
- holds, anywhere in it, a stage that writes (`$out`, `$merge`) or an operator that runs JavaScript on the server (`$function`, `$accumulator`, `$where`), or a JavaScript value (`{"$code": ...}`).

A refusal names the invariant and the stage, as `the invariant writes-back: its stage 2 is $merge, which writes a collection`, or, for an operator inside a stage, `its stage 1 ($project) holds $function, which runs JavaScript on the server`.
A malformed file (not JSON, a key or a value outside the format, a pipeline that is not Extended JSON v2) is refused the same way, naming what is wrong.
Either way nothing is checked, and the file is Conventioner's to fix.

## How the tool runs them

- Input: `ref` (`origin/main` when left out) and `invariants`, the names of the ones to run (every one in the file when left out); a name the file lacks is refused, naming the ones it has.
- It connects to production once per call, with the read user's connection string, and runs each invariant in the file's order: its pipeline, then the two stages above, with `maxTimeMS` 60,000, so one invariant is stopped after a minute.
- It reads each violation with the driver's raw form and decodes only its printable id, so no document is ever turned into text.
- An invariant that errors (a pipeline the server rejects, a value that cannot be converted, one that runs past its minute) is named with the server's code name and its message, with every connection string and everything from its first `{` removed and every quoted value blanked but an operator's name, since such a message may quote a document's value; the other invariants still run, and the answer is then an error.
- It takes no lock, writes no file, and the backups folder is never touched.

## The answer

```text
Integrity of conventioner on production by back-end/integrity/invariants.json at 1a2b3c4d5e6f (origin/main): 2 of 4 invariants failed
- application-market-exists: FAIL: 2 documents: 65f0c1d2e3a4b5c6d7e8f901, 65f0c1d2e3a4b5c6d7e8f902
- market-city-unique: FAIL: 2 documents: 3f2c9a6e-1b2d-4c3e-9f4a-5b6c7d8e9f01, 8a7b6c5d-4e3f-4a1b-9c2d-0e1f2a3b4c5d
- market-has-stalls: PASS
- seat-assigned: PASS (production has no collection seats)
```

- The first line names the commit read, by its first 12 hex digits and the ref as given, and the verdict.
- Each invariant gets one line: `PASS`; `FAIL` with the count and at most 50 ids, sorted, then "and <n> more"; or `ERROR` with the reason above.
- At 10,001 violations the read stops, and the count is given as `>10,000`, with 50 ids "and more".
- An invariant on a collection production does not have passes, and its line says so, since a misspelt collection would otherwise pass in silence.

### Printable ids

Every id the answer gives is the toolkit's printable id, the same as every other tool's (`servers/prod-mongo/changes.mjs`):

- the document's top-level `id` when it is a UUID-shaped string, the id Conventioner's runbooks query by;
- else its `_id`, when that is an ObjectId (as its hex), a UUID-shaped string, an integer, or a document whose keys are plain field names and whose values are each one of those;
- else `sha256:<12 hex>` of the `_id`'s canonical Extended JSON, so an email address or a name used as a key never reaches a transcript.
  Daniel finds such a document in Atlas by hashing the candidates the same way, or by the invariant's own pipeline run there.

## Two worked invariants

A reference that must exist: every application names a market by the market's top-level `id`, and that market must be there.
`$lookup` gives each application its matching markets, and the ones with none are the violations, each named by the application's own id:

```json
{
  "name": "application-market-exists",
  "description": "Every application names a market that exists.",
  "collection": "applications",
  "pipeline": [
    {"$lookup": {"from": "markets", "localField": "market_id", "foreignField": "id", "as": "market"}},
    {"$match": {"market": {"$size": 0}}}
  ]
}
```

A value that must be unique: no two markets share a city.
`$group` gathers the markets of each city, keeping each one's `_id` and `id`, `$match` keeps the cities with more than one, and `$unwind` and `$replaceRoot` give back each market of those cities as one violation, so the answer names every market involved, not the city:

```json
{
  "name": "market-city-unique",
  "description": "No two markets share a city.",
  "collection": "markets",
  "pipeline": [
    {"$group": {"_id": "$city", "markets": {"$push": {"_id": "$_id", "id": "$id"}}, "n": {"$sum": 1}}},
    {"$match": {"n": {"$gt": 1}}},
    {"$unwind": "$markets"},
    {"$replaceRoot": {"newRoot": "$markets"}}
  ]
}
```

Both are in the toolkit test's fixture file (`tests/toolkits/prod-mongo.test.mjs`, `fixtureInvariants`), which runs them on a seeded database.
To try a new invariant before it is committed, run its pipeline read-only in Atlas's Data Explorer, or commit it on a branch of Conventioner's and ask for a check at that branch.
