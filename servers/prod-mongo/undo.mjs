// prod-mongo's undo: what putting one document or one collection back from a dump would change on
// production now, and the command that does it, for Daniel to run in a terminal of their own.
//
//   await prepareUndo({ MongoClient, BSON, value, database, root, shown, scrubbed, input })
//                            the prepare-undo tool's answer's text; throws a Refusal (refusal.mjs)
//                            when the input, the root or the dump is refused or production
//                            cannot be read
//   undoInput                the tool's input schema
//
// The input is a dump's stamp, a collection its manifest lists and, for one document, an id: a
// printable id as the toolkit's answers give it (changes.mjs), or its _id's hex or UUID. Each is
// checked, with the root and the dump (root.mjs), before any connection.
// It reads production through the read user's connection string (`value`), one client per call,
// and never writes there; it never starts mongoimport or mongorestore.
//
// One document: it finds the document in the dump's .bson.gz by its id; reads production's by its
// _id (or, when the dump has none of that id, scans production's collection for it); and compares
// their hashes. An id that names more than one document on either side is refused, and so is the
// dump's document when production has no collection of that name (an import would make it with
// only the _id index) or holds the document's top-level UUID id under another _id (an upsert
// would leave two documents with that id); both refusals point to the collection's undo.
// When the hashes are the same, nothing is written. When production's differs or is gone,
// it writes the dump's document as canonical Extended JSON v2 to undo/<at>/<collection>.json and
// prepares `mongoimport --mode upsert` from that file; when the document is in production only
// (created since the dump), it writes {"_id": <its _id>} there and prepares `--mode delete`.
// A collection: it snapshots production's collection and the dump's, compares them, and prepares
// `mongorestore --nsInclude '<database>.<collection>' --drop --gzip --dir <the dump>`, naming the
// ids it would put back (in the dump only), revert (changed) and lose (in production only), at
// most 50 of each, the index names it would add and drop, and that --drop loses every write since
// the dump. When production already matches the dump, nothing is written.
// Otherwise undo/<at>/report.json (mode 0600, like every file here, in 0700 folders) holds the
// full lists, and the prepared command. Each command is a fenced block that starts with
// `read -rs PROD_URI`, passes the string only as --config=<(printf 'uri: %s\n' "$PROD_URI"), so
// it never reaches an argument list, and names every path from ~/.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { driverReason, stampOf } from "./backup.mjs";
import { answersTo, capped, compareCollections, dumpFiles, entryOf, idList, printableId, readBsonGz, snapshotBsonGz, snapshotCollection, uuid } from "./changes.mjs";
import { count, plural } from "./dump.mjs";
import { Refusal } from "./refusal.mjs";
import { checkRoot, dumpByStamp, stampPattern } from "./root.mjs";

// A collection's name as a file name and a shell word: what Conventioner's names are.
const collectionPattern = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,119}$/;
const idPattern = /^[!-~](?:[ -~]{0,198}[!-~])?$/;
const exact = { promoteValues: false, promoteLongs: false, promoteBuffers: false, bsonRegExp: true };

export const undoInput = {
  type: "object",
  properties: {
    backup: {
      type: "string",
      pattern: stampPattern.source,
      description: "The backup's name, its UTC start as list-backups gives it (2026-11-08T142305Z).",
    },
    collection: {
      type: "string",
      pattern: collectionPattern.source,
      description: "The collection to put back, one the backup holds, as backup and list-backups name them (markets).",
    },
    id: {
      type: "string",
      pattern: idPattern.source,
      description:
        "One document to put back, by its id as this toolkit's answers print it (a UUID, an ObjectId's hex, an integer or sha256:<12 hex>), " +
        "or by its _id's hex or UUID; the whole collection when left out.",
    },
  },
  required: ["backup", "collection"],
  additionalProperties: false,
};

// A path as a shell word for Daniel's terminal: from ~/, the rest quoted when it needs it.
function shellPath(shownPath) {
  const word = (text) => (/^[A-Za-z0-9._/+-]+$/.test(text) ? text : `'${text.replaceAll("'", "'\\''")}'`);
  return shownPath.startsWith("~/") ? `~/${word(shownPath.slice(2))}` : word(shownPath);
}

const config = `--config=<(printf 'uri: %s\\n' "$PROD_URI")`;
const commandBlock = (line) => ["```bash", "read -rs PROD_URI", line, "unset PROD_URI", "```"];
const runIt =
  "Run it in a terminal of your own, pasting the connection string of a user that may write (the read user cannot) at the read -rs prompt; " +
  "<(...) is a pipe, so the string is never in an argument list or a file:";

function checkInput(input) {
  const { backup, collection, id } = input;
  if (typeof backup !== "string") throw new Refusal("backup is required: a backup's name, its UTC start as list-backups gives it (2026-11-08T142305Z)");
  if (typeof collection !== "string" || !collectionPattern.test(collection)) {
    throw new Refusal("collection must be one collection's name, of letters, digits and . _ - only, as backup and list-backups name them");
  }
  if (id !== undefined && (typeof id !== "string" || !idPattern.test(id))) {
    throw new Refusal("id must be one document's id as this toolkit prints it, or its _id's hex or UUID");
  }
}

// The fields that differ between two entries of one document, by the field-name rule.
function fieldsText(production, dump) {
  const documents = (entry) => ({ type: "collection", documents: new Map([["one", entry]]), indexes: [] });
  const { fields, otherFields } = compareCollections(documents(production), documents(dump));
  const named = Object.keys(fields);
  if (otherFields) named.push("other fields");
  return { fields: Object.keys(fields), otherFields, text: named.join(", ") };
}

// The documents of the dump's .bson.gz, or of production's collection, that `given` names, each
// with its BSON bytes.
async function findInDump(bson, given, BSON) {
  const found = [];
  if (!bson) return found;
  await readBsonGz(bson, (doc) => {
    const entry = entryOf(doc, BSON);
    if (answersTo(entry, given)) found.push({ entry, doc: Buffer.from(doc) });
  });
  return found;
}

async function findInCollection(collection, given, BSON) {
  const found = [];
  for await (const raw of collection.find({}, { raw: true })) {
    const doc = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
    const entry = entryOf(doc, BSON);
    if (answersTo(entry, given)) found.push({ entry, doc: Buffer.from(doc) });
  }
  return found;
}

const toCollection = "so prepare the collection's undo instead (prepare-undo with no id)";

// An _id as the answers print it: its own printed form, or the hash of one that has none.
const shownIdOf = (_id, BSON) => printableId(BSON.serialize({ _id }), BSON);

const many = (given, n, where) =>
  new Refusal(`${given} names ${count(n)} documents of the collection ${where}: give the _id's hex or UUID, as the answers print it, instead`);

// The dump's undo folder for this call, undo/<at>/, made now (0700); when another call took this
// second's, it waits for the next second and takes that one.
async function undoFolder(folder, shownFolder) {
  mkdirSync(join(folder, "undo"), { recursive: true, mode: 0o700 });
  for (let tries = 0; ; tries += 1) {
    const now = new Date();
    const at = stampOf(now);
    try {
      mkdirSync(join(folder, "undo", at), { mode: 0o700 });
      return { at, dir: join(folder, "undo", at), shown: `${shownFolder}/undo/${at}` };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (tries >= 2) throw new Refusal(`${shownFolder}/undo/${at} already exists: ask again in a second`);
    }
    await new Promise((resolve) => setTimeout(resolve, 1000 - now.getMilliseconds() + 5));
  }
}

const writeJson = (path, value) => writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: "wx" });

export async function prepareUndo({ MongoClient, BSON, value, database, root, shown, scrubbed, input }) {
  checkInput(input);
  const { backup, collection, id } = input;
  const shownRoot = shown(root);
  const { real, missing, note } = checkRoot(root, { shown });
  if (missing) throw new Refusal(`${shownRoot} does not exist yet, so it holds no backup to undo from`);
  const { stamp, folder, manifest } = dumpByStamp(real, backup, shownRoot);
  const shownFolder = `${shownRoot}/${stamp}`;
  if (manifest.database !== database) throw new Refusal(`${shownFolder} is a dump of ${JSON.stringify(String(manifest.database)).slice(0, 40)}, not of ${database}`);
  const listed = (Array.isArray(manifest.collections) ? manifest.collections : []).find(({ name }) => name === collection);
  if (!listed) throw new Refusal(`${shownFolder} holds no collection ${collection}: its manifest lists ${manifest.collections?.map(({ name }) => name).join(", ") || "none"}`);
  if (listed.type === "view") throw new Refusal(`${collection} is a view, whose dump is its definition only: there is no document to put back`);
  const file = dumpFiles(join(folder, "dump", database)).get(collection);
  if (!file || file.type !== "collection") throw new Refusal(`${shownFolder}'s dump holds no files of ${collection}`);

  const client = new MongoClient(value, { serverSelectionTimeoutMS: 20_000, appName: "prod-mongo" });
  try {
    const lines = id === undefined
      ? await collectionUndo({ client, BSON, database, collection, file, scrubbed, stamp, folder, shownFolder })
      : await documentUndo({ client, BSON, database, collection, file, scrubbed, stamp, folder, shownFolder, id });
    return [...lines, ...(note ? [note] : [])].join("\n");
  } finally {
    await client.close().catch(() => {});
  }
}

async function productionCollection(client, database, collection, scrubbed) {
  try {
    await client.connect();
    const [found] = await client.db(database).listCollections({ name: collection }, { nameOnly: false }).toArray();
    return found;
  } catch (error) {
    throw new Refusal(driverReason(error, scrubbed));
  }
}

async function documentUndo({ client, BSON, database, collection, file, scrubbed, stamp, folder, shownFolder, id }) {
  const inDump = await findInDump(file.bson, id, BSON);
  if (inDump.length > 1) throw many(id, inDump.length, "in the dump");
  const listed = await productionCollection(client, database, collection, scrubbed);
  if (listed && listed.type === "view") throw new Refusal(`production's ${collection} is a view now, so a document cannot be put back into it`);
  const live = client.db(database).collection(collection);

  const [dumped] = inDump;
  if (dumped && !listed) {
    throw new Refusal(`production has no collection ${collection} now, and an import of one document would make it with none of the dump's indexes but _id's, ${toCollection}`);
  }
  let current;
  try {
    if (dumped) {
      const { _id, id: sharedId } = BSON.deserialize(dumped.doc, exact);
      const [raw] = await live.find({ _id }, { raw: true }).limit(1).toArray();
      if (raw) {
        const doc = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
        current = { entry: entryOf(doc, BSON), doc };
      }
      // A document deleted and created again keeps its top-level id under a new _id: an upsert of
      // the dump's would leave two documents with that id, however the document was named.
      if (typeof sharedId === "string" && uuid.test(sharedId)) {
        const [other] = await live.find({ id: sharedId, _id: { $ne: _id } }, { projection: { _id: 1 } }).limit(1).toArray();
        if (other) {
          throw new Refusal(
            `${dumped.entry.id} is the document ${shownIdOf(_id, BSON)} in the dump, but production holds its id under another _id, ${shownIdOf(other._id, BSON)}: ` +
              `putting the dump's document back would leave two documents with that id, ${toCollection}`,
          );
        }
      }
    } else {
      const inProduction = listed ? await findInCollection(live, id, BSON) : [];
      if (inProduction.length > 1) throw many(id, inProduction.length, "in production");
      [current] = inProduction;
    }
  } catch (error) {
    if (error instanceof Refusal) throw error;
    throw new Refusal(driverReason(error, scrubbed));
  }
  if (!dumped && !current) throw new Refusal(`${id} names no document of ${collection}, in the dump or in production`);

  const shownId = (dumped ?? current).entry.id;
  const header = `Undo of one document of ${collection} from ${shownFolder}, prepared for you to run; nothing was written to production:`;
  if (dumped && current && dumped.entry.hash === current.entry.hash) {
    return [`${shownId} in ${collection}: production already matches the dump: nothing to undo, and nothing was written.`];
  }

  const undo = await undoFolder(folder, shownFolder);
  const undoFile = join(undo.dir, `${collection}.json`);
  let state;
  let mode;
  let what;
  let fields = [];
  let otherFields = 0;
  if (dumped) {
    writeFileSync(undoFile, `${BSON.EJSON.stringify(BSON.deserialize(dumped.doc, exact), { relaxed: false })}\n`, { mode: 0o600, flag: "wx" });
    mode = "upsert";
    if (current) {
      state = "changed";
      ({ fields, otherFields, text: what } = fieldsText(current.entry, dumped.entry));
      what = `${shownId}: changed in production since the dump${what ? `, in ${what}` : ""}. The command puts the dump's version back in its place (mongoimport --mode upsert).`;
    } else {
      state = "deleted";
      what = `${shownId}: not in production now, so deleted since the dump. The command inserts the dump's version (mongoimport --mode upsert).`;
    }
  } else {
    const { _id } = BSON.deserialize(current.doc, exact);
    writeFileSync(undoFile, `${BSON.EJSON.stringify({ _id }, { relaxed: false })}\n`, { mode: 0o600, flag: "wx" });
    mode = "delete";
    state = "created";
    what = `${shownId}: in production but not in the dump, so created since it. The command deletes it from production (mongoimport --mode delete, matching its _id).`;
  }
  const shownFile = `${undo.shown}/${collection}.json`;
  const command = `mongoimport ${config} --db ${database} --collection ${collection} --mode ${mode} --file ${shellPath(shownFile)}`;
  writeJson(join(undo.dir, "report.json"), { kind: "document", backup: stamp, at: undo.at, collection, id: shownId, state, fields, otherFields, mode, file: shownFile, command });
  return [header, what, `The file it imports: ${shownFile}`, runIt, ...commandBlock(command)];
}

async function collectionUndo({ client, BSON, database, collection, file, scrubbed, stamp, folder, shownFolder }) {
  const listed = await productionCollection(client, database, collection, scrubbed);
  let production;
  try {
    if (listed?.type === "view") production = { type: "view" };
    else if (listed) {
      const live = client.db(database).collection(collection);
      production = { type: "collection", indexes: (await live.indexes()).map((index) => index.name).sort(), documents: await snapshotCollection(live, BSON) };
    }
  } catch (error) {
    throw new Refusal(driverReason(error, scrubbed));
  }
  const dump = { type: "collection", documents: file.bson ? await snapshotBsonGz(file.bson, BSON) : new Map(), indexes: file.indexes };
  const comparison = compareCollections(production, dump);
  const { added, removed, changed, fields, otherFields, indexesAdded, indexesRemoved } = comparison;
  const nothing = production?.type === "collection" && !added.length && !removed.length && !changed.length && !indexesAdded.length && !indexesRemoved.length;
  if (nothing) return [`Production's ${collection} already matches the dump in ${shownFolder}: nothing to undo, and nothing was written.`];

  const undo = await undoFolder(folder, shownFolder);
  const command = `mongorestore ${config} --nsInclude '${database}.${collection}' --drop --gzip --dir ${shellPath(`${shownFolder}/dump`)}`;
  writeJson(join(undo.dir, "report.json"), {
    kind: "collection", backup: stamp, at: undo.at, collection,
    production: comparison.before, dump: comparison.after,
    putBack: added, reverted: changed, lost: removed, fields, otherFields,
    indexesAdded, indexesDropped: indexesRemoved, command,
  });
  const shown = capped(comparison);
  const now = production === undefined ? "Production has no collection of that name now" : production.type === "view" ? "Production's is a view now" : `Production holds ${plural(comparison.before, "document")} now`;
  const named = Object.entries(fields).map(([name, n]) => `${name}: ${count(n)}`);
  if (otherFields) named.push(`other fields: ${count(otherFields)}`);
  const kind = (label, list, extra = "") => `- ${label}: ${count(list.count)}${extra}${list.count ? `: ${idList(list)}` : ""}`;
  const indexLine = [
    indexesAdded.length ? `adds ${indexesAdded.join(", ")}` : "",
    indexesRemoved.length ? `drops ${indexesRemoved.join(", ")}` : "",
  ].filter(Boolean).join("; ");
  return [
    `Undo of the collection ${collection} from ${shownFolder}, prepared for you to run; nothing was written to production:`,
    `${now}, the dump ${plural(comparison.after, "document")}. The restore would:`,
    kind("put back (in the dump only)", shown.added),
    kind("revert (changed since the dump)", shown.changed, named.length ? ` (${named.join(", ")})` : ""),
    kind("lose (in production only, written since the dump)", shown.removed),
    `- indexes: ${indexLine || "the same names as production's"}`,
    `--drop replaces the whole collection: every write to ${collection} since the dump is lost, the ones above and any made before you run it.`,
    `The full lists: ${undo.shown}/report.json`,
    runIt,
    ...commandBlock(command),
  ];
}
