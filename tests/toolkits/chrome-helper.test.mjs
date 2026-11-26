// How the tests' stand-in Chrome (helpers/chrome.mjs) starts: startChrome waits for a Chrome
// that starts late, as one on a loaded CI runner may, and fails at once on one that exits before
// it opens its debugging port, and on one too old for open_devtools, which inspect drives,
// naming the Chrome and what it lacks, where each inspect would otherwise only time out after
// 180 s.
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { chromePath, startChrome } from "./helpers/chrome.mjs";
import { stubDir, tempDir } from "./helpers/mcp.mjs";

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
  scriptedChrome(t, `sleep 35\nexec "${chromePath()}" "$@"`);
  const start = Date.now();
  const chrome = await startChrome(["data:text/html,<title>Page</title>"]);
  t.after(() => chrome.close());
  assert.ok(Date.now() - start >= 35_000, "it started late");
  const { webSocketDebuggerUrl } = await fetch(`${chrome.browserUrl}/json/version`).then((r) => r.json());
  assert.match(webSocketDebuggerUrl, /^ws:/);
});

test("a Chrome that exits before opening its debugging port fails at once, with its status and its log", async (t) => {
  scriptedChrome(t, `echo "scripted Chrome: gave up" >&2\nexit 3`);
  const start = Date.now();
  await assert.rejects(startChrome(["data:text/html,<title>Page</title>"]), {
    message: "Chrome exited (status 3) before it opened its debugging port:\nscripted Chrome: gave up\n",
  });
  assert.ok(Date.now() - start < 20_000, "it fails without waiting the port's time out");
});

test("a Chrome without open_devtools' protocol methods fails at once, naming itself and what it lacks", async (t) => {
  useChrome(t, join(stubDir, "old-chrome"));
  const start = Date.now();
  await assert.rejects(startChrome(["data:text/html,<title>Page</title>"]), {
    message:
      "Chrome/138.0.7204.183 has no Target.openDevTools or Target.getDevToolsTarget, which open_devtools needs: " +
      "update Chrome, or set TEAM_CHROME to a current one",
  });
  assert.ok(Date.now() - start < 20_000, "it fails before any wait for the tabs");
});
