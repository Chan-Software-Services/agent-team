// The end of what a test started (helpers/process.mjs's owned), against a node:test file of its
// own, fixtures/owned-children.mjs, run with node --test as tests/run runs a toolkit file but
// without --test-force-exit, so only owned() can end what it started: a test that fails or times
// out mid-run leaves no process of the drill-shaped tree it started, the leader having had
// SIGTERM first to clean up, a stubborn leader's process started on that SIGTERM included, and
// node --test ends at once instead of waiting on them. And ownedPid's end of a detached daemon
// that is no child of the test, one that ignores SIGTERM, with the child below it.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { repoRoot, tempDir } from "./helpers/mcp.mjs";
import { owned, ownedPid } from "./helpers/process.mjs";

// A process is gone once ps no longer lists it, or lists it as a zombie its parent has yet to reap.
const gone = (pid) => {
  try {
    return execFileSync("ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).trim().startsWith("Z");
  } catch (error) {
    if (error.status === 1) return true;
    throw error;
  }
};

// The pid a fixture tree's process wrote, or a failure that says that part of the tree never
// started, as on a machine too loaded to start it before its test ended.
function pidOf(dir, name, role) {
  const file = join(dir, `${name}.${role}`);
  assert.ok(existsSync(file), `${name}: its ${role} never wrote its pid, so the tree had not started when its test ended`);
  return Number(readFileSync(file, "utf8"));
}

test("a tree that had not started fails by saying so, never on a missing file", () => {
  const dir = tempDir("owned-children-unstarted");
  writeFileSync(join(dir, "timed-out.leader"), "1234");
  assert.equal(pidOf(dir, "timed-out", "leader"), 1234);
  assert.throws(() => pidOf(dir, "timed-out", "spy"), { message: "timed-out: its spy never wrote its pid, so the tree had not started when its test ended" });
  mkdirSync(join(dir, "empty"));
  assert.throws(() => pidOf(join(dir, "empty"), "failed", "leader"), { message: /^failed: its leader never wrote its pid/ });
});

test("a test that fails or times out mid-run leaves no process it started through owned(), and node --test ends at once", async (t) => {
  const dir = tempDir("owned-children");
  // Without NODE_TEST_CONTEXT, which marks this run's own file process, so the inner node --test
  // runs its file instead of skipping it as a recursive run.
  const { NODE_TEST_CONTEXT: _context, ...env } = process.env;
  const run = owned(t, spawn(process.execPath, ["--test", join(repoRoot, "tests", "toolkits", "fixtures", "owned-children.mjs")], {
    env: { ...env, OWNED_CHILDREN_DIR: dir },
    stdio: ["ignore", "pipe", "pipe"],
  }));
  let output = "";
  run.stdout.setEncoding("utf8").on("data", (chunk) => (output += chunk));
  run.stderr.setEncoding("utf8").on("data", (chunk) => (output += chunk));
  const started = Date.now();
  // Each stray and late process sleeps 600 s and each leader runs until it is stopped, so a run
  // that waited on them would take that long; one that ends them takes the fixture's 20-second
  // timeout, its three tests running at once, and some seconds more.
  const code = await new Promise((resolve) => run.on("close", resolve));
  assert.ok(Date.now() - started < 120_000, `node --test took ${Date.now() - started} ms to end`);
  assert.equal(code, 1, output);
  assert.match(output, /✖ fails mid-run/);
  assert.match(output, /failed mid-run, as the test asked/);
  assert.match(output, /✖ times out mid-run/);
  assert.match(output, /test timed out after 20000ms/);
  assert.match(output, /failed mid-run with a stubborn leader, as the test asked/);
  const trees = { failed: ["leader", "spy", "stray"], "timed-out": ["leader", "spy", "stray"], stubborn: ["leader", "spy", "stray", "late"] };
  for (const [name, roles] of Object.entries(trees)) {
    for (const role of roles) {
      const pid = pidOf(dir, name, role);
      // A SIGKILLed process is gone in a moment, once its parent or init reaps it.
      for (const start = Date.now(); !gone(pid) && Date.now() - start < 10_000; ) await new Promise((resolve) => setTimeout(resolve, 50));
      assert.ok(gone(pid), `${name}: its ${role} (pid ${pid}) still runs`);
    }
    assert.ok(existsSync(join(dir, `${name}.cleaned`)), `${name}: the leader had no SIGTERM to clean up on`);
  }
});

test("ownedPid ends a detached process that is no child of the test, and the tree below it, when its test ends", async (t) => {
  const dir = tempDir("owned-pid");
  // A daemon as a client starts one: the shell that started it exits at once, so the daemon is
  // nobody's child here. It ignores SIGTERM, and its child is a sleeper of its own.
  const script = join(dir, "daemon.mjs");
  writeFileSync(script, [
    `import { spawn } from "node:child_process";`,
    `import { writeFileSync } from "node:fs";`,
    `process.on("SIGTERM", () => {});`,
    `writeFileSync(${JSON.stringify(join(dir, "child"))}, String(spawn("sleep", ["600"], { stdio: "ignore" }).pid));`,
    `writeFileSync(${JSON.stringify(join(dir, "daemon"))}, String(process.pid));`,
    `setInterval(() => {}, 1000);`,
  ].join("\n"));
  execFileSync("sh", ["-c", `'${process.execPath}' '${script}' >/dev/null 2>&1 &`]);
  for (const start = Date.now(); !(existsSync(join(dir, "daemon")) && existsSync(join(dir, "child"))) && Date.now() - start < 10_000; ) await new Promise((resolve) => setTimeout(resolve, 50));
  const daemon = Number(readFileSync(join(dir, "daemon"), "utf8"));
  const child = Number(readFileSync(join(dir, "child"), "utf8"));
  assert.ok(!gone(daemon) && !gone(child));
  await t.test("the test that owns it", (inner) => ownedPid(inner, daemon));
  for (const pid of [daemon, child]) {
    for (const start = Date.now(); !gone(pid) && Date.now() - start < 10_000; ) await new Promise((resolve) => setTimeout(resolve, 50));
    assert.ok(gone(pid), `${pid} still runs`);
  }
  assert.throws(() => ownedPid(t, daemon), { message: `ownedPid: no process ${daemon}` });
});
