// A throwaway local MongoDB for the toolkit tests: one container per test file, at the exact
// version production runs, on a random loopback port, with its data on tmpfs, removed when the
// file is done.
//
//   const db = await startMongo();           before()
//   db.uri(user, password, options)          a connection string for a test user
//   await db.createUser(user, password, roles)
//   await db.connectAs(user, password)       a driver client as a test user; close it when done
//   await db.seed(database, { collection: [documents] })   beforeEach(): drop, then insert
//   db.client                                a driver client as root, for checking the data
//   await db.stop();                         after()
// startMongo runs one mongod with auth on (oneMongod), waits for it with connectWhenReady, makes the
// root user in the container (createRoot), and stop() removes the container with removeContainer;
// connectWhenReady and removeContainer are exported for their own tests. mongoImage,
// perThreadCaches, oneMongod and createRoot are the pin, the environment, the command and the root
// user's script the prod-mongo toolkit's throwaway is held to.
import { execFileSync, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import { join } from "node:path";
import { repoRoot } from "./mcp.mjs";

// Production is Atlas on MongoDB 8.0.
export const mongoImage = "mongo:8.0.34@sha256:4a4ab5d4834207389e0d7270fac988e21ffedccecba77991a552f755df229907";

// MongoDB 8.0 exits at start on Linux 6.19 to 7.0.13 when tcmalloc runs on per-CPU caches, whose
// rseq use those kernels break (SERVER-121912, SERVER-125742). The image turns glibc's rseq off
// (GLIBC_TUNABLES=glibc.pthread.rseq=0) so tcmalloc can take rseq for those caches; turning it back
// on leaves tcmalloc on per-thread caches, which mongod's startup check lets start
// (docs/v8.0/administration/tcmalloc-performance). Drop this once every machine that runs these
// tests, GitHub's runners included, is on 7.0.14 or later, where 8.0.30 and newer start with
// per-CPU caches.
export const perThreadCaches = ["--env", "GLIBC_TUNABLES=glibc.pthread.rseq=1"];

// The image declares /data/db and /data/configdb as volumes, so a container with nothing mounted
// there gets two anonymous volumes, about 0.3 GB a pair, which a run killed before its after() and
// a later docker rm without --volumes leave on disk. On tmpfs Docker makes none, so whatever ends
// the run leaves at most a container. Every container of the image takes these.
export const dataOnTmpfs = ["--tmpfs", "/data/db", "--tmpfs", "/data/configdb"];

// The image's entrypoint, given MONGO_INITDB_ROOT_USERNAME and _PASSWORD, makes the root user on a
// first mongod on 127.0.0.1:27017, stops it with mongod --shutdown and starts a second on
// 0.0.0.0:27017. But mongod --shutdown returns once the first one has emptied its mongod.lock,
// before it exits, and mongod's listener shutdown only cancels its accept, so the first one listens
// until it is gone: on a busy machine the second one's bind fails with "Address already in use" and
// it exits 48. So the container runs one mongod, with auth on and no MONGO_INITDB_* variables, as
// the command after the image (the entrypoint adds --bind_ip_all), and createRoot, run in it by
// docker exec once mongod answers a ping, makes the root user on the localhost exception, which
// closes once a user exists; its password comes as MONGO_ROOT_PASSWORD, a name-only docker exec
// --env, never in an argument list.
export const oneMongod = ["mongod", "--auth"];
export const createRoot = [
  "mongosh", "--quiet", "--norc", "--eval",
  'db.getSiblingDB("admin").createUser({ user: "root", pwd: process.env.MONGO_ROOT_PASSWORD, roles: ["root"] })',
];

// The driver from the pinned server's own install (servers/install), so the tests add no
// dependency of their own.
const { MongoClient } = createRequire(join(repoRoot, "servers", "package.json"))("mongodb");

const docker = (...args) => execFileSync("docker", args, { encoding: "utf8" }).trim();

// Removes container <name>, and with --volumes any anonymous volume it has, which dataOnTmpfs
// leaves none of unless the image declares a new one.
export function removeContainer(name) {
  docker("rm", "--force", "--volumes", name);
}

export async function startMongo() {
  const rootPassword = randomBytes(12).toString("hex");
  const name = `toolkit-test-${randomBytes(4).toString("hex")}`;
  docker(
    "run", "--detach", "--name", name, "--label", "agent-team-test=toolkits",
    "--publish", "127.0.0.1::27017",
    ...perThreadCaches, ...dataOnTmpfs,
    mongoImage, ...oneMongod,
  );
  try {
    const port = Number(docker("port", name, "27017/tcp").split("\n")[0].split(":").at(-1));
    const uri = (user, password, options = "") =>
      `mongodb://${user}:${password}@127.0.0.1:${port}/?authSource=admin${options}`;
    await (await connectWhenReady(`mongodb://127.0.0.1:${port}/`, name)).close();
    execFileSync("docker", ["exec", "--env", "MONGO_ROOT_PASSWORD", name, ...createRoot], {
      env: { ...process.env, MONGO_ROOT_PASSWORD: rootPassword },
      stdio: ["ignore", "ignore", "pipe"],
    });
    const client = await new MongoClient(uri("root", rootPassword)).connect();
    return {
      name,
      port,
      uri,
      client,
      createUser: (user, password, roles) =>
        client.db("admin").command({ createUser: user, pwd: password, roles }),
      connectAs: (user, password) => new MongoClient(uri(user, password)).connect(),
      async seed(database, collections) {
        await client.db(database).dropDatabase();
        for (const [collection, documents] of Object.entries(collections)) {
          await client.db(database).collection(collection).insertMany(documents);
        }
      },
      async stop() {
        await client.close();
        removeContainer(name);
      },
    };
  } catch (error) {
    removeContainer(name);
    throw error;
  }
}

// Wait for a ping, which mongod answers before any login: up to <waitMs> (180 s, since a Docker
// busy starting other stacks can take minutes), then fail with the time waited and container <name>'s last log lines. A container that exits
// first fails the wait at once with its exit code: startMongo runs it without --rm, so it is still
// there to read.
export async function connectWhenReady(uri, name, waitMs = 180_000) {
  const start = Date.now();
  for (;;) {
    const client = new MongoClient(uri, { serverSelectionTimeoutMS: 1_000 });
    try {
      await client.connect();
      await client.db("admin").command({ ping: 1 });
      return client;
    } catch (error) {
      await client.close().catch(() => {});
      const exited = exitOf(name);
      if (exited) {
        const waited = Math.round((Date.now() - start) / 1_000);
        throw new Error(
          `MongoDB container ${name} ${exited} after ${waited} s, before it was ready\n` +
            `docker logs --tail 20 ${name}:\n${lastLogLines(name)}`,
          { cause: error },
        );
      }
      if (Date.now() - start > waitMs) {
        const waited = Math.round((Date.now() - start) / 1_000);
        throw new Error(
          `MongoDB in container ${name} was not ready after ${waited} s: ${error.message}\n` +
            `docker logs --tail 20 ${name}:\n${lastLogLines(name)}`,
          { cause: error },
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
}

// How container <name> ended ("exited with code 137, killed out of memory"), or null while it runs
// or while Docker is too busy to say.
function exitOf(name) {
  const state = spawnSync("docker", ["inspect", "--format", "{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}", name], { encoding: "utf8" });
  if (state.error || state.status !== 0) {
    return /no such object/i.test(state.stderr ?? "") ? `was gone (${state.stderr.trim()})` : null;
  }
  const [status, code, oom] = state.stdout.trim().split(" ");
  if (["created", "running", "restarting", "paused"].includes(status)) return null;
  return `exited with code ${code}${oom === "true" ? ", killed out of memory" : ""}`;
}

// Container <name>'s last 20 log lines, stdout and stderr, or why docker could not read them.
function lastLogLines(name) {
  const logs = spawnSync("docker", ["logs", "--tail", "20", name], { encoding: "utf8" });
  if (logs.error || logs.status !== 0) {
    return `(docker logs failed: ${(logs.error?.message ?? logs.stderr).trim()})`;
  }
  return `${logs.stdout}${logs.stderr}`.trim() || "(nothing logged)";
}
