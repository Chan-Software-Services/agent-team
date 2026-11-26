// The Agent Chrome as one of the prototyping window's targets (proto/agent-chrome.mjs), driven
// through the CLI and the host's API as Daniel and the session do, against a throwaway headless
// Chrome standing in for the Agent Chrome (helpers/chrome.mjs's startChrome, its address given as
// PROTO_AGENT_CHROME_URL), never Daniel's on 9222. That Chrome holds tabs of its own before the
// host attaches: a localhost page in its default context, the one the host attaches to, and one
// in an off-the-record context. It checks the target's availability and version, the host's own
// tab opened at the window's URL in front while every other tab keeps its page and gets no
// toolbar, even reloaded, a size applied by emulation and `window` clearing it, a switch away and
// `proto stop` leaving the Agent Chrome as it was, the host's tab reused, no cookie or storage
// written into it, the tab on a page off localhost getting no toolbar and its binding refused,
// the Chrome quitting while attached, and the frontend toolkit's MCP server
// sharing the Chrome with the host. A launched engine the switch-away cases need runs as in the
// other proto tests: under CI=true a missing one fails, elsewhere it skips with its reason.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { createServer as createTcpServer } from "node:net";
import { describe, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { browserSession, declaredServer, serverListing, startChrome, tabSession } from "./helpers/chrome.mjs";
import { tempDir } from "./helpers/mcp.mjs";
import { protoSession } from "./helpers/proto.mjs";

const listen = (server) => new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", () => resolve(server.address().port));
});

// The fixture site on 127.0.0.1: /login sets a cookie and a localStorage item, /home copies that
// item into a cookie (so a page's metrics show the localStorage it was given), /other and /tab
// set nothing.
async function fixture(t) {
  const server = createServer((request, response) => {
    const { pathname } = new URL(request.url, "http://x");
    const pages = {
      "/login": `<title>login</title><script>document.cookie = "login=yes; path=/"; localStorage.setItem("login", "yes")</script><p>logged in</p>`,
      "/home": `<title>home</title><script>document.cookie = "seen=" + localStorage.getItem("login") + "; path=/"</script><p>home</p>`,
      "/other": "<title>other</title><p>other</p>",
      "/tab": "<title>own tab</title><p>a tab of Daniel's own</p>",
    };
    if (pathname === "/file") {
      response.writeHead(200, { "content-type": "text/plain", "content-disposition": 'attachment; filename="proto-download.txt"' });
      return response.end("downloaded\n");
    }
    if (!Object.hasOwn(pages, pathname)) {
      response.writeHead(404);
      return response.end("not found");
    }
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    return response.end(`<!doctype html><meta name="viewport" content="width=device-width">${pages[pathname]}`);
  });
  const port = await listen(server);
  t.after(() => new Promise((resolve) => {
    server.closeAllConnections();
    server.close(resolve);
  }));
  return { url: `http://127.0.0.1:${port}/` };
}

// The throwaway Agent Chrome, with an off-the-record tab (startChrome's) and Daniel's own
// localhost tab in its default context; closed when `t` ends.
async function agentChrome(t, site) {
  const chrome = await startChrome([`${site.url}other?incognito`]);
  t.after(() => chrome.close());
  const browser = await browserSession(chrome.browserUrl);
  try {
    await browser.send("Target.createTarget", { url: `${site.url}tab` });
  } finally {
    browser.close();
  }
  await until(async () => (await tabs(chrome)).some((tab) => tab.url === `${site.url}tab` && tab.title === "own tab"), "Daniel's tab loads");
  return chrome;
}

// The Chrome's page tabs, as /json/list has them, the front one first.
const tabs = async (chrome) => (await fetch(`${chrome.browserUrl}/json/list`).then((r) => r.json())).filter((tab) => tab.type === "page");

async function until(check, why, timeoutMs = 20_000) {
  for (const started = Date.now(); Date.now() - started < timeoutMs; await sleep(100)) {
    if (await check()) return;
  }
  assert.fail(`${why}: not in ${timeoutMs / 1000} s`);
}

// What a tab shows of the host, read over a session of the test's own: its overlay script, the
// answer to its hello, its <proto-overlay> elements, the binding, and its size.
const probe = `(async () => ({
  url: location.href,
  overlay: typeof window.__protoOverlay,
  shown: window.__protoOverlay ? await window.__protoOverlay.ready : null,
  drawn: document.querySelectorAll("proto-overlay").length,
  binding: typeof window.__protoHost,
  width: innerWidth,
  height: innerHeight,
  scale: devicePixelRatio,
  touch: navigator.maxTouchPoints,
  cookie: document.cookie,
  login: localStorage.getItem("login"),
}))()`;

async function inTab(chrome, targetId, { reload = false } = {}) {
  const tab = await tabSession(chrome.browserUrl, targetId);
  try {
    if (reload) {
      await tab.send("Page.enable");
      const loaded = new Promise((resolve) => tab.on("Page.loadEventFired", resolve));
      await tab.send("Page.reload");
      await loaded;
    }
    const { result, exceptionDetails } = await tab.send("Runtime.evaluate", { expression: probe, awaitPromise: true, returnByValue: true });
    if (exceptionDetails) throw new Error(`the probe failed in ${targetId}: ${exceptionDetails.text}`);
    return result.value;
  } finally {
    tab.close();
  }
}

const hostEnv = (chrome) => ({ PROTO_AGENT_CHROME_URL: chrome.browserUrl });
const versionOf = async (chrome) => (await fetch(`${chrome.browserUrl}/json/version`).then((r) => r.json())).Browser.split("/")[1];

// The host's own tab: the one tab at `url` that was not there before.
async function hostTab(chrome, before, url) {
  const known = new Set(before.map((tab) => tab.id));
  const added = (await tabs(chrome)).filter((tab) => !known.has(tab.id));
  assert.equal(added.length, 1, `one tab added: ${JSON.stringify(added)}`);
  assert.equal(added[0].url, url);
  return added[0];
}

describe("the agent-chrome target's availability", () => {
  test("with no Agent Chrome answering, it is unavailable naming the address and agent-chrome, and a window there is refused", async (t) => {
    const proto = protoSession(t);
    const reason = "no Agent Chrome answers on 127.0.0.1:1; start it with `toolkits/frontend/scripts/agent-chrome`";
    const targets = await proto.run(["targets"]);
    assert.equal(targets.status, 0, targets.stderr);
    assert.ok(targets.stdout.includes(`  agent-chrome (no version): unavailable: ${reason}; sizeBy=emulation overlayBeforePageScripts=true matchedRules=cdp navigationGuard=false\n`), targets.stdout);
    const site = await fixture(t);
    const opened = await proto.run(["open", `${site.url}other`, "--target", "agent-chrome/window"]);
    assert.deepEqual([opened.status, opened.stderr], [1, `proto: ${reason}\n`]);
    assert.equal((await proto.request("GET", "/v1/status")).body.window, null);
  });

  test("an address that takes the connection and never answers is unavailable within about 2 s", async (t) => {
    const held = new Set();
    const silent = createTcpServer((socket) => held.add(socket));
    const port = await listen(silent);
    t.after(() => {
      for (const socket of held) socket.destroy();
      silent.close();
    });
    const proto = protoSession(t, { env: { PROTO_AGENT_CHROME_URL: `http://127.0.0.1:${port}` } });
    assert.equal((await proto.run(["status"])).status, 0);
    await proto.run(["targets"]);
    const started = Date.now();
    const { body } = await proto.request("GET", "/v1/targets");
    const took = Date.now() - started;
    const engine = body.engines.find((each) => each.name === "agent-chrome");
    assert.deepEqual([engine.available, engine.reason], [false, `no Agent Chrome answers on 127.0.0.1:${port}; start it with \`toolkits/frontend/scripts/agent-chrome\``]);
    assert.ok(took >= 1_900 && took < 5_000, `the answer took ${took} ms`);
  });

  test("with the Agent Chrome running, proto targets shows it available with its version from /json/version", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const proto = protoSession(t, { env: hostEnv(chrome) });
    const targets = await proto.run(["targets"]);
    assert.equal(targets.status, 0, targets.stderr);
    const version = await versionOf(chrome);
    assert.match(version, /^\d+\.\d+\.\d+\.\d+$/);
    assert.ok(targets.stdout.includes(`  agent-chrome ${version}: available; sizeBy=emulation overlayBeforePageScripts=true matchedRules=cdp navigationGuard=false\n`), targets.stdout);
  });
});

describe("a window on the Agent Chrome", () => {
  test("opens a new tab of its own at the URL in front, and leaves every other tab on its page with no toolbar, even reloaded", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const before = await tabs(chrome);
    const unattached = await Promise.all(before.map((tab) => inTab(chrome, tab.id)));
    const proto = protoSession(t, { env: hostEnv(chrome) });
    const url = `${site.url}other?window`;
    const opened = await proto.run(["open", url, "--target", "agent-chrome/window"]);
    assert.equal(opened.status, 0, opened.stderr);
    assert.equal(opened.stdout, `proto: agent-chrome ${await versionOf(chrome)} at window (its own window size) on ${url}\n`);
    const own = await hostTab(chrome, before, url);
    assert.equal((await tabs(chrome))[0].id, own.id, "the host's tab is in front");
    const read = await proto.toolbarUntil((toolbar) => toolbar.drawn, "the toolbar draws in the host's tab");
    assert.equal(read.controls.Engine.value, "agent-chrome");
    assert.equal(read.controls.Size.value, "window");
    assert.ok(read.controls.Size.options.some((option) => option.value === "window"), "window is a size here");
    for (const [index, tab] of before.entries()) {
      for (const reload of [false, true]) {
        const seen = await inTab(chrome, tab.id, { reload });
        assert.equal(seen.url, tab.url, `${tab.url} keeps its page`);
        assert.deepEqual([seen.width, seen.height, seen.scale], [unattached[index].width, unattached[index].height, unattached[index].scale], `${tab.url} keeps its size`);
        assert.equal(seen.drawn, 0, `${tab.url} has no toolbar (reloaded: ${reload})`);
        assert.notEqual(seen.shown, true, `${tab.url} was not told to show it`);
      }
    }
    assert.deepEqual((await tabs(chrome)).map((tab) => tab.url).sort(), [...before.map((tab) => tab.url), url].sort());
  });

  test("leaves the Agent Chrome's own settings: a download in another tab still lands where Daniel's Chrome puts it", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const before = await tabs(chrome);
    const daniels = before.find((tab) => tab.url === `${site.url}tab`);
    // Daniel's own download setting, held by a session of the test's as long as the test runs.
    const downloads = tempDir("downloads");
    const settings = await browserSession(chrome.browserUrl);
    t.after(() => settings.close());
    await settings.send("Browser.setDownloadBehavior", { behavior: "allow", downloadPath: downloads });
    const proto = protoSession(t, { env: hostEnv(chrome) });
    assert.equal((await proto.run(["open", `${site.url}other`, "--target", "agent-chrome/phone"])).status, 0);
    const tab = await tabSession(chrome.browserUrl, daniels.id);
    try {
      await tab.send("Runtime.evaluate", { expression: `Object.assign(document.createElement("a"), { href: "/file", download: "proto-download.txt" }).click()` });
    } finally {
      tab.close();
    }
    await until(() => existsSync(join(downloads, "proto-download.txt")), "the download lands in Daniel's download directory", 10_000);
  });

  test("takes each size by emulation, without the device's user agent, and window clears it", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const before = await tabs(chrome);
    const own = await inTab(chrome, before.find((tab) => tab.url === `${site.url}tab`).id);
    const proto = protoSession(t, { env: hostEnv(chrome) });
    const url = `${site.url}other`;
    assert.equal((await proto.run(["open", url, "--target", "agent-chrome/window"])).status, 0);
    const tab = await hostTab(chrome, before, url);
    const metrics = async () => {
      const page = await proto.page("metrics");
      return [page.innerWidth, page.innerHeight, page.devicePixelRatio, page.maxTouchPoints > 0, page.userAgent];
    };
    const agent = (await proto.page("metrics")).userAgent;
    assert.deepEqual(await metrics(), [own.width, own.height, own.scale, false, agent]);
    const sizes = [
      ["phone", [390, 844, 3, true]],
      ["1024x768@2", [1024, 768, 2, false]],
      ["iPhone 15", [393, 659, 3, true]],
      ["tablet", [768, 1024, 2, true]],
      ["window", [own.width, own.height, own.scale, false]],
      ["phone-small", [360, 800, 3, true]],
      ["777x555", [777, 555, 1, false]],
    ];
    for (const [size, expected] of sizes) {
      const set = await proto.run(["set", size]);
      assert.equal(set.status, 0, `${size}: ${set.stderr}`);
      assert.deepEqual(await metrics(), [...expected, agent], size);
      assert.equal((await inTab(chrome, tab.id)).width, expected[0], `${size}: the tab itself reports it`);
    }
    assert.equal((await proto.run(["set", "window"])).status, 0);
    assert.deepEqual(await metrics(), [own.width, own.height, own.scale, false, agent]);
    assert.equal((await tabs(chrome)).length, before.length + 1, "every size in the one tab");
  });

  test("switching away carries the URL and the localhost login, and leaves the tab open as it was: no toolbar, its own size, and reloaded no overlay or binding", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const before = await tabs(chrome);
    const own = await inTab(chrome, before.find((tab) => tab.url === `${site.url}tab`).id);
    const proto = protoSession(t, { env: hostEnv(chrome) });
    if (!(await proto.engine(t, "chromium"))) return;
    assert.equal((await proto.run(["open", `${site.url}login`, "--target", "agent-chrome/phone"])).status, 0);
    const tab = await hostTab(chrome, before, `${site.url}login`);
    const home = `${site.url}home?carried`;
    assert.equal((await proto.run(["open", home])).status, 0, "a new URL on the Agent Chrome");
    assert.equal((await tabs(chrome)).length, before.length + 1, "in the same tab");
    await proto.toolbarUntil((toolbar) => toolbar.drawn, "the toolbar draws");
    const set = await proto.run(["set", "chromium/laptop"]);
    assert.equal(set.status, 0, set.stderr);
    assert.match(set.stdout, /^proto: chromium \S+ at laptop \(1440x900@1\) on /);
    const page = await proto.page("metrics");
    assert.equal(page.url, home);
    assert.match(page.userAgent, /Chrome\//);
    assert.deepEqual(page.cookie.split("; ").sort(), ["login=yes", "seen=yes"], "the cookie and the localStorage item came along");
    const left = await inTab(chrome, tab.id);
    assert.deepEqual([left.url, left.drawn, left.width, left.height, left.scale, left.touch], [home, 0, own.width, own.height, own.scale, 0]);
    const reloaded = await inTab(chrome, tab.id, { reload: true });
    assert.deepEqual([reloaded.url, reloaded.overlay, reloaded.binding, reloaded.drawn, reloaded.width], [home, "undefined", "undefined", 0, own.width]);
    assert.deepEqual((await tabs(chrome)).map((each) => each.url).sort(), [...before.map((each) => each.url), home].sort());
  });

  test("proto stop leaves the Agent Chrome's tab open as it was: no toolbar, its own size, and reloaded no overlay or binding", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const before = await tabs(chrome);
    const own = await inTab(chrome, before.find((tab) => tab.url === `${site.url}tab`).id);
    const proto = protoSession(t, { env: hostEnv(chrome) });
    const url = `${site.url}other`;
    assert.equal((await proto.run(["open", url, "--target", "agent-chrome/tablet"])).status, 0);
    const tab = await hostTab(chrome, before, url);
    await proto.toolbarUntil((toolbar) => toolbar.drawn, "the toolbar draws");
    assert.equal((await inTab(chrome, tab.id)).width, 768);
    assert.deepEqual([(await proto.run(["stop"])).stdout, await proto.hostPid()], ["proto: stopped\n", null]);
    const left = await inTab(chrome, tab.id);
    assert.deepEqual([left.url, left.drawn, left.width, left.height, left.scale, left.touch], [url, 0, own.width, own.height, own.scale, 0]);
    const reloaded = await inTab(chrome, tab.id, { reload: true });
    assert.deepEqual([reloaded.overlay, reloaded.binding, reloaded.drawn, reloaded.width], ["undefined", "undefined", 0, own.width]);
    assert.equal((await tabs(chrome)).length, before.length + 1);
  });

  test("switching to it again reuses the host's tab, and no cookie or storage of a launched window is written into it", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const before = await tabs(chrome);
    const proto = protoSession(t, { env: hostEnv(chrome) });
    if (!(await proto.engine(t, "chromium"))) return;
    assert.equal((await proto.run(["open", `${site.url}login`, "--target", "chromium/laptop"])).status, 0);
    assert.equal((await proto.page("metrics")).cookie, "login=yes", "the launched window is logged in");
    const other = `${site.url}other`;
    assert.equal((await proto.run(["open", other, "--target", "agent-chrome/window"])).status, 0);
    const tab = await hostTab(chrome, before, other);
    const cookies = async () => {
      const browser = await browserSession(chrome.browserUrl);
      try {
        return (await browser.send("Storage.getCookies")).cookies.map((cookie) => cookie.name);
      } finally {
        browser.close();
      }
    };
    assert.deepEqual(await cookies(), []);
    assert.deepEqual([(await inTab(chrome, tab.id)).cookie, (await inTab(chrome, tab.id)).login], ["", null]);
    assert.equal((await proto.run(["set", "chromium"])).status, 0);
    assert.equal((await proto.run(["set", "agent-chrome/phone"])).status, 0);
    const again = await tabs(chrome);
    assert.equal(again.length, before.length + 1, "no second tab");
    assert.ok(again.some((each) => each.id === tab.id && each.url === other), "the same tab, at the window's URL");
    assert.equal(again[0].id, tab.id, "brought to the front");
    await proto.toolbarUntil((toolbar) => toolbar.drawn && toolbar.controls.Size.value === "phone", "the toolbar draws in the reused tab");
    assert.equal((await proto.page("metrics")).innerWidth, 390);
    assert.deepEqual(await cookies(), []);
    assert.equal((await inTab(chrome, tab.id)).login, null);
  });

  test("the Chrome quitting while attached drops the window, and the host runs on", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const proto = protoSession(t, { env: hostEnv(chrome) });
    assert.equal((await proto.run(["open", `${site.url}other`, "--target", "agent-chrome/phone"])).status, 0);
    const pid = await proto.hostPid();
    await chrome.close();
    await until(async () => (await proto.request("GET", "/v1/status")).body.window === null, "the window is dropped");
    const status = await proto.run(["status"]);
    assert.equal(status.stdout, `proto: host ${pid}; no window\n`);
    const { body } = await proto.request("GET", "/v1/targets");
    assert.equal(body.engines.find((each) => each.name === "agent-chrome").available, false);
    assert.equal((await proto.run(["set", "phone"])).stderr, "proto: no window is open; run `proto open`\n");
  });
});

describe("the host's tab on a page off localhost", () => {
  test("gets no toolbar, and the host answers its binding as any other page's", async (t) => {
    const site = await fixture(t);
    // A second site on [::1], off localhost by the guard's rule, which the Agent Chrome's tab may
    // reach, as it has no navigation guard.
    const off = createServer((request, response) => {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end("<!doctype html><title>off</title><p>a page off localhost</p>");
    });
    await new Promise((resolve, reject) => {
      off.once("error", reject);
      off.listen(0, "::1", resolve);
    });
    t.after(() => new Promise((resolve) => {
      off.closeAllConnections();
      off.close(resolve);
    }));
    const offUrl = `http://[::1]:${off.address().port}/off`;
    const chrome = await agentChrome(t, site);
    const proto = protoSession(t, { env: hostEnv(chrome) });
    assert.equal((await proto.run(["open", `${site.url}other`, "--target", "agent-chrome/phone"])).status, 0);
    await proto.toolbarUntil((toolbar) => toolbar.drawn, "the toolbar draws on the localhost page");
    assert.equal((await proto.page("navigate", { url: offUrl })).url, offUrl);
    assert.deepEqual(await proto.page("send", { message: { type: "hello" } }), { answer: { show: false } });
    for (const message of [{ type: "reload" }, { type: "collapse", collapsed: true }, { type: "set_target", target: "phone-small" }]) {
      const { answer } = await proto.page("send", { message });
      assert.equal(answer.error, "this page is not the prototyping window's", JSON.stringify(message));
    }
    const read = await proto.toolbar("read");
    assert.deepEqual(read, { drawn: false });
    assert.equal((await proto.page("metrics")).url, offUrl, "nothing reloaded or moved the page");
    assert.equal((await proto.request("GET", "/v1/status")).body.window.target, "agent-chrome/phone", "no switch began");
  });
});

describe("the host's tab closed by Daniel", () => {
  test("drops the window, and the host runs on with the Agent Chrome still available", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const before = await tabs(chrome);
    const proto = protoSession(t, { env: hostEnv(chrome) });
    assert.equal((await proto.run(["open", `${site.url}other`, "--target", "agent-chrome/window"])).status, 0);
    const tab = await hostTab(chrome, before, `${site.url}other`);
    const browser = await browserSession(chrome.browserUrl);
    try {
      await browser.send("Target.closeTarget", { targetId: tab.id });
    } finally {
      browser.close();
    }
    await until(async () => (await proto.request("GET", "/v1/status")).body.window === null, "the window is dropped");
    assert.equal((await proto.run(["status"])).stdout, `proto: host ${await proto.hostPid()}; no window\n`);
    assert.deepEqual((await tabs(chrome)).map((each) => each.id).sort(), before.map((each) => each.id).sort());
    const opened = await proto.run(["open", `${site.url}other?again`, "--target", "agent-chrome/phone"]);
    assert.equal(opened.status, 0, opened.stderr);
    await hostTab(chrome, before, `${site.url}other?again`);
  });
});

describe("the host and the frontend toolkit's MCP server on one Agent Chrome", () => {
  test("the server lists the host's tab, takes its snapshot and evaluates on it, and the toolbar, the binding and the size hold", async (t) => {
    const site = await fixture(t);
    const chrome = await agentChrome(t, site);
    const proto = protoSession(t, { env: hostEnv(chrome) });
    const url = `${site.url}other?shared`;
    assert.equal((await proto.run(["open", url, "--target", "agent-chrome/phone"])).status, 0);
    await proto.toolbarUntil((toolbar) => toolbar.drawn, "the toolbar draws");
    const { server, pages } = await serverListing(() => declaredServer(chrome.browserUrl), url);
    try {
      const id = Number(pages.match(new RegExp(`^(\\d+): other \\(${url.replace(/[.?]/g, "\\$&")}\\)`, "m"))?.[1]);
      assert.ok(id > 0, pages);
      await server.call("select_page", { pageId: id });
      const snapshot = await server.call("take_snapshot");
      // The server's snapshot lists the toolbar's controls, as ui-capture's page-snapshot.txt does.
      assert.match(snapshot, /combobox "Engine" .*value="agent-chrome"/);
      assert.match(snapshot, /combobox "Size" .*value="phone"/);
      assert.match(snapshot, /button "Hide toolbar"/);
      const evaluated = await server.call("evaluate_script", { function: "() => [innerWidth, innerHeight, devicePixelRatio, typeof window.__protoHost, document.querySelectorAll('proto-overlay').length]" });
      assert.match(evaluated, /\[\s*390,\s*844,\s*3,\s*"function",\s*1\s*\]/);
      const read = await proto.toolbar("read");
      assert.deepEqual([read.drawn, read.controls.Size.value], [true, "phone"]);
      assert.equal((await proto.page("send", { message: { type: "hello" } })).answer.show, true, "the binding answers");
      const page = await proto.page("metrics");
      assert.deepEqual([page.innerWidth, page.innerHeight, page.devicePixelRatio], [390, 844, 3]);
      assert.equal((await proto.run(["set", "1024x768"])).status, 0, "the host resizes with the server attached");
      assert.match(await server.call("evaluate_script", { function: "() => [innerWidth, innerHeight]" }), /\[\s*1024,\s*768\s*\]/);
    } finally {
      await server.close();
    }
    const read = await proto.toolbar("read");
    assert.deepEqual([read.drawn, read.controls.Size.value], [true, "1024x768"]);
    assert.equal((await proto.page("metrics")).innerWidth, 1024);
  });
});
