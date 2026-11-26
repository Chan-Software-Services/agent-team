// The client: the one way the CLI and the bridge reach the prototyping host, over its Unix
// socket in the runtime directory (guards.mjs).
//
//   protocol                      1, the host API's number, which each connection checks
//   const host = await connect({ start, env })
//                                 first, in a team session (AGENT_TEAM_ROLE set in the process's
//                                 own environment), the gate's line on stderr and exit 1;
//                                 then the running host, or null when none runs and `start` is false;
//                                 with `start`, a host it starts when none answers: it takes
//                                 the start lock (start.lock, a directory made atomically; one
//                                 older than 30 s is taken over as a crashed start's), checks
//                                 again, removes a stale socket, spawns `node host.mjs` detached
//                                 with `env` and its output to host.log (truncated), waits up to
//                                 20 s for it to answer, and releases the lock; a client that
//                                 finds the lock held waits up to 25 s for the host to answer.
//                                 Throws a one-line reason: a host on another protocol ("a proto
//                                 host of older code is running (protocol <n>); run `proto
//                                 stop`, then retry"), a refused token, a host that never
//                                 answered (naming host.log), or a runtime directory refused
//   host.pid, host.status         the host's pid, and its first /v1/status answer
//   await host.request(method, path, body, { timeoutMs })
//                                 one request, 30 s by default; resolves the answer's JSON, and
//                                 throws its `error` line (error.status the HTTP status)
//   await host.stopped(ms)        resolves once the host's process is gone, false after `ms`
//   checkout(cwd)                 the root of the git checkout holding `cwd` (the process's own
//                                 when left out), where a client reads .proto.json and puts a
//                                 capture's .scratch/ui, or null outside one
import { execFileSync, spawn } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { dirname, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { checkRuntimeDir, refuseTeamSession, runtimeDir, runtimePaths } from "./guards.mjs";

export const protocol = 1;
const hostScript = join(dirname(fileURLToPath(import.meta.url)), "host.mjs");
const startWaitMs = 20_000;
const heldWaitMs = 25_000;
const staleLockMs = 30_000;
const pollMs = 100;

class HostError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

const readToken = (paths) => {
  try {
    return readFileSync(paths.token, "utf8").trim();
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    return "";
  }
};

// One request over the socket. Rejects with error.code ENOENT or ECONNREFUSED when no host
// listens there, and a HostError carrying the status for an answer with `error`. A host holds a
// request until it has written its token, so one sent with the token read a moment before (none,
// or a gone host's) is refused 401 with another token in the file by then: it is sent again
// with that one, and a 401 on the file's own token is the refusal.
async function send(paths, method, path, body, options) {
  for (;;) {
    const token = readToken(paths);
    try {
      return await sendOnce(paths, token, method, path, body, options);
    } catch (error) {
      if (error.status !== 401 || readToken(paths) === token) throw error;
    }
  }
}

function sendOnce(paths, token, method, path, body, { timeoutMs = 30_000 } = {}) {
  const payload = body === undefined ? undefined : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const request = httpRequest({
      socketPath: paths.socket,
      method,
      path,
      headers: {
        authorization: `Bearer ${token}`,
        ...(payload === undefined ? {} : { "content-type": "application/json", "content-length": Buffer.byteLength(payload) }),
      },
      timeout: timeoutMs,
    }, (response) => {
      let text = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => (text += chunk));
      response.on("end", () => {
        let value;
        try {
          value = JSON.parse(text);
        } catch {
          return reject(new HostError(`the host answered ${response.statusCode} with no JSON`, response.statusCode));
        }
        if (response.statusCode === 200) return resolve(value);
        if (response.statusCode === 401) return reject(new HostError(`the host on ${paths.socket} refused the token in ${paths.token}; run \`proto stop\`, or end that host`, 401));
        reject(new HostError(value?.error ?? `the host answered ${response.statusCode}`, response.statusCode));
      });
    });
    request.on("timeout", () => request.destroy(new HostError(`the host did not answer ${method} ${path} in ${Math.round(timeoutMs / 1000)} s`)));
    request.on("error", reject);
    request.end(payload);
  });
}

const notListening = (error) => error.code === "ENOENT" || error.code === "ECONNREFUSED";

// The host's status, or null when none listens; throws for one on another protocol.
async function probe(paths) {
  let status;
  try {
    status = await send(paths, "GET", "/v1/status", undefined, { timeoutMs: 5_000 });
  } catch (error) {
    if (notListening(error)) return null;
    throw error;
  }
  if (status.protocol !== protocol) {
    throw new HostError(`a proto host of older code is running (protocol ${status.protocol}); run \`proto stop\`, then retry`);
  }
  return status;
}

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
};

function handle(paths, status) {
  return {
    pid: status.pid,
    status,
    request: (method, path, body, options) => send(paths, method, path, body, options),
    async stopped(ms) {
      const deadline = Date.now() + ms;
      while (alive(status.pid)) {
        if (Date.now() > deadline) return false;
        await sleep(pollMs);
      }
      return true;
    },
  };
}

export async function connect({ start = false, env = process.env } = {}) {
  // The gate reads the process's own environment, never `env`, which a caller may have emptied.
  refuseTeamSession(process.env);
  const dir = runtimeDir(env);
  if (!checkRuntimeDir(dir, { create: start })) return null;
  const paths = runtimePaths(dir);
  const status = await probe(paths);
  if (status) return handle(paths, status);
  if (!start) return null;
  return handle(paths, await startHost(paths, env));
}

// Polls until the host answers, `until` passes or `gaveUp()` names a reason to stop. A refused
// token while a host starts is asked again.
async function answering(paths, until, gaveUp = () => null) {
  for (;;) {
    try {
      const status = await probe(paths);
      if (status) return status;
    } catch (error) {
      if (error.status !== 401) throw error;
    }
    const reason = gaveUp();
    if (reason) throw new HostError(reason);
    if (Date.now() > until) return null;
    await sleep(pollMs);
  }
}

// The start lock, or null once a host answers while another client holds it.
async function takeLock(paths) {
  const until = Date.now() + heldWaitMs;
  for (;;) {
    try {
      mkdirSync(paths.lock, { mode: 0o700 });
      return true;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
    let age;
    try {
      age = Date.now() - statSync(paths.lock).mtimeMs;
    } catch {
      continue; // Released while we looked.
    }
    if (age > staleLockMs) {
      // Taken over by a rename, which only one of several clients wins.
      const taken = `${paths.lock}.stale.${process.pid}`;
      try {
        renameSync(paths.lock, taken);
        rmSync(taken, { recursive: true, force: true });
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
      continue;
    }
    const status = await answering(paths, Math.min(until, Date.now() + pollMs));
    if (status) return status;
    if (Date.now() > until) throw new HostError(`another proto start holds ${paths.lock} and no host answered in ${heldWaitMs / 1000} s; see ${paths.log}`);
  }
}

async function startHost(paths, env) {
  const held = await takeLock(paths);
  if (held !== true) return held;
  try {
    const running = await probe(paths);
    if (running) return running;
    if (existsSync(paths.socket)) rmSync(paths.socket, { force: true });
    const log = openSync(paths.log, "w", 0o600);
    let exit = null;
    try {
      const child = spawn(process.execPath, [hostScript], { detached: true, stdio: ["ignore", log, log], env });
      child.on("exit", (code, signal) => (exit = signal ?? `code ${code}`));
      child.unref();
    } finally {
      closeSync(log);
    }
    const status = await answering(paths, Date.now() + startWaitMs, () => {
      if (exit === null) return null;
      const last = readFileSync(paths.log, "utf8").trim().split("\n").at(-1);
      return `the host exited (${exit}) before it answered${last ? `: ${last.replace(/^proto host: /, "")}` : ""}; see ${paths.log}`;
    });
    if (!status) throw new HostError(`the host did not answer in ${startWaitMs / 1000} s; see ${paths.log}`);
    return status;
  } finally {
    rmSync(paths.lock, { recursive: true, force: true });
  }
}

export function checkout(cwd = process.cwd()) {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim() || null;
  } catch {
    return null;
  }
}
