// The prototyping host's tracer bullet (toolkits/frontend/scripts/proto and proto/), driven
// through the CLI as Daniel runs it, headless, in a runtime directory of each test's own, against
// fixture pages on 127.0.0.1 (helpers/proto.mjs, helpers/chrome.mjs's serveFixture): the team
// session gate (the CLI's, the host's and client.mjs's connect's), the localhost guard and the
// catalogue's refusals before anything opens; a window opened in each launched engine at a
// preset, a device and a free size, read back through the page's own metrics (/v1/test/page),
// and moved by a second open in the same host; status, targets and stop; the runtime
// directory's, socket's and token's modes and the token check; two opens at once, a killed
// host, a stale start lock taken over by eight clients at once and by a client that read it
// stale before another took it, a client that read no token before the host wrote its own, and
// a host of another protocol; install's call of Playwright's own installer; and an engine whose
// browser is missing. Every engine the machine has runs; under CI=true a missing one fails,
// elsewhere it skips with its reason.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { describe, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { serveFixture } from "./helpers/chrome.mjs";
import { repoRoot, tempDir } from "./helpers/mcp.mjs";
import { children, ownedPid, startingEnvironment } from "./helpers/process.mjs";
import { protoSession, runScript } from "./helpers/proto.mjs";

const hostScript = join(repoRoot, "toolkits", "frontend", "proto", "host.mjs");
const clientModule = join(repoRoot, "toolkits", "frontend", "proto", "client.mjs");
const engines = ["chromium", "firefox", "webkit"];
const page = (title) => `<!doctype html><meta name="viewport" content="width=device-width"><title>${title}</title><p>${title}</p>`;
const devices = JSON.parse(execFileSync(process.execPath, ["-e", `process.stdout.write(JSON.stringify(require(${JSON.stringify(join(repoRoot, "servers", "node_modules", "playwright-core"))}).devices["iPhone 15"]))`], { encoding: "utf8" }));
const offLocalhost = (url) => `proto: ${url} is off localhost; proto opens only http or https on localhost or 127.0.0.1\n`;
const gate = (role) => `proto: the prototyping host is Daniel's own sessions'; a team session (AGENT_TEAM_ROLE=${role}) may not drive it\n`;

async function fixture(t) {
  const site = await serveFixture({ "/": page("home"), "/other": page("other") });
  t.after(() => site.close());
  return site;
}

const metrics = async (proto) => {
  const answer = await proto.request("POST", "/v1/test/page", { action: "metrics" });
  assert.equal(answer.status, 200, JSON.stringify(answer.body));
  return answer.body;
};

// The host processes of this runtime directory, by their command and starting environment.
function hostsOf(dir) {
  const listing = execFileSync("ps", ["-A", "-ww", "-o", "pid=", "-o", "command="], { encoding: "utf8" });
  return listing.trim().split("\n").map((line) => line.trim()).filter((line) => line.includes(hostScript))
    .map((line) => Number(line.split(/\s/, 1)[0]))
    .filter((pid) => {
      try {
        return startingEnvironment(pid).includes(`PROTO_RUNTIME_DIR=${dir}`);
      } catch {
        return false; // Gone while we looked.
      }
    });
}

// A git checkout holding `settings` as its .proto.json (a string as written, or a value).
function checkoutWith(settings) {
  const dir = tempDir("checkout");
  execFileSync("git", ["init", "-q", dir]);
  if (settings !== undefined) writeFileSync(join(dir, ".proto.json"), typeof settings === "string" ? settings : JSON.stringify(settings));
  return dir;
}

describe("proto's refusals before anything opens", () => {
  test("--help prints the CLI's header, and a malformed command line exits 2", async (t) => {
    const proto = protoSession(t);
    const help = await proto.run(["--help"]);
    assert.equal(help.status, 0);
    assert.match(help.stdout, /^Open the project's dev site in a prototyping window/);
    assert.match(help.stdout, /^Usage: proto open \[<url>\] \[--target <engine>\/<size>\]$/m);
    assert.match(help.stdout, /never with --with-deps and never under sudo/);
    for (const args of [[], ["bogus"], ["status", "extra"], ["open", "--bogus"], ["open", "--target"]]) {
      const result = await proto.run(args);
      assert.equal(result.status, 2, `${args.join(" ")}: ${result.stderr}`);
      assert.match(result.stderr, /^proto: usage: proto open/);
    }
    assert.equal(existsSync(proto.dir), false);
  });

  test("a team session is refused by the CLI, the host and the client module before any directory is read or made", async (t) => {
    const proto = protoSession(t);
    // A script of the session's own that imports the client, as a worker's `node -e` could, and
    // hands connect an environment with no role in it.
    const direct = `const { connect } = await import(${JSON.stringify(clientModule)});
const { AGENT_TEAM_ROLE: _role, ...env } = process.env;
await connect({ start: true, env });
process.stdout.write("connected\\n");`;
    for (const role of ["builder", "coordinator"]) {
      for (const args of [["open", "http://127.0.0.1:1/"], ["status"], ["stop"], ["install"]]) {
        const result = await proto.run(args, { env: { AGENT_TEAM_ROLE: role } });
        assert.deepEqual([result.status, result.stderr, result.stdout], [1, gate(role), ""], args.join(" "));
      }
      const host = await runScript(t, process.execPath, [hostScript], { env: { ...proto.env, AGENT_TEAM_ROLE: role } });
      assert.deepEqual([host.status, host.stderr], [1, gate(role)]);
      const client = await runScript(t, process.execPath, ["--input-type=module", "-e", direct], { env: { ...proto.env, AGENT_TEAM_ROLE: role } });
      assert.deepEqual([client.status, client.stderr, client.stdout], [1, gate(role), ""], "client.mjs's connect");
    }
    assert.equal(existsSync(proto.dir), false);
  });

  test("a URL off localhost is refused before anything opens", async (t) => {
    const proto = protoSession(t);
    for (const url of ["http://example.com/", "file:///etc/passwd", "http://localhost.example.com/", "http://127.0.0.2/"]) {
      const result = await proto.run(["open", url]);
      assert.deepEqual([result.status, result.stderr], [1, offLocalhost(url)]);
    }
    const notUrl = await proto.run(["open", "localhost:5173"]);
    assert.equal(notUrl.status, 1);
    assert.equal(existsSync(proto.dir), false);
  });

  test("each bad target is refused with one line naming its text, before a host starts", async (t) => {
    const proto = protoSession(t);
    const cases = {
      "safari/phone": `unknown engine "safari" in "safari/phone"; the engines are chromium, firefox, webkit, agent-chrome`,
      "chromium/huge": `unknown size "huge"; a size is a preset (phone-small, phone, tablet, laptop, desktop), a project size, a Playwright device name, or <width>x<height>[@<scale>]`,
      "chromium/50x900": `the size "50x900" is out of range; width and height are whole pixels from 120 to 7680`,
      "chromium/800x9000": `the size "800x9000" is out of range; width and height are whole pixels from 120 to 7680`,
      "chromium/800x600@5": `the scale of "800x600@5" is out of range; a scale is from 0.5 to 4`,
      "chromium/800x600@0.25": `the scale of "800x600@0.25" is out of range; a scale is from 0.5 to 4`,
      "firefox/window": `the size "window" is the Agent Chrome's own window, for agent-chrome only, not firefox`,
      "chromium/iphone 15": `unknown size "iphone 15"; a size is a preset (phone-small, phone, tablet, laptop, desktop), a project size, a Playwright device name, or <width>x<height>[@<scale>]`,
    };
    for (const [target, reason] of Object.entries(cases)) {
      const result = await proto.run(["open", "http://127.0.0.1:1/", "--target", target]);
      assert.deepEqual([result.status, result.stderr], [1, `proto: ${reason}\n`], target);
    }
    assert.equal(existsSync(proto.dir), false);
  });

  test("a bad .proto.json is refused naming the file, the key and the reason", async (t) => {
    const proto = protoSession(t);
    const cases = [
      [{ port: 5173 }, `unknown key "port"; the keys are url, sizes and matrix`],
      [{ sizes: { tiny: { width: 50, height: 800 } } }, "sizes.tiny.width: 50 is not whole pixels from 120 to 7680"],
      [{ sizes: { pixel: { device: "Pixel 99" } } }, `sizes.pixel.device: no Playwright device is named "Pixel 99"`],
      [{ sizes: { phone: { width: 400, height: 800 } } }, `sizes.phone: "phone" is a preset's id`],
      [{ sizes: { window: { width: 400, height: 800 } } }, `sizes.window: "window" is the Agent Chrome's own size`],
      [{ sizes: { "400x800": { width: 400, height: 800 } } }, `sizes.400x800: "400x800" is shaped like a free size`],
      [{ sizes: { wide: { width: 1600, height: 900, scale: 9 } } }, "sizes.wide.scale: 9 is out of range; a scale is from 0.5 to 4"],
      [{ url: "https://example.com/" }, "url: https://example.com/ is off localhost; proto opens only http or https on localhost or 127.0.0.1"],
      [{ matrix: { engines: ["agent-chrome"] } }, `matrix.engines: "agent-chrome" is not one of chromium, firefox, webkit, the engines a capture launches`],
      [{ matrix: { sizes: ["huge"] } }, `matrix.sizes: unknown size "huge"`],
      ["{ not json", "not JSON"],
    ];
    for (const [settings, reason] of cases) {
      const dir = checkoutWith(settings);
      for (const args of [["targets"], ["open", "--target", "chromium/laptop"]]) {
        const result = await proto.run(args, { cwd: dir });
        assert.equal(result.status, 1, `${JSON.stringify(settings)}: ${result.stderr}`);
        assert.ok(result.stderr.startsWith(`proto: ${join(dir, ".proto.json")}: ${reason}`), `${JSON.stringify(settings)}: ${result.stderr}`);
        assert.equal(result.stderr.split("\n").length, 2);
      }
    }
    assert.equal(existsSync(proto.dir), false);
  });
});

describe("a window in each launched engine", () => {
  for (const engine of engines) {
    test(`${engine}: opens at a preset, a device and a free size, each read from the page itself, all in one host and one window`, async (t) => {
      const proto = protoSession(t);
      const site = await fixture(t);
      if (!(await proto.engine(t, engine))) return;
      const version = JSON.parse(readFileSync(join(repoRoot, "servers", "node_modules", "playwright-core", "browsers.json"), "utf8"))
        .browsers.find((browser) => browser.name === engine).browserVersion;
      const host = await proto.hostPid();
      const cases = [
        [`${engine}/phone`, site.url, { width: 390, height: 844, scale: 3, label: "phone (390x844@3)" }],
        [`${engine}/iPhone 15`, `${site.url}other`, { width: devices.viewport.width, height: devices.viewport.height, scale: devices.deviceScaleFactor, userAgent: devices.userAgent, label: `iPhone 15 (${devices.viewport.width}x${devices.viewport.height}@${devices.deviceScaleFactor})` }],
        [`${engine}/1024x768@2`, site.url, { width: 1024, height: 768, scale: 2, label: "1024x768@2 (1024x768@2)" }],
      ];
      for (const [target, url, want] of cases) {
        const opened = await proto.run(["open", url, "--target", target]);
        assert.deepEqual([opened.status, opened.stderr], [0, ""], target);
        assert.equal(opened.stdout, `proto: ${engine} ${version} at ${want.label} on ${url}\n`);
        const seen = await metrics(proto);
        assert.deepEqual([seen.innerWidth, seen.innerHeight, seen.devicePixelRatio, seen.url], [want.width, want.height, want.scale, url], target);
        if (want.userAgent) assert.equal(seen.userAgent, want.userAgent);
        else assert.notEqual(seen.userAgent, devices.userAgent);
        assert.equal(await proto.hostPid(), host, "the same host");
        assert.equal(children(host).length, 1, `one browser below the host after ${target}`);
      }
    });
  }

  test("a second open to another engine and URL moves the one window there, in the same host", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    const available = (await proto.engines()).filter((engine) => engine.available).map((engine) => engine.name);
    if (available.length < 2) {
      if (process.env.CI === "true") assert.fail(`in CI every engine runs, but only ${available.join(", ")} did`);
      return t.skip(`two engines are needed; only ${available.join(", ") || "none"} runs here`);
    }
    const [first, second] = available;
    assert.equal((await proto.run(["open", site.url, "--target", `${first}/laptop`])).status, 0);
    const host = await proto.hostPid();
    const [firstBrowser] = children(host);
    const moved = await proto.run(["open", `${site.url}other`, "--target", second]);
    assert.equal(moved.status, 0, moved.stderr);
    assert.match(moved.stdout, new RegExp(`^proto: ${second} \\S+ at laptop \\(1440x900@1\\) on ${site.url}other\\n$`));
    assert.equal(await proto.hostPid(), host);
    assert.deepEqual(children(host).length, 1);
    assert.notEqual(children(host)[0], firstBrowser, "the first engine's browser was closed");
    const status = await proto.run(["status"]);
    assert.equal(status.stdout, `proto: host ${host}; window ${second}/laptop on ${site.url}other\n`);
  });
});

describe("the host's life", () => {
  test("status, targets and stop: a window by default at chromium/laptop, and nothing left after stop", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    assert.deepEqual(await proto.run(["status"]), { status: 0, stdout: "proto: no host running\n", stderr: "" });
    assert.deepEqual(await proto.run(["stop"]), { status: 0, stdout: "proto: no host running\n", stderr: "" });
    const targets = await proto.run(["targets"]);
    assert.equal(targets.status, 0, targets.stderr);
    const browsers = JSON.parse(readFileSync(join(repoRoot, "servers", "node_modules", "playwright-core", "browsers.json"), "utf8")).browsers;
    for (const engine of engines) {
      const version = browsers.find((browser) => browser.name === engine).browserVersion;
      const rules = engine === "chromium" ? "cdp" : "stylesheet-walk";
      assert.match(targets.stdout, new RegExp(`^  ${engine} ${version.replaceAll(".", "\\.")}: (available|unavailable: .+); sizeBy=context overlayBeforePageScripts=true matchedRules=${rules} navigationGuard=true$`, "m"));
    }
    assert.match(targets.stdout, /^  agent-chrome \(no version\): unavailable: .+; sizeBy=emulation overlayBeforePageScripts=true matchedRules=cdp navigationGuard=false$/m);
    for (const line of ["  phone-small: 360x800@3, mobile, touch (preset)", "  phone: 390x844@3, mobile, touch (preset)", "  tablet: 768x1024@2, mobile, touch (preset)", "  laptop: 1440x900@1 (preset)", "  desktop: 1920x1080@1 (preset)"]) {
      assert.ok(targets.stdout.includes(`${line}\n`), line);
    }
    assert.match(targets.stdout, /^  any of Playwright's 207 devices by name, <width>x<height>\[@<scale>\], and window for agent-chrome$/m);
    if (!(await proto.engine(t, "chromium"))) return;

    const opened = await proto.run(["open", site.url]);
    assert.equal(opened.status, 0, opened.stderr);
    assert.match(opened.stdout, /^proto: chromium \S+ at laptop \(1440x900@1\) on /);
    const host = await proto.hostPid();
    assert.equal((await proto.run(["status"])).stdout, `proto: host ${host}; window chromium/laptop on ${site.url}\n`);
    assert.match((await proto.run(["targets"])).stdout, /^window: chromium\/laptop$/m);
    const [browser] = children(host);
    assert.ok(browser);

    assert.deepEqual(await proto.run(["stop"]), { status: 0, stdout: "proto: stopped\n", stderr: "" });
    for (const pid of [host, Number(browser)]) assert.throws(() => process.kill(pid, 0), { code: "ESRCH" }, `${pid} is gone`);
    for (const name of ["host.sock", "token"]) assert.equal(existsSync(join(proto.dir, name)), false, name);
    assert.equal((await proto.run(["status"])).stdout, "proto: no host running\n");
  });

  test("the runtime directory, socket and token are private, the token is checked, and a directory open to others is refused", async (t) => {
    const proto = protoSession(t);
    assert.equal((await proto.run(["targets"])).status, 0);
    const mode = (name) => statSync(join(proto.dir, name)).mode & 0o777;
    assert.deepEqual([mode("."), mode("host.sock"), mode("token")], [0o700, 0o600, 0o600]);
    assert.match(readFileSync(join(proto.dir, "token"), "utf8"), /^[0-9a-f]{64}\n$/);
    assert.equal((await proto.request("GET", "/v1/status")).status, 200);
    for (const token of [null, "0".repeat(64), ""]) {
      for (const [method, path] of [["GET", "/v1/status"], ["POST", "/v1/stop"], ["GET", "/v1/nowhere"]]) {
        assert.deepEqual(await proto.request(method, path, undefined, { token }), { status: 401, body: { error: "unauthorised" } }, `${method} ${path} with ${token}`);
      }
    }
    assert.equal((await proto.request("GET", "/v1/nowhere")).status, 404);

    const open = protoSession(t);
    mkdirSync(open.dir, { mode: 0o755 });
    for (const args of [["open", "http://127.0.0.1:1/"], ["status"]]) {
      const result = await open.run(args);
      assert.deepEqual([result.status, result.stderr], [1, `proto: the runtime directory ${open.dir} is open to others (mode 0755); make it 0700 or remove it\n`]);
    }
    const host = await runScript(t, process.execPath, [hostScript], { env: open.env });
    assert.deepEqual([host.status, host.stderr], [1, `proto host: the runtime directory ${open.dir} is open to others (mode 0755); make it 0700 or remove it\n`]);
  });

  test("the test routes are off without PROTO_TEST_SEAM", async (t) => {
    const proto = protoSession(t, { env: { PROTO_TEST_SEAM: "" } });
    assert.equal((await proto.run(["targets"])).status, 0);
    assert.equal((await proto.request("POST", "/v1/test/page", { action: "metrics" })).status, 404);
    assert.equal((await proto.request("POST", "/v1/test/toolbar", { action: "read" })).status, 404);
  });

  test("a bad body or target sent to the host is answered 400, and an unavailable engine 503", async (t) => {
    const proto = protoSession(t, { env: { PROTO_BROWSERS_PATH: tempDir("no-browsers") } });
    assert.equal((await proto.run(["targets"])).status, 0);
    const open = (body) => proto.request("POST", "/v1/open", body);
    assert.deepEqual(await open({ url: "http://example.com/" }), { status: 400, body: { error: "http://example.com/ is off localhost; proto opens only http or https on localhost or 127.0.0.1" } });
    assert.deepEqual(await open({ url: "http://127.0.0.1:1/", colour: "red" }), { status: 400, body: { error: `unknown field "colour"; this route takes url, target, project` } });
    assert.deepEqual(await open({ url: "http://127.0.0.1:1/", target: "lynx/phone" }), { status: 400, body: { error: `unknown engine "lynx" in "lynx/phone"; the engines are chromium, firefox, webkit, agent-chrome` } });
    assert.deepEqual(await open({ url: "http://127.0.0.1:1/", project: { file: "/x/.proto.json", settings: { port: 1 } } }), { status: 400, body: { error: `/x/.proto.json: unknown key "port"; the keys are url, sizes and matrix` } });
    const unavailable = await open({ url: "http://127.0.0.1:1/", target: "chromium/phone" });
    assert.equal(unavailable.status, 503);
    assert.match(unavailable.body.error, /^chromium \S+ is not installed \(no .+\); run `proto install`$/);
    // A body past 1 MiB is answered 400 once the limit is passed, and the rest is never read.
    assert.deepEqual(await open({ url: "http://127.0.0.1:1/", pad: "x".repeat(8 << 20) }), { status: 400, body: { error: "the body is over 1 MiB" } });
    assert.equal((await proto.request("GET", "/v1/status")).status, 200);
  });

  test("two opens at once leave one host and one window", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    if (!(await proto.engine(t, "chromium"))) return;
    assert.equal((await proto.run(["stop"])).stdout, "proto: stopped\n");
    const both = await Promise.all([proto.run(["open", site.url]), proto.run(["open", `${site.url}other`])]);
    for (const result of both) assert.equal(result.status, 0, result.stderr);
    const hosts = hostsOf(proto.dir);
    assert.equal(hosts.length, 1, `hosts: ${hosts.join(", ")}`);
    assert.equal(hosts[0], await proto.hostPid());
    assert.equal(children(hosts[0]).length, 1);
  });

  test("a host killed with SIGKILL is replaced by the next open", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    if (!(await proto.engine(t, "chromium"))) return;
    const first = await proto.run(["open", site.url]);
    assert.equal(first.status, 0, first.stderr);
    const killed = await proto.hostPid();
    // Its browser outlives it, as SIGKILL gives Playwright no time; the test ends it.
    for (const pid of children(killed)) ownedPid(t, Number(pid));
    process.kill(killed, "SIGKILL");
    const opened = await proto.run(["open", site.url]);
    assert.equal(opened.status, 0, opened.stderr);
    const host = await proto.hostPid();
    assert.ok(host !== null && host !== killed);
    assert.equal((await proto.run(["status"])).stdout, `proto: host ${host}; window chromium/laptop on ${site.url}\n`);
  });

  test("a start lock older than 30 s is taken over by eight clients at once, which leave one host", async (t) => {
    const proto = protoSession(t);
    mkdirSync(join(proto.dir, "start.lock"), { recursive: true, mode: 0o700 });
    const old = new Date(Date.now() - 31_000);
    utimesSync(join(proto.dir, "start.lock"), old, old);
    const started = Date.now();
    const results = await Promise.all(Array.from({ length: 8 }, () => proto.run(["targets"])));
    for (const result of results) assert.equal(result.status, 0, result.stderr);
    assert.ok(Date.now() - started < 20_000);
    const hosts = hostsOf(proto.dir);
    for (const pid of hosts) ownedPid(t, pid);
    assert.equal(hosts.length, 1, `hosts: ${hosts.join(", ")}`);
    assert.equal((await proto.run(["status"])).stdout, `proto: host ${hosts[0]}; no window\n`);
    assert.equal(existsSync(join(proto.dir, "start.lock")), false);
  });

  test("a client that read a crashed start's lock as stale never takes over the lock another client took after it", async (t) => {
    const proto = protoSession(t);
    const lock = join(proto.dir, "start.lock");
    mkdirSync(lock, { recursive: true, mode: 0o700 });
    const old = new Date(Date.now() - 61_000);
    utimesSync(lock, old, old);
    // Preloaded in the late client alone: its first stat of start.lock is answered only once
    // another client has taken the lock afresh and its host has bound the socket, so it acts on a
    // stale reading of a fresh lock, as a client paused between its stat and its rename would.
    const dir = tempDir("late-client");
    const read = join(dir, "read");
    const taken = join(dir, "taken");
    const hook = join(dir, "late.mjs");
    writeFileSync(hook, `import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
const statSync = fs.statSync;
let late = true;
fs.statSync = (path, ...rest) => {
  const seen = statSync(path, ...rest);
  if (late && String(path).endsWith("start.lock")) {
    late = false;
    fs.writeFileSync(${JSON.stringify(read)}, "");
    const until = Date.now() + 20_000;
    for (;;) {
      let fresh = false;
      try {
        fresh = Date.now() - statSync(path).mtimeMs < 10_000 && fs.existsSync(${JSON.stringify(join(proto.dir, "host.sock"))});
      } catch {}
      if (fresh) fs.writeFileSync(${JSON.stringify(taken)}, "");
      if (fresh || Date.now() > until) break;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
    }
  }
  return seen;
};
syncBuiltinESMExports();
`);
    const lateRun = proto.run(["targets"], { env: { NODE_OPTIONS: `--import=${pathToFileURL(hook).href}` } });
    const deadline = Date.now() + 20_000;
    while (!existsSync(read)) {
      assert.ok(Date.now() < deadline, "the late client read the lock");
      await sleep(20);
    }
    const first = await proto.run(["targets"]);
    const late = await lateRun;
    const hosts = hostsOf(proto.dir);
    for (const pid of hosts) ownedPid(t, pid);
    assert.ok(existsSync(taken), "the late client went on only once the first had taken the lock and its host had bound");
    assert.deepEqual([first.status, late.status], [0, 0], first.stderr + late.stderr);
    assert.equal(hosts.length, 1, `hosts: ${hosts.join(", ")}`);
    assert.equal((await proto.run(["status"])).stdout, `proto: host ${hosts[0]}; no window\n`);
    assert.equal(existsSync(lock), false);
  });

  test("a client that read no token before the host wrote its own is answered once it is there", async (t) => {
    const proto = protoSession(t);
    // Preloaded in the host: its token's rename into place waits 3 s, so a client that reads the
    // token file while the socket is bound reads none, as a client a moment early does.
    const dir = tempDir("slow-token");
    const hook = join(dir, "slow-token.mjs");
    writeFileSync(hook, `import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
const renameSync = fs.renameSync;
fs.renameSync = (from, to, ...rest) => {
  if (String(to).endsWith("/token") && process.argv[1]?.endsWith("host.mjs")) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 3_000);
  return renameSync(from, to, ...rest);
};
syncBuiltinESMExports();
`);
    const starting = proto.run(["targets"], { env: { NODE_OPTIONS: `--import=${pathToFileURL(hook).href}` } });
    const deadline = Date.now() + 20_000;
    while (!existsSync(join(proto.dir, "host.sock"))) {
      assert.ok(Date.now() < deadline, "the host bound its socket");
      await sleep(20);
    }
    assert.equal(existsSync(join(proto.dir, "token")), false, "the token is not there yet");
    const status = await proto.run(["status"]);
    assert.equal((await starting).status, 0);
    const [host] = hostsOf(proto.dir);
    assert.deepEqual([status.status, status.stderr, status.stdout], [0, "", `proto: host ${host}; no window\n`]);
  });

  test("a host answering another protocol number is named with its fix", async (t) => {
    const proto = protoSession(t);
    mkdirSync(proto.dir, { recursive: true, mode: 0o700 });
    writeFileSync(join(proto.dir, "token"), "stub\n", { mode: 0o600 });
    const stub = createServer((request, response) => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ protocol: 0, pid: null, window: null }));
    });
    await new Promise((resolve) => stub.listen(join(proto.dir, "host.sock"), resolve));
    t.after(() => new Promise((resolve) => stub.close(resolve)));
    for (const args of [["status"], ["open", "http://127.0.0.1:1/"], ["stop"]]) {
      const result = await proto.run(args);
      assert.deepEqual([result.status, result.stderr], [1, "proto: a proto host of older code is running (protocol 0); run `proto stop`, then retry\n"], args.join(" "));
    }
  });

  test("an engine whose browser is missing is unavailable with its reason, and open on it exits 1 with that reason", async (t) => {
    const empty = tempDir("no-browsers");
    const proto = protoSession(t, { env: { PROTO_BROWSERS_PATH: empty } });
    const targets = await proto.run(["targets"]);
    assert.equal(targets.status, 0, targets.stderr);
    for (const engine of engines) {
      assert.match(targets.stdout, new RegExp(`^  ${engine} \\S+: unavailable: ${engine} \\S+ is not installed \\(no ${empty}/[^)]+\\); run \`proto install\`; `, "m"));
    }
    const result = await proto.run(["open", "http://127.0.0.1:1/", "--target", "firefox/phone"]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`^proto: firefox \\S+ is not installed \\(no ${empty}/[^)]+\\); run \`proto install\`\\n$`));
    assert.equal((await proto.run(["status"])).stdout, `proto: host ${await proto.hostPid()}; no window\n`);
  });
});

describe("a project's .proto.json", () => {
  test("its url, sizes and devices are what open and targets take", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    const dir = checkoutWith({ url: `${site.url}other`, sizes: { wide: { width: 1600, height: 1000 }, pixel: { device: "Pixel 7" } }, matrix: { engines: ["chromium"], sizes: ["phone", "wide"] } });
    mkdirSync(join(dir, "sub"));
    const targets = await proto.run(["targets"], { cwd: join(dir, "sub") });
    assert.equal(targets.status, 0, targets.stderr);
    assert.ok(targets.stdout.includes("  wide: 1600x1000@1 (project)\n"), targets.stdout);
    assert.match(targets.stdout, /^  pixel: \d+x\d+@[\d.]+, mobile, touch \(project, the device Pixel 7\)$/m);
    if (!(await proto.engine(t, "chromium"))) return;
    const opened = await proto.run(["open", "--target", "chromium/wide"], { cwd: dir });
    assert.deepEqual([opened.status, opened.stderr], [0, ""]);
    assert.match(opened.stdout, new RegExp(`^proto: chromium \\S+ at wide \\(1600x1000@1\\) on ${site.url}other\\n$`));
    const seen = await metrics(proto);
    assert.deepEqual([seen.innerWidth, seen.innerHeight, seen.url], [1600, 1000, `${site.url}other`]);
    // The size alone keeps the engine; the project's device is its own size.
    const pixel = await proto.run(["open", site.url, "--target", "pixel"], { cwd: dir });
    assert.match(pixel.stdout, /^proto: chromium \S+ at pixel \(\d+x\d+@[\d.]+\) on /);
  });
});

describe("proto install", () => {
  test("runs playwright-core's own installer for the three browsers, never with --with-deps", async (t) => {
    const dir = tempDir("installer");
    const installer = join(dir, "installer.mjs");
    writeFileSync(installer, `import { writeFileSync } from "node:fs";\nwriteFileSync(${JSON.stringify(join(dir, "call.json"))}, JSON.stringify({ args: process.argv.slice(2), browsers: process.env.PLAYWRIGHT_BROWSERS_PATH ?? null }));\nprocess.exit(Number(process.env.INSTALLER_EXIT ?? 0));\n`);
    const browsers = tempDir("browsers");
    const proto = protoSession(t, { env: { PROTO_INSTALLER: installer, PROTO_BROWSERS_PATH: browsers } });
    const installed = await proto.run(["install"]);
    // On Linux, WebKit's library step follows (proto-webkit-libs.test.mjs); with no WebKit here it has nothing to check.
    const libraries = process.platform === "linux" ? "proto: WebKit's libraries resolve; nothing to place\n" : "";
    assert.deepEqual(installed, { status: 0, stdout: `proto: the pinned browsers are installed\n${libraries}`, stderr: "" });
    assert.deepEqual(JSON.parse(readFileSync(join(dir, "call.json"), "utf8")), { args: ["install", "chromium", "firefox", "webkit"], browsers });
    const failed = await proto.run(["install"], { env: { INSTALLER_EXIT: "3" } });
    assert.deepEqual([failed.status, failed.stderr], [1, "proto: playwright-core's installer exited 3\n"]);
    assert.equal((await proto.run(["install", "--with-deps"])).status, 2);
  });
});
