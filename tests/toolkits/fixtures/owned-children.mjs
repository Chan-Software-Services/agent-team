// A node:test file that process-helper.test.mjs runs with node --test, never the suite itself
// (tests/run runs only tests/toolkits/*.test.mjs). Each test starts, through owned(), a process
// tree shaped like a restore drill's: a leader that cleans up on SIGTERM, as the drill removes
// its throwaway, a spy that holds while its parent lives, as the mongorestore spy does, and a
// process that ignores SIGTERM and outlives its parent, as a hung mongorestore would. Then one
// test fails mid-run and the other times out. Every pid goes in OWNED_CHILDREN_DIR as
// <test>.<role> (leader, spy, stray), and the leader's SIGTERM leaves <test>.cleaned there.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { owned } from "../helpers/process.mjs";

const dir = process.env.OWNED_CHILDREN_DIR;

// The spy: it starts the stray in the background, then holds while its parent lives.
const spy = `sh -c 'trap "" TERM; echo $$ >"$0"; exec sleep 600' "$1" & echo $$ >"$2"; while kill -0 $PPID 2>/dev/null; do sleep 0.1; done`;

const leader = `
const { spawn } = require("node:child_process");
const { writeFileSync } = require("node:fs");
const [base] = process.argv.slice(1);
writeFileSync(base + ".leader", String(process.pid));
process.on("SIGTERM", () => {
  writeFileSync(base + ".cleaned", "");
  process.exit(143);
});
spawn("sh", ["-c", ${JSON.stringify(spy)}, "spy", base + ".stray", base + ".spy"], { stdio: "ignore" });
setInterval(() => {}, 60_000);
`;

async function startTree(t, name) {
  const base = join(dir, name);
  const child = owned(t, spawn(process.execPath, ["-e", leader, base], { stdio: ["ignore", "pipe", "pipe"] }));
  child.stdout.on("data", () => {});
  child.stderr.on("data", () => {});
  while (!["leader", "spy", "stray"].every((role) => existsSync(`${base}.${role}`))) {
    if (t.signal.aborted) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

test("fails mid-run", async (t) => {
  await startTree(t, "failed");
  throw new Error("failed mid-run, as the test asked");
});

test("times out mid-run", { timeout: 5_000 }, async (t) => {
  await startTree(t, "timed-out");
  await new Promise(() => {});
});
