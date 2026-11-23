// The rust toolkit as team-worker --toolkit rust loads it: its plugin layout (the manifest, its
// rust-analyzer language server declared inline as lspServers with exactly the keys and values the
// toolkit's README and spec give, and no MCP config), its README's "When the coordinator gives it",
// and its rust-core skill, the only skill of that name in any toolkit or the coordinator's plugin,
// whose description and size limits and order of sections the test holds, against the files alone:
// no cargo, rustup or rust-analyzer runs here.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, test } from "node:test";
import { repoRoot } from "./helpers/mcp.mjs";

const toolkit = join(repoRoot, "toolkits", "rust");
const manifest = JSON.parse(readFileSync(join(toolkit, ".claude-plugin", "plugin.json"), "utf8"));
const skill = readFileSync(join(toolkit, "skills", "rust-core", "SKILL.md"), "utf8");
const readme = readFileSync(join(toolkit, "README.md"), "utf8");

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

  test("its README marks each unmeasured cost and holds the build cache's and the confinement roots' rules", () => {
    const section = (name) => readme.split(`## ${name}\n`)[1].split("\n## ")[0];
    assert.match(section("What it costs"), /not measured/);
    const cache = section("The build cache");
    assert.match(cache, /~\/\.cache\/sccache/);
    assert.match(cache, /`target\/`/);
    assert.match(cache, /5 minutes/);
    assert.match(cache, /4 GiB/);
    assert.match(cache, /team-heavy/);
    const roots = section("Confinement roots");
    for (const path of ["`~/.cargo`", "`~/.cache/sccache`", "`~/.rustup`", "`RUSTUP_AUTO_INSTALL=0`"]) {
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

  test("gives the layout: a virtual workspace, crates under crates/, each taking the workspace's lints", () => {
    const text = section("## 2. The layout");
    assert.match(text, /`crates\/`/);
    assert.match(text, /`\[lints\] workspace = true`/);
    assert.match(text, /ticket/);
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
