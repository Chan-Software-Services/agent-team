// The prototyping window's overlay toolbar (toolkits/frontend/proto/overlay.js), driven as Daniel
// drives it: by role and accessible name through the host's test seam (POST /v1/test/toolbar),
// the host headless in a runtime directory of each test's own (helpers/proto.mjs), against a
// fixture site on 127.0.0.1 that records each request and the reports its pages send. It checks
// that the overlay is in before the page's first script in the top frame alone, and draws nothing
// in a page that is not the window's; the toolbar's controls, their roles and names, and an
// unavailable engine's option; that choosing an engine, a size or a custom size switches the
// window as `proto set` does; the controls while a switch runs and the status of one that fails;
// "Reload", "Hide toolbar" and the collapsed state across a reload and switches; the status of a
// blocked navigation; a message of an unknown type; and that the page's CSS and the toolbar's
// leave each other's computed styles alone. Every engine the machine has runs; under CI=true a
// missing one fails, elsewhere it skips with its reason.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { describe, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { repoRoot } from "./helpers/mcp.mjs";
import { browsersWithout, protoSession } from "./helpers/proto.mjs";

const engines = ["chromium", "firefox", "webkit"];
const agents = {
  chromium: (agent) => /Chrome\//.test(agent) && !/Firefox\//.test(agent),
  firefox: (agent) => /Firefox\//.test(agent),
  webkit: (agent) => /Version\/[\d.]+ Safari\//.test(agent) && !/Chrome\//.test(agent),
};

const listen = (server, port, host) => new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(port, host, () => resolve(server.address().port));
});

// The computed styles the style probe compares, on the page's elements and on the toolbar's.
const properties = [
  "color", "background-color", "font-family", "font-size", "font-weight", "font-style", "line-height", "letter-spacing",
  "text-transform", "margin-top", "margin-right", "padding-top", "padding-left", "border-top-width", "border-top-style",
  "border-top-color", "box-sizing", "display", "position", "width", "height", "opacity", "z-index", "right", "bottom",
];

// A page's last script: its own elements' computed styles now, before the overlay draws, then,
// once the toolbar is in, its own again and the toolbar's, posted to /styles.
const styleProbe = `<script>(() => {
  const properties = ${JSON.stringify(properties)};
  const read = (node) => {
    const style = getComputedStyle(node);
    return Object.fromEntries(properties.map((name) => [name, style.getPropertyValue(name)]));
  };
  const own = () => Object.fromEntries(["html", "body", "#text", "#page-button", "#page-select"].map((selector) => [selector, read(document.querySelector(selector))]));
  const before = own();
  const started = Date.now();
  const wait = () => {
    const root = document.querySelector("proto-overlay")?.shadowRoot;
    const bar = root?.querySelector("[role=toolbar]");
    if (!bar) {
      if (Date.now() - started < 15000) setTimeout(wait, 50);
      return;
    }
    const toolbar = {
      host: read(document.querySelector("proto-overlay")),
      bar: read(bar),
      select: read(root.querySelector("select")),
      button: read(root.querySelector("button")),
      status: read(root.querySelector("[role=status]")),
    };
    fetch("/styles?page=" + location.pathname.slice(1), { method: "POST", body: JSON.stringify({ before, after: own(), toolbar }) });
  };
  wait();
})()</script>`;

// CSS that would reach the toolbar if anything could: every element, the controls, the element's
// own name, and :root's variables and font size.
const hostileCss = `<style>
  :root { --bg: red; --fg: lime; --proto-bg: red; color-scheme: light; font-size: 40px; }
  * { font-family: serif !important; color: red !important; background: yellow; margin: 7px; padding: 3px; letter-spacing: 2px; box-sizing: content-box; line-height: 3; text-transform: uppercase; opacity: 0.9; }
  button, select, input { all: unset; border: 5px solid red !important; font-size: 30px !important; display: block; width: 300px; }
  proto-overlay { display: none !important; position: static !important; right: auto; bottom: auto; }
</style>`;

// The fixture site: its pages on 127.0.0.1 and a frame on [::1]. Each request is recorded as
// { origin, path, query }; each page's first script reports the type of window.__protoOverlay
// (/report?first=), and each frame's (/report?frame=), both written before the page's load ends.
// /slow answers after 1.5 s; with `failing` set, a page's request is cut off.
async function fixture(t) {
  const requests = [];
  const styles = {};
  let site;
  const handler = (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host}`);
    requests.push({ origin: url.origin, path: url.pathname, query: Object.fromEntries(url.searchParams) });
    const html = (body) => {
      if (site.failing) return request.socket.destroy();
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      return response.end(`<!doctype html><meta name="viewport" content="width=device-width">${body}`);
    };
    const first = `<script>document.write('<img alt="" src="/report?first=' + typeof window.__protoOverlay + '">')</script>`;
    const own = `<p id="text">a paragraph</p><button id="page-button">A page button</button><select id="page-select"><option>one</option></select>`;
    switch (url.pathname) {
      case "/plain":
        return html(`<title>plain</title>${first}<iframe src="/frame"></iframe><iframe src="${site.other}frame"></iframe>${own}${styleProbe}`);
      case "/styled":
        return html(`<title>styled</title>${hostileCss}${first}${own}${styleProbe}`);
      case "/other":
        return html(`<title>other</title>${first}<p>other</p>`);
      case "/slow":
        return setTimeout(() => html(`<title>slow</title>${first}<p>slow</p>`), 1500);
      case "/frame":
        return html(`<script>document.write('<img alt="" src="/report?frame=' + typeof window.__protoOverlay + '">')</script>frame`);
      case "/report":
        response.writeHead(204);
        return response.end();
      case "/styles": {
        let text = "";
        request.setEncoding("utf8").on("data", (chunk) => (text += chunk));
        return request.on("end", () => {
          styles[url.searchParams.get("page")] = JSON.parse(text);
          response.writeHead(204);
          response.end();
        });
      }
      default:
        response.writeHead(404);
        return response.end("not found");
    }
  };
  const servers = [createServer(handler), createServer(handler)];
  const main = await listen(servers[0], 0, "127.0.0.1");
  const other = await listen(servers[1], 0, "::1");
  site = { url: `http://127.0.0.1:${main}/`, other: `http://[::1]:${other}/`, failing: false };
  t.after(() => Promise.all(servers.map((server) => new Promise((resolve) => {
    server.closeAllConnections();
    server.close(resolve);
  }))));
  return Object.assign(site, {
    requests,
    mark: () => requests.length,
    reports: (mark, key) => requests.slice(mark).filter((each) => each.path === "/report" && key in each.query).map((each) => each.query[key]),
    pages: (mark, path) => requests.slice(mark).filter((each) => each.origin === new URL(site.url).origin && each.path === path).length,
    async styles(page) {
      for (let waited = 0; !styles[page] && waited < 20_000; waited += 50) await sleep(50);
      assert.ok(styles[page], `the ${page} page posted its styles`);
      const posted = styles[page];
      delete styles[page];
      return posted;
    },
  });
}

async function available(t, proto, least) {
  const names = (await proto.engines()).filter((engine) => engine.available).map((engine) => engine.name);
  if (names.length >= least) return names;
  if (process.env.CI === "true") assert.fail(`in CI every engine runs, but only ${names.join(", ") || "none"} did`);
  t.skip(`${least} engines are needed; only ${names.join(", ") || "none"} runs here`);
  return null;
}

const open = async (proto, url, target) => {
  const opened = await proto.run(["open", url, "--target", target]);
  assert.equal(opened.status, 0, opened.stderr);
};

// The toolbar drawn and idle: every control enabled.
const idle = (read) => read.drawn && !read.collapsed && read.controls.Engine && !read.controls.Engine.disabled;
const drawnIdle = (proto, why) => proto.toolbarUntil(idle, why);

describe("the overlay's init script", () => {
  for (const engine of engines) {
    test(`${engine}: is in before the page's first script, in the top frame alone, and draws nothing in a page that is not the window's`, async (t) => {
      const proto = protoSession(t);
      const site = await fixture(t);
      if (!(await proto.engine(t, engine))) return;
      const mark = site.mark();
      await open(proto, `${site.url}plain`, `${engine}/laptop`);
      const read = await drawnIdle(proto, "the window's toolbar");
      assert.ok(read.aria, "the toolbar has an aria snapshot");
      assert.deepEqual(site.reports(mark, "first"), ["object"], "the page's first script finds window.__protoOverlay");
      assert.deepEqual(site.reports(mark, "frame"), ["undefined", "undefined"], "neither frame, same origin or [::1], has it");

      // The window's own page is answered the state; another page sharing its context is not.
      const hello = await proto.page("send", { message: { type: "hello" } });
      assert.equal(hello.answer.show, true);
      assert.equal(hello.answer.current.engine, engine);
      assert.deepEqual(await proto.page("popup", { url: `${site.url}other` }), { overlay: "object", shown: false, drawn: 0 });
      assert.deepEqual(await proto.toolbar("read"), read, "the window's toolbar is as it was");
    });
  }
});

describe("the toolbar's controls", () => {
  test("have their roles and names; an unavailable engine's option is disabled, says so and holds the reason", async (t) => {
    const site = await fixture(t);
    const probe = protoSession(t);
    const [first] = (await available(t, probe, 1)) ?? [];
    if (!first) return;
    const missing = engines.find((engine) => engine !== first);
    const proto = protoSession(t, { env: { PROTO_BROWSERS_PATH: browsersWithout(missing) } });
    await open(proto, `${site.url}other`, `${first}/laptop`);
    const read = await drawnIdle(proto, "the toolbar");
    assert.deepEqual(Object.keys(read.controls), ["Engine", "Size", "Reload", "Hide toolbar"]);
    assert.deepEqual(Object.values(read.controls).map((control) => control.role), ["combobox", "combobox", "button", "button"]);
    assert.deepEqual([read.collapsed, read.status], [false, null]);
    const aria = JSON.stringify(read.aria);
    assert.match(aria, /"role":"toolbar","name":"Prototype targets"/);
    assert.match(aria, /"role":"status"/);

    const { Engine, Size } = read.controls;
    assert.equal(Engine.value, first);
    assert.deepEqual(Engine.options.map((option) => option.value), ["chromium", "firefox", "webkit", "agent-chrome"]);
    const gone = Engine.options.find((option) => option.value === missing);
    assert.deepEqual([gone.text, gone.disabled], [`${missing} (unavailable)`, true]);
    assert.match(gone.title, new RegExp(`^${missing} \\S+ is not installed \\(no .+\\); run \`proto install\`$`));
    const here = Engine.options.find((option) => option.value === first);
    assert.deepEqual([here.text, here.disabled, here.title], [first, false, null]);

    assert.equal(Size.value, "laptop");
    assert.deepEqual(Size.options.map((option) => [option.value, option.text]), [
      ["phone-small", "phone-small"], ["phone", "phone"], ["tablet", "tablet"], ["laptop", "laptop"], ["desktop", "desktop"], ["custom", "Custom..."],
    ]);
    assert.equal(Size.options.find((option) => option.value === "phone").title, "390x844@3");

    // "Custom..." takes a width, a height and a scale, from the window's own.
    await proto.toolbar("select", { name: "Size", value: "Custom..." });
    const custom = await proto.toolbarUntil((each) => "Width" in each.controls, "the custom size's fields");
    assert.deepEqual(Object.keys(custom.controls), ["Engine", "Size", "Width", "Height", "Scale", "Apply", "Reload", "Hide toolbar"]);
    assert.deepEqual(["Width", "Height", "Scale"].map((name) => [custom.controls[name].role, custom.controls[name].value]), [["spinbutton", "1440"], ["spinbutton", "900"], ["spinbutton", "1"]]);
    assert.equal(custom.controls.Apply.role, "button");
    assert.equal(custom.controls.Size.value, "custom");
    // Choosing it switched nothing.
    assert.match((await proto.run(["status"])).stdout, new RegExp(`window ${first}/laptop on `));
  });
});

describe("a switch from the toolbar", () => {
  test("choosing a size, applying a custom size and choosing each engine switch the window as proto set does", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    const names = await available(t, proto, 1);
    if (!names) return;
    await open(proto, `${site.url}other`, `${names[0]}/laptop`);
    await drawnIdle(proto, "the toolbar");
    const metrics = async () => {
      const seen = await proto.page("metrics");
      return [seen.innerWidth, seen.innerHeight, seen.devicePixelRatio];
    };

    await proto.toolbar("select", { name: "Size", value: "phone" });
    let read = await proto.toolbarUntil((each) => idle(each) && each.controls.Size.value === "phone", "the phone size");
    assert.deepEqual(await metrics(), [390, 844, 3]);
    assert.equal(read.status, null);

    await proto.toolbar("select", { name: "Size", value: "Custom..." });
    await proto.toolbarUntil((each) => "Width" in each.controls, "the custom size's fields");
    await proto.toolbar("fill", { name: "Width", value: "1024" });
    await proto.toolbar("fill", { name: "Height", value: "768" });
    await proto.toolbar("fill", { name: "Scale", value: "2" });
    await proto.toolbar("click", { name: "Apply" });
    read = await proto.toolbarUntil((each) => idle(each) && each.controls.Size.value === "1024x768@2", "the custom size");
    assert.ok(!("Width" in read.controls), "applied, the custom fields close");
    assert.deepEqual(await metrics(), [1024, 768, 2]);
    // The window's own size is listed, as its own option.
    assert.equal(read.controls.Size.options.find((option) => option.value === "1024x768@2").title, "1024x768@2");
    assert.match((await proto.run(["status"])).stdout, new RegExp(`window ${names[0]}/1024x768@2 on ${site.url}other\\n$`));

    for (const engine of [...names.slice(1), names[0]]) {
      if (engine === names[0] && names.length === 1) break;
      await proto.toolbar("select", { name: "Engine", value: engine });
      read = await proto.toolbarUntil((each) => idle(each) && each.controls.Engine.value === engine, `the ${engine} window`);
      const seen = await proto.page("metrics");
      assert.ok(agents[engine](seen.userAgent), `${engine}'s user agent: ${seen.userAgent}`);
      assert.deepEqual([seen.innerWidth, seen.innerHeight, seen.devicePixelRatio, seen.url], [1024, 768, 2, `${site.url}other`], engine);
      assert.equal(read.controls.Size.value, "1024x768@2", `${engine} keeps the size`);
      assert.match((await proto.run(["status"])).stdout, new RegExp(`window ${engine}/1024x768@2 on `));
    }
  });

  test("while it runs every control but Hide toolbar is disabled and the status names it; one that fails shows its error and the old window keeps its toolbar", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    const [engine] = (await available(t, proto, 1)) ?? [];
    if (!engine) return;
    await open(proto, `${site.url}slow`, `${engine}/laptop`);
    await drawnIdle(proto, "the toolbar");

    // A new scale is a fresh context, which loads the slow page again.
    await proto.toolbar("select", { name: "Size", value: "phone" });
    const running = await proto.toolbarUntil((each) => each.drawn && each.status === `Opening ${engine} at phone...`, "the switch running");
    assert.deepEqual(Object.fromEntries(Object.entries(running.controls).map(([name, control]) => [name, control.disabled])), {
      Engine: true, Size: true, Reload: true, "Hide toolbar": false,
    });
    const done = await proto.toolbarUntil((each) => idle(each) && each.controls.Size.value === "phone", "the switch done");
    assert.equal(done.status, null);

    site.failing = true;
    await proto.toolbar("select", { name: "Size", value: "tablet" });
    const failed = await proto.toolbarUntil((each) => idle(each) && each.status !== null && !each.status.startsWith("Opening"), "the failed switch's status");
    assert.ok(failed.status.startsWith(`${engine} could not open ${site.url}slow: `), failed.status);
    assert.equal(failed.controls.Size.value, "phone", "the old window's size");
    const seen = await proto.page("metrics");
    assert.deepEqual([seen.innerWidth, seen.innerHeight, seen.devicePixelRatio, seen.url], [390, 844, 3, `${site.url}slow`]);

    // A switch by the CLI shows in the toolbar alike, and its failure too.
    const cli = await proto.run(["set", "laptop"]);
    assert.equal(cli.status, 1);
    const shown = await proto.toolbarUntil((each) => idle(each) && each.status !== null && !each.status.startsWith("Opening"), "the CLI's failed switch");
    assert.equal(`proto: ${shown.status}\n`, cli.stderr);
    site.failing = false;
  });
});

describe("Reload and Hide toolbar", () => {
  test("Reload reloads the page; the collapsed toolbar stays collapsed across a reload, a size switch and an engine switch", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    const names = await available(t, proto, 1);
    if (!names) return;
    await open(proto, `${site.url}other`, `${names[0]}/laptop`);
    await drawnIdle(proto, "the toolbar");

    let mark = site.mark();
    await proto.toolbar("click", { name: "Reload" });
    for (let waited = 0; site.pages(mark, "/other") === 0 && waited < 10_000; waited += 50) await sleep(50);
    assert.equal(site.pages(mark, "/other"), 1, "the page was requested again");
    await drawnIdle(proto, "the toolbar after the reload");

    await proto.toolbar("click", { name: "Hide toolbar" });
    let read = await proto.toolbarUntil((each) => each.drawn && each.collapsed, "the toolbar collapsed");
    assert.deepEqual(Object.keys(read.controls), ["proto"]);
    assert.equal(read.controls.proto.role, "button");

    const collapsedAfter = async (why) => {
      read = await proto.toolbarUntil((each) => each.drawn, why);
      assert.equal(read.collapsed, true, why);
    };
    mark = site.mark();
    const reloaded = await proto.request("POST", "/v1/reload", {});
    assert.deepEqual(reloaded, { status: 200, body: { target: `${names[0]}/laptop`, url: `${site.url}other` } });
    assert.equal(site.pages(mark, "/other"), 1);
    await collapsedAfter("after a reload");
    assert.equal((await proto.run(["set", "phone"])).status, 0);
    await collapsedAfter("after a size switch");
    if (names.length > 1) {
      assert.equal((await proto.run(["set", names[1]])).status, 0);
      await collapsedAfter(`after a switch to ${names[1]}`);
    }

    await proto.toolbar("click", { name: "proto" });
    read = await drawnIdle(proto, "the toolbar shown again");
    assert.equal(read.collapsed, false);
    assert.equal(read.controls.Size.value, "phone");
  });
});

describe("the status line", () => {
  for (const engine of engines) {
    test(`${engine}: a navigation off localhost shows "Blocked <url>: off localhost", which the next page clears`, async (t) => {
      const proto = protoSession(t);
      const site = await fixture(t);
      if (!(await proto.engine(t, engine))) return;
      await open(proto, `${site.url}other`, `${engine}/laptop`);
      await drawnIdle(proto, "the toolbar");
      await proto.page("navigate", { url: "http://example.invalid/" });
      const blocked = await proto.toolbarUntil((each) => each.drawn && each.status !== null, "the blocked status");
      assert.equal(blocked.status, "Blocked http://example.invalid/: off localhost");
      await proto.page("navigate", { url: `${site.url}plain` });
      const cleared = await drawnIdle(proto, "the next page's toolbar");
      assert.equal(cleared.status, null);
    });
  }
});

describe("the binding", () => {
  test("answers a message of an unknown type, or a malformed one, with an error and changes nothing; overlay.js's header names its sections and types", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    const [engine] = (await available(t, proto, 1)) ?? [];
    if (!engine) return;
    await open(proto, `${site.url}other`, `${engine}/laptop`);
    const before = await drawnIdle(proto, "the toolbar");
    const types = "the types are hello, set_target, reload, collapse";
    for (const [message, error] of [
      [{ type: "bogus" }, `unknown message type "bogus"; ${types}`],
      [{ type: "toString" }, `unknown message type "toString"; ${types}`],
      [{}, "a message is an object with a type"],
      ["hello", "a message is an object with a type"],
      [{ type: "collapse", collapsed: "yes" }, "collapse takes collapsed, true or false"],
      [{ type: "collapse", collapsed: true, extra: 1 }, `unknown field "extra" in collapse; it takes collapsed`],
      [{ type: "set_target", target: "netscape/phone" }, `unknown engine "netscape" in "netscape/phone"; the engines are chromium, firefox, webkit, agent-chrome`],
    ]) {
      assert.deepEqual(await proto.page("send", { message }), { answer: { error } }, JSON.stringify(message));
    }
    assert.deepEqual(await proto.toolbar("read"), before);
    assert.match((await proto.run(["status"])).stdout, new RegExp(`window ${engine}/laptop on ${site.url}other\\n$`));

    const source = readFileSync(join(repoRoot, "toolkits", "frontend", "proto", "overlay.js"), "utf8");
    const header = source.slice(0, source.search(/^[^/]/m));
    for (const name of ["target", "reload", "collapse", "status"]) assert.match(header, new RegExp(`^//   ${name} `, "m"), `the section ${name}`);
    for (const type of ["hello", "set_target", "reload", "collapse"]) assert.match(header, new RegExp(`^//   ${type}\\b`, "m"), `the type ${type}`);
  });
});

describe("the toolbar's styles", () => {
  for (const engine of engines) {
    test(`${engine}: a page's CSS on button, select, * and :root leaves the toolbar's computed styles alone, and the toolbar leaves the page's`, async (t) => {
      const proto = protoSession(t);
      const site = await fixture(t);
      if (!(await proto.engine(t, engine))) return;
      await open(proto, `${site.url}plain`, `${engine}/laptop`);
      const plain = await site.styles("plain");
      await open(proto, `${site.url}styled`, `${engine}/laptop`);
      const styled = await site.styles("styled");
      assert.deepEqual(styled.toolbar, plain.toolbar, "the toolbar's styles on the styled page");
      assert.deepEqual(plain.after, plain.before, "the plain page's own styles");
      assert.deepEqual(styled.after, styled.before, "the styled page's own styles");
      // The styled page's CSS did reach its own elements.
      assert.equal(styled.before["#page-button"]["font-size"], "30px");
      assert.equal(plain.toolbar.host.position, "fixed");
      assert.equal(styled.toolbar.host.display, "block");
    });
  }
});
