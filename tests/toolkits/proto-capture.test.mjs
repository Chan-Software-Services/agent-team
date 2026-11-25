// The capture (toolkits/frontend/scripts/proto capture, POST /v1/capture), driven through the CLI
// and the host's API as Daniel and the session do, headless, in a runtime directory of each
// test's own (helpers/proto.mjs), against a fixture site on 127.0.0.1 that records every request
// it is sent. Its page shows its width class (narrow below 600 CSS px, medium below 1200, wide
// from 1200) by a media query, as the body's colour, and reports what it saw (innerWidth,
// innerHeight, devicePixelRatio, the class, whether the overlay is in) by an image request
// written before load, recorded with the request's user agent and cookie.
// It checks each row's PNG against its target (its pixel size, and the colour of its width
// class) for the presets, a device and a free size in every engine the machine has, a full-page
// and an element capture, the window's localhost login carried and none with no window, the
// window left as it was and no overlay in a capture, the defaults (the project's matrix, else
// every launched engine at the five presets, the output directory in the checkout), an
// unavailable engine's rows, a row that fails alone (no element at one width, a navigation off
// localhost, a redirect off localhost, a load past 30 s), the exit status, the refusals with
// nothing written, matrix.md, and two captures at once running one after the other. Every engine
// the machine has runs; under CI=true a missing one fails, elsewhere it skips with its reason.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { describe, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { repoRoot, tempDir } from "./helpers/mcp.mjs";
import { browsersWithout, pngPixel, pngSize, protoSession } from "./helpers/proto.mjs";

const engines = ["chromium", "firefox", "webkit"];
const iPhone = JSON.parse(execFileSync(process.execPath, ["-e", `process.stdout.write(JSON.stringify(require(${JSON.stringify(join(repoRoot, "servers", "node_modules", "playwright-core"))}).devices["iPhone 15"]))`], { encoding: "utf8" }));

const presets = {
  "phone-small": { width: 360, height: 800, scale: 3 },
  phone: { width: 390, height: 844, scale: 3 },
  tablet: { width: 768, height: 1024, scale: 2 },
  laptop: { width: 1440, height: 900, scale: 1 },
  desktop: { width: 1920, height: 1080, scale: 1 },
};
const sizes = {
  ...presets,
  "iPhone 15": { width: iPhone.viewport.width, height: iPhone.viewport.height, scale: iPhone.deviceScaleFactor, userAgent: iPhone.userAgent },
  "1024x768@2": { width: 1024, height: 768, scale: 2 },
};
const fileNames = {
  "phone-small": "phone-small",
  phone: "phone",
  tablet: "tablet",
  laptop: "laptop",
  desktop: "desktop",
  "iPhone 15": "iphone-15",
  "1024x768@2": "1024x768@2",
};

const widthClass = (width) => (width >= 1200 ? "wide" : width >= 600 ? "medium" : "narrow");
const colours = { narrow: [200, 0, 0], medium: [0, 200, 0], wide: [0, 0, 200] };

// Each engine's user agent, as its page's request sends it.
const agents = {
  chromium: (agent) => /Chrome\//.test(agent) && !/Firefox\//.test(agent),
  firefox: (agent) => /Firefox\//.test(agent),
  webkit: (agent) => /Version\/[\d.]+ Safari\//.test(agent) && !/Chrome\//.test(agent),
};

const listen = (server, port, host) => new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(port, host, () => resolve(server.address().port));
});

// The fixture site. /page takes, in its query: `long` (the page 3000 px tall), `away=narrow` (at
// a narrow width its script sends the page off localhost, to [::1]), `hang=narrow` (at a narrow
// width it writes an image that never answers, so the page never loads), `slow=<ms>` (its
// report answers that late, so the page loads that late), and `tag`, kept in the report.
// /login sets the login cookie; /redirect answers 302 to [::1]'s page.
async function fixture(t) {
  const requests = [];
  const reports = [];
  let site;
  const hanging = new Set();
  const handler = (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host}`);
    const query = Object.fromEntries(url.searchParams);
    requests.push({ origin: url.origin, path: url.pathname, query, cookie: request.headers.cookie ?? "", agent: request.headers["user-agent"] ?? "", at: Date.now() });
    const html = (body) => {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end(`<!doctype html><meta name="viewport" content="width=device-width">${body}`);
    };
    switch (url.pathname) {
      case "/login":
        return html(`<title>login</title><script>document.cookie = "login=yes; path=/"</script><p>logged in</p>`);
      case "/page": {
        const report = `const cls = matchMedia("(min-width: 1200px)").matches ? "wide" : matchMedia("(min-width: 600px)").matches ? "medium" : "narrow";
          const fields = { width: innerWidth, height: innerHeight, scale: devicePixelRatio, cls, overlay: typeof window.__protoOverlay, tag: ${JSON.stringify(query.tag ?? "")}, slow: ${JSON.stringify(query.slow ?? "0")} };
          document.write('<img alt="" src="/report?' + new URLSearchParams(fields) + '">');
          if (${JSON.stringify(query.away ?? "")} === cls) location.href = ${JSON.stringify(`${site?.other ?? ""}page`)};
          if (${JSON.stringify(query.hang ?? "")} === cls) document.write('<img alt="" src="/never">');`;
        return html(`<title>page</title><style>
          html, body { margin: 0 }
          body { background: rgb(200, 0, 0); ${query.long ? "height: 3000px;" : ""} }
          @media (min-width: 600px) { body { background: rgb(0, 200, 0) } }
          @media (min-width: 1200px) { body { background: rgb(0, 0, 200) } }
          #box { position: absolute; left: 20px; top: 40px; width: 200px; height: 100px; background: rgb(250, 200, 0) }
          #wide-only { display: none }
          @media (min-width: 1200px) { #wide-only { display: block; position: absolute; left: 300px; top: 40px; width: 120px; height: 60px; background: white } }
          #class { position: absolute; left: 20px; top: 200px; margin: 0; font: 16px sans-serif }
          #class::after { content: "narrow" }
          @media (min-width: 600px) { #class::after { content: "medium" } }
          @media (min-width: 1200px) { #class::after { content: "wide" } }
        </style><div id="box"></div><div id="wide-only"></div><p id="class"></p><script>${report}</script>`);
      }
      case "/report": {
        reports.push({ ...Object.fromEntries(url.searchParams), agent: request.headers["user-agent"] ?? "", cookie: request.headers.cookie ?? "", at: Date.now() });
        const end = () => {
          response.writeHead(204);
          response.end();
        };
        const slow = Number(query.slow ?? 0);
        return slow ? setTimeout(end, slow) : end();
      }
      case "/redirect":
        response.writeHead(302, { location: `${site.other}page` });
        return response.end();
      case "/never":
        hanging.add(response);
        return undefined;
      default:
        response.writeHead(404);
        return response.end("not found");
    }
  };
  const servers = [createServer(handler), createServer(handler)];
  const main = await listen(servers[0], 0, "127.0.0.1");
  const other = await listen(servers[1], 0, "::1");
  site = { url: `http://127.0.0.1:${main}/`, other: `http://[::1]:${other}/` };
  t.after(() => Promise.all(servers.map((server) => new Promise((resolve) => {
    server.closeAllConnections();
    server.close(resolve);
  }))));
  return { ...site, requests, reports, mark: () => reports.length, since: (mark) => reports.slice(mark) };
}

// A git checkout holding `settings` as its .proto.json, or none.
function checkout(settings) {
  const dir = tempDir("proto-checkout");
  execFileSync("git", ["init", "-q", dir]);
  if (settings !== undefined) writeFileSync(join(dir, ".proto.json"), JSON.stringify(settings));
  return dir;
}

// The rows `proto capture` printed: { target: file or error }, and the index's path.
function printed(stdout) {
  const lines = stdout.trimEnd().split("\n");
  const index = lines.pop();
  assert.match(index, /^proto: index: \//, stdout);
  const rows = {};
  for (const line of lines) {
    const match = /^proto: (\S+(?: \d+)?): (.*)$/.exec(line);
    assert.ok(match, `a row's line: ${line}`);
    rows[match[1]] = match[2];
  }
  return { rows, index: index.slice("proto: index: ".length) };
}

const capture = (proto, args, options) => proto.run(["capture", ...args], options);
const sizeArgs = (list) => list.flatMap((size) => ["--size", size]);

describe("each row's PNG", () => {
  for (const engine of engines) {
    test(`${engine}: the presets, a device and a free size each have their target's pixels and saw their own width; a full page and an element have theirs`, async (t) => {
      const proto = protoSession(t);
      const site = await fixture(t);
      if (!(await proto.engine(t, engine))) return;
      const out = join(tempDir("capture"), "out");
      const mark = site.mark();
      const result = await capture(proto, ["--url", `${site.url}page`, "--engine", engine, ...sizeArgs(Object.keys(sizes)), "--out", out]);
      assert.equal(result.status, 0, result.stderr);
      const { rows, index } = printed(result.stdout);
      assert.equal(index, join(out, "matrix.md"));
      assert.deepEqual(Object.keys(rows), Object.keys(sizes).map((size) => `${engine}/${size}`), "one row per size, in order");
      const seen = site.since(mark);
      for (const [size, want] of Object.entries(sizes)) {
        const file = join(out, `${engine}-${fileNames[size]}.png`);
        assert.equal(rows[`${engine}/${size}`], file);
        assert.deepEqual(pngSize(file), { width: want.width * want.scale, height: want.height * want.scale }, `${engine}/${size}'s pixels`);
        assert.deepEqual(pngPixel(file, 2, 2), colours[widthClass(want.width)], `${engine}/${size} shows its width class`);
        const report = seen.filter((each) => Number(each.width) === want.width && Number(each.scale) === want.scale);
        assert.equal(report.length, 1, `${engine}/${size}: one load at its width and scale: ${JSON.stringify(seen)}`);
        assert.equal(report[0].cls, widthClass(want.width), `${engine}/${size}'s media query`);
        assert.equal(Number(report[0].height), want.height, `${engine}/${size}'s height`);
        assert.equal(report[0].overlay, "undefined", `${engine}/${size}: no overlay in a capture`);
        if (want.userAgent) assert.equal(report[0].agent, want.userAgent, `${engine}/${size}: the device's user agent`);
        else assert.ok(agents[engine](report[0].agent), `${engine}/${size}'s user agent: ${report[0].agent}`);
      }
      assert.deepEqual(readdirSync(out).sort(), [...Object.values(fileNames).map((name) => `${engine}-${name}.png`), "matrix.md"].sort());

      const fullOut = join(tempDir("capture"), "full");
      const full = await capture(proto, ["--url", `${site.url}page?long=1`, "--engine", engine, "--size", "laptop", "--full-page", "--out", fullOut]);
      assert.equal(full.status, 0, full.stderr);
      const fullSize = pngSize(join(fullOut, `${engine}-laptop.png`));
      assert.equal(fullSize.width, 1440);
      assert.ok(fullSize.height >= 3000, `the full page is taller than the viewport: ${fullSize.height}`);

      const boxOut = join(tempDir("capture"), "box");
      const box = await capture(proto, ["--url", `${site.url}page`, "--engine", engine, "--size", "phone", "--size", "laptop", "--selector", "#box", "--out", boxOut]);
      assert.equal(box.status, 0, box.stderr);
      assert.deepEqual(pngSize(join(boxOut, `${engine}-phone.png`)), { width: 600, height: 300 });
      assert.deepEqual(pngSize(join(boxOut, `${engine}-laptop.png`)), { width: 200, height: 100 });
      assert.deepEqual(pngPixel(join(boxOut, `${engine}-phone.png`), 300, 150), [250, 200, 0], "the element's own pixels");
    });
  }
});

describe("the window's login and the window itself", () => {
  test("a capture carries the window's localhost login, leaves the window's engine, size and URL as they were while it runs, and has no overlay; with no window it sends no cookie", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    if (!(await proto.engine(t, "chromium"))) return;

    const bare = join(tempDir("capture"), "bare");
    let mark = site.mark();
    const alone = await capture(proto, ["--url", `${site.url}page`, "--engine", "chromium", "--size", "laptop", "--out", bare]);
    assert.equal(alone.status, 0, alone.stderr);
    assert.deepEqual(site.since(mark).map((each) => each.cookie), [""], "with no window, no cookie");

    assert.equal((await proto.run(["open", `${site.url}login`, "--target", "chromium/tablet"])).status, 0);
    const followed = await proto.page("navigate", { url: `${site.url}page?tag=window` });
    assert.equal(followed.url, `${site.url}page?tag=window`);
    const before = await proto.page("metrics");
    const status = (await proto.run(["status"])).stdout;
    const host = await proto.hostPid();
    assert.equal(status, `proto: host ${host}; window chromium/tablet on ${site.url}page?tag=window\n`);
    const [windowReport] = site.reports.filter((each) => each.tag === "window");
    assert.equal(windowReport.overlay, "object", "the window's page has the overlay");

    const out = join(tempDir("capture"), "login");
    mark = site.mark();
    // Each row's page loads 2 s late, so the window is read while the capture runs.
    const running = capture(proto, ["--url", `${site.url}page?slow=2000&tag=capture`, "--engine", "chromium", "--size", "phone", "--size", "desktop", "--out", out]);
    for (let read = 0; read < 3; read++) {
      await sleep(700);
      const during = await proto.page("metrics");
      assert.deepEqual(during, before, "the window while the capture runs");
      assert.equal((await proto.run(["status"])).stdout, status);
    }
    const result = await running;
    assert.equal(result.status, 0, result.stderr);
    const rows = site.since(mark).filter((each) => each.tag === "capture");
    assert.equal(rows.length, 2);
    for (const row of rows) {
      assert.match(row.cookie, /(^|; )login=yes($|;)/, "the window's login carried");
      assert.equal(row.overlay, "undefined", "no overlay in a capture");
    }
    assert.deepEqual(await proto.page("metrics"), before, "the window after the capture");
    assert.equal((await proto.run(["status"])).stdout, status);

    // With no --url, the window's own page.
    const here = join(tempDir("capture"), "here");
    mark = site.mark();
    const own = await capture(proto, ["--engine", "chromium", "--size", "laptop", "--out", here]);
    assert.equal(own.status, 0, own.stderr);
    assert.deepEqual(site.since(mark).map((each) => [each.tag, each.width]), [["window", "1440"]]);
    assert.match(readFileSync(join(here, "matrix.md"), "utf8"), new RegExp(`${site.url.replaceAll(".", "\\.")}page\\?tag=window`));
  });
});

describe("the defaults", () => {
  test("the project's matrix when .proto.json has one, its url, and the output directory in the checkout's .scratch/ui", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    const names = (await proto.engines()).filter((engine) => engine.available).map((engine) => engine.name);
    if (!names.includes("chromium") || !names.includes("firefox")) {
      if (process.env.CI === "true") assert.fail(`in CI every engine runs, but only ${names.join(", ")} did`);
      return t.skip("chromium and firefox are needed");
    }
    const dir = checkout({ url: `${site.url}page`, matrix: { engines: ["firefox", "chromium"], sizes: ["phone", "1024x768"] } });
    const started = new Date();
    const result = await capture(proto, [], { cwd: dir });
    assert.equal(result.status, 0, result.stderr);
    const { rows, index } = printed(result.stdout);
    assert.deepEqual(Object.keys(rows), ["firefox/phone", "firefox/1024x768", "chromium/phone", "chromium/1024x768"]);
    const out = index.slice(0, -"/matrix.md".length);
    const name = /^(.*)\/matrix-(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)$/.exec(out);
    assert.ok(name, out);
    assert.equal(name[1], join(dir, ".scratch", "ui"));
    const stamp = Date.UTC(Number(name[2]), Number(name[3]) - 1, Number(name[4]), Number(name[5]), Number(name[6]), Number(name[7]));
    assert.ok(stamp >= Math.floor(started.getTime() / 1000) * 1000 && stamp <= Date.now(), `the directory's UTC time ${out}`);
    assert.equal(rows["chromium/1024x768"], join(out, "chromium-1024x768.png"));
    assert.deepEqual(pngSize(rows["firefox/phone"]), { width: 1170, height: 2532 });
  });

  test("with no matrix, every launched engine at the five presets; an unavailable engine's rows say so while the others capture, and with none captured it exits 1", async (t) => {
    const site = await fixture(t);
    const probe = protoSession(t);
    const available = (await probe.engines()).filter((engine) => engine.available).map((engine) => engine.name);
    if (process.env.CI === "true") assert.deepEqual(available, engines, "in CI every engine runs");
    const proto = protoSession(t, { env: { PROTO_BROWSERS_PATH: browsersWithout("firefox") } });
    const dir = checkout({ url: `${site.url}page` });
    const result = await capture(proto, [], { cwd: dir });
    const { rows, index } = printed(result.stdout);
    const targets = engines.flatMap((engine) => Object.keys(presets).map((size) => `${engine}/${size}`));
    assert.deepEqual(Object.keys(rows), targets);
    const captured = available.filter((engine) => engine !== "firefox");
    assert.equal(result.status, captured.length ? 0 : 1, result.stderr);
    for (const target of targets) {
      const [engine, size] = target.split("/");
      if (engine === "firefox") {
        assert.match(rows[target], /^unavailable: firefox \S+ is not installed \(no .+\); run `proto install`$/, target);
      } else if (captured.includes(engine)) {
        assert.equal(rows[target], join(index, "..", `${engine}-${size}.png`), target);
        assert.deepEqual(pngSize(rows[target]), { width: presets[size].width * presets[size].scale, height: presets[size].height * presets[size].scale }, target);
      } else {
        assert.match(rows[target], new RegExp(`^unavailable: ${engine} `), target);
      }
    }
    const lines = readFileSync(index, "utf8").split("\n").filter((line) => line.startsWith("- "));
    assert.equal(lines.length, 15, "one line per row in matrix.md");

    const none = join(tempDir("capture"), "none");
    const nothing = await capture(proto, ["--url", `${site.url}page`, "--engine", "firefox", "--out", none]);
    assert.equal(nothing.status, 1);
    assert.equal(Object.keys(printed(nothing.stdout).rows).length, 5);
    assert.equal(nothing.stderr, `proto: no target was captured; see ${join(none, "matrix.md")}\n`);
  });

  test("outside a git checkout --out is required, and given it the capture runs there", async (t) => {
    const proto = protoSession(t, { env: { PROTO_BROWSERS_PATH: browsersWithout("firefox") } });
    const site = await fixture(t);
    const outside = tempDir("not-a-checkout");
    const refused = await capture(proto, ["--url", `${site.url}page`], { cwd: outside });
    assert.deepEqual(refused, { status: 1, stdout: "", stderr: "proto: outside a git checkout, proto capture needs --out <an absolute directory>\n" });
    assert.equal(await proto.hostPid(), null, "refused before a host starts");
    const out = join(outside, "shots");
    const given = await capture(proto, ["--url", `${site.url}page`, "--engine", "firefox", "--size", "phone", "--out", out], { cwd: outside });
    assert.equal(given.status, 1, "firefox is unavailable here, so none captured");
    assert.deepEqual(readdirSync(out), ["matrix.md"]);
  });
});

describe("a row that fails", () => {
  test("fails alone, with its error on its row: no element at one width, a load past 30 s; a redirect off localhost fails its rows", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    if (!(await proto.engine(t, "chromium"))) return;
    const run = async (url, extra) => {
      const out = join(tempDir("capture"), "rows");
      const result = await capture(proto, ["--url", url, "--engine", "chromium", "--size", "phone", "--size", "laptop", ...extra, "--out", out]);
      return { ...result, ...printed(result.stdout), out };
    };

    const selector = await run(`${site.url}page`, ["--selector", "#wide-only"]);
    assert.equal(selector.status, 0, selector.stderr);
    assert.equal(selector.rows["chromium/phone"], `no visible element matches "#wide-only" after 10 s`);
    assert.deepEqual(pngSize(selector.rows["chromium/laptop"]), { width: 120, height: 60 });

    const started = Date.now();
    const hang = await run(`${site.url}page?hang=narrow`, []);
    assert.equal(hang.status, 0, hang.stderr);
    assert.ok(Date.now() - started >= 30_000, "the load was waited for 30 s");
    assert.match(hang.rows["chromium/phone"], new RegExp(`^could not load ${site.url.replaceAll(".", "\\.")}page\\?hang=narrow in 30 s`));
    assert.deepEqual(pngSize(hang.rows["chromium/laptop"]), { width: 1440, height: 900 });
    assert.deepEqual(readdirSync(hang.out).sort(), ["chromium-laptop.png", "matrix.md"]);

    const redirect = await run(`${site.url}redirect`, []);
    assert.equal(redirect.status, 1);
    for (const row of ["chromium/phone", "chromium/laptop"]) {
      assert.equal(redirect.rows[row], `the page left localhost for ${site.other}page; a capture takes localhost pages only`);
    }
    assert.deepEqual(readdirSync(redirect.out), ["matrix.md"]);
  });
});

describe("a navigation off localhost", () => {
  for (const engine of engines) {
    test(`${engine}: fails its row at once, the others captured, and nothing is sent off localhost`, async (t) => {
      const proto = protoSession(t);
      const site = await fixture(t);
      if (!(await proto.engine(t, engine))) return;
      const out = join(tempDir("capture"), "away");
      const started = Date.now();
      // The page loads 1.5 s late, so its navigation is sent before the load in every engine:
      // WebKit runs a location change a script makes while the page parses from a timer, about
      // 200 ms later, which a page that loads at once has passed before it is taken.
      const result = await capture(proto, ["--url", `${site.url}page?away=narrow&slow=1500`, "--engine", engine, "--size", "phone", "--size", "laptop", "--out", out]);
      assert.equal(result.status, 0, result.stderr);
      assert.ok(Date.now() - started < 20_000, "a blocked navigation fails its row at once, not at the load's 30 s");
      const { rows } = printed(result.stdout);
      assert.equal(rows[`${engine}/phone`], `Blocked ${site.other}page: off localhost`);
      assert.deepEqual(pngSize(rows[`${engine}/laptop`]), { width: 1440, height: 900 });
      assert.deepEqual(readdirSync(out).sort(), [`${engine}-laptop.png`, "matrix.md"].sort());
      assert.ok(!site.requests.some((each) => each.origin === new URL(site.other).origin), "nothing was sent off localhost");
    });
  }
});

describe("the refusals", () => {
  test("--help describes capture, and a malformed capture command line exits 2 before a host starts", async (t) => {
    const proto = protoSession(t);
    const help = await proto.run(["--help"]);
    assert.equal(help.status, 0);
    assert.match(help.stdout, /^ {7}proto capture \[--url <url>\] \[--engine <engine>\]\.\.\. \[--size <size>\]\.\.\. \[--selector <css>\]$/m);
    assert.match(help.stdout, /^ {2}capture {2}starts the host when none runs and takes the page at every target asked/m);
    for (const args of [["--url"], ["--engine"], ["--out", "/a", "--out", "/b"], ["--bogus"], ["stray"]]) {
      const result = await capture(proto, args);
      assert.equal(result.status, 2, `${args.join(" ")}: ${result.stderr}`);
      assert.match(result.stderr, /^proto: usage: proto open .* \| capture \[--url <url>\]/);
    }
    assert.equal(await proto.hostPid(), null);
  });

  test("agent-chrome in the engines, an outDir relative or not empty, a URL off localhost and a bad size are refused, and nothing is written", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    const cwd = tempDir("capture-cwd");
    const empty = join(cwd, "fresh");
    const refusals = [
      [["--engine", "agent-chrome", "--out", empty], "the Agent Chrome is Daniel's window; a capture uses launched engines"],
      [["--engine", "chromium", "--engine", "agent-chrome", "--out", empty], "the Agent Chrome is Daniel's window; a capture uses launched engines"],
      [["--engine", "opera", "--out", empty], `unknown engine "opera"; a capture launches chromium, firefox or webkit`],
      [["--size", "window", "--out", empty], `the size "window" is the Agent Chrome's own window, for agent-chrome only, not chromium`],
      [["--size", "huge", "--out", empty], `unknown size "huge"; a size is a preset (phone-small, phone, tablet, laptop, desktop), a project size, a Playwright device name, or <width>x<height>[@<scale>]`],
      [["--out", "relative/dir"], "outDir must be an absolute directory, not relative/dir"],
    ];
    for (const [args, reason] of refusals) {
      const result = await capture(proto, ["--url", `${site.url}page`, ...args], { cwd });
      assert.deepEqual(result, { status: 1, stdout: "", stderr: `proto: ${reason}\n` }, args.join(" "));
    }
    assert.deepEqual(readdirSync(cwd), [], "nothing written");

    const full = join(cwd, "full");
    mkdirSync(full);
    writeFileSync(join(full, "earlier.png"), "earlier");
    const notEmpty = await capture(proto, ["--url", `${site.url}page`, "--out", full], { cwd });
    assert.deepEqual(notEmpty, { status: 1, stdout: "", stderr: `proto: ${full} exists and is not empty; a capture writes into a new or empty directory\n` });
    assert.deepEqual(readdirSync(full), ["earlier.png"]);
    assert.equal(readFileSync(join(full, "earlier.png"), "utf8"), "earlier");

    const offLocal = await capture(proto, ["--url", "http://example.com/", "--out", empty], { cwd });
    assert.deepEqual(offLocal, { status: 1, stdout: "", stderr: "proto: http://example.com/ is off localhost; proto opens only http or https on localhost or 127.0.0.1\n" });
    const api = (body) => proto.request("POST", "/v1/capture", body);
    assert.deepEqual(await api({ outDir: empty, url: "http://localhost.example.com/" }), { status: 400, body: { error: "http://localhost.example.com/ is off localhost; proto opens only http or https on localhost or 127.0.0.1" } });
    assert.deepEqual(await api({ url: `${site.url}page` }), { status: 400, body: { error: "outDir must be an absolute directory, not undefined" } });
    assert.deepEqual(await api({ outDir: empty, colour: "red" }), { status: 400, body: { error: `unknown field "colour"; this route takes outDir, url, engines, sizes, selector, fullPage, project` } });
    assert.deepEqual(await api({ outDir: empty, engines: "chromium" }), { status: 400, body: { error: "engines must be a list of engines" } });
    assert.deepEqual(await api({ outDir: empty, fullPage: "yes" }), { status: 400, body: { error: "fullPage must be true or false" } });
    assert.ok(!existsSync(empty), "nothing written");
  });
});

describe("matrix.md and the file names", () => {
  test("one line per row: the target, its width, height and scale, the engine's version, the URL, and the file or the error", async (t) => {
    const proto = protoSession(t, { env: { PROTO_BROWSERS_PATH: browsersWithout("firefox") } });
    const site = await fixture(t);
    if (!(await proto.engine(t, "chromium"))) return;
    const { body } = await proto.request("GET", "/v1/targets");
    const version = (name) => body.engines.find((engine) => engine.name === name).version;
    const out = join(tempDir("capture"), "index");
    const url = `${site.url}page`;
    const result = await capture(proto, ["--url", url, "--engine", "chromium", "--engine", "firefox", "--size", "iPhone 15", "--size", "1024x768@2", "--out", out]);
    assert.equal(result.status, 0, result.stderr);
    const unavailable = body.engines.find((engine) => engine.name === "firefox").reason;
    const device = `${iPhone.viewport.width}x${iPhone.viewport.height}@${iPhone.deviceScaleFactor}`;
    const lines = readFileSync(join(out, "matrix.md"), "utf8").split("\n");
    assert.match(lines[0], /^# proto capture, \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.deepEqual(lines.slice(1), [
      "",
      `- chromium/iPhone 15, ${device}, chromium ${version("chromium")}, ${url}: chromium-iphone-15.png`,
      `- chromium/1024x768@2, 1024x768@2, chromium ${version("chromium")}, ${url}: chromium-1024x768@2.png`,
      `- firefox/iPhone 15, ${device}, firefox ${version("firefox")}, ${url}: unavailable: ${unavailable}`,
      `- firefox/1024x768@2, 1024x768@2, firefox ${version("firefox")}, ${url}: unavailable: ${unavailable}`,
      "",
    ]);
    const answer = await proto.request("POST", "/v1/capture", { outDir: join(tempDir("capture"), "api"), url, engines: ["chromium"], sizes: ["phone"] });
    assert.equal(answer.status, 200, JSON.stringify(answer.body));
    assert.deepEqual(Object.keys(answer.body), ["rows", "index"]);
    assert.deepEqual(answer.body.rows, [{ target: "chromium/phone", file: join(answer.body.index, "..", "chromium-phone.png") }]);
  });
});

describe("two captures at once", () => {
  test("run one after the other", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    if (!(await proto.engine(t, "chromium"))) return;
    const both = await Promise.all(["a", "b"].map((tag) => capture(proto, ["--url", `${site.url}page?slow=500&tag=${tag}`, "--engine", "chromium", "--size", "phone", "--size", "laptop", "--out", join(tempDir("capture"), tag)])));
    for (const result of both) assert.equal(result.status, 0, result.stderr);
    const times = (tag) => site.reports.filter((each) => each.tag === tag).map((each) => each.at);
    const [a, b] = [times("a"), times("b")];
    assert.equal(a.length, 2);
    assert.equal(b.length, 2);
    const [first, second] = Math.min(...a) < Math.min(...b) ? [a, b] : [b, a];
    assert.ok(Math.max(...first) < Math.min(...second), `one after the other: ${JSON.stringify({ a, b })}`);
  });
});
