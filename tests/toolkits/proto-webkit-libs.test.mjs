// WebKit's libraries on Linux (toolkits/frontend/proto/webkit-libs.mjs and webkit-libs.json), driven
// through the proto CLI as Daniel runs it: the pins and their layout; the offline pin test against
// servers/package.json and playwright-core's browsers.json, and the runner's against the packages
// that ldd and dpkg -S find on a Debian-family machine (CI's Ubuntu 24.04 runner); the check's
// files and library path; WebKit's availability through `proto targets` and `proto open`; and
// `proto install`'s placing and `--refresh-pins`, from fixture .debs built here (an ar archive
// whose data.tar.zst is zlib's zstd) and fixture Packages.gz indexes served on 127.0.0.1 through
// PROTO_WEBKIT_LIBS_SOURCES, with a stub ldd (PROTO_LDD) that names a soname missing until it is in
// the fake revision directory's sys/lib, and a copy of the pins (PROTO_WEBKIT_LIBS_FILE). No test
// fetches from Ubuntu or Launchpad, and none writes Playwright's own cache.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { hostname } from "node:os";
import { basename, join } from "node:path";
import { describe, test } from "node:test";
import { gzipSync, zstdCompressSync } from "node:zlib";
import { repoRoot, tempDir } from "./helpers/mcp.mjs";
import { protoSession } from "./helpers/proto.mjs";

const proto = join(repoRoot, "toolkits", "frontend", "proto");
const { checkWebkitLibs, formatPins, readPins, webkitDirectories } = await import(join(proto, "webkit-libs.mjs"));
const pinFile = join(proto, "webkit-libs.json");
const browsersJson = JSON.parse(readFileSync(join(repoRoot, "servers", "node_modules", "playwright-core", "browsers.json"), "utf8"));
const webkitPinned = browsersJson.browsers.find((browser) => browser.name === "webkit");
const linuxOnly = process.platform === "linux" ? {} : { skip: "WebKit's library step runs on Linux only" };
const four = ["libicudata.so.74", "libicui18n.so.74", "libicuuc.so.74", "libxml2.so.2"];
const lacks = (sonames) => `WebKit ${webkitPinned.browserVersion} lacks ${sonames.join(", ")} on this machine; run \`proto install\``;

// --- Fixture packages -----------------------------------------------------------------------

function tarHeader(path, { size = 0, type = "0", target = "", mode = 0o644 }) {
  const block = Buffer.alloc(512);
  const put = (text, offset, length) => block.write(text, offset, length, "utf8");
  const octal = (value, length) => value.toString(8).padStart(length - 1, "0");
  assert.ok(Buffer.byteLength(path) <= 100, path);
  put(path, 0, 100);
  put(octal(mode, 8), 100, 7);
  put(octal(0, 8), 108, 7);
  put(octal(0, 8), 116, 7);
  put(octal(size, 12), 124, 11);
  put(octal(0, 12), 136, 11);
  put("        ", 148, 8);
  put(type, 156, 1);
  put(target, 157, 100);
  put("ustar\0", 257, 6);
  put("00", 263, 2);
  const sum = block.reduce((total, byte) => total + byte, 0);
  put(`${sum.toString(8).padStart(6, "0")}\0 `, 148, 8);
  return block;
}

// A tar of entries [path, { data, type, target, mode }], directories as type "5".
function tar(entries) {
  const blocks = [];
  for (const [path, entry] of entries) {
    const data = entry.data ?? Buffer.alloc(0);
    blocks.push(tarHeader(path, { ...entry, size: data.length }), data, Buffer.alloc((512 - (data.length % 512)) % 512));
  }
  blocks.push(Buffer.alloc(1024));
  return Buffer.concat(blocks);
}

function ar(members) {
  const parts = [Buffer.from("!<arch>\n")];
  for (const [name, data] of members) {
    const header = `${`${name}/`.padEnd(16)}${"0".padEnd(12)}${"0".padEnd(6)}${"0".padEnd(6)}${"100644".padEnd(8)}${String(data.length).padEnd(10)}\`\n`;
    parts.push(Buffer.from(header, "latin1"), data, data.length % 2 ? Buffer.from("\n") : Buffer.alloc(0));
  }
  return Buffer.concat(parts);
}

const libDir = "./usr/lib/x86_64-linux-gnu/";
// A .deb holding each soname's real file (bytes of its own) and link, plus `extra` entries.
function deb(name, links, { extra = [], linkTargets = {} } = {}) {
  const entries = [["./", { type: "5", mode: 0o755 }], ["./usr/", { type: "5", mode: 0o755 }], ["./usr/lib/", { type: "5", mode: 0o755 }], [libDir, { type: "5", mode: 0o755 }]];
  const files = {};
  for (const [soname, real] of Object.entries(links)) {
    files[real] = Buffer.from(`${name}'s ${real}: ${"x".repeat(700)}`);
    entries.push([`${libDir}${real}`, { data: files[real] }], [`${libDir}${soname}`, { type: "2", target: linkTargets[soname] ?? real }]);
  }
  entries.push([`./usr/share/doc/${name}/copyright`, { data: Buffer.from("copyright\n") }], ...extra);
  const control = tar([["./control", { data: Buffer.from(`Package: ${name}\n`) }]]);
  const bytes = ar([["debian-binary", Buffer.from("2.0\n")], ["control.tar.zst", zstdCompressSync(control)], ["data.tar.zst", zstdCompressSync(tar(entries))]]);
  return { bytes, files, sha256: createHash("sha256").update(bytes).digest("hex") };
}

const icuLinks = { "libicudata.so.74": "libicudata.so.74.2", "libicui18n.so.74": "libicui18n.so.74.2", "libicuuc.so.74": "libicuuc.so.74.2" };
const xmlLinks = { "libxml2.so.2": "libxml2.so.2.9.14" };

// The pinned packages' fixtures, libicu74 holding libicuio too, which no pin names.
function fixturePackages() {
  return {
    libicu74: deb("libicu74", { ...icuLinks, "libicuio.so.74": "libicuio.so.74.2" }),
    libxml2: deb("libxml2", xmlLinks),
  };
}

// A copy of the real pins with the fixtures' SHA-256s, and `change` applied.
function fixturePins(packages, change = (pins) => pins) {
  const pins = JSON.parse(readFileSync(pinFile, "utf8"));
  for (const pin of pins.packages) pin.sha256 = packages[pin.name].sha256;
  const file = join(tempDir("pins"), "webkit-libs.json");
  writeFileSync(file, `${JSON.stringify(change(pins), null, 2)}\n`);
  return file;
}

// --- Fixture sources ------------------------------------------------------------------------

// A server on 127.0.0.1 answering each path of `routes` (bytes, or { status, location, body }),
// 404 to the rest; `requests` lists the paths it was asked for.
async function serve(t, routes = {}) {
  const requests = [];
  const server = createServer((request, response) => {
    requests.push(request.url);
    const route = routes[request.url];
    if (route === undefined) return response.writeHead(404).end("not found");
    if (Buffer.isBuffer(route)) return response.writeHead(200, { "content-type": "application/octet-stream" }).end(route);
    response.writeHead(route.status ?? 200, route.location ? { location: route.location } : {}).end(route.body ?? "");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return { routes, requests, base: `http://127.0.0.1:${server.address().port}/` };
}

const poolOf = (pins, name) => JSON.parse(readFileSync(pins, "utf8")).packages.find((pin) => pin.name === name).pool;

// The archive (pool paths below ubuntu/) and Launchpad (file names below lp/), each serving the
// fixture packages of the pin file unless a test changes a route.
async function sources(t, packages, pins) {
  const archive = await serve(t);
  const launchpad = await serve(t);
  for (const [name, fixture] of Object.entries(packages)) {
    const pool = poolOf(pins, name);
    archive.routes[`/ubuntu/${pool}`] = fixture.bytes;
    launchpad.routes[`/lp/${basename(pool)}`] = fixture.bytes;
  }
  return { archive, launchpad, env: { PROTO_WEBKIT_LIBS_SOURCES: `${archive.base}ubuntu/ ${launchpad.base}lp/` } };
}

// --- A fake WebKit and ldd ------------------------------------------------------------------

// Playwright's browsers path holding a WebKit revision directory shaped as the real one: each
// bundle's wrapper script, executables, libraries, and a file the check skips.
function fakeBrowsers() {
  const root = tempDir("browsers");
  const revision = join(root, `webkit-${webkitPinned.revision}`);
  for (const bundle of ["minibrowser-gtk", "minibrowser-wpe"]) {
    for (const dir of ["bin", "lib", "sys/lib"]) mkdirSync(join(revision, bundle, dir), { recursive: true });
    writeFileSync(join(revision, bundle, "MiniBrowser"), "#!/bin/sh\nexec bin/MiniBrowser\n", { mode: 0o755 });
    writeFileSync(join(revision, bundle, "README.txt"), "not checked\n");
    writeFileSync(join(revision, bundle, "bin", "MiniBrowser"), "\x7fELF", { mode: 0o755 });
    writeFileSync(join(revision, bundle, "bin", "WebKitWebProcess"), "\x7fELF", { mode: 0o755 });
    writeFileSync(join(revision, bundle, "lib", "libMiniBrowserInjectedBundle.so"), "\x7fELF");
    writeFileSync(join(revision, bundle, "sys", "lib", "libwebkit.so.0"), "\x7fELF");
  }
  writeFileSync(join(revision, "pw_run.sh"), "#!/bin/sh\n", { mode: 0o755 });
  return { root, revision, libs: ["minibrowser-gtk", "minibrowser-wpe"].map((bundle) => join(revision, bundle, "sys", "lib")) };
}

// ldd's stand-in: each soname of STUB_LDD_NEEDS found where LD_LIBRARY_PATH holds it, else "not
// found"; a script is no dynamic executable; each call logged to STUB_LDD_LOG when set.
function stubLdd() {
  const file = join(tempDir("ldd"), "ldd");
  writeFileSync(file, `#!/bin/sh
if [ -n "$STUB_LDD_LOG" ]; then printf '%s\\t%s\\n' "$1" "$LD_LIBRARY_PATH" >> "$STUB_LDD_LOG"; fi
if [ "$(head -c 2 "$1")" = "#!" ]; then echo "	not a dynamic executable"; exit 1; fi
for need in $STUB_LDD_NEEDS; do
  where="not found"
  old_ifs=$IFS; IFS=:
  for dir in $LD_LIBRARY_PATH; do
    if [ -e "$dir/$need" ]; then where="$dir/$need (0x00007f0000000000)"; break; fi
  done
  IFS=$old_ifs
  printf '\\t%s => %s\\n' "$need" "$where"
done
`, { mode: 0o755 });
  return file;
}

// What a sys/lib holds: each name's link target, or its bytes' SHA-256.
function holdings(dir) {
  const held = {};
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name);
    held[name] = lstatSync(path).isSymbolicLink() ? `-> ${readlinkSync(path)}` : createHash("sha256").update(readFileSync(path)).digest("hex");
  }
  return held;
}

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");

// A session of the CLI with a fake WebKit, the stub ldd naming `needs`, a fixture pin file and
// fixture sources, and an installer that does nothing.
async function installSession(t, { needs = four, change, packages = fixturePackages() } = {}) {
  const browsers = fakeBrowsers();
  const installer = join(tempDir("installer"), "installer.mjs");
  writeFileSync(installer, "process.exit(0);\n");
  const pins = fixturePins(packages, change);
  const served = await sources(t, packages, pins);
  const env = {
    PROTO_BROWSERS_PATH: browsers.root,
    PROTO_INSTALLER: installer,
    PROTO_LDD: stubLdd(),
    PROTO_WEBKIT_LIBS_FILE: pins,
    STUB_LDD_NEEDS: needs.join(" "),
    ...served.env,
  };
  const session = protoSession(t, { env });
  const check = () => checkWebkitLibs(browsers.revision, { env: { ...process.env, ...env } });
  return { session, browsers, pins, packages, served, env, check };
}

const before = (browsers) => browsers.libs.map(holdings);

// What each sys/lib holds once the four are placed from `packages`.
function placed(browsers, packages) {
  const want = {};
  for (const [name, links] of [["libicu74", icuLinks], ["libxml2", xmlLinks]]) {
    for (const [soname, real] of Object.entries(links)) {
      want[soname] = `-> ${real}`;
      want[real] = digest(packages[name].files[real]);
    }
  }
  return { ...holdings(browsers.libs[0]), ...want };
}

const placedLines = [
  "proto: the pinned browsers are installed",
  `proto: placed libicudata.so.74, libicui18n.so.74, libicuuc.so.74 from libicu74 74.2-1ubuntu3.1 into WebKit ${webkitPinned.browserVersion}`,
  `proto: placed libxml2.so.2 from libxml2 2.9.14+dfsg-1.3ubuntu3.10 into WebKit ${webkitPinned.browserVersion}`,
  "",
].join("\n");

// --- The pins -------------------------------------------------------------------------------

describe("the pins", () => {
  test("webkit-libs.json holds the spec's pins, in the layout formatPins writes", () => {
    const text = readFileSync(pinFile, "utf8");
    assert.deepEqual(JSON.parse(text), {
      checkedFor: { playwrightCore: "1.65.1", webkitRevision: "2388", webkitVersion: "27.2" },
      series: "noble",
      checked: "2026-11-24, EndeavourOS",
      packages: [
        {
          name: "libicu74",
          version: "74.2-1ubuntu3.1",
          pool: "pool/main/i/icu/libicu74_74.2-1ubuntu3.1_amd64.deb",
          sha256: "c9a70989678660eed9a1e904c74fa043da8bec8e2036856fc16e31ced79b04f8",
          links: icuLinks,
        },
        {
          name: "libxml2",
          version: "2.9.14+dfsg-1.3ubuntu3.10",
          pool: "pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3.10_amd64.deb",
          sha256: "c5a065f85c1e6f605741e365e40cad71c3ceb0e85e2791400bd35b8896e12ad1",
          links: xmlLinks,
        },
      ],
    });
    assert.equal(formatPins(readPins(pinFile)), text);
  });

  test("offline: they were checked for the pinned playwright-core and its WebKit revision", () => {
    const { checkedFor } = readPins(pinFile);
    const servers = JSON.parse(readFileSync(join(repoRoot, "servers", "package.json"), "utf8"));
    assert.equal(checkedFor.playwrightCore, servers.dependencies["playwright-core"], "playwright-core moved: run `proto install --refresh-pins` (toolkits/frontend/README.md, \"WebKit on Linux\")");
    assert.equal(checkedFor.webkitRevision, webkitPinned.revision, "WebKit's revision moved: run `proto install --refresh-pins` (toolkits/frontend/README.md, \"WebKit on Linux\")");
    assert.equal(checkedFor.webkitVersion, webkitPinned.browserVersion);
  });

  test("on the runner: the sonames WebKit resolves to the pinned packages are exactly the pins' links", (t) => {
    const missing = (reason) => {
      if (process.env.CI === "true") assert.fail(`in CI the runner's pin test runs, but ${reason}`);
      t.skip(reason);
    };
    if (spawnSync("dpkg", ["--version"]).error) return missing("this machine has no dpkg");
    const revision = join(process.env.PLAYWRIGHT_BROWSERS_PATH || join(process.env.HOME, ".cache", "ms-playwright"), `webkit-${webkitPinned.revision}`);
    if (!existsSync(revision)) return missing(`WebKit ${webkitPinned.browserVersion} is not installed (no ${revision})`);
    const resolved = new Map();
    for (const bundle of ["minibrowser-gtk", "minibrowser-wpe"]) {
      const libraryPath = `${join(revision, bundle, "lib")}:${join(revision, bundle, "sys", "lib")}`;
      for (const directory of webkitDirectories.filter((each) => each.startsWith(`${bundle}`))) {
        const dir = join(revision, directory);
        if (!existsSync(dir)) continue;
        for (const name of readdirSync(dir)) {
          const run = spawnSync("ldd", [join(dir, name)], { env: { ...process.env, LD_LIBRARY_PATH: libraryPath }, encoding: "utf8" });
          if (run.status !== 0) continue;
          for (const line of run.stdout.split("\n")) {
            const found = /^\s*(\S+) => (\/\S+) \(0x[0-9a-f]+\)$/.exec(line);
            if (found) resolved.set(found[1], found[2]);
          }
        }
      }
    }
    // dpkg lists a usr-merged library under /usr/lib, which ldd may name under /lib.
    const candidates = (path) => [...new Set([path, path.replace(/^\/lib/, "/usr/lib"), path.replace(/^\/usr\/lib/, "/lib")])];
    const owners = new Map();
    const query = spawnSync("dpkg", ["-S", ...[...resolved.values()].flatMap(candidates)], { encoding: "utf8" });
    for (const line of query.stdout.split("\n")) {
      const match = /^(.+?): (\/.+)$/.exec(line);
      if (match) owners.set(match[2], match[1].split(", ").map((each) => each.split(":")[0]));
    }
    const pins = readPins(pinFile);
    const names = new Set(pins.packages.map((pin) => pin.name));
    const found = {};
    for (const [soname, path] of resolved) {
      const owner = candidates(path).flatMap((each) => owners.get(each) ?? []).find((each) => names.has(each));
      if (owner) (found[owner] ??= []).push(soname);
    }
    const expected = Object.fromEntries(pins.packages.map((pin) => [pin.name, Object.keys(pin.links).sort()]));
    assert.deepEqual(Object.fromEntries(Object.entries(found).map(([name, sonames]) => [name, sonames.sort()])), expected);
  });
});

// --- The check ------------------------------------------------------------------------------

describe("the check", linuxOnly, () => {
  test("runs ldd over the eight directories' executables and libraries, each with its bundle's lib and sys/lib, and answers the sorted missing sonames", () => {
    const browsers = fakeBrowsers();
    const log = join(tempDir("ldd-log"), "calls");
    const env = { ...process.env, PROTO_LDD: stubLdd(), STUB_LDD_NEEDS: "libxml2.so.2 libicuuc.so.74 libwebkit.so.0", STUB_LDD_LOG: log, LD_LIBRARY_PATH: "/elsewhere" };
    assert.deepEqual(checkWebkitLibs(browsers.revision, { env }), ["libicuuc.so.74", "libxml2.so.2"]);
    const calls = readFileSync(log, "utf8").trim().split("\n").map((line) => line.split("\t")).sort();
    const expected = [];
    for (const bundle of ["minibrowser-gtk", "minibrowser-wpe"]) {
      const path = `${join(browsers.revision, bundle, "lib")}:${join(browsers.revision, bundle, "sys", "lib")}`;
      for (const file of ["MiniBrowser", "bin/MiniBrowser", "bin/WebKitWebProcess", "lib/libMiniBrowserInjectedBundle.so", "sys/lib/libwebkit.so.0"]) {
        expected.push([join(browsers.revision, bundle, file), path]);
      }
    }
    assert.deepEqual(calls, expected.sort());
    assert.deepEqual(webkitDirectories, ["minibrowser-gtk", "minibrowser-gtk/bin", "minibrowser-gtk/lib", "minibrowser-gtk/sys/lib", "minibrowser-wpe", "minibrowser-wpe/bin", "minibrowser-wpe/lib", "minibrowser-wpe/sys/lib"]);
  });

  test("on macOS it answers none without running anything", () => {
    const browsers = fakeBrowsers();
    const log = join(tempDir("ldd-log"), "calls");
    const env = { ...process.env, PROTO_LDD: stubLdd(), STUB_LDD_NEEDS: "libxml2.so.2", STUB_LDD_LOG: log };
    assert.deepEqual(checkWebkitLibs(browsers.revision, { env, platform: "darwin" }), []);
    assert.equal(existsSync(log), false);
  });
});

describe("WebKit's availability", linuxOnly, () => {
  test("is the check at every reading: proto targets shows it unavailable, and proto open to it exits 1, naming the soname and proto install", async (t) => {
    const browsers = fakeBrowsers();
    const session = protoSession(t, { env: { PROTO_BROWSERS_PATH: browsers.root, PROTO_LDD: stubLdd(), STUB_LDD_NEEDS: "libicuuc.so.74" } });
    const targets = await session.run(["targets"]);
    assert.equal(targets.status, 0, targets.stderr);
    assert.match(targets.stdout, new RegExp(`^  webkit ${webkitPinned.browserVersion.replace(".", "\\.")}: unavailable: ${lacks(["libicuuc.so.74"]).replace(/[.()`]/g, "\\$&")}; `, "m"));
    const opened = await session.run(["open", "http://127.0.0.1:1/", "--target", "webkit/phone"]);
    assert.deepEqual([opened.status, opened.stderr], [1, `proto: ${lacks(["libicuuc.so.74"])}\n`]);
    // Placed, the same host reads it again and finds it whole.
    for (const dir of browsers.libs) writeFileSync(join(dir, "libicuuc.so.74"), "\x7fELF");
    const { body } = await session.request("GET", "/v1/targets");
    assert.deepEqual(body.engines.find((engine) => engine.name === "webkit").available, true);
  });
});

// --- proto install --------------------------------------------------------------------------

describe("proto install's library step", linuxOnly, () => {
  test("with nothing missing it fetches nothing", async (t) => {
    const { session, served, browsers } = await installSession(t, { needs: [] });
    const was = before(browsers);
    const installed = await session.run(["install"]);
    assert.deepEqual(installed, { status: 0, stdout: "proto: the pinned browsers are installed\nproto: WebKit's libraries resolve; nothing to place\n", stderr: "" });
    assert.deepEqual([served.archive.requests, served.launchpad.requests], [[], []]);
    assert.deepEqual(before(browsers), was);
  });

  test("places each missing soname's real file and link into both bundles' sys/lib, and only those", async (t) => {
    const { session, served, browsers, packages, check } = await installSession(t);
    assert.deepEqual(check(), four);
    const want = placed(browsers, packages);
    const installed = await session.run(["install"]);
    assert.deepEqual(installed, { status: 0, stdout: placedLines, stderr: "" });
    for (const dir of browsers.libs) assert.deepEqual(holdings(dir), want);
    assert.deepEqual(check(), []);
    assert.equal(served.launchpad.requests.length, 0);
    // Placed, the next install finds nothing to place.
    const again = await session.run(["install"]);
    assert.equal(again.stdout, "proto: the pinned browsers are installed\nproto: WebKit's libraries resolve; nothing to place\n");
  });

  test("places only what the check names: one soname of a package", async (t) => {
    const { session, served, browsers } = await installSession(t, { needs: ["libxml2.so.2"] });
    const installed = await session.run(["install"]);
    assert.equal(installed.stdout, `proto: the pinned browsers are installed\nproto: placed libxml2.so.2 from libxml2 2.9.14+dfsg-1.3ubuntu3.10 into WebKit ${webkitPinned.browserVersion}\n`);
    assert.deepEqual(served.archive.requests, ["/ubuntu/pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3.10_amd64.deb"]);
    assert.deepEqual(Object.keys(holdings(browsers.libs[1])), ["libwebkit.so.0", "libxml2.so.2", "libxml2.so.2.9.14"]);
  });

  test("refuses altered bytes by SHA-256 and takes the second source; a 404 first source falls back too", async (t) => {
    const { session, served, browsers, packages, pins } = await installSession(t);
    served.archive.routes[`/ubuntu/${poolOf(pins, "libicu74")}`] = Buffer.concat([packages.libicu74.bytes, Buffer.from("altered")]);
    delete served.archive.routes[`/ubuntu/${poolOf(pins, "libxml2")}`];
    const installed = await session.run(["install"]);
    assert.deepEqual(installed, { status: 0, stdout: placedLines, stderr: "" });
    assert.deepEqual(served.launchpad.requests.sort(), [`/lp/${basename(poolOf(pins, "libicu74"))}`, `/lp/${basename(poolOf(pins, "libxml2"))}`].sort());
    for (const dir of browsers.libs) assert.deepEqual(holdings(dir), placed(browsers, packages));
  });

  test("with both sources failing it exits 1 naming the package and each source's reason, with nothing placed", async (t) => {
    const { session, served, browsers, pins } = await installSession(t);
    const pool = poolOf(pins, "libxml2");
    served.archive.routes[`/ubuntu/${pool}`] = Buffer.from("not the package");
    delete served.launchpad.routes[`/lp/${basename(pool)}`];
    const was = before(browsers);
    const installed = await session.run(["install"]);
    const bad = digest(Buffer.from("not the package"));
    const pinned = JSON.parse(readFileSync(pins, "utf8")).packages[1].sha256;
    assert.equal(installed.status, 1);
    assert.equal(installed.stderr, `proto: could not fetch libxml2 2.9.14+dfsg-1.3ubuntu3.10: ${served.archive.base}ubuntu/${pool}: SHA-256 ${bad} is not the pin's ${pinned}; ${served.launchpad.base}lp/${basename(pool)}: HTTP 404\n`);
    assert.deepEqual(before(browsers), was);
  });

  test("refuses a redirect off the sources' hosts", async (t) => {
    const { session, served, browsers, packages, pins } = await installSession(t);
    const elsewhere = await serve(t, { "/libicu74.deb": packages.libicu74.bytes });
    served.archive.routes[`/ubuntu/${poolOf(pins, "libicu74")}`] = { status: 302, location: `${elsewhere.base}libicu74.deb` };
    // A redirect onto the other source's host is followed.
    served.archive.routes[`/ubuntu/${poolOf(pins, "libxml2")}`] = { status: 302, location: `${served.launchpad.base}lp/${basename(poolOf(pins, "libxml2"))}` };
    const installed = await session.run(["install"]);
    assert.deepEqual(installed, { status: 0, stdout: placedLines, stderr: "" });
    assert.deepEqual(elsewhere.requests, []);
    assert.deepEqual(served.launchpad.requests.sort(), [`/lp/${basename(poolOf(pins, "libicu74"))}`, `/lp/${basename(poolOf(pins, "libxml2"))}`].sort());
    for (const dir of browsers.libs) assert.deepEqual(holdings(dir), placed(browsers, packages));

  });

  test("a redirect off the sources' hosts is that source's failure", async (t) => {
    const { session, served, browsers, packages, pins } = await installSession(t, { needs: ["libicuuc.so.74"] });
    const elsewhere = await serve(t, { "/libicu74.deb": packages.libicu74.bytes });
    const pool = poolOf(pins, "libicu74");
    served.archive.routes[`/ubuntu/${pool}`] = { status: 302, location: `${elsewhere.base}libicu74.deb` };
    delete served.launchpad.routes[`/lp/${basename(pool)}`];
    const was = before(browsers);
    const refused = await session.run(["install"]);
    assert.equal(refused.status, 1);
    assert.equal(refused.stderr, `proto: could not fetch libicu74 74.2-1ubuntu3.1: ${served.archive.base}ubuntu/${pool}: a redirect to ${elsewhere.base.slice(0, -1)} is off the sources' hosts (${new URL(served.archive.base).host}, ${new URL(served.launchpad.base).host}); ${served.launchpad.base}lp/${basename(pool)}: HTTP 404\n`);
    assert.deepEqual(elsewhere.requests, []);
    assert.deepEqual(before(browsers), was);
  });

  for (const [what, extra, linkTargets] of [
    ["an entry path holding ..", [["./usr/lib/x86_64-linux-gnu/../../../../escaped.so.1", { data: Buffer.from("out") }]], {}],
    ["a soname link pointing out of sys/lib", [], { "libicuuc.so.74": "../../../../etc/passwd" }],
  ]) {
    test(`refuses a package holding ${what}, with nothing written`, async (t) => {
      const packages = { libicu74: deb("libicu74", icuLinks, { extra, linkTargets }), libxml2: deb("libxml2", xmlLinks) };
      const { session, browsers } = await installSession(t, { packages });
      const was = before(browsers);
      const installed = await session.run(["install"]);
      assert.equal(installed.status, 1);
      assert.match(installed.stderr, /^proto: libicu74 74\.2-1ubuntu3\.1 is refused: its (entry \.\/usr\/lib\/x86_64-linux-gnu\/\.\.\/\.\.\/\.\.\/\.\.\/escaped\.so\.1 leaves the package's root|link libicuuc\.so\.74 -> \.\.\/\.\.\/\.\.\/\.\.\/etc\/passwd points out of sys\/lib)\n$/);
      assert.deepEqual(before(browsers), was);
    });
  }

  test("a placing stopped after its first real file leaves the check naming the rest, and a rerun completes it", async (t) => {
    const { session, browsers, packages, check } = await installSession(t);
    if (process.getuid?.() === 0) return t.skip("root writes a read-only directory");
    chmodSync(browsers.libs[1], 0o555);
    const stopped = await session.run(["install"]);
    chmodSync(browsers.libs[1], 0o755);
    assert.equal(stopped.status, 1);
    assert.match(stopped.stderr, /^proto: could not write .*minibrowser-wpe\/sys\/lib\/libicudata\.so\.74\.2: EACCES\n$/);
    assert.deepEqual(Object.keys(holdings(browsers.libs[0])), ["libicudata.so.74.2", "libwebkit.so.0"]);
    assert.deepEqual(check(), four);
    const rerun = await session.run(["install"]);
    assert.deepEqual(rerun, { status: 0, stdout: placedLines, stderr: "" });
    for (const dir of browsers.libs) assert.deepEqual(holdings(dir), placed(browsers, packages));
  });

  test("two installs at once leave every file whole", async (t) => {
    const { session, browsers, packages, check } = await installSession(t);
    const runs = await Promise.all([session.run(["install"]), session.run(["install"])]);
    for (const run of runs) assert.equal(run.status, 0, run.stderr);
    for (const dir of browsers.libs) assert.deepEqual(holdings(dir), placed(browsers, packages));
    assert.deepEqual(check(), []);
  });

  test("a soname no pinned package provides exits 1 with the still-lacks line, once the rest are placed", async (t) => {
    const { session, browsers, packages } = await installSession(t, { needs: [...four, "libfoo.so.1"] });
    const installed = await session.run(["install"]);
    assert.equal(installed.status, 1);
    assert.equal(installed.stdout, placedLines);
    assert.equal(installed.stderr, `proto: WebKit ${webkitPinned.browserVersion} still lacks libfoo.so.1; no pinned package provides them: see the README's "WebKit on Linux"\n`);
    for (const dir of browsers.libs) assert.deepEqual(holdings(dir), placed(browsers, packages));
  });

  test("pins checked for another WebKit revision add the refresh line and still place", async (t) => {
    const { session, browsers, packages } = await installSession(t, { change: (pins) => ({ ...pins, checkedFor: { ...pins.checkedFor, webkitRevision: "2300" } }) });
    const installed = await session.run(["install"]);
    assert.deepEqual(installed, { status: 0, stdout: placedLines, stderr: "proto: the pins were checked for WebKit revision 2300; refresh them (README, \"WebKit on Linux\")\n" });
    for (const dir of browsers.libs) assert.deepEqual(holdings(dir), placed(browsers, packages));
  });
});

// --- proto install --refresh-pins -----------------------------------------------------------

// A Packages.gz listing each [name, version, pool, sha256].
const packagesGz = (entries) => gzipSync(entries.map(([name, version, pool, sha256]) => `Package: ${name}\nArchitecture: amd64\nVersion: ${version}\nFilename: ${pool}\nSize: 1\nSHA256: ${sha256}\nDescription: ${name}\n`).join("\n"));

// The archive's noble-updates listing a newer libxml2 (and libicu74 in the release pocket only),
// a jammy series, and libfoo1, which provides libfoo.so.1; both sources serve every file.
async function refreshSources(t, session) {
  const xml = deb("libxml2", { "libxml2.so.2": "libxml2.so.2.9.15" });
  const icu = session.packages.libicu74;
  const foo = deb("libfoo1", { "libfoo.so.1": "libfoo.so.1.0.0" });
  const files = {
    libxml2: ["2.9.14+dfsg-1.3ubuntu3.11", "pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3.11_amd64.deb", xml],
    libicu74: ["74.2-1ubuntu3.1", "pool/main/i/icu/libicu74_74.2-1ubuntu3.1_amd64.deb", icu],
    libfoo1: ["1.0-1", "pool/main/f/foo/libfoo1_1.0-1_amd64.deb", foo],
  };
  const { archive, launchpad } = session.served;
  for (const [, pool, fixture] of Object.values(files)) {
    archive.routes[`/ubuntu/${pool}`] = fixture.bytes;
    launchpad.routes[`/lp/${basename(pool)}`] = fixture.bytes;
  }
  const row = (name) => [name, files[name][0], files[name][1], files[name][2].sha256];
  archive.routes["/ubuntu/dists/noble-updates/main/binary-amd64/Packages.gz"] = packagesGz([row("libxml2")]);
  archive.routes["/ubuntu/dists/noble/main/binary-amd64/Packages.gz"] = packagesGz([["libxml2", "2.9.14+dfsg-1.3ubuntu3", "pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3_amd64.deb", "0".repeat(64)], row("libicu74"), row("libfoo1")]);
  archive.routes["/ubuntu/dists/jammy-updates/main/binary-amd64/Packages.gz"] = packagesGz([row("libxml2"), row("libicu74")]);
  archive.routes["/ubuntu/dists/jammy/main/binary-amd64/Packages.gz"] = packagesGz([]);
  return { files, xml, foo };
}

const today = () => new Date().toISOString().slice(0, 10);

describe("proto install --refresh-pins", linuxOnly, () => {
  test("moves the pins to the series' current packages, places them, and writes the pin file once WebKit lacks nothing", async (t) => {
    const session = await installSession(t);
    const { files, xml } = await refreshSources(t, session);
    const refreshed = await session.session.run(["install", "--refresh-pins"]);
    assert.equal(refreshed.status, 0, refreshed.stderr);
    const pins = readPins(session.pins);
    const playwrightCore = JSON.parse(readFileSync(join(repoRoot, "servers", "node_modules", "playwright-core", "package.json"), "utf8")).version;
    assert.deepEqual({ ...pins, checked: pins.checked.slice(0, 10) }, {
      checkedFor: { playwrightCore, webkitRevision: webkitPinned.revision, webkitVersion: webkitPinned.browserVersion },
      series: "noble",
      checked: today(),
      packages: [
        { name: "libicu74", version: "74.2-1ubuntu3.1", pool: files.libicu74[1], sha256: files.libicu74[2].sha256, links: icuLinks },
        { name: "libxml2", version: "2.9.14+dfsg-1.3ubuntu3.11", pool: files.libxml2[1], sha256: xml.sha256, links: { "libxml2.so.2": "libxml2.so.2.9.15" } },
      ],
    });
    assert.match(pins.checked, /^\d{4}-\d\d-\d\d, [^,()]+$/);
    assert.ok(!pins.checked.includes(hostname()), "the pins name the OS, never the machine");
    assert.equal(readFileSync(session.pins, "utf8"), formatPins(pins));
    for (const dir of session.browsers.libs) {
      const held = holdings(dir);
      assert.equal(held["libxml2.so.2"], "-> libxml2.so.2.9.15");
      assert.equal(held["libxml2.so.2.9.15"], digest(xml.files["libxml2.so.2.9.15"]));
    }
    assert.deepEqual(session.check(), []);
    // Each new file was fetched from both sources.
    assert.ok(session.served.launchpad.requests.includes(`/lp/${basename(files.libxml2[1])}`));
    assert.ok(session.served.archive.requests.includes(`/ubuntu/${files.libxml2[1]}`));
  });

  test("refuses a file the two sources do not both serve as the index has it, writing nothing", async (t) => {
    const session = await installSession(t);
    const { files } = await refreshSources(t, session);
    session.served.launchpad.routes[`/lp/${basename(files.libxml2[1])}`] = Buffer.from("altered");
    const was = readFileSync(session.pins, "utf8");
    const refreshed = await session.session.run(["install", "--refresh-pins"]);
    assert.equal(refreshed.status, 1);
    assert.match(refreshed.stderr, /^proto: libxml2 2\.9\.14\+dfsg-1\.3ubuntu3\.11 is not taken, since both sources must serve the index's file: .*lp\/libxml2_2\.9\.14\+dfsg-1\.3ubuntu3\.11_amd64\.deb: SHA-256 [0-9a-f]{64} is not the index's [0-9a-f]{64}\n$/);
    assert.equal(readFileSync(session.pins, "utf8"), was);
  });

  test("with a soname still missing it writes nothing and names it; --add pins its package", async (t) => {
    const session = await installSession(t, { needs: [...four, "libfoo.so.1"] });
    const { foo, files } = await refreshSources(t, session);
    const was = readFileSync(session.pins, "utf8");
    const refreshed = await session.session.run(["install", "--refresh-pins"]);
    assert.equal(refreshed.status, 1);
    assert.equal(refreshed.stderr, `proto: WebKit ${webkitPinned.browserVersion} still lacks libfoo.so.1; the pins are unchanged: find the package that provides each and rerun with --add <package> (README, "WebKit on Linux")\n`);
    assert.equal(readFileSync(session.pins, "utf8"), was);
    const added = await session.session.run(["install", "--refresh-pins", "--add", "libfoo1"]);
    assert.equal(added.status, 0, added.stderr);
    const pins = readPins(session.pins);
    assert.deepEqual(pins.packages.map((pin) => pin.name), ["libicu74", "libxml2", "libfoo1"]);
    assert.deepEqual(pins.packages[2], { name: "libfoo1", version: "1.0-1", pool: files.libfoo1[1], sha256: foo.sha256, links: { "libfoo.so.1": "libfoo.so.1.0.0" } });
    assert.deepEqual(session.check(), []);
  });

  test("--series reads that series", async (t) => {
    const session = await installSession(t);
    await refreshSources(t, session);
    const refreshed = await session.session.run(["install", "--refresh-pins", "--series", "jammy"]);
    assert.equal(refreshed.status, 0, refreshed.stderr);
    assert.equal(readPins(session.pins).series, "jammy");
    assert.ok(session.served.archive.requests.includes("/ubuntu/dists/jammy-updates/main/binary-amd64/Packages.gz"));
    assert.equal((await session.session.run(["install", "--series", "jammy"])).status, 2);
  });
});
