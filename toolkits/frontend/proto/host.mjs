// The prototyping host: one long-lived process per user, started detached by a client (the CLI,
// or the bridge) through client.mjs, which owns the browsers and Daniel's one prototyping window.
//
// Usage: node host.mjs   (no arguments; a client starts it, its output to host.log)
//
// It serves HTTP and JSON on a Unix socket, host.sock in the runtime directory (guards.mjs's
// runtimeDir, mode 0700, refused when open to others), the socket mode 0600, with a token
// minted at each start (32 random bytes as hex, mode 0600) that every request carries as
// "Authorization: Bearer <token>", compared in constant time; a missing or wrong one is answered
// 401 and nothing else. It binds the socket first, so two hosts started at once leave one (the
// other exits 1), then writes the token and only then answers a request.
//
//   GET  /v1/status    { protocol, pid, window: { target, url } or null }
//   GET  /v1/targets   { engines: [{ name, available, reason, version, capabilities }], sizes,
//                      devices, current }: the catalogue for the window's project
//   POST /v1/open      { url?, target?, project? } -> the window's { target, url, engine,
//                      version, width, height, scale, mobile, touch }: opens one when none is
//                      open, else moves the one open to the URL and target as a switch does.
//                      The URL defaults to the project's url, the target to the window's own,
//                      else chromium/laptop; an engine or a size alone keeps the other.
//                      `project` is the client's reading of .proto.json, { file, settings },
//                      checked again here and kept for the window.
//   POST /v1/target    { target, url? } -> the window's answer, as open's, after the switch:
//                      the URL defaults to the page's own now, wherever it navigated; refused
//                      400 with no window open ("run `proto open`") and 409 while another open
//                      or switch is queued or running ("a switch is already running").
//                      A switch, by open or target:
//                      - another engine: the window's storage state, localhost's cookies and
//                        origins alone, is read, the new engine opened at the URL with it, and
//                        once its page has loaded the old browser is closed;
//                      - the same engine at another scale, mobile or touch flag or user agent,
//                        or at another URL: a fresh context in the same browser, carrying the
//                        storage state the same way, and then the old context is closed;
//                      - the same engine and URL at another width and height alone: the
//                        viewport resized in place, the page not loaded again.
//                      When the new window fails (an engine unavailable, a launch or a load
//                      failing), what it opened is closed and the old window stays as it was.
//   POST /v1/stop      { stopped: true }, then it closes its windows, removes the socket and the
//                      token, and exits 0; SIGTERM, SIGINT and SIGHUP do the same
//   POST /v1/test/page { action, url? } (PROTO_TEST_SEAM=1 only; 404 without it):
//                      "metrics" -> the window page's innerWidth, innerHeight, devicePixelRatio,
//                      userAgent, cookie and url; "navigate" with `url` -> follows a link there
//                      as a user would (launched.mjs's follow), then the metrics and `status`,
//                      the host's status line ("Blocked <url>: off localhost", which the next
//                      main-frame navigation clears) or null; "close-browser" -> closes the
//                      window's browser as Daniel quits it, then { closed: true }
// A window whose page or browser Daniel closes is dropped (status's window null, "no window")
// while the host runs on; `proto open` opens a new one.
// An error answers { error: "<one line>" }: 400 a bad body, target or URL (one off localhost is
// refused before anything opens), 401, 404, 503 an engine unavailable or failing to start or
// load, with its reason; 409 a switch while another runs. Window operations run one at a time,
// in the order they came.
// `protocol` is 1; a client refuses a host that answers another.
//
// It refuses to run in a team session (AGENT_TEAM_ROLE set), before anything is read.
// Seams, read only from the environment:
//   PROTO_HEADLESS=1        launch the window headless
//   PROTO_RUNTIME_DIR       the runtime directory (guards.mjs)
//   PROTO_BROWSERS_PATH     Playwright's browsers path, passed on as PLAYWRIGHT_BROWSERS_PATH,
//                           so a test points an engine at an empty directory
//   PROTO_LDD               the program WebKit's library check runs in place of ldd
//                           (webkit-libs.mjs), so a test names a soname missing
//   PROTO_TEST_SEAM=1       serve POST /v1/test/page
import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { catalogue, checkProject, defaultTarget, launchedEngines, readProject, resolveTarget, targetText } from "./catalogue.mjs";
import { protocol } from "./client.mjs";
import { checkLocalUrl, checkRuntimeDir, refuseTeamSession, runtimeDir, runtimePaths } from "./guards.mjs";
import { firstLine, launchedDriver } from "./launched.mjs";

refuseTeamSession();

const env = process.env;
if (env.PROTO_BROWSERS_PATH) env.PLAYWRIGHT_BROWSERS_PATH = env.PROTO_BROWSERS_PATH;

const fail = (reason) => {
  process.stderr.write(`proto host: ${reason}\n`);
  process.exit(1);
};

const dir = runtimeDir(env);
try {
  checkRuntimeDir(dir, { create: true });
} catch (error) {
  fail(error.message);
}
const paths = runtimePaths(dir);

const headless = env.PROTO_HEADLESS === "1";
const drivers = new Map(launchedEngines.map((name) => [name, launchedDriver(name, { headless })]));
// The Agent Chrome's driver is agent-chrome.mjs's; until it is in, the target says so.
const agentChrome = {
  name: "agent-chrome",
  capabilities: { sizeBy: "emulation", overlayBeforePageScripts: true, matchedRules: "cdp", navigationGuard: false },
  version: () => null,
  available: () => ({ available: false, reason: "the agent-chrome target is not in this build of the host" }),
};
drivers.set("agent-chrome", agentChrome);

class Refusal extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// The window: { driver, handle, target, project }, or null. A switch changes its target and
// project in place, or puts a new one here.
let current = null;
const defaultProject = readProject(null);
let stopping = false;
// The open and target operations queued or running, and the status line the toolbar shows.
let switching = 0;
let statusLine = null;

// One window operation at a time, in the order they came.
let queue = Promise.resolve();
const queued = (operation) => {
  const run = queue.then(operation);
  queue = run.catch(() => {});
  return run;
};

const windowAnswer = (window) => ({
  target: targetText(window.target),
  url: window.handle.url(),
  engine: window.target.engine,
  size: window.target.size,
  version: window.driver.version(),
  width: window.target.width,
  height: window.target.height,
  scale: window.target.scale,
  mobile: window.target.mobile,
  touch: window.target.touch,
});

function engineState(driver) {
  const { available, reason = null } = driver.available();
  return { name: driver.name, available, reason, version: driver.version(), capabilities: driver.capabilities };
}

function checkBody(body, fields) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) throw new Refusal(400, "the body must be a JSON object");
  for (const key of Object.keys(body)) if (!fields.includes(key)) throw new Refusal(400, `unknown field "${key}"; this route takes ${fields.join(", ") || "none"}`);
}

function readRequestProject(project) {
  if (project === undefined) return current?.project ?? defaultProject;
  if (project === null || typeof project !== "object" || typeof project.settings !== "object") {
    throw new Refusal(400, "project must be { file, settings }, the client's reading of .proto.json");
  }
  try {
    return { ...checkProject(project.settings, project.file ?? "the open request's project"), file: project.file ?? null, settings: project.settings };
  } catch (error) {
    throw new Refusal(400, error.message);
  }
}

// The hooks of a window record not yet made: each acts only while it is the host's window.
function windowHooks() {
  const record = {};
  const mine = () => current !== null && current === record;
  record.hooks = {
    onGone: () => {
      if (!mine()) return;
      current = null;
      statusLine = null;
    },
    onBlocked: (url) => {
      if (mine()) statusLine = `Blocked ${url}: off localhost`;
    },
    onNavigated: () => {
      if (mine()) statusLine = null;
    },
  };
  return record;
}

const sameContext = (a, b) => a.scale === b.scale && a.mobile === b.mobile && a.touch === b.touch && (a.userAgent ?? null) === (b.userAgent ?? null);

// Opens the window, or moves the one open to `url` and `target` (the header's "A switch"); in the
// queue, so `current` holds still.
async function place(url, target, project) {
  const old = current;
  const driver = drivers.get(target.engine);
  const sameEngine = old !== null && old.target.engine === target.engine;
  if (sameEngine && sameContext(old.target, target) && url === old.handle.url()) {
    if (old.target.width !== target.width || old.target.height !== target.height) await old.handle.resize(target);
    old.target = target;
    old.project = project;
    return windowAnswer(old);
  }
  if (!sameEngine) {
    const state = driver.available();
    if (!state.available) throw new Refusal(503, state.reason);
  }
  const record = windowHooks();
  try {
    const storage = old ? await old.handle.storageState() : undefined;
    record.handle = sameEngine ? await old.handle.reopen(url, target, storage, record.hooks) : await driver.open(url, target, storage, record.hooks);
  } catch (error) {
    throw new Refusal(503, `${target.engine} could not open ${url}: ${firstLine(error)}`);
  }
  Object.assign(record, { driver, target, project });
  current = record;
  statusLine = null;
  if (old) await old.handle.close().catch(() => {});
  return windowAnswer(record);
}

// A window operation that switches: queued, and counted while it waits and runs.
const switched = (operation) => {
  switching++;
  return queued(operation).finally(() => switching--);
};

async function open(body) {
  checkBody(body, ["url", "target", "project"]);
  const project = readRequestProject(body.project);
  let url;
  try {
    url = checkLocalUrl(body.url ?? project.url);
  } catch (error) {
    throw new Refusal(400, error.message);
  }
  const base = current ? targetText(current.target) : defaultTarget;
  let target;
  try {
    target = resolveTarget(body.target ?? base, project, base);
  } catch (error) {
    throw new Refusal(400, error.message);
  }
  return switched(() => place(url, target, project));
}

const noWindow = "no window is open; run `proto open`";

async function switchTarget(body) {
  checkBody(body, ["target", "url"]);
  if (switching > 0) throw new Refusal(409, "a switch is already running");
  if (!current) throw new Refusal(400, noWindow);
  let url;
  let target;
  try {
    if (body.url !== undefined) url = checkLocalUrl(body.url);
    target = resolveTarget(body.target, current.project, targetText(current.target));
  } catch (error) {
    throw new Refusal(400, error.message);
  }
  return switched(async () => {
    if (!current) throw new Refusal(400, noWindow);
    let here = url;
    if (here === undefined) {
      try {
        here = checkLocalUrl(current.handle.url());
      } catch (error) {
        throw new Refusal(400, `the window's page is not one proto opens: ${error.message}`);
      }
    }
    return place(here, target, current.project);
  });
}

const testActions = ["metrics", "navigate", "close-browser"];

async function testPage(body) {
  checkBody(body, ["action", "url"]);
  if (!testActions.includes(body.action)) throw new Refusal(400, `unknown action ${JSON.stringify(body.action)}; the actions are ${testActions.join(", ")}`);
  if (!current) throw new Refusal(400, noWindow);
  const window = current;
  if (body.action === "metrics") return window.handle.metrics();
  if (body.action === "close-browser") {
    await window.handle.closeBrowser();
    return { closed: true };
  }
  if (typeof body.url !== "string" || !URL.canParse(body.url)) throw new Refusal(400, "navigate takes url, the link's address");
  await window.handle.follow(body.url);
  return { ...(await window.handle.metrics()), status: statusLine };
}

async function stop() {
  if (stopping) return;
  stopping = true;
  // The queue first, so an open under way ends before its window is closed.
  await queue;
  if (current) await current.handle.close().catch(() => {});
  current = null;
  server.close();
  rmSync(paths.socket, { force: true });
  rmSync(paths.token, { force: true });
  process.exit(0);
}

const routes = {
  "GET /v1/status": async () => ({ protocol, pid: process.pid, window: current ? { target: targetText(current.target), url: current.handle.url() } : null }),
  "GET /v1/targets": async () => {
    const project = current?.project ?? defaultProject;
    const listing = catalogue(project);
    return { ...listing, engines: listing.engines.map((name) => engineState(drivers.get(name))), current: current ? targetText(current.target) : null };
  },
  "POST /v1/open": open,
  "POST /v1/target": switchTarget,
  "POST /v1/stop": async () => {
    setImmediate(stop);
    return { stopped: true };
  },
  ...(env.PROTO_TEST_SEAM === "1" ? { "POST /v1/test/page": testPage } : {}),
};

const token = randomBytes(32).toString("hex");
const tokenBytes = Buffer.from(`Bearer ${token}`);
const authorised = (header) => {
  const given = Buffer.from(header ?? "");
  return given.length === tokenBytes.length && timingSafeEqual(given, tokenBytes);
};

let ready;
const whenReady = new Promise((resolve) => (ready = resolve));

const answer = (response, status, value) => {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(`${JSON.stringify(value)}\n`);
};

const bodyLimit = 1 << 20;
function readBody(request) {
  return new Promise((resolve, reject) => {
    let text = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      text += chunk;
      if (text.length > bodyLimit) reject(new Refusal(400, "the body is over 1 MiB"));
    });
    request.on("end", () => {
      if (text === "") return resolve({});
      try {
        resolve(JSON.parse(text));
      } catch {
        reject(new Refusal(400, "the body is not JSON"));
      }
    });
    request.on("error", reject);
  });
}

const server = createServer(async (request, response) => {
  await whenReady;
  if (!authorised(request.headers.authorization)) return answer(response, 401, { error: "unauthorised" });
  const route = routes[`${request.method} ${new URL(request.url, "http://host").pathname}`];
  if (!route) return answer(response, 404, { error: `no route ${request.method} ${request.url}` });
  if (stopping) return answer(response, 503, { error: "the host is stopping" });
  try {
    const body = request.method === "POST" ? await readBody(request) : {};
    answer(response, 200, await route(body));
  } catch (error) {
    if (error instanceof Refusal) return answer(response, error.status, { error: error.message });
    process.stderr.write(`proto host: ${request.method} ${request.url}: ${error.stack}\n`);
    answer(response, 500, { error: firstLine(error) });
  }
});

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") fail(`another host holds ${paths.socket}`);
  fail(`${paths.socket}: ${error.message}`);
});

const previousMask = process.umask(0o177);
server.listen(paths.socket, () => {
  process.umask(previousMask);
  chmodSync(paths.socket, 0o600);
  const staged = `${paths.token}.${process.pid}`;
  writeFileSync(staged, `${token}\n`, { mode: 0o600 });
  renameSync(staged, paths.token);
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(signal, stop);
  process.stdout.write(`proto host: ${process.pid} on ${paths.socket}\n`);
  ready();
});
