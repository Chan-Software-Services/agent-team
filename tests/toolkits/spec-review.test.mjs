// The spec-review toolkit as team-worker --toolkit spec-review loads it: its plugin layout, its
// manifest's version and description and the skills-only property of its files, its three read-only reader agents' frontmatter (their
// read-only tools, omitClaudeMd and model), the task files each is told never to read and what each
// returns, its spec-review and claims-check skills' names, limits and order of steps, its README's
// sections in the effect toolkit's order, its coordinator section, the files and eval cases it
// names and its attribution line, and each
// eval case's tools and graders. The eval's sandbox gives its session no git, so the two
// claims-check cases start at the skill's step 3, and one test here runs the git commands the
// skill's steps 1, 2 and 5 name, as written, on a repository a case's scaffold makes.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import { repoRoot } from "./helpers/mcp.mjs";

const toolkit = join(repoRoot, "toolkits", "spec-review");
const read = (...parts) => readFileSync(join(toolkit, ...parts), "utf8");
const frontmatterOf = (text) => text.match(/^---\n([\s\S]*?)\n---\n/)?.[1] ?? "";
const fieldOf = (frontmatter, name) => frontmatter.match(new RegExp(`^${name}: (.*)$`, "m"))?.[1];

const skill = read("skills", "spec-review", "SKILL.md");
const claimsSkill = read("skills", "claims-check", "SKILL.md");
const readme = read("README.md");

describe("the spec-review toolkit", () => {
  test("is a plugin named spec-review with three agents and two skills, and no MCP server, hook or script", () => {
    const manifest = JSON.parse(read(".claude-plugin", "plugin.json"));
    assert.equal(manifest.name, "spec-review");
    assert.equal(manifest.author?.name, "Daniel Chan");
    assert.equal(manifest.version, "0.2.0");
    // The manifest says both skills and whom each serves, and still that nothing else loads.
    for (const part of ["For a planner", "the spec-review skill", "For every delivering builder", "team-worker", "the claims-check skill"]) {
      assert.ok(manifest.description.includes(part), `the manifest's description lacks "${part}"`);
    }
    assert.ok(manifest.description.endsWith("No MCP server, hook or script."), "the manifest's description's last sentence");
    assert.deepEqual(readdirSync(toolkit).sort(), [".claude-plugin", "README.md", "agents", "evals", "skills"]);
    assert.ok(!existsSync(join(toolkit, ".mcp.json")), "the toolkit declares an MCP server");
    assert.ok(!existsSync(join(toolkit, "hooks")), "the toolkit has hooks");
    assert.ok(!existsSync(join(toolkit, "scripts")), "the toolkit has scripts");
    assert.deepEqual(readdirSync(join(toolkit, "agents")).sort(), ["claims-reader.md", "spec-paraphrase.md", "spec-readiness.md"]);
    assert.deepEqual(readdirSync(join(toolkit, "skills")).sort(), ["claims-check", "spec-review"]);
  });

  // The spec's launch rule lets a skills-only toolkit past a project's toolkits allow list, and
  // skills-only is this property of the toolkit's own files.
  test("is skills-only, the property the delivery exemption from a project's allow list rests on", () => {
    const why = "the delivery exemption from a project's toolkits allow list rests on the toolkit being skills-only";
    const allowed = [".claude-plugin", "README.md", "agents", "skills", "evals"];
    for (const entry of readdirSync(toolkit)) assert.ok(allowed.includes(entry), `${entry}: ${why}`);
    assert.deepEqual(readdirSync(join(toolkit, ".claude-plugin")), ["plugin.json"], why);
    const manifest = JSON.parse(read(".claude-plugin", "plugin.json"));
    for (const key of Object.keys(manifest)) {
      assert.ok(["name", "version", "description", "author"].includes(key), `plugin.json's ${key}: ${why}`);
    }
    const loaded = [];
    for (const agent of readdirSync(join(toolkit, "agents"))) {
      assert.match(agent, /^[a-z0-9-]+\.md$/, `agents/${agent}: ${why}`);
      loaded.push(join("agents", agent));
    }
    for (const dir of readdirSync(join(toolkit, "skills"))) {
      assert.match(dir, /^[a-z0-9-]+$/, `skills/${dir}: ${why}`);
      assert.deepEqual(readdirSync(join(toolkit, "skills", dir)), ["SKILL.md"], `skills/${dir}: ${why}`);
      loaded.push(join("skills", dir, "SKILL.md"));
    }
    for (const file of loaded) {
      assert.doesNotMatch(frontmatterOf(read(file)), /^(hooks|mcpServers):/m, `${file}: ${why}`);
      // The launch rule reads a frontmatter only as plain ASCII: a file opens with ---, and no line of it holds another byte.
      assert.ok(read(file).startsWith("---\n"), `${file} does not open with a frontmatter: ${why}`);
      assert.match(frontmatterOf(read(file)), /^[\x20-\x7E\n]+$/, `${file}'s frontmatter holds a byte that is no printable ASCII: ${why}`);
      // Claude Code runs a command a skill's text writes with an exclamation mark, so the launch rule refuses one anywhere in a skill file.
      if (file.endsWith("SKILL.md")) assert.ok(!read(file).includes("!"), `${file} holds an exclamation mark: ${why}`);
      // The launch rule's listed keys: a line that is not blank, a comment or indented opens with one.
      for (const line of frontmatterOf(read(file)).split("\n").filter((line) => !/^(\s|#|$)/.test(line))) {
        assert.match(line, /^(name|description|tools|model|omitClaudeMd|argument-hint):(\s|$)/, `${file}, "${line.slice(0, 40)}": ${why}`);
      }
    }
  });

  test("its README says when the coordinator gives it", () => {
    assert.match(readme, /^## When the coordinator gives it$/m);
    assert.match(readme, /--toolkit spec-review/);
    // A delivering builder gets it from team-worker with nothing given, on a project that lists no toolkit.
    const when = readme.split("## When the coordinator gives it\n")[1].split("\n## ")[0];
    for (const template of ["builder-deliver", "builder-round", "builder-fix"]) {
      assert.ok(when.includes(`\`${template}\``), `"When the coordinator gives it" does not name ${template}`);
    }
    assert.match(when, /`team-worker` adds the toolkit/);
    assert.match(when, /a skills-only toolkit needs no line in a project's allow list/);
    assert.match(when, /`bin\/team-worker`'s header/);
  });

  test("its README has the effect toolkit's sections, in order", () => {
    const headings = [...readme.matchAll(/^## (.*)$/gm)].map(([, heading]) => heading);
    assert.deepEqual(headings, ["When the coordinator gives it", "What loads", "What it costs", "Credits", "Tests"]);
  });

  test("its README says what both skills and the three agents load, and names every eval case", () => {
    const loads = readme.split("## What loads\n")[1].split("\n## ")[0];
    for (const file of ["skills/spec-review/SKILL.md", "skills/claims-check/SKILL.md", "agents/spec-paraphrase.md", "agents/spec-readiness.md", "agents/claims-reader.md"]) {
      assert.ok(loads.includes(`\`${file}\``), `"What loads" does not name ${file}`);
    }
    const tests = readme.split("## Tests\n")[1];
    for (const name of readdirSync(join(toolkit, "evals")).filter((entry) => entry !== "results")) {
      assert.ok(tests.includes(`\`${name}\``), `"Tests" does not name the eval case ${name}`);
    }
  });

  test("its README credits elephant-goldfish-model and its licence, and names no copyright holder", () => {
    const credits = readme.split("## Credits\n")[1].split("\n## ")[0];
    const line = "Its method is adapted from google/elephant-goldfish-model (https://github.com/google/elephant-goldfish-model, commit e9e1f06), Apache License 2.0.";
    assert.ok(credits.split("\n").includes(line), "the Credits section lacks the attribution line");
    assert.doesNotMatch(credits, /Copyright \(c\)|Copyright \d/);
  });
});

describe("the reader agents", () => {
  const specFiles = ["plan.md", "brief", "interview.md", "memory.md", "handoff.md", "build-notes/", "spec-review.md"];
  // The claims reader's inputs are the diff and the PR body, so the spec and tickets are not its to read.
  const forbidden = {
    "claims-reader": [...specFiles, "spec.md", "tickets/", "review.md", "claims-check.md"],
    "spec-paraphrase": specFiles,
    "spec-readiness": specFiles,
  };
  for (const name of Object.keys(forbidden)) {
    const text = read("agents", `${name}.md`);
    const frontmatter = frontmatterOf(text);
    test(`${name} is read-only, omits CLAUDE.md and names a model`, () => {
      assert.equal(fieldOf(frontmatter, "name"), name);
      assert.ok(fieldOf(frontmatter, "description"), `${name} has no description`);
      assert.equal(fieldOf(frontmatter, "tools"), "[Read, Grep, Glob]");
      assert.equal(fieldOf(frontmatter, "omitClaudeMd"), "true");
      assert.match(fieldOf(frontmatter, "model") ?? "", /^(inherit|opus|sonnet|haiku|claude-[\w-]+)$/);
    });

    test(`${name} is told never to read the task directory beyond its inputs`, () => {
      for (const file of forbidden[name]) {
        assert.ok(text.includes(`\`${file}`), `${name} does not forbid ${file}`);
      }
    });
  }

  test("spec-paraphrase returns exactly the spec's three headed parts", () => {
    const text = read("agents", "spec-paraphrase.md");
    for (const part of ["## What this changes", "## How the system works today, per this spec", "## Could not follow"]) {
      assert.ok(text.includes(part), `spec-paraphrase does not return ${part}`);
    }
  });

  test("spec-readiness reads the code root's CLAUDE.md and AGENTS.md first, and returns its findings and what it read", () => {
    const text = read("agents", "spec-readiness.md");
    const order = ["<code root>/CLAUDE.md", "<code root>/AGENTS.md", "<task dir>/spec.md", "<task dir>/scope.txt", "<task dir>/tickets/"];
    const at = order.map((step) => text.indexOf(step));
    order.forEach((step, i) => assert.ok(at[i] >= 0, `spec-readiness does not name ${step}`));
    assert.deepEqual([...at].sort((a, b) => a - b), at, "spec-readiness reads out of order");
    for (const kind of ["open-decision", "missing", "contradiction", "too-large"]) assert.ok(text.includes(`\`${kind}\``), kind);
    assert.ok(text.includes("- <severity> <kind> <where>: <finding>"));
    assert.ok(text.includes("Left to the builder"));
    assert.ok(text.indexOf("## Findings") < text.indexOf("## Read"));
  });

  test("claims-reader takes the code root, the diff and the PR body, and returns its findings and what it checked", () => {
    const text = read("agents", "claims-reader.md");
    for (const line of ["`Code root: <path>`", "`Diff: <path>`", "`PR body: <path>`"]) {
      assert.ok(text.includes(line), `claims-reader does not name its prompt line ${line}`);
    }
    assert.ok(text.includes('- <path>:<line>: "<the sentence>" - the code:'), "claims-reader lacks the finding line's shape");
    assert.ok(text.includes("- <path>: <n> sentences"), "claims-reader lacks the checked line's shape");
    assert.match(text, /the single word `none`/);
    assert.ok(text.indexOf("## Findings") >= 0 && text.indexOf("## Findings") < text.indexOf("## Checked"));
    // The search rules spec-readiness states, which keep a search out of a task directory under the code root.
    assert.ok(text.includes("`!<task dir, relative to the code root>/**`"), "claims-reader lacks the Grep rule");
    assert.match(text, /give Glob a `path` below the code root/);
  });
});

const skillFrontmatter = frontmatterOf(skill);

// Each skill of a name, as <plugin>/<directory>, in every toolkit and the coordinator's plugin: a
// skill of the same name in another plugin a session loads would bring it to a session without the
// toolkit.
const skillsNamed = (name) => {
  const named = [];
  for (const root of [join(repoRoot, "toolkits"), join(repoRoot, "plugins")]) {
    for (const plugin of readdirSync(root)) {
      const skills = join(root, plugin, "skills");
      if (!existsSync(skills)) continue;
      for (const dir of readdirSync(skills)) {
        const text = readFileSync(join(skills, dir, "SKILL.md"), "utf8");
        if (dir === name || new RegExp(`^name: ${name}$`, "m").test(text)) named.push(`${plugin}/${dir}`);
      }
    }
  }
  return named;
};

describe("the spec-review skill", () => {
  test("is named spec-review, its description under 250 characters and its whole file under 8 kB", () => {
    assert.equal(fieldOf(skillFrontmatter, "name"), "spec-review");
    const description = fieldOf(skillFrontmatter, "description");
    assert.ok(description, "the skill has no description");
    assert.ok(description.length < 250, `its description is ${description.length} characters`);
    assert.match(description, /spec/);
    assert.match(description, /before the plan is approved/);
    assert.match(description, /[Nn]ot for (a )?code review/);
    const size = Buffer.byteLength(skill);
    assert.ok(size < 8192, `the skill is ${size} bytes`);
  });

  test("takes a task directory, a code root and a model", () => {
    assert.ok(skill.includes("/spec-review [<task dir>] [<code root>] [--model sonnet|opus]"));
  });

  test("is the only skill named spec-review in any toolkit or the coordinator's plugin", () => {
    assert.deepEqual(skillsNamed("spec-review"), ["spec-review/spec-review"]);
  });

  test("holds its eight steps in the spec's order", () => {
    const steps = [
      "## 1. Check the inputs",
      "## 2. Dispatch both readers at once",
      "`spec-review:spec-paraphrase`",
      "`spec-review:spec-readiness`",
      "## 3. Retry a failed reader once",
      "not run: <why>",
      "## 4. Write `spec-review.md`",
      "escalated: none",
      "## 5. Stop here on a spec you did not write",
      "## 6. Compare the paraphrase with your plan",
      "`misread`",
      "## 7. Sort every finding",
      "`fix`",
      "`contest`",
      "`escalate`",
      "## 8. Rewrite the table",
    ];
    const at = steps.map((step) => skill.indexOf(step));
    steps.forEach((step, i) => assert.ok(at[i] >= 0, `the skill does not name ${step}`));
    assert.deepEqual([...at].sort((a, b) => a - b), at, "the skill's steps are out of order");
    assert.ok(skill.includes("| # | Reader | Severity | Kind | Where | Finding | Sort | Evidence |"));
  });
});

describe("the claims-check skill", () => {
  const frontmatter = frontmatterOf(claimsSkill);

  test("is named claims-check, its description under 250 characters and its whole file under 8 kB", () => {
    assert.equal(fieldOf(frontmatter, "name"), "claims-check");
    assert.equal(fieldOf(frontmatter, "argument-hint"), '"[<code root>] [<base>] [--pr-body <file>]"');
    const description = fieldOf(frontmatter, "description");
    assert.ok(description, "the skill has no description");
    assert.ok(description.length < 250, `its description is ${description.length} characters`);
    assert.match(description, /\bPR\b/);
    assert.match(description, /fresh read-only reader/);
    assert.match(description, /`?HEAD`?/);
    assert.ok(description.endsWith("Not for a spec or for reviewing someone else's diff."), description);
    const size = Buffer.byteLength(claimsSkill);
    assert.ok(size < 8192, `the skill is ${size} bytes`);
  });

  test("takes a code root, a base and a PR body file", () => {
    assert.ok(claimsSkill.includes("`/claims-check [<code root>] [<base>] [--pr-body <file>]`"));
    assert.ok(claimsSkill.includes("refs/remotes/origin/HEAD"), "the skill does not say the base's default");
  });

  test("is the only skill named claims-check in any toolkit or the coordinator's plugin", () => {
    assert.deepEqual(skillsNamed("claims-check"), ["spec-review/claims-check"]);
  });

  test("holds its seven steps in the spec's order", () => {
    const steps = [
      "## 1. Check the inputs",
      "status --porcelain",
      "## 2. Write the diff",
      "diff --no-color --no-ext-diff <base>...HEAD",
      "## 3. Dispatch the reader",
      "`spec-review:claims-reader`",
      "## 4. Retry a failed reader once",
      "## 5. Write claims-check.md",
      "# Claims check",
      "reader: ran on <model>",
      "## Answers",
      "## 6. Answer every finding",
      "<n>. kept: <path>:<line>",
      "## 7. Say what it found",
      "claims-check: <k> findings, <a> fixed, <b> cut, <c> kept (.scratch/task/claims-check.md)",
    ];
    const at = steps.map((step) => claimsSkill.indexOf(step));
    steps.forEach((step, i) => assert.ok(at[i] >= 0, `the skill does not name ${step}`));
    assert.deepEqual([...at].sort((a, b) => a - b), at, "the skill's steps are out of order");
    assert.equal([...claimsSkill.matchAll(/^## \d+\. /gm)].length, 7);
    for (const part of ["not run: <why>", ".scratch/task/claims-check.diff", "Code root: <code root>", "Diff: <diff>", "PR body: <pr body>"]) {
      assert.ok(claimsSkill.includes(part), `the skill does not name ${part}`);
    }
    // The reader line step 2 writes with no reader dispatched is one of step 5's forms, and step 7 has its reply.
    const notDispatched = "`not dispatched: the branch changes nothing against <base>`";
    const step5 = claimsSkill.split("## 5. Write claims-check.md")[1].split("\n## 6. ")[0];
    assert.ok(claimsSkill.split("## 2. Write the diff")[1].split("\n## 3. ")[0].includes(notDispatched), "step 2 does not write the not dispatched line");
    assert.ok(step5.includes(notDispatched), "step 5's reader lines leave out step 2's");
    assert.ok(claimsSkill.split("## 7. Say what it found")[1].includes("also when step 2 dispatched no reader"), "step 7 has no reply for a check that dispatched no reader");
    // The task directory is the PR body file's when one is named, as a brief's {{task_dir}} gives it.
    assert.ok(claimsSkill.split("## 1. ")[0].includes("the directory that holds the `--pr-body` file when one is named, else `.scratch/task/` under the session's working directory"), "the skill does not say which directory is the task directory");
  });
});

// The evals cannot run the skill's git commands, so this does: each command is taken from the
// skill's text, its placeholders filled in, and run on the name-a-false-header scaffold's repository.
describe("the claims-check skill's git commands", () => {
  const commands = [...claimsSkill.matchAll(/`(git -C <code root> [^`]+)`/g)].map(([, command]) => command);
  const named = (part) => {
    const found = commands.filter((command) => command.includes(part));
    assert.equal(found.length, 1, `the skill names ${found.length} commands with ${part}`);
    return found[0];
  };

  test("check a scaffolded branch's inputs and write the diff its eval case reads", (t) => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "claims-check-")));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const env = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" };
    execFileSync("bash", [join(toolkit, "evals", "name-a-false-header", "scaffold.sh")], { cwd: root, env });
    const diff = join(root, ".scratch", "task", "skill.diff");
    // Runs one of the skill's commands from another directory, so only its -C finds the checkout.
    const run = (part, base = "main") => {
      const words = named(part).replaceAll("<code root>", root).replaceAll("<base>", base).replaceAll("<diff>", diff).split(" ");
      return execFileSync(words[0], words.slice(1), { cwd: tmpdir(), env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
    };

    // Step 1: a checkout, a base that resolves, and a clean tree, the gitignored task directory aside.
    assert.equal(run("rev-parse --show-toplevel"), root);
    assert.throws(() => run("symbolic-ref"), "a repository with no origin has a default base");
    assert.match(run("rev-parse --verify"), /^[0-9a-f]{40}$/);
    assert.throws(() => run("rev-parse --verify", "no-such-base"), "an unknown base resolves");
    assert.ok(existsSync(join(root, ".scratch", "task", "pr-body.md")));
    assert.equal(run("status --porcelain"), "");
    writeFileSync(join(root, "untracked.md"), "A new file.\n");
    assert.equal(run("status --porcelain"), "?? untracked.md");
    rmSync(join(root, "untracked.md"));

    // Step 2: the diff is the one the scaffold wrote for the eval's reader, the planted line in it.
    run("diff --no-color");
    const written = readFileSync(diff, "utf8");
    assert.equal(written, readFileSync(join(root, ".scratch", "task", "claims-check.diff"), "utf8"));
    assert.ok(written.includes("\n+# With --all, archives every note, pinned ones included.\n"));
    assert.equal(run("status --porcelain"), "", "the diff file dirties the tree");

    // Step 5: the merge base is main's commit and the head the branch's.
    assert.equal(run("merge-base"), run("rev-parse --verify"));
    assert.equal(run("rev-parse HEAD"), run("rev-parse --verify", "feat/archive"));
    assert.notEqual(run("rev-parse HEAD"), run("merge-base"));
  });
});

// Each case is one case.yaml, its fixture written by its scaffold script, its graders listed in it.
const evals = join(toolkit, "evals");
const caseOf = (name) => read("evals", name, "case.yaml");
// The graders a case.yaml lists, each its own block of lines from "  - name:" on.
const gradersOf = (text) => text.split(/^graders:\n/m)[1].split(/^(?=  - name: )/m).filter((block) => block.trim());

describe("the spec-review evals", () => {
  const cases = ["name-a-false-header", "pass-prose-that-holds", "planner-notes-stay-out", "replay-an-ignored-tree", "review-a-code-diff", "review-a-spec"];

  test("are six cases, each a case.yaml and its scaffold script", () => {
    assert.deepEqual(readdirSync(evals).filter((name) => name !== "results").sort(), cases);
    for (const name of cases) {
      assert.deepEqual(readdirSync(join(evals, name)).sort(), ["case.yaml", "scaffold.sh"]);
      const text = caseOf(name);
      assert.match(text, /^schema_version: "1\.1"$/m);
      assert.match(text, new RegExp(`^name: ${name}$`, "m"));
      assert.match(text, /^tags: \[spec-review\]$/m);
      assert.match(text, /^ {2}scaffold_script: scaffold\.sh$/m);
      assert.match(text, /^ {2}model: claude-opus-5-5$/m);
      // No case needs a tool the eval's operator must grant, so one command runs them all.
      assert.match(text, /^ {2}allowed_tools: \[Read, Glob, Grep, Skill, Agent\]$/m);
      assert.match(text, /^ {2}prompt: \|$/m);
    }
  });

  // What the two claims-check cases share: a git repository on main with a branch, .scratch/
  // ignored, commits under a fixture address, a PR body in the task directory, the branch's diff
  // written by the scaffold (the eval's sandbox gives its session no git), and the graders that
  // the skill fired and its one reader was dispatched.
  const claimsCase = (name) => {
    const text = caseOf(name);
    assert.match(text, /^ {2}max_turns: 30$/m);
    assert.match(text, /^ {2}timeout_seconds: 900$/m);
    const graders = gradersOf(text);
    assert.equal(graders.length, 3);
    const fired = graders.find((block) => /tool: Skill/.test(block));
    assert.match(fired, /name: skill-fired/);
    assert.match(fired, /type: tool_used/);
    assert.ok(fired.includes(String.raw`input_match: '"skill"\s*:\s*"(?:[\w-]+:)?claims-check"'`), "skill-fired's pattern");
    const dispatched = graders.find((block) => /tool: Agent/.test(block));
    assert.match(dispatched, /name: reader-dispatched/);
    assert.ok(dispatched.includes(String.raw`input_match: '"subagent_type"\s*:\s*"spec-review:claims-reader"'`), "reader-dispatched's pattern");
    assert.match(dispatched, /arm: with-only/);
    const scaffold = read("evals", name, "scaffold.sh");
    assert.match(scaffold, /^\.scratch\/$/m);
    assert.match(scaffold, /^git init -q -b main$/m);
    assert.match(scaffold, /^git checkout -q -b feat\/archive$/m);
    const commits = scaffold.match(/^git .* commit .*$/gm);
    assert.equal(commits.length, 2);
    for (const commit of commits) assert.ok(commit.startsWith("git -c user.name=eval -c user.email=eval@example.com commit "), commit);
    assert.ok(scaffold.includes("cat >.scratch/task/pr-body.md <<'EOF'\n"), "the scaffold writes no PR body");
    assert.ok(scaffold.includes("archive_notes() {"), "the branch adds no archive_notes");
    assert.match(scaffold, /^git diff --no-color --no-ext-diff main\.\.\.HEAD --output=\.scratch\/task\/claims-check\.diff$/m);
    assert.match(text, /^ {4}.*`\.scratch\/task\/claims-check\.diff`/m, "the prompt does not name the diff the scaffold wrote");
    return { scaffold, judged: graders.find((block) => /type: llm/.test(block)) };
  };

  test("name-a-false-header plants a header line the code does not bear out, and judges that the reader names it and neither the README's line nor the PR body", () => {
    const { scaffold, judged } = claimsCase("name-a-false-header");
    assert.ok(scaffold.includes("notecat archive [--all]"), "the header's usage lacks --all");
    assert.ok(scaffold.includes("# With --all, archives every note, pinned ones included."), "the false line is not planted");
    // Only comments name --all: the scaffold's own header and bin/notecat's, never notecat's code.
    for (const line of scaffold.split("\n").filter((line) => /--all|pinned/.test(line))) {
      assert.match(line, /^#/, `notecat's code names --all or a pinned note: ${line}`);
    }
    assert.match(judged, /--all/);
    assert.match(judged, /bin\/notecat/);
    assert.match(judged, /cut or narrow/);
    assert.match(judged, /README/);
    assert.match(judged, /PR body/);
  });

  test("pass-prose-that-holds plants nothing false, and judges that the findings are none", () => {
    const { scaffold, judged } = claimsCase("pass-prose-that-holds");
    assert.doesNotMatch(scaffold, /--all|pinned/);
    assert.match(judged, /PASS if .*`none`/);
    assert.match(judged, /FAIL .*any finding/);
  });

  test("review-a-spec fires the skill, dispatches both readers and grades the two planted faults", () => {
    const graders = gradersOf(caseOf("review-a-spec"));
    const skillFired = graders.find((block) => /tool: Skill/.test(block));
    assert.match(skillFired, /type: tool_used/);
    assert.match(skillFired, /spec-review/);
    for (const agent of ["spec-paraphrase", "spec-readiness"]) {
      const dispatched = graders.find((block) => /tool: Agent/.test(block) && block.includes(agent));
      assert.ok(dispatched, `no grader for ${agent}`);
      assert.match(dispatched, /type: tool_used/);
      assert.match(dispatched, /spec-review:/);
      assert.match(dispatched, /arm: with-only/);
    }
    const judged = graders.find((block) => /type: llm/.test(block));
    assert.match(judged, /open-decision/);
    assert.match(judged, /missing/);
    assert.match(judged, /blocking/);
    assert.equal(graders.length, 4);
  });

  test("planner-notes-stay-out dispatches the readiness reader and fails on the planner's notes in the trace", () => {
    const graders = gradersOf(caseOf("planner-notes-stay-out"));
    assert.equal(graders.length, 2);
    const dispatched = graders.find((block) => /tool: Agent/.test(block));
    assert.match(dispatched, /spec-review:spec-readiness/);
    assert.match(dispatched, /arm: with-only/);
    const unseen = graders.find((block) => /type: regex/.test(block));
    assert.match(unseen, /target: trace/);
    assert.match(unseen, /match: not_contains/);
    // The pattern names the notes' marker and their paths, on a reader's own line of the trace.
    const pattern = unseen.match(/pattern: '([^']+)'/)[1];
    const marker = pattern.match(/^\(([A-Z][A-Z-]+)\|/)[1];
    assert.ok(pattern.includes("(memory|plan)"), "the pattern does not name both notes");
    assert.ok(pattern.endsWith('"parent_tool_use_id":"toolu_'), "the pattern is not held to a reader's lines");
    const scaffold = read("evals", "planner-notes-stay-out", "scaffold.sh");
    for (const note of ["memory.md", "plan.md"]) {
      const body = scaffold.split(`cat >.scratch/task/${note} <<'EOF'\n`)[1].split("\nEOF\n")[0];
      assert.ok(body.includes(marker), `${note} lacks the marker`);
      assert.ok(body.includes("archive_notes"), `${note} lacks the function the spec extends`);
    }
    assert.match(scaffold, /^\.scratch\/$/m);
    assert.match(scaffold, /^git init -q$/m);
  });

  test("replay-an-ignored-tree fires the skill, dispatches the readiness reader and judges the tree's search", () => {
    const graders = gradersOf(caseOf("replay-an-ignored-tree"));
    assert.equal(graders.length, 3);
    assert.match(graders.find((block) => /tool: Skill/.test(block)), /spec-review/);
    assert.match(graders.find((block) => /tool: Agent/.test(block)), /spec-review:spec-readiness/);
    const judged = graders.find((block) => /type: llm/.test(block));
    assert.match(judged, /prune_notes/);
    assert.match(judged, /rotate_notes/);
    const scaffold = read("evals", "replay-an-ignored-tree", "scaffold.sh");
    assert.match(scaffold, /^tree=\.scratch\/task\/replay\/T9\/tree$/m);
    assert.match(scaffold, /^\.scratch\/$/m);
    assert.match(scaffold, /^git init -q$/m);
  });

  test("review-a-code-diff never fires either skill", () => {
    const graders = gradersOf(caseOf("review-a-code-diff"));
    assert.equal(graders.length, 2);
    for (const [i, [name, skillName]] of [["skill-not-fired", "spec-review"], ["claims-check-not-fired", "claims-check"]].entries()) {
      assert.match(graders[i], new RegExp(`name: ${name}$`, "m"));
      assert.match(graders[i], /type: tool_used/);
      assert.match(graders[i], /tool: Skill/);
      assert.ok(graders[i].includes(String.raw`input_match: '"skill"\s*:\s*"(?:[\w-]+:)?${skillName}"'`), `${name}'s pattern`);
      assert.match(graders[i], /min: 0/);
      assert.match(graders[i], /max: 0/);
      assert.match(graders[i], /arm: both/);
    }
  });
});
