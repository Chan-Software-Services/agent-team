// How the tests' stand-in Chrome (helpers/chrome.mjs) starts, against a TEAM_CHROME that is a
// shell script, or helpers/old-chrome. startChrome waits for a Chrome that starts late, as one on
// a loaded CI runner may (the script sleeps, then runs the machine's Chrome). It ends one that
// never opens its debugging port at the bound, and fails at once on one that exits first, each
// failure with Chrome's log. And it fails at once on a Chrome too old for open_devtools, which
// inspect drives, naming it and what it lacks, where each inspect would otherwise only time out
// after 180 s.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { chromePath, startChrome } from "./helpers/chrome.mjs";
import { stubDir, tempDir } from "./helpers/mcp.mjs";

const tabs = ["data:text/html,<title>Page</title>"];

// Runs the rest of test `t` with TEAM_CHROME naming `path`.
function useChrome(t, path) {
  const before = process.env.TEAM_CHROME;
  t.after(() => {
    if (before === undefined) delete process.env.TEAM_CHROME;
    else process.env.TEAM_CHROME = before;
  });
  process.env.TEAM_CHROME = path;
}

// A TEAM_CHROME for test `t` that is a shell script of `body`.
function scriptedChrome(t, body) {
  const path = join(tempDir("scripted-chrome"), "chrome");
  writeFileSync(path, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  useChrome(t, path);
}

test("a Chrome that starts more than 30 s late is waited for", async (t) => {
  const lateS = 35;
  scriptedChrome(t, `sleep ${lateS}\nexec "${chromePath()}" "$@"`);
  const start = Date.now();
  const chrome = await startChrome(tabs);
  t.after(() => chrome.close());
  assert.ok(Date.now() - start >= lateS * 1000, "it started late");
  const { webSocketDebuggerUrl } = await fetch(`${chrome.browserUrl}/json/version`).then((r) => r.json());
  assert.match(webSocketDebuggerUrl, /^ws:/);
});

test("a Chrome that never opens its debugging port is ended at the bound, with its log", async (t) => {
  const pidFile = join(tempDir("chrome-pid"), "pid");
  scriptedChrome(t, `echo $$ >"${pidFile}"\necho "scripted Chrome: still starting" >&2\nexec sleep 600`);
  await assert.rejects(startChrome(tabs, { portWaitMs: 5000 }), {
    message: "Chrome did not open its debugging port in 5 s:\nscripted Chrome: still starting\n",
  });
  const pid = Number(readFileSync(pidFile, "utf8"));
  assert.throws(() => process.kill(pid, 0), { code: "ESRCH" }, "its process has ended");
});

test("a Chrome that exits before opening its debugging port fails at once, with its status and its log", async (t) => {
  scriptedChrome(t, `echo "scripted Chrome: gave up" >&2\nexit 3`);
  const start = Date.now();
  await assert.rejects(startChrome(tabs), {
    message: "Chrome exited (status 3) before it opened its debugging port:\nscripted Chrome: gave up\n",
  });
  assert.ok(Date.now() - start < 20_000, "it fails without waiting the port's time out");
});

test("a Chrome without open_devtools' protocol methods fails at once, naming itself and what it lacks", async (t) => {
  useChrome(t, join(stubDir, "old-chrome"));
  const start = Date.now();
  await assert.rejects(startChrome(tabs), {
    message:
      "Chrome/138.0.7204.183 has no Target.openDevTools or Target.getDevToolsTarget, which open_devtools needs: " +
      "update Chrome, or set TEAM_CHROME to a current one",
  });
  assert.ok(Date.now() - start < 20_000, "it fails before any wait for the tabs");
});
