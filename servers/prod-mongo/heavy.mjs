// How prod-mongo's server runs one of the toolkit's container scripts: through the machine's
// heavy-run lock, bin/team-heavy of the server's own checkout, so it queues behind the machine's
// other heavy runs, is admitted to the team's memory budget and runs in a scope of its own.
//
//   checkout                 the code checkout this server runs from
//   steps(tool)              { step(text), names(list), stepLine(line), namesLine(line) }: a
//                            script's step lines, `<tool>: <text>` on its stderr, which a person
//                            running it by hand reads as it goes and runHeavy relays, and its
//                            names line, `<tool>: docker objects: <name>...`, the names of what it
//                            is about to make in Docker, which runHeavy keeps; stepLine gives a step
//                            line's text and namesLine a names line's names, or undefined
//   await runHeavy({ tool, kind, noun, script, args, label, boundMinutes, progress, scrubbed })
//                            runs `team-heavy run --wait <minutes> --kind <kind> --label <label> --
//                            node <script> <args>` in the server's working directory, relays each
//                            step line as a progress notification, and resolves { busy }, team-heavy's
//                            reason when the lock was still held (its exit 75); { overtime, result? }
//                            when the script ran past its bound; or { result }, the one JSON object
//                            the script printed last on stdout; a Refusal when team-heavy could not
//                            start or the script printed none.
//   overtimeText(tool, noun, overtime, logs)
//                            the failure's answer for a run past its bound: what was stopped, what
//                            is left, and the logs so far when `logs` names them
//
// The bound: `boundMinutes` from the script's first line on stderr (it runs only once team-heavy
// holds the lock and has admitted it), or the wait plus the bound from the start when no line comes.
// Past it the server sends TERM to team-heavy's process group, which ends the script's whole tree
// (team-heavy stops it, and under a held lock the script is in that group itself), so the script
// removes what it made; KILL 30 seconds later when any of it is still there; then, by id, every
// container, network and image labelled toolkit=prod-mongo of a name the script's names line gave
// (removeNamed, throwaway.mjs), and overtime is { limit, cleanup }, `cleanup` that removal's
// { gone, left }, `result` the script's JSON when its TERM handler printed one.
//
// The child gets childEnv() (children.mjs) and what team-heavy needs beyond it: the team home and
// systemd's user manager, for its admission and its scope, and PROD_MONGO_ROOT when the server has
// one. PROD_MONGO_HEAVY_WAIT_MINUTES replaces the 20-minute wait, PROD_MONGO_BOUND_SECONDS the
// bound and PROD_MONGO_KILL_GRACE_SECONDS the 30 seconds before KILL, for the tests only.
import { writeSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { childEnv, lastLine, run } from "./children.mjs";
import { limit } from "./dump.mjs";
import { Refusal } from "./refusal.mjs";
import { removeNamed } from "./throwaway.mjs";

export const checkout = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const teamHeavy = join(checkout, "bin", "team-heavy");

export function steps(tool) {
  const prefix = `${tool}: `;
  const namesPrefix = `${prefix}docker objects: `;
  return {
    step: (text) => writeSync(2, `${prefix}${text}\n`),
    names: (list) => writeSync(2, `${namesPrefix}${list.join(" ")}\n`),
    stepLine: (line) => (line.startsWith(prefix) && !line.startsWith(namesPrefix) ? line.slice(prefix.length) : undefined),
    namesLine: (line) => (line.startsWith(namesPrefix) ? line.slice(namesPrefix.length).split(" ").filter(Boolean) : undefined),
  };
}

const testing = (name) => (/^\d+$/.test(process.env[name] ?? "") ? Number(process.env[name]) : undefined);

// A signal to the whole process group `child` leads; gone already, or never started, is fine.
function signalGroup(child, signal) {
  if (!child.pid) return;
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
}

export async function runHeavy({ tool, kind, noun, script, args, label, boundMinutes, progress, scrubbed }) {
  const { stepLine, namesLine } = steps(tool);
  const wait = String(testing("PROD_MONGO_HEAVY_WAIT_MINUTES") ?? 20);
  const boundMs = (testing("PROD_MONGO_BOUND_SECONDS") ?? boundMinutes * 60) * 1000;
  const graceMs = (testing("PROD_MONGO_KILL_GRACE_SECONDS") ?? 30) * 1000;
  const extra = {};
  for (const key of ["PROD_MONGO_ROOT", "TEAM_HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]) {
    if (process.env[key] !== undefined) extra[key] = process.env[key];
  }
  const heavyArgs = ["run", "--wait", wait, "--kind", kind, "--label", label, "--", process.execPath, script, ...args];
  const names = [];
  const timers = [];
  let overtime = false;
  // The script's steps, relayed as they come, and its names kept; its other stderr lines are kept
  // for a failure's reason. Its first line starts the bound.
  const watch = (child) => {
    const stop = () => {
      overtime = true;
      signalGroup(child, "SIGTERM");
      timers.push(setTimeout(() => signalGroup(child, "SIGKILL"), graceMs));
    };
    let bound;
    const backstop = setTimeout(stop, Number(wait) * 60_000 + boundMs);
    timers.push(backstop);
    for (const end of ["close", "error"]) child.on(end, () => timers.forEach(clearTimeout));
    let partial = "";
    child.stderr.on("data", (chunk) => {
      const lines = (partial + chunk).split("\n");
      partial = lines.pop();
      for (const line of lines) {
        const named = namesLine(line);
        const text = stepLine(line);
        if ((named || text !== undefined) && !bound && !overtime) {
          clearTimeout(backstop);
          bound = setTimeout(stop, boundMs);
          timers.push(bound);
        }
        if (named) names.push(...named);
        if (text !== undefined) progress(text);
      }
    });
  };
  let ran;
  try {
    ran = await run(teamHeavy, heavyArgs, { env: childEnv(extra), detached: true, onSpawn: watch });
  } catch (error) {
    throw new Refusal(`team-heavy could not start: ${scrubbed(error.message)}`);
  }
  const stderr = ran.stderr.split("\n").filter((line) => stepLine(line) === undefined && namesLine(line) === undefined).join("\n");
  let result;
  try {
    result = JSON.parse(ran.stdout.trim().split("\n").at(-1));
  } catch {
    result = undefined;
  }
  if (overtime) {
    let cleanup;
    try {
      cleanup = removeNamed(names);
    } catch (error) {
      cleanup = { gone: false, left: [scrubbed(error.message)] };
    }
    return { overtime: { limit: limit(boundMs), cleanup }, ...(result ? { result } : {}) };
  }
  if (ran.code === 75) return { busy: scrubbed(lastLine(stderr)).replace(/^team-heavy: /, "") };
  if (result !== undefined) return { result };
  const why = scrubbed(lastLine(stderr));
  throw new Refusal(`the ${noun} gave no result (exit ${ran.code ?? ran.signal})${why ? `: ${why}` : ""}`);
}

export function overtimeText(tool, noun, { limit, cleanup }, logs) {
  const left = cleanup.gone
    ? "what it made in Docker was removed, so nothing was left running"
    : `but docker could not remove ${cleanup.left.join(", ")}, which the next rehearsal or drill removes once an hour old`;
  const lines = [`${tool}: failed: the ${noun} ran past its ${limit}, so it was stopped; ${left}.`];
  if (logs) lines.push(`Logs so far, for Daniel to read in a terminal (never quoted here): ${logs}`);
  return lines.join("\n");
}
