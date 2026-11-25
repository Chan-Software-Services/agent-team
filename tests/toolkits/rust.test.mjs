// The rust toolkit as team-worker --toolkit rust loads it: its plugin layout (the manifest, its
// rust-analyzer language server declared inline as lspServers with exactly the keys and values the
// toolkit's README and spec give, its two hooks, and no MCP config), its README's "When the
// coordinator gives it", and its rust-core skill, the only skill of that name in any toolkit or the
// coordinator's plugin, whose description and size limits and order of sections the test holds,
// against the files alone.
// Its two hooks run as Claude Code runs a plugin's, with the event on stdin: the session-start hook
// in a copy of the toolkit beside a stub team-capacity, with stub sccache; the post-edit hook with
// stub cargo binaries, and with the real cargo on a copy of the fixture crate
// (tests/toolkits/fixtures/rust-crate/), whose lints and clippy.toml the test holds equal to the
// root's. The real-cargo cases need the toolchain rust-toolchain.toml pins: they skip, saying why,
// where cargo --version in the repository's root gives another, unless RUST_TOOLKIT_TESTS=require,
// which makes that skip a failure.
// Its four eval cases, against their files: each case's frontmatter and graders, each scaffold run as
// claude plugin eval runs one and copying the fixture with no cargo, the review case's diff applying
// to the fixture (git apply --check), and the lint case's quoted line in the scaffolded copy; with
// the pinned toolchain, that clippy gives the lint case's warning as its prompt quotes it and the
// wildcard finding on the review case's diff.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { accessSync, constants, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync,
  symlinkSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { describe, test } from "node:test";
import { repoRoot, tempDir, testPath } from "./helpers/mcp.mjs";

const toolkit = join(repoRoot, "toolkits", "rust");
const manifest = JSON.parse(readFileSync(join(toolkit, ".claude-plugin", "plugin.json"), "utf8"));
const skill = readFileSync(join(toolkit, "skills", "rust-core", "SKILL.md"), "utf8");
const readme = readFileSync(join(toolkit, "README.md"), "utf8");
const hooks = JSON.parse(readFileSync(join(toolkit, "hooks", "hooks.json"), "utf8"));
const fixture = join(repoRoot, "tests", "toolkits", "fixtures", "rust-crate");
const channel = readFileSync(join(repoRoot, "rust-toolchain.toml"), "utf8").match(/^channel = "(.*)"$/m)?.[1];

// The language server Claude Code starts for a session that lists the toolkit: navigation only, its
// pushed diagnostics off and no cargo check of its own, its cargo calls held to two jobs. The config
// object is strict, an unknown key failing the plugin's load, so the keys are held exactly.
const languageServer = {
  "rust-analyzer": {
    command: "rust-analyzer",
    extensionToLanguage: { ".rs": "rust" },
    diagnostics: false,
    startupTimeout: 60000,
    env: { CARGO_BUILD_JOBS: "2", RUSTC_WRAPPER: "sccache" },
    initializationOptions: { checkOnSave: false },
  },
};

// The keys of one server's config in the schema of Claude Code 2.1.330's binary, read on 2026-11-23.
const knownKeys = ["command", "args", "extensionToLanguage", "transport", "env", "initializationOptions", "settings",
  "workspaceFolder", "startupTimeout", "shutdownTimeout", "requestTimeout", "restartOnCrash", "maxRestarts", "diagnostics"];

describe("the rust toolkit", () => {
  test("is a plugin named rust by Daniel Chan, with rust-analyzer as its language server and no MCP config", () => {
    assert.deepEqual(Object.keys(manifest).sort(), ["author", "description", "lspServers", "name", "version"]);
    assert.equal(manifest.name, "rust");
    assert.equal(manifest.version, "0.1.0");
    assert.deepEqual(manifest.author, { name: "Daniel Chan" });
    assert.match(manifest.description, /^For the planner, builder and reviewer of a task that writes Rust in agent-team's Cargo workspace: the rust-core skill/);
    assert.deepEqual(manifest.lspServers, languageServer);
    for (const key of Object.keys(manifest.lspServers["rust-analyzer"])) {
      assert.ok(knownKeys.includes(key), `${key} is no key of a language server's config`);
    }
    assert.ok(!existsSync(join(toolkit, ".mcp.json")), "the toolkit has an MCP config");
    assert.ok(!existsSync(join(toolkit, "mcp-roles.json")), "the toolkit has an mcp-roles.json");
    assert.ok(!existsSync(join(toolkit, ".lsp.json")), "the language server is declared twice");
    assert.deepEqual(readdirSync(join(toolkit, "skills")), ["rust-core"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills", "rust-core")), ["SKILL.md"]);
  });

  // The session-start hook sets cargo's jobs and wrapper and prints the banner; the post-edit hook
  // gives clippy's findings, its timeout the 20 s deadline plus 5 s.
  test("has one SessionStart hook, rust-session, and one PostToolUse hook on edits, rust-diagnostics.mjs", () => {
    assert.deepEqual(Object.keys(hooks).sort(), ["description", "hooks"]);
    assert.match(hooks.description, /^At session start/);
    assert.deepEqual(Object.keys(hooks.hooks), ["SessionStart", "PostToolUse"]);
    assert.deepEqual(hooks.hooks.SessionStart, [{ hooks: [{
      type: "command",
      command: '"${CLAUDE_PLUGIN_ROOT}/scripts/rust-session"',
      timeout: 10,
    }] }]);
    assert.deepEqual(hooks.hooks.PostToolUse, [{ matcher: "Edit|Write|MultiEdit", hooks: [{
      type: "command",
      command: 'node "${CLAUDE_PLUGIN_ROOT}/scripts/rust-diagnostics.mjs"',
      timeout: 25,
    }] }]);
    assert.deepEqual(readdirSync(join(toolkit, "hooks")), ["hooks.json"]);
    assert.deepEqual(readdirSync(join(toolkit, "scripts")).sort(), ["rust-diagnostics.mjs", "rust-session"]);
    accessSync(join(toolkit, "scripts", "rust-session"), constants.X_OK);
    assert.match(manifest.description, /session-start hook/);
    assert.match(manifest.description, /post-edit hook/);
  });

  // rustup's rust-analyzer proxy runs the pinned toolchain's, which it has only as a component.
  test("its language server is a component of the toolchain rust-toolchain.toml pins", () => {
    const toml = readFileSync(join(repoRoot, "rust-toolchain.toml"), "utf8");
    const components = toml.match(/^components = \[(.*)\]$/m)?.[1] ?? "";
    assert.match(components, /"rust-analyzer"/);
    assert.match(components, /"rust-src"/);
  });

  test("its README says when the coordinator gives it, and has the spec's sections in order", () => {
    const sections = ["## When the coordinator gives it", "## What loads", "## What it costs",
      "## The build cache", "## Confinement roots", "## Tests"];
    const at = sections.map((section) => readme.search(new RegExp(`^${section}$`, "m")));
    sections.forEach((section, i) => assert.ok(at[i] >= 0, `the README has no "${section}"`));
    assert.deepEqual([...at].sort((a, b) => a - b), at, "the README's sections are out of order");
    const when = readme.split("## When the coordinator gives it\n")[1].split("\n## ")[0];
    assert.match(when, /--toolkit rust/);
    for (const role of ["planner", "builder", "reviewer"]) assert.match(when, new RegExp(role));
    assert.match(when, /`toolkits`/);
    assert.match(when, /team-load-check --toolkit rust/);
    assert.match(when, /team-load-check --context --toolkit rust/);
  });

  test("its README describes both hooks as built, and its tests", () => {
    const section = (name) => readme.split(`## ${name}\n`)[1].split("\n## ")[0];
    const loads = section("What loads");
    for (const part of ["scripts/rust-session", "scripts/rust-diagnostics.mjs", "`CLAUDE_ENV_FILE`", "CARGO_BUILD_JOBS",
      "NEXTEST_TEST_THREADS", "`RUSTC_WRAPPER=sccache`", "20 s", "4,000 characters", "`RUST_DIAGNOSTICS_DEADLINE_MS`"]) {
      assert.ok(loads.includes(part), `"What loads" does not name ${part}`);
    }
    assert.match(section("What it costs"), /4,000 characters/);
    const tests = section("Tests");
    for (const part of ["`RUST_TOOLKIT_TESTS=require`", "tests/toolkits/fixtures/rust-crate/", "stub"]) {
      assert.ok(tests.includes(part), `"Tests" does not name ${part}`);
    }
    for (const name of ["add-an-event-kind", "review-a-diff-with-a-missed-case", "fix-a-lint", "python-question"]) {
      assert.ok(tests.includes(`\`${name}\``), `"Tests" does not name the eval case ${name}`);
    }
    const runs = [...readme.matchAll(/`(claude plugin eval [^`]*)`/g)].map(([, run]) => run);
    assert.ok(runs.length > 0, "the README names no eval run");
    for (const run of runs) assert.match(run, /--no-publish/, `${run} would publish its report`);
    assert.ok(tests.includes("`claude plugin eval --no-publish --scaffold --trust-plugin toolkits/rust`"), "the README names no eval command");
  });

  test("its README gives each cost its live measure and holds the build cache's and the confinement roots' rules", () => {
    const section = (name) => readme.split(`## ${name}\n`)[1].split("\n## ")[0];
    assert.doesNotMatch(readme, /not measured|not yet proven|not yet checked/i);
    const costs = section("What it costs");
    for (const part of ["`LSP`", "rust-analyzer", "MB", "sccache server", "cold", "warm"]) {
      assert.ok(costs.includes(part), `"What it costs" does not name ${part}`);
    }
    const cache = section("The build cache");
    assert.match(cache, /hits/);
    assert.match(cache, /~\/\.cache\/sccache/);
    assert.match(cache, /`target\/`/);
    assert.match(cache, /5 minutes/);
    assert.match(cache, /4 GiB/);
    assert.match(cache, /team-heavy/);
    const roots = section("Confinement roots");
    for (const path of ["`~/.cargo`", "`~/.cargo/advisory-dbs/`", "`~/.cache/sccache`", "`~/.local/state/agent-team`",
      "`~/.rustup`", "`RUSTUP_AUTO_INSTALL=0`", "`bin/lib/confine-roots`"]) {
      assert.ok(roots.includes(path), `"Confinement roots" does not name ${path}`);
    }
  });
});

const frontmatter = skill.match(/^---\n([\s\S]*?)\n---\n/)?.[1] ?? "";
const field = (name) => frontmatter.match(new RegExp(`^${name}: (.*)$`, "m"))?.[1];
const section = (heading) => skill.split(`\n${heading}\n`)[1]?.split("\n## ")[0] ?? "";

describe("the rust-core skill", () => {
  test("is named rust-core, its description under 250 characters and its whole file under 8 kB", () => {
    assert.deepEqual(frontmatter.split("\n").map((line) => line.split(":")[0]), ["name", "description"]);
    assert.equal(field("name"), "rust-core");
    const description = field("description");
    assert.ok(description, "the skill has no description");
    assert.ok(description.length < 250, `its description is ${description.length} characters`);
    assert.match(description, /writing, reviewing or planning Rust/);
    assert.match(description, /Cargo workspace/);
    const size = Buffer.byteLength(skill);
    assert.ok(size < 8192, `the skill is ${size} bytes`);
  });

  // A skill of the same name in another plugin a session loads would bring the skill to a session
  // without the rust toolkit.
  test("is the only skill named rust-core in any toolkit or the coordinator's plugin", () => {
    const named = [];
    for (const root of [join(repoRoot, "toolkits"), join(repoRoot, "plugins")]) {
      for (const plugin of readdirSync(root)) {
        const skills = join(root, plugin, "skills");
        if (!existsSync(skills)) continue;
        for (const dir of readdirSync(skills)) {
          const text = readFileSync(join(skills, dir, "SKILL.md"), "utf8");
          if (dir === "rust-core" || /^name: rust-core$/m.test(text)) named.push(`${plugin}/${dir}`);
        }
      }
    }
    assert.deepEqual(named, ["rust/rust-core"]);
  });

  test("has the spec's six sections, in order", () => {
    const headings = [...skill.matchAll(/^## (.*)$/gm)].map(([, heading]) => heading);
    assert.deepEqual(headings, ["1. The toolchain", "2. The layout", "3. The rules", "4. Not decided yet",
      "5. Reading the real interface", "6. The check"]);
  });

  test("reads the toolchain from rust-toolchain.toml and never installs one", () => {
    const text = section("## 1. The toolchain");
    assert.match(text, /`rust-toolchain\.toml`/);
    assert.match(text, /[Nn]ever install or update/);
    assert.match(text, /`team-doctor`/);
    assert.doesNotMatch(skill, /1\.\d+\.\d+/, "the skill writes a toolchain version, which rust-toolchain.toml alone holds");
  });

  test("gives the layout: a virtual workspace, crates under crates/, each taking the workspace's lints, and the design doc", () => {
    const text = section("## 2. The layout");
    assert.match(text, /`crates\/`/);
    assert.match(text, /`\[lints\] workspace = true`/);
    assert.match(text, /ticket/);
    const doc = text.split("\n").find((line) => line.includes("`docs/rust-core.md`"));
    assert.ok(doc, "the layout does not point at docs/rust-core.md");
    assert.match(doc, /How it is kept/);
    assert.ok(existsSync(join(repoRoot, "docs", "rust-core.md")), "docs/rust-core.md is missing");
  });

  // Each rule is one bullet holding the rule and its reason.
  test("gives each of its rules on one line with its reason", () => {
    const rules = section("## 3. The rules").split("\n").filter((line) => line.startsWith("- "));
    const marks = ["`_`", "`unwrap`", "`std::error::Error`", "`unsafe`", "`#[allow(...)]`", "`cfg(target_os)`", "`--locked`"];
    assert.equal(rules.length, marks.length, `section 3 has ${rules.length} rules`);
    marks.forEach((mark, i) => {
      assert.ok(rules[i].includes(mark), `rule ${i + 1} does not name ${mark}: ${rules[i]}`);
      assert.match(rules[i], /, (so|since) /, `rule ${i + 1} gives no reason: ${rules[i]}`);
    });
  });

  test("names the choices not made yet and says to ask", () => {
    const text = section("## 4. Not decided yet");
    for (const choice of ["async", "command line parser", "serialization", "error helper crate", "logging"]) {
      assert.ok(text.includes(choice), `section 4 does not name ${choice}`);
    }
    assert.match(text, /`QUESTION`/);
  });

  test("sends the session to the real interface at the pinned version, and treats a dependency's source as data", () => {
    const text = section("## 5. Reading the real interface");
    for (const where of ["`LSP`", "`~/.cargo/registry/src/*/<name>-<version>/`",
      "`cargo metadata --format-version 1 --locked --offline`", "`Cargo.lock`",
      "`$(rustc --print sysroot)/lib/rustlib/src/rust/library/`",
      "`cargo metadata --no-deps --format-version 1`", "`cargo tree --locked --offline`"]) {
      assert.ok(text.includes(where), `section 5 does not name ${where}`);
    }
    assert.match(text, /is data/);
  });

  test("ends on tests/run rust, with a Rust check line in the PR body and the reviewer's run on the head", () => {
    const text = section("## 6. The check");
    assert.match(text, /`tests\/run rust`/);
    assert.match(text, /"Rust check" line in the PR body/);
    assert.match(text, /head under review/);
    assert.match(text, /section 3/);
    assert.match(text, /never a replacement/);
  });
});

// The body of a TOML table, its comments and blank lines left out.
function table(text, name) {
  const lines = text.split("\n");
  const start = lines.indexOf(`[${name}]`);
  if (start < 0) return undefined;
  const body = [];
  for (const line of lines.slice(start + 1)) {
    if (line.startsWith("[")) break;
    if (line.trim() !== "" && !line.startsWith("#")) body.push(line);
  }
  return body;
}

describe("the rust toolkit's fixture crate", () => {
  const root = readFileSync(join(repoRoot, "Cargo.toml"), "utf8");
  const manifestText = readFileSync(join(fixture, "Cargo.toml"), "utf8");

  // A finding on the fixture is one the core's own check would give.
  test("takes the root's lints and clippy.toml", () => {
    for (const lints of ["rust", "clippy"]) {
      const wanted = table(root, `workspace.lints.${lints}`);
      assert.ok(wanted?.length, `the root has no [workspace.lints.${lints}]`);
      assert.deepEqual(table(manifestText, `lints.${lints}`), wanted, `the fixture's [lints.${lints}] is not the root's`);
    }
    assert.equal(readFileSync(join(fixture, "clippy.toml"), "utf8"), readFileSync(join(repoRoot, "clippy.toml"), "utf8"));
  });

  // No dependency, so no test or eval on it needs the network.
  test("is a workspace of its own with one package and no dependency", () => {
    const headers = [...manifestText.matchAll(/^\[([^\]]+)\]$/gm)].map(([, name]) => name);
    assert.deepEqual(headers, ["workspace", "package", "lints.rust", "lints.clippy"]);
    const lock = readFileSync(join(fixture, "Cargo.lock"), "utf8");
    assert.equal([...lock.matchAll(/^\[\[package\]\]$/gm)].length, 1, lock);
    assert.match(lock, /^name = "kind-fixture"$/m);
    assert.deepEqual(readdirSync(fixture).sort(), ["Cargo.lock", "Cargo.toml", "clippy.toml", "src"]);
  });

  // The evals add a variant to Kind and judge each match on it.
  test("has Kind's three variants, three functions matching on every one, a Result function and tests", () => {
    const source = readFileSync(join(fixture, "src", "kind.rs"), "utf8");
    assert.match(source, /^pub enum Kind \{\n {4}Opened,\n {4}Closed,\n {4}Parked,\n\}$/m);
    for (const signature of ["pub fn label(kind: Kind) -> &'static str {", "pub fn is_terminal(kind: Kind) -> bool {",
      "pub fn next(kind: Kind) -> Option<Kind> {"]) {
      const body = source.split(signature)[1]?.split("\n}\n")[0];
      assert.ok(body, `the fixture has no ${signature}`);
      for (const variant of ["Opened", "Closed", "Parked"]) assert.match(body, new RegExp(`Kind::${variant} =>`), signature);
      assert.doesNotMatch(body, /\b_ =>/, signature);
    }
    assert.match(source, /-> Result<Kind, ParseKindError>/);
    assert.match(source, /^impl Error for ParseKindError \{\}$/m);
    assert.match(source, /^#\[cfg\(test\)\]$/m);
  });
});

// The eval cases claude plugin eval runs: three that read a copy of the fixture its scaffold makes and
// fire the skill, graded on the answer, and one Python question that must not fire it.
const evals = join(toolkit, "evals");
const fixtureCases = ["add-an-event-kind", "fix-a-lint", "review-a-diff-with-a-missed-case"];
const evalFile = (name, ...path) => readFileSync(join(evals, name, ...path), "utf8");
const promptBody = (name) => evalFile(name, "prompt.md").split(/^---$/m)[2] ?? "";
// The fenced block of the given language in a case's prompt.
const fenced = (name, language) => promptBody(name).match(new RegExp("^```" + language + "\\n([\\s\\S]*?)^```$", "m"))?.[1];
// The lint case's quoted line, by its location in clippy's warning and its source line.
const lintQuote = () => {
  const warning = fenced("fix-a-lint", "text") ?? "";
  const [, file, line] = warning.match(/^ {2}--> (\S+):(\d+):\d+$/m) ?? [];
  const source = warning.match(new RegExp(`^${line} \\| (.*)$`, "m"))?.[1];
  return { warning, file, line: Number(line), source };
};

// Every file under a directory, by its path from it, with its text.
function tree(dir, from = dir) {
  const files = {};
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) Object.assign(files, tree(path, from));
    else files[path.slice(from.length + 1)] = readFileSync(path, "utf8");
  }
  return files;
}

// A case's scaffold run as claude plugin eval runs one: bash on its real path, in an empty
// directory, with only PATH, HOME and TMPDIR; a stub cargo first on PATH logs any call.
function scaffold(name) {
  const cwd = realpathSync(tempDir("eval-run"));
  const log = join(tempDir("cargo-log"), "calls");
  const bin = stubs({ cargo: `echo "$*" >>"${log}"; exit 1` });
  const run = spawnSync("bash", [join(evals, name, "scaffold.sh")], {
    cwd,
    encoding: "utf8",
    env: { PATH: `${bin}${delimiter}${testPath({ withOp: false })}`, HOME: tempDir("eval-home"), TMPDIR: tempDir("eval-tmp") },
  });
  assert.equal(run.status, 0, run.stderr);
  assert.ok(!existsSync(log), `the ${name} scaffold ran cargo`);
  return cwd;
}

describe("the rust toolkit's evals", () => {
  test("are four cases, three reading the fixture through a case.yaml and its scaffold, and a Python question", () => {
    assert.deepEqual(readdirSync(evals).filter((name) => name !== "results").sort(),
      ["add-an-event-kind", "fix-a-lint", "python-question", "review-a-diff-with-a-missed-case"]);
    for (const name of fixtureCases) {
      assert.deepEqual(readdirSync(join(evals, name)).sort(), ["case.yaml", "graders", "prompt.md", "scaffold.sh"], name);
      assert.equal(evalFile(name, "case.yaml"), `schema_version: "1.1"\nname: ${name}\ncontext:\n  scaffold_script: scaffold.sh\n`);
    }
    assert.deepEqual(readdirSync(join(evals, "python-question")).sort(), ["graders", "prompt.md"]);
  });

  test("each run Opus for 15 turns in 600 s with Read, Glob, Grep and Skill alone", () => {
    for (const name of [...fixtureCases, "python-question"]) {
      const front = evalFile(name, "prompt.md").match(/^---\n([\s\S]*?)\n---\n/)?.[1];
      assert.ok(front, `${name}'s prompt.md has no frontmatter`);
      const keys = [...front.matchAll(/^(\w+):/gm)].map(([, key]) => key);
      assert.deepEqual(keys, ["description", "tags", "model", "max_turns", "timeout_seconds", "allowed_tools"], name);
      assert.match(front, /^tags: \[rust\]$/m, name);
      assert.match(front, /^model: claude-opus-5-5$/m, name);
      assert.match(front, /^max_turns: 15$/m, name);
      assert.match(front, /^timeout_seconds: 600$/m, name);
      assert.match(front, /^allowed_tools: \[Read, Glob, Grep, Skill\]$/m, name);
      assert.ok(promptBody(name).trim(), `${name}'s prompt.md has no prompt`);
    }
  });

  test("fire the skill and grade the answer on the fixture, and leave the skill alone on a Python question", () => {
    const skillMatch = `input_match: '"skill"\\s*:\\s*"(?:[\\w-]+:)?rust-core"'`;
    for (const name of fixtureCases) {
      assert.deepEqual(readdirSync(join(evals, name, "graders")).sort(), ["answer.md", "skill-fired.md"], name);
      assert.equal(evalFile(name, "graders", "skill-fired.md"), `---\ntype: tool_used\ntool: Skill\n${skillMatch}\n---\n`);
      const answer = evalFile(name, "graders", "answer.md");
      assert.match(answer, /^---\ntype: llm\n---\n\nPASS if .+\n(?:.+\n)*FAIL if .+\n$/, name);
    }
    assert.deepEqual(readdirSync(join(evals, "python-question", "graders")), ["skill-not-fired.md"]);
    assert.equal(evalFile("python-question", "graders", "skill-not-fired.md"),
      `---\ntype: tool_used\ntool: Skill\n${skillMatch}\nmin: 0\nmax: 0\n---\n`);
    assert.match(promptBody("python-question"), /list comprehension/);
    assert.doesNotMatch(promptBody("python-question"), /\bRust\b|\bcargo\b/i);
  });

  // The answer graders name what each case is about: every match on Kind, the wildcard arm, the unwrap.
  test("grade adding a variant on every match on Kind, the review on the wildcard arm, and the lint fix on no unwrap", () => {
    const add = evalFile("add-an-event-kind", "graders", "answer.md");
    for (const name of ["`label`", "`is_terminal`", "`next`", "`Reopened`", "`_`", "`unwrap`", "dependency"]) assert.ok(add.includes(name), name);
    assert.match(promptBody("add-an-event-kind"), /`Reopened`/);
    assert.match(promptBody("add-an-event-kind"), /change no files/);
    const review = evalFile("review-a-diff-with-a-missed-case", "graders", "answer.md");
    assert.match(review, /`_ => false`/);
    assert.match(review, /`is_terminal`/);
    assert.match(review, /approves/);
    const lint = evalFile("fix-a-lint", "graders", "answer.md");
    for (const name of ["Result", "#[allow(...)]", "expect", "test"]) assert.ok(lint.includes(name), name);
  });

  test("scaffold a copy of the fixture with no cargo, the lint case adding one function on its quoted line", () => {
    const want = tree(fixture);
    for (const name of ["add-an-event-kind", "review-a-diff-with-a-missed-case"]) assert.deepEqual(tree(scaffold(name)), want, name);
    const lint = tree(scaffold("fix-a-lint"));
    const { file, line, source } = lintQuote();
    assert.equal(file, "src/lib.rs");
    assert.deepEqual({ ...lint, [file]: undefined }, { ...want, [file]: undefined });
    assert.ok(lint[file].startsWith(want[file]), "the lint case's scaffold changes the fixture's src/lib.rs");
    assert.equal(lint[file].split("\n")[line - 1], source, `src/lib.rs:${line} is not the line the prompt quotes`);
    assert.match(source, /\.unwrap\(\)/);
    assert.doesNotMatch(lint[file], /#\[cfg\(test\)\]/, "the quoted line could be test code");
    assert.ok(promptBody("fix-a-lint").includes(`\`${source.trim()}\``), "the prompt does not quote the line");
  });

  test("give the review a diff that applies to the fixture, handling Reopened in two functions and adding _ => false to is_terminal", () => {
    const diff = fenced("review-a-diff-with-a-missed-case", "diff");
    assert.ok(diff, "the review case's prompt has no diff");
    const copy = realpathSync(tempDir("review-copy"));
    cpSync(fixture, copy, { recursive: true });
    const check = spawnSync("git", ["apply", "--check", "-"], { cwd: copy, input: diff, encoding: "utf8" });
    assert.equal(check.status, 0, check.stderr);
    assert.match(diff, /^\+ {4}Reopened,$/m);
    assert.match(diff, /^\+ {8}Kind::Reopened => "reopened",$/m);
    assert.match(diff, /^\+ {8}Kind::Reopened => Some\(Kind::Opened\),$/m);
    assert.match(diff, /^@@ .* @@ pub fn is_terminal\(kind: Kind\) -> bool \{\n(?: .*\n)*\+ {8}_ => false,$/m);
    assert.equal([...diff.matchAll(/^\+.*\b_ =>/gm)].length, 1);
  });
});

// Links to every command of the test PATH but those named, so a test can run with no sccache or no
// cargo whatever the machine has (Arch has /usr/bin/cargo).
const pathsWithout = new Map();
function pathWithout(...names) {
  const key = names.join(" ");
  if (!pathsWithout.has(key)) {
    const dir = tempDir("path-without");
    const linked = new Set(names);
    for (const from of testPath({ withOp: false }).split(delimiter)) {
      let entries;
      try {
        entries = readdirSync(from);
      } catch {
        continue;
      }
      for (const name of entries) {
        if (linked.has(name)) continue;
        linked.add(name);
        symlinkSync(join(from, name), join(dir, name));
      }
    }
    pathsWithout.set(key, dir);
  }
  return pathsWithout.get(key);
}

// A directory of stub commands, each the shell script given.
function stubs(scripts) {
  const dir = realpathSync(tempDir("stubs"));
  for (const [name, script] of Object.entries(scripts)) {
    writeFileSync(join(dir, name), `#!/bin/sh\n${script}\n`, { mode: 0o755 });
  }
  return dir;
}

const sessionCommand = hooks.hooks.SessionStart[0].hooks[0].command;
const banner = (jobs, sccache) => `rust: toolchain 1.100.0; cargo jobs ${jobs}; sccache ${sccache}; end on tests/run rust (skill rust-core)`;

// A copy of the toolkit in a checkout of its own, whose bin/team-capacity is the script given, or
// none; the hook reads team-capacity from the checkout it lies in.
function checkout(capacity) {
  const dir = realpathSync(tempDir("checkout"));
  cpSync(toolkit, join(dir, "toolkits", "rust"), { recursive: true });
  mkdirSync(join(dir, "bin"));
  if (capacity !== undefined) writeFileSync(join(dir, "bin", "team-capacity"), `#!/bin/sh\n${capacity}\n`, { mode: 0o755 });
  return dir;
}

// A worktree with the files named, rust-toolchain.toml pinning 1.100.0.
function worktree(files = ["Cargo.toml", "rust-toolchain.toml"]) {
  const dir = realpathSync(tempDir("worktree"));
  for (const file of files) {
    writeFileSync(join(dir, file), file === "rust-toolchain.toml" ? '[toolchain]\nchannel = "1.100.0"\n' : "[workspace]\n");
  }
  return dir;
}

// The session-start hook in cwd, as Claude Code runs it: its exit code, stdout, stderr, and the
// env file's text (undefined when the file was never written).
function runSession({ cwd, root = checkout('echo 7'), env = {}, path = pathWithout("sccache"), envFile = true }) {
  const file = join(realpathSync(tempDir("env-file")), "env");
  const event = { session_id: "5be0c1a2-0000-4000-8000-000000000000", hook_event_name: "SessionStart", source: "startup", cwd };
  const run = spawnSync("sh", ["-c", sessionCommand], {
    cwd,
    encoding: "utf8",
    input: JSON.stringify(event),
    env: { HOME: cwd, PATH: path, CLAUDE_PLUGIN_ROOT: join(root, "toolkits", "rust"), ...(envFile ? { CLAUDE_ENV_FILE: file } : {}), ...env },
    timeout: 30_000,
  });
  return { status: run.status, stdout: run.stdout, stderr: run.stderr, envFile: existsSync(file) ? readFileSync(file, "utf8") : undefined };
}

describe("the rust toolkit's session-start hook", () => {
  test("in a worktree with Cargo.toml and rust-toolchain.toml, exports team-capacity's jobs and prints the banner", () => {
    const run = runSession({ cwd: worktree() });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stdout, `${banner(7, "off")}\n`);
    assert.equal(run.envFile, "export CARGO_BUILD_JOBS=7\nexport NEXTEST_TEST_THREADS=7\n");
  });

  test("takes TEAM_JOBS over team-capacity", () => {
    const root = checkout('echo called >"$(dirname "$0")/called"; echo 7');
    const run = runSession({ cwd: worktree(), root, env: { TEAM_JOBS: "3" } });
    assert.equal(run.stdout, `${banner(3, "off")}\n`);
    assert.equal(run.envFile, "export CARGO_BUILD_JOBS=3\nexport NEXTEST_TEST_THREADS=3\n");
    assert.ok(!existsSync(join(root, "bin", "called")), "the hook ran team-capacity with TEAM_JOBS set");
  });

  test("exports RUSTC_WRAPPER=sccache when sccache is on PATH", () => {
    const path = `${stubs({ sccache: "exit 0" })}${delimiter}${pathWithout("sccache")}`;
    const run = runSession({ cwd: worktree(), path });
    assert.equal(run.stdout, `${banner(7, "on")}\n`);
    assert.equal(run.envFile, "export CARGO_BUILD_JOBS=7\nexport NEXTEST_TEST_THREADS=7\nexport RUSTC_WRAPPER=sccache\n");
  });

  // A failure of team-capacity is the same as no number: cargo keeps its default.
  test("writes no jobs line when neither TEAM_JOBS nor team-capacity gives a whole number above 0", () => {
    const cases = [
      { root: checkout("exit 1") },
      { root: checkout("echo 0") },
      { root: checkout("echo lots") },
      { root: checkout("echo 4; exit 2") },
      { root: checkout() },
      { root: checkout("echo 7"), env: { TEAM_JOBS: "none" } },
      { root: checkout("echo 7"), env: { TEAM_JOBS: "0" } },
    ];
    for (const { root, env } of cases) {
      const run = runSession({ cwd: worktree(), root, env });
      assert.equal(run.status, 0, run.stderr);
      assert.equal(run.stdout, `${banner("default", "off")}\n`, JSON.stringify(env));
      assert.ok(!run.envFile, `the env file holds ${run.envFile}`);
    }
    const path = `${stubs({ sccache: "exit 0" })}${delimiter}${pathWithout("sccache")}`;
    const run = runSession({ cwd: worktree(), root: checkout("exit 1"), path });
    assert.equal(run.envFile, "export RUSTC_WRAPPER=sccache\n");
  });

  test("appends to the env file another hook wrote, and prints the banner with no env file", () => {
    const cwd = worktree();
    const file = join(realpathSync(tempDir("env-file")), "env");
    writeFileSync(file, "export OTHER=1\n");
    const run = runSession({ cwd, env: { CLAUDE_ENV_FILE: file } });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(readFileSync(file, "utf8"), "export OTHER=1\nexport CARGO_BUILD_JOBS=7\nexport NEXTEST_TEST_THREADS=7\n");
    const bare = runSession({ cwd, envFile: false });
    assert.equal(bare.status, 0, bare.stderr);
    assert.equal(bare.stdout, `${banner(7, "off")}\n`);
  });

  test("prints and writes nothing in a directory without Cargo.toml or rust-toolchain.toml", () => {
    const path = `${stubs({ sccache: "exit 0" })}${delimiter}${pathWithout("sccache")}`;
    for (const files of [[], ["Cargo.toml"], ["rust-toolchain.toml"]]) {
      const run = runSession({ cwd: worktree(files), path });
      assert.equal(run.status, 0, run.stderr);
      assert.equal(run.stdout, "", files.join(" "));
      assert.equal(run.envFile, undefined, files.join(" "));
    }
  });

  // The event's cwd is the session's, whatever directory Claude Code runs the hook in.
  test("judges the event's cwd, and exits 0 on an event it cannot read", () => {
    const run = runSession({ cwd: worktree() });
    assert.equal(run.status, 0);
    const odd = spawnSync("sh", ["-c", sessionCommand], {
      cwd: worktree([]),
      encoding: "utf8",
      input: "not json",
      env: { HOME: "/nonexistent", PATH: pathWithout("sccache"), CLAUDE_PLUGIN_ROOT: join(checkout("echo 7"), "toolkits", "rust") },
    });
    assert.equal(odd.status, 0, odd.stderr);
    assert.equal(odd.stdout, "");
  });
});

const editCommand = hooks.hooks.PostToolUse[0].hooks[0].command;

// A workspace at cwd with one package, demo, under crates/demo, and src/lib.rs and src/other.rs in
// it; and a stub cargo that logs its directory, arguments and environment, then prints the file
// out.jsonl beside it, then runs the shell given. STUB is the stubs' directory.
function stubbedWorkspace(script = "") {
  const cwd = realpathSync(tempDir("rust-stub"));
  writeFileSync(join(cwd, "Cargo.toml"), '[workspace]\nmembers = ["crates/*"]\n');
  const demo = join(cwd, "crates", "demo");
  mkdirSync(join(demo, "src"), { recursive: true });
  writeFileSync(join(demo, "Cargo.toml"), '[package]\nname = "demo"\nversion = "0.1.0"\n');
  for (const file of ["lib.rs", "other.rs"]) writeFileSync(join(demo, "src", file), "pub fn x() {}\n");
  const bin = stubs({
    cargo: [
      'pwd >"$STUB/pwd"',
      'printf "%s\\n" "$@" >"$STUB/args"',
      'echo "RUSTC_WRAPPER=${RUSTC_WRAPPER-unset} RUSTUP_AUTO_INSTALL=${RUSTUP_AUTO_INSTALL-unset}" >"$STUB/env"',
      'if [ -f "$STUB/out.jsonl" ]; then cat "$STUB/out.jsonl"; fi',
      script,
    ].join("\n"),
  });
  return { cwd, demo, bin };
}

// One line of cargo's JSON: a compiler message of the level given whose primary span is in file
// (relative to the workspace's root, as rustc is given it), rendered as the text given.
function message({ file, level = "warning", rendered, spans = true }) {
  return JSON.stringify({
    reason: "compiler-message",
    package_id: "path+file:///w/crates/demo#0.1.0",
    manifest_path: "/w/crates/demo/Cargo.toml",
    target: { kind: ["lib"], name: "demo" },
    message: {
      rendered,
      level,
      message: rendered.split("\n")[0],
      spans: spans ? [{ file_name: file, is_primary: true, line_start: 1, line_end: 1 }] : [],
      children: [],
    },
  });
}

function writeOut(bin, lines) {
  writeFileSync(join(bin, "out.jsonl"), `${lines.join("\n")}\n`);
}

// The post-edit hook on an edit of file in a session whose cwd is cwd, as Claude Code runs it.
function runEdit({ cwd, file, tool = "Edit", env = {}, path }) {
  const event = {
    session_id: "5be0c1a2-0000-4000-8000-000000000000",
    hook_event_name: "PostToolUse",
    cwd,
    tool_name: tool,
    tool_input: { file_path: file, old_string: "a", new_string: "b" },
    tool_response: { filePath: file },
  };
  const started = Date.now();
  const run = spawnSync("sh", ["-c", editCommand], {
    cwd,
    encoding: "utf8",
    input: JSON.stringify(event),
    env: { HOME: cwd, PATH: path, CLAUDE_PLUGIN_ROOT: toolkit, ...env },
    timeout: 60_000,
  });
  return { status: run.status, stdout: run.stdout, stderr: run.stderr, ms: Date.now() - started };
}

// The post-edit hook with the stub workspace's cargo first on PATH and no sccache.
function runStubbed({ bin }, { env = {}, ...rest }) {
  return runEdit({ ...rest, path: `${bin}${delimiter}${pathWithout("sccache", "cargo")}`, env: { STUB: bin, ...env } });
}

// The hook's additional context, after checking its output is the documented JSON shape.
function context(run) {
  assert.equal(run.status, 0, run.stderr);
  const out = JSON.parse(run.stdout);
  assert.deepEqual(Object.keys(out), ["hookSpecificOutput"]);
  assert.equal(out.hookSpecificOutput.hookEventName, "PostToolUse");
  assert.equal(typeof out.hookSpecificOutput.additionalContext, "string");
  return out.hookSpecificOutput.additionalContext;
}

function silent(run) {
  assert.equal(run.status, 0, run.stderr);
  assert.equal(run.stdout, "");
}

// Whether a process group is gone within ms: a member killed with SIGKILL still answers a signal
// until whoever it was reparented to reaps it, which on a loaded machine takes a moment.
function goneWithin(group, ms) {
  const alive = () => {
    try {
      process.kill(-group, 0);
      return true;
    } catch (error) {
      if (error.code === "ESRCH") return false;
      throw error;
    }
  };
  const pause = new Int32Array(new SharedArrayBuffer(4));
  const end = Date.now() + ms;
  while (alive()) {
    if (Date.now() >= end) return false;
    Atomics.wait(pause, 0, 0, 20);
  }
  return true;
}

const finding = (n, file = "crates/demo/src/lib.rs") =>
  `warning: finding number ${n}\n --> ${file}:${n}:1\n  |\n${n} | pub fn x() {}\n  |\n  = help: see the lint's page\n\n`;

describe("the rust toolkit's post-edit hook, on stub cargo binaries", () => {
  test("never starts cargo for a file that is not Rust, outside cwd, under target/, or in no package up to cwd", () => {
    const ws = stubbedWorkspace();
    const { cwd, demo } = ws;
    const other = stubbedWorkspace();
    writeFileSync(join(demo, "notes.md"), "# notes\n");
    mkdirSync(join(demo, "target", "debug", "build"), { recursive: true });
    writeFileSync(join(demo, "target", "debug", "build", "out.rs"), "pub fn x() {}\n");
    mkdirSync(join(cwd, "loose"));
    writeFileSync(join(cwd, "loose", "a.rs"), "pub fn x() {}\n");
    // A package above cwd is another checkout's: the hook looks no higher than cwd.
    const inner = join(demo, "src");
    symlinkSync(join(other.demo, "src", "lib.rs"), join(demo, "src", "link.rs"));
    symlinkSync(join(other.demo, "src"), join(demo, "linked"));
    const cases = [
      { cwd, file: join(demo, "notes.md") },
      { cwd, file: join(demo, "src", "lib.rs.bak") },
      { cwd, file: join(other.demo, "src", "lib.rs") },
      { cwd, file: join(cwd, "..", "a.rs") },
      { cwd, file: join(demo, "target", "debug", "build", "out.rs") },
      { cwd, file: join(cwd, "loose", "a.rs") },
      { cwd: inner, file: join(inner, "lib.rs") },
      { cwd, file: join(demo, "src", "link.rs") },
      { cwd, file: join(demo, "linked", "lib.rs") },
    ];
    for (const { cwd: at, file } of cases) {
      silent(runStubbed(ws, { cwd: at, file }));
      assert.ok(!existsSync(join(ws.bin, "args")), `the hook started cargo for ${file} in ${at}`);
    }
    silent(runStubbed(ws, { cwd, file: join(demo, "src", "lib.rs") }));
    assert.ok(existsSync(join(ws.bin, "args")), "the hook never started cargo for a package's file");
  });

  test("runs cargo clippy --message-format=json --all-targets --offline in the package's directory, for each edit tool and a relative path", () => {
    const ws = stubbedWorkspace();
    for (const [tool, file] of [["Edit", join(ws.demo, "src", "lib.rs")], ["Write", "crates/demo/src/lib.rs"], ["MultiEdit", join(ws.demo, "src", "other.rs")]]) {
      silent(runStubbed(ws, { cwd: ws.cwd, file, tool }));
      assert.equal(readFileSync(join(ws.bin, "pwd"), "utf8").trim(), ws.demo, tool);
      assert.deepEqual(readFileSync(join(ws.bin, "args"), "utf8").trim().split("\n"),
        ["clippy", "--message-format=json", "--all-targets", "--offline"], tool);
    }
  });

  // A session's cwd follows a Bash cd, so the session's directory is CLAUDE_PROJECT_DIR when set.
  test("takes CLAUDE_PROJECT_DIR as the session's directory once a cd has moved the event's cwd", () => {
    const ws = stubbedWorkspace();
    const file = "crates/demo/src/lib.rs";
    writeOut(ws.bin, [message({ file, rendered: finding(1) })]);
    const src = join(ws.demo, "src");
    // Below the package, no package lies up to cwd; in another crate, the file lies outside it.
    silent(runStubbed(ws, { cwd: src, file: join(src, "lib.rs") }));
    assert.equal(existsSync(join(ws.bin, "pwd")), false);
    const other = join(ws.cwd, "crates", "other");
    mkdirSync(other, { recursive: true });
    silent(runStubbed(ws, { cwd: other, file: join(src, "lib.rs") }));
    assert.equal(existsSync(join(ws.bin, "pwd")), false);
    for (const cwd of [src, other]) {
      const text = context(runStubbed(ws, { cwd, file: join(src, "lib.rs"), env: { CLAUDE_PROJECT_DIR: ws.cwd } }));
      assert.equal(text, `rust: 1 finding in ${file} (cargo clippy)\n${finding(1).trimEnd()}`, cwd);
      assert.equal(readFileSync(join(ws.bin, "pwd"), "utf8").trim(), ws.demo, cwd);
    }
    // A relative file_path is still taken from cwd.
    rmSync(join(ws.bin, "pwd"));
    context(runStubbed(ws, { cwd: src, file: "lib.rs", env: { CLAUDE_PROJECT_DIR: ws.cwd } }));
    assert.equal(readFileSync(join(ws.bin, "pwd"), "utf8").trim(), ws.demo);
  });

  // A hook stays off the network and installs no toolchain; sccache wraps rustc as the session's
  // own cargo has it, unless the session set a wrapper, an empty one included.
  test("sets RUSTC_WRAPPER=sccache only with sccache on PATH and none set, and RUSTUP_AUTO_INSTALL=0 when unset", () => {
    const ws = stubbedWorkspace();
    const file = join(ws.demo, "src", "lib.rs");
    const env = () => readFileSync(join(ws.bin, "env"), "utf8").trim();
    silent(runStubbed(ws, { cwd: ws.cwd, file }));
    assert.equal(env(), "RUSTC_WRAPPER=unset RUSTUP_AUTO_INSTALL=0");
    const sccache = stubs({ sccache: "exit 0" });
    const path = `${ws.bin}${delimiter}${sccache}${delimiter}${pathWithout("sccache", "cargo")}`;
    silent(runEdit({ cwd: ws.cwd, file, path, env: { STUB: ws.bin } }));
    assert.equal(env(), "RUSTC_WRAPPER=sccache RUSTUP_AUTO_INSTALL=0");
    silent(runEdit({ cwd: ws.cwd, file, path, env: { STUB: ws.bin, RUSTC_WRAPPER: "", RUSTUP_AUTO_INSTALL: "1" } }));
    assert.equal(env(), "RUSTC_WRAPPER= RUSTUP_AUTO_INSTALL=1");
  });

  test("gives the findings in the edited file, once each, under a line naming them and the file", () => {
    const ws = stubbedWorkspace();
    const file = "crates/demo/src/lib.rs";
    writeOut(ws.bin, [
      JSON.stringify({ reason: "compiler-artifact", package_id: "x" }),
      message({ file, rendered: finding(1) }),
      message({ file, level: "error", rendered: finding(2).replace("warning", "error[E0308]") }),
      // The same finding from the lib's test target.
      message({ file, rendered: finding(1) }),
      message({ file, level: "note", rendered: "note: a note\n" }),
      message({ file, level: "error", rendered: "error: aborting due to 1 previous error\n", spans: false }),
      JSON.stringify({ reason: "build-finished", success: false }),
    ]);
    const text = context(runStubbed(ws, { cwd: ws.cwd, file: join(ws.demo, "src", "lib.rs") }));
    assert.equal(text, `rust: 2 findings in crates/demo/src/lib.rs (cargo clippy)\n${finding(1).trimEnd()}\n\n${finding(2).replace("warning", "error[E0308]").trimEnd()}`);
    writeOut(ws.bin, [message({ file, rendered: finding(1) })]);
    assert.match(context(runStubbed(ws, { cwd: ws.cwd, file: join(ws.demo, "src", "lib.rs") })), /^rust: 1 finding in crates\/demo\/src\/lib\.rs \(cargo clippy\)\n/);
  });

  // rustc names a file by its absolute path when it lies outside the workspace's root, and a
  // lone package is its own workspace.
  test("matches a finding given by its absolute path, and in a package that is its own workspace", () => {
    const cwd = realpathSync(tempDir("rust-lone"));
    writeFileSync(join(cwd, "Cargo.toml"), '[package]\nname = "lone"\nversion = "0.1.0"\n');
    mkdirSync(join(cwd, "src"));
    writeFileSync(join(cwd, "src", "lib.rs"), "pub fn x() {}\n");
    const ws = stubbedWorkspace();
    writeOut(ws.bin, [message({ file: "src/lib.rs", rendered: finding(1, "src/lib.rs") }),
      message({ file: join(cwd, "src", "lib.rs"), rendered: finding(2, "src/lib.rs") })]);
    const text = context(runStubbed(ws, { cwd, file: join(cwd, "src", "lib.rs") }));
    assert.match(text, /^rust: 2 findings in src\/lib\.rs \(cargo clippy\)\n/);
    assert.equal(readFileSync(join(ws.bin, "pwd"), "utf8").trim(), cwd);
  });

  test("gives one line for findings in other files only, and that line after the file's own", () => {
    const ws = stubbedWorkspace();
    const other = message({ file: "crates/demo/src/other.rs", rendered: finding(3, "crates/demo/src/other.rs") });
    writeOut(ws.bin, [other, message({ file: "crates/demo/src/other.rs", level: "error", rendered: finding(4, "crates/demo/src/other.rs") })]);
    const file = join(ws.demo, "src", "lib.rs");
    assert.equal(context(runStubbed(ws, { cwd: ws.cwd, file })), "rust: 2 findings in other files of demo; cargo clippy -p demo shows them");
    writeOut(ws.bin, [other, message({ file: "crates/demo/src/lib.rs", rendered: finding(1) })]);
    assert.equal(context(runStubbed(ws, { cwd: ws.cwd, file })),
      `rust: 1 finding in crates/demo/src/lib.rs (cargo clippy)\n${finding(1).trimEnd()}\nrust: 1 finding in other files of demo; cargo clippy -p demo shows them`);
  });

  test("says nothing of a clean package", () => {
    const ws = stubbedWorkspace();
    writeOut(ws.bin, [JSON.stringify({ reason: "compiler-artifact", package_id: "x" }), JSON.stringify({ reason: "build-finished", success: true })]);
    silent(runStubbed(ws, { cwd: ws.cwd, file: join(ws.demo, "src", "lib.rs") }));
  });

  test("cuts the findings at 4,000 characters with a line saying how many more there were", () => {
    const ws = stubbedWorkspace();
    const lines = [];
    for (let n = 1; n <= 80; n++) lines.push(message({ file: "crates/demo/src/lib.rs", rendered: finding(n) }));
    lines.push(message({ file: "crates/demo/src/other.rs", rendered: finding(81, "crates/demo/src/other.rs") }));
    writeOut(ws.bin, lines);
    const text = context(runStubbed(ws, { cwd: ws.cwd, file: join(ws.demo, "src", "lib.rs") }));
    assert.ok(text.length <= 4000, `the context is ${text.length} characters`);
    const all = text.split("\n");
    assert.equal(all[0], "rust: 80 findings in crates/demo/src/lib.rs (cargo clippy)");
    assert.equal(all.at(-1), "rust: 1 finding in other files of demo; cargo clippy -p demo shows them");
    const cut = all.at(-2).match(/^rust: cut (\d+) more characters; tests\/run rust gives the rest$/);
    assert.ok(cut, all.at(-2));
    const shown = all.slice(1, -2).join("\n");
    const whole = Array.from({ length: 80 }, (_, i) => finding(i + 1).trimEnd()).join("\n\n");
    assert.ok(whole.startsWith(shown), "the findings shown are not the first ones");
    assert.equal(Number(cut[1]), whole.length - shown.length);
    assert.ok(shown.length > 3000, `only ${shown.length} characters shown`);
  });

  test("on its deadline kills cargo's process group and gives one line", () => {
    const ws = stubbedWorkspace('echo $$ >"$STUB/group"\nsleep 30 &\nsleep 30');
    const run = runStubbed(ws, { cwd: ws.cwd, file: join(ws.demo, "src", "lib.rs"), env: { RUST_DIAGNOSTICS_DEADLINE_MS: "500" } });
    const text = context(run);
    assert.ok(run.ms < 500 + 2500, `the hook took ${run.ms} ms on a 500 ms deadline`);
    assert.equal(text, "rust: cargo clippy on demo did not finish in 0.5 s; run tests/run rust before delivering");
    const group = Number(readFileSync(join(ws.bin, "group"), "utf8"));
    assert.ok(group > 1);
    assert.ok(goneWithin(group, 2000), `process group ${group} is still alive 2 s after the hook ended`);
  });

  test("keeps its 20 s deadline when no seam is set", () => {
    const ws = stubbedWorkspace("sleep 60");
    const run = runStubbed(ws, { cwd: ws.cwd, file: join(ws.demo, "src", "lib.rs") });
    const text = context(run);
    assert.ok(run.ms >= 20_000, `the hook gave up after ${run.ms} ms`);
    assert.ok(run.ms < 23_000, `the hook took ${run.ms} ms`);
    assert.equal(text, "rust: cargo clippy on demo did not finish in 20 s; run tests/run rust before delivering");
  });

  // cargo's stderr starts with its progress lines; the line worth giving is its first error.
  test("gives one line with cargo's exit and its first error line when it fails with no finding", () => {
    const ws = stubbedWorkspace("echo '    Checking demo v0.1.0' >&2\necho 'error: failed to parse manifest at `x/Cargo.toml`' >&2\necho 'Caused by:' >&2\nexit 101");
    assert.equal(context(runStubbed(ws, { cwd: ws.cwd, file: join(ws.demo, "src", "lib.rs") })),
      "rust: cargo clippy failed (exit 101): error: failed to parse manifest at `x/Cargo.toml`");
    const plain = stubbedWorkspace("echo '' >&2\necho 'something broke' >&2\nexit 3");
    assert.equal(context(runStubbed(plain, { cwd: plain.cwd, file: join(plain.demo, "src", "lib.rs") })),
      "rust: cargo clippy failed (exit 3): something broke");
    const mute = stubbedWorkspace("exit 4");
    assert.equal(context(runStubbed(mute, { cwd: mute.cwd, file: join(mute.demo, "src", "lib.rs") })),
      "rust: cargo clippy failed (exit 4): no stderr");
    // Compiler messages that give no finding (no primary span, or a note) are no finding: a failure
    // with only those is still the failure line.
    const spanless = stubbedWorkspace("echo 'error: could not compile `demo` (lib) due to 1 previous error' >&2\nexit 101");
    writeOut(spanless.bin, [
      message({ file: "crates/demo/src/lib.rs", level: "error", rendered: "error[E0463]: can't find crate for `std`", spans: false }),
      message({ file: "crates/demo/src/lib.rs", level: "note", rendered: "note: the `x` target may not be installed" }),
    ]);
    assert.equal(context(runStubbed(spanless, { cwd: spanless.cwd, file: join(spanless.demo, "src", "lib.rs") })),
      "rust: cargo clippy failed (exit 101): error: could not compile `demo` (lib) due to 1 previous error");
  });

  test("cuts cargo's error line at 300 characters", () => {
    const ws = stubbedWorkspace("printf 'error: %0500d\\n' 0 >&2\nexit 101");
    const text = context(runStubbed(ws, { cwd: ws.cwd, file: join(ws.demo, "src", "lib.rs") }));
    assert.equal(text, `rust: cargo clippy failed (exit 101): error: ${"0".repeat(293)}... (207 characters cut)`);
  });

  test("gives one line when cargo cannot start, and exits 0 on an event it cannot read", () => {
    const ws = stubbedWorkspace();
    const text = context(runEdit({ cwd: ws.cwd, file: join(ws.demo, "src", "lib.rs"), path: pathWithout("sccache", "cargo") }));
    assert.match(text, /^rust: cargo clippy failed \(could not start\): .*ENOENT/);
    const odd = spawnSync("sh", ["-c", editCommand], { cwd: ws.cwd, encoding: "utf8", input: "{not json",
      env: { HOME: ws.cwd, PATH: pathWithout("sccache", "cargo"), CLAUDE_PLUGIN_ROOT: toolkit } });
    assert.equal(odd.status, 0, odd.stderr);
    assert.equal(odd.stdout, "");
  });
});

// The real cargo, as the session's PATH gives it: these cases run only where it is the pinned
// toolchain's, and fail instead of skipping with RUST_TOOLKIT_TESTS=require, which CI's toolkits job
// does not set yet.
const realCargo = (() => {
  const run = spawnSync("cargo", ["--version"], { cwd: repoRoot, encoding: "utf8", env: { ...process.env, RUSTUP_AUTO_INSTALL: "0" } });
  if (run.error) return { skip: `no cargo on PATH (${run.error.code}), so the pinned toolchain ${channel} is not here` };
  const version = run.stdout.match(/^cargo (\S+)/)?.[1];
  if (run.status !== 0 || version !== channel) {
    return { skip: `cargo --version in the repository's root gives ${version ?? `exit ${run.status}: ${run.stderr.trim().split("\n")[0]}`}, not the pinned ${channel}` };
  }
  const which = spawnSync("sh", ["-c", "command -v cargo"], { encoding: "utf8" }).stdout.trim();
  return { skip: false, dir: dirname(which) };
})();
const required = process.env.RUST_TOOLKIT_TESTS === "require";
const realTest = (name, body) => test(name, { skip: required ? false : realCargo.skip }, () => {
  if (realCargo.skip) assert.fail(`RUST_TOOLKIT_TESTS=require, and ${realCargo.skip}`);
  body();
});

// A copy of the fixture with the repository's rust-toolchain.toml, as a worktree has it.
function realCrate() {
  const cwd = realpathSync(tempDir("rust-crate"));
  cpSync(fixture, cwd, { recursive: true });
  cpSync(join(repoRoot, "rust-toolchain.toml"), join(cwd, "rust-toolchain.toml"));
  return cwd;
}

// An edit of the copy's src/kind.rs, as the session's Edit tool makes one.
function edit(cwd, from, to) {
  const file = join(cwd, "src", "kind.rs");
  const text = readFileSync(file, "utf8");
  assert.equal(text.split(from).length, 2, `src/kind.rs holds ${from} other than once`);
  writeFileSync(file, text.replace(from, to));
}

// The real cargo's environment: the machine's HOME and rustup and cargo homes, its cargo first on
// the test PATH.
function realEnv() {
  const env = { HOME: process.env.HOME, RUSTUP_AUTO_INSTALL: "0" };
  for (const name of ["CARGO_HOME", "RUSTUP_HOME"]) if (process.env[name]) env[name] = process.env[name];
  return env;
}

function realEdit(cwd, file) {
  return runEdit({ cwd, file: join(cwd, file), env: realEnv(), path: `${realCargo.dir}${delimiter}${testPath({ withOp: false })}` });
}

describe("the rust toolkit's post-edit hook, on the real cargo and the fixture", () => {
  realTest("says nothing of a clean edit", () => {
    silent(realEdit(realCrate(), "src/kind.rs"));
  });

  realTest("names unwrap_used for an added unwrap(), once", () => {
    const cwd = realCrate();
    edit(cwd, '"opened" => Ok(Kind::Opened),', '"opened" => Ok(next(Kind::Parked).unwrap()),');
    const text = context(realEdit(cwd, "src/kind.rs"));
    assert.match(text, /^rust: 1 finding in src\/kind\.rs \(cargo clippy\)\n/);
    assert.match(text, /unwrap_used/);
  });

  realTest("gives the compiler's error for a type mistake", () => {
    const cwd = realCrate();
    edit(cwd, 'Kind::Opened => "opened",', "Kind::Opened => 1,");
    const text = context(realEdit(cwd, "src/kind.rs"));
    assert.match(text, /^rust: 1 finding in src\/kind\.rs \(cargo clippy\)\n/);
    assert.match(text, /error\[E0308\]: mismatched types/);
  });

  realTest("names a finding in another file of the package in one line", () => {
    const cwd = realCrate();
    edit(cwd, '"opened" => Ok(Kind::Opened),', '"opened" => Ok(next(Kind::Parked).unwrap()),');
    assert.equal(context(realEdit(cwd, "src/lib.rs")), "rust: 1 finding in other files of kind-fixture; cargo clippy -p kind-fixture shows them");
  });

  realTest("finds the fixture clean under the root's lints, warnings denied", () => {
    const cwd = realCrate();
    const run = spawnSync("cargo", ["clippy", "--all-targets", "--offline", "--locked", "--", "-D", "warnings"], {
      cwd,
      encoding: "utf8",
      env: { ...realEnv(), PATH: `${realCargo.dir}${delimiter}${testPath({ withOp: false })}` },
    });
    assert.equal(run.status, 0, run.stderr);
  });
});

// The eval cases' code as the pinned clippy sees it: the lint case's warning is the one the prompt
// quotes, and the review case's diff has the wildcard arm clippy names.
describe("the rust toolkit's evals, on the real cargo", () => {
  // clippy's JSON messages for a crate, as the rendered text of each warning and error.
  function clippy(cwd) {
    cpSync(join(repoRoot, "rust-toolchain.toml"), join(cwd, "rust-toolchain.toml"));
    const run = spawnSync("cargo", ["clippy", "--message-format=json", "--all-targets", "--offline", "--locked"], {
      cwd,
      encoding: "utf8",
      env: { ...realEnv(), PATH: `${realCargo.dir}${delimiter}${testPath({ withOp: false })}` },
    });
    assert.equal(run.status, 0, run.stderr);
    const rendered = run.stdout.split("\n").filter(Boolean).map((line) => JSON.parse(line))
      .filter((line) => line.reason === "compiler-message" && line.message.spans.length > 0)
      .map((line) => line.message.rendered);
    return [...new Set(rendered)];
  }

  realTest("the lint case's scaffold gives the one unwrap_used warning its prompt quotes", () => {
    const [warning, ...rest] = clippy(scaffold("fix-a-lint"));
    assert.deepEqual(rest, []);
    assert.match(warning, /#unwrap_used\n/);
    assert.equal(lintQuote().warning, `${warning.replace(/^ {3}= help: for further information .*\n/m, "").trimEnd()}\n`);
  });

  realTest("the review case's diff gives clippy's wildcard finding on its _ => false arm, and no other", () => {
    const copy = realpathSync(tempDir("review-copy"));
    cpSync(fixture, copy, { recursive: true });
    const apply = spawnSync("git", ["apply", "-"], { cwd: copy, input: fenced("review-a-diff-with-a-missed-case", "diff"), encoding: "utf8" });
    assert.equal(apply.status, 0, apply.stderr);
    const [warning, ...rest] = clippy(copy);
    assert.deepEqual(rest, []);
    assert.match(warning, /^warning: wildcard matches only a single variant/);
    assert.match(warning, /^\d+ \| +_ => false,$/m);
    assert.match(warning, /help: try: `Kind::Reopened`/);
  });
});
