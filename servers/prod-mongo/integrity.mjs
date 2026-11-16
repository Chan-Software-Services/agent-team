// prod-mongo's integrity check: the project's saved invariants, read from one commit of its
// repository, run read-only against production, each answered PASS or FAIL with the printable ids
// of the documents that break it (changes.mjs), never a document.
//
//   await checkIntegrity({ MongoClient, BSON, value, database, scrubbed, input, progress, repositories })
//                            the check-integrity tool's answer, { text, isError }; throws a Refusal
//                            (refusal.mjs) when the input, the checkout, the ref or the file is
//                            refused, or production cannot be reached
//   integrityInput           the tool's input schema
//   readInvariants(text, EJSON)
//                            { invariants } from the invariants file's text, each { name,
//                            description, collection, pipeline } with the pipeline deserialized
//                            from Extended JSON v2, or { refusal }: the file's format, then the
//                            read-only rule (readOnlyRefusal) for each invariant, by name
//   readOnlyRefusal(pipeline)
//                            why a parsed pipeline could write or run code, naming the stage, or
//                            undefined: the stages $out and $merge, and the operators $function,
//                            $accumulator and $where, anywhere in it, a JavaScript value ($code)
//                            anywhere, and any stage, at the top or in a $lookup's, $unionWith's or
//                            $facet's pipeline, not on `allowedStages`
//   allowedStages, invariantsPath, violationCap
//                            the stages an invariant may use, back-end/integrity/invariants.json,
//                            and 10,000, past which a count is ">10,000"
//
// The file lives in the project's repository, so a schema change and its invariants change in one
// PR; the tool reads it at `ref` (origin/main when left out, what production runs) with `git show
// <sha>:back-end/integrity/invariants.json`, after the same origin check, fetch and ref resolution
// as the rehearsal (repository.mjs's commitOf). A commit with no such file is answered "no
// invariants", not an error. Its format:
//   { "version": 1, "invariants": [{ "name", "description", "collection", "pipeline" }] }
// a name `^[a-z0-9-]{1,64}$` and unique, a description one line of 1 to 200 characters, a collection
// a name of letters, digits and . _ - (not system.*), a pipeline 1 to 100 stages of Extended JSON v2,
// and at most 50 invariants; no other key. Every check of the file and the input comes before any
// connection.
// Each invariant runs on production through the read user, one client per call: its pipeline plus
// {$project: {_id: 1, id: 1}} and {$limit: 10001}, maxTimeMS 60,000, read with the driver's raw:
// true, so each output document, one violation, is never decoded but for its printable id; the
// answer gives at most 50 of them, sorted. A collection production does not have passes, and its
// line says so. An invariant that errors is named with the error's code name and its scrubbed
// message, each quoted value in it blanked, since a server error may quote a document's value;
// the others still run, and the answer is then an error.
import { driverReason } from "./backup.mjs";
import { idLimit, idList, printableId } from "./changes.mjs";
import { count, plural } from "./dump.mjs";
import { Refusal } from "./refusal.mjs";
import { commitOf, git, refPattern } from "./repository.mjs";

export const invariantsPath = "back-end/integrity/invariants.json";
export const violationCap = 10_000;
export const allowedStages = [
  "$match", "$lookup", "$unwind", "$group", "$project", "$addFields", "$set", "$unset", "$count", "$sort", "$limit", "$skip",
  "$facet", "$unionWith", "$replaceRoot", "$replaceWith", "$sortByCount", "$bucket",
];

const namePattern = /^[a-z0-9-]{1,64}$/;
const collectionPattern = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,119}$/;
const mostInvariants = 50;
const mostStages = 100;
const mostBytes = 1024 * 1024;
const maxTimeMS = 60_000;
const allowed = new Set(allowedStages);
// What an invariant may hold nowhere: what writes, and what runs JavaScript on the server.
const refusedAnywhere = new Map([
  ["$out", "writes a collection"],
  ["$merge", "writes a collection"],
  ["$function", "runs JavaScript on the server"],
  ["$accumulator", "runs JavaScript on the server"],
  ["$where", "runs JavaScript on the server"],
  ["$code", "is JavaScript"],
]);

export const integrityInput = {
  type: "object",
  properties: {
    ref: {
      type: "string",
      pattern: refPattern.source,
      description: "The commit of the project's repository to read the invariants file from: a branch, a tag or a commit sha; origin/main, what production runs, when left out.",
    },
    invariants: {
      type: "array",
      items: { type: "string", pattern: namePattern.source },
      minItems: 1,
      maxItems: mostInvariants,
      description: "The invariants to run, by name (application-market-exists); every invariant in the file when left out.",
    },
  },
  additionalProperties: false,
};

const isPlain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

// The first key anywhere in `value` that refusedAnywhere names, or undefined.
function refusedKey(value) {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = refusedKey(item);
      if (found) return found;
    }
    return undefined;
  }
  if (!isPlain(value)) return undefined;
  for (const [key, inner] of Object.entries(value)) {
    if (refusedAnywhere.has(key)) return key;
    const found = refusedKey(inner);
    if (found) return found;
  }
  return undefined;
}

// The pipelines a stage holds, each with the words that name it.
function innerPipelines(name, body) {
  if (name === "$lookup" && isPlain(body) && body.pipeline !== undefined) return [["its pipeline", body.pipeline]];
  if (name === "$unionWith" && isPlain(body) && body.pipeline !== undefined) return [["its pipeline", body.pipeline]];
  if (name === "$facet" && isPlain(body)) return Object.entries(body).map(([facet, pipeline]) => [`its facet ${JSON.stringify(facet).slice(0, 66)}`, pipeline]);
  return [];
}

function pipelineRefusal(pipeline, where) {
  if (!Array.isArray(pipeline)) return `${where} is not an array of stages`;
  for (const [index, stage] of pipeline.entries()) {
    const at = `${where} stage ${index + 1}`;
    if (!isPlain(stage) || Object.keys(stage).length !== 1) return `${at} is not one stage, an object of one key`;
    const [name] = Object.keys(stage);
    const shownName = JSON.stringify(name).slice(1, -1).slice(0, 64);
    if (refusedAnywhere.has(name)) return `${at} is ${shownName}, which ${refusedAnywhere.get(name)}`;
    if (!allowed.has(name)) return `${at} is ${shownName}, which is not on the read-only allowlist of the prod-mongo toolkit's docs/integrity.md`;
    const here = `${at} (${name})`;
    for (const [words, inner] of innerPipelines(name, stage[name])) {
      const refusal = pipelineRefusal(inner, `${here}, ${words}'s`);
      if (refusal) return refusal;
    }
    const key = refusedKey(stage[name]);
    if (key) return `${here} holds ${key}, which ${refusedAnywhere.get(key)}`;
  }
  return undefined;
}

export function readOnlyRefusal(pipeline) {
  return pipelineRefusal(pipeline, "its");
}

const oneLine = (text) => typeof text === "string" && text.trim() !== "" && [...text].length <= 200 && !/[\u0000-\u001f\u007f\u2028\u2029]/.test(text);
const listed = (names) => names.map((name) => JSON.stringify(name).slice(0, 66)).join(", ");

export function readInvariants(text, EJSON) {
  let file;
  try {
    file = JSON.parse(text);
  } catch (error) {
    return { refusal: `it is not JSON (${String(error.message).split("\n")[0].slice(0, 120)})` };
  }
  if (!isPlain(file)) return { refusal: "it is not a JSON object" };
  const extra = Object.keys(file).filter((key) => key !== "version" && key !== "invariants");
  if (extra.length) return { refusal: `it holds ${listed(extra)}, which is not a key of the format (version and invariants)` };
  if (file.version !== 1) return { refusal: `its version is ${JSON.stringify(file.version ?? null).slice(0, 40)}, not 1, the one this toolkit reads` };
  if (!Array.isArray(file.invariants)) return { refusal: "its invariants is not a list" };
  if (file.invariants.length > mostInvariants) return { refusal: `it lists ${count(file.invariants.length)} invariants, more than the ${mostInvariants} a check runs` };

  const invariants = [];
  const seen = new Set();
  for (const [index, invariant] of file.invariants.entries()) {
    const at = `invariant ${index + 1}`;
    if (!isPlain(invariant)) return { refusal: `${at} is not an object` };
    const { name, description, collection, pipeline } = invariant;
    if (typeof name !== "string" || !namePattern.test(name)) return { refusal: `${at}'s name is not 1 to 64 of a-z, 0-9 and -` };
    const named = `the invariant ${name}`;
    if (seen.has(name)) return { refusal: `${named} is named twice` };
    seen.add(name);
    const unknown = Object.keys(invariant).filter((key) => !["name", "description", "collection", "pipeline"].includes(key));
    if (unknown.length) return { refusal: `${named} holds ${listed(unknown)}, which is not a key of an invariant (name, description, collection and pipeline)` };
    if (!oneLine(description)) return { refusal: `${named}'s description is not one line of 1 to 200 characters` };
    if (typeof collection !== "string" || !collectionPattern.test(collection) || collection.startsWith("system.")) {
      return { refusal: `${named}'s collection is not a collection's name, of letters, digits and . _ - only, and not system.*` };
    }
    if (!Array.isArray(pipeline) || pipeline.length < 1 || pipeline.length > mostStages) return { refusal: `${named}'s pipeline is not a list of 1 to ${mostStages} stages` };
    const readOnly = readOnlyRefusal(pipeline);
    if (readOnly) return { refusal: `${named}: ${readOnly}; an invariant only reads` };
    let deserialized;
    try {
      deserialized = EJSON.deserialize(pipeline, { relaxed: false });
    } catch (error) {
      return { refusal: `${named}'s pipeline is not Extended JSON v2 (${String(error?.message ?? error).split("\n")[0].slice(0, 120)})` };
    }
    invariants.push({ name, description, collection, pipeline: deserialized });
  }
  return { invariants };
}

function checkInput(input) {
  const { ref, invariants } = input;
  if (ref !== undefined && (typeof ref !== "string" || !refPattern.test(ref))) throw new Refusal("ref must be a commit sha, a branch or a tag, of letters, digits and . _ / - only");
  if (invariants === undefined) return;
  if (!Array.isArray(invariants) || invariants.length < 1 || invariants.length > mostInvariants || !invariants.every((name) => typeof name === "string" && namePattern.test(name))) {
    throw new Refusal(`invariants must be 1 to ${mostInvariants} invariants' names, each as application-market-exists`);
  }
  const twice = invariants.find((name, index) => invariants.indexOf(name) !== index);
  if (twice) throw new Refusal(`invariants names ${twice} twice`);
}

// An invariant's error as one line: the driver's reason when the database could not be reached or
// refused the user, else the server's code name and its message, scrubbed, each quoted value in it
// blanked but an operator's name.
function errorText(error, scrubbed) {
  if (error?.code === 50 || error?.codeName === "MaxTimeMSExpired") return `it ran past its ${maxTimeMS / 1000} s limit (maxTimeMS), so it was stopped`;
  if (error?.name === "MongoServerSelectionError" || error?.name === "MongoNetworkError" || error?.code === 18 || error?.code === 13) return driverReason(error, scrubbed);
  const message = scrubbed(error?.message ?? error).replace(/'[^']*'|"[^"]*"/g, (quoted) => (/^.\$[A-Za-z]+.$/.test(quoted) ? quoted : `${quoted[0]}...${quoted[0]}`));
  return error?.codeName ? `${error.codeName}: ${message}` : message;
}

export async function checkIntegrity({ MongoClient, BSON, value, database, scrubbed, input, progress, repositories }) {
  checkInput(input);
  const ref = input.ref ?? "origin/main";
  const cwd = process.cwd();
  const { sha, stale } = await commitOf({ cwd, ref, repositories, progress });
  const short = sha.slice(0, 12);
  const read = `${short} (${ref})`;
  const end = (lines) => [...lines, ...(stale ? [stale] : [])].join("\n");

  const kind = git(cwd, ["cat-file", "-t", `${sha}:${invariantsPath}`]);
  if (!kind.ok) return { text: end([`No invariants at ${read}: it holds no ${invariantsPath}, so nothing was checked.`]) };
  if (kind.stdout !== "blob") throw new Refusal(`${invariantsPath} at ${read} is not a file`);
  const size = Number(git(cwd, ["cat-file", "-s", `${sha}:${invariantsPath}`]).stdout);
  if (!(size <= mostBytes)) throw new Refusal(`${invariantsPath} at ${read} is larger than 1 MiB`);
  const shown = git(cwd, ["show", `${sha}:${invariantsPath}`]);
  if (!shown.ok) throw new Refusal(`git show could not read ${invariantsPath} at ${read}`);
  const { invariants: all, refusal } = readInvariants(shown.stdout, BSON.EJSON);
  if (refusal) throw new Refusal(`${invariantsPath} at ${read} is refused, so nothing was checked: ${refusal}`);
  if (!all.length) return { text: end([`No invariants at ${read}: its ${invariantsPath} lists none, so nothing was checked.`]) };
  const missing = (input.invariants ?? []).filter((name) => !all.some((invariant) => invariant.name === name));
  if (missing.length) {
    throw new Refusal(`${invariantsPath} at ${read} has no invariant ${missing.join(" or ")}: it has ${all.map(({ name }) => name).join(", ")}`);
  }
  const chosen = input.invariants ? all.filter(({ name }) => input.invariants.includes(name)) : all;

  const client = new MongoClient(value, { serverSelectionTimeoutMS: 20_000, appName: "prod-mongo" });
  try {
    let collections;
    try {
      await client.connect();
      collections = new Set((await client.db(database).listCollections({}, { nameOnly: true }).toArray()).map(({ name }) => name));
    } catch (error) {
      throw new Refusal(driverReason(error, scrubbed));
    }
    const lines = [];
    let failed = 0;
    let errored = 0;
    for (const [index, { name, collection, pipeline }] of chosen.entries()) {
      progress(`checking ${name} (${index + 1} of ${chosen.length})`);
      let found;
      try {
        const cursor = client.db(database).collection(collection).aggregate([...pipeline, { $project: { _id: 1, id: 1 } }, { $limit: violationCap + 1 }], { maxTimeMS, raw: true });
        found = await cursor.toArray();
      } catch (error) {
        errored += 1;
        lines.push(`- ${name}: ERROR: ${errorText(error, scrubbed)}`);
        continue;
      }
      if (!found.length) {
        lines.push(`- ${name}: PASS${collections.has(collection) ? "" : ` (production has no collection ${collection})`}`);
        continue;
      }
      failed += 1;
      const ids = found.map((doc) => printableId(Buffer.isBuffer(doc) ? doc : Buffer.from(doc), BSON)).sort().slice(0, idLimit);
      const capped = found.length > violationCap;
      const documents = capped ? `>${count(violationCap)} documents` : plural(found.length, "document");
      lines.push(`- ${name}: FAIL: ${documents}: ${capped ? `${ids.join(", ")} and more` : idList({ count: found.length, ids })}`);
    }
    const of = plural(chosen.length, "invariant");
    let verdict;
    if (!failed && !errored) verdict = chosen.length === 1 ? "its 1 invariant passed" : `all ${of} passed`;
    else if (!failed) verdict = `${count(errored)} of ${of} could not run`;
    else verdict = `${count(failed)} of ${of} failed${errored ? `, ${count(errored)} could not run` : ""}`;
    const header = `Integrity of ${database} on production by ${invariantsPath} at ${read}: ${verdict}`;
    return { text: end([header, ...lines]), ...(errored ? { isError: true } : {}) };
  } finally {
    await client.close().catch(() => {});
  }
}
