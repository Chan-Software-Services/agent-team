// The prototyping host in a test, started and ended through its CLI (toolkits/frontend/scripts/
// proto) exactly as Daniel does, with the seams set, so nothing reaches Daniel's own host.
//
//   const proto = protoSession(t, { env })
//                         a runtime directory of the test's own (PROTO_RUNTIME_DIR), the window
//                         headless (PROTO_HEADLESS=1) and the test routes on (PROTO_TEST_SEAM=1),
//                         a temporary directory of the test's own (TMPDIR), the Agent Chrome at
//                         an address nothing answers on (PROTO_AGENT_CHROME_URL, port 1 of
//                         127.0.0.1, so no test reaches Daniel's on 9222; a test of the target
//                         names its throwaway Chrome's in `env`), the environment without a team
//                         session's role, plus `env`; when `t`
//                         ends, `proto stop`, then every host the session saw is ended by
//                         ownedPid (helpers/process.mjs), with the browsers below it
//   proto.dir, proto.env  that runtime directory, and the CLI's environment
//   await proto.run(args, { cwd, env })   the CLI's { status, stdout, stderr }, the CLI process
//                         handed to owned; after it, a host that answers is handed to ownedPid
//   await proto.request(method, path, body, { token })
//                         one request over the host's socket: { status, body }, with the token
//                         the host wrote unless `token` names another (null for none)
//   proto.hostPid()       the pid of the host that answers, or null
//   await proto.engines()  the launched engines as the host reports them, starting it (`proto
//                         targets`): each { name, available, reason, version, capabilities }
//   await proto.engine(t, name)
//                         true when the host reports the engine available; else, under CI=true,
//                         fails the test with the reason, and elsewhere skips it with the reason
//   await proto.available(t, least)
//                         the names of the launched engines the host reports available when
//                         there are at least `least`; else null, the test failed under CI=true
//                         and skipped elsewhere, as engine() does
//   await proto.page(action, fields)   POST /v1/test/page's answer body for `action` ("metrics",
//                         "navigate" with `url`, "close-browser", "popup" with `url`, "send" with
//                         `message`), failing the test unless 200
//   await proto.toolbar(action, fields)   POST /v1/test/toolbar's answer body for `action`
//                         ("select" or "fill" with `name` and `value`, "click" with `name`,
//                         "read"), failing the test unless 200
//   await proto.toolbarUntil(check, why)   the toolbar's "read" again every 50 ms until
//                         check(read) is true, and that read; an answer that is not 200 (the page
//                         between documents in a switch) is read again; fails the test, naming
//                         `why` and the last answer, after 20 s
//   const bridge = await proto.bridge({ cwd, env })
//                         the bridge, the MCP server `proto`, started exactly as the toolkit's
//                         .mcp.json declares it (bridgeConfig()) in `cwd` (a session's checkout),
//                         with the session's environment plus `env`, initialized; the server
//                         process is handed to owned, and closed when `t` ends.
//                         bridge.call(name, args, { timeoutMs }) is its tools/call result with
//                         its text joined as `text` (helpers/mcp.mjs's callTool), after which a
//                         host that answers is handed to ownedPid; bridge.server is the
//                         connection (listTools, stderr, exited)
//   await runScript(t, command, args, { cwd, env, timeoutMs })
//                         runs `command` with `args`, handed to owned, killed after `timeoutMs`
//                         (180 s by default): its { status, stdout, stderr }, status the exit
//                         code or the signal that ended it
//   bridgeConfig()        the `proto` entry of toolkits/frontend/.mcp.json, ${CLAUDE_PLUGIN_ROOT}
//                         resolved to the toolkit as Claude Code resolves it for --plugin-dir
//   pngSize(file)         a PNG's { width, height }, from its header
//   pngPixel(file, x, y)  the [red, green, blue] of one pixel of a PNG of 8-bit RGB or RGBA, as
//                         Playwright writes one, its image data inflated and unfiltered
//   browsersWithout(name) a browsers directory for PROTO_BROWSERS_PATH holding a link to every
//                         entry of Playwright's browsers path (PROTO_BROWSERS_PATH when the test
//                         runs with one, else PLAYWRIGHT_BROWSERS_PATH, else Playwright's default
//                         cache) but engine `name`'s, so that one engine is unavailable while the
//                         others run
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, readFileSync, readdirSync, symlinkSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { inflateSync } from "node:zlib";
import { repoRoot, startServer, tempDir } from "./mcp.mjs";
import { owned, ownedPid } from "./process.mjs";

export const protoCli = join(repoRoot, "toolkits", "frontend", "scripts", "proto");
const toolkit = join(repoRoot, "toolkits", "frontend");

export function bridgeConfig() {
  const text = readFileSync(join(toolkit, ".mcp.json"), "utf8");
  return JSON.parse(text.replaceAll("${CLAUDE_PLUGIN_ROOT}", toolkit)).mcpServers.proto;
}

// The environment with no team session's role in it, as a builder running these tests has one,
// which the CLI and the host would refuse.
export function cleanEnvironment(extra = {}) {
  const { AGENT_TEAM_ROLE: _role, AGENT_TEAM_TASK: _task, ...rest } = process.env;
  return { ...rest, ...extra };
}

export function runScript(t, command, args, { cwd, env, timeoutMs = 180_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = owned(t, spawn(command, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] }));
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => (stdout += chunk));
    child.stderr.setEncoding("utf8").on("data", (chunk) => (stderr += chunk));
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.on("error", reject);
    child.on("close", (status, signal) => {
      clearTimeout(timer);
      resolve({ status: status ?? signal, stdout, stderr });
    });
  });
}

// An address no Agent Chrome answers on: nothing listens on port 1, so a connection is refused.
export const noAgentChrome = "http://127.0.0.1:1";

// The one rule for an engine the machine lacks: in CI every engine runs, so the test fails;
// elsewhere it is skipped, with the reason.
function lacking(test, reason) {
  if (process.env.CI === "true") assert.fail(`in CI every engine runs, but ${reason}`);
  test.skip(reason);
}

export function protoSession(t, { env = {} } = {}) {
  const dir = join(tempDir("proto"), "rt");
  // TMPDIR too, where Playwright makes each browser's throwaway profile, which a browser that
  // outlives a killed host leaves behind.
  const sessionEnv = cleanEnvironment({ PROTO_RUNTIME_DIR: dir, PROTO_HEADLESS: "1", PROTO_TEST_SEAM: "1", TMPDIR: tempDir("proto-tmp"), PROTO_AGENT_CHROME_URL: noAgentChrome, ...env });
  const seen = new Set();
  const paths = { socket: join(dir, "host.sock"), token: join(dir, "token") };

  const request = (method, path, body, { token } = {}) => new Promise((resolve, reject) => {
    const bearer = token === undefined ? readFileSync(paths.token, "utf8").trim() : token;
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const outgoing = httpRequest({
      socketPath: paths.socket,
      method,
      path,
      headers: { ...(bearer === null ? {} : { authorization: `Bearer ${bearer}` }), ...(payload ? { "content-type": "application/json" } : {}) },
    }, (response) => {
      let text = "";
      response.setEncoding("utf8").on("data", (chunk) => (text += chunk));
      response.on("end", () => resolve({ status: response.statusCode, body: text ? JSON.parse(text) : null }));
    });
    outgoing.on("error", reject);
    outgoing.end(payload);
  });

  const hostPid = async () => {
    if (!existsSync(paths.socket) || !existsSync(paths.token)) return null;
    try {
      const answer = await request("GET", "/v1/status");
      // A host of another protocol, such as a test's stub, is not this one's to end.
      return answer.status === 200 && answer.body.protocol === 1 ? answer.body.pid : null;
    } catch {
      return null;
    }
  };

  const adopt = async () => {
    const pid = await hostPid();
    if (pid !== null && !seen.has(pid)) {
      seen.add(pid);
      ownedPid(t, pid);
    }
  };

  // Registered before any ownedPid, so it runs first: the host ends as Daniel ends it.
  t.after(async () => {
    if (await hostPid()) await runScript(t, process.execPath, [protoCli, "stop"], { env: sessionEnv, timeoutMs: 60_000 });
  });

  return {
    dir,
    env: sessionEnv,
    request,
    hostPid,
    async run(args, { cwd, env: extra = {} } = {}) {
      const result = await runScript(t, process.execPath, [protoCli, ...args], { cwd, env: { ...sessionEnv, ...extra } });
      await adopt();
      return result;
    },
    async bridge({ cwd, env: extra = {} } = {}) {
      const server = startServer(bridgeConfig(), { home: sessionEnv.HOME, env: { ...sessionEnv, ...extra }, path: sessionEnv.PATH, role: null, cwd });
      owned(t, server.child);
      t.after(() => server.close());
      await server.initialize();
      return {
        server,
        async call(name, args = {}, options = {}) {
          const result = await server.callTool(name, args, { timeoutMs: 120_000, ...options });
          await adopt();
          return result;
        },
      };
    },
    async engines() {
      const started = await this.run(["targets"]);
      assert.equal(started.status, 0, started.stderr);
      const { body } = await request("GET", "/v1/targets");
      return body.engines.filter((engine) => engine.name !== "agent-chrome");
    },
    async page(action, fields = {}) {
      const answer = await request("POST", "/v1/test/page", { action, ...fields });
      assert.equal(answer.status, 200, `${action}: ${JSON.stringify(answer.body)}`);
      return answer.body;
    },
    async toolbar(action, fields = {}) {
      const answer = await request("POST", "/v1/test/toolbar", { action, ...fields });
      assert.equal(answer.status, 200, `${action}: ${JSON.stringify(answer.body)}`);
      return answer.body;
    },
    async toolbarUntil(check, why, { timeoutMs = 20_000 } = {}) {
      let last;
      for (const started = Date.now(); Date.now() - started < timeoutMs; await sleep(50)) {
        last = await request("POST", "/v1/test/toolbar", { action: "read" });
        if (last.status === 200 && check(last.body)) return last.body;
      }
      return assert.fail(`${why}: the toolbar never got there; last read ${JSON.stringify(last)}`);
    },
    async engine(test, name) {
      const engine = (await this.engines()).find((each) => each.name === name);
      if (engine.available) return true;
      lacking(test, `${name} is unavailable: ${engine.reason}`);
      return false;
    },
    async available(test, least) {
      const names = (await this.engines()).filter((engine) => engine.available).map((engine) => engine.name);
      if (names.length >= least) return names;
      lacking(test, `${least} engines are needed, and only ${names.join(", ") || "none"} runs`);
      return null;
    },
  };
}

export function pngSize(file) {
  const bytes = readFileSync(file);
  assert.equal(bytes.subarray(1, 4).toString("latin1"), "PNG", `${file} is not a PNG`);
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}

// The paeth predictor of PNG's filter type 4.
const paeth = (a, b, c) => {
  const p = a + b - c;
  const [pa, pb, pc] = [Math.abs(p - a), Math.abs(p - b), Math.abs(p - c)];
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
};

export function pngPixel(file, x, y) {
  const bytes = readFileSync(file);
  const { width, height } = pngSize(file);
  const [depth, type, interlace] = [bytes[24], bytes[25], bytes[28]];
  assert.ok(depth === 8 && (type === 2 || type === 6) && interlace === 0, `${file}: only 8-bit RGB or RGBA, not interlaced, is read (depth ${depth}, type ${type}, interlace ${interlace})`);
  assert.ok(x >= 0 && x < width && y >= 0 && y < height, `${file}: (${x}, ${y}) is outside its ${width}x${height}`);
  const chunks = [];
  for (let at = 8; at < bytes.length;) {
    const length = bytes.readUInt32BE(at);
    const kind = bytes.subarray(at + 4, at + 8).toString("latin1");
    if (kind === "IDAT") chunks.push(bytes.subarray(at + 8, at + 8 + length));
    if (kind === "IEND") break;
    at += 12 + length;
  }
  const data = inflateSync(Buffer.concat(chunks));
  const channels = type === 6 ? 4 : 3;
  const stride = width * channels;
  let previous = Buffer.alloc(stride);
  let row;
  for (let line = 0; line <= y; line++) {
    const filter = data[line * (stride + 1)];
    row = Buffer.from(data.subarray(line * (stride + 1) + 1, (line + 1) * (stride + 1)));
    for (let i = 0; i < stride; i++) {
      const left = i >= channels ? row[i - channels] : 0;
      const up = previous[i];
      const corner = i >= channels ? previous[i - channels] : 0;
      const add = [0, left, up, (left + up) >> 1, paeth(left, up, corner)][filter];
      row[i] = (row[i] + add) & 0xff;
    }
    previous = row;
  }
  return [...row.subarray(x * channels, x * channels + 3)];
}

// Playwright's browsers path, as playwright-core's registry finds it.
function browsersPath() {
  if (process.env.PROTO_BROWSERS_PATH) return process.env.PROTO_BROWSERS_PATH;
  if (process.env.PLAYWRIGHT_BROWSERS_PATH) return process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (process.platform === "darwin") return join(homedir(), "Library", "Caches", "ms-playwright");
  return join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "ms-playwright");
}

export function browsersWithout(name) {
  const dir = tempDir(`browsers-without-${name}`);
  const from = browsersPath();
  for (const entry of existsSync(from) ? readdirSync(from) : []) {
    if (!entry.startsWith(`${name}-`)) symlinkSync(join(from, entry), join(dir, entry));
  }
  return dir;
}
