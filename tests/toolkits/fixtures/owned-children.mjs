// A node:test file that process-helper.test.mjs runs with node --test, never the suite itself
// (tests/run runs only tests/toolkits/*.test.mjs). Each test starts, through owned(), a process
// tree shaped like a restore drill's: a leader that cleans up on SIGTERM, as the drill removes
// its throwaway, a spy that holds while its parent lives, as the mongorestore spy does, and a
// process that ignores SIGTERM and outlives its parent, as a hung mongorestore would. Then one
// test fails mid-run, one times out, and one fails with a stubborn leader, whose SIGTERM starts
// one more process, as the drill's starts a docker rm, and never exits. The three run at once.
// Every pid goes in OWNED_CHILDREN_DIR as <test>.<role> (leader, spy, stray, and the stubborn
// leader's late), and the leader's SIGTERM leaves <test>.cleaned there.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, test } from "node:test";
import { owned } from "../helpers/process.mjs";

const dir = process.env.OWNED_CHILDREN_DIR;

// The spy: it starts the stray in the background, then holds while its parent lives.
const spy = `sh -c 'trap "" TERM; echo $$ >"$0"; exec sleep 600' "$1" & echo $$ >"$2"; while kill -0 $PPID 2>/dev/null; do sleep 0.1; done`;

const leader = `
const { spawn } = require("node:child_process");
const { writeFileSync } = require("node:fs");
const [base, mode] = process.argv.slice(1);
writeFileSync(base + ".leader", String(process.pid));
process.on("SIGTERM", () => {
  writeFileSync(base + ".cleaned", "");
  if (mode !== "stubborn") process.exit(143);
  writeFileSync(base + ".late", String(spawn("sleep", ["600"], { stdio: "ignore" }).pid));
});
spawn("sh", ["-c", ${JSON.stringify(spy)}, "spy", base + ".stray", base + ".spy"], { stdio: "ignore" });
setInterval(() => {}, 60_000);
`;

async function startTree(t, name, mode = "") {
  const base = join(dir, name);
  const child = owned(t, spawn(process.execPath, ["-e", leader, base, mode], { stdio: ["ignore", "pipe", "pipe"] }));
  child.stdout.on("data", () => {});
  child.stderr.on("data", () => {});
  while (!["leader", "spy", "stray"].every((role) => existsSync(`${base}.${role}`))) {
    if (t.signal.aborted) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

describe("trees", { concurrency: true }, () => {
  test("fails mid-run", async (t) => {
    await startTree(t, "failed");
    throw new Error("failed mid-run, as the test asked");
  });

  // Room for a loaded machine's node and sh starts before the timeout, which the tree must beat.
  test("times out mid-run", { timeout: 20_000 }, async (t) => {
    await startTree(t, "timed-out");
    await new Promise(() => {});
  });

  test("fails mid-run with a stubborn leader", async (t) => {
    await startTree(t, "stubborn", "stubborn");
    throw new Error("failed mid-run with a stubborn leader, as the test asked");
  });
});
