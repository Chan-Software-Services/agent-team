// What a running process holds, read on Linux and macOS: the environment and the sockets from
// /proc on Linux, and through ps and lsof on macOS, which has no /proc; the children through ps
// on both. And the end of what a test started, so a failed or timed-out test leaves nothing
// running that holds node --test open.
//
//   startingEnvironment(pid)   the environment the process started with (Linux: its
//                              /proc/<pid>/environ; macOS: what `ps -E` appends to its command)
//   children(pid)              the pids of the process's children (`ps -A`, on both systems)
//   descendants(pids)          the pids of every live process below any of `pids`: their
//                              children, their children's, and on, from one `ps -A`
//   owned(t, child)            `child`, a spawned ChildProcess, which endTree ends when test `t`
//                              ends, passed, failed or timed out (node:test runs `t.after` on each)
//   await endTree(child, { graceMs })
//                              ends `child` and every process below it: reads its tree first,
//                              since a process whose parent ends is no longer below it; sends the
//                              child SIGTERM and waits up to `graceMs` (5 s) for it to exit, so a
//                              script that cleans up on SIGTERM (the restore drill removing its
//                              throwaway) does; then SIGKILLs what of the tree still runs, the
//                              child too, and resolves once the child has exited
//   inetPeers(pid)             the remote address of every TCP and UDP socket it holds, as
//                              "host:port": an IPv4 address, or an IPv4-mapped IPv6 one, as
//                              dotted IPv4 on both systems; any other IPv6 address in each
//                              system's own form (Linux: eight groups of four hex digits, none
//                              left out; macOS: lsof's, shortened with "::"), never bracketed.
//                              A socket with no remote end is "0.0.0.0:0" on macOS, and on Linux
//                              its zero address in the same forms ("0.0.0.0:0" for IPv4).
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, readlinkSync } from "node:fs";

const linux = process.platform === "linux";

// The starting environment, as text holding each NAME=value. Neither source sees what the
// process later sets in its own environment, which is the point of the leak checks.
export function startingEnvironment(pid) {
  if (linux) return readFileSync(`/proc/${pid}/environ`, "utf8");
  return execFileSync("ps", ["-E", "-ww", "-o", "command=", "-p", String(pid)], { encoding: "utf8" });
}

const processTable = () =>
  execFileSync("ps", ["-A", "-o", "pid=", "-o", "ppid="], { encoding: "utf8" })
    .trim().split("\n").map((line) => line.trim().split(/\s+/));

export function children(pid) {
  return processTable().filter(([, ppid]) => ppid === String(pid)).map(([child]) => child);
}

export function descendants(pids) {
  const below = new Map();
  for (const [pid, ppid] of processTable()) below.set(ppid, [...(below.get(ppid) ?? []), pid]);
  const found = new Set();
  const queue = pids.map(String);
  while (queue.length) {
    for (const pid of below.get(queue.shift()) ?? []) {
      if (found.has(pid)) continue;
      found.add(pid);
      queue.push(pid);
    }
  }
  return [...found].map(Number);
}

export function owned(t, child) {
  t.after(() => endTree(child));
  return child;
}

const running = (child) => child.pid !== undefined && child.exitCode === null && child.signalCode === null;

// Resolves true once `child` has exited, or false after `ms` (never, with no `ms`).
function exited(child, ms) {
  if (!running(child)) return Promise.resolve(true);
  return new Promise((resolve) => {
    const timer = ms === undefined ? undefined : setTimeout(() => resolve(false), ms);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve(true);
    });
  });
}

export async function endTree(child, { graceMs = 5_000 } = {}) {
  if (!running(child)) return;
  const tree = descendants([child.pid]);
  child.kill("SIGTERM");
  await exited(child, graceMs);
  for (const pid of [...tree, ...descendants(tree)]) {
    try {
      process.kill(pid, "SIGKILL");
    } catch (error) {
      // Gone already, or a pid reused by another user's process since the tree was read.
      if (error.code !== "ESRCH" && error.code !== "EPERM") throw error;
    }
  }
  if (running(child)) child.kill("SIGKILL");
  await exited(child);
}

export function inetPeers(pid) {
  return linux ? procInetPeers(pid) : lsofInetPeers(pid);
}

function procInetPeers(pid) {
  const inodes = new Set();
  for (const fd of readdirSync(`/proc/${pid}/fd`)) {
    try {
      const link = readlinkSync(`/proc/${pid}/fd/${fd}`);
      if (link.startsWith("socket:[")) inodes.add(link.slice(8, -1));
    } catch {
      // The descriptor closed while we looked.
    }
  }
  const peers = [];
  for (const table of ["tcp", "tcp6", "udp", "udp6"]) {
    for (const line of readFileSync(`/proc/${pid}/net/${table}`, "utf8").trim().split("\n").slice(1)) {
      const fields = line.trim().split(/\s+/);
      if (inodes.has(fields[9])) peers.push(procAddress(fields[2]));
    }
  }
  return peers;
}

// /proc/net's hex address: IPv4 as one little-endian word, IPv6 as four.
function procAddress(hex) {
  const [host, port] = hex.toLowerCase().split(":");
  const words = host.match(/.{8}/g).map((word) => word.match(/../g).reverse().join(""));
  const ipv4 = (word) => word.match(/../g).map((byte) => parseInt(byte, 16)).join(".");
  const ip = words.length === 1 ? ipv4(words[0])
    : words.slice(0, 3).join("") === "00000000000000000000ffff" ? ipv4(words[3])
    : words.join("").match(/.{4}/g).join(":");
  return `${ip}:${parseInt(port, 16)}`;
}

// lsof's name field is "local->remote" for a connected socket and "local" for one with no
// remote end; an IPv6 address is bracketed, and an IPv4-mapped one is given as IPv4.
function lsofInetPeers(pid) {
  let output;
  try {
    output = execFileSync("lsof", ["-a", "-p", String(pid), "-i", "-n", "-P", "-F", "n"], { encoding: "utf8" });
  } catch (error) {
    if (error.status === 1 && !error.stderr) return []; // lsof exits 1 when it finds no socket.
    throw error;
  }
  return output.split("\n").filter((line) => line.startsWith("n")).map((line) => {
    const remote = line.slice(1).split("->")[1];
    if (remote === undefined) return "0.0.0.0:0";
    const [, host, port] = remote.match(/^\[?(.*?)\]?:(\d+|\*)$/);
    return `${host.replace(/^::ffff:(?=\d+\.)/, "")}:${port}`;
  });
}
