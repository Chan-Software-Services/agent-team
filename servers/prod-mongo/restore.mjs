// What prod-mongo's two container scripts share when they restore a dump into a throwaway
// MongoDB (throwaway.mjs): the restore drill (drill.mjs) and the migration rehearsal (rehearse.mjs).
//
//   restoreLimit             512 MiB: the largest restore a throwaway takes, read from the manifest's
//                            restoredBytes (the database's data and indexes, uncompressed, never the
//                            gzipped dump's size), since tmpfs in the throwaway's 2 GiB cap, beside
//                            mongod's own cache, could not hold much more
//   restorableDump({ root, shown, stamp, database, verb, noun })
//                            the checks a script makes of its dump before Docker is touched: the
//                            root (root.mjs's rules, making nothing), the stamp (a verified dump
//                            directly under the root), the dump's database and its restored size;
//                            { stamp, folder, shownFolder, manifest }, or a Refusal, worded with
//                            `verb` ("drill") and `noun` ("a drill")
//   await restoreTools()     { mongorestore, MongoClient, BSON }: mongorestore's version and the
//                            pinned driver, or a Refusal naming the install
//   await restoreDump({ database, folder, fifo, uri })
//                            runs `mongorestore --config=<fifo> --nsInclude '<database>.*' --gzip
//                            --dir <folder>/dump`, the throwaway's connection string `uri` going
//                            through the FIFO `fifo`, which the caller places in the dump's own
//                            0700 folder; resolves undefined, or the one line saying why the dump
//                            did not restore (mongorestore's last line scrubbed of `uri`); rejects
//                            when mongorestore or mkfifo could not start
import { join } from "node:path";
import { lastLine, runWithConfig, scrubber, toolVersion, yamlConfig } from "./children.mjs";
import { humanBytes, limit } from "./dump.mjs";
import { Refusal } from "./refusal.mjs";
import { checkRoot, dumpByStamp } from "./root.mjs";

export const restoreLimit = 512 * 1024 ** 2;

const mongorestoreTimeoutMs = 20 * 60_000;

export function restorableDump({ root, shown, stamp: given, database, verb, noun }) {
  const shownRoot = shown(root);
  const { real, missing } = checkRoot(root, { shown });
  if (missing) throw new Refusal(`${shownRoot} does not exist yet, so it holds no backup to ${verb}`);
  const { stamp, folder, manifest } = dumpByStamp(real, given, shownRoot);
  const shownFolder = `${shownRoot}/${stamp}`;
  if (manifest.database !== database) throw new Refusal(`${shownFolder} is a dump of ${JSON.stringify(String(manifest.database)).slice(0, 40)}, not of ${database}`);
  const restoredBytes = Number(manifest.totals?.restoredBytes);
  if (!Number.isFinite(restoredBytes) || restoredBytes < 0) throw new Refusal(`${shownFolder}'s manifest gives no restored size`);
  if (restoredBytes > restoreLimit) {
    throw new Refusal(`${shownFolder} restores to ${humanBytes(restoredBytes)} of data and indexes, more than the ${humanBytes(restoreLimit)} ${noun} holds in memory`);
  }
  return { stamp, folder, shownFolder, manifest };
}

export async function restoreTools() {
  const { version: mongorestore, reason } = toolVersion("mongorestore");
  if (reason) throw new Refusal(reason);
  try {
    const { MongoClient, BSON } = await import("mongodb");
    return { mongorestore, MongoClient, BSON };
  } catch {
    throw new Refusal("the pinned MongoDB driver is not installed: run servers/install");
  }
}

export async function restoreDump({ database, folder, fifo, uri }) {
  const scrubbed = scrubber(uri);
  let restored;
  try {
    restored = await runWithConfig(
      "mongorestore",
      (path) => [`--config=${path}`, "--nsInclude", `${database}.*`, "--gzip", "--dir", join(folder, "dump")],
      { fifo, config: yamlConfig("uri", uri), timeoutMs: mongorestoreTimeoutMs },
    );
  } catch (error) {
    if (!error.mkfifo) throw new Error(`mongorestore could not start: ${scrubbed(error.message)}`);
    throw new Error(`mkfifo failed: ${scrubbed(error.message)}`);
  }
  if (restored.fedError) return `mongorestore never read its config: ${scrubbed(restored.fedError.message)}`;
  if (restored.timedOut) return `mongorestore did not finish in ${limit(mongorestoreTimeoutMs)}, so it was killed`;
  if (restored.code !== 0) {
    const why = scrubbed(lastLine(restored.stderr));
    return `mongorestore ${restored.signal ? `was killed (${restored.signal})` : `exited ${restored.code}`}${why ? `: ${why}` : ""}`;
  }
  return undefined;
}
