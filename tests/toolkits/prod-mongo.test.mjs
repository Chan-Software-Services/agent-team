// The prod-mongo toolkit's server as Claude Code starts it from toolkits/prod-mongo/.mcp.json,
// with op stubbed (helpers/op), a throwaway MongoDB 8.0 (helpers/mongo.mjs) in place of
// production, a second one to restore its dumps into, and the lock's Database Tools from the
// test's own PATH (CI's toolkits job installs them into ~/.local/bin). A spy mongodump first on the
// server's PATH records the argument list and environment the server starts it with, then runs the
// real one; files in its directory make it hold after the dump, or lose a collection's documents.
// Spies of mongorestore and docker stand first on its PATH for the restore drill and the migration
// rehearsal, which run through team-heavy (at once under tests/run's heavy-run lock), as the tool
// and by hand. The rehearsal's Conventioner is a fixture git repository the test builds, the
// server's working directory, whose back-end image (a Python image pinned by digest, with a pinned
// pymongo) the rehearsal builds for real, so its first build needs the network. The undo's
// prepared commands are run with bash, as Daniel would, by the lock's mongoimport and mongorestore
// against "production" as a user that may write; spies of both first on the server's PATH prove
// the server never starts either.
// Every backups folder lives under ~/.cache/agent-team-tests/, since a dump of real data is never
// kept in a temporary directory, and is removed when the file exits.
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { accessSync, chmodSync, constants, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { after, before, beforeEach, describe, test } from "node:test";
import { gzipSync } from "node:zlib";
import { roomRefusal, stampOf } from "../../servers/prod-mongo/backup.mjs";
import { capped, changeLine, compareCollections, compareDatabases, differs, fieldName, idLimit, printableId, snapshotBsonGz, snapshotDatabase, snapshotDump } from "../../servers/prod-mongo/changes.mjs";
import { childEnv, scrubber } from "../../servers/prod-mongo/children.mjs";
import { humanBytes } from "../../servers/prod-mongo/dump.mjs";
import { kept } from "../../servers/prod-mongo/list.mjs";
import { checkoutRefusal, rehearsalAnswer, resolveRef } from "../../servers/prod-mongo/rehearse.mjs";
import { restoreLimit } from "../../servers/prod-mongo/restore.mjs";
import { destinationRefusal, dumpByStamp } from "../../servers/prod-mongo/root.mjs";
import { perThreadCaches as throwawayCaches, removeThrowaway, startThrowaway, teamLabel, throwawayImage, throwawayName } from "../../servers/prod-mongo/throwaway.mjs";
import { opStub, repoRoot, startToolkitServer, stubDir, tempDir, testPath } from "./helpers/mcp.mjs";
import { dataOnTmpfs, mongoImage, perThreadCaches, startMongo } from "./helpers/mongo.mjs";
import { owned } from "./helpers/process.mjs";
import { assertNoLeak, evalMockTools, launcherRefusalTests } from "./helpers/toolkit.mjs";

const reference = "op://agent-team/conventioner-prod-read/uri";
// The read user's password, which every connection string the op stub prints carries.
const marker = `pwmarker${randomBytes(8).toString("hex")}`;
const email = `vendor-${randomBytes(4).toString("hex")}@example.com`;
// Each market's top-level id, a UUID, as Conventioner's documents carry beside their _id.
const marketIds = [randomUUID(), randomUUID(), randomUUID()];

// The lock's Database Tools, from this run's PATH.
const toolsDir = (process.env.PATH ?? "").split(delimiter).find((dir) => {
  try {
    accessSync(join(dir, "mongodump"), constants.X_OK);
    accessSync(join(dir, "mongorestore"), constants.X_OK);
    return true;
  } catch {
    return false;
  }
});
if (!toolsDir) throw new Error("mongodump and mongorestore are not on PATH: install the lock's Database Tools (bin/lib/tools.jq's download_sources)");
if (existsSync(join(toolsDir, "op"))) throw new Error(`a real op is beside mongodump, in ${toolsDir}`);
const mongodumpVersion = /^mongodump version: (\S+)$/m.exec(execFileSync(join(toolsDir, "mongodump"), ["--version"], { encoding: "utf8" }))[1];

// Every backups folder and test HOME lives here, under the developer's own home.
const testRoot = join(homedir(), ".cache", "agent-team-tests", `prod-mongo-${randomBytes(6).toString("hex")}`);
mkdirSync(testRoot, { recursive: true, mode: 0o700 });
process.on("exit", () => rmSync(testRoot, { recursive: true, force: true }));
let homes = 0;
const newHome = () => {
  const dir = join(testRoot, `home-${(homes += 1)}`);
  mkdirSync(dir, { mode: 0o700 });
  return dir;
};

// The spy mongodump: it records its argument list, its environment and the kind of file its
// --config names, then runs the real one; with `hold` it waits after the dump until `go` exists
// or its parent, the server, is gone, and with `lose` (collections' names, one per line) it
// empties each one's dump. It runs no command the helpers spy on (cat, head, hostname).
function spyMongodump() {
  const dir = tempDir("mongodump-spy");
  const linux = process.platform === "linux";
  writeFileSync(join(dir, "mongodump"), `#!/bin/sh
dir='${dir}'
real='${join(toolsDir, "mongodump")}'
[ "$1" = --version ] && exec "$real" "$@"
${linux ? `tr '\\0' '\\n' </proc/$$/cmdline >"$dir/cmdline"
tr '\\0' '\\n' </proc/$$/environ >"$dir/environ"` : `ps -ww -o command= -p $$ >"$dir/cmdline"
ps -E -ww -o command= -p $$ >"$dir/environ"`}
config=\${1#--config=}
if [ -p "$config" ]; then echo fifo >"$dir/config-kind"; else echo other >"$dir/config-kind"; fi
"$real" "$@"
status=$?
if [ -f "$dir/lose" ]; then
  while read -r lost; do
    : | gzip >"$(dirname "$config")/dump/conventioner/$lost.bson.gz"
  done <"$dir/lose"
fi
if [ -f "$dir/hold" ]; then
  : >"$dir/held"
  while [ ! -f "$dir/go" ] && kill -0 $PPID 2>/dev/null; do sleep 0.1; done
fi
exit $status
`, { mode: 0o755 });
  const read = (name) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : null);
  return { dir, read, set: (name, text = "") => writeFileSync(join(dir, name), text) };
}

const serverPath = (spy) => (options) => [spy?.dir, toolsDir, testPath(options)].filter(Boolean).join(":");

let production;
let target;
let targetUri;
let home;
let root;
let spy;

before(async () => {
  [production, target] = await Promise.all([startMongo(), startMongo()]);
  await production.createUser("ops-read", marker, [{ role: "read", db: "conventioner" }]);
  const restorer = `restorer${randomBytes(6).toString("hex")}`;
  await target.createUser("restorer", restorer, [{ role: "root", db: "admin" }]);
  targetUri = target.uri("restorer", restorer);
});

after(async () => {
  await Promise.all([production?.stop(), target?.stop()]);
});

beforeEach(async () => {
  await seed();
  home = newHome();
  root = join(home, "conventioner-backups");
  spy = spyMongodump();
});

// "Production": a collection with a unique index and a top-level id beside its _id, one of nested
// documents, an empty one, a view, and one keyed by an email address.
async function seed() {
  await production.seed("conventioner", {
    markets: [
      { id: marketIds[0], name: "Riverside Night Market", city: "Vancouver", stalls: 40 },
      { id: marketIds[1], name: "Harbour Craft Fair", city: "Victoria", stalls: 25 },
      { id: marketIds[2], name: "Lakeside Summer Market", city: "Kelowna", stalls: 15 },
    ],
    applications: Array.from({ length: 5 }, (_, n) => ({
      vendor: { name: `Vendor ${n}`, contact: { phone: `555-010${n}` } },
      booths: [{ size: "10x10", power: n % 2 === 0 }],
    })),
    accounts: [{ _id: email, role: "vendor" }, { _id: `other-${email}`, role: "admin" }],
  });
  const db = production.client.db("conventioner");
  await db.collection("markets").createIndex({ name: 1 }, { unique: true, name: "name_unique" });
  await db.createCollection("archived");
  await db.createCollection("open_markets", { viewOn: "markets", pipeline: [{ $match: { stalls: { $gte: 20 } } }] });
}

// A connection string no call can reach: a tool that answers with it read no database, and a
// refusal given with it came before any connection.
const unreachable = () => `mongodb://ops-read:${marker}@127.0.0.1:1/?authSource=admin&serverSelectionTimeoutMS=2000`;

async function withServer(body, { value = production.uri("ops-read", marker), env = {}, path = serverPath(spy)(), cwd } = {}) {
  const op = opStub({ value });
  const server = startToolkitServer("prod-mongo", { home, opDir: op.dir, path, cwd, env: { PROD_MONGO_ROOT: root, ...env } });
  try {
    await server.initialize();
    await body(server, op);
  } finally {
    await server.close();
    assertNoLeak(server, { marker, home });
  }
}

const backups = () => (existsSync(root) ? readdirSync(root) : []);

// Every path under `dir`, files and directories, with its lstat.
function walk(dir) {
  return readdirSync(dir, { recursive: true }).map((name) => ({ path: join(dir, name), stat: lstatSync(join(dir, name)) }));
}

async function collectionsOf(client) {
  const db = client.db("conventioner");
  const listed = await db.listCollections().toArray();
  const out = {};
  for (const { name, type } of listed.filter(({ name }) => !name.startsWith("system."))) {
    if (type === "view") {
      out[name] = { type };
      continue;
    }
    const indexes = (await db.collection(name).indexes()).map((index) => index.name).sort();
    out[name] = { type, documents: await db.collection(name).countDocuments({}), indexes };
  }
  return out;
}

test("the MCP config names one server, prod-mongo, with no secret, no env and a timeout past the longest call", () => {
  const config = JSON.parse(readFileSync(join(repoRoot, "toolkits", "prod-mongo", ".mcp.json"), "utf8"));
  assert.deepEqual(Object.keys(config.mcpServers), ["prod-mongo"]);
  const { command, args, env, timeout } = config.mcpServers["prod-mongo"];
  assert.equal(command, "node");
  assert.deepEqual(args, ["@TEAM_CODE@/toolkits/prod-mongo/scripts/start-server.mjs"]);
  assert.equal(env, undefined);
  // A rehearsal may wait 20 minutes for the heavy-run lock, then run 45: past Claude Code's
  // 30-minute idle timeout for a stdio call.
  assert.equal(timeout, 90 * 60_000);
});

test("no file of the toolkit or its server is executable", () => {
  for (const dir of [join(repoRoot, "toolkits", "prod-mongo"), join(repoRoot, "servers", "prod-mongo")]) {
    for (const { path, stat } of walk(dir)) {
      if (stat.isFile()) assert.equal(stat.mode & 0o111, 0, `${path} is executable`);
    }
  }
});

test("the tools are backup and list-backups, taking no input, restore-drill, taking a backup's name or nothing, rehearse-migrations and prepare-undo", async () => {
  await withServer(async (server) => {
    const tools = await server.listTools();
    assert.deepEqual(tools.map((tool) => tool.name), ["backup", "list-backups", "restore-drill", "rehearse-migrations", "prepare-undo"]);
    for (const tool of tools.slice(0, 2)) assert.deepEqual(tool.inputSchema, { type: "object", properties: {}, additionalProperties: false }, tool.name);
    assert.equal(tools[1].annotations.readOnlyHint, true);
    const { inputSchema } = tools[2];
    assert.deepEqual(Object.keys(inputSchema.properties), ["backup"]);
    assert.equal(inputSchema.properties.backup.type, "string");
    assert.equal(inputSchema.required, undefined);
    assert.equal(inputSchema.additionalProperties, false);
  });
});

test("the tools are the tools/list the skill's eval mocks give the server", async () => {
  await withServer(async (server) => {
    assert.deepEqual(evalMockTools("prod-mongo", "prod-mongo"), await server.listTools(), "toolkits/prod-mongo/evals/mocks/prod-mongo/_tools.json");
  });
});

describe("backup", () => {
  test("takes a verified dump into a 0700 folder named for its UTC start, and answers its counts from ~/", async () => {
    const start = Date.now();
    let text;
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
      text = result.text;
    });
    const [stamp] = backups();
    assert.deepEqual(backups(), [stamp]);
    assert.match(stamp, /^\d{4}-\d{2}-\d{2}T\d{6}Z$/);
    const startedAt = Date.parse(`${stamp.slice(0, 13)}:${stamp.slice(13, 15)}:${stamp.slice(15, 17)}Z`);
    assert.ok(Math.abs(startedAt - start) < 60_000, `${stamp} is not the call's start`);

    const lines = text.split("\n");
    assert.match(lines[0], new RegExp(`^Backup taken: ~/conventioner-backups/${stamp} \\(\\d+(\\.\\d)? (B|KiB|MiB) on disk, \\d+ s\\), mongodump ${mongodumpVersion.replaceAll(".", "\\.")}$`));
    assert.equal(lines[1], "4 collections and 1 view, 10 documents, each matching the database's count:");
    assert.match(lines.at(-1), /^The folder holds 1 dump \(\d+(\.\d)? (B|KiB|MiB)\); the newest 5 are kept, none is past that\.$/);
    assert.deepEqual(lines.slice(2, -1), [
      "- accounts: 2 documents",
      "- applications: 5 documents",
      "- archived: 0 documents",
      "- markets: 3 documents",
      "- open_markets: a view, its definition only",
    ]);
    assert.ok(!text.includes(home) && !text.includes(homedir()), "the answer names an absolute path");
    assert.ok(!text.includes(email), "the answer holds a document's id");

    const folder = join(root, stamp);
    assert.equal(statSync(root).mode & 0o777, 0o700);
    for (const { path, stat } of [{ path: folder, stat: statSync(folder) }, ...walk(folder)]) {
      if (stat.isDirectory()) assert.equal(stat.mode & 0o777, 0o700, path);
      else {
        assert.ok(stat.isFile(), `${path} is neither a file nor a directory`);
        assert.equal(stat.mode & 0o777, 0o600, path);
      }
    }

    const manifestText = readFileSync(join(folder, "manifest.json"), "utf8");
    const manifest = JSON.parse(manifestText);
    assert.equal(manifest.database, "conventioner");
    assert.equal(manifest.verified, true);
    assert.equal(manifest.mongodump, mongodumpVersion);
    assert.match(manifest.server, /^8\.0\./);
    assert.ok(Date.parse(manifest.ended) >= Date.parse(manifest.started));
    assert.deepEqual(
      manifest.collections.map(({ name, type, before, after, dumped, judgement, indexes }) => ({ name, type, before, after, dumped, judgement, indexes })),
      [
        { name: "accounts", type: "collection", before: 2, after: 2, dumped: 2, judgement: "match", indexes: ["_id_"] },
        { name: "applications", type: "collection", before: 5, after: 5, dumped: 5, judgement: "match", indexes: ["_id_"] },
        { name: "archived", type: "collection", before: 0, after: 0, dumped: 0, judgement: "match", indexes: ["_id_"] },
        { name: "markets", type: "collection", before: 3, after: 3, dumped: 3, judgement: "match", indexes: ["_id_", "name_unique"] },
        { name: "open_markets", type: "view", before: null, after: null, dumped: null, judgement: "match", indexes: [] },
      ],
    );
    for (const { name, type, bytes } of manifest.collections) {
      if (type === "collection") assert.ok(bytes > 0, `${name} has no bytes`);
    }
    assert.deepEqual(
      { ...manifest.totals, bytes: manifest.totals.bytes > 0, restoredBytes: manifest.totals.restoredBytes > 0 },
      { collections: 4, views: 1, documents: 10, bytes: true, restoredBytes: true },
    );
    // The bytes on disk are every file of the folder's, the manifest's own as written.
    assert.equal(manifest.totals.bytes, walk(folder).filter(({ stat }) => stat.isFile()).reduce((sum, { stat }) => sum + stat.size, 0));
    // What a restore holds: the database's data and indexes, uncompressed, as dbStats gave them.
    const stats = await production.client.db("conventioner").command({ dbStats: 1 });
    assert.equal(manifest.totals.restoredBytes, stats.dataSize + stats.indexSize);
    for (const hidden of [marker, "127.0.0.1", String(production.port), email, "Riverside"]) {
      assert.ok(!manifestText.includes(hidden), `the manifest holds ${hidden}`);
    }
  });

  test("restores into another MongoDB with every collection's count and index names, the view and the empty collection included", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
    });
    const [stamp] = backups();
    await target.client.db("conventioner").dropDatabase();
    execFileSync(join(toolsDir, "mongorestore"), [`--uri=${targetUri}`, "--nsInclude", "conventioner.*", "--gzip", "--dir", join(root, stamp, "dump"), "--quiet"], { stdio: "pipe" });
    const restored = await collectionsOf(target.client);
    assert.deepEqual(restored, await collectionsOf(production.client));
    assert.deepEqual(Object.keys(restored).sort(), ["accounts", "applications", "archived", "markets", "open_markets"]);
    assert.equal(restored.open_markets.type, "view");
  });

  test("gives mongodump the connection string only through a FIFO, gone after the call, and writes it nowhere", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
    });
    const cmdline = spy.read("cmdline");
    const environ = spy.read("environ");
    assert.ok(cmdline && environ, "the spy did not run");
    for (const [what, text] of [["argument list", cmdline], ["environment", environ]]) {
      assert.ok(!text.includes(marker), `the password is in mongodump's ${what}`);
      assert.ok(!text.includes("ops-read"), `the user is in mongodump's ${what}`);
      assert.doesNotMatch(text, /mongodb(\+srv)?:\/\//, `a connection string is in mongodump's ${what}`);
      assert.ok(!text.includes(`127.0.0.1:${production.port}`), `the host is in mongodump's ${what}`);
    }
    assert.match(cmdline, /--config=\S*\/\.\d{4}-\d{2}-\d{2}T\d{6}Z\.partial\/config\.fifo/);
    assert.equal(spy.read("config-kind"), "fifo\n");
    // childEnv's variables, no more: the spy's sh adds PWD (and macOS's ps the rest of its line).
    if (process.platform === "linux") {
      const names = environ.split("\n").filter(Boolean).map((line) => line.split("=")[0]).filter((name) => name !== "PWD");
      assert.deepEqual(names.sort(), ["HOME", "PATH"]);
    }
    for (const { path, stat } of walk(root)) {
      assert.ok(!stat.isFIFO(), `${path} is a FIFO`);
      assert.ok(!path.endsWith("config.fifo"), `${path} is left`);
    }
    for (const dir of [home, join(repoRoot, "toolkits", "prod-mongo"), join(repoRoot, "servers", "prod-mongo")]) {
      for (const { path, stat } of walk(dir)) {
        if (stat.isFile()) assert.ok(!readFileSync(path).includes(marker), `${path} holds the password`);
      }
    }
  });

  test("reports a collection written during the dump as changed, with its counts before and after", async () => {
    spy.set("hold");
    await withServer(async (server) => {
      const call = server.callTool("backup", {});
      await until(() => spy.read("held") !== null);
      await production.client.db("conventioner").collection("accounts").insertOne({ _id: `late-${email}`, role: "vendor" });
      spy.set("go");
      const result = await call;
      assert.ok(!result.isError, result.text);
      assert.match(result.text, /each matching the database's count, but 1 changed during the dump:/);
      assert.match(result.text, /^- accounts: 2 documents, changed during the dump \(2 before, 3 after\)$/m);
    });
    const [stamp] = backups();
    const manifest = JSON.parse(readFileSync(join(root, stamp, "manifest.json"), "utf8"));
    const accounts = manifest.collections.find(({ name }) => name === "accounts");
    assert.deepEqual([accounts.before, accounts.after, accounts.dumped, accounts.judgement], [2, 3, 2, "changed"]);
  });

  test("fails a dump short of documents, naming the collection, and leaves no folder", async () => {
    spy.set("lose", "markets\n");
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.equal(result.isError, true);
      assert.equal(result.text.split("\n").length, 1, result.text);
      assert.match(result.text, /^backup: failed: the dump does not match the database, so it was removed: markets has 0 in the dump, 3 in the database before and after$/);
      for (const hidden of ["127.0.0.1", String(production.port), "ops-read"]) assert.ok(!result.text.includes(hidden), hidden);
    });
    assert.deepEqual(backups(), []);
  });

  test("names every collection the dump is short of, with its counts, however long the answer", async () => {
    spy.set("lose", "accounts\napplications\nmarkets\n");
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.equal(result.isError, true);
      assert.equal(
        result.text,
        "backup: failed: the dump does not match the database, so it was removed: " +
          "accounts has 0 in the dump, 2 in the database before and after; " +
          "applications has 0 in the dump, 5 in the database before and after; " +
          "markets has 0 in the dump, 3 in the database before and after",
      );
    });
    assert.deepEqual(backups(), []);
  });

  test("refuses a second backup while one runs", async () => {
    spy.set("hold");
    await withServer(async (server) => {
      const first = server.callTool("backup", {});
      await until(() => spy.read("held") !== null);
      const second = await server.callTool("backup", {});
      assert.equal(second.isError, true);
      assert.equal(second.text, "backup: a backup is already running");
      // list-backups takes no lock, and names the running backup's folder for what it is.
      const listed = await server.callTool("list-backups", {});
      assert.ok(!listed.isError, listed.text);
      assert.match(listed.text, /^- \.\d{4}-\d{2}-\d{2}T\d{6}Z\.partial: .*, being written by the backup running now$/m);
      spy.set("go");
      assert.ok(!(await first).isError);
    });
    assert.equal(backups().length, 1);
  });

  test("refuses any input", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("backup", { root: "/tmp" });
      assert.equal(result.isError, true);
      assert.equal(result.text, "backup: takes no root");
    });
    assert.deepEqual(backups(), []);
  });

  test("fails in one line naming neither the host nor the secret when the database is unreachable", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.equal(result.isError, true);
      assert.equal(result.text, "backup: failed: could not reach the database");
    }, { value: unreachable() });
    assert.deepEqual(backups(), []);
  });

  test("refuses a root that is a file", async () => {
    mkdirSync(dirname(root), { recursive: true });
    writeFileSync(root, "");
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.equal(result.isError, true);
      assert.equal(result.text, "backup: failed: ~/conventioner-backups is not a directory");
    });
    assert.equal(statSync(root).isFile(), true);
  });
});

describe("the backups root", () => {
  // Each rule refuses backup and list-backups alike, with its reason, before any connection (the
  // database is unreachable, so a connection would have failed with that instead), and makes nothing.
  async function refused(expected, { env = {} } = {}) {
    await withServer(async (server) => {
      for (const tool of ["backup", "list-backups"]) {
        const result = await server.callTool(tool, {});
        assert.equal(result.isError, true, result.text);
        if (expected instanceof RegExp) assert.match(result.text, new RegExp(`^${tool}: failed: ${expected.source}$`));
        else assert.equal(result.text, `${tool}: failed: ${expected}`);
      }
    }, { value: unreachable(), env });
    assert.equal(spy.read("cmdline"), null, "mongodump ran");
  }
  const dir = (...parts) => {
    const path = join(home, ...parts);
    mkdirSync(path, { recursive: true });
    return path;
  };

  test("refuses one inside a git checkout", async () => {
    dir("repo", ".git");
    root = join(home, "repo", "backups");
    await refused("the backups folder ~/repo/backups is inside a git checkout: ~/repo holds .git");
    assert.equal(existsSync(root), false);
  });

  test("refuses one inside a linked worktree, whose .git is a file", async () => {
    dir("worktree");
    writeFileSync(join(home, "worktree", ".git"), "gitdir: /elsewhere\n");
    root = join(home, "worktree", "deep", "backups");
    await refused("the backups folder ~/worktree/deep/backups is inside a git checkout: ~/worktree holds .git");
    assert.equal(existsSync(join(home, "worktree", "deep")), false);
  });

  test("refuses a symlinked root whose real path is inside a checkout, made or not", async () => {
    dir("repo", ".git");
    dir("repo", "made");
    symlinkSync(join(home, "repo", "made"), join(home, "made-link"));
    symlinkSync(join(home, "repo", "not-yet"), join(home, "dangling-link"));
    for (const link of ["made-link", "dangling-link"]) {
      root = join(home, link);
      await refused(`the backups folder ~/${link} is inside a git checkout: ~/repo holds .git`);
    }
    assert.equal(existsSync(join(home, "repo", "not-yet")), false);
  });

  test("takes a symlinked root whose real path passes, and answers from the path as given", async () => {
    dir("elsewhere");
    symlinkSync(join(home, "elsewhere"), join(home, "link"));
    root = join(home, "link");
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
      assert.match(result.text, /^Backup taken: ~\/link\/\d{4}-\d{2}-\d{2}T\d{6}Z /);
    });
    assert.equal(readdirSync(join(home, "elsewhere")).length, 1);
  });

  test("refuses one inside the team home, named by TEAM_HOME or by the setting, even with no .git", async () => {
    dir("records");
    root = join(home, "records", "backups");
    await refused("the backups folder ~/records/backups is inside the team home, ~/records", { env: { TEAM_HOME: join(home, "records") } });
    dir(".config", "agent-team");
    writeFileSync(join(home, ".config", "agent-team", "home"), "records\n");
    await refused("the backups folder ~/records/backups is inside the team home, ~/records");
  });

  test("refuses one inside ~/.claude or ~/.no-mistakes", async () => {
    root = join(home, ".claude", "jobs", "backups");
    await refused("the backups folder ~/.claude/jobs/backups is inside ~/.claude, Claude Code's own folder of transcripts and jobs");
    root = join(home, ".no-mistakes", "backups");
    await refused("the backups folder ~/.no-mistakes/backups is inside ~/.no-mistakes, the gate's own folder of worktrees");
  });

  test("refuses one inside a shared temporary directory, TMPDIR or XDG_RUNTIME_DIR", async () => {
    root = join(tempDir("root"), "backups");
    await refused(/the backups folder \/\S+ is inside a shared temporary directory, \/(tmp|var\/tmp|var\/folders|private\/\S+)/);
    root = join(dir("scratch"), "backups");
    await refused("the backups folder ~/scratch/backups is inside a shared temporary directory, ~/scratch", { env: { TMPDIR: join(home, "scratch") } });
    await refused("the backups folder ~/scratch/backups is inside a shared temporary directory, ~/scratch", { env: { XDG_RUNTIME_DIR: join(home, "scratch") } });
  });

  test("refuses one inside a synced folder, by its name or a sync client's marker", async () => {
    root = join(home, "Dropbox", "backups");
    await refused("the backups folder ~/Dropbox/backups is inside a synced folder, ~/Dropbox");
    dir("shared");
    writeFileSync(join(home, "shared", ".stfolder"), "");
    root = join(home, "shared", "backups");
    await refused("the backups folder ~/shared/backups is inside a synced folder: ~/shared holds .stfolder");
  });

  test("refuses one inside a CI workspace", async () => {
    root = join(dir("workspace"), "backups");
    await refused("the backups folder ~/workspace/backups is inside a CI workspace, GITHUB_WORKSPACE (~/workspace)", { env: { GITHUB_WORKSPACE: join(home, "workspace") } });
  });

  test("refuses the home itself and a relative path", async () => {
    root = home;
    await refused("the backups folder ~ is the home directory itself");
    root = "conventioner-backups";
    await refused("the backups folder conventioner-backups is not an absolute path");
  });

  test("sets a looser root to 0700 and says so once", async () => {
    mkdirSync(root);
    chmodSync(root, 0o755);
    await withServer(async (server) => {
      const first = await server.callTool("backup", {});
      assert.ok(!first.isError, first.text);
      const lines = first.text.split("\n");
      assert.equal(lines.at(-2), "~/conventioner-backups was mode 0755, open to others, so it is now 0700, yours alone.");
      assert.match(lines.at(-1), /^The folder holds 1 dump /);
      assert.equal(statSync(root).mode & 0o777, 0o700);
      const again = await server.callTool("list-backups", {});
      assert.ok(!again.isError, again.text);
      assert.doesNotMatch(again.text, /was mode/);
      chmodSync(root, 0o750);
      const listed = await server.callTool("list-backups", {});
      assert.match(listed.text, /^~\/conventioner-backups was mode 0750, open to others, so it is now 0700, yours alone\.$/m);
      assert.equal(statSync(root).mode & 0o777, 0o700);
    });
  });
});

describe("list-backups", () => {
  const sized = (text) => text.replaceAll(/\d+(\.\d)? (B|KiB|MiB)/g, "<size>");

  test("says the root does not exist yet, and makes nothing", async () => {
    await withServer(async (server) => {
      const result = await server.callTool("list-backups", {});
      assert.ok(!result.isError, result.text);
      assert.equal(result.text, "~/conventioner-backups does not exist yet, so it holds no dumps.\nThe folder holds no dumps; the newest 5 are kept.");
    }, { value: unreachable() });
    assert.equal(existsSync(root), false);
  });

  test("lists verified dumps newest first with what was derived from them, the other entries apart, and those past the rule", async () => {
    await withServer(async (server) => {
      assert.ok(!(await server.callTool("backup", {})).isError);
    });
    const [taken] = backups();
    // Five older copies of it, verified, and one whose manifest is not.
    const older = ["2025-01-01T000000Z", "2025-01-02T000000Z", "2025-01-03T000000Z", "2025-01-04T000000Z", "2025-01-05T000000Z"];
    for (const stamp of older) cpSync(join(root, taken), join(root, stamp), { recursive: true });
    cpSync(join(root, taken), join(root, "2025-06-01T000000Z"), { recursive: true });
    const unverified = join(root, "2025-06-01T000000Z", "manifest.json");
    writeFileSync(unverified, JSON.stringify({ ...JSON.parse(readFileSync(unverified, "utf8")), verified: false }));
    // What later tools derive from a dump, in its folder.
    const derived = (...parts) => join(root, taken, ...parts);
    mkdirSync(derived("drills"));
    writeFileSync(derived("drills", "2026-01-01T100000Z.json"), JSON.stringify({ verdict: "FAIL" }));
    writeFileSync(derived("drills", "2026-01-01T110000Z.json"), JSON.stringify({ verdict: "PASS" }));
    mkdirSync(derived("rehearsals", "2026-01-01T120000Z"), { recursive: true });
    mkdirSync(derived("undo", "2026-01-01T130000Z"), { recursive: true });
    mkdirSync(derived("undo", "2026-01-01T140000Z"), { recursive: true });
    mkdirSync(derived("diffs"));
    writeFileSync(derived("diffs", "2025-01-05T000000Z.json"), "{}");
    // Daniel's own dump, one a killed server left, a stamp-named folder with no manifest, a file.
    mkdirSync(join(root, "hand-dump"));
    writeFileSync(join(root, "hand-dump", "markets.bson"), "hand-made");
    mkdirSync(join(root, ".2025-02-01T000000Z.partial"));
    writeFileSync(join(root, ".2025-02-01T000000Z.partial", "x"), "part");
    mkdirSync(join(root, "2025-03-01T000000Z"));
    writeFileSync(join(root, "notes.txt"), "mine");

    spy = spyMongodump();
    let text;
    await withServer(async (server) => {
      const result = await server.callTool("list-backups", {});
      assert.ok(!result.isError, result.text);
      text = result.text;
    }, { value: unreachable() });
    assert.equal(spy.read("cmdline"), null, "mongodump ran");
    const summary = "4 collections and 1 view, 10 documents, <size>";
    const plain = "0 drills, 0 rehearsals, 0 undos, 0 diffs";
    assert.deepEqual(sized(text).split("\n"), [
      "~/conventioner-backups holds 7 dumps taken by this toolkit, newest first:",
      `- ${taken}: ${summary}, verified; 2 drills (newest PASS), 1 rehearsal, 2 undos, 1 diff`,
      `- 2025-06-01T000000Z: ${summary}, not verified; ${plain}`,
      ...older.toReversed().map((stamp) => `- ${stamp}: ${summary}, verified; ${plain}`),
      "4 other entries:",
      "- .2025-02-01T000000Z.partial: <size>, left unfinished",
      "- 2025-03-01T000000Z: <size>, not taken by this toolkit",
      "- hand-dump: <size>, not taken by this toolkit",
      "- notes.txt: <size>, not taken by this toolkit",
      "In all, <size>.",
      `The folder holds 7 dumps (<size>); the newest ${kept} are kept, so 2 are past that, for Daniel to delete by hand: 2025-06-01T000000Z (not verified), 2025-01-01T000000Z.`,
    ]);
    const total = walk(root).reduce((sum, { stat }) => sum + (stat.isFile() ? stat.size : 0), 0);
    assert.ok(text.includes(`\nIn all, ${humanBytes(total)}.\n`), text);
    assert.match(text, /^- hand-dump: 9 B, not taken by this toolkit$/m);
    assert.ok(!text.includes(home) && !text.includes(email), text);
    // The toolkit never deletes a dump.
    assert.equal(backups().length, 11);
  });

  test("backup's answer names the dumps past the rule too", async () => {
    mkdirSync(root, { mode: 0o700 });
    const old = ["2025-01-01T000000Z", "2025-01-02T000000Z", "2025-01-03T000000Z", "2025-01-04T000000Z", "2025-01-05T000000Z"];
    for (const stamp of old) {
      mkdirSync(join(root, stamp));
      writeFileSync(join(root, stamp, "manifest.json"), JSON.stringify({ verified: true, totals: { collections: 1, views: 0, documents: 1 } }));
    }
    await withServer(async (server) => {
      const result = await server.callTool("backup", {});
      assert.ok(!result.isError, result.text);
      assert.match(result.text.split("\n").at(-1), /^The folder holds 6 dumps \(\S+ \S+\); the newest 5 are kept, so 1 is past that, for Daniel to delete by hand: 2025-01-01T000000Z\.$/);
    });
  });
});

// What the tests of the two container scripts share: the restore drill's and the rehearsal's.
const realDocker = (process.env.PATH ?? "").split(delimiter).map((dir) => join(dir, "docker")).find((path) => existsSync(path));
const { MongoClient } = createRequire(join(repoRoot, "servers", "package.json"))("mongodb");
const environOf = process.platform === "linux" ? "tr '\\0' '\\n' </proc/$$/environ" : "ps -E -ww -o command= -p $$";
const cmdlineOf = process.platform === "linux" ? "tr '\\0' '\\n' </proc/$$/cmdline" : "ps -ww -o command= -p $$";

// The spy docker: each call's arguments, one per line and ended by "--- end", in `calls`, and
// the environment `docker run` starts with, in `run-environ` and in `run-environ-<its --name>`;
// then the real docker, but for
// `docker port`, which fails while `fail-port` exists. While `hold-run` exists, `docker run`
// first writes its pid to `run-held` and to `held-<its --name>`, waits up to 20 seconds for
// `go-run`, as a first pull of the image does, and then writes `went-on-<its --name>`. While
// `hang-rm` exists, the first removal (`rm`, `network rm` or `image rm`) moves it to `hung-rm`
// and sleeps two minutes, as a docker daemon that stopped answering does.
function spyDocker() {
  const dir = tempDir("docker-spy");
  writeFileSync(join(dir, "docker"), `#!/bin/sh
dir='${dir}'
{ printf '%s\\n' "$@"; echo '--- end'; } >>"$dir/calls"
name=
if [ "$1" = run ]; then
  name=$(printf '%s\\n' "$@" | sed -n '/^--name$/{n;p;q;}')
  ${environOf} >"$dir/run-environ"
  cp "$dir/run-environ" "$dir/run-environ-$name"
fi
if [ "$1" = run ] && [ -f "$dir/hold-run" ]; then
  echo $$ >"$dir/held-$name"
  echo $$ >"$dir/run-held"
  n=0
  while [ ! -f "$dir/go-run" ] && [ $n -lt 200 ]; do sleep 0.1; n=$((n + 1)); done
  : >"$dir/went-on-$name"
fi
if [ "$1" = port ] && [ -f "$dir/fail-port" ]; then echo 'Error: no port, as the test asked' >&2; exit 1; fi
if { [ "$1" = rm ] || [ "$2" = rm ]; } && mv "$dir/hang-rm" "$dir/hung-rm" 2>/dev/null; then sleep 120; fi
exec '${realDocker}' "$@"
`, { mode: 0o755 });
  const read = (name) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : "");
  const calls = () => read("calls").split("--- end\n").filter(Boolean).map((call) => call.split("\n").filter(Boolean));
  return { dir, read, calls, set: (name) => writeFileSync(join(dir, name), "") };
}

// The spy mongorestore: its argument list, environment and the kind of its --config file, then
// the real one; with `hold` it waits after the restore until `go` exists or its parent is gone,
// and with `fail` it then exits 1 with a line naming the throwaway's connection string.
function spyMongorestore() {
  const dir = tempDir("mongorestore-spy");
  writeFileSync(join(dir, "mongorestore"), `#!/bin/sh
dir='${dir}'
real='${join(toolsDir, "mongorestore")}'
[ "$1" = --version ] && exec "$real" "$@"
${cmdlineOf} >"$dir/cmdline"
${environOf} >"$dir/environ"
config=\${1#--config=}
if [ -p "$config" ]; then echo fifo >"$dir/config-kind"; else echo other >"$dir/config-kind"; fi
"$real" "$@"
status=$?
if [ -f "$dir/hold" ]; then
  : >"$dir/held"
  while [ ! -f "$dir/go" ] && kill -0 $PPID 2>/dev/null; do sleep 0.1; done
fi
if [ -f "$dir/fail" ]; then echo "Failed: restoring into $(sed -n 's/^uri: //p' "$config" 2>/dev/null)mongodb://root:x@127.0.0.1 {\"doc\": 1}" >&2; exit 1; fi
exit $status
`, { mode: 0o755 });
  const read = (name) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : null);
  return { dir, read, set: (name, text = "") => writeFileSync(join(dir, name), text) };
}

let docker;
let restorer;
const drillPath = () => [spy.dir, restorer.dir, docker.dir, toolsDir, testPath()].join(":");
// Under tests/run the heavy-run lock is held, so the server's team-heavy runs the drill at once;
// run alone, this file holds none, and the drill runs at once all the same (the lock test holds
// one in the test's HOME).
const held = { TEAM_HEAVY_HELD: process.env.TEAM_HEAVY_HELD ?? "1" };
const drillServer = (body, options = {}) => withServer(body, { path: drillPath(), ...options, env: { ...held, ...options.env } });
beforeEach(() => {
  docker = spyDocker();
  restorer = spyMongorestore();
});

async function takeBackup() {
  await withServer(async (server) => {
    const result = await server.callTool("backup", {});
    assert.ok(!result.isError, result.text);
  });
  return backups().filter((name) => /^\d{4}-\d{2}-\d{2}T\d{6}Z$/.test(name)).sort().at(-1);
}
const gone = (name) => {
  const inspected = spawnSync(realDocker, ["container", "inspect", name], { encoding: "utf8" });
  return inspected.status !== 0 && /no such (container|object)/i.test(inspected.stderr);
};
const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code !== "ESRCH";
  }
};
const timed = (text) => text.replace(/: (PASS|FAIL) in \d+( min \d+)? s, /, ": $1 in <time>, ");
const drillsOf = (stamp) => (existsSync(join(root, stamp, "drills")) ? readdirSync(join(root, stamp, "drills")) : []);

describe("restore-drill", () => {
  test("the throwaway's image and its environment are the test helpers' own", () => {
    assert.equal(throwawayImage, mongoImage);
    assert.deepEqual(throwawayCaches, perThreadCaches);
  });

  // The rehearsal's form: the throwaway on the default bridge and on the caller's network too.
  test("the throwaway is a loopback-only, tmpfs, 2 GiB, self-ending --rm container that joins a network under an alias", async () => {
    const network = `prod-mongo-test-${randomBytes(4).toString("hex")}`;
    execFileSync(realDocker, ["network", "create", "--internal", network], { stdio: "pipe" });
    const name = throwawayName("drill");
    try {
      const throwaway = await startThrowaway({ name, kind: "drill", join: { network, alias: "mongodb" }, MongoClient });
      const [inspected] = JSON.parse(execFileSync(realDocker, ["container", "inspect", name], { encoding: "utf8" }));
      const { HostConfig: host, Config: config } = inspected;
      assert.ok(inspected.NetworkSettings.Networks[network]?.Aliases?.includes("mongodb"), JSON.stringify(inspected.NetworkSettings.Networks));
      assert.ok(inspected.NetworkSettings.Networks.bridge, "not on the default bridge");
      assert.equal(host.AutoRemove, true);
      assert.equal(host.Memory, 2 * 1024 ** 3);
      assert.equal(host.MemorySwap, 2 * 1024 ** 3);
      assert.deepEqual(host.PortBindings, { "27017/tcp": [{ HostIp: "127.0.0.1", HostPort: "" }] });
      assert.deepEqual(Object.keys(host.Tmpfs).sort(), ["/data/configdb", "/data/db"]);
      assert.deepEqual(inspected.Mounts.filter(({ Type }) => Type === "volume"), [], "it has a volume");
      assert.deepEqual(config.Entrypoint, ["timeout"]);
      assert.deepEqual(config.Cmd, ["3600", "docker-entrypoint.sh", "mongod"]);
      assert.equal(config.Labels[teamLabel("toolkit")], "prod-mongo");
      assert.equal(config.Labels[teamLabel("expires")], throwaway.expires);
      await throwaway.client.db("admin").command({ ping: 1 });
      assert.deepEqual(await throwaway.stop(), { gone: true });
      assert.ok(gone(name));
    } finally {
      spawnSync(realDocker, ["rm", "--force", "--volumes", name]);
      spawnSync(realDocker, ["network", "rm", network]);
    }
  });

  test("removing one throwaway kills only its own docker run, never another one still starting", async () => {
    const path = process.env.PATH;
    process.env.PATH = [docker.dir, path].join(delimiter);
    docker.set("hold-run");
    const [first, second] = [throwawayName("drill"), throwawayName("drill")];
    try {
      const settled = Promise.allSettled([first, second].map((name) => startThrowaway({ name, kind: "drill", MongoClient })));
      await until(() => existsSync(join(docker.dir, `held-${first}`)) && existsSync(join(docker.dir, `held-${second}`)), 30_000);
      assert.deepEqual(removeThrowaway(first), { gone: true });
      await until(() => !alive(Number(docker.read(`held-${first}`))), 10_000);
      assert.equal(alive(Number(docker.read(`held-${second}`))), true, "the other docker run was killed");
      docker.set("go-run");
      const [stopped, started] = await settled;
      assert.equal(stopped.status, "rejected");
      assert.equal(existsSync(join(docker.dir, `went-on-${first}`)), false, "the removed throwaway's docker run went on");
      assert.equal(started.status, "fulfilled", started.reason?.message);
      assert.equal(started.value.name, second);
      assert.deepEqual(await started.value.stop(), { gone: true });
      assert.ok(gone(first) && gone(second));
    } finally {
      process.env.PATH = path;
      for (const name of [first, second]) spawnSync(realDocker, ["rm", "--force", "--volumes", name]);
    }
  });

  test("sends a progress notification per step of a backup and of a drill, the drill's relayed from its script", async () => {
    const steps = (server, token) =>
      server.fromServer
        .filter(({ method, params }) => method === "notifications/progress" && params.progressToken === token)
        .map(({ params }) => [params.progress, params.message]);
    let stamp;
    await withServer(async (server) => {
      const result = await server.callTool("backup", {}, { progressToken: "b" });
      assert.ok(!result.isError, result.text);
      stamp = backups()[0];
      assert.deepEqual(steps(server, "b"), [
        [1, "checking the backups folder"],
        [2, "reading the database's size"],
        [3, "counting each collection"],
        [4, "dumping"],
        [5, "counting each collection again"],
        [6, "checking the dump"],
      ]);
    });
    await drillServer(async (server) => {
      const result = await server.callTool("restore-drill", {}, { progressToken: "d" });
      assert.ok(!result.isError, result.text);
      assert.deepEqual(steps(server, "d"), [
        [1, `drilling ${stamp}, through the machine's heavy-run lock`],
        [2, "removing what earlier drills left past their expiry"],
        [3, "starting the throwaway MongoDB"],
        [4, "restoring the dump"],
        [5, "comparing each collection with the manifest"],
        [6, "removing the throwaway MongoDB"],
      ]);
      // No token, no notification.
      const quiet = await server.callTool("restore-drill", {});
      assert.ok(!quiet.isError, quiet.text);
      assert.equal(server.fromServer.filter(({ method }) => method === "notifications/progress").length, 6);
    });
  });

  test("passes on a backup the test took, records its verdict beside it, and leaves nothing running", async () => {
    const stamp = await takeBackup();
    let text;
    await drillServer(async (server) => {
      const result = await server.callTool("restore-drill", {});
      assert.ok(!result.isError, result.text);
      text = result.text;
      const listed = await server.callTool("list-backups", {});
      assert.match(listed.text, new RegExp(`^- ${stamp}: .*, verified; 1 drill \\(newest PASS\\), 0 rehearsals, 0 undos, 0 diffs$`, "m"));
    });
    const [file] = drillsOf(stamp);
    assert.deepEqual(drillsOf(stamp), [file]);
    assert.match(file, /^\d{4}-\d{2}-\d{2}T\d{6}Z\.json$/);
    assert.deepEqual(timed(text).split("\n"), [
      `Restore drill of ~/conventioner-backups/${stamp}: PASS in <time>, mongorestore ${mongodumpVersion}`,
      "4 collections and 1 view, 10 documents, each collection's count and index names as its manifest gives them.",
      `Recorded in ~/conventioner-backups/${stamp}/drills/${file}; nothing was left running.`,
    ]);
    assert.equal(statSync(join(root, stamp, "drills")).mode & 0o777, 0o700);
    assert.equal(statSync(join(root, stamp, "drills", file)).mode & 0o777, 0o600);
    const record = JSON.parse(readFileSync(join(root, stamp, "drills", file), "utf8"));
    assert.equal(record.verdict, "PASS");
    assert.equal(record.stamp, stamp);
    assert.equal(record.image, mongoImage);
    assert.deepEqual(record.collections.map(({ name, match }) => [name, match]), [["accounts", true], ["applications", true], ["archived", true], ["markets", true], ["open_markets", true]]);
    assert.deepEqual(record.collections.find(({ name }) => name === "markets").restored, { type: "collection", documents: 3, indexes: ["_id_", "name_unique"] });

    // The throwaway: started once, as the spec says, and gone.
    const runs = docker.calls().filter(([command]) => command === "run");
    assert.equal(runs.length, 1);
    const [run] = runs;
    const name = run[run.indexOf("--name") + 1];
    assert.match(name, /^prod-mongo-drill-[0-9a-f]{12}$/);
    assert.ok(gone(name), `${name} is still there`);
    for (const part of ["--rm", "--detach"]) assert.ok(run.includes(part), part);
    const pairs = run.slice(0, -4).flatMap((arg, n) => (arg.startsWith("--") ? [`${arg} ${run[n + 1]}`] : []));
    for (const pair of [
      "--memory 2g", "--memory-swap 2g", "--publish 127.0.0.1::27017", "--tmpfs /data/db", "--tmpfs /data/configdb",
      "--env GLIBC_TUNABLES=glibc.pthread.rseq=1", "--env MONGO_INITDB_ROOT_USERNAME=root", "--env MONGO_INITDB_ROOT_PASSWORD", "--entrypoint timeout",
      `--label ${teamLabel("owner")}=agent-team`, `--label ${teamLabel("kind")}=drill`, `--label ${teamLabel("toolkit")}=prod-mongo`,
    ]) {
      assert.ok(pairs.includes(pair), `docker run has no ${pair}`);
    }
    assert.deepEqual(run.slice(-4), [mongoImage, "3600", "docker-entrypoint.sh", "mongod"]);
    const expires = Date.parse(pairs.find((pair) => pair.startsWith(`--label ${teamLabel("expires")}=`)).split("=")[1]);
    assert.ok(Math.abs(expires - (Date.parse(record.started) + 3600_000)) < 60_000, "expires is not its start plus an hour");

    // The password: in docker run's own environment, and nowhere else.
    const password = /^MONGO_INITDB_ROOT_PASSWORD=([0-9a-f]{48})$/m.exec(docker.read("run-environ"))?.[1];
    assert.ok(password, "docker run's environment holds no password");
    for (const call of docker.calls()) assert.ok(!call.join(" ").includes(password), `the password is in docker ${call[0]}'s argument list`);
    for (const what of ["cmdline", "environ"]) assert.ok(!restorer.read(what).includes(password), `the password is in mongorestore's ${what}`);
    assert.doesNotMatch(restorer.read("cmdline"), /mongodb:\/\//);
    assert.equal(restorer.read("config-kind"), "fifo\n");
    assert.match(restorer.read("cmdline"), new RegExp(`^--config=\\S*/${stamp}/drills/\\.\\S+\\.config\\.fifo$`, "m"));
    assert.ok(!text.includes(password));
    for (const { path, stat } of walk(home)) {
      assert.ok(!stat.isFIFO(), `${path} is a FIFO`);
      if (stat.isFile()) assert.ok(!readFileSync(path).includes(password), `${path} holds the password`);
    }
  });

  test("fails on a manifest altered to a wrong count, naming the collection, records FAIL and leaves nothing running", async () => {
    const stamp = await takeBackup();
    const path = join(root, stamp, "manifest.json");
    const manifest = JSON.parse(readFileSync(path, "utf8"));
    manifest.collections.find(({ name }) => name === "markets").dumped = 4;
    writeFileSync(path, JSON.stringify(manifest));
    await drillServer(async (server) => {
      const result = await server.callTool("restore-drill", { backup: stamp });
      assert.equal(result.isError, true);
      const [file] = drillsOf(stamp);
      assert.deepEqual(timed(result.text).split("\n"), [
        `Restore drill of ~/conventioner-backups/${stamp}: FAIL in <time>, mongorestore ${mongodumpVersion}`,
        "1 of 5 did not match the manifest:",
        "- markets: 3 documents restored, 4 in its manifest",
        `Recorded in ~/conventioner-backups/${stamp}/drills/${file}; nothing was left running.`,
      ]);
      const listed = await server.callTool("list-backups", {});
      assert.match(listed.text, new RegExp(`^- ${stamp}: .*; 1 drill \\(newest FAIL\\),`, "m"));
    });
    const [file] = drillsOf(stamp);
    assert.equal(JSON.parse(readFileSync(join(root, stamp, "drills", file), "utf8")).verdict, "FAIL");
    const [run] = docker.calls().filter(([command]) => command === "run");
    assert.ok(gone(run[run.indexOf("--name") + 1]));
  });

  test("fails a dump mongorestore cannot restore, with its scrubbed reason, and removes the throwaway on an error with no verdict", async () => {
    const stamp = await takeBackup();
    restorer.set("fail");
    await drillServer(async (server) => {
      const failed = await server.callTool("restore-drill", { backup: stamp });
      assert.equal(failed.isError, true);
      const lines = timed(failed.text).split("\n");
      assert.equal(lines[0], `Restore drill of ~/conventioner-backups/${stamp}: FAIL in <time>, mongorestore ${mongodumpVersion}`);
      assert.equal(lines[1], "mongorestore exited 1: Failed: restoring into [uri], so the dump did not restore.");
      assert.match(lines.at(-1), /; nothing was left running\.$/);
    });
    assert.equal(drillsOf(stamp).length, 1);
    docker.set("fail-port");
    await drillServer(async (server) => {
      const result = await server.callTool("restore-drill", { backup: stamp });
      assert.equal(result.isError, true);
      assert.equal(
        result.text,
        `restore-drill: failed: docker gave no loopback port for the throwaway MongoDB: Error: no port, as the test asked, so ~/conventioner-backups/${stamp} has no verdict; nothing was left running.`,
      );
    });
    assert.equal(drillsOf(stamp).length, 1, "a Docker failure recorded a verdict");
    const names = docker.calls().filter(([command]) => command === "run").map((run) => run[run.indexOf("--name") + 1]);
    assert.equal(names.length, 2);
    for (const name of names) assert.ok(gone(name), `${name} is still there`);
  });

  test("refuses before Docker is touched: no backup, a stamp not under the root, a dump not verified or too big", async () => {
    await drillServer(async (server) => {
      const none = await server.callTool("restore-drill", {});
      assert.equal(none.text, "restore-drill: failed: ~/conventioner-backups does not exist yet, so it holds no backup to drill");
    });
    const stamp = await takeBackup();
    cpSync(join(root, stamp), join(root, "2025-01-01T000000Z"), { recursive: true });
    const unverified = join(root, "2025-01-01T000000Z", "manifest.json");
    writeFileSync(unverified, JSON.stringify({ ...JSON.parse(readFileSync(unverified, "utf8")), verified: false }));
    cpSync(join(root, stamp), join(root, "2025-02-01T000000Z"), { recursive: true });
    const big = join(root, "2025-02-01T000000Z", "manifest.json");
    const bigManifest = JSON.parse(readFileSync(big, "utf8"));
    // The limit is on what the restore holds in memory, never the gzipped dump on disk.
    writeFileSync(big, JSON.stringify({ ...bigManifest, totals: { ...bigManifest.totals, restoredBytes: restoreLimit + 1 } }));
    cpSync(join(root, stamp), join(root, "2025-03-01T000000Z"), { recursive: true });
    const sizeless = join(root, "2025-03-01T000000Z", "manifest.json");
    const { restoredBytes: _dropped, ...sizelessTotals } = bigManifest.totals;
    writeFileSync(sizeless, JSON.stringify({ ...bigManifest, totals: sizelessTotals }));
    const outside = join(home, "elsewhere", stamp);
    cpSync(join(root, stamp), outside, { recursive: true });
    await drillServer(async (server) => {
      for (const [backup, reason] of [
        [outside, `"${outside.slice(0, 40)}..." is not a backup's name, which is its UTC start, as 2026-11-08T142305Z`],
        [`../elsewhere/${stamp}`, `"../elsewhere/${stamp}" is not a backup's name, which is its UTC start, as 2026-11-08T142305Z`],
        ["2024-01-01T000000Z", "~/conventioner-backups holds no backup 2024-01-01T000000Z"],
        ["2025-01-01T000000Z", "~/conventioner-backups/2025-01-01T000000Z has no verified manifest.json, so it is not a dump this toolkit took"],
        ["2025-02-01T000000Z", "~/conventioner-backups/2025-02-01T000000Z restores to 512.0 MiB of data and indexes, more than the 512.0 MiB a drill holds in memory"],
        ["2025-03-01T000000Z", "~/conventioner-backups/2025-03-01T000000Z's manifest gives no restored size"],
      ]) {
        const result = await server.callTool("restore-drill", { backup });
        assert.equal(result.isError, true, backup);
        assert.equal(result.text, `restore-drill: failed: ${reason}`, backup);
      }
      const typed = await server.callTool("restore-drill", { backup: 7 });
      assert.equal(typed.text, "restore-drill: failed: that is not a backup's name, which is its UTC start, as 2026-11-08T142305Z");
      const other = await server.callTool("restore-drill", { root: "/tmp" });
      assert.equal(other.text, "restore-drill: takes no root");
    });
    assert.deepEqual(docker.calls(), [], "docker ran");
    assert.equal(restorer.read("cmdline"), null, "mongorestore ran");
    assert.deepEqual(drillsOf(stamp), []);
  });

  test("removes the toolkit's container, network and image past their expiry, naming each, and keeps the rest", async () => {
    const stamp = await takeBackup();
    const tag = randomBytes(4).toString("hex");
    const labels = (expires, toolkit = "prod-mongo") => ["--label", `${teamLabel("owner")}=agent-team`, "--label", `${teamLabel("kind")}=drill`, "--label", `${teamLabel("toolkit")}=${toolkit}`, "--label", `${teamLabel("expires")}=${expires}`];
    const made = { containers: [], networks: [], images: [] };
    const make = (name, labelArgs) => {
      execFileSync(realDocker, ["run", "--detach", "--name", name, ...labelArgs, ...dataOnTmpfs, "--entrypoint", "sleep", mongoImage, "600"], { stdio: "pipe" });
      made.containers.push(name);
      // The image declares /data/db and /data/configdb as volumes, so a container started
      // without tmpfs there leaves two anonymous volumes behind every run.
      const [inspected] = JSON.parse(execFileSync(realDocker, ["container", "inspect", name], { encoding: "utf8" }));
      assert.deepEqual(inspected.Mounts.filter(({ Type }) => Type === "volume"), [], `${name} has a volume`);
    };
    try {
      make(`prod-mongo-drill-expired-${tag}`, labels("2020-01-01T00:00:00Z"));
      make(`prod-mongo-drill-live-${tag}`, labels("2999-01-01T00:00:00Z"));
      make(`not-prod-mongo-${tag}`, labels("2020-01-01T00:00:00Z", "other"));
      execFileSync(realDocker, ["commit", `prod-mongo-drill-expired-${tag}`, `prod-mongo-expired-test:${tag}`], { stdio: "pipe" });
      made.images.push(`prod-mongo-expired-test:${tag}`);
      execFileSync(realDocker, ["network", "create", ...labels("2020-01-01T00:00:00Z"), `prod-mongo-expired-${tag}`], { stdio: "pipe" });
      made.networks.push(`prod-mongo-expired-${tag}`);
      await drillServer(async (server) => {
        const result = await server.callTool("restore-drill", { backup: stamp });
        assert.ok(!result.isError, result.text);
        assert.match(
          result.text.split("\n").at(-1),
          new RegExp(`^Removed what an earlier run left past its expiry: (\\S+ \\S+, )*container prod-mongo-drill-expired-${tag}(, \\S+ \\S+)*\\.$`),
        );
        for (const part of [`network prod-mongo-expired-${tag}`, `image prod-mongo-expired-test:${tag}`]) assert.ok(result.text.includes(part), part);
        assert.ok(!result.text.includes(`live-${tag}`) && !result.text.includes(`not-prod-mongo-${tag}`), result.text);
      });
      assert.ok(gone(`prod-mongo-drill-expired-${tag}`));
      assert.ok(!gone(`prod-mongo-drill-live-${tag}`));
      assert.ok(!gone(`not-prod-mongo-${tag}`));
      assert.notEqual(spawnSync(realDocker, ["network", "inspect", `prod-mongo-expired-${tag}`]).status, 0, "the expired network is still there");
      assert.notEqual(spawnSync(realDocker, ["image", "inspect", `prod-mongo-expired-test:${tag}`]).status, 0, "the expired image is still there");
      // Each expired one removed by its id; the drill's own by its name.
      const [run] = docker.calls().filter(([command]) => command === "run");
      const own = run[run.indexOf("--name") + 1];
      const removals = docker.calls().filter(([command, sub]) => command === "rm" || (["network", "image"].includes(command) && sub === "rm"));
      assert.equal(removals.filter((call) => call.at(-1) !== own).length, 3, JSON.stringify(removals));
      for (const call of removals.filter((args) => args.at(-1) !== own)) assert.match(call.at(-1), /^(sha256:)?[0-9a-f]{64}$/, call.join(" "));
    } finally {
      for (const name of made.containers) spawnSync(realDocker, ["rm", "--force", "--volumes", name]);
      for (const name of made.networks) spawnSync(realDocker, ["network", "rm", name]);
      for (const name of made.images) spawnSync(realDocker, ["image", "rm", "--force", name]);
    }
  });

  test("answers that the machine is busy while another run holds the heavy-run lock, and runs nothing", async (t) => {
    const stamp = await takeBackup();
    const lock = join(home, ".local", "state", "agent-team", "heavy.lock");
    mkdirSync(dirname(lock), { recursive: true });
    writeFileSync(lock, "the test's own run (pid 1) since now\n");
    // flock and its sleep, which holds the lock, both end with the test.
    owned(t, spawn("flock", [lock, "sleep", "300"], { stdio: "ignore" }));
    await until(() => spawnSync("flock", ["-n", lock, "true"]).status !== 0);
    await withServer(async (server) => {
      const result = await server.callTool("restore-drill", { backup: stamp });
      assert.equal(result.isError, true);
      assert.equal(result.text, "restore-drill: the machine is busy: the heavy-run lock is held by the test's own run (pid 1) since now; ask again later");
    }, { path: drillPath(), env: { PROD_MONGO_HEAVY_WAIT_MINUTES: "0" } });
    assert.deepEqual(docker.calls(), [], "docker ran");
    assert.deepEqual(drillsOf(stamp), []);
  });

  test("shares the one-long-call lock with backup", async () => {
    spy.set("hold");
    await drillServer(async (server) => {
      const first = server.callTool("backup", {});
      await until(() => spy.read("held") !== null);
      const drill = await server.callTool("restore-drill", {});
      assert.equal(drill.text, "restore-drill: a backup is already running");
      spy.set("go");
      assert.ok(!(await first).isError);
    });
    assert.deepEqual(docker.calls(), []);
  });

  // The script as Daniel runs it: through team-heavy (this test's HOME has a lock of its own),
  // with no MCP server and no op; it ends with test `t`.
  const byHand = (t, args, { path = [toolsDir, testPath()].join(":") } = {}) =>
    owned(t, spawn(join(repoRoot, "bin", "team-heavy"), ["run", "--kind", "restore-drill", "--", process.execPath, join(repoRoot, "toolkits", "prod-mongo", "scripts", "restore-drill.mjs"), ...args], {
      env: { HOME: home, PATH: path, PROD_MONGO_ROOT: root },
      stdio: ["ignore", "pipe", "pipe"],
    }));
  test("run by hand through team-heavy: --text prints the tool's answer, and without it one JSON object", async (t) => {
    const stamp = await takeBackup();
    const text = await ended(byHand(t, [stamp, "--text"]));
    assert.equal(text.code, 0, text.stderr);
    assert.match(text.stdout, new RegExp(`^Restore drill of ~/conventioner-backups/${stamp}: PASS in \\d+ s, mongorestore `));
    assert.match(text.stdout, /; nothing was left running\.\n$/);
    const json = await ended(byHand(t, [stamp]));
    assert.equal(json.code, 0, json.stderr);
    assert.equal(json.stdout.split("\n").filter(Boolean).length, 1, json.stdout);
    const result = JSON.parse(json.stdout);
    assert.equal(result.verdict, "PASS");
    assert.deepEqual(result.cleanup, { gone: true });
    assert.ok(gone(result.container));
    assert.equal(drillsOf(stamp).length, 2);
    const refused = await ended(byHand(t, ["--uri=mongodb://x", stamp]));
    assert.equal(refused.code, 1);
    assert.deepEqual(JSON.parse(refused.stdout), { refused: "takes exactly one argument, a backup's name, its UTC start as 2026-11-08T142305Z (and --text for the answer as text)" });
  });

  test("restoring.md's commands: the drill by hand as the tests run it, and the restore to production, run as Daniel would", async () => {
    const doc = readFileSync(join(repoRoot, "toolkits", "prod-mongo", "docs", "restoring.md"), "utf8");
    assert.ok(doc.includes("\n~/agent-team/bin/team-heavy run --kind restore-drill -- node ~/agent-team/toolkits/prod-mongo/scripts/restore-drill.mjs <stamp> --text\n"));
    const blocks = [...doc.matchAll(/^```bash\n([\s\S]*?)^```$/gm)].map(([, body]) => body);
    const restore = blocks.find((body) => body.startsWith("read -rs PROD_URI\n"));
    assert.ok(restore, "restoring.md has no restore command");
    const stamp = await takeBackup();
    await target.client.db("conventioner").dropDatabase();
    await target.client.db("conventioner").collection("markets").insertOne({ name: "written since the dump" });
    const restored = spawnSync("bash", ["-c", restore.replaceAll("<stamp>", stamp)], {
      input: `${targetUri}\n`,
      env: { HOME: home, PATH: [restorer.dir, toolsDir, testPath()].join(":") },
      encoding: "utf8",
    });
    assert.equal(restored.status, 0, restored.stderr);
    assert.deepEqual(await collectionsOf(target.client), await collectionsOf(production.client));
    assert.equal(await target.client.db("conventioner").collection("markets").countDocuments({ name: "written since the dump" }), 0);
    const { password } = new URL(targetUri);
    assert.ok(!restorer.read("cmdline").includes(password), "the password is in mongorestore's argument list");
    assert.doesNotMatch(restorer.read("cmdline"), /mongodb:\/\//);
    assert.ok(!restorer.read("environ").includes(password), "the password is in mongorestore's environment");
    assert.equal(restorer.read("config-kind"), "fifo\n");
  });

  test("stops at once on SIGTERM while docker run still waits, and leaves no container", async (t) => {
    const stamp = await takeBackup();
    const script = join(repoRoot, "toolkits", "prod-mongo", "scripts", "restore-drill.mjs");
    docker.set("hold-run");
    const child = owned(t, spawn(process.execPath, [script, stamp], {
      env: { HOME: home, PATH: [restorer.dir, docker.dir, toolsDir, testPath()].join(":"), PROD_MONGO_ROOT: root },
      stdio: ["ignore", "pipe", "pipe"],
    }));
    const done = ended(child);
    await until(() => existsSync(join(docker.dir, "run-held")), 60_000);
    const stopped = Date.now();
    child.kill("SIGTERM");
    const result = await done;
    assert.ok(Date.now() - stopped < 10_000, `it waited ${Date.now() - stopped} ms for docker run`);
    assert.equal(result.code, 128 + 15, result.stderr);
    const out = JSON.parse(result.stdout);
    assert.equal(out.failed, "the drill was stopped (SIGTERM)");
    assert.deepEqual(out.cleanup, { gone: true });
    // The held docker run never goes on to start the container once its drill is gone: let it go
    // on, wait until its process is gone, and it never got past its hold.
    const held = Number(docker.read(`held-${out.container}`));
    docker.set("go-run");
    await until(() => !alive(held), 10_000);
    assert.equal(existsSync(join(docker.dir, `went-on-${out.container}`)), false, "the held docker run went on");
    assert.ok(gone(out.container), out.container);
    assert.deepEqual(drillsOf(stamp), []);
  });

  test("removes its throwaway when stopped by SIGINT, SIGTERM or SIGHUP mid-drill, and records no verdict", async (t) => {
    const stamp = await takeBackup();
    const script = join(repoRoot, "toolkits", "prod-mongo", "scripts", "restore-drill.mjs");
    // One drill at a time, as the heavy-run lock runs them, each on its own copy of the dump with a
    // holding mongorestore spy, stopped by its signal once the spy holds.
    for (const [n, signal] of ["SIGINT", "SIGTERM", "SIGHUP"].entries()) {
      const copy = `2025-0${n + 1}-01T000000Z`;
      cpSync(join(root, stamp), join(root, copy), { recursive: true });
      const holding = spyMongorestore();
      holding.set("hold");
      const child = owned(t, spawn(process.execPath, [script, copy], { env: { HOME: home, PATH: [holding.dir, toolsDir, testPath()].join(":"), PROD_MONGO_ROOT: root }, stdio: ["ignore", "pipe", "pipe"] }));
      const done = ended(child);
      // No deadline of the test's own, which a loaded machine could beat: the wait ends once the
      // spy holds or the drill has ended, so a drill that fails first fails the test at once with
      // its own reason, and one that does neither meets tests/run's time limit for a test, whose
      // end stops the wait and, through owned, the drill.
      await until(() => holding.read("held") !== null || child.exitCode !== null || child.signalCode !== null, Infinity, t.signal);
      if (holding.read("held") === null) {
        const early = await done;
        assert.fail(`the ${signal} drill ended before its restore held (exit ${early.code ?? early.signal}): ${early.stdout}${early.stderr}`);
      }
      child.kill(signal);
      const result = await done;
      assert.equal(result.code, 128 + { SIGINT: 2, SIGTERM: 15, SIGHUP: 1 }[signal], result.stderr);
      const out = JSON.parse(result.stdout);
      assert.equal(out.failed, `the drill was stopped (${signal})`);
      assert.deepEqual(out.cleanup, { gone: true });
      assert.ok(gone(out.container), out.container);
      assert.deepEqual(drillsOf(copy), []);
    }
  });
});

// A fixture Conventioner: a git checkout whose back-end/ builds a small Python image with pymongo
// and holds migrations, at commit `base` on main; a later commit, `release`, is only on its
// origin, a bare repository that stands in for GitHub: the checkout's origin is Conventioner's
// URL, and a HOME's git config (originFor) sends that URL to the bare repository, or nowhere.
const pythonImage = "python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1";
// What one fixture migration prints and uses in a field's name: never to reach an answer.
const printed = "printed-by-a-migration@example.com";

function fixtureConventioner() {
  const dir = tempDir("conventioner");
  const work = join(dir, "checkout");
  const bare = join(dir, "origin.git");
  const gitHome = join(dir, "home");
  mkdirSync(gitHome);
  const identity = { GIT_AUTHOR_NAME: "Fixture", GIT_AUTHOR_EMAIL: "fixture@example.com", GIT_COMMITTER_NAME: "Fixture", GIT_COMMITTER_EMAIL: "fixture@example.com" };
  const git = (cwd, ...args) =>
    execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: { PATH: process.env.PATH, HOME: gitHome, GIT_CONFIG_NOSYSTEM: "1", ...identity } }).trim();
  const migration = (body) => `import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from db_config import get_database

db = get_database()
${body}`;
  const files = {
    "README.md": "A fixture of Conventioner for the prod-mongo toolkit's tests.\n",
    "back-end/Dockerfile": `FROM ${pythonImage}
RUN pip install --no-cache-dir --disable-pip-version-check pymongo==4.10.1 && useradd -m -u 1000 appuser
WORKDIR /app
COPY . .
USER appuser
`,
    "back-end/.dockerignore": "tests/\n",
    "back-end/db_config.py": `import os
from pymongo import MongoClient


def get_database(db_name="conventioner"):
    return MongoClient(os.environ["MONGODB_URI"], serverSelectionTimeoutMS=5000)[db_name]
`,
    "back-end/migrations/open_big_markets.py": migration(`result = db.markets.update_many({"stalls": {"$gte": 20}}, {"$set": {"phase": "open"}})
print(f"opened {result.modified_count} markets")
`),
    "back-end/migrations/tidy_accounts.py": migration(`db.accounts.update_one({"role": "vendor"}, {"$set": {"role": "seller", "flag for ${printed}": True}})
db.archived.insert_one({"_id": 7, "note": "kept"})
db.applications.delete_one({"vendor.name": "Vendor 3"})
db.markets.create_index("city", name="city_1")
print("contact: ${printed}")
print("warned: ${printed}", file=sys.stderr)
`),
    "back-end/migrations/exits_three.py": migration(`db.archived.insert_one({"_id": 8})
sys.exit(3)
`),
    // A dry run as Conventioner's migrations take one: --dry-run counts, and only the real run writes.
    "back-end/migrations/close_small_markets.py": migration(`dry_run = "--dry-run" in sys.argv
if dry_run:
    print(f"would close {db.markets.count_documents({'stalls': {'$lt': 20}})} markets")
else:
    result = db.markets.update_many({"stalls": {"$lt": 20}}, {"$set": {"phase": "closed"}})
    print(f"closed {result.modified_count} markets")
`),
    // A dry run that writes all the same.
    "back-end/migrations/leaky_dry_run.py": migration(`dry_run = "--dry-run" in sys.argv
db.archived.insert_one({"_id": 9 if dry_run else 10})
print("dry run" if dry_run else "real run")
`),
    "back-end/migrations/waits.py": migration(`print("waiting", flush=True)
import time

time.sleep(300)
`),
  };
  const write = (path, text) => {
    mkdirSync(dirname(join(work, path)), { recursive: true });
    writeFileSync(join(work, path), text);
  };
  mkdirSync(work);
  git(work, "init", "--quiet", "--initial-branch", "main");
  for (const [path, text] of Object.entries(files)) write(path, text);
  git(work, "add", "--all");
  git(work, "commit", "--quiet", "--message", "base");
  const base = git(work, "rev-parse", "HEAD");
  git(dir, "clone", "--quiet", "--bare", work, bare);
  git(work, "remote", "add", "origin", "https://github.com/chanjdaniel/Conventioner.git");
  // The checkout has fetched origin's main once, as any clone has: a rehearsal takes only a commit
  // a branch of origin's holds.
  git(work, "update-ref", "refs/remotes/origin/main", base);
  // The release's commit, pushed to the origin and then forgotten here: only a fetch brings its branch.
  git(work, "checkout", "--quiet", "-b", "release");
  write("back-end/migrations/open_big_markets.py", migration(`db.markets.update_many({"stalls": {"$gte": 20}}, {"$set": {"phase": "open", "opened_by": "release"}})
`));
  git(work, "commit", "--quiet", "--all", "--message", "release");
  const release = git(work, "rev-parse", "HEAD");
  git(work, "push", "--quiet", bare, "release");
  git(work, "checkout", "--quiet", "main");
  git(work, "branch", "--quiet", "-D", "release");
  // Where a HOME's git finds Conventioner's URL: the bare repository, or with `reachable` false nowhere.
  const originFor = (forHome, reachable = true) =>
    writeFileSync(join(forHome, ".gitconfig"), `[url "${reachable ? `file://${bare}` : join(dir, "nowhere.git")}"]\n\tinsteadOf = https://github.com/chanjdaniel/Conventioner.git\n`);
  return { dir, work, bare, base, release, git, write, originFor };
}

describe("rehearse-migrations", () => {
  const { BSON } = createRequire(join(repoRoot, "servers", "package.json"))("mongodb");
  const script = join(repoRoot, "toolkits", "prod-mongo", "scripts", "rehearse.mjs");
  const label = `label=${teamLabel("toolkit")}=prod-mongo`;
  // The first build pulls the Python image and installs pymongo.
  const long = { timeoutMs: 15 * 60_000 };
  let repo;
  before(() => {
    repo = fixtureConventioner();
  });
  beforeEach(() => repo.originFor(home));
  const rehearseServer = (body, options = {}) => drillServer(body, { cwd: repo.work, ...options });
  const timedRehearsal = (text) => text.replace(/ \((\d+ min )?\d+ s\)$/m, " (<time>)").replace(/ in (\d+ min )?\d+ s/g, " in <time>");
  const rehearsalsOf = (stamp) => (existsSync(join(root, stamp, "rehearsals")) ? readdirSync(join(root, stamp, "rehearsals")) : []);
  const hashed = (id) => `sha256:${createHash("sha256").update(JSON.stringify(id)).digest("hex").slice(0, 12)}`;
  const listed = (...args) => execFileSync(realDocker, [...args, "--filter", label], { encoding: "utf8" }).trim();
  const shownBackup = (stamp) => `~/conventioner-backups/${stamp}`;

  // What the spy docker saw the rehearsal make, each by its name, and that none of it is left, nor
  // any volume of the toolkit's.
  function madeAndGone() {
    const calls = docker.calls();
    const built = calls.find(([command]) => command === "build");
    const image = built[built.indexOf("--tag") + 1];
    const network = calls.find(([command, sub]) => command === "network" && sub === "create").at(-1);
    const runs = calls.filter(([command]) => command === "run");
    const containers = runs.map((run) => run[run.indexOf("--name") + 1]);
    for (const container of containers) assert.ok(gone(container), `${container} is still there`);
    assert.notEqual(spawnSync(realDocker, ["network", "inspect", network], { stdio: "pipe" }).status, 0, `network ${network} is still there`);
    assert.notEqual(spawnSync(realDocker, ["image", "inspect", image], { stdio: "pipe" }).status, 0, `image ${image} is still there`);
    for (const [what, names] of [["container", listed("container", "ls", "--all", "--format", "{{.Names}}")], ["network", listed("network", "ls", "--format", "{{.Name}}")], ["image", listed("image", "ls", "--format", "{{.Repository}}:{{.Tag}}")]]) {
      for (const name of names.split("\n").filter(Boolean)) assert.ok(!name.includes(network) && name !== image, `the ${what} ${name} is left`);
    }
    assert.equal(listed("volume", "ls", "--quiet"), "", "a volume of the toolkit's is left");
    return { image, network, runs, containers, calls };
  }

  test("takes a ref, 1 to 20 script names and a backup's name, each held to its pattern", async () => {
    await withServer(async (server) => {
      const tool = (await server.listTools()).find(({ name }) => name === "rehearse-migrations");
      const { properties, required, additionalProperties } = tool.inputSchema;
      assert.deepEqual(Object.keys(properties), ["ref", "migrations", "backup"]);
      assert.deepEqual(required, ["ref", "migrations"]);
      assert.equal(additionalProperties, false);
      assert.equal(properties.migrations.items.pattern, "^[A-Za-z0-9_]+\\.py$");
      assert.deepEqual([properties.migrations.minItems, properties.migrations.maxItems], [1, 20]);
      assert.equal(properties.backup.pattern, "^\\d{4}-\\d{2}-\\d{2}T\\d{6}Z$");
      assert.ok(new RegExp(properties.ref.pattern).test("origin/release-2026.11_a"));
      for (const bad of ["--upload-pack=x", "a b", "main;id", "", "x".repeat(201)]) assert.ok(!new RegExp(properties.ref.pattern).test(bad), bad);
    });
  });

  test("runs each migration of the commit on a restored dump, dry first where it takes --dry-run, and answers what each changed by counts, ids and fields, never its output", async () => {
    const stamp = await takeBackup();
    const vendor3 = (await production.client.db("conventioner").collection("applications").findOne({ "vendor.name": "Vendor 3" }))._id.toHexString();
    // This HOME's git cannot reach the origin: the fetch fails, and the commit is one origin's main
    // held when the checkout last fetched it.
    repo.originFor(home, false);
    let text;
    await rehearseServer(async (server) => {
      const result = await server.callTool("rehearse-migrations", { ref: repo.base, migrations: ["open_big_markets.py", "tidy_accounts.py", "close_small_markets.py"] }, long);
      assert.ok(!result.isError, result.text);
      text = result.text;
      const backupsListed = await server.callTool("list-backups", {});
      assert.match(backupsListed.text, new RegExp(`^- ${stamp}: .*, verified; 0 drills, 1 rehearsal, 0 undos, 0 diffs$`, "m"));
    });
    const [at] = rehearsalsOf(stamp);
    assert.deepEqual(rehearsalsOf(stamp), [at]);
    assert.match(at, /^\d{4}-\d{2}-\d{2}T\d{6}Z$/);
    const opened = [marketIds[0], marketIds[1]].sort();
    assert.deepEqual(timedRehearsal(text).split("\n"), [
      `Rehearsal of ${repo.base.slice(0, 8)} on ${shownBackup(stamp)}: 3 migrations ran, nothing left running (<time>)`,
      "1. open_big_markets.py (no dry run): exit 0 in <time>",
      `   - markets: 3 -> 3, 2 changed (phase: 2): ${opened.join(", ")}`,
      "2. tidy_accounts.py (no dry run): exit 0 in <time>",
      `   - accounts: 2 -> 2, 1 changed (role: 1, other fields: 1): ${hashed(email)}`,
      `   - applications: 5 -> 4, 1 removed: ${vendor3}`,
      "   - archived: 0 -> 1, 1 added: 7",
      "   - markets: 3 -> 3, indexes added: city_1",
      "3. close_small_markets.py --dry-run: exit 0 in <time>, wrote nothing",
      "   close_small_markets.py: exit 0 in <time>",
      `   - markets: 3 -> 3, 1 changed (phase: 1): ${marketIds[2]}`,
      `Logs, for Daniel to read in a terminal (never quoted here): ${shownBackup(stamp)}/rehearsals/${at}/ (1-open_big_markets.py.run.log, 1 line; 2-tidy_accounts.py.run.log, 2 lines; 3-close_small_markets.py.dry-run.log, 1 line; 3-close_small_markets.py.run.log, 1 line)`,
      "git fetch origin failed, so the ref was read as this checkout last fetched it.",
    ]);

    // The logs hold the migrations' own output, for Daniel alone; the answer and the report none of it.
    const dir = join(root, stamp, "rehearsals", at);
    assert.deepEqual(readdirSync(dir).sort(), ["1-open_big_markets.py.run.log", "2-tidy_accounts.py.run.log", "3-close_small_markets.py.dry-run.log", "3-close_small_markets.py.run.log", "report.json"]);
    assert.equal(statSync(join(root, stamp, "rehearsals")).mode & 0o777, 0o700);
    assert.equal(statSync(dir).mode & 0o777, 0o700);
    for (const file of readdirSync(dir)) assert.equal(statSync(join(dir, file)).mode & 0o777, 0o600, file);
    assert.equal(readFileSync(join(dir, "1-open_big_markets.py.run.log"), "utf8"), "opened 2 markets\n");
    assert.deepEqual(readFileSync(join(dir, "2-tidy_accounts.py.run.log"), "utf8").split("\n").filter(Boolean).sort(), [`contact: ${printed}`, `warned: ${printed}`]);
    assert.equal(readFileSync(join(dir, "3-close_small_markets.py.dry-run.log"), "utf8"), "would close 1 markets\n");
    assert.equal(readFileSync(join(dir, "3-close_small_markets.py.run.log"), "utf8"), "closed 1 markets\n");
    const reportText = readFileSync(join(dir, "report.json"), "utf8");
    for (const hidden of [printed, "printed-by", email, "opened 2", "Riverside", homedir()]) {
      assert.ok(!text.includes(hidden), `the answer holds ${hidden}`);
      assert.ok(!reportText.includes(hidden), `the report holds ${hidden}`);
    }
    const report = JSON.parse(reportText);
    assert.deepEqual({ at: report.at, stamp: report.stamp, sha: report.sha, image: report.image }, { at, stamp, sha: repo.base, image: mongoImage });
    assert.deepEqual(report.steps.map(({ n, script: name, mode, exit, log, lines }) => ({ n, name, mode, exit, log, lines })), [
      { n: 1, name: "open_big_markets.py", mode: "run", exit: 0, log: "1-open_big_markets.py.run.log", lines: 1 },
      { n: 2, name: "tidy_accounts.py", mode: "run", exit: 0, log: "2-tidy_accounts.py.run.log", lines: 2 },
      { n: 3, name: "close_small_markets.py", mode: "dry-run", exit: 0, log: "3-close_small_markets.py.dry-run.log", lines: 1 },
      { n: 3, name: "close_small_markets.py", mode: "run", exit: 0, log: "3-close_small_markets.py.run.log", lines: 1 },
    ]);
    assert.equal(report.stopped, undefined);
    assert.deepEqual(report.notRun, []);
    assert.deepEqual(report.steps[0].collections.map(({ collection }) => collection), ["accounts", "applications", "archived", "markets", "open_markets"]);
    assert.deepEqual(report.steps[1].collections.find(({ collection }) => collection === "accounts"), {
      collection: "accounts", before: 2, after: 2, added: [], removed: [], changed: [hashed(email)], fields: { role: 1 }, otherFields: 1, indexesAdded: [], indexesRemoved: [],
    });

    // In Docker: an image built from the commit on stdin, a network with no route out, the
    // throwaway on it as `mongodb`, each migration on that network alone, and none of it left.
    const { image, network, runs, calls } = madeAndGone();
    assert.equal(image, `agent-team-rehearsal:${repo.base.slice(0, 12)}`);
    const build = calls.find(([command]) => command === "build");
    assert.equal(build.at(-1), "-");
    const created = calls.find(([command, sub]) => command === "network" && sub === "create");
    assert.ok(created.includes("--internal"), "the network is not --internal");
    assert.match(network, /^prod-mongo-rehearsal-[0-9a-f]{12}$/);
    for (const call of [build, created, ...runs]) {
      for (const pair of [`${teamLabel("owner")}=agent-team`, `${teamLabel("kind")}=drill`, `${teamLabel("toolkit")}=prod-mongo`]) assert.ok(call.includes(pair), `docker ${call[0]} has no label ${pair}`);
      assert.ok(call.some((arg) => arg.startsWith(`${teamLabel("expires")}=`)), `docker ${call[0]} has no expires`);
    }
    assert.equal(runs.length, 5);
    const [throwaway, ...migrations] = runs;
    assert.ok(!throwaway.includes("--network"), "the throwaway is not on the default bridge");
    assert.deepEqual(calls.find(([command, sub]) => command === "network" && sub === "connect"), ["network", "connect", "--alias", "mongodb", network, network]);
    const expected = [
      [`${network}-run-1`, "open_big_markets.py"], [`${network}-run-2`, "tidy_accounts.py"],
      [`${network}-dry-run-3`, "close_small_markets.py", "--dry-run"], [`${network}-run-3`, "close_small_markets.py"],
    ];
    for (const [n, run] of migrations.entries()) {
      const [container, name, ...dry] = expected[n];
      assert.equal(run[run.indexOf("--name") + 1], container);
      assert.deepEqual(run.slice(run.indexOf(image)), [image, "timeout", "600", "python", `migrations/${name}`, ...dry]);
      assert.deepEqual(run.filter((arg, index) => run[index - 1] === "--network"), [network]);
      assert.deepEqual(run.filter((arg, index) => run[index - 1] === "--env"), ["MONGODB_URI"]);
      for (const pair of ["--rm", "--pull never", "--memory 1g"]) assert.ok(run.join(" ").includes(pair), `docker run has no ${pair}`);
      assert.ok(!run.includes("--publish") && !run.includes("-p"), "a migration's container publishes a port");
    }
    // The throwaway's URI, with its password: in each migration's docker run's own environment only.
    const uri = /^MONGODB_URI=(mongodb:\/\/root:([0-9a-f]{48})@mongodb:27017\/\?authSource=admin)$/m.exec(docker.read(`run-environ-${network}-run-1`));
    assert.ok(uri, "the migration's docker run has no MONGODB_URI for the host mongodb");
    for (const call of calls) assert.ok(!call.join(" ").includes(uri[2]), `the password is in docker ${call[0]}'s argument list`);
    assert.ok(!text.includes(uri[2]) && !reportText.includes(uri[2]));
    for (const { path, stat } of walk(home)) {
      assert.ok(!stat.isFIFO(), `${path} is a FIFO`);
      if (stat.isFile()) assert.ok(!readFileSync(path).includes(uri[2]), `${path} holds the password`);
    }
    // Production: untouched.
    assert.equal(await production.client.db("conventioner").collection("markets").countDocuments({ phase: { $exists: true } }), 0);
    assert.equal(await production.client.db("conventioner").collection("applications").countDocuments({}), 5);
  });

  test("fetches, then runs the commit a ref of the origin names, whatever the checkout's own files hold", async () => {
    const stamp = await takeBackup();
    // The checkout's own copy of the script, uncommitted, would drop a collection.
    const own = join(repo.work, "back-end", "migrations", "open_big_markets.py");
    const committed = readFileSync(own, "utf8");
    writeFileSync(own, `${committed}db.accounts.drop()\n`);
    try {
      assert.throws(() => repo.git(repo.work, "rev-parse", "--verify", "--quiet", "origin/release"), "the checkout already holds origin/release");
      await rehearseServer(async (server) => {
        const result = await server.callTool("rehearse-migrations", { ref: "origin/release", migrations: ["open_big_markets.py"], backup: stamp }, long);
        assert.ok(!result.isError, result.text);
        const opened = [marketIds[0], marketIds[1]].sort();
        assert.deepEqual(timedRehearsal(result.text).split("\n").slice(0, 3), [
          `Rehearsal of ${repo.release.slice(0, 8)} on ${shownBackup(stamp)}: 1 migration ran, nothing left running (<time>)`,
          "1. open_big_markets.py (no dry run): exit 0 in <time>",
          `   - markets: 3 -> 3, 2 changed (opened_by: 2, phase: 2): ${opened.join(", ")}`,
        ]);
        assert.ok(!result.text.includes("git fetch"), result.text);
      });
      assert.equal(madeAndGone().image, `agent-team-rehearsal:${repo.release.slice(0, 12)}`);
    } finally {
      writeFileSync(own, committed);
    }
  });

  test("refuses before Docker is touched: a ref that names no commit, a script not at it, another repository's checkout, no checkout, and input outside its patterns", async () => {
    const stamp = await takeBackup();
    const other = tempDir("other-repository");
    repo.git(other, "clone", "--quiet", repo.bare, "checkout");
    repo.git(join(other, "checkout"), "remote", "set-url", "origin", "https://github.com/chanjdaniel/agent-team.git");
    const cases = [
      { input: { ref: "no-such-branch", migrations: ["open_big_markets.py"] }, reason: "no-such-branch names no branch or tag of Chan-Software-Services/Conventioner's origin, nor a commit on one of its branches, in this checkout" },
      { input: { ref: repo.base, migrations: ["open_big_markets.py", "not_there.py"] }, reason: `back-end/migrations/not_there.py is not a file at ${repo.base.slice(0, 8)}` },
      { input: { ref: repo.base, migrations: ["open_big_markets.py"], backup: "2020-01-01T000000Z" }, reason: "~/conventioner-backups holds no backup 2020-01-01T000000Z" },
      { input: { ref: "--upload-pack=touch", migrations: ["open_big_markets.py"] }, reason: "ref must be a commit sha, a branch or a tag, of letters, digits and . _ / - only" },
      { input: { ref: repo.base, migrations: ["../../app.py"] }, reason: "migrations must be 1 to 20 script names, each as migrate_phase.py" },
      { input: { ref: repo.base, migrations: [] }, reason: "migrations must be 1 to 20 script names, each as migrate_phase.py" },
      { input: { ref: repo.base, migrations: Array(21).fill("open_big_markets.py") }, reason: "migrations must be 1 to 20 script names, each as migrate_phase.py" },
      { input: { migrations: ["open_big_markets.py"] }, reason: "ref must be a commit sha, a branch or a tag, of letters, digits and . _ / - only" },
      { input: { ref: repo.base, migrations: ["open_big_markets.py"], cwd: "/" }, whole: "rehearse-migrations: takes no cwd" },
      { cwd: join(other, "checkout"), input: { ref: repo.base, migrations: ["open_big_markets.py"] }, reason: "the working directory's origin is not Chan-Software-Services/Conventioner, whose migrations a rehearsal runs" },
      { cwd: other, input: { ref: repo.base, migrations: ["open_big_markets.py"] }, reason: "the working directory is not a git checkout with an origin, so it is not a checkout of Chan-Software-Services/Conventioner" },
    ];
    for (const { cwd = repo.work, input, reason, whole } of cases) {
      await rehearseServer(async (server) => {
        const result = await server.callTool("rehearse-migrations", input);
        assert.ok(result.isError, result.text);
        assert.equal(result.text, whole ?? `rehearse-migrations: failed: ${reason}`);
      }, { cwd });
    }
    assert.deepEqual(docker.calls(), []);
    assert.deepEqual(rehearsalsOf(stamp), []);
  });

  test("a checkout's origin may name the repository under either owner, over https or ssh, and no other", () => {
    const checkout = join(tempDir("origins"), "checkout");
    repo.git(dirname(checkout), "clone", "--quiet", repo.bare, "checkout");
    const repositories = ["Chan-Software-Services/Conventioner", "chanjdaniel/Conventioner"];
    // A URL that carries a token, built here so this file holds nothing shaped like an address.
    const withToken = ["https://x-access-token:abc", "github.com/Chan-Software-Services/Conventioner.git/"].join("@");
    const refusalOf = (url) => {
      repo.git(checkout, "remote", "set-url", "origin", url);
      return checkoutRefusal(checkout, repositories);
    };
    for (const url of [
      "https://github.com/Chan-Software-Services/Conventioner.git", "https://github.com/chanjdaniel/Conventioner", "git@github.com:chan-software-services/conventioner.git",
      "ssh://git@github.com/chanjdaniel/Conventioner.git", withToken,
    ]) {
      assert.equal(refusalOf(url), undefined, url);
    }
    for (const url of [
      "https://github.com/someone/Conventioner.git", "https://github.com/chanjdaniel/Conventioner-fork.git", "https://example.com/chanjdaniel/Conventioner.git",
      "https://notgithub.com/chanjdaniel/Conventioner.git", "https://github.com/chanjdaniel/Conventioner/extra.git", repo.bare,
      // Another host, or a local path, whose path only ends in GitHub's.
      "https://other.example/github.com/Chan-Software-Services/Conventioner.git", "file:///srv/mirror/github.com/Chan-Software-Services/Conventioner",
      "/srv/mirror/github.com/Chan-Software-Services/Conventioner", "ssh://git@other.example/github.com/chanjdaniel/Conventioner.git",
    ]) {
      const refusal = refusalOf(url);
      assert.equal(refusal, "the working directory's origin is not Chan-Software-Services/Conventioner, whose migrations a rehearsal runs", url);
      assert.ok(!refusal.includes(url));
    }
  });

  test("a ref names origin's branch or tag, never a local branch or tag of the same name, and a commit only when a branch of origin holds it", () => {
    // An origin of its own, so the tags pushed here reach no other test.
    const dir = tempDir("refs");
    repo.git(dir, "clone", "--quiet", "--bare", repo.bare, "origin.git");
    repo.git(dir, "clone", "--quiet", join(dir, "origin.git"), "checkout");
    const checkout = join(dir, "checkout");
    // Origin's tags: v1 on the release's commit, and v2, annotated, on it too.
    repo.git(checkout, "tag", "v1", repo.release);
    repo.git(checkout, "tag", "--annotate", "--message", "v2", "v2", repo.release);
    repo.git(checkout, "push", "--quiet", "origin", "v1", "v2");
    // Here: a stale local release at base, while origin's is a commit ahead; v1 moved to base; main
    // moved on by a commit never pushed, and a tag on it origin never had.
    repo.git(checkout, "branch", "--quiet", "release", repo.base);
    repo.git(checkout, "tag", "--force", "v1", repo.base);
    repo.git(checkout, "commit", "--quiet", "--allow-empty", "--message", "never pushed");
    const local = repo.git(checkout, "rev-parse", "HEAD");
    repo.git(checkout, "tag", "local-only");
    const repository = "Chan-Software-Services/Conventioner";
    const resolved = (ref) => resolveRef(checkout, ref, repository);
    for (const [ref, sha] of [["release", repo.release], ["origin/release", repo.release], ["main", repo.base], ["v1", repo.release], ["v2", repo.release], [repo.base, repo.base], [repo.base.slice(0, 10), repo.base]]) {
      assert.deepEqual(resolved(ref), { sha }, ref);
    }
    const unpushed = (ref) => ({ refusal: `${ref} names ${local.slice(0, 8)}, which no branch of ${repository}'s origin holds in this checkout: only a pushed commit is rehearsed` });
    assert.deepEqual(resolved(local), unpushed(local));
    assert.deepEqual(resolved(local.slice(0, 12)), unpushed(local.slice(0, 12)));
    for (const ref of ["local-only", "no-such-branch"]) {
      assert.deepEqual(resolved(ref), { refusal: `${ref} names no branch or tag of ${repository}'s origin, nor a commit on one of its branches, in this checkout` }, ref);
    }
    // Origin out of reach: a branch is still read as the checkout last fetched it, but a tag, read
    // from origin at the call, is not, nor is the local tag of its name, and the refusal says why.
    renameSync(join(dir, "origin.git"), join(dir, "gone.git"));
    assert.deepEqual(resolved("release"), { sha: repo.release });
    for (const ref of ["v1", "local-only"]) {
      assert.deepEqual(resolved(ref), {
        refusal: `${ref} names no branch of ${repository}'s origin, nor a commit on one of its branches, in this checkout, and origin's tags could not be listed (git ls-remote origin failed), so it was not read as a tag`,
      }, ref);
    }
  });

  // The script as Daniel runs it: from the checkout, with no MCP server and no op; it ends with
  // test `t`.
  const byHand = (t, args, { cwd = repo.work, heavy = true } = {}) => {
    const env = { HOME: home, PATH: [docker.dir, toolsDir, testPath()].join(":"), PROD_MONGO_ROOT: root };
    const command = heavy ? [join(repoRoot, "bin", "team-heavy"), "run", "--kind", "rehearsal", "--", process.execPath, script, ...args] : [process.execPath, script, ...args];
    return owned(t, spawn(command[0], command.slice(1), { cwd, env, stdio: ["ignore", "pipe", "pipe"] }));
  };

  test("run by hand through team-heavy: one JSON object, stopped at a migration that exits non-zero with its exit code, the next not run, and exit 1", async (t) => {
    const stamp = await takeBackup();
    const ran = await ended(byHand(t, [stamp, repo.base, "exits_three.py", "close_small_markets.py"]));
    assert.equal(ran.code, 1, ran.stderr);
    assert.equal(ran.stdout.split("\n").filter(Boolean).length, 1, ran.stdout);
    const result = JSON.parse(ran.stdout);
    assert.deepEqual(result.steps.map(({ script: name, mode, exit }) => [name, mode, exit]), [["exits_three.py", "run", 3]]);
    assert.deepEqual(result.steps[0].collections.map(({ collection, added }) => [collection, added]), [["archived", { count: 1, ids: ["8"] }]]);
    assert.deepEqual(result.stopped, { n: 1, script: "exits_three.py", mode: "run", exit: 3, signal: null, timedOut: false, wrote: false });
    assert.deepEqual(result.notRun, [{ n: 2, script: "close_small_markets.py", mode: "dry-run" }, { n: 2, script: "close_small_markets.py", mode: "run" }]);
    assert.deepEqual(result.cleanup, { gone: true, left: [] });
    assert.equal(result.folder, shownBackup(stamp));
    assert.match(ran.stderr, /^rehearse-migrations: running exits_three\.py \(1 of 2\)$/m);
    assert.doesNotMatch(ran.stderr, /running close_small_markets/);
    // --text prints the tool's own answer to that JSON.
    const at = result.at;
    assert.deepEqual(timedRehearsal(rehearsalAnswer(result).text).split("\n"), [
      `Rehearsal of ${repo.base.slice(0, 8)} on ${shownBackup(stamp)}: stopped at 1 of 2 migrations, nothing left running (<time>)`,
      "1. exits_three.py (no dry run): exit 3 in <time>",
      "   - archived: 0 -> 1, 1 added: 8",
      "Stopped: exits_three.py exited 3.",
      "Not run: close_small_markets.py --dry-run, close_small_markets.py.",
      `Logs, for Daniel to read in a terminal (never quoted here): ${shownBackup(stamp)}/rehearsals/${at}/ (1-exits_three.py.run.log, 0 lines)`,
    ]);
    assert.equal(rehearsalAnswer(result).isError, true);
    // The report and the logs so far are kept, and nothing is left in Docker.
    const report = JSON.parse(readFileSync(join(root, stamp, "rehearsals", at, "report.json"), "utf8"));
    assert.deepEqual([report.stopped, report.notRun], [result.stopped, result.notRun]);
    assert.deepEqual(readdirSync(join(root, stamp, "rehearsals", at)).sort(), ["1-exits_three.py.run.log", "report.json"]);
    assert.equal(madeAndGone().runs.length, 2);

    const refused = await ended(byHand(t, [stamp, repo.base.slice(0, 12), "open_big_markets.py", "--text"]));
    assert.equal(refused.code, 1);
    assert.equal(refused.stdout, "rehearse-migrations: failed: takes a backup's name, a commit's full sha and 1 to 20 migration scripts' names, each as migrate_phase.py (and --text for the answer as text)\n");
    const elsewhere = await ended(byHand(t, [stamp, repo.base, "open_big_markets.py"], { cwd: repo.dir }));
    assert.deepEqual(JSON.parse(elsewhere.stdout), { refused: "the working directory is not a git checkout with an origin, so it is not a checkout of Chan-Software-Services/Conventioner" });
  });

  test("removes the migration's container, the throwaway, the network and the image when stopped by a signal, and writes no report", async (t) => {
    const stamp = await takeBackup();
    const child = byHand(t, [stamp, repo.base, "waits.py"], { heavy: false });
    const done = ended(child);
    const log = () => {
      const [at] = rehearsalsOf(stamp).filter((name) => !name.startsWith("."));
      const path = at && join(root, stamp, "rehearsals", at, "1-waits.py.run.log");
      return path && existsSync(path) ? readFileSync(path, "utf8") : "";
    };
    await until(() => log().includes("waiting") || child.exitCode !== null, 15 * 60_000);
    child.kill("SIGTERM");
    const result = await done;
    assert.equal(result.code, 143, result.stderr + result.stdout);
    const out = JSON.parse(result.stdout);
    assert.equal(out.failed, "the rehearsal was stopped (SIGTERM)");
    assert.deepEqual(out.cleanup, { gone: true, left: [] });
    const { containers } = madeAndGone();
    assert.equal(containers.length, 2);
    const [at] = rehearsalsOf(stamp);
    assert.equal(out.logs, `${shownBackup(stamp)}/rehearsals/${at}/`);
    assert.deepEqual(readdirSync(join(root, stamp, "rehearsals", at)), ["1-waits.py.run.log"]);
  });

  test("stops at a dry run that wrote, naming what it wrote, before its real run and the migrations after it; keeps the report and the logs, and leaves nothing in Docker", async () => {
    const stamp = await takeBackup();
    let result;
    await rehearseServer(async (server) => {
      result = await server.callTool("rehearse-migrations", { ref: repo.base, migrations: ["close_small_markets.py", "leaky_dry_run.py", "exits_three.py"], backup: stamp }, long);
    });
    assert.equal(result.isError, true, result.text);
    const [at] = rehearsalsOf(stamp);
    assert.deepEqual(timedRehearsal(result.text).split("\n"), [
      `Rehearsal of ${repo.base.slice(0, 8)} on ${shownBackup(stamp)}: stopped at 2 of 3 migrations, nothing left running (<time>)`,
      "1. close_small_markets.py --dry-run: exit 0 in <time>, wrote nothing",
      "   close_small_markets.py: exit 0 in <time>",
      `   - markets: 3 -> 3, 1 changed (phase: 1): ${marketIds[2]}`,
      "2. leaky_dry_run.py --dry-run: exit 0 in <time>",
      "   - archived: 0 -> 1, 1 added: 9",
      "Stopped: the dry run of leaky_dry_run.py wrote: archived: 0 -> 1, 1 added.",
      "Not run: leaky_dry_run.py, exits_three.py.",
      `Logs, for Daniel to read in a terminal (never quoted here): ${shownBackup(stamp)}/rehearsals/${at}/ (1-close_small_markets.py.dry-run.log, 1 line; 1-close_small_markets.py.run.log, 1 line; 2-leaky_dry_run.py.dry-run.log, 1 line)`,
    ]);
    const dir = join(root, stamp, "rehearsals", at);
    assert.deepEqual(readdirSync(dir).sort(), ["1-close_small_markets.py.dry-run.log", "1-close_small_markets.py.run.log", "2-leaky_dry_run.py.dry-run.log", "report.json"]);
    for (const file of readdirSync(dir)) assert.equal(statSync(join(dir, file)).mode & 0o777, 0o600, file);
    const report = JSON.parse(readFileSync(join(dir, "report.json"), "utf8"));
    assert.deepEqual(report.stopped, { n: 2, script: "leaky_dry_run.py", mode: "dry-run", exit: 0, signal: null, timedOut: false, wrote: true });
    assert.deepEqual(report.notRun, [{ n: 2, script: "leaky_dry_run.py", mode: "run" }, { n: 3, script: "exits_three.py", mode: "run" }]);
    // The real run of the leaky script never ran: no container of it, and no document 10.
    const { runs, network } = madeAndGone();
    assert.deepEqual(runs.slice(1).map((run) => run[run.indexOf("--name") + 1]), [`${network}-dry-run-1`, `${network}-run-1`, `${network}-dry-run-2`]);
    assert.deepEqual(runs.at(-1).slice(-2), ["migrations/leaky_dry_run.py", "--dry-run"]);
  });

  test("a migration reaches the throwaway by its alias, and neither production's MongoDB, by its loopback port or its container, nor a public address", async () => {
    const stamp = await takeBackup();
    const inspect = (format, ...what) => execFileSync(realDocker, [...what, "--format", format], { encoding: "utf8" }).trim();
    const productionIp = inspect("{{.NetworkSettings.Networks.bridge.IPAddress}}", "container", "inspect", production.name);
    const gateway = inspect("{{(index .IPAM.Config 0).Gateway}}", "network", "inspect", "bridge");
    assert.match(productionIp, /^\d+\.\d+\.\d+\.\d+$/);
    // Each place production may be reached from a container, and two outside the machine.
    const targets = [
      ["production's loopback port, as the host's own", "127.0.0.1", production.port],
      ["production's loopback port, by host.docker.internal", "host.docker.internal", production.port],
      ["production's loopback port, by the default bridge's gateway", gateway, production.port],
      ["production's loopback port, by this network's first address", "first", production.port],
      ["production's container, on the default bridge", productionIp, 27017],
      ["a public address", "1.1.1.1", 443],
      ["a public name", "example.com", 443],
    ];
    const probe = (tries) => `import socket
tries = ${JSON.stringify(tries)}
for label, host, port in tries:
    if host == "first":
        host = ".".join(socket.gethostbyname(socket.gethostname()).split(".")[:3] + ["1"])
    try:
        socket.create_connection((host, port), timeout=3).close()
        print(f"reached {label}", flush=True)
    except OSError as error:
        print(f"could not reach {label}: {type(error).__name__}", flush=True)
`;
    // The probe itself reaches production's container from the default bridge, so its failures
    // below are the internal network's doing. The test's own container may pull the image, which
    // the rehearsal's build may have pulled into its build cache alone (as on CI).
    const control = execFileSync(realDocker, ["run", "--rm", "--pull", "missing", pythonImage, "python", "-c", probe([targets[4]])], { encoding: "utf8" });
    assert.equal(control, `reached ${targets[4][0]}\n`);
    repo.git(repo.work, "checkout", "--quiet", "-b", "reaches-out");
    repo.write("back-end/migrations/reaches_out.py", `${probe(targets)}import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from db_config import get_database

get_database().command("ping")
print("reached the throwaway as mongodb", flush=True)
`);
    repo.git(repo.work, "add", "--all");
    repo.git(repo.work, "commit", "--quiet", "--message", "reaches out");
    const sha = repo.git(repo.work, "rev-parse", "HEAD");
    repo.git(repo.work, "push", "--quiet", repo.bare, "reaches-out");
    repo.git(repo.work, "checkout", "--quiet", "main");
    let result;
    await rehearseServer(async (server) => {
      result = await server.callTool("rehearse-migrations", { ref: sha, migrations: ["reaches_out.py"], backup: stamp }, long);
    });
    assert.ok(!result.isError, result.text);
    const [at] = rehearsalsOf(stamp);
    const log = readFileSync(join(root, stamp, "rehearsals", at, "1-reaches_out.py.run.log"), "utf8").split("\n").filter(Boolean);
    assert.deepEqual(log.map((line) => line.replace(/: \w+$/, "")), [...targets.map(([what]) => `could not reach ${what}`), "reached the throwaway as mongodb"]);
    assert.ok(!result.text.includes("could not reach"), result.text);
    madeAndGone();
  });

  test("refuses a rehearsal while a backup runs, and answers that the machine is busy while another run holds the heavy-run lock, running nothing", async (t) => {
    spy.set("hold");
    await rehearseServer(async (server) => {
      const first = server.callTool("backup", {});
      await until(() => spy.read("held") !== null);
      const rehearsal = await server.callTool("rehearse-migrations", { ref: repo.base, migrations: ["open_big_markets.py"] });
      assert.deepEqual([rehearsal.isError, rehearsal.text], [true, "rehearse-migrations: a backup is already running"]);
      spy.set("go");
      assert.ok(!(await first).isError);
    });
    const [stamp] = backups();
    const lock = join(home, ".local", "state", "agent-team", "heavy.lock");
    mkdirSync(dirname(lock), { recursive: true });
    writeFileSync(lock, "the test's own run (pid 1) since now\n");
    // flock and its sleep, which holds the lock, both end with the test.
    owned(t, spawn("flock", [lock, "sleep", "300"], { stdio: "ignore" }));
    await until(() => spawnSync("flock", ["-n", lock, "true"]).status !== 0);
    await withServer(async (server) => {
      const result = await server.callTool("rehearse-migrations", { ref: repo.base, migrations: ["open_big_markets.py"], backup: stamp });
      assert.deepEqual([result.isError, result.text], [true, "rehearse-migrations: the machine is busy: the heavy-run lock is held by the test's own run (pid 1) since now; ask again later"]);
    }, { path: drillPath(), cwd: repo.work, env: { PROD_MONGO_HEAVY_WAIT_MINUTES: "0" } });
    assert.deepEqual(docker.calls(), [], "docker ran");
    assert.deepEqual(rehearsalsOf(stamp), []);
  });

  test("answers a back-end image that does not build with docker build's last line, scrubbed, and leaves nothing in Docker", async () => {
    const stamp = await takeBackup();
    // A build step that fails, printing a connection string and a document, as a failing step's
    // command line is echoed in docker build's error.
    const secret = `buildpw${randomBytes(6).toString("hex")}`;
    repo.git(repo.work, "checkout", "--quiet", "-b", "broken-build");
    const dockerfile = readFileSync(join(repo.work, "back-end", "Dockerfile"), "utf8");
    repo.write("back-end/Dockerfile", `${dockerfile}RUN echo 'mongodb://someone:${secret}@db.internal/x {"email": "${printed}"}' && exit 7\n`);
    repo.git(repo.work, "commit", "--quiet", "--all", "--message", "a build that fails");
    const sha = repo.git(repo.work, "rev-parse", "HEAD");
    repo.git(repo.work, "push", "--quiet", repo.bare, "broken-build");
    repo.git(repo.work, "checkout", "--quiet", "main");
    let result;
    await rehearseServer(async (server) => {
      result = await server.callTool("rehearse-migrations", { ref: sha, migrations: ["open_big_markets.py"], backup: stamp }, long);
    });
    assert.equal(result.isError, true, result.text);
    assert.match(result.text, /^rehearse-migrations: failed: the back-end image could not be built: docker build exited 1: .*\[uri\].*; nothing left running\.$/);
    for (const hidden of [secret, "someone", printed, "email"]) assert.ok(!result.text.includes(hidden), `the answer holds ${hidden}`);
    assert.deepEqual(rehearsalsOf(stamp), []);
    const image = `agent-team-rehearsal:${sha.slice(0, 12)}`;
    assert.notEqual(spawnSync(realDocker, ["image", "inspect", image], { stdio: "pipe" }).status, 0, `image ${image} is still there`);
    assert.ok(!docker.calls().some(([command, sub]) => command === "run" || (command === "network" && sub === "create")), "the rehearsal went on past its build");
  });

  test("the server stops a rehearsal past its bound and removes, by id, what the script made but could not remove", async () => {
    const stamp = await takeBackup();
    // The script's own removal hangs, as with a docker daemon that stopped answering, so only the
    // server's removal by id is left to remove what it made.
    docker.set("hang-rm");
    let result;
    await rehearseServer(async (server) => {
      result = await server.callTool("rehearse-migrations", { ref: repo.base, migrations: ["waits.py"], backup: stamp }, long);
    }, { env: { PROD_MONGO_BOUND_SECONDS: "45", PROD_MONGO_KILL_GRACE_SECONDS: "2" } });
    assert.equal(result.isError, true);
    assert.equal(result.text, "rehearse-migrations: failed: the rehearsal ran past its 45 s, so it was stopped; what it made in Docker was removed, so nothing was left running.");
    assert.ok(existsSync(join(docker.dir, "hung-rm")), "the script's removal never hung");
    // The migration was running when the bound came: its log has its first line.
    const [at] = rehearsalsOf(stamp).filter((name) => !name.startsWith("."));
    assert.equal(readFileSync(join(root, stamp, "rehearsals", at, "1-waits.py.run.log"), "utf8"), "waiting\n");
    const { runs, calls } = madeAndGone();
    assert.equal(runs.length, 2);
    // After the hung one, the server's removals, each by its id: the throwaway (the migration's
    // container ends with its docker run, which the TERM reached), the network and the image.
    const removals = calls.slice(calls.findIndex(([command]) => command === "rm") + 1).filter(([command, sub]) => command === "rm" || (["network", "image"].includes(command) && sub === "rm"));
    for (const call of removals) assert.match(call.at(-1), /^(sha256:)?[0-9a-f]{64}$/, call.join(" "));
    assert.deepEqual([...new Set(removals.map(([command]) => (command === "rm" ? "container" : command)))], ["container", "network", "image"]);
  });

  describe("the change engine", () => {
    const id = (document) => printableId(BSON.serialize(document), BSON);
    const gz = (documents) => {
      const path = join(tempDir("bson"), "collection.bson.gz");
      writeFileSync(path, gzipSync(Buffer.concat(documents.map((document) => BSON.serialize(document)))));
      return path;
    };

    test("a printable id is the top-level UUID id, else an ObjectId, UUID or integer _id or a document of those, else a hash", () => {
      const oid = new BSON.ObjectId();
      const uuid = randomUUID();
      assert.equal(id({ _id: oid, id: uuid }), uuid);
      assert.equal(id({ _id: oid, id: "not-a-uuid" }), oid.toHexString());
      assert.equal(id({ _id: oid }), oid.toHexString());
      assert.equal(id({ _id: uuid }), uuid);
      assert.equal(id({ _id: 42 }), "42");
      assert.equal(id({ _id: BSON.Long.fromString("9007199254740993") }), "9007199254740993");
      assert.equal(id({ _id: { market: uuid, day: 3, of: oid } }), `{market: ${uuid}, day: 3, of: ${oid.toHexString()}}`);
      for (const hidden of [email, "Riverside Night Market", 1.5, { name: "Vendor 1" }, { [email]: 1 }, { nested: { day: 1 } }, [1, 2], new Date(0), null, true]) {
        const printedId = id({ _id: hidden });
        const canonical = BSON.EJSON.stringify(BSON.deserialize(BSON.serialize({ _id: hidden }), { promoteValues: false, promoteLongs: false })._id, { relaxed: false });
        assert.equal(printedId, `sha256:${createHash("sha256").update(canonical).digest("hex").slice(0, 12)}`);
        assert.match(printedId, /^sha256:[0-9a-f]{12}$/);
      }
      assert.equal(id({ _id: email }), hashed(email));
      assert.notEqual(id({ _id: email }), id({ _id: `other-${email}` }));
    });

    test("a dump's snapshot is the live database's: nothing differs between a backup and what it was taken of", async () => {
      const stamp = await takeBackup();
      const fromDump = await snapshotDump(join(root, stamp, "dump", "conventioner"), BSON);
      const live = await snapshotDatabase(production.client.db("conventioner"), BSON);
      assert.deepEqual([...fromDump.keys()].sort(), ["accounts", "applications", "archived", "markets", "open_markets"]);
      assert.deepEqual(fromDump.get("open_markets"), { type: "view" });
      assert.equal(fromDump.get("applications").documents.size, 5);
      assert.deepEqual(fromDump.get("markets").indexes, ["_id_", "name_unique"]);
      const comparisons = compareDatabases(fromDump, live);
      assert.deepEqual(comparisons.filter(differs), []);
      assert.deepEqual(comparisons.map(({ collection, before, after }) => [collection, before, after]), [["accounts", 2, 2], ["applications", 5, 5], ["archived", 0, 0], ["markets", 3, 3], ["open_markets", null, null]]);
      // A write to production then differs from the dump, by that document and field alone.
      await production.client.db("conventioner").collection("markets").updateOne({ id: marketIds[2] }, { $set: { stalls: 16 } });
      const after = await snapshotDatabase(production.client.db("conventioner"), BSON);
      assert.deepEqual(compareDatabases(fromDump, after).filter(differs), [
        { collection: "markets", before: 3, after: 3, added: [], removed: [], changed: [marketIds[2]], fields: { stalls: 1 }, otherFields: 0, indexesAdded: [], indexesRemoved: [] },
      ]);
    });

    test("a comparison names a field only by a plain name, counts the rest as other fields, and lists at most 50 ids of a kind", async () => {
      const before = Array.from({ length: 60 }, (_, n) => ({ _id: n, name: `Vendor ${n}`, [`note for ${email}`]: 1, kept: true }));
      const after = [
        ...before.slice(5).map((document) => ({ ...document, name: `${document.name}!`, ...(document._id < 10 ? { [`note for ${email}`]: 2 } : {}) })),
        { _id: 100, name: "new" },
      ];
      const comparison = compareCollections(
        { type: "collection", documents: await snapshotBsonGz(gz(before), BSON), indexes: ["_id_", "old_1"] },
        { type: "collection", documents: await snapshotBsonGz(gz(after), BSON), indexes: ["_id_", "new_1"] },
      );
      assert.deepEqual({ ...comparison, changed: comparison.changed.length }, {
        before: 60, after: 56, added: ["100"], removed: ["0", "1", "2", "3", "4"], changed: 55, fields: { name: 55 }, otherFields: 5, indexesAdded: ["new_1"], indexesRemoved: ["old_1"],
      });
      assert.equal(idLimit, 50);
      const brief = capped(comparison);
      assert.deepEqual([brief.changed.count, brief.changed.ids.length, brief.added, brief.removed.count], [55, 50, { count: 1, ids: ["100"] }, 5]);
      const line = changeLine({ collection: "vendors", ...comparison });
      assert.equal(line, changeLine({ collection: "vendors", ...brief }));
      assert.equal(line, `- vendors: 60 -> 56, 1 added: 100; 5 removed: 0, 1, 2, 3, 4; 55 changed (name: 55, other fields: 5): ${comparison.changed.slice(0, 50).join(", ")} and 5 more; indexes added: new_1; indexes removed: old_1`);
      assert.ok(!line.includes("example.com"));
      assert.ok(fieldName.test("phase_2") && !fieldName.test("2phase") && !fieldName.test("a.b") && !fieldName.test("x".repeat(65)));
      // A collection made or dropped whole.
      const made = compareCollections(undefined, { type: "collection", documents: await snapshotBsonGz(gz([{ _id: 1 }]), BSON), indexes: ["_id_"] });
      assert.equal(changeLine({ collection: "fresh", ...made }), "- fresh: a collection was created, none -> 1, 1 added: 1; indexes added: _id_");
      const dropped = compareCollections({ type: "view" }, undefined);
      assert.equal(changeLine({ collection: "open_markets", ...dropped }), "- open_markets: the view was dropped, none -> none");
      assert.ok(differs(dropped));
    });

    test("a snapshot refuses a file that is no BSON stream or ends inside a document", async () => {
      const whole = BSON.serialize({ _id: 1, name: "x" });
      const cut = join(tempDir("bson"), "cut.bson.gz");
      writeFileSync(cut, gzipSync(Buffer.concat([whole, whole.subarray(0, 9)])));
      await assert.rejects(snapshotBsonGz(cut, BSON), /ends inside a document$/);
      const junk = join(tempDir("bson"), "junk.bson.gz");
      writeFileSync(junk, gzipSync(Buffer.from([1, 0, 0, 0, 0])));
      await assert.rejects(snapshotBsonGz(junk, BSON), /is not a BSON stream$/);
    });
  });
});

// The lock's mongoimport, which only the prepared commands run, as Daniel would.
const importDir = (process.env.PATH ?? "").split(delimiter).find((dir) => {
  try {
    accessSync(join(dir, "mongoimport"), constants.X_OK);
    return true;
  } catch {
    return false;
  }
});

describe("prepare-undo", () => {
  const { BSON } = createRequire(join(repoRoot, "servers", "package.json"))("mongodb");
  const writer = `writer${randomBytes(8).toString("hex")}`;
  let writerUri;
  let never;
  before(async () => {
    if (!importDir) throw new Error("mongoimport is not on PATH: install the lock's Database Tools (bin/lib/tools.jq's download_sources)");
    // The user Daniel's prepared command connects as: one that may write, unlike the read user.
    await production.createUser("ops-write", writer, [{ role: "readWrite", db: "conventioner" }]);
    writerUri = production.uri("ops-write", writer);
  });
  // A mongoimport and a mongorestore first on the server's PATH that record any run: the server
  // never starts either.
  beforeEach(() => {
    const dir = tempDir("never-run");
    for (const name of ["mongoimport", "mongorestore"]) {
      writeFileSync(join(dir, name), `#!/bin/sh\necho "$0 $*" >>'${dir}/ran'\nexit 1\n`, { mode: 0o755 });
    }
    never = { dir, ran: () => (existsSync(join(dir, "ran")) ? readFileSync(join(dir, "ran"), "utf8") : null) };
  });
  const undoServer = (body, options = {}) => withServer(body, { path: [spy.dir, never.dir, toolsDir, testPath()].join(":"), ...options });
  const live = () => production.client.db("conventioner");
  const shownBackup = (stamp) => `~/conventioner-backups/${stamp}`;
  const undosOf = (stamp) => (existsSync(join(root, stamp, "undo")) ? readdirSync(join(root, stamp, "undo")) : []);
  const hashed = (id) => `sha256:${createHash("sha256").update(JSON.stringify(id)).digest("hex").slice(0, 12)}`;
  const runIt =
    "Run it in a terminal of your own, pasting the connection string of a user that may write (the read user cannot) at the read -rs prompt; " +
    "<(...) is a pipe, so the string is never in an argument list or a file:";

  // Calls prepare-undo, checking it changed no document or index of "production" and ran no
  // Database Tool, and answers its text and its one undo folder's name (or undefined).
  async function prepare(stamp, args) {
    const before = await snapshotDatabase(live(), BSON);
    const had = undosOf(stamp);
    let result;
    await undoServer(async (server) => {
      result = await server.callTool("prepare-undo", { backup: stamp, ...args });
    });
    assert.equal(never.ran(), null, "the server ran a Database Tool");
    const changed = compareDatabases(before, await snapshotDatabase(live(), BSON)).filter(differs);
    assert.deepEqual(changed, [], "the tool's call changed production");
    const made = undosOf(stamp).filter((name) => !had.includes(name));
    assert.ok(made.length <= 1, made.join(", "));
    return { ...result, at: made[0] };
  }

  // The answer's fenced command, its rules checked, run with bash as Daniel would: their writer's
  // connection string typed at the read -rs prompt.
  function runPrepared(text) {
    const blocks = [...text.matchAll(/^```bash\n([\s\S]*?)^```$/gm)].map(([, body]) => body);
    assert.equal(blocks.length, 1, text);
    const [block] = blocks;
    const lines = block.trimEnd().split("\n");
    assert.equal(lines.length, 3, block);
    assert.equal(lines[0], "read -rs PROD_URI");
    assert.equal(lines[2], "unset PROD_URI");
    assert.ok(lines[1].includes(` --config=<(printf 'uri: %s\\n' "$PROD_URI") `), lines[1]);
    assert.doesNotMatch(lines[1], /mongodb(\+srv)?:\/\/|ops-read|pwmarker/);
    assert.ok(!block.includes(home), block);
    for (const path of lines[1].match(/ --(file|dir) \S+/g)) assert.match(path, / --(file|dir) ~\/conventioner-backups\//);
    const ran = spawnSync("bash", ["-c", block], {
      input: `${writerUri}\n`,
      env: { HOME: home, PATH: [importDir, toolsDir, testPath()].join(":") },
      encoding: "utf8",
    });
    assert.equal(ran.status, 0, ran.stderr);
    assert.ok(!`${ran.stdout}${ran.stderr}`.includes(writer), "the writer's password was printed");
    return lines[1];
  }

  // That production's collection is exactly the dump's: every document's hash and every index name.
  async function matchesDump(stamp, collection) {
    const dumped = (await snapshotDump(join(root, stamp, "dump", "conventioner"), BSON)).get(collection);
    const now = (await snapshotDatabase(live(), BSON)).get(collection);
    const comparison = compareCollections(dumped, now);
    assert.ok(!differs(comparison), JSON.stringify(capped(comparison)));
  }

  // Each undo folder 0700, each file in it 0600, and no file under the root holding the read
  // user's secret.
  function checkFiles(stamp, at, names) {
    const dir = join(root, stamp, "undo", at);
    assert.equal(statSync(join(root, stamp, "undo")).mode & 0o777, 0o700);
    assert.equal(statSync(dir).mode & 0o777, 0o700);
    assert.deepEqual(readdirSync(dir).sort(), names.sort());
    for (const name of names) assert.equal(statSync(join(dir, name)).mode & 0o777, 0o600, name);
    for (const { path, stat } of walk(root)) {
      if (stat.isFile()) assert.ok(!readFileSync(path).includes(marker), `${path} holds the read user's secret`);
    }
    return (name) => readFileSync(join(dir, name), "utf8");
  }

  test("takes a backup's name, a collection and an optional id, each held to its pattern", async () => {
    await undoServer(async (server) => {
      const tool = (await server.listTools()).find(({ name }) => name === "prepare-undo");
      assert.deepEqual(Object.keys(tool.inputSchema.properties), ["backup", "collection", "id"]);
      assert.deepEqual(tool.inputSchema.required, ["backup", "collection"]);
      assert.equal(tool.inputSchema.additionalProperties, false);
      assert.equal(tool.inputSchema.properties.backup.pattern, "^\\d{4}-\\d{2}-\\d{2}T\\d{6}Z$");
      assert.equal(tool.annotations.readOnlyHint, false);
      assert.equal(tool.annotations.destructiveHint, false);
    });
  });

  test("a changed document: names the fields that differ, writes the dump's version, and its upsert, run as Daniel would, puts it back", async () => {
    const stamp = await takeBackup();
    await live().collection("markets").updateOne({ id: marketIds[1] }, { $set: { stalls: 30, city: "Nanaimo" } });
    const { text, isError, at } = await prepare(stamp, { collection: "markets", id: marketIds[1] });
    assert.ok(!isError, text);
    const undo = `${shownBackup(stamp)}/undo/${at}`;
    const command = `mongoimport --config=<(printf 'uri: %s\\n' "$PROD_URI") --db conventioner --collection markets --mode upsert --file ${undo}/markets.json`;
    assert.equal(text, [
      `Undo of one document of markets from ${shownBackup(stamp)}, prepared for you to run; nothing was written to production:`,
      `${marketIds[1]}: changed in production since the dump, in city, stalls. The command puts the dump's version back in its place (mongoimport --mode upsert).`,
      `The file it imports: ${undo}/markets.json`,
      runIt,
      "```bash",
      "read -rs PROD_URI",
      command,
      "unset PROD_URI",
      "```",
    ].join("\n"));
    const read = checkFiles(stamp, at, ["markets.json", "report.json"]);
    // Canonical Extended JSON v2 of the dump's document, every number's type spelled out.
    const written = read("markets.json");
    assert.match(written, /^\{"_id":\{"\$oid":"[0-9a-f]{24}"\},"id":"[0-9a-f-]{36}","name":"Harbour Craft Fair","city":"Victoria","stalls":\{"\$numberInt":"25"\}\}\n$/);
    assert.deepEqual(JSON.parse(read("report.json")), {
      kind: "document", backup: stamp, at, collection: "markets", id: marketIds[1], state: "changed", fields: ["city", "stalls"], otherFields: 0,
      mode: "upsert", file: `${undo}/markets.json`, command,
    });
    assert.equal(runPrepared(text), command);
    await matchesDump(stamp, "markets");

    // list-backups counts it.
    await withServer(async (server) => {
      assert.match((await server.callTool("list-backups", {})).text, new RegExp(`^- ${stamp}: .*; 0 drills, 0 rehearsals, 1 undo, 0 diffs$`, "m"));
    }, { value: unreachable() });
  });

  test("a deleted document, named by its ObjectId's hex in capitals: its upsert inserts the dump's version", async () => {
    const stamp = await takeBackup();
    const { _id } = await live().collection("applications").findOne({ "vendor.name": "Vendor 2" });
    await live().collection("applications").deleteOne({ _id });
    const { text, isError, at } = await prepare(stamp, { collection: "applications", id: _id.toHexString().toUpperCase() });
    assert.ok(!isError, text);
    assert.equal(text.split("\n")[1], `${_id.toHexString()}: not in production now, so deleted since the dump. The command inserts the dump's version (mongoimport --mode upsert).`);
    const read = checkFiles(stamp, at, ["applications.json", "report.json"]);
    assert.equal(BSON.EJSON.parse(read("applications.json")).vendor.contact.phone, "555-0102");
    assert.equal(JSON.parse(read("report.json")).state, "deleted");
    assert.match(runPrepared(text), / --collection applications --mode upsert --file /);
    await matchesDump(stamp, "applications");
  });

  test("a document created since the dump: writes its _id alone, and its delete, run as Daniel would, removes it", async () => {
    const stamp = await takeBackup();
    const created = randomUUID();
    const { insertedId } = await live().collection("markets").insertOne({ id: created, name: "Created Since", stalls: 5 });
    const { text, isError, at } = await prepare(stamp, { collection: "markets", id: created });
    assert.ok(!isError, text);
    assert.equal(text.split("\n")[1], `${created}: in production but not in the dump, so created since it. The command deletes it from production (mongoimport --mode delete, matching its _id).`);
    const read = checkFiles(stamp, at, ["markets.json", "report.json"]);
    assert.equal(read("markets.json"), `{"_id":{"$oid":"${insertedId.toHexString()}"}}\n`);
    assert.deepEqual(JSON.parse(read("report.json")).state, "created");
    assert.match(runPrepared(text), / --collection markets --mode delete --file /);
    await matchesDump(stamp, "markets");
  });

  test("a document deleted and created again under another _id: refused by its id and by its _id's hex, pointing to the collection's undo", async () => {
    const stamp = await takeBackup();
    const markets = live().collection("markets");
    const { _id: old, ...rest } = await markets.findOne({ id: marketIds[1] });
    await markets.deleteOne({ _id: old });
    const { insertedId } = await markets.insertOne({ ...rest, stalls: 26 });
    const reason = `prepare-undo: failed: ${marketIds[1]} is the document ${old.toHexString()} in the dump, but production holds its id under another _id, ${insertedId.toHexString()}: ` +
      "putting the dump's document back would leave two documents with that id, so prepare the collection's undo instead (prepare-undo with no id)";
    for (const id of [marketIds[1], old.toHexString()]) {
      const { text, isError, at } = await prepare(stamp, { collection: "markets", id });
      assert.ok(isError, text);
      assert.equal(text, reason, id);
      assert.equal(at, undefined);
    }
    assert.deepEqual(undosOf(stamp), []);
  });

  test("an id that names two documents, in the dump or in production, is refused, asking for the _id", async () => {
    const markets = live().collection("markets");
    await markets.insertOne({ id: marketIds[0], name: "Riverside Night Market, again", stalls: 2 });
    const stamp = await takeBackup();
    const twice = randomUUID();
    await markets.insertMany([{ id: twice, name: "Twice 1" }, { id: twice, name: "Twice 2" }]);
    for (const [id, where] of [[marketIds[0], "in the dump"], [twice, "in production"]]) {
      const { text, isError, at } = await prepare(stamp, { collection: "markets", id });
      assert.ok(isError, text);
      assert.equal(text, `prepare-undo: failed: ${id} names 2 documents of the collection ${where}: give the _id's hex or UUID, as the answers print it, instead`);
      assert.equal(at, undefined);
    }
    assert.deepEqual(undosOf(stamp), []);
  });

  test("one document of a collection production no longer has: refused, pointing to the collection's undo, which keeps the dump's indexes", async () => {
    const stamp = await takeBackup();
    await live().collection("open_markets").drop();
    await live().collection("markets").drop();
    const { text, isError, at } = await prepare(stamp, { collection: "markets", id: marketIds[1] });
    assert.ok(isError, text);
    assert.equal(text, "prepare-undo: failed: production has no collection markets now, and an import of one document would make it with none of the dump's indexes but _id's, so prepare the collection's undo instead (prepare-undo with no id)");
    assert.equal(at, undefined);
    assert.deepEqual(undosOf(stamp), []);
  });

  test("a document that already matches the dump, or a collection that does: nothing to undo, and nothing written", async () => {
    const stamp = await takeBackup();
    let answer = await prepare(stamp, { collection: "markets", id: marketIds[0] });
    assert.ok(!answer.isError, answer.text);
    assert.equal(answer.text, `${marketIds[0]} in markets: production already matches the dump: nothing to undo, and nothing was written.`);
    answer = await prepare(stamp, { collection: "applications" });
    assert.equal(answer.text, `Production's applications already matches the dump in ${shownBackup(stamp)}: nothing to undo, and nothing was written.`);
    assert.deepEqual(undosOf(stamp), []);
    assert.ok(!existsSync(join(root, stamp, "undo")));
  });

  test("a collection: the counts, the ids it puts back, reverts and loses, the indexes, what --drop loses; its restore, run as Daniel would, leaves it as the dump", async () => {
    const stamp = await takeBackup();
    const markets = live().collection("markets");
    await markets.updateOne({ id: marketIds[0] }, { $set: { stalls: 41 } });
    await markets.deleteOne({ id: marketIds[2] });
    const lost = [randomUUID(), randomUUID()];
    await markets.insertMany(lost.map((id, n) => ({ id, name: `Since ${n}`, stalls: n })));
    await markets.dropIndex("name_unique");
    await markets.createIndex({ city: 1 }, { name: "city_1" });
    const { text, isError, at } = await prepare(stamp, { collection: "markets" });
    assert.ok(!isError, text);
    const command = `mongorestore --config=<(printf 'uri: %s\\n' "$PROD_URI") --nsInclude 'conventioner.markets' --drop --gzip --dir ${shownBackup(stamp)}/dump`;
    assert.equal(text, [
      `Undo of the collection markets from ${shownBackup(stamp)}, prepared for you to run; nothing was written to production:`,
      "Production holds 4 documents now, the dump 3 documents. The restore would:",
      `- put back (in the dump only): 1: ${marketIds[2]}`,
      `- revert (changed since the dump): 1 (stalls: 1): ${marketIds[0]}`,
      `- lose (in production only, written since the dump): 2: ${lost.toSorted().join(", ")}`,
      "- indexes: adds name_unique; drops city_1",
      "--drop replaces the whole collection: every write to markets since the dump is lost, the ones above and any made before you run it.",
      `The full lists: ${shownBackup(stamp)}/undo/${at}/report.json`,
      runIt,
      "```bash",
      "read -rs PROD_URI",
      command,
      "unset PROD_URI",
      "```",
    ].join("\n"));
    const read = checkFiles(stamp, at, ["report.json"]);
    assert.deepEqual(JSON.parse(read("report.json")), {
      kind: "collection", backup: stamp, at, collection: "markets", production: 4, dump: 3,
      putBack: [marketIds[2]], reverted: [marketIds[0]], lost: lost.toSorted(), fields: { stalls: 1 }, otherFields: 0,
      indexesAdded: ["name_unique"], indexesDropped: ["city_1"], command,
    });
    assert.equal(runPrepared(text), command);
    await matchesDump(stamp, "markets");
    assert.deepEqual(await collectionsOf(production.client).then(({ markets: m }) => m.indexes), ["_id_", "name_unique"]);
  });

  test("a collection's answer lists at most 50 ids of each kind, its report every one; an email-shaped _id is printed hashed, and names its document", async () => {
    const stamp = await takeBackup();
    const archived = live().collection("archived");
    const { insertedIds } = await archived.insertMany(Array.from({ length: 55 }, (_, n) => ({ n })));
    const ids = Object.values(insertedIds).map((id) => id.toHexString()).sort();
    const { text, at } = await prepare(stamp, { collection: "archived" });
    assert.ok(text.includes(`\n- lose (in production only, written since the dump): 55: ${ids.slice(0, 50).join(", ")} and 5 more\n`), text);
    assert.deepEqual(JSON.parse(checkFiles(stamp, at, ["report.json"])("report.json")).lost, ids);

    await live().collection("accounts").updateOne({ _id: email }, { $set: { role: "admin" } });
    const accounts = await prepare(stamp, { collection: "accounts" });
    assert.ok(accounts.text.includes(`\n- revert (changed since the dump): 1 (role: 1): ${hashed(email)}\n`), accounts.text);
    const one = await prepare(stamp, { collection: "accounts", id: hashed(email) });
    assert.equal(one.text.split("\n")[1], `${hashed(email)}: changed in production since the dump, in role. The command puts the dump's version back in its place (mongoimport --mode upsert).`);
    for (const answer of [text, accounts.text, one.text]) assert.ok(!answer.includes(email), answer);
    runPrepared(one.text);
    await matchesDump(stamp, "accounts");
  });

  test("a call whose second another undo took waits for the next one, and each undo keeps its own folder", async () => {
    const stamp = await takeBackup();
    await live().collection("markets").updateOne({ id: marketIds[1] }, { $set: { stalls: 31 } });
    const taken = [0, 1000].map((ms) => stampOf(new Date(Date.now() + ms)));
    for (const at of taken) mkdirSync(join(root, stamp, "undo", at), { recursive: true, mode: 0o700 });
    const { text, isError, at } = await prepare(stamp, { collection: "markets", id: marketIds[1] });
    assert.ok(!isError, text);
    assert.ok(at > taken[1], `${at} is not after ${taken[1]}`);
    for (const dir of taken) assert.deepEqual(readdirSync(join(root, stamp, "undo", dir)), []);
    checkFiles(stamp, at, ["markets.json", "report.json"]);
  });

  test("refuses before any connection: no backup, a stamp not under the root, a collection it does not hold or a view, input outside its patterns", async () => {
    const stamp = await takeBackup();
    await undoServer(async (server) => {
      const refusals = [
        [{ collection: "markets" }, "prepare-undo: failed: backup is required: a backup's name, its UTC start as list-backups gives it (2026-11-08T142305Z)"],
        [{ backup: "../x", collection: "markets" }, `prepare-undo: failed: "../x" is not a backup's name, which is its UTC start, as 2026-11-08T142305Z`],
        [{ backup: "2020-01-01T000000Z", collection: "markets" }, "prepare-undo: failed: ~/conventioner-backups holds no backup 2020-01-01T000000Z"],
        [{ backup: stamp }, "prepare-undo: failed: collection must be one collection's name, of letters, digits and . _ - only, as backup and list-backups name them"],
        [{ backup: stamp, collection: "../markets" }, "prepare-undo: failed: collection must be one collection's name, of letters, digits and . _ - only, as backup and list-backups name them"],
        [{ backup: stamp, collection: "vendors" }, `prepare-undo: failed: ${shownBackup(stamp)} holds no collection vendors: its manifest lists accounts, applications, archived, markets, open_markets`],
        [{ backup: stamp, collection: "open_markets" }, "prepare-undo: failed: open_markets is a view, whose dump is its definition only: there is no document to put back"],
        [{ backup: stamp, collection: "markets", id: "a\nb" }, "prepare-undo: failed: id must be one document's id as this toolkit prints it, or its _id's hex or UUID"],
        [{ backup: stamp, collection: "markets", id: 7 }, "prepare-undo: failed: id must be one document's id as this toolkit prints it, or its _id's hex or UUID"],
        [{ backup: stamp, collection: "markets", path: "/tmp" }, "prepare-undo: takes no path"],
      ];
      for (const [args, expected] of refusals) {
        const result = await server.callTool("prepare-undo", args);
        assert.ok(result.isError, JSON.stringify(args));
        assert.equal(result.text, expected, JSON.stringify(args));
      }
    }, { value: unreachable(), path: [spy.dir, never.dir, toolsDir, testPath()].join(":") });
    assert.deepEqual(undosOf(stamp), []);
    assert.equal(never.ran(), null);

    // With production reachable: an id that names no document, and production unreachable.
    const none = await prepare(stamp, { collection: "markets", id: randomUUID() });
    assert.ok(none.isError);
    assert.match(none.text, /^prepare-undo: failed: [0-9a-f-]{36} names no document of markets, in the dump or in production$/);
    await undoServer(async (server) => {
      const result = await server.callTool("prepare-undo", { backup: stamp, collection: "markets" });
      assert.equal(result.text, "prepare-undo: failed: could not reach the database");
    }, { value: unreachable() });
    assert.deepEqual(undosOf(stamp), []);
  });
});

describe("the launcher refuses before the server starts", () => {
  launcherRefusalTests("prod-mongo", () => ({ value: production.uri("ops-read", marker), home, marker }), { path: serverPath() });

  test("when mongodump is not on PATH, before any op call", async () => {
    const op = opStub({ value: production.uri("ops-read", marker) });
    const server = startToolkitServer("prod-mongo", { home, opDir: op.dir, path: [stubDir, dirname(process.execPath)].join(":") });
    try {
      await assert.rejects(server.initialize(), /server exited \(1\)/);
    } finally {
      await server.close();
    }
    assert.equal(server.stderr, "prod-mongo: mongodump is not installed: team-doctor names the install\n");
    assert.deepEqual(op.calls(), []);
    assertNoLeak(server, { marker, home });
  });
});

describe("the server's rules", () => {
  test("a stamp is the UTC start to the second", () => {
    assert.equal(stampOf(new Date("2026-11-08T14:23:05.987Z")), "2026-11-08T142305Z");
  });

  test("a dump needs 1 GiB plus twice the database's data free", () => {
    const gib = 1024 ** 3;
    assert.equal(roomRefusal(gib + 2 * 100, 100), undefined);
    assert.equal(
      roomRefusal(gib, 512 * 1024 ** 2),
      "the backups folder's disk has 1.0 GiB free, less than the 2.0 GiB a dump needs (1 GiB plus twice the database's 512.0 MiB of data)",
    );
  });

  test("the room rule's edges: exactly enough passes, a byte short refuses naming both numbers", () => {
    const gib = 1024 ** 3;
    assert.equal(roomRefusal(gib, 0), undefined);
    assert.equal(roomRefusal(gib + 2 * gib, gib), undefined);
    assert.equal(
      roomRefusal(gib + 2 * gib - 1, gib),
      "the backups folder's disk has 3.0 GiB free, less than the 3.0 GiB a dump needs (1 GiB plus twice the database's 1.0 GiB of data)",
    );
    assert.match(roomRefusal(0, 0), /^the backups folder's disk has 0 B free, less than the 1\.0 GiB a dump needs/);
  });

  // The rules the server cannot reach on this machine: macOS's folders, the CI variables, the forms
  // a symlink gives, on a context written out.
  describe("destinationRefusal", () => {
    const linux = { home: "/home/d", teamHome: "/home/d/agent-team-records", tmpdir: "/tmp", env: {}, platform: "linux", holding: {}, resolved: {} };
    const mac = { ...linux, home: "/Users/d", teamHome: undefined, tmpdir: "/var/folders/ab/T", platform: "darwin" };
    const refusal = (path, context) => destinationRefusal(path, context);

    test("passes the launcher's root, and one beside the checkouts", () => {
      assert.equal(refusal("/home/d/conventioner-backups", linux), undefined);
      assert.equal(refusal("/srv/backups", linux), undefined);
      assert.equal(refusal("/Users/d/conventioner-backups", mac), undefined);
    });

    test("refuses / and the home, however written", () => {
      assert.equal(refusal("/", linux), "the backups folder / is / itself");
      assert.equal(refusal("/home/d/", linux), "the backups folder ~ is the home directory itself");
      assert.equal(refusal("/home/d/x/..", linux), "the backups folder ~ is the home directory itself");
    });

    test("refuses Desktop and Documents on macOS only", () => {
      for (const name of ["Desktop", "Documents"]) {
        assert.equal(refusal(`/Users/d/${name}/backups`, mac), `the backups folder ~/${name}/backups is inside a synced folder, ~/${name}`);
        assert.equal(refusal(`/home/d/${name}/backups`, linux), undefined);
      }
    });

    test("refuses macOS's cloud folders and temporary directories", () => {
      assert.equal(refusal("/Users/d/Library/CloudStorage/GoogleDrive-d/backups", mac), "the backups folder ~/Library/CloudStorage/GoogleDrive-d/backups is inside a synced folder, ~/Library/CloudStorage");
      assert.equal(refusal("/Users/d/Library/Mobile Documents/backups", mac), "the backups folder ~/Library/Mobile Documents/backups is inside a synced folder, ~/Library/Mobile Documents");
      assert.equal(refusal("/private/var/folders/ab/T/backups", mac), "the backups folder /private/var/folders/ab/T/backups is inside a shared temporary directory, /private/var/folders");
      assert.equal(refusal("/private/tmp/backups", mac), "the backups folder /private/tmp/backups is inside a shared temporary directory, /private/tmp");
    });

    test("refuses every synced folder by name, a work OneDrive included", () => {
      for (const name of ["Box", "Dropbox", "Google Drive", "GoogleDrive", "iCloud Drive", "MEGA", "Nextcloud", "OneDrive", "ownCloud", "pCloudDrive", "Sync"]) {
        assert.equal(refusal(`/home/d/${name}/b`, linux), `the backups folder ~/${name}/b is inside a synced folder, ~/${name}`);
      }
      assert.equal(refusal("/home/d/OneDrive - Acme Ltd/b", linux), "the backups folder ~/OneDrive - Acme Ltd/b is inside a synced folder, ~/OneDrive - Acme Ltd");
      assert.equal(refusal("/home/d/OneDriveNotes/b", linux), undefined);
    });

    test("refuses below any sync client's marker, a .sync_*.db file included", () => {
      for (const marker of [".dropbox", ".dropbox.cache", ".nextcloudsync.log", ".owncloudsync.log", ".stfolder", ".sync", ".sync_4f2a.db"]) {
        assert.equal(refusal("/data/share/b", { ...linux, holding: { "/data/share": [marker] } }), `the backups folder /data/share/b is inside a synced folder: /data/share holds ${marker}`);
      }
    });

    test("refuses the CI workspaces and the temporary directories the environment names", () => {
      for (const name of ["GITHUB_WORKSPACE", "RUNNER_WORKSPACE", "RUNNER_TEMP"]) {
        assert.equal(refusal("/home/runner/work/x/b", { ...linux, env: { [name]: "/home/runner/work/x" } }), `the backups folder /home/runner/work/x/b is inside a CI workspace, ${name} (/home/runner/work/x)`);
      }
      assert.equal(refusal("/run/user/1000/b", { ...linux, env: { XDG_RUNTIME_DIR: "/run/user/1000" } }), "the backups folder /run/user/1000/b is inside a shared temporary directory, /run/user/1000");
      assert.equal(refusal("/var/tmp/b", linux), "the backups folder /var/tmp/b is inside a shared temporary directory, /var/tmp");
      assert.equal(refusal("/dev/shm/b", linux), "the backups folder /dev/shm/b is inside a shared temporary directory, /dev/shm");
    });

    test("judges the real path as well as the one given, and a named directory by its real path too", () => {
      assert.equal(refusal("/home/d/link", { ...linux, real: "/home/d/Dropbox/b" }), "the backups folder ~/link is inside a synced folder, ~/Dropbox");
      assert.equal(refusal("/home/d/link", { ...linux, real: "/home/d/repo/b", holding: { "/home/d/repo": [".git"] } }), "the backups folder ~/link is inside a git checkout: ~/repo holds .git");
      assert.equal(refusal("/home/d/b", { ...linux, real: "/mnt/records/b", teamHome: "/home/d/records", resolved: { "/home/d/records": "/mnt/records" } }), "the backups folder ~/b is inside the team home, ~/records");
      // A home that is itself a symlink: its real form is the home too.
      assert.equal(refusal("/home/d/b", { ...linux, real: "/data/home/d/.claude/b", resolved: { "/home/d": "/data/home/d" } }), "the backups folder ~/b is inside ~/.claude, Claude Code's own folder of transcripts and jobs");
      // A prefix of a name is not a parent.
      assert.equal(refusal("/home/d/agent-team-records-old/b", linux), undefined);
      assert.equal(refusal("/tmpfiles/b", linux), undefined);
    });
  });

  describe("dumpByStamp", () => {
    let real;
    beforeEach(() => {
      real = join(newHome(), "backups");
      mkdirSync(real);
      const make = (stamp, manifest) => {
        mkdirSync(join(real, stamp));
        if (manifest !== undefined) writeFileSync(join(real, stamp, "manifest.json"), manifest);
      };
      make("2026-11-08T142305Z", JSON.stringify({ verified: true, totals: { documents: 3 } }));
      make("2026-11-08T150000Z", JSON.stringify({ verified: false }));
      make("2026-11-08T160000Z");
      make("2026-11-08T170000Z", "{not json");
      symlinkSync(join(real, "2026-11-08T142305Z"), join(real, "2026-11-08T180000Z"));
    });
    test("gives the verified dump of a stamp", () => {
      const { stamp, folder, manifest } = dumpByStamp(real, "2026-11-08T142305Z", "~/b");
      assert.deepEqual([stamp, folder, manifest.totals.documents], ["2026-11-08T142305Z", join(real, "2026-11-08T142305Z"), 3]);
    });

    test("refuses a path, a partial's name or anything not a stamp", () => {
      for (const stamp of ["../2026-11-08T142305Z", "/etc", "2026-11-08T142305Z/", ".2026-11-08T142305Z.partial", "2026-11-08", "", 7, undefined]) {
        assert.throws(() => dumpByStamp(real, stamp, "~/b"), { message: /is not a backup's name, which is its UTC start, as 2026-11-08T142305Z$/ }, String(stamp));
      }
      assert.throws(() => dumpByStamp(real, "../x", "~/b"), { message: `"../x" is not a backup's name, which is its UTC start, as 2026-11-08T142305Z` });
      assert.throws(() => dumpByStamp(real, "x".repeat(100), "~/b"), { message: `"${"x".repeat(40)}..." is not a backup's name, which is its UTC start, as 2026-11-08T142305Z` });
    });

    test("refuses a stamp with no folder, no verified manifest, or a symlink for a folder", () => {
      assert.throws(() => dumpByStamp(real, "2026-01-01T000000Z", "~/b"), { message: "~/b holds no backup 2026-01-01T000000Z" });
      for (const stamp of ["2026-11-08T150000Z", "2026-11-08T160000Z", "2026-11-08T170000Z"]) {
        assert.throws(() => dumpByStamp(real, stamp, "~/b"), { message: `~/b/${stamp} has no verified manifest.json, so it is not a dump this toolkit took` }, stamp);
      }
      assert.throws(() => dumpByStamp(real, "2026-11-08T180000Z", "~/b"), { message: "~/b/2026-11-08T180000Z is not a folder this toolkit took" });
    });
  });

  test("the retention rule keeps the 5 newest verified dumps", () => {
    assert.equal(kept, 5);
  });

  test("scrubbed drops every connection string, the secret's parts and hosts, and anything from a {", () => {
    const value = "mongodb+srv://ops:p%40ss-word@cluster0.example.mongodb.net/?retryWrites=true";
    const scrubbed = scrubber(value);
    assert.equal(scrubbed(`failed to connect to ${value}`), "failed to connect to [uri]");
    assert.equal(scrubbed("auth failed for p@ss-word at cluster0.example.mongodb.net: {\"doc\":1}"), "auth failed for [redacted] at [redacted]:");
    assert.equal(scrubbed("x".repeat(300)).length, 200);
  });

  test("childEnv passes its list and the extras, never the rest", () => {
    const saved = { ...process.env };
    try {
      Object.assign(process.env, { TEAM_HEAVY_HELD: "1", AGENT_TEAM_TASK: "T1", SECRET_THING: "no" });
      const env = childEnv({ EXTRA: "yes" });
      assert.equal(env.TEAM_HEAVY_HELD, "1");
      assert.equal(env.AGENT_TEAM_TASK, "T1");
      assert.equal(env.EXTRA, "yes");
      assert.equal(env.SECRET_THING, undefined);
      for (const key of Object.keys(env)) {
        assert.ok(["PATH", "HOME", "LANG", "AGENT_TEAM_TASK", "TEAM_HEAVY_HELD", "DOCKER_HOST", "DOCKER_CONTEXT", "EXTRA"].includes(key), key);
      }
    } finally {
      for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
      Object.assign(process.env, saved);
    }
  });
});

// A child's end: its exit code or signal, and everything it printed.
function ended(child) {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => (stdout += chunk));
    child.stderr.setEncoding("utf8").on("data", (chunk) => (stderr += chunk));
    child.on("close", (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
}

// Polls `check` every 50 ms until it holds, `timeoutMs` passes (Infinity: never), or `signal`, a
// test's own, is aborted, as node:test aborts it when the test times out.
async function until(check, timeoutMs = 60_000, signal = undefined) {
  const start = Date.now();
  while (!check()) {
    if (Date.now() - start > timeoutMs) throw new Error("timed out waiting");
    signal?.throwIfAborted();
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}
