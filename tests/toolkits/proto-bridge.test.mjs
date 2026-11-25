// The bridge (toolkits/frontend/proto/bridge.mjs), the MCP server `proto` of the frontend
// toolkit, started exactly as its .mcp.json declares it, ${CLAUDE_PLUGIN_ROOT} resolved as Claude
// Code resolves it for --plugin-dir, and spoken to over stdio as Daniel's session speaks to it
// (helpers/proto.mjs's bridge, on helpers/mcp.mjs's client), with the host's seams in its
// environment: headless, a runtime directory of each test's own, the test routes on and no
// Agent Chrome. Its working directory is a test git checkout, the session's.
// It checks the declaration beside the unchanged frontend server, the tools/list (the three
// tools, their arguments, descriptions and annotations, and the eval mock's copy of it), a first
// call starting the host, a host that cannot start, set_target opening the window and switching
// it (a resize and each other engine, read back from the page itself), its refusals carrying the
// host's own line, capture_matrix's files in the checkout's .scratch/ui with one line per target
// and no image, a target that fails alone, the refusals outside a checkout and of agent-chrome,
// and the gate on a team session. Every engine the machine has runs; under CI=true a missing
// one fails, elsewhere it skips with its reason.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { describe, test } from "node:test";
import { pathToFileURL } from "node:url";
import { serveFixture } from "./helpers/chrome.mjs";
import { repoRoot, startServer, tempDir } from "./helpers/mcp.mjs";
import { bridgeConfig, browsersWithout, pngSize, protoSession } from "./helpers/proto.mjs";

const toolkit = join(repoRoot, "toolkits", "frontend");
const page = (title) => `<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>${title}</title></head><body><h1>${title}</h1></body></html>`;
const agents = {
  chromium: /Chrome\//,
  firefox: /Firefox\//,
  webkit: /Version\/[\d.]+ Safari\//,
};

// A git checkout of the test's own, the session's working directory.
function checkoutDir() {
  const dir = realpathSync(tempDir("checkout"));
  execFileSync("git", ["init", "-q", dir]);
  return dir;
}

async function site(t) {
  const served = await serveFixture({ "/": page("Fixture home"), "/import": page("Fixture import") });
  t.after(() => served.close());
  return served;
}

describe("the declaration", () => {
  test("the toolkit's .mcp.json declares proto as node ${CLAUDE_PLUGIN_ROOT}/proto/bridge.mjs, beside the frontend server", () => {
    const { mcpServers } = JSON.parse(readFileSync(join(toolkit, ".mcp.json"), "utf8"));
    assert.deepEqual(Object.keys(mcpServers), ["frontend", "proto"]);
    assert.deepEqual(mcpServers.proto, { command: "node", args: ["${CLAUDE_PLUGIN_ROOT}/proto/bridge.mjs"] });
    assert.deepEqual(bridgeConfig(), { command: "node", args: [join(toolkit, "proto", "bridge.mjs")] });
  });
});

describe("the bridge", () => {
  test("lists exactly list_targets, set_target and capture_matrix, as the eval mock holds them, starting no host", async (t) => {
    const proto = protoSession(t);
    const { server } = await proto.bridge({ cwd: checkoutDir() });
    const tools = await server.listTools();
    assert.deepEqual(tools.map((tool) => tool.name), ["list_targets", "set_target", "capture_matrix"]);
    const [list, set, capture] = tools;
    assert.deepEqual(list.inputSchema.properties, {});
    assert.equal(list.annotations.readOnlyHint, true);
    assert.deepEqual(Object.keys(set.inputSchema.properties), ["target", "url"]);
    assert.deepEqual(set.inputSchema.required, ["target"]);
    assert.equal(set.annotations.readOnlyHint, false);
    assert.deepEqual(Object.keys(capture.inputSchema.properties), ["url", "engines", "sizes", "selector", "full_page"]);
    assert.equal(capture.inputSchema.required, undefined);
    assert.equal(capture.annotations.readOnlyHint, false);
    for (const tool of tools) {
      assert.equal(tool.inputSchema.additionalProperties, false, tool.name);
      assert.match(tool.description, /localhost/, `${tool.name} says only localhost is taken`);
    }
    assert.match(list.description, /changes nothing on Daniel's screen/);
    assert.match(set.description, /changes what Daniel sees on their screen/);
    assert.match(capture.description, /Daniel's window and screen are not touched/);
    // The eval mocks answer with the server's own tools/list.
    const mock = JSON.parse(readFileSync(join(toolkit, "evals", "mocks", "proto", "_tools.json"), "utf8")).tools;
    assert.deepEqual(mock, tools, "toolkits/frontend/evals/mocks/proto/_tools.json");
    const frontMatter = readFileSync(join(toolkit, "evals", "mocks", "proto", "_server.md"), "utf8").match(/^tools: \[(.*)\]$/m)[1];
    assert.deepEqual(frontMatter.split(", "), tools.map((tool) => tool.name));
    assert.equal(await proto.hostPid(), null, "listing the tools starts no host");
  });

  test("with no host running, the first call starts one and answers, read-only and as text", async (t) => {
    const proto = protoSession(t);
    const bridge = await proto.bridge({ cwd: checkoutDir() });
    assert.equal(await proto.hostPid(), null);
    const result = await bridge.call("list_targets");
    assert.ok(!result.isError, result.text);
    assert.ok(await proto.hostPid(), "a host answers");
    assert.ok(result.content.every((part) => part.type === "text"));
    assert.match(result.text, /^engines:\n {2}chromium \S+: (available|unavailable: .+); sizeBy=context /);
    assert.match(result.text, /\n {2}agent-chrome \(no version\): unavailable: no Agent Chrome answers on 127\.0\.0\.1:1; /);
    assert.match(result.text, /\nsizes:\n {2}phone-small: 360x800@3, mobile, touch \(preset\)\n/);
    assert.match(result.text, /\n {2}laptop: 1440x900@1 \(preset\)\n/);
    assert.match(result.text, /any of Playwright's \d+ devices by name/);
    const cli = await proto.run(["targets"]);
    assert.equal(cli.stdout, `${result.text}\n`, "the same text as proto targets");
    assert.equal((await proto.request("GET", "/v1/status")).body.window, null, "no window opened");
  });

  test("a host that cannot start answers a tool error naming host.log", async (t) => {
    const refuse = join(tempDir("refuse"), "refuse-host.mjs");
    writeFileSync(refuse, 'if (process.argv[1]?.endsWith("/proto/host.mjs")) { process.stderr.write("proto host: refused by the test\\n"); process.exit(3); }\n');
    const proto = protoSession(t, { env: { NODE_OPTIONS: `--import=${pathToFileURL(refuse).href}` } });
    const bridge = await proto.bridge({ cwd: checkoutDir() });
    const result = await bridge.call("list_targets");
    assert.equal(result.isError, true);
    assert.equal(result.text, `the host exited (code 3) before it answered: refused by the test; see ${join(proto.dir, "host.log")}`);
    assert.equal(await proto.hostPid(), null);
  });

  test("set_target opens the window when none is open, then switches its size and its page, answering its line each time", async (t) => {
    const proto = protoSession(t);
    if (!(await proto.engine(t, "chromium"))) return;
    const served = await site(t);
    const bridge = await proto.bridge({ cwd: checkoutDir() });
    const opened = await bridge.call("set_target", { target: "chromium/phone", url: served.url });
    assert.ok(!opened.isError, opened.text);
    assert.match(opened.text, new RegExp(`^chromium \\S+ at phone \\(390x844@3\\) on ${served.url.replaceAll(".", "\\.")}$`));
    let metrics = await proto.page("metrics");
    assert.deepEqual([metrics.innerWidth, metrics.innerHeight, metrics.devicePixelRatio], [390, 844, 3]);
    const resized = await bridge.call("set_target", { target: "phone-small" });
    assert.ok(!resized.isError, resized.text);
    assert.match(resized.text, /^chromium \S+ at phone-small \(360x800@3\) on http:\/\/127\.0\.0\.1:\d+\/$/);
    metrics = await proto.page("metrics");
    assert.deepEqual([metrics.innerWidth, metrics.innerHeight, metrics.devicePixelRatio], [360, 800, 3]);
    const moved = await bridge.call("set_target", { target: "laptop", url: `${served.url}import` });
    assert.match(moved.text, /^chromium \S+ at laptop \(1440x900@1\) on http:\/\/127\.0\.0\.1:\d+\/import$/);
    assert.equal((await proto.page("metrics")).url, `${served.url}import`);
  });

  for (const engine of ["firefox", "webkit"]) {
    test(`set_target switches the open window to ${engine} on the page it shows`, async (t) => {
      const proto = protoSession(t);
      if (!(await proto.engine(t, "chromium")) || !(await proto.engine(t, engine))) return;
      const served = await site(t);
      const bridge = await proto.bridge({ cwd: checkoutDir() });
      await bridge.call("set_target", { target: "chromium/laptop", url: `${served.url}import` });
      const switched = await bridge.call("set_target", { target: engine });
      assert.ok(!switched.isError, switched.text);
      assert.match(switched.text, new RegExp(`^${engine} \\S+ at laptop \\(1440x900@1\\) on http://127\\.0\\.0\\.1:\\d+/import$`));
      const metrics = await proto.page("metrics");
      assert.match(metrics.userAgent, agents[engine]);
      assert.equal(metrics.innerWidth, 1440);
    });
  }

  test("a bad target or a URL off localhost is a tool error with the host's own line, and opens nothing", async (t) => {
    const proto = protoSession(t);
    const served = await site(t);
    const bridge = await proto.bridge({ cwd: checkoutDir() });
    for (const fields of [{ target: "chromium/huge", url: served.url }, { target: "netscape/phone", url: served.url }, { target: "chromium/phone", url: "http://example.com/" }, { target: "chromium/phone", url: "http://127.0.0.2/" }]) {
      const result = await bridge.call("set_target", fields);
      assert.equal(result.isError, true, JSON.stringify(fields));
      const host = await proto.request("POST", "/v1/open", fields);
      assert.equal(host.status, 400);
      assert.equal(result.text, host.body.error, JSON.stringify(fields));
    }
    assert.equal((await proto.request("GET", "/v1/status")).body.window, null);
    const missing = await bridge.call("set_target", {});
    assert.equal(missing.isError, true);
    assert.match(missing.text, /^set_target refused its input: .*target/);
    if (!(await proto.engine(t, "chromium"))) return;
    await bridge.call("set_target", { target: "chromium/laptop", url: served.url });
    const bad = await bridge.call("set_target", { target: "chromium/huge" });
    assert.equal(bad.isError, true);
    assert.equal(bad.text, (await proto.request("POST", "/v1/target", { target: "chromium/huge" })).body.error);
    assert.equal((await proto.page("metrics")).innerWidth, 1440, "the window is as it was");
  });

  test("capture_matrix writes into the checkout's .scratch/ui and answers each target's absolute path, then the index, with no image", async (t) => {
    const proto = protoSession(t);
    if (!(await proto.engine(t, "chromium"))) return;
    const served = await site(t);
    const checkout = checkoutDir();
    const bridge = await proto.bridge({ cwd: checkout });
    const result = await bridge.call("capture_matrix", { url: served.url, engines: ["chromium"], sizes: ["phone", "laptop"] }, { timeoutMs: 240_000 });
    assert.ok(!result.isError, result.text);
    assert.deepEqual(result.content.map((part) => part.type), ["text"]);
    const lines = result.text.split("\n");
    assert.equal(lines.length, 3, result.text);
    const [dir] = readdirSync(join(checkout, ".scratch", "ui"));
    assert.match(dir, /^matrix-\d{8}-\d{6}$/);
    const out = join(checkout, ".scratch", "ui", dir);
    assert.deepEqual(lines, [`chromium/phone: ${join(out, "chromium-phone.png")}`, `chromium/laptop: ${join(out, "chromium-laptop.png")}`, `index: ${join(out, "matrix.md")}`]);
    assert.deepEqual(pngSize(join(out, "chromium-phone.png")), { width: 1170, height: 2532 });
    assert.deepEqual(pngSize(join(out, "chromium-laptop.png")), { width: 1440, height: 900 });
    assert.ok(existsSync(join(out, "matrix.md")));
    for (const line of lines) assert.ok(isAbsolute(line.slice(line.indexOf(": ") + 2)), line);
  });

  test("capture_matrix: a target that fails is its own line while the others capture, and with none captured it is a tool error", async (t) => {
    const proto = protoSession(t, { env: { PROTO_BROWSERS_PATH: browsersWithout("firefox") } });
    if (!(await proto.engine(t, "chromium"))) return;
    const served = await site(t);
    const checkout = checkoutDir();
    const bridge = await proto.bridge({ cwd: checkout });
    const some = await bridge.call("capture_matrix", { url: served.url, engines: ["chromium", "firefox"], sizes: ["phone"] }, { timeoutMs: 240_000 });
    assert.ok(!some.isError, some.text);
    const [chromium, firefox, index] = some.text.split("\n");
    assert.match(chromium, /^chromium\/phone: \/.+\/chromium-phone\.png$/);
    assert.match(firefox, /^firefox\/phone: unavailable: firefox \S+ is not installed/);
    assert.match(index, /^index: \/.+\/matrix\.md$/);
    // A second capture in the same second would share its directory name.
    await new Promise((resolve) => setTimeout(resolve, 1100));
    const none = await bridge.call("capture_matrix", { url: served.url, engines: ["firefox"], sizes: ["phone"] }, { timeoutMs: 240_000 });
    assert.equal(none.isError, true);
    assert.match(none.text, /^firefox\/phone: unavailable: .+\nindex: \/.+\/matrix\.md$/);
  });

  test("capture_matrix is refused outside a git checkout, and for agent-chrome with the host's line, writing nothing", async (t) => {
    const proto = protoSession(t);
    const plain = realpathSync(tempDir("plain"));
    const outside = await proto.bridge({ cwd: plain });
    const refused = await outside.call("capture_matrix", {});
    assert.equal(refused.isError, true);
    assert.equal(refused.text, `the session's working directory ${plain} is in no git checkout, so capture_matrix has no .scratch/ui to write in; run \`proto capture --out <an absolute directory>\` there instead`);
    assert.deepEqual(readdirSync(plain), []);
    const checkout = checkoutDir();
    const inside = await proto.bridge({ cwd: checkout });
    const chrome = await inside.call("capture_matrix", { url: "http://127.0.0.1:9/", engines: ["agent-chrome"] });
    assert.equal(chrome.isError, true);
    assert.match(chrome.text, /the Agent Chrome is Daniel's window; a capture uses launched engines/);
    assert.ok(!existsSync(join(checkout, ".scratch")), "nothing written");
    const off = await inside.call("capture_matrix", { url: "http://example.com/" });
    assert.equal(off.isError, true);
    assert.match(off.text, /^http:\/\/example\.com\/ is off localhost/);
    assert.ok(!existsSync(join(checkout, ".scratch")), "nothing written");
  });

  for (const role of ["builder", "coordinator"]) {
    test(`refuses to start in a team session (AGENT_TEAM_ROLE=${role}), before any directory is read or made`, async (t) => {
      const proto = protoSession(t);
      const server = startServer(bridgeConfig(), { home: proto.env.HOME, env: proto.env, path: proto.env.PATH, role, cwd: checkoutDir() });
      const { code } = await server.exited;
      assert.equal(code, 1);
      assert.equal(server.stderr, `proto: the prototyping host is Daniel's own sessions'; a team session (AGENT_TEAM_ROLE=${role}) may not drive it\n`);
      assert.equal(server.stdout, "");
      assert.ok(!existsSync(proto.dir), "no runtime directory made");
    });
  }
});
