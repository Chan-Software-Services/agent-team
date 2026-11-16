// What a running process holds, read on Linux and macOS: the environment and the sockets from
// /proc on Linux, and through ps and lsof on macOS, which has no /proc; the children and each
// process's start time from /proc on Linux and through ps on macOS. And the end of what a test
// started, so a failed or timed-out test leaves nothing running that holds node --test open.
//
//   startingEnvironment(pid)   the environment the process started with (Linux: its
//                              /proc/<pid>/environ; macOS: what `ps -E` appends to its command)
//   children(pid)              the pids of the process's children (Linux: /proc/<pid>/stat's
//                              ppid; macOS: `ps -A`)
//   owned(t, child)            returns `child`, a spawned ChildProcess, after arranging that it
//                              and every process below it end when test `t` ends, passed, failed
//                              or timed out (node:test runs `t.after` on each): the tree is read
//                              first, since a process whose parent ends is no longer below it;
//                              the child gets SIGTERM and up to 15 s to exit, so a script that
//                              cleans up on SIGTERM does (the restore drill removing its
//                              throwaway, team-heavy stopping its scope, whose own stop waits up
//                              to 10 s); then every process of the tree read first that is still
//                              the same process, by its start time, and every process now below
//                              one of them or below the child (one it started since, as on its
//                              SIGTERM) gets SIGKILL, the child too, and the hook resolves once
//                              the child has exited
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

// Every process: [pid, ppid, started], `started` being its start time, so a pid read twice is the
// same process only when its start is the same. On Linux the start is field 22 of
// /proc/<pid>/stat, in clock ticks since boot, which no step of the wall clock moves (ps's
// lstart is the boot time plus those ticks, and an NTP step moves the boot time it reads); on
// macOS, which has no /proc, it is ps's lstart, to the second.
const processTable = () => (linux ? procProcessTable() : psProcessTable());

function procProcessTable() {
  const table = [];
  for (const pid of readdirSync("/proc").filter((name) => /^\d+$/.test(name))) {
    let stat;
    try {
      stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    } catch {
      continue; // Gone while we looked.
    }
    // The command name, field 2, is in parentheses and may hold blanks or parentheses itself, so
    // the fields are counted from after its last ")": field 3 first, ppid field 4, start field 22.
    const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    table.push([pid, fields[1], fields[19]]);
  }
  return table;
}

const psProcessTable = () =>
  execFileSync("ps", ["-A", "-o", "pid=", "-o", "ppid=", "-o", "lstart="], { encoding: "utf8", env: { ...process.env, LC_ALL: "C" } })
    .trim().split("\n").map((line) => {
      const [pid, ppid, ...started] = line.trim().split(/\s+/);
      return [pid, ppid, started.join(" ")];
    });

export function children(pid) {
  return processTable().filter(([, ppid]) => ppid === String(pid)).map(([child]) => child);
}

// Every process of `table` below any of `pids`: their children, their children's, and on, as a
// Map of pid to start time.
function below(pids, table) {
  const childrenOf = new Map();
  for (const [pid, ppid, started] of table) childrenOf.set(ppid, [...(childrenOf.get(ppid) ?? []), [pid, started]]);
  const found = new Map();
  const queue = pids.map(String);
  while (queue.length) {
    for (const [pid, started] of childrenOf.get(queue.shift()) ?? []) {
      if (found.has(pid)) continue;
      found.set(pid, started);
      queue.push(pid);
    }
  }
  return found;
}

const graceMs = 15_000;

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

async function endTree(child) {
  if (!running(child)) return;
  const tree = below([child.pid], processTable());
  child.kill("SIGTERM");
  await exited(child, graceMs);
  const now = processTable();
  const startOf = new Map(now.map(([pid, , started]) => [pid, started]));
  // A pid of the first read whose start has changed is another process since, never this tree's.
  const same = [...tree].filter(([pid, started]) => startOf.get(pid) === started).map(([pid]) => pid);
  const roots = running(child) ? [String(child.pid), ...same] : same;
  for (const pid of new Set([...same, ...below(roots, now).keys()])) {
    try {
      process.kill(Number(pid), "SIGKILL");
    } catch (error) {
      // Gone since the second read, or another user's process.
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
