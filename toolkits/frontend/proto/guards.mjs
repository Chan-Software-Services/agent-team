// The prototyping host's guards, which the CLI, the bridge and the host all hold to: the team
// session gate, the localhost guard on every URL a client gives, and the runtime directory's
// place and modes.
//
//   teamSessionRefusal(env)      the gate's one line when AGENT_TEAM_ROLE is set and not empty, a
//                                team session (a worker or the coordinator), else null
//   refuseTeamSession(env)       writes that line to stderr and exits 1, before anything is read;
//                                each entry point calls it first, and client.mjs's connect too
//   checkLocalUrl(text)          the URL as its href when its scheme is http or https and its host
//                                localhost or 127.0.0.1 (any port), else throws a one-line reason
//   isLocalUrl(text)             whether checkLocalUrl takes it
//   localStorageState(state)     a Playwright storage state with only the cookies and origins of
//                                localhost and 127.0.0.1, what a switch carries to a new window
//   runtimeDir(env)              PROTO_RUNTIME_DIR when set, else $XDG_RUNTIME_DIR/agent-team-proto
//                                when XDG_RUNTIME_DIR is set, else ~/.local/state/agent-team/proto
//   checkRuntimeDir(dir, { create })   makes the directory mode 0700 when `create` and it is
//                                missing; throws a one-line reason naming it when it is not a
//                                directory, is owned by another user, or is open to others (any
//                                group or other mode bit), or when its socket's path would pass
//                                100 bytes (macOS refuses a Unix socket path past 104); answers
//                                whether it exists
//   runtimePaths(dir)            { socket, token, log, lock }: host.sock, token, host.log and
//                                start.lock in the directory
//
// The gate guards these scripts and the client module alone, as ui-capture's does: any local
// process of Daniel's user that reads the token file can still reach the socket without them,
// and team-worker's refusal of the frontend toolkit keeps the bridge out of every worker.
// settings/worker.json also denies a worker's Bash call naming the runtime directory or the
// socket (agent-team-proto, agent-team/proto, host.sock) and its Read in either directory, a
// speed bump that another spelling gets past.
import { lstatSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export function teamSessionRefusal(env = process.env) {
  const role = env.AGENT_TEAM_ROLE;
  if (role === undefined || role === "") return null;
  return `proto: the prototyping host is Daniel's own sessions'; a team session (AGENT_TEAM_ROLE=${role}) may not drive it`;
}

export function refuseTeamSession(env = process.env) {
  const refusal = teamSessionRefusal(env);
  if (refusal === null) return;
  process.stderr.write(`${refusal}\n`);
  process.exit(1);
}

const localHosts = new Set(["localhost", "127.0.0.1"]);

export function checkLocalUrl(text) {
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new Error(`"${text}" is not a URL; proto opens http or https on localhost or 127.0.0.1`);
  }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || !localHosts.has(url.hostname)) {
    throw new Error(`${text} is off localhost; proto opens only http or https on localhost or 127.0.0.1`);
  }
  return url.href;
}

export function isLocalUrl(text) {
  try {
    checkLocalUrl(text);
    return true;
  } catch {
    return false;
  }
}

export function localStorageState(state) {
  return {
    cookies: state.cookies.filter((cookie) => localHosts.has(cookie.domain.replace(/^\./, ""))),
    origins: state.origins.filter((origin) => isLocalUrl(origin.origin)),
  };
}

export function runtimeDir(env = process.env) {
  if (env.PROTO_RUNTIME_DIR) return env.PROTO_RUNTIME_DIR;
  if (env.XDG_RUNTIME_DIR) return join(env.XDG_RUNTIME_DIR, "agent-team-proto");
  return join(env.HOME || homedir(), ".local", "state", "agent-team", "proto");
}

const socketPathLimit = 100;

export const runtimePaths = (dir) => ({
  socket: join(dir, "host.sock"),
  token: join(dir, "token"),
  log: join(dir, "host.log"),
  lock: join(dir, "start.lock"),
});

export function checkRuntimeDir(dir, { create = false } = {}) {
  const socket = runtimePaths(dir).socket;
  if (Buffer.byteLength(socket) > socketPathLimit) {
    throw new Error(`the host's socket path ${socket} is ${Buffer.byteLength(socket)} bytes, past the ${socketPathLimit} a Unix socket takes; set PROTO_RUNTIME_DIR to a shorter directory`);
  }
  let stat;
  try {
    stat = lstatSync(dir);
  } catch (error) {
    if (error.code !== "ENOENT") throw new Error(`the runtime directory ${dir} cannot be read: ${error.code}`);
    if (!create) return false;
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    stat = lstatSync(dir);
  }
  if (!stat.isDirectory()) throw new Error(`the runtime directory ${dir} is not a directory`);
  if (stat.uid !== process.getuid()) throw new Error(`the runtime directory ${dir} is owned by another user (uid ${stat.uid}); remove it or set PROTO_RUNTIME_DIR`);
  const mode = stat.mode & 0o777;
  if (mode & 0o077) {
    throw new Error(`the runtime directory ${dir} is open to others (mode ${mode.toString(8).padStart(4, "0")}); make it 0700 or remove it`);
  }
  return true;
}
