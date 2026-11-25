// The capture behind the host's POST /v1/capture: a page taken at every target asked, in headless
// browsers launched for it alone, never in Daniel's window, as one PNG per target and an index,
// matrix.md, in a new or empty directory.
//
//   agentChromeRefusal          the line an engines list naming agent-chrome is refused with
//   fileName(engine, size)      "<engine>-<size>.png", the size id lowered with every run of
//                               characters other than letters, digits, "@" and "." turned into
//                               "-" (webkit-phone.png, chromium-iphone-15.png, firefox-1024x768@2.png)
//   defaultOutDir(checkout, now)   <checkout>/.scratch/ui/matrix-<UTC YYYYMMDD-HHMMSS>, the CLI's
//                               and the bridge's default
//   planCapture(body, project)  the capture `body` asks ({ outDir, url?, engines?, sizes?,
//                               selector?, fullPage? }, its fields already known) checked against
//                               the project (catalogue.mjs's readProject): { outDir, url (or
//                               undefined, for the caller's default), rows: [{ target, file }],
//                               selector, fullPage }, each engine's rows together in the order
//                               asked; the engines default to the project's matrix.engines, else
//                               every launched engine, the sizes to its matrix.sizes, else the five
//                               presets. Throws a one-line reason, before anything is written: an
//                               outDir not absolute, agent-chrome or an unknown engine, a bad size,
//                               a URL off localhost (guards.mjs), a bad selector or fullPage, two
//                               sizes that would write one file
//   prepareOutDir(dir)          the directory made (its parents too), or throws when it exists and
//                               is not an empty directory, so no capture overwrites another
//   await runCapture(plan, { url, storageState, drivers, track })
//                               the rows taken, engine by engine (`drivers`, the host's, by name):
//                               an unavailable engine's rows are "unavailable: <reason>"; else one
//                               headless browser (driver.launch) for the engine's rows, handed to
//                               track(browser) while it runs (track(null) after), so the host's
//                               stop can close it, and closed after them. Each row is a fresh
//                               context at its target (launched.mjs's contextOptions) with
//                               `storageState` (the window's, localhost's alone, or none) and the
//                               localhost guard (guardContext), its page loaded at `url` (30 s),
//                               then document.fonts.ready (30 s), then a screenshot with animations
//                               off and the caret hidden: the viewport, the full page with
//                               fullPage, or the first element matching the selector once it is
//                               visible (10 s). A row fails alone, its error on it: a load that
//                               fails or passes 30 s, a navigation off localhost the guard blocked,
//                               a page that redirected off localhost, no visible element. Answers
//                               { rows: [{ target, file } or { target, error }], index }, the file
//                               and index paths absolute; matrix.md has a title line, then one
//                               line per row: "- <target>, <width>x<height>@<scale>, <engine>
//                               <version>, <url>: <file name or error>"
// A navigation off localhost fails its row when the guard blocks it before the row is taken; one
// a page starts later (WebKit runs a location change set while the page parses from a timer,
// about 200 ms on) is blocked all the same, the page staying on localhost, and the row keeps the
// localhost page it took.
// The overlay is never in a capture's pages: its contexts get no init script and no binding.
import { mkdirSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import { launchedEngines, presets, resolveTarget, sizeText, targetText } from "./catalogue.mjs";
import { checkLocalUrl, isLocalUrl } from "./guards.mjs";
import { contextOptions, firstLine, guardContext } from "./launched.mjs";

export const agentChromeRefusal = "the Agent Chrome is Daniel's window; a capture uses launched engines";
const loadTimeoutMs = 30_000;
const selectorTimeoutMs = 10_000;

export const fileName = (engine, size) => `${engine}-${size.toLowerCase().replace(/[^a-z0-9@.]+/g, "-")}.png`;

// 2026-11-25T09:08:07.123Z -> 20261125-090807
const stamp = (now) => now.toISOString().slice(0, 19).replace(/[-:]/g, "").replace("T", "-");
export const defaultOutDir = (checkout, now = new Date()) => join(checkout, ".scratch", "ui", `matrix-${stamp(now)}`);

const listOf = (value, what) => {
  if (!Array.isArray(value) || value.length === 0 || value.some((each) => typeof each !== "string")) throw new Error(`${what} must be a list of ${what}`);
  return [...new Set(value)];
};

export function planCapture(body, project) {
  if (typeof body.outDir !== "string" || !isAbsolute(body.outDir)) throw new Error(`outDir must be an absolute directory, not ${body.outDir}`);
  const url = body.url === undefined ? undefined : checkLocalUrl(body.url);
  const engines = listOf(body.engines ?? project.matrix?.engines ?? launchedEngines, "engines");
  for (const engine of engines) {
    if (engine === "agent-chrome") throw new Error(agentChromeRefusal);
    if (!launchedEngines.includes(engine)) throw new Error(`unknown engine ${JSON.stringify(engine)}; a capture launches ${launchedEngines.slice(0, -1).join(", ")} or ${launchedEngines.at(-1)}`);
  }
  const sizes = listOf(body.sizes ?? project.matrix?.sizes ?? Object.keys(presets), "sizes");
  if (body.selector !== undefined && (typeof body.selector !== "string" || body.selector.trim() === "")) throw new Error("selector must be a CSS selector");
  if (body.fullPage !== undefined && typeof body.fullPage !== "boolean") throw new Error("fullPage must be true or false");
  if (body.selector !== undefined && body.fullPage) throw new Error("a capture takes a selector or fullPage, not both");
  const rows = [];
  const files = new Map();
  for (const engine of engines) {
    for (const size of sizes) {
      const target = resolveTarget(`${engine}/${size}`, project);
      const text = targetText(target);
      const name = fileName(engine, target.size);
      if (files.has(name)) {
        // The same size asked twice, as "1024x768" and "1024x768@1", is one row.
        if (files.get(name) === text) continue;
        throw new Error(`${files.get(name)} and ${text} would write one file, ${name}`);
      }
      files.set(name, text);
      rows.push({ target, file: join(body.outDir, name) });
    }
  }
  return { outDir: body.outDir, url, rows, selector: body.selector, fullPage: body.fullPage === true };
}

export function prepareOutDir(dir) {
  let entries = null;
  try {
    if (!statSync(dir).isDirectory()) throw new Error(`${dir} exists and is not a directory`);
    entries = readdirSync(dir);
  } catch (error) {
    if (error.code === "ENOENT") entries = null;
    else if (error.code) throw new Error(`${dir} cannot be read: ${error.code}`);
    else throw error;
  }
  if (entries?.length) throw new Error(`${dir} exists and is not empty; a capture writes into a new or empty directory`);
  mkdirSync(dir, { recursive: true });
}

const within = (promise, ms, reason) => {
  let timer;
  const late = new Promise((_, reject) => (timer = setTimeout(() => reject(new Error(reason)), ms)));
  return Promise.race([promise, late]).finally(() => clearTimeout(timer));
};

async function captureRow(browser, { target, file }, { url, storageState, selector, fullPage }) {
  const context = await browser.newContext(contextOptions(target, storageState));
  let blocked = null;
  const blockedLine = () => `Blocked ${blocked}: off localhost`;
  // A blocked navigation fails the row at once: Chromium's load waits on it until it times out.
  let onBlocked;
  const blocking = new Promise((_, reject) => (onBlocked = reject));
  blocking.catch(() => {});
  try {
    await guardContext(context, (address) => {
      blocked ??= address;
      onBlocked(new Error(blockedLine()));
    });
    const page = await context.newPage();
    try {
      await Promise.race([page.goto(url, { waitUntil: "load", timeout: loadTimeoutMs }), blocking]);
    } catch (error) {
      if (blocked) throw new Error(blockedLine());
      if (error.name === "TimeoutError") throw new Error(`could not load ${url} in ${loadTimeoutMs / 1000} s`);
      throw new Error(`could not load ${url}: ${firstLine(error)}`);
    }
    // A redirect is not routed, so a page that left localhost by one is caught here.
    if (!isLocalUrl(page.url())) throw new Error(`the page left localhost for ${page.url()}; a capture takes localhost pages only`);
    await within(page.evaluate(() => document.fonts.ready.then(() => null)), loadTimeoutMs, `the page's fonts did not load in ${loadTimeoutMs / 1000} s`);
    const options = { animations: "disabled", caret: "hide", timeout: loadTimeoutMs };
    let png;
    if (selector === undefined) {
      png = await page.screenshot({ ...options, fullPage });
    } else {
      const element = page.locator(selector).first();
      try {
        await element.waitFor({ state: "visible", timeout: selectorTimeoutMs });
      } catch (error) {
        if (error.name === "TimeoutError") throw new Error(`no visible element matches ${JSON.stringify(selector)} after ${selectorTimeoutMs / 1000} s`);
        throw new Error(`the selector ${JSON.stringify(selector)}: ${firstLine(error)}`);
      }
      png = await element.screenshot(options);
    }
    if (blocked) throw new Error(blockedLine());
    writeFileSync(file, png);
  } finally {
    await context.close().catch(() => {});
  }
}

export async function runCapture(plan, { url, storageState, drivers, track = () => {} }) {
  const rows = [];
  const lines = [];
  const engines = [...new Set(plan.rows.map((row) => row.target.engine))];
  for (const engine of engines) {
    const driver = drivers.get(engine);
    const version = driver.version();
    let browser = null;
    let refusal = null;
    const state = await driver.available();
    if (!state.available) {
      refusal = `unavailable: ${state.reason}`;
    } else {
      try {
        browser = await driver.launch({ headless: true });
        track(browser);
      } catch (error) {
        refusal = `${engine} could not start: ${firstLine(error)}`;
      }
    }
    try {
      for (const row of plan.rows.filter((each) => each.target.engine === engine)) {
        let result;
        if (refusal) {
          result = { error: refusal };
        } else {
          try {
            await captureRow(browser, row, { url, storageState, selector: plan.selector, fullPage: plan.fullPage });
            result = { file: row.file };
          } catch (error) {
            result = { error: firstLine(error) };
          }
        }
        const target = targetText(row.target);
        rows.push({ target, ...result });
        lines.push(`- ${target}, ${sizeText(row.target)}, ${engine} ${version}, ${url}: ${result.file ? basename(result.file) : result.error}`);
      }
    } finally {
      if (browser) {
        track(null);
        await browser.close().catch(() => {});
      }
    }
  }
  const index = join(plan.outDir, "matrix.md");
  writeFileSync(index, `# proto capture, ${new Date().toISOString().slice(0, 19)}Z\n\n${lines.join("\n")}\n`);
  return { rows, index };
}
