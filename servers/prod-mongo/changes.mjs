// prod-mongo's change engine: what a collection held at one moment, as hashes only, and what
// differs between two such moments. The rehearsal compares the throwaway before and after each
// migration with it; no document is decoded into text on the way.
//
//   await snapshotBsonGz(path, BSON)        the documents of a dump's <collection>.bson.gz
//   await snapshotCollection(collection, BSON)
//                            the documents of a live collection, read with the driver's raw: true
//   await snapshotDatabase(db, BSON)        Map of name to { type, documents, indexes } for every
//                            collection of a live database that mongodump would dump, and
//                            { type: "view" } for a view
//   await snapshotDump(dir, BSON)           the same Map for a dump's database directory
//   dumpFiles(dir)           Map of collection name to { type, bson, indexes } for a dump's database
//                            directory: its type, its .bson.gz file's path (undefined when there is
//                            none) and its index names, from each .metadata.json.gz
//   await readBsonGz(path, visit)           calls visit(doc) with each document's BSON bytes of a
//                            gzipped BSON stream, in order
//   entryOf(doc, BSON)       { key, id, plain, hash, fields } of one document's BSON bytes: its key
//                            in a `documents` Map, its printable id, its _id's own printed form
//                            when it has one (an ObjectId's hex, a UUID, an integer), its hash and
//                            its fields' hashes
//   answersTo(entry, given)  whether a document's entry is the one `given` names: its printable id
//                            or its _id's printed form (an ObjectId's hex in either case)
//   compareCollections(before, after)       what differs between two of those entries (either may
//                            be undefined): { before, after, added, removed, changed, fields,
//                            otherFields, indexesAdded, indexesRemoved, created?, dropped? }; the
//                            counts on each side (null where it was not there or is a view), the
//                            printable ids added, removed and changed, sorted, how many changed
//                            documents changed each top-level field, and the index names
//   compareDatabases(before, after)         [{ collection, ...comparison }] for every collection of
//                            either Map, by name
//   differs(comparison)      whether a comparison holds any change
//   capped(comparison)       the comparison with each id list as { count, ids }, at most idLimit ids
//   changeLine(comparison)   an answer's line for one collection that changed, capped or not
//   changeCounts(comparison) the same line's counts alone, with no id and no leading "- "
//   idList({ count, ids })   a capped id list as an answer prints it: `<ids>` and "and <n> more"
//   printableId(key, BSON)   the one id any tool prints for a document, from `key`, the BSON bytes
//                            of a document holding only its _id and its top-level id
//   fieldName, idLimit       the pattern a field's name is reported by, and 50
//
// A `documents` is a Map from a document's _id (its BSON type and bytes, as base64) to { id, hash,
// fields }: its printable id, a hash of the whole document and a Map of each top-level field's
// name to a hash of its value. A hash is SHA-256 cut to 16 bytes, over the raw BSON bytes.
// A field is named in a comparison only when its name matches fieldName; any other is counted
// under otherFields, so no data-shaped key reaches an answer.
// A printable id is the document's top-level `id` when that is a UUID-shaped string, else its _id
// when that is an ObjectId (as hex), a UUID-shaped string, an integer, or a document whose keys are
// field names and whose values are each one of those; anything else is `sha256:<12 hex>` of its
// canonical Extended JSON, so an email address or a name used as a key is never printed.
// `BSON` is the driver's (`(await import("mongodb")).BSON`), which the caller imports, so a
// machine without the driver gets the caller's own refusal.
import { createHash } from "node:crypto";
import { createReadStream, existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { pipeline } from "node:stream/promises";
import { createGunzip, gunzipSync } from "node:zlib";
import { count, dumped } from "./dump.mjs";

export const fieldName = /^[A-Za-z_][A-Za-z0-9_]{0,63}$/;
export const idLimit = 50;

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const hashOf = (...parts) => {
  const hash = createHash("sha256");
  for (const part of parts) hash.update(part);
  return hash.digest().subarray(0, 16).toString("base64");
};

// The bytes of a BSON value of `type` that starts at `at`.
function valueLength(doc, type, at) {
  switch (type) {
    case 0x01: case 0x09: case 0x11: case 0x12:
      return 8;
    case 0x02: case 0x0d: case 0x0e:
      return 4 + doc.readInt32LE(at);
    case 0x03: case 0x04: case 0x0f:
      return doc.readInt32LE(at);
    case 0x05:
      return 5 + doc.readInt32LE(at);
    case 0x06: case 0x0a: case 0x7f: case 0xff:
      return 0;
    case 0x07:
      return 12;
    case 0x08:
      return 1;
    case 0x0b: {
      const pattern = doc.indexOf(0, at);
      const options = pattern < 0 ? -1 : doc.indexOf(0, pattern + 1);
      if (options < 0) throw new Error("a BSON regular expression does not end");
      return options + 1 - at;
    }
    case 0x0c:
      return 4 + doc.readInt32LE(at) + 12;
    case 0x10:
      return 4;
    case 0x13:
      return 16;
    default:
      throw new Error(`a BSON element has the unknown type ${type}`);
  }
}

// Each top-level element of a BSON document: its type, its name, and where the element and its
// value start and end.
function* elementsOf(doc) {
  if (doc.length < 5 || doc.readInt32LE(0) !== doc.length || doc[doc.length - 1] !== 0) throw new Error("not a BSON document");
  const last = doc.length - 1;
  let at = 4;
  while (at < last) {
    const type = doc[at];
    const nameEnd = doc.indexOf(0, at + 1);
    if (nameEnd < 0 || nameEnd >= last) throw new Error("a BSON element's name does not end");
    const valueStart = nameEnd + 1;
    const length = valueLength(doc, type, valueStart);
    const end = valueStart + length;
    if (length < 0 || end > last) throw new Error("a BSON element runs past its document");
    yield { type, name: doc.toString("utf8", at + 1, nameEnd), start: at, valueStart, end };
    at = end;
  }
}

export function entryOf(doc, BSON) {
  const fields = new Map();
  const keyParts = [];
  let key;
  for (const { type, name, start, valueStart, end } of elementsOf(doc)) {
    const typed = Buffer.from([type]);
    const value = doc.subarray(valueStart, end);
    fields.set(name, hashOf(typed, value));
    if (name === "_id") key = Buffer.concat([typed, value]).toString("base64");
    if (name === "_id" || name === "id") keyParts.push(doc.subarray(start, end));
  }
  const hash = hashOf(doc);
  const head = Buffer.alloc(4);
  const keyDocument = Buffer.concat([head, ...keyParts, Buffer.from([0])]);
  keyDocument.writeInt32LE(keyDocument.length, 0);
  // A collection's documents each have an _id; a stream's document without one is keyed by itself.
  return { key: key ?? `document:${hash}`, ...idsOf(keyDocument, BSON), hash, fields };
}

function add(documents, doc, BSON) {
  const { key, id, hash, fields } = entryOf(doc, BSON);
  documents.set(key, { id, hash, fields });
}

function plainId(value, nested = false) {
  if (typeof value === "string") return uuid.test(value) ? value : undefined;
  if (value === null || typeof value !== "object") return undefined;
  switch (value._bsontype) {
    case "ObjectId":
      return value.toHexString();
    case "Int32":
      return String(value.value);
    case "Long":
      return value.toString();
    case "Double":
      return Number.isInteger(value.value) ? String(value.value) : undefined;
    case undefined: {
      // An embedded document only: a Date or an array is an object too.
      if (nested || Object.getPrototypeOf(value) !== Object.prototype) return undefined;
      const parts = [];
      for (const [name, part] of Object.entries(value)) {
        const plain = plainId(part, true);
        if (plain === undefined || !fieldName.test(name)) return undefined;
        parts.push(`${name}: ${plain}`);
      }
      return `{${parts.join(", ")}}`;
    }
    default:
      return undefined;
  }
}

// The printable id and the _id's own printed form (undefined when it has none) of `key`.
function idsOf(key, BSON) {
  const { _id, id } = BSON.deserialize(key, { promoteValues: false, promoteLongs: false });
  const plain = plainId(_id);
  if (typeof id === "string" && uuid.test(id)) return { id, plain };
  if (plain !== undefined) return { id: plain, plain };
  const canonical = BSON.EJSON.stringify(_id, { relaxed: false }) ?? "";
  return { id: `sha256:${createHash("sha256").update(canonical).digest("hex").slice(0, 12)}`, plain };
}

export function printableId(key, BSON) {
  return idsOf(key, BSON).id;
}

const objectIdHex = /^[0-9a-f]{24}$/i;

export function answersTo({ id, plain }, given) {
  if (given === id || given === plain) return true;
  return objectIdHex.test(given) && plain !== undefined && objectIdHex.test(plain) && given.toLowerCase() === plain;
}

export async function snapshotBsonGz(path, BSON) {
  const documents = new Map();
  await readBsonGz(path, (doc) => add(documents, doc, BSON));
  return documents;
}

export async function readBsonGz(path, visit) {
  let held = [];
  let heldBytes = 0;
  let need = 4;
  await pipeline(createReadStream(path), createGunzip(), async (source) => {
    for await (const chunk of source) {
      held.push(chunk);
      heldBytes += chunk.length;
      while (heldBytes >= need) {
        const bytes = held.length === 1 ? held[0] : Buffer.concat(held);
        const length = bytes.readInt32LE(0);
        if (length < 5) throw new Error(`${path} is not a BSON stream`);
        if (bytes.length < length) {
          held = [bytes];
          need = length;
          break;
        }
        visit(bytes.subarray(0, length));
        const rest = bytes.subarray(length);
        held = rest.length ? [rest] : [];
        heldBytes = rest.length;
        need = 4;
      }
    }
  });
  if (heldBytes > 0) throw new Error(`${path} ends inside a document`);
}

export async function snapshotCollection(collection, BSON) {
  const documents = new Map();
  for await (const doc of collection.find({}, { raw: true })) add(documents, Buffer.isBuffer(doc) ? doc : Buffer.from(doc), BSON);
  return documents;
}

export async function snapshotDatabase(db, BSON) {
  const snapshot = new Map();
  const listed = (await db.listCollections({}, { nameOnly: false }).toArray()).filter(({ name }) => dumped(name));
  for (const { name, type } of listed) {
    if (type === "view") {
      snapshot.set(name, { type: "view" });
      continue;
    }
    const collection = db.collection(name);
    const indexes = (await collection.indexes()).map((index) => index.name).sort();
    snapshot.set(name, { type: "collection", documents: await snapshotCollection(collection, BSON), indexes });
  }
  return snapshot;
}

const metadataSuffix = ".metadata.json.gz";

export function dumpFiles(dir) {
  const files = new Map();
  for (const file of (existsSync(dir) ? readdirSync(dir).sort() : []).filter((name) => name.endsWith(metadataSuffix))) {
    const base = file.slice(0, -metadataSuffix.length);
    const metadata = JSON.parse(gunzipSync(readFileSync(join(dir, file))).toString("utf8"));
    // mongodump escapes a name it cannot use as a file name; the metadata holds it as it is.
    const name = metadata.collectionName ?? base;
    const bson = join(dir, `${base}.bson.gz`);
    files.set(name, {
      type: metadata.type === "view" ? "view" : "collection",
      bson: existsSync(bson) ? bson : undefined,
      indexes: (metadata.indexes ?? []).map((index) => index.name).sort(),
    });
  }
  return files;
}

export async function snapshotDump(dir, BSON) {
  const snapshot = new Map();
  for (const [name, { type, bson, indexes }] of dumpFiles(dir)) {
    if (type === "view") {
      snapshot.set(name, { type: "view" });
      continue;
    }
    snapshot.set(name, { type: "collection", documents: bson ? await snapshotBsonGz(bson, BSON) : new Map(), indexes });
  }
  return snapshot;
}

export function compareCollections(before, after) {
  const was = before?.documents ?? new Map();
  const now = after?.documents ?? new Map();
  const added = [];
  const removed = [];
  const changed = [];
  const fields = {};
  let otherFields = 0;
  for (const [key, entry] of now) {
    const old = was.get(key);
    if (!old) {
      added.push(entry.id);
      continue;
    }
    if (old.hash === entry.hash) continue;
    changed.push(entry.id);
    let other = false;
    for (const name of new Set([...old.fields.keys(), ...entry.fields.keys()])) {
      if (old.fields.get(name) === entry.fields.get(name)) continue;
      if (fieldName.test(name)) fields[name] = (fields[name] ?? 0) + 1;
      else other = true;
    }
    if (other) otherFields += 1;
  }
  for (const [key, entry] of was) {
    if (!now.has(key)) removed.push(entry.id);
  }
  const wasIndexes = before?.indexes ?? [];
  const nowIndexes = after?.indexes ?? [];
  return {
    before: before?.documents ? was.size : null,
    after: after?.documents ? now.size : null,
    added: added.sort(),
    removed: removed.sort(),
    changed: changed.sort(),
    fields: Object.fromEntries(Object.entries(fields).sort(([a], [b]) => (a < b ? -1 : 1))),
    otherFields,
    indexesAdded: nowIndexes.filter((name) => !wasIndexes.includes(name)),
    indexesRemoved: wasIndexes.filter((name) => !nowIndexes.includes(name)),
    ...(before === undefined ? { created: after.type } : {}),
    ...(after === undefined ? { dropped: before.type } : {}),
    ...(before && after && before.type !== after.type ? { dropped: before.type, created: after.type } : {}),
  };
}

export function compareDatabases(before, after) {
  const names = [...new Set([...before.keys(), ...after.keys()])].sort();
  return names.map((collection) => ({ collection, ...compareCollections(before.get(collection), after.get(collection)) }));
}

export const differs = ({ added, removed, changed, indexesAdded, indexesRemoved, created, dropped }) =>
  Boolean(added.length || removed.length || changed.length || indexesAdded.length || indexesRemoved.length || created || dropped);

// An id list as { count, ids }, with at most idLimit ids; one already so is kept.
const cap = (ids) => (Array.isArray(ids) ? { count: ids.length, ids: ids.slice(0, idLimit) } : ids);

export function capped(comparison) {
  return { ...comparison, added: cap(comparison.added), removed: cap(comparison.removed), changed: cap(comparison.changed) };
}

export function idList({ count: total, ids }) {
  const more = total - ids.length;
  return `${ids.join(", ")}${more > 0 ? ` and ${count(more)} more` : ""}`;
}

// `- markets: 12 -> 12, 4 changed (phase: 4): <ids>`, each kind of change after a "; ".
export function changeLine(comparison) {
  return `- ${described(capped(comparison), true)}`;
}

// `markets: 12 -> 12, 4 changed (phase: 4)`: changeLine's counts, with no id.
export function changeCounts(comparison) {
  return described(capped(comparison), false);
}

function described({ collection, before, after, added, removed, changed, fields, otherFields, indexesAdded, indexesRemoved, created, dropped }, withIds) {
  const side = (n) => (n === null ? "none" : count(n));
  const ids = (list) => (withIds ? `: ${idList(list)}` : "");
  const parts = [];
  if (added.count) parts.push(`${count(added.count)} added${ids(added)}`);
  if (removed.count) parts.push(`${count(removed.count)} removed${ids(removed)}`);
  if (changed.count) {
    const named = Object.entries(fields).map(([name, n]) => `${name}: ${count(n)}`);
    if (otherFields) named.push(`other fields: ${count(otherFields)}`);
    parts.push(`${count(changed.count)} changed${named.length ? ` (${named.join(", ")})` : ""}${ids(changed)}`);
  }
  if (indexesAdded.length) parts.push(`indexes added: ${indexesAdded.join(", ")}`);
  if (indexesRemoved.length) parts.push(`indexes removed: ${indexesRemoved.join(", ")}`);
  const whole = [dropped ? `the ${dropped} was dropped` : "", created ? `a ${created} was created` : ""].filter(Boolean).join(" and ");
  return `${collection}: ${whole ? `${whole}, ` : ""}${side(before)} -> ${side(after)}${parts.length ? `, ${parts.join("; ")}` : ""}`;
}
