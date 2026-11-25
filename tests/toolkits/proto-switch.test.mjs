// Switching the prototyping window (toolkits/frontend/scripts/proto set, POST /v1/target), driven
// through the CLI and the host's API as Daniel and the session do, headless, in a runtime
// directory of each test's own (helpers/proto.mjs), against a fixture site that records every
// request it is sent: on 127.0.0.1 (the window's pages), on [::1] (an origin off localhost, by
// the guard's rule, whose frame sets a cookie and a localStorage item), and on localhost (a
// sub-resource server). It checks an engine switch at each pair of the engines the machine has
// (the page's own URL, the user agent, the localhost login carried and the other origin's not,
// the old browser closed), a resize in place against a fresh context in the same browser, a
// switch that fails leaving the old window as it was, two switches at once, a main-frame
// navigation off localhost blocked while sub-resources load, and a window whose browser is
// closed. Every engine the machine has runs; under CI=true a missing one fails, elsewhere it
// skips with its reason.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { join } from "node:path";
import { describe, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { repoRoot } from "./helpers/mcp.mjs";
import { children } from "./helpers/process.mjs";
import { browsersWithout, protoSession } from "./helpers/proto.mjs";

const engines = ["chromium", "firefox", "webkit"];
const iPhone = JSON.parse(execFileSync(process.execPath, ["-e", `process.stdout.write(JSON.stringify(require(${JSON.stringify(join(repoRoot, "servers", "node_modules", "playwright-core"))}).devices["iPhone 15"]))`], { encoding: "utf8" }));

// Each engine's user agent, as its page reports it.
const agents = {
  chromium: (agent) => /Chrome\//.test(agent) && !/Firefox\//.test(agent),
  firefox: (agent) => /Firefox\//.test(agent),
  webkit: (agent) => /Version\/[\d.]+ Safari\//.test(agent) && !/Chrome\//.test(agent),
};

const listen = (server, port, host) => new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(port, host, () => resolve(server.address().port));
});

// The fixture site: its pages on 127.0.0.1, a frame and a script on [::1], and a script on
// localhost (served on 127.0.0.1 and [::1] at one port, so either address the name takes
// answers). Each request is recorded as { origin, path, query, cookie }; /events is an open
// event stream, counted while it stays open.
async function fixture(t) {
  const requests = [];
  let streams = 0;
  let site;
  const handler = (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host}`);
    requests.push({ origin: url.origin, path: url.pathname, query: Object.fromEntries(url.searchParams), cookie: request.headers.cookie ?? "" });
    const html = (body, headers = {}) => {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8", ...headers });
      response.end(`<!doctype html><meta name="viewport" content="width=device-width">${body}`);
    };
    const frame = `<iframe src="${site.other}frame"></iframe>`;
    const report = (key) => `<script>document.write('<img src="/report?item=' + encodeURIComponent(String(localStorage.getItem(${JSON.stringify(key)}))) + '">')</script>`;
    switch (url.pathname) {
      case "/login":
        return html(`<title>login</title><script>document.cookie = "login=yes; path=/"; localStorage.setItem("login", "yes")</script>${frame}<p>logged in</p>`);
      case "/home":
        return html(`<title>home</title>${report("login")}${frame}<script src="${site.named}named.js"></script><script src="${site.other}other.js"></script><script>new EventSource("/events")</script><p>home</p>`);
      case "/other":
        return html("<title>other</title><p>other</p>");
      case "/frame":
        return html(`${report("framels")}<script>localStorage.setItem("framels", "1"); document.cookie = "framejs=1; SameSite=None; Secure"</script>frame`, { "set-cookie": "framecookie=1; Path=/; SameSite=None; Secure" });
      case "/named.js":
      case "/other.js":
        response.writeHead(200, { "content-type": "text/javascript" });
        return response.end("void 0;\n");
      case "/report":
        response.writeHead(204);
        return response.end();
      case "/events":
        streams++;
        response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
        response.write(": open\n\n");
        response.on("close", () => streams--);
        return undefined;
      default:
        response.writeHead(404);
        return response.end("not found");
    }
  };
  const servers = [createServer(handler), createServer(handler), createServer(handler), createServer(handler)];
  const main = await listen(servers[0], 0, "127.0.0.1");
  const other = await listen(servers[1], 0, "::1");
  const named = await listen(servers[2], 0, "127.0.0.1");
  await listen(servers[3], named, "::1");
  site = { url: `http://127.0.0.1:${main}/`, other: `http://[::1]:${other}/`, named: `http://localhost:${named}/` };
  t.after(() => Promise.all(servers.map((server) => new Promise((resolve) => {
    server.closeAllConnections();
    server.close(resolve);
  }))));
  return {
    ...site,
    requests,
    streams: () => streams,
    mark: () => requests.length,
    since: (mark, origin, path) => requests.slice(mark).filter((each) => each.origin === new URL(origin).origin && each.path === path),
  };
}

// The open event streams settle after a page closes; wait until there are `count`.
async function streamsSettle(site, count) {
  for (let waited = 0; site.streams() !== count && waited < 10_000; waited += 100) await sleep(100);
  assert.equal(site.streams(), count, "open event streams");
}

const set = (proto, target, url) => proto.request("POST", "/v1/target", { target, ...(url ? { url } : {}) });

describe("proto set's refusals", () => {
  test("with no window open, proto set and POST /v1/target are refused naming proto open; a malformed set exits 2", async (t) => {
    const proto = protoSession(t);
    const refused = "proto: no window is open; run `proto open`\n";
    assert.deepEqual(await proto.run(["set", "webkit"]), { status: 1, stdout: "", stderr: refused });
    assert.equal(await proto.hostPid(), null, "set starts no host");
    assert.equal((await proto.run(["targets"])).status, 0);
    assert.deepEqual(await proto.run(["set", "webkit/phone"]), { status: 1, stdout: "", stderr: refused });
    assert.deepEqual(await set(proto, "phone"), { status: 400, body: { error: "no window is open; run `proto open`" } });
    for (const args of [["set"], ["set", "webkit", "phone"], ["set", "--bogus"]]) {
      const result = await proto.run(args);
      assert.equal(result.status, 2, `${args.join(" ")}: ${result.stderr}`);
      assert.match(result.stderr, /^proto: usage: proto open/);
    }
  });
});

describe("an engine switch", () => {
  test("goes round every engine the machine has, each reopening the page's own URL with the localhost login and closing the old browser", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    const names = await proto.available(t, 2);
    if (!names) return;
    const opened = await proto.run(["open", `${site.url}login`, "--target", `${names[0]}/laptop`]);
    assert.equal(opened.status, 0, opened.stderr);
    // A page the window reached by its own navigation, not the one opened.
    const followed = await proto.page("navigate", { url: `${site.url}home` });
    assert.equal(followed.url, `${site.url}home`);
    const host = await proto.hostPid();
    let [browser] = children(host);
    for (const engine of [...names.slice(1), names[0]]) {
      const mark = site.mark();
      // An engine alone keeps the size, and the last step names both.
      const moved = await proto.run(["set", engine === names[0] ? `${engine}/laptop` : engine]);
      assert.equal(moved.status, 0, moved.stderr);
      assert.match(moved.stdout, new RegExp(`^proto: ${engine} \\S+ at laptop \\(1440x900@1\\) on ${site.url}home\\n$`));
      const seen = await proto.page("metrics");
      assert.equal(seen.url, `${site.url}home`, engine);
      assert.ok(agents[engine](seen.userAgent), `${engine}'s user agent: ${seen.userAgent}`);
      assert.deepEqual([seen.innerWidth, seen.innerHeight], [1440, 900]);
      // The login carried: the page's request sends the cookie, its script reads the item.
      const [home] = site.since(mark, site.url, "/home");
      assert.match(home.cookie, /(^|; )login=yes($|;)/, `${engine}: the cookie sent`);
      assert.deepEqual(site.since(mark, site.url, "/report").map((each) => each.query.item), ["yes"], `${engine}: the item read`);
      // The [::1] frame's cookie and item, off localhost, stayed behind.
      const frames = site.since(mark, site.other, "/frame");
      assert.equal(frames.length, 1);
      assert.equal(frames[0].cookie, "", `${engine}: no cookie of [::1] carried`);
      assert.deepEqual(site.since(mark, site.other, "/report").map((each) => each.query.item), ["null"], `${engine}: no item of [::1] carried`);
      // One browser, a new one, and the old page's stream closed with its browser.
      const now = children(host);
      assert.equal(now.length, 1, `one browser after ${engine}`);
      assert.notEqual(now[0], browser, `the browser before ${engine} was closed`);
      browser = now[0];
      await streamsSettle(site, 1);
      assert.equal((await proto.run(["status"])).stdout, `proto: host ${host}; window ${engine}/laptop on ${site.url}home\n`);
    }
  });
});

describe("a size switch", () => {
  for (const engine of engines) {
    test(`${engine}: width and height alone resize in place; a new scale, mobile, touch or user agent opens a fresh context in the same browser`, async (t) => {
      const proto = protoSession(t);
      const site = await fixture(t);
      if (!(await proto.engine(t, engine))) return;
      assert.equal((await proto.run(["open", `${site.url}login`, "--target", `${engine}/laptop`])).status, 0);
      await proto.page("navigate", { url: `${site.url}home` });
      // A value the test sets on the page's window: its location's fragment, by a link.
      assert.equal((await proto.page("navigate", { url: `${site.url}home#kept` })).url, `${site.url}home#kept`);
      const host = await proto.hostPid();
      const [browser] = children(host);
      await streamsSettle(site, 1);

      let mark = site.mark();
      const resized = await proto.run(["set", "1024x768"]);
      assert.deepEqual([resized.status, resized.stderr], [0, ""]);
      assert.match(resized.stdout, new RegExp(`^proto: ${engine} \\S+ at 1024x768 \\(1024x768@1\\) on ${site.url}home#kept\\n$`));
      let seen = await proto.page("metrics");
      assert.deepEqual([seen.innerWidth, seen.innerHeight, seen.devicePixelRatio, seen.url], [1024, 768, 1, `${site.url}home#kept`]);
      assert.deepEqual(site.requests.slice(mark), [], "in place: the page was not loaded again");
      assert.equal(site.streams(), 1, "in place: its stream is the same one");
      assert.deepEqual(children(host), [browser]);

      for (const [target, want] of [["phone", { width: 390, height: 844, scale: 3 }], ["iPhone 15", { width: iPhone.viewport.width, height: iPhone.viewport.height, scale: iPhone.deviceScaleFactor, userAgent: iPhone.userAgent }]]) {
        mark = site.mark();
        const switched = await proto.run(["set", target]);
        assert.deepEqual([switched.status, switched.stderr], [0, ""], target);
        seen = await proto.page("metrics");
        assert.deepEqual([seen.innerWidth, seen.innerHeight, seen.devicePixelRatio, seen.url], [want.width, want.height, want.scale, `${site.url}home#kept`], target);
        if (want.userAgent) assert.equal(seen.userAgent, want.userAgent);
        else assert.ok(agents[engine](seen.userAgent), seen.userAgent);
        const [home] = site.since(mark, site.url, "/home");
        assert.match(home.cookie, /(^|; )login=yes($|;)/, `${target}: the cookie carried into the fresh context`);
        assert.deepEqual(site.since(mark, site.url, "/report").map((each) => each.query.item), ["yes"], `${target}: the item carried`);
        assert.equal(site.since(mark, site.other, "/frame")[0].cookie, "", `${target}: no cookie of [::1]`);
        assert.deepEqual(children(host), [browser], `${target}: the same browser`);
        await streamsSettle(site, 1);
      }
      assert.match((await proto.run(["status"])).stdout, new RegExp(`window ${engine}/iPhone 15 on `));
    });
  }
});

describe("a switch that fails", () => {
  test("to an unavailable engine answers 503 with its reason, and one whose page fails to load answers its error; the old window stays as it was", async (t) => {
    const site = await fixture(t);
    const probe = protoSession(t);
    const [first] = (await probe.available(t, 1)) ?? [];
    if (!first) return;
    const missing = engines.find((engine) => engine !== first);
    const proto = protoSession(t, { env: { PROTO_BROWSERS_PATH: browsersWithout(missing) } });
    assert.equal((await proto.run(["open", `${site.url}home`, "--target", `${first}/tablet`])).status, 0);
    const host = await proto.hostPid();
    const [browser] = children(host);
    const before = await proto.page("metrics");
    const unchanged = async (why) => {
      const seen = await proto.page("metrics");
      assert.deepEqual([seen.url, seen.innerWidth, seen.innerHeight, seen.devicePixelRatio, seen.userAgent], [before.url, before.innerWidth, before.innerHeight, before.devicePixelRatio, before.userAgent], why);
      assert.deepEqual(children(host), [browser], why);
      assert.equal((await proto.run(["status"])).stdout, `proto: host ${host}; window ${first}/tablet on ${site.url}home\n`, why);
    };

    const unavailable = await set(proto, `${missing}/phone`);
    assert.equal(unavailable.status, 503);
    assert.match(unavailable.body.error, new RegExp(`^${missing} \\S+ is not installed \\(no .+\\); run \`proto install\`$`));
    const cli = await proto.run(["set", missing]);
    assert.deepEqual([cli.status, cli.stdout, cli.stderr], [1, "", `proto: ${unavailable.body.error}\n`]);
    await unchanged("after the unavailable engine");

    const dead = createServer();
    const port = await listen(dead, 0, "127.0.0.1");
    await new Promise((resolve) => dead.close(resolve));
    const deadUrl = `http://127.0.0.1:${port}/`;
    for (const target of [`${first}/laptop`, `${first}/phone`]) {
      const failed = await set(proto, target, deadUrl);
      assert.equal(failed.status, 503, target);
      assert.ok(failed.body.error.startsWith(`${first} could not open ${deadUrl}: `), failed.body.error);
      await unchanged(`after ${target} failed to load`);
    }
    const offLocal = await set(proto, "phone", "http://example.com/");
    assert.deepEqual(offLocal, { status: 400, body: { error: "http://example.com/ is off localhost; proto opens only http or https on localhost or 127.0.0.1" } });
    await unchanged("after a URL off localhost");
  });

  test("two switches at once: one is answered 409", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    if (!(await proto.engine(t, "chromium"))) return;
    assert.equal((await proto.run(["open", `${site.url}home`])).status, 0);
    const both = await Promise.all([set(proto, "phone"), set(proto, "tablet")]);
    assert.deepEqual(both.map((each) => each.status).sort(), [200, 409]);
    assert.deepEqual(both.find((each) => each.status === 409).body, { error: "a switch is already running" });
    const done = both.find((each) => each.status === 200).body;
    assert.match((await proto.run(["status"])).stdout, new RegExp(`window ${done.target.replace("/", "\\/")} on `));
  });
});

describe("the localhost guard in a launched window", () => {
  for (const engine of engines) {
    test(`${engine}: a link off localhost is blocked and the page stays; sub-resources off localhost still load`, async (t) => {
      const proto = protoSession(t);
      const site = await fixture(t);
      if (!(await proto.engine(t, engine))) return;
      const mark = site.mark();
      assert.equal((await proto.run(["open", `${site.url}home`, "--target", `${engine}/laptop`])).status, 0);
      // The route refuses only main-frame navigations: the [::1] frame and script, and the
      // localhost script, all loaded.
      assert.equal(site.since(mark, site.other, "/frame").length, 1, "the [::1] frame");
      assert.equal(site.since(mark, site.other, "/other.js").length, 1, "the [::1] script");
      assert.equal(site.since(mark, site.named, "/named.js").length, 1, "the localhost script");
      for (const url of ["http://example.invalid/", `${site.other}other.js`]) {
        const blocked = await proto.page("navigate", { url });
        assert.equal(blocked.url, `${site.url}home`, url);
        assert.equal(blocked.status, `Blocked ${url}: off localhost`);
      }
      assert.equal((await proto.page("metrics")).url, `${site.url}home`);
      assert.equal(site.since(mark, site.other, "/other.js").length, 1, "the blocked navigation sent no request");
      const local = await proto.page("navigate", { url: `${site.url}other` });
      assert.deepEqual([local.url, local.status], [`${site.url}other`, null]);
    });
  }
});

describe("a window whose browser is closed", () => {
  test("is dropped while the host keeps running, and proto open opens a new one", async (t) => {
    const proto = protoSession(t);
    const site = await fixture(t);
    if (!(await proto.engine(t, "chromium"))) return;
    assert.equal((await proto.run(["open", `${site.url}home`])).status, 0);
    const host = await proto.hostPid();
    const [browser] = children(host);
    assert.deepEqual(await proto.page("close-browser"), { closed: true });
    assert.throws(() => process.kill(Number(browser), 0), { code: "ESRCH" });
    assert.equal(await proto.hostPid(), host);
    assert.equal((await proto.run(["status"])).stdout, `proto: host ${host}; no window\n`);
    assert.deepEqual(await proto.run(["set", "phone"]), { status: 1, stdout: "", stderr: "proto: no window is open; run `proto open`\n" });
    const reopened = await proto.run(["open", `${site.url}other`]);
    assert.equal(reopened.status, 0, reopened.stderr);
    assert.equal((await proto.run(["status"])).stdout, `proto: host ${host}; window chromium/laptop on ${site.url}other\n`);
    assert.equal(children(host).length, 1);
  });
});
