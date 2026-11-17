// prod-mongo's restore drill: proves a dump restores, by restoring it into a throwaway local
// MongoDB (throwaway.mjs) and comparing every collection with the dump's manifest.
//
//   await restoreDrill({ argv, database, root })
//                            the body of toolkits/prod-mongo/scripts/restore-drill.mjs: prints one
//                            JSON object on stdout (with --text, drillAnswer's text instead), each
//                            step as it starts on stderr (`restore-drill: <step>`), the
//                            throwaway's name before it starts (`restore-drill: docker objects:
//                            <name>`, heavy.mjs), and exits 0 on PASS, 1 on FAIL, a refusal or a
//                            failure, and 128 plus the signal's number when stopped by SIGINT,
//                            SIGTERM or SIGHUP
//   await drillTool({ input, root, shown, scrubbed, progress })
//                            the restore-drill tool: runs that script through the server's own
//                            checkout's bin/team-heavy, relays each step the script writes on its
//                            stderr (`restore-drill: <step>`) as a progress notification, stops
//                            it 30 minutes after it starts (runHeavy's bound), and answers
//                            { text, isError }
//   drillAnswer(result)      the tool's answer to the script's JSON: { text, isError }
//
// The script takes exactly one argument, a backup's stamp (and --text), never a path or a
// connection string: it reads no credential, so it cannot reach production. Before Docker is
// touched it checks the root (root.mjs's rules), the stamp (a verified dump directly under the
// root), the dump's database and size, and that mongorestore and the driver are installed; each
// failure there is a refusal. Then it removes what an earlier run left past its expiry, starts the
// throwaway, restores the dump into it (restore.mjs's restoreDump, its FIFO in the dump's 0700
// drills/ folder), compares each collection's document count and index names (and each view's
// being there) with the manifest, writes drills/<at>.json (mode 0600, `verdict` PASS or FAIL, the
// name the drill's start stamp) and removes the throwaway, on every path: at the end, on an error,
// and on SIGINT, SIGTERM and SIGHUP. A Docker failure is no verdict on the dump, so it writes no
// record. mongorestore's own output never reaches the JSON but its last line on a failure, scrubbed.
// The JSON forms: { refused }; { failed, stamp, folder, container, removed, cleanup }; and
// { verdict, stamp, folder, at, record, seconds, mongorestore, container, collections,
// restoreError?, removed, cleanup }, every path written from ~/.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { stampOf } from "./backup.mjs";
import { count, dumped, duration, plural } from "./dump.mjs";
import { busyText, checkout, overtimeText, runHeavy, scriptStart, steps } from "./heavy.mjs";
import { Refusal } from "./refusal.mjs";
import { chosenDump, restorableDump, restoreDump, restoreTools } from "./restore.mjs";
import { backupsRoot } from "./root.mjs";
import { expiredLines, removeExpired, removeThrowaway, startThrowaway, throwawayImage, throwawayName } from "./throwaway.mjs";

const script = join(checkout, "toolkits", "prod-mongo", "scripts", "restore-drill.mjs");

// Each step of the script, one line on its stderr, which drillTool relays as a progress
// notification and a person running it by hand reads as it goes.
const { step, names } = steps("restore-drill");

export async function restoreDrill({ argv, database, root: configuredRoot }) {
  const { root, shown } = backupsRoot(configuredRoot);
  const state = { name: undefined, removed: [], stamp: undefined, folder: undefined };

  const failed = (reason, cleanup) => ({
    failed: reason,
    stamp: state.stamp,
    folder: state.folder,
    container: state.name ?? null,
    removed: state.removed,
    cleanup: cleanup ?? null,
  });
  const { rest, print } = scriptStart({
    argv,
    answer: drillAnswer,
    stopped: (signal) => failed(`the drill was stopped (${signal})`, state.name ? removeThrowaway(state.name) : null),
  });

  let result;
  try {
    result = await drill({ rest, database, root, shown, state });
  } catch (error) {
    if (error instanceof Refusal) result = { refused: error.message };
    else {
      const cleanup = state.name ? removeThrowaway(state.name) : null;
      result = failed(String(error?.message ?? error), cleanup);
    }
  }
  print(result);
  process.exit(result.verdict === "PASS" ? 0 : 1);
}

async function drill({ rest, database, root, shown, state }) {
  if (rest.length !== 1 || rest[0].startsWith("-")) {
    throw new Refusal("takes exactly one argument, a backup's name, its UTC start as 2026-11-08T142305Z (and --text for the answer as text)");
  }
  const { stamp, folder, shownFolder, manifest } = restorableDump({ root, shown, stamp: rest[0], database, verb: "drill", noun: "a drill" });
  Object.assign(state, { stamp, folder: shownFolder });
  const { mongorestore, MongoClient } = await restoreTools();

  // Docker from here on.
  const started = Date.now();
  const at = stampOf(new Date(started));
  const drills = join(folder, "drills");
  const recordPath = join(drills, `${at}.json`);
  if (existsSync(recordPath)) throw new Refusal(`${shownFolder}/drills/${at}.json already exists: ask again in a second`);
  step("removing what earlier drills left past their expiry");
  state.removed = removeExpired(started);
  state.name = throwawayName("drill");
  names([state.name]);
  step("starting the throwaway MongoDB");
  const throwaway = await startThrowaway({ name: state.name, kind: "drill", MongoClient });

  mkdirSync(drills, { recursive: true, mode: 0o700 });
  step("restoring the dump");
  const restoreError = await restoreDump({ database, folder, fifo: join(drills, `.${at}.config.fifo`), uri: throwaway.uri });

  step("comparing each collection with the manifest");
  const collections = await compare(throwaway.client, database, manifest);
  const verdict = !restoreError && collections.every(({ match }) => match) ? "PASS" : "FAIL";
  step("removing the throwaway MongoDB");
  const cleanup = await throwaway.stop();
  state.name = undefined;
  const ended = Date.now();
  const record = {
    verdict,
    at,
    stamp,
    started: new Date(started).toISOString(),
    ended: new Date(ended).toISOString(),
    mongorestore,
    image: throwawayImage,
    ...(restoreError ? { restoreError } : {}),
    collections,
  };
  writeFileSync(recordPath, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  return {
    verdict,
    stamp,
    folder: shownFolder,
    at,
    record: `${shownFolder}/drills/${at}.json`,
    seconds: Math.round((ended - started) / 1000),
    mongorestore,
    container: throwaway.name,
    collections,
    ...(restoreError ? { restoreError } : {}),
    removed: state.removed,
    cleanup,
  };
}

// Each manifest entry against what the throwaway holds, then anything it holds the manifest does
// not name.
async function compare(client, database, manifest) {
  const db = client.db(database);
  const listed = (await db.listCollections({}, { nameOnly: false }).toArray()).filter(({ name }) => dumped(name));
  const restored = new Map();
  for (const { name, type } of listed) {
    if (type === "view") restored.set(name, { type: "view" });
    else {
      const indexes = (await db.collection(name).indexes()).map((index) => index.name).sort();
      restored.set(name, { type: "collection", documents: await db.collection(name).countDocuments({}), indexes });
    }
  }
  const entries = (Array.isArray(manifest.collections) ? manifest.collections : []).map(({ name, type, dumped: documents, indexes }) => {
    const expected = type === "view" ? { type: "view" } : { type: "collection", documents, indexes: [...(indexes ?? [])].sort() };
    const found = restored.get(name) ?? null;
    restored.delete(name);
    const match =
      found !== null &&
      found.type === expected.type &&
      (expected.type === "view" || (found.documents === expected.documents && found.indexes.join("\n") === expected.indexes.join("\n")));
    return { name, expected, restored: found, match };
  });
  for (const [name, found] of restored) entries.push({ name, expected: null, restored: found, match: false });
  return entries;
}

export async function drillTool({ input, root, shown, scrubbed, progress }) {
  const { stamp, note } = chosenDump({ root, shown, stamp: input.backup, verb: "drill" });

  progress(`drilling ${stamp}, through the machine's heavy-run lock`);
  const { busy, overtime, result } = await runHeavy({
    tool: "restore-drill", kind: "restore-drill", noun: "drill", script, args: [stamp], label: `prod-mongo restore-drill ${stamp}`, boundMinutes: 30, progress, scrubbed,
  });
  if (busy !== undefined) return { text: busyText("restore-drill", busy), isError: true };
  if (overtime) return { text: overtimeText("restore-drill", "drill", overtime), isError: true };
  const answer = drillAnswer(result);
  return note ? { ...answer, text: `${answer.text}\n${note}` } : answer;
}

function kindsOf(entries) {
  const collections = entries.filter(({ type }) => type === "collection").length;
  const views = entries.filter(({ type }) => type === "view").length;
  return [plural(collections, "collection"), ...(views ? [plural(views, "view")] : [])].join(" and ");
}

function mismatch({ name, expected, restored }) {
  if (expected === null) return `- ${name}: restored, but its manifest does not name it`;
  if (restored === null) return `- ${name}: ${expected.type === "view" ? "the view was" : "it was"} not restored`;
  if (restored.type !== expected.type) return `- ${name}: restored as a ${restored.type}, its manifest says a ${expected.type}`;
  const parts = [];
  if (restored.documents !== expected.documents) parts.push(`${plural(restored.documents, "document")} restored, ${count(expected.documents ?? 0)} in its manifest`);
  if (restored.indexes.join("\n") !== expected.indexes.join("\n")) parts.push(`indexes ${restored.indexes.join(", ") || "none"} restored, ${expected.indexes.join(", ") || "none"} in its manifest`);
  return `- ${name}: ${parts.join("; ")}`;
}

function cleanupClause({ container, cleanup }) {
  if (!container || cleanup?.gone) return "nothing was left running";
  return `the throwaway MongoDB ${container} could not be removed (${cleanup?.error ?? "unknown"}), but it ends itself within the hour`;
}

export function drillAnswer(result) {
  if (result.refused) return { text: `restore-drill: failed: ${result.refused}`, isError: true };
  if (result.failed) {
    return { text: [`restore-drill: failed: ${result.failed}, so ${result.folder ?? "the dump"} has no verdict; ${cleanupClause(result)}.`, ...expiredLines(result.removed)].join("\n"), isError: true };
  }
  const { verdict, folder, seconds, mongorestore, collections, restoreError, record } = result;
  const expected = collections.filter(({ expected: e }) => e !== null).map(({ expected: e }) => e);
  const lines = [`Restore drill of ${folder}: ${verdict} in ${duration(seconds * 1000)}, mongorestore ${mongorestore}`];
  if (restoreError) lines.push(`${restoreError}, so the dump did not restore.`);
  const bad = collections.filter(({ match }) => !match);
  if (!bad.length) {
    const documents = expected.reduce((sum, { documents }) => sum + (documents ?? 0), 0);
    lines.push(`${kindsOf(expected)}, ${plural(documents, "document")}, each collection's count and index names as its manifest gives them.`);
  } else {
    lines.push(`${count(bad.length)} of ${count(collections.length)} did not match the manifest:`);
    lines.push(...bad.map(mismatch));
  }
  lines.push(`Recorded in ${record}; ${cleanupClause(result)}.`);
  lines.push(...expiredLines(result.removed));
  return { text: lines.join("\n"), isError: verdict !== "PASS" };
}
