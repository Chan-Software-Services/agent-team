#!/usr/bin/env node
// The rust toolkit's PostToolUse hook: after an Edit, Write or MultiEdit of a Rust file, the
// compiler's and clippy's findings for its package, given back to the session as additional
// context, so a mistake is named at the edit that made it rather than at the end.
//
// Usage: node rust-diagnostics.mjs < <PostToolUse event JSON>
// Claude Code runs it from the toolkit's hooks/hooks.json, with the event on stdin; it reads only
// tool_input.file_path and cwd (https://code.claude.com/docs/en/hooks, "PostToolUse input"), and
// CLAUDE_PROJECT_DIR from its environment.
// The session's directory is CLAUDE_PROJECT_DIR when set, else cwd, since a session's cwd follows
// a Bash cd; a relative file_path is taken from cwd.
// It does nothing (no output, exit 0, no process started) unless the file's name ends in .rs, its
// real path lies under the session directory's real path and outside any directory named target,
// and some directory from the file's up to the session's directory holds a Cargo.toml with a
// [package] table: the nearest such is the package. A path inside the session's directory that
// resolves outside it is judged by where it resolves.
// It runs `cargo clippy --message-format=json --all-targets --offline` in the package's directory,
// cargo found on PATH, in a process group of its own, with the environment it was given plus, where
// unset, RUSTC_WRAPPER=sccache when sccache is on PATH and RUSTUP_AUTO_INSTALL=0, so it never
// reaches the network for a crate or a toolchain. It takes no --locked: the session may be
// changing a manifest.
// From cargo's JSON lines whose reason is compiler-message it takes each message.rendered whose
// level is error or warning and that has a primary span, once each (--all-targets checks a file
// once per target), split by whether that span is the edited file; a span's file_name is taken
// from the workspace's root, the nearest directory from the package's up that has a Cargo.toml with
// a [workspace] table, else the package's own, unless it is absolute.
// It prints, as the event's documented JSON output ("PostToolUse decision control",
// hookSpecificOutput with hookEventName "PostToolUse" and additionalContext):
//   - with findings in the edited file: `rust: <n> finding(s) in <path from the session's
//     directory> (cargo clippy)`, then their rendered text, cut at a line's end so the whole
//     context stays within 4,000 characters, with a line `rust: cut <n> more characters; tests/run
//     rust gives the rest`;
//   - with findings in other files: `rust: <n> finding(s) in other files of <package>; cargo clippy
//     -p <package> shows them`, after the file's own when there are both;
//   - on the deadline, after killing the process group: `rust: cargo clippy on <package> did not
//     finish in <s> s; run tests/run rust before delivering`;
//   - when cargo gives no finding and fails (no toolchain, a broken manifest, a dependency not
//     fetched, or only messages with no primary span): `rust: cargo clippy failed (exit <code>):
//     <line>`, the line being its stderr's first line starting with "error", else its first
//     non-empty one, cut at 300 characters; `signal <name>` in place of the exit for a signal, and
//     `could not start` with the reason when cargo did not start.
// A clean package prints nothing. It never blocks the edit: it always exits 0, never 2.
// The findings are a subset of tests/run rust, the rust-core skill's check, never a replacement.
//
// Environment:
//   CLAUDE_PROJECT_DIR            the session's directory, which Claude Code sets for a hook
//   RUST_DIAGNOSTICS_DEADLINE_MS  the deadline in milliseconds, in place of the default of 20 s
//                                 (hooks.json's timeout is the deadline plus 5 s); the test's
//                                 seam, never set by settings
import { spawn } from "node:child_process";
import { accessSync, constants, existsSync, readFileSync, realpathSync } from "node:fs";
import { delimiter, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

const defaultDeadlineMs = 20_000;
const cap = 4000;
// The most characters of cargo's own line.
const lineCap = 300;
// How long the output may take to drain once cargo has exited: a process it left running (an
// sccache server it started) may hold the pipes open.
const drainMs = 1000;

function give(text) {
  process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: text } })}\n`);
}

function short(line) {
  return line.length <= lineCap ? line : `${line.slice(0, lineCap)}... (${line.length - lineCap} characters cut)`;
}

function real(path) {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
}

// The path from base to path, or undefined when path is not under base.
function under(base, path) {
  const rel = relative(base, path);
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return undefined;
  return rel;
}

function manifest(dir) {
  try {
    return readFileSync(join(dir, "Cargo.toml"), "utf8");
  } catch {
    return undefined;
  }
}

const hasTable = (text, name) => new RegExp(`^\\s*\\[${name}\\]\\s*(#.*)?$`, "m").test(text);

// The nearest directory from the file's up to top whose Cargo.toml has a [package] table.
function nearestPackage(file, top) {
  for (let dir = dirname(file); ; dir = dirname(dir)) {
    const text = manifest(dir);
    if (text !== undefined && hasTable(text, "package")) return { dir, text };
    if (dir === top || dirname(dir) === dir) return undefined;
  }
}

// The workspace's root, as cargo finds it: the nearest directory from the package's up whose
// Cargo.toml has a [workspace] table, else the package's own.
function workspaceRoot(packageDir) {
  for (let dir = packageDir; ; dir = dirname(dir)) {
    const text = manifest(dir);
    if (text !== undefined && hasTable(text, "workspace")) return dir;
    if (dirname(dir) === dir) return packageDir;
  }
}

// The package's name from its [package] table, else its directory's.
function packageName(text, dir) {
  const table = text.split(/^\s*\[package\]\s*(?:#.*)?$/m)[1]?.split(/^\s*\[/m)[0] ?? "";
  return table.match(/^\s*name\s*=\s*"([^"]+)"/m)?.[1] ?? dir.split(sep).at(-1);
}

function onPath(name, env) {
  for (const dir of (env.PATH ?? "").split(delimiter)) {
    if (dir === "") continue;
    try {
      accessSync(join(dir, name), constants.X_OK);
      return true;
    } catch {
      // Not in this directory.
    }
  }
  return false;
}

const plural = (n) => `${n} finding${n === 1 ? "" : "s"}`;

// The compiler's findings in cargo's JSON lines, once each, split by whether their primary span is
// the file; undefined when there is none.
function findingsOf(stdout, file, root) {
  const own = [];
  const others = [];
  const seen = new Set();
  for (const line of stdout.split("\n")) {
    if (!line.startsWith("{")) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    if (record?.reason !== "compiler-message") continue;
    const message = record.message;
    if (message?.level !== "error" && message?.level !== "warning") continue;
    const span = Array.isArray(message.spans) ? message.spans.find((s) => s?.is_primary) : undefined;
    if (typeof span?.file_name !== "string" || typeof message.rendered !== "string") continue;
    const text = message.rendered.trimEnd();
    if (seen.has(text)) continue;
    seen.add(text);
    const path = isAbsolute(span.file_name) ? span.file_name : join(root, span.file_name);
    (real(path) === file ? own : others).push(text);
  }
  return own.length + others.length === 0 ? undefined : { own, others };
}

// The context for the findings: the file's own under their head, cut to the cap at a line's end,
// then the other files' line.
function report(shown, name, { own, others }) {
  const tail = others.length > 0 ? `${plural(others.length)} in other files of ${name}; cargo clippy -p ${name} shows them` : "";
  if (own.length === 0) return tail === "" ? undefined : `rust: ${tail}`;
  const head = `rust: ${plural(own.length)} in ${shown} (cargo clippy)`;
  const body = own.join("\n\n");
  const after = tail === "" ? "" : `\nrust: ${tail}`;
  if (head.length + 1 + body.length + after.length <= cap) return `${head}\n${body}${after}`;
  const cutLine = (n) => `rust: cut ${n} more characters; tests/run rust gives the rest`;
  // The longest start of the body, ending at a line's end, that leaves room for the cut line; the
  // cut line's length is taken at the body's whole length, the most it can be.
  const room = cap - head.length - 1 - 1 - cutLine(body.length).length - after.length;
  let end = body.lastIndexOf("\n", Math.max(room, 0));
  if (end < 0) end = Math.max(room, 0);
  const kept = body.slice(0, end).trimEnd();
  return `${head}\n${kept}\n${cutLine(body.length - kept.length)}${after}`;
}

function main() {
  let event;
  try {
    event = JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return;
  }
  const given = event?.tool_input?.file_path;
  if (typeof given !== "string" || !given.endsWith(".rs")) return;
  const cwd = real(typeof event.cwd === "string" && event.cwd !== "" ? event.cwd : process.cwd());
  const project = process.env.CLAUDE_PROJECT_DIR;
  const top = typeof project === "string" && project !== "" ? real(project) : cwd;
  const file = real(isAbsolute(given) ? given : resolve(cwd, given));
  const shown = under(top, file);
  if (shown === undefined || shown.split(sep).includes("target")) return;
  const pkg = nearestPackage(file, top);
  if (!pkg) return;
  const name = packageName(pkg.text, pkg.dir);
  const root = workspaceRoot(pkg.dir);

  const env = { ...process.env };
  if (env.RUSTC_WRAPPER === undefined && onPath("sccache", env)) env.RUSTC_WRAPPER = "sccache";
  if (env.RUSTUP_AUTO_INSTALL === undefined) env.RUSTUP_AUTO_INSTALL = "0";
  delete env.RUST_DIAGNOSTICS_DEADLINE_MS;

  const seam = Number(process.env.RUST_DIAGNOSTICS_DEADLINE_MS);
  const deadlineMs = Number.isFinite(seam) && seam > 0 ? seam : defaultDeadlineMs;
  const child = spawn("cargo", ["clippy", "--message-format=json", "--all-targets", "--offline"], {
    cwd: pkg.dir,
    env,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });

  let done = false;
  let drain;
  const finish = (text) => {
    if (done) return;
    done = true;
    clearTimeout(timer);
    clearTimeout(drain);
    if (text) give(text);
    process.exitCode = 0;
    // A process cargo left running may hold the pipes and keep node alive: end once written.
    process.stdout.write("", () => process.exit(0));
  };
  const timer = setTimeout(() => {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
      // The group is gone already.
    }
    finish(`rust: cargo clippy on ${name} did not finish in ${deadlineMs / 1000} s; run tests/run rust before delivering`);
  }, deadlineMs);

  const judge = (code, signal) => {
    const found = findingsOf(stdout, file, root);
    if (found) return finish(report(shown, name, found));
    if (code === 0) return finish();
    const lines = stderr.split(/\r?\n/).map((line) => line.trim()).filter((line) => line !== "");
    const first = lines.find((line) => line.startsWith("error")) ?? lines[0] ?? "no stderr";
    const how = signal ? `signal ${signal}` : `exit ${code}`;
    finish(`rust: cargo clippy failed (${how}): ${short(first)}`);
  };
  child.on("error", (error) => {
    finish(`rust: cargo clippy failed (could not start): ${short(error.message)}`);
  });
  child.on("exit", (code, signal) => {
    drain = setTimeout(() => judge(code, signal), drainMs);
    child.on("close", () => judge(code, signal));
  });
}

try {
  main();
} catch {
  process.exitCode = 0;
}
