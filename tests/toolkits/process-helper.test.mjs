// The end of what a test started (helpers/process.mjs's owned and endTree), against a node:test
// file of its own, fixtures/owned-children.mjs, run with node --test as tests/run runs a toolkit
// file but without --test-force-exit, so only owned() can end what it started: a test that fails
// or times out mid-run leaves no process of the drill-shaped tree it started, the leader having
// had SIGTERM first to clean up, and node --test ends at once instead of waiting on them.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { repoRoot, tempDir } from "./helpers/mcp.mjs";
import { owned } from "./helpers/process.mjs";

// A process is gone once ps no longer lists it, or lists it as a zombie its parent has yet to reap.
const gone = (pid) => {
  try {
    return execFileSync("ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).trim().startsWith("Z");
  } catch (error) {
    if (error.status === 1) return true;
    throw error;
  }
};

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
  // Each stray sleeps 600 s and each leader runs until it is stopped, so a run that waited on
  // them would take that long; one that ends them takes the fixture's 5-second timeout and a
  // few seconds more.
  const code = await new Promise((resolve) => run.on("close", resolve));
  assert.ok(Date.now() - started < 60_000, `node --test took ${Date.now() - started} ms to end`);
  assert.equal(code, 1, output);
  assert.match(output, /✖ fails mid-run/);
  assert.match(output, /failed mid-run, as the test asked/);
  assert.match(output, /✖ times out mid-run/);
  assert.match(output, /test timed out after 5000ms/);
  for (const name of ["failed", "timed-out"]) {
    assert.ok(existsSync(join(dir, `${name}.cleaned`)), `${name}: the leader had no SIGTERM to clean up on`);
    for (const role of ["leader", "spy", "stray"]) {
      const pid = Number(readFileSync(join(dir, `${name}.${role}`), "utf8"));
      // A SIGKILLed process is gone in a moment, once its parent or init reaps it.
      for (const start = Date.now(); !gone(pid) && Date.now() - start < 10_000; ) await new Promise((resolve) => setTimeout(resolve, 50));
      assert.ok(gone(pid), `${name}: its ${role} (pid ${pid}) still runs`);
    }
  }
});
