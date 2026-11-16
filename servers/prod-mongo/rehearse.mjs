// prod-mongo's migration rehearsal: runs a release's migration scripts, from one commit of the
// project's repository, against a dump restored into a throwaway local MongoDB (throwaway.mjs),
// and reports per collection what each one changed (changes.mjs): counts and ids, never content.
//
//   await rehearse({ argv, database, root, repositories })
//                            the body of toolkits/prod-mongo/scripts/rehearse.mjs: prints one JSON
//                            object on stdout (with --text, rehearsalAnswer's text instead), each
//                            step as it starts on stderr (`rehearse-migrations: <step>`), the names
//                            of what it makes in Docker before it makes them (`rehearse-migrations:
//                            docker objects: <name> <image>`, heavy.mjs), and exits 0 when every
//                            migration ran, none stopped the rehearsal and nothing was left in
//                            Docker, 1 otherwise, and 128 plus the signal's number when stopped by
//                            SIGINT, SIGTERM or SIGHUP
//   await rehearseTool({ input, root, shown, scrubbed, progress, repositories })
//                            the rehearse-migrations tool: checks the input, the dump and the
//                            working directory, fetches, resolves the ref, marks each script that
//                            takes a dry run, then runs that script through the server's own
//                            checkout's bin/team-heavy, stopped 45 minutes after it starts
//                            (runHeavy's bound), and answers { text, isError }
//   rehearsalAnswer(result)  the tool's answer to the script's JSON: { text, isError }
//   rehearseInput            the tool's input schema
//   takesDryRun(cwd, sha, script)
//                            whether back-end/migrations/<script>'s text at <sha> holds --dry-run
//   checkoutRefusal(cwd, repositories)
//                            why `cwd` is not a checkout of one of `repositories` (owner/name on
//                            GitHub, the first the one named in a refusal), or undefined
//   resolveRef(cwd, ref, repository)
//                            { sha } of the commit `ref` names as origin has it (a branch of
//                            origin's, else a tag, else a commit's hex), held by a branch of
//                            origin's, or { refusal }
//
// The tool, before the heavy-run lock and before Docker: the working directory's origin
// (`git config --get remote.origin.url`, the URL as the checkout holds it, never printed, since one
// may carry a token) must name one of `repositories`; `git fetch --quiet origin`, whose failure is
// a line in the answer, not a refusal; the ref resolved as origin has it (resolveRef), never as a
// local branch; and each script must be a file at <sha>:back-end/migrations/<script>. git gets childEnv() with
// GIT_TERMINAL_PROMPT=0, and the fetch alone SSH_AUTH_SOCK when set, for an ssh origin.
//
// The script takes a backup's stamp, a commit's full sha and 1 to 20 script names (and --text),
// never a path or a connection string: it reads no credential, so it cannot reach production. It
// runs in the checkout (its working directory), and before Docker is touched checks the root, the
// stamp, the dump's database and size, mongorestore and the driver, the checkout's origin, the
// commit and each script; each failure there is a refusal. Then it:
//   1. removes what an earlier run left past its expiry;
//   2. builds the back-end image from `git archive <sha>:back-end` piped to `docker build -` (no
//      file is written, the directory's own .dockerignore applies), tagged
//      agent-team-rehearsal:<sha12> with the toolkit's labels, stopped after 15 minutes;
//   3. creates a Docker network with --internal, so no route out of the machine, labelled, and
//      starts the throwaway on the default bridge (for this script's loopback connection) and on
//      that network under the alias `mongodb`;
//   4. restores the dump as the drill does (restore.mjs), its FIFO in the dump's 0700 rehearsals/
//      folder, and snapshots every collection;
//   5. for each script in order, when it takes a dry run (takesDryRun), runs it with --dry-run,
//      snapshots and compares; a dry run that changed anything stops the rehearsal there, before
//      the script's real run. Then runs it for real, snapshots again and compares. Each run is
//      `docker run --rm --pull never --network <the internal network> --memory 1g --env MONGODB_URI
//      <image> timeout 600 python migrations/<script> [--dry-run]`, the URI (the throwaway's, host
//      `mongodb`) in the docker CLI child's own environment, never an argument list; its stdout and
//      stderr go to rehearsals/<at>/<n>-<script>.<dry-run|run>.log (mode 0600) and nowhere else. A
//      run that exits non-zero (124 when its `timeout 600` ended it) or whose docker run is killed
//      10 minutes and 30 seconds on stops the rehearsal there;
//   6. writes rehearsals/<at>/report.json (mode 0600: each step's exit code, seconds, log and every
//      collection's comparison with its full id lists, what stopped the rehearsal and the steps not
//      run) and removes the throwaway, the network and the image, on every path: at the end, at a
//      stop, on an error, and on SIGINT, SIGTERM and SIGHUP.
// The JSON forms: { refused }; { failed, stamp, folder, sha, logs?, removed, cleanup }; and
// { stamp, folder, sha, at, logs, report, seconds, steps, stopped?, notRun, removed, cleanup }, each
// step { n, script, mode: "dry-run" or "run", exit, signal, timedOut, seconds, log, lines,
// collections }, `collections` the comparisons that hold a change, each id list as { count, ids }
// with at most 50 ids; `stopped` { n, script, mode, exit, signal, timedOut, wrote }, the step that
// stopped the rehearsal, `wrote` true when it was a dry run that changed something; `notRun` the
// steps after it, each { n, script, mode }; and `cleanup` { gone, left }; every path written from ~/.
import { spawn, spawnSync } from "node:child_process";
import { closeSync, createReadStream, existsSync, mkdirSync, openSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { stampOf } from "./backup.mjs";
import { capped, changeCounts, changeLine, compareDatabases, differs, snapshotDatabase } from "./changes.mjs";
import { childEnv, lastLine, run, scrubber } from "./children.mjs";
import { count, duration, limit, plural } from "./dump.mjs";
import { busyText, checkout, leftText, logsSoFar, overtimeText, runHeavy, scriptStart, steps } from "./heavy.mjs";
import { Refusal } from "./refusal.mjs";
import { chosenDump, restorableDump, restoreDump, restoreTools } from "./restore.mjs";
import { backupsRoot, stampPattern } from "./root.mjs";
import { docker, expiredLines, removeExpired, removeThrowaway, startThrowaway, throwawayImage, throwawayName, toolkitLabels } from "./throwaway.mjs";

const tool = "rehearse-migrations";
const script = join(checkout, "toolkits", "prod-mongo", "scripts", "rehearse.mjs");
const { step, names } = steps(tool);

const refPattern = /^[A-Za-z0-9_][A-Za-z0-9._/-]{0,199}$/;
const scriptPattern = /^[A-Za-z0-9_]+\.py$/;
const scriptLength = 100;
const shaPattern = /^[0-9a-f]{40}([0-9a-f]{24})?$/;
const hexPattern = /^[0-9a-f]{7,64}$/i;
const mostScripts = 20;

const buildMs = 15 * 60_000;
const runSeconds = 600;
const lifeMs = 3600_000;

export const rehearseInput = {
  type: "object",
  properties: {
    ref: {
      type: "string",
      pattern: refPattern.source,
      description: "The commit of the project's repository whose migrations to rehearse: a commit sha, a branch or a tag, the release's own sha by preference.",
    },
    migrations: {
      type: "array",
      items: { type: "string", pattern: scriptPattern.source, maxLength: scriptLength },
      minItems: 1,
      maxItems: mostScripts,
      description: "The migration scripts to run, in the release's order: each a file's name under back-end/migrations/ at that commit (migrate_phase.py).",
    },
    backup: {
      type: "string",
      pattern: stampPattern.source,
      description: "The backup's name, its UTC start as list-backups gives it (2026-11-08T142305Z); the newest verified backup when left out.",
    },
  },
  required: ["ref", "migrations"],
  additionalProperties: false,
};

const isScript = (name) => typeof name === "string" && name.length <= scriptLength && scriptPattern.test(name);

function git(cwd, args) {
  const ran = spawnSync("git", args, { cwd, env: childEnv({ GIT_TERMINAL_PROMPT: "0" }), stdio: ["ignore", "pipe", "pipe"], encoding: "utf8", timeout: 30_000 });
  return { ok: !ran.error && ran.status === 0, stdout: (ran.stdout ?? "").trim(), missing: ran.error?.code === "ENOENT" };
}

export function checkoutRefusal(cwd, repositories) {
  const [repository] = repositories;
  const origin = git(cwd, ["config", "--get", "remote.origin.url"]);
  if (origin.missing) return "git is not installed";
  if (!origin.ok || !origin.stdout) return `the working directory is not a git checkout with an origin, so it is not a checkout of ${repository}`;
  // GitHub's host at the URL's start, so no other host or path can end in its name.
  const named = /^(?:https:\/\/(?:[^@/]+@)?|ssh:\/\/git@|git@)github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/i.exec(origin.stdout)?.[1];
  if (!named || !repositories.some((known) => known.toLowerCase() === named.toLowerCase())) {
    return `the working directory's origin is not ${repository}, whose migrations a rehearsal runs`;
  }
  return undefined;
}

// The commit a ref names, as origin has it: a branch of origin's (`<ref>` or `origin/<ref>`), else a
// tag, else a commit's hex; never a local branch, so a stale one cannot stand in for origin's.
// The commit must be on a branch of origin's, so one never pushed is not rehearsed.
// { sha }, or { refusal }.
export function resolveRef(cwd, ref, repository) {
  const candidates = [`refs/remotes/origin/${ref}`, ...(ref.startsWith("origin/") ? [`refs/remotes/${ref}`] : []), `refs/tags/${ref}`, ...(hexPattern.test(ref) ? [ref] : [])];
  const sha = candidates
    .map((candidate) => git(cwd, ["rev-parse", "--verify", "--quiet", "--end-of-options", `${candidate}^{commit}`]))
    .find(({ ok, stdout }) => ok && shaPattern.test(stdout))?.stdout;
  if (!sha) return { refusal: `${ref} names no branch or tag of ${repository}'s origin, nor a commit on one of its branches, in this checkout` };
  const held = git(cwd, ["for-each-ref", "--count=1", "--format=%(refname)", "--contains", sha, "refs/remotes/origin/"]);
  if (!held.ok || !held.stdout) return { refusal: `${ref} names ${sha.slice(0, 8)}, which no branch of ${repository}'s origin holds in this checkout: only a pushed commit is rehearsed` };
  return { sha };
}

export function takesDryRun(cwd, sha, name) {
  const text = git(cwd, ["cat-file", "blob", `${sha}:back-end/migrations/${name}`]);
  return text.ok && text.stdout.includes("--dry-run");
}

// Why the scripts cannot run at the commit, or undefined.
function scriptsRefusal(cwd, sha, scripts) {
  for (const name of scripts) {
    const kind = git(cwd, ["cat-file", "-t", `${sha}:back-end/migrations/${name}`]);
    if (!kind.ok || kind.stdout !== "blob") return `back-end/migrations/${name} is not a file at ${sha.slice(0, 8)}`;
  }
  return undefined;
}

export async function rehearseTool({ input, root, shown, scrubbed, progress, repositories }) {
  const { ref, migrations, backup } = input;
  if (typeof ref !== "string" || !refPattern.test(ref)) throw new Refusal("ref must be a commit sha, a branch or a tag, of letters, digits and . _ / - only");
  if (!Array.isArray(migrations) || migrations.length < 1 || migrations.length > mostScripts || !migrations.every(isScript)) {
    throw new Refusal(`migrations must be 1 to ${mostScripts} script names, each as migrate_phase.py`);
  }
  const { stamp, note } = chosenDump({ root, shown, stamp: backup, verb: "rehearse on" });

  const cwd = process.cwd();
  const refusal = checkoutRefusal(cwd, repositories);
  if (refusal) throw new Refusal(refusal);
  progress("fetching origin");
  const ssh = process.env.SSH_AUTH_SOCK === undefined ? {} : { SSH_AUTH_SOCK: process.env.SSH_AUTH_SOCK };
  let fetched;
  try {
    const ran = await run("git", ["fetch", "--quiet", "origin"], { cwd, env: childEnv({ GIT_TERMINAL_PROMPT: "0", ...ssh }), timeoutMs: 120_000 });
    fetched = ran.code === 0;
  } catch {
    fetched = false;
  }
  const stale = fetched ? "" : "git fetch origin failed, so the ref was read as this checkout last fetched it.";
  const { sha, refusal: unresolved } = resolveRef(cwd, ref, repositories[0]);
  if (unresolved) throw new Refusal(`${unresolved}${fetched ? "" : ", and git fetch origin failed"}`);
  const absent = scriptsRefusal(cwd, sha, migrations);
  if (absent) throw new Refusal(absent);

  const dry = migrations.filter((name) => takesDryRun(cwd, sha, name)).length;
  progress(`rehearsing ${plural(migrations.length, "migration")} of ${sha.slice(0, 8)} (${dry ? `${count(dry)} with a dry run` : "no dry run"}) on ${stamp}, through the machine's heavy-run lock`);
  const { busy, overtime, result } = await runHeavy({
    tool, kind: "rehearsal", noun: "rehearsal", script, args: [stamp, sha, ...migrations], label: `prod-mongo rehearsal ${stamp}`, boundMinutes: 45, progress, scrubbed,
  });
  if (busy !== undefined) return { text: busyText(tool, busy), isError: true };
  if (overtime) return { text: [overtimeText(tool, "rehearsal", overtime, result?.logs), stale, note].filter(Boolean).join("\n"), isError: true };
  const answer = rehearsalAnswer(result);
  return { ...answer, text: [answer.text, stale, note].filter(Boolean).join("\n") };
}

export async function rehearse({ argv, database, root: configuredRoot, repositories }) {
  const { root, shown } = backupsRoot(configuredRoot);
  // What the run made in Docker and has not yet removed, and what a failure's answer names.
  const state = { stamp: undefined, folder: undefined, sha: undefined, logs: undefined, removed: [], uri: "", made: {} };

  const failed = (reason) => ({
    failed: reason,
    stamp: state.stamp,
    folder: state.folder,
    sha: state.sha,
    ...(state.logs ? { logs: state.logs } : {}),
    removed: state.removed,
    cleanup: cleanup(state.made),
  });
  const { rest, print } = scriptStart({ argv, answer: rehearsalAnswer, stopped: (signal) => failed(`the rehearsal was stopped (${signal})`) });

  let result;
  try {
    result = await rehearsal({ rest, database, root, shown, repositories, state });
  } catch (error) {
    if (error instanceof Refusal) result = { refused: error.message };
    else result = failed(scrubber(state.uri)(String(error?.message ?? error)));
  }
  print(result);
  process.exit(result.steps && !result.stopped && result.cleanup.gone ? 0 : 1);
}

// Removes what `made` still names, in the order that frees each: the docker child still running,
// the migration's container, the throwaway, the network, the image. Synchronous, for a signal, and
// safe to call again: what is gone is forgotten.
function cleanup(made) {
  const left = [];
  for (const child of made.children ?? []) child.kill("SIGKILL");
  made.children = [];
  for (const key of ["container", "throwaway"]) {
    if (!made[key]) continue;
    const { gone, error } = removeThrowaway(made[key]);
    if (gone) made[key] = undefined;
    else left.push(`container ${made[key]} (${error})`);
  }
  const absent = (why) => /no such|not found/i.test(why);
  if (made.network) {
    const removed = docker(["network", "rm", made.network]);
    if (removed.ok || absent(removed.why)) made.network = undefined;
    else left.push(`network ${made.network} (${removed.why})`);
  }
  if (made.image) {
    const removed = docker(["image", "rm", "--force", made.image]);
    if (removed.ok || absent(removed.why)) made.image = undefined;
    else left.push(`image ${made.image} (${removed.why})`);
  }
  return { gone: left.length === 0, left };
}

async function rehearsal({ rest, database, root, shown, repositories, state }) {
  const [given, sha, ...scripts] = rest;
  if (rest.some((arg) => arg.startsWith("-")) || scripts.length < 1 || scripts.length > mostScripts || !shaPattern.test(sha) || !scripts.every(isScript)) {
    throw new Refusal(`takes a backup's name, a commit's full sha and 1 to ${mostScripts} migration scripts' names, each as migrate_phase.py (and --text for the answer as text)`);
  }
  const { stamp, folder, shownFolder } = restorableDump({ root, shown, stamp: given, database, verb: "rehearse on", noun: "a rehearsal" });
  Object.assign(state, { stamp, folder: shownFolder, sha });
  const { mongorestore, MongoClient, BSON } = await restoreTools();
  const cwd = process.cwd();
  const refusal = checkoutRefusal(cwd, repositories);
  if (refusal) throw new Refusal(refusal);
  const commit = git(cwd, ["cat-file", "-t", sha]);
  if (!commit.ok || commit.stdout !== "commit") throw new Refusal(`${sha.slice(0, 8)} is no commit of ${repositories[0]} in this checkout`);
  const absent = scriptsRefusal(cwd, sha, scripts);
  if (absent) throw new Refusal(absent);

  // Docker from here on.
  const started = Date.now();
  const at = stampOf(new Date(started));
  const rehearsals = join(folder, "rehearsals");
  const dir = join(rehearsals, at);
  const shownDir = `${shownFolder}/rehearsals/${at}`;
  if (existsSync(dir)) throw new Refusal(`${shownDir} already exists: ask again in a second`);
  step("removing what earlier runs left past their expiry");
  state.removed = removeExpired(started);

  const name = throwawayName("rehearsal");
  const labels = toolkitLabels({ kind: "drill", expires: `${new Date(started + lifeMs).toISOString().slice(0, 19)}Z` });
  const image = `agent-team-rehearsal:${sha.slice(0, 12)}`;
  const { made } = state;
  names([name, image]);
  step(`building the back-end image at ${sha.slice(0, 8)}`);
  made.image = image;
  await build({ cwd, sha, image, labels, made });

  step("creating the network with no route out");
  made.network = name;
  const network = docker(["network", "create", "--internal", ...labels, name]);
  if (!network.ok) throw new Error(`docker could not create the network: ${network.why}`);
  step("starting the throwaway MongoDB");
  made.throwaway = name;
  const throwaway = await startThrowaway({ name, kind: "drill", join: { network: name, alias: "mongodb" }, MongoClient });
  state.uri = throwaway.uri;

  mkdirSync(rehearsals, { recursive: true, mode: 0o700 });
  step("restoring the dump");
  const restoreError = await restoreDump({ database, folder, fifo: join(rehearsals, `.${at}.config.fifo`), uri: throwaway.uri });
  if (restoreError) throw new Error(`${restoreError}, so the dump did not restore`);
  step("taking the snapshot before the migrations");
  const db = throwaway.client.db(database);
  let before = await snapshotDatabase(db, BSON);

  mkdirSync(dir, { mode: 0o700 });
  state.logs = `${shownDir}/`;
  // The throwaway as a migration reaches it: by its alias on the internal network.
  const uri = `mongodb://root:${throwaway.password}@mongodb:27017/?authSource=admin`;
  const briefSteps = [];
  const fullSteps = [];
  let stopped;
  const notRun = [];
  for (const [index, migration] of scripts.entries()) {
    const n = index + 1;
    for (const mode of takesDryRun(cwd, sha, migration) ? ["dry-run", "run"] : ["run"]) {
      if (stopped) {
        notRun.push({ n, script: migration, mode });
        continue;
      }
      const dryRun = mode === "dry-run";
      const log = `${n}-${migration}.${mode}.log`;
      step(`running ${migration}${dryRun ? " --dry-run" : ""} (${n} of ${scripts.length})`);
      made.container = `${name}-${mode}-${n}`;
      const ranAt = Date.now();
      const ran = await runLogged(
        [
          "run", "--rm", "--pull", "never", "--name", made.container, ...labels,
          "--network", name, "--memory", "1g", "--env", "MONGODB_URI",
          image, "timeout", String(runSeconds), "python", `migrations/${migration}`, ...(dryRun ? ["--dry-run"] : []),
        ],
        { env: childEnv({ MONGODB_URI: uri }), log: join(dir, log), timeoutMs: (runSeconds + 30) * 1000, made },
      );
      const seconds = Math.round((Date.now() - ranAt) / 1000);
      // --rm removed it, unless its docker run was stopped.
      const left = removeThrowaway(made.container);
      if (!left.gone) throw new Error(`docker could not remove ${made.container}: ${left.error}`);
      made.container = undefined;
      const after = await snapshotDatabase(db, BSON);
      const collections = compareDatabases(before, after);
      before = after;
      const record = { n, script: migration, mode, exit: ran.code, signal: ran.signal, timedOut: ran.timedOut, seconds, log, lines: await lineCount(join(dir, log)) };
      fullSteps.push({ ...record, collections });
      briefSteps.push({ ...record, collections: collections.filter(differs).map(capped) });
      const wrote = dryRun && collections.some(differs);
      if (ran.code !== 0 || ran.timedOut || wrote) {
        stopped = { n, script: migration, mode, exit: ran.code, signal: ran.signal, timedOut: ran.timedOut, wrote };
      }
    }
  }

  step("removing the throwaway MongoDB, the network and the image");
  await throwaway.client.close().catch(() => {});
  const cleaned = cleanup(made);
  const ended = Date.now();
  const report = {
    at, stamp, sha, started: new Date(started).toISOString(), ended: new Date(ended).toISOString(), mongorestore, image: throwawayImage, steps: fullSteps,
    ...(stopped ? { stopped } : {}), notRun,
  };
  writeFileSync(join(dir, "report.json"), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  return {
    stamp,
    folder: shownFolder,
    sha,
    at,
    logs: `${shownDir}/`,
    report: `${shownDir}/report.json`,
    seconds: Math.round((ended - started) / 1000),
    steps: briefSteps,
    ...(stopped ? { stopped } : {}),
    notRun,
    removed: state.removed,
    cleanup: cleaned,
  };
}

const brief = scrubber("");

// git archive <sha>:back-end piped to docker build -: the image is built from the commit's own
// files, none written to disk. Neither child blocks a signal: both are killed by cleanup.
function build({ cwd, sha, image, labels, made }) {
  return new Promise((resolve, reject) => {
    const archive = spawn("git", ["archive", "--format=tar", `${sha}:back-end`], { cwd, env: childEnv({ GIT_TERMINAL_PROMPT: "0" }), stdio: ["ignore", "pipe", "pipe"] });
    const built = spawn("docker", ["build", "--tag", image, ...labels, "-"], { env: childEnv(), stdio: ["pipe", "pipe", "pipe"] });
    made.children = [archive, built];
    const tail = (child) => {
      let text = "";
      child.stderr.setEncoding("utf8").on("data", (chunk) => (text = (text + chunk).slice(-16_384)));
      return () => text;
    };
    const archiveErrors = tail(archive);
    const buildErrors = tail(built);
    built.stdout.resume();
    built.stdin.on("error", () => {});
    archive.stdout.pipe(built.stdin);
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      archive.kill("SIGKILL");
      built.kill("SIGKILL");
    }, buildMs);
    const ends = [archive, built].map(
      (child) =>
        new Promise((done) => {
          child.on("error", (error) => done({ error }));
          child.on("close", (code, signal) => done({ code, signal }));
        }),
    );
    Promise.all(ends).then(([archived, builtEnd]) => {
      clearTimeout(timer);
      made.children = [];
      const of = (what, end, errors) => `${what} ${end.error ? `could not start (${end.error.code ?? end.error.message})` : `exited ${end.code ?? end.signal}`}${errors ? `: ${brief(lastLine(errors))}` : ""}`;
      if (timedOut) reject(new Error(`the image's build did not finish in ${limit(buildMs)}, so it was stopped`));
      else if (archived.error || archived.code !== 0) reject(new Error(`the commit's back-end could not be read: ${of("git archive", archived, archiveErrors())}`));
      else if (builtEnd.error || builtEnd.code !== 0) reject(new Error(`the back-end image could not be built: ${of("docker build", builtEnd, buildErrors())}`));
      else resolve();
    });
  });
}

// One docker run whose stdout and stderr go to a new file `log` (mode 0600) and nowhere else.
function runLogged(args, { env, log, timeoutMs, made }) {
  return new Promise((resolve, reject) => {
    const fd = openSync(log, "wx", 0o600);
    let child;
    try {
      child = spawn("docker", args, { env, stdio: ["ignore", fd, fd] });
    } finally {
      closeSync(fd);
    }
    made.children = [child];
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, timeoutMs);
    child.on("error", (error) => {
      clearTimeout(timer);
      made.children = [];
      reject(new Error(error.code === "ENOENT" ? "docker is not installed" : error.message));
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      made.children = [];
      resolve({ code, signal, timedOut });
    });
  });
}

// A file's lines, counted as bytes: nothing of it is decoded.
async function lineCount(path) {
  let lines = 0;
  let last = 0x0a;
  for await (const chunk of createReadStream(path)) {
    for (const byte of chunk) {
      if (byte === 0x0a) lines += 1;
    }
    if (chunk.length) last = chunk[chunk.length - 1];
  }
  return last === 0x0a ? lines : lines + 1;
}

function cleanupClause(cleanup) {
  if (!cleanup || cleanup.gone) return "nothing left running";
  return `but ${leftText(cleanup.left)}`;
}

function outcome({ exit, signal, timedOut, seconds }) {
  const took = duration(seconds * 1000);
  if (timedOut) return `stopped after ${took}, past its time`;
  if (exit === null) return `killed (${signal}) after ${took}`;
  if (exit === 124) return `exit 124 in ${took}, stopped by its ${limit(runSeconds * 1000)} limit`;
  return `exit ${exit} in ${took}`;
}

const stepName = ({ script: name, mode }) => `${name}${mode === "dry-run" ? " --dry-run" : ""}`;

// Why the rehearsal stopped, in one sentence.
function stopLine(stopped, ranSteps) {
  const what = stopped.mode === "dry-run" ? `the dry run of ${stopped.script}` : stopped.script;
  if (stopped.wrote) {
    const at = ranSteps.find(({ n, mode }) => n === stopped.n && mode === stopped.mode);
    return `Stopped: ${what} wrote: ${at.collections.map(changeCounts).join("; ")}.`;
  }
  if (stopped.timedOut) return `Stopped: ${what} did not end in ${limit((runSeconds + 30) * 1000)}, so its docker run was killed.`;
  if (stopped.exit === null) return `Stopped: ${what} was killed (${stopped.signal}).`;
  if (stopped.exit === 124) return `Stopped: ${what} ran past its ${limit(runSeconds * 1000)} limit (exit 124).`;
  return `Stopped: ${what} exited ${stopped.exit}.`;
}

export function rehearsalAnswer(result) {
  if (result.refused) return { text: `${tool}: failed: ${result.refused}`, isError: true };
  if (result.failed) {
    const lines = [`${tool}: failed: ${result.failed}; ${cleanupClause(result.cleanup)}.`];
    if (result.logs) lines.push(logsSoFar(result.logs));
    return { text: [...lines, ...expiredLines(result.removed)].join("\n"), isError: true };
  }
  const { folder, sha, seconds, steps: ran, stopped, notRun = [], logs, cleanup: cleaned } = result;
  const migrations = new Set([...ran, ...notRun].map(({ n }) => n)).size;
  const outcomeOf = stopped
    ? `stopped at ${stopped.n} of ${plural(migrations, "migration")}`
    : `${plural(migrations, "migration")} ran`;
  const lines = [`Rehearsal of ${sha.slice(0, 8)} on ${folder}: ${outcomeOf}, ${cleanupClause(cleaned)} (${duration(seconds * 1000)})`];
  for (const ranStep of ran) {
    const dryRun = ranStep.mode === "dry-run";
    const first = dryRun || !ran.some(({ n, mode }) => n === ranStep.n && mode === "dry-run");
    const opening = first ? `${ranStep.n}. ` : "   ";
    const name = `${stepName(ranStep)}${!dryRun && first ? " (no dry run)" : ""}`;
    const nothing = dryRun ? ", wrote nothing" : ", changed nothing";
    lines.push(`${opening}${name}: ${outcome(ranStep)}${ranStep.collections.length ? "" : nothing}`);
    for (const comparison of ranStep.collections) lines.push(`   ${changeLine(comparison)}`);
  }
  if (stopped) lines.push(stopLine(stopped, ran));
  if (notRun.length) lines.push(`Not run: ${notRun.map(stepName).join(", ")}.`);
  const logged = ran.map(({ log, lines: n }) => `${log}, ${plural(n, "line")}`).join("; ");
  lines.push(`Logs, for Daniel to read in a terminal (never quoted here): ${logs} (${logged})`);
  lines.push(...expiredLines(result.removed));
  return { text: lines.join("\n"), isError: !cleaned.gone || Boolean(stopped) };
}
