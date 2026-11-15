// How prod-mongo's server runs one of the toolkit's container scripts: through the machine's
// heavy-run lock, bin/team-heavy of the server's own checkout, so it queues behind the machine's
// other heavy runs, is admitted to the team's memory budget and runs in a scope of its own.
//
//   checkout                 the code checkout this server runs from
//   steps(tool)              { step(text), stepLine(line) }: a script's step lines, `<tool>: <text>`
//                            on its stderr, which a person running it by hand reads as it goes and
//                            runHeavy relays; stepLine gives a line's text, or undefined
//   await runHeavy({ tool, kind, noun, script, args, label, boundMinutes, progress, scrubbed })
//                            runs `team-heavy run --wait <minutes> --kind <kind> --label <label> --
//                            node <script> <args>` in the server's working directory, relays each
//                            step line as a progress notification, and resolves { busy }, team-heavy's
//                            reason when the lock was still held (its exit 75), or { result }, the one
//                            JSON object the script printed last on stdout; a Refusal when team-heavy
//                            could not start or the script printed none. The run is sent TERM
//                            `boundMinutes` after the wait, so the script removes what it made.
//
// The child gets childEnv() (children.mjs) and what team-heavy needs beyond it: the team home and
// systemd's user manager, for its admission and its scope, and PROD_MONGO_ROOT when the server has
// one. PROD_MONGO_HEAVY_WAIT_MINUTES replaces the 20-minute wait, for the tests only.
import { writeSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { childEnv, lastLine, run } from "./children.mjs";
import { Refusal } from "./refusal.mjs";

export const checkout = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const teamHeavy = join(checkout, "bin", "team-heavy");

export function steps(tool) {
  const prefix = `${tool}: `;
  return {
    step: (text) => writeSync(2, `${prefix}${text}\n`),
    stepLine: (line) => (line.startsWith(prefix) ? line.slice(prefix.length) : undefined),
  };
}

export async function runHeavy({ tool, kind, noun, script, args, label, boundMinutes, progress, scrubbed }) {
  const { stepLine } = steps(tool);
  const wait = /^\d+$/.test(process.env.PROD_MONGO_HEAVY_WAIT_MINUTES ?? "") ? process.env.PROD_MONGO_HEAVY_WAIT_MINUTES : "20";
  const extra = {};
  for (const key of ["PROD_MONGO_ROOT", "TEAM_HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]) {
    if (process.env[key] !== undefined) extra[key] = process.env[key];
  }
  const heavyArgs = ["run", "--wait", wait, "--kind", kind, "--label", label, "--", process.execPath, script, ...args];
  // The script's steps, relayed as they come; its other stderr lines are kept for a failure's reason.
  const relay = (child) => {
    let partial = "";
    child.stderr.on("data", (chunk) => {
      const lines = (partial + chunk).split("\n");
      partial = lines.pop();
      for (const line of lines) {
        const text = stepLine(line);
        if (text !== undefined) progress(text);
      }
    });
  };
  let ran;
  try {
    // TERM, so the script removes what it made before it ends.
    ran = await run(teamHeavy, heavyArgs, { env: childEnv(extra), timeoutMs: (Number(wait) + boundMinutes) * 60_000, killSignal: "SIGTERM", onSpawn: relay });
  } catch (error) {
    throw new Refusal(`team-heavy could not start: ${scrubbed(error.message)}`);
  }
  const stderr = ran.stderr.split("\n").filter((line) => stepLine(line) === undefined).join("\n");
  if (ran.code === 75) return { busy: scrubbed(lastLine(stderr)).replace(/^team-heavy: /, "") };
  try {
    return { result: JSON.parse(ran.stdout.trim().split("\n").at(-1)) };
  } catch {
    const why = scrubbed(lastLine(stderr));
    throw new Refusal(`the ${noun} gave no result (${ran.timedOut ? "stopped after its time ran out" : `exit ${ran.code ?? ran.signal}`})${why ? `: ${why}` : ""}`);
  }
}
