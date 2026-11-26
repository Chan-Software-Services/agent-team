// WebKit's libraries on Linux: the one reader of the pins in webkit-libs.json, the check that
// names the sonames Playwright's WebKit build lacks on this machine, and the step of `proto
// install` that places them, from Ubuntu's own packages, into the WebKit bundle alone.
//
// Playwright gives a Linux it does not know (Arch, EndeavourOS) its ubuntu24.04-x64 build, which
// links sonames such a machine may not have (ICU 74, libxml2.so.2). Each bundle's MiniBrowser
// wrapper sets LD_LIBRARY_PATH to its own lib and sys/lib, dropping whatever a launch passes, so
// the libraries go into each bundle's sys/lib, and nothing is written anywhere else: nothing
// system-wide, and nothing under sudo. On macOS none of this runs: Playwright's Mac WebKit links
// the system's own frameworks.
//
//   webkitDirectories      the eight directories checked, as Playwright 1.65.1's own host check
//                          (its registry's webkitLinuxLddDirectories) lists them
//   readPins(file)         its pins, checked: { checkedFor, series, checked, packages }
//   formatPins(pins)       the pins as the file holds them, byte for byte
//   webkitBuild()          the installed WebKit: { revision, version, dir }, from playwright-core's
//                          browsers.json and its browsers path
//   checkWebkitLibs(revisionDir, { platform, env })
//                          on Linux, ldd (PROTO_LDD in its place) over every regular file that is
//                          executable or named *.so* in the eight directories, each with LD_LIBRARY_PATH
//                          set to its bundle's lib and sys/lib, as its wrapper sets it: the sorted
//                          sonames it names not found, or none; elsewhere none, running nothing
//   lacksLine(version, missing)   "WebKit <version> lacks <sonames> on this machine; run `proto install`"
//   await placeWebkitLibs(revisionDir, { file, env, say, warn })
//                          `proto install`'s step: places, from the pinned packages, only what the
//                          check names missing, then checks again; throws a one-line reason
//   await refreshPins(revisionDir, { file, env, series, add, say })
//                          `proto install --refresh-pins`: the pins moved to the series' current
//                          packages, placed, checked, and only then written to `file`
//
// placeWebkitLibs and refreshPins read the pins from `file`, by default PROTO_WEBKIT_LIBS_FILE,
// else this directory's webkit-libs.json.
//
// Fetching: each .deb over HTTPS from archive.ubuntu.com's pool, then, on any failure (an HTTP
// error, 60 s without its whole answer, a wrong SHA-256), from Launchpad's librarian by its file
// name; a redirect is followed only to archive.ubuntu.com, launchpad.net and
// launchpadlibrarian.net, and every file is held to its pinned SHA-256 whatever its source. A
// .deb is read in Node alone (its ar archive, its data.tar.zst by zlib's zstd, the tar), only
// the entries the pins name are taken, and an entry path holding ".." or absolute, or a soname
// link pointing anywhere but a file beside it, refuses the package before anything is written.
// Each file is written as a temporary file renamed into place, the real file before its link, so
// a soname is either absent or whole, and two installs at once write the same bytes.
// Seams, read only from the environment: PROTO_LDD, the program run in place of ldd;
// PROTO_WEBKIT_LIBS_SOURCES, the two base URLs in place of archive.ubuntu.com's
// (https://archive.ubuntu.com/ubuntu/, a pool path below it) and Launchpad's
// (https://launchpad.net/ubuntu/+archive/primary/+files/, a file name below it), blank-separated,
// whose hosts are then the only ones a redirect may reach; PROTO_WEBKIT_LIBS_FILE, above.
import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, readdirSync, readFileSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, zstdDecompressSync } from "node:zlib";
import { pinnedBrowsers, playwright, serversDir } from "./playwright.mjs";

const bundles = ["minibrowser-gtk", "minibrowser-wpe"];
// Playwright 1.65.1's own list, its registry's webkitLinuxLddDirectories.
export const webkitDirectories = bundles.flatMap((bundle) => [bundle, `${bundle}/bin`, `${bundle}/lib`, `${bundle}/sys/lib`]);

const fetchTimeoutMs = 60_000;
const defaultSources = ["https://archive.ubuntu.com/ubuntu/", "https://launchpad.net/ubuntu/+archive/primary/+files/"];
const defaultHosts = ["archive.ubuntu.com", "launchpad.net", "launchpadlibrarian.net"];
const readme = 'see the README\'s "WebKit on Linux"';

// The pin file: PROTO_WEBKIT_LIBS_FILE, else this directory's webkit-libs.json.
const pinsFile = (env = process.env) => env.PROTO_WEBKIT_LIBS_FILE || join(dirname(fileURLToPath(import.meta.url)), "webkit-libs.json");

const plainName = (name) => typeof name === "string" && /^[A-Za-z0-9._+-]+$/.test(name) && name !== "." && name !== "..";

export function readPins(file) {
  let pins;
  try {
    pins = JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`the WebKit library pins ${file} cannot be read: ${error.message}`);
  }
  const bad = (reason) => new Error(`${file}: ${reason}`);
  if (typeof pins?.series !== "string" || !Array.isArray(pins.packages)) throw bad("it needs series and packages");
  for (const pin of pins.packages) {
    for (const key of ["name", "version", "pool", "sha256"]) if (typeof pin[key] !== "string") throw bad(`a package needs ${key}`);
    if (!/^[0-9a-f]{64}$/.test(pin.sha256)) throw bad(`${pin.name}: sha256 is not 64 hex digits`);
    if (!plainName(basename(pin.pool)) || pin.pool.split("/").includes("..") || pin.pool.startsWith("/")) throw bad(`${pin.name}: pool ${pin.pool} is not a pool path`);
    if (typeof pin.links !== "object" || pin.links === null || !Object.keys(pin.links).length) throw bad(`${pin.name}: links names no soname`);
    for (const [soname, real] of Object.entries(pin.links)) {
      if (!plainName(soname) || !plainName(real)) throw bad(`${pin.name}: the link ${soname} -> ${real} is not a file name beside it`);
    }
  }
  return pins;
}

// The layout the file is kept in, so a refresh's diff shows only what moved.
export function formatPins(pins) {
  const inline = (value) => `{ ${Object.entries(value).map(([key, each]) => `${JSON.stringify(key)}: ${JSON.stringify(each)}`).join(", ")} }`;
  const packages = pins.packages.map((pin) => [
    "    {",
    `      "name": ${JSON.stringify(pin.name)},`,
    `      "version": ${JSON.stringify(pin.version)},`,
    `      "pool": ${JSON.stringify(pin.pool)},`,
    `      "sha256": ${JSON.stringify(pin.sha256)},`,
    `      "links": ${inline(pin.links)}`,
    "    }",
  ].join("\n"));
  return [
    "{",
    `  "checkedFor": ${inline(pins.checkedFor)},`,
    `  "series": ${JSON.stringify(pins.series)},`,
    `  "checked": ${JSON.stringify(pins.checked)},`,
    '  "packages": [',
    packages.join(",\n"),
    "  ]",
    "}",
    "",
  ].join("\n");
}

export function webkitBuild() {
  const pinned = pinnedBrowsers().find((browser) => browser.name === "webkit");
  return { revision: pinned.revision, version: pinned.browserVersion, dir: dirname(playwright().webkit.executablePath()) };
}

// The files Playwright's check reads in one directory: regular files (a link followed), each
// executable or a shared library by name.
function checkedFiles(dir) {
  if (!existsSync(dir)) return [];
  const files = [];
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name);
    let stat;
    try {
      stat = statSync(path);
    } catch {
      continue; // A dangling link: what it names is missing, which ldd reports where it is needed.
    }
    const library = name.endsWith(".so") || name.includes(".so.");
    if (stat.isFile() && (library || stat.mode & 0o111)) files.push(path);
  }
  return files;
}

export function checkWebkitLibs(revisionDir, { platform = process.platform, env = process.env } = {}) {
  if (platform !== "linux") return [];
  const ldd = env.PROTO_LDD || "ldd";
  const missing = new Set();
  for (const bundle of bundles) {
    const libraryPath = `${join(revisionDir, bundle, "lib")}:${join(revisionDir, bundle, "sys", "lib")}`;
    for (const directory of webkitDirectories.filter((each) => each.split("/")[0] === bundle)) {
      for (const file of checkedFiles(join(revisionDir, directory))) {
        const run = spawnSync(ldd, [file], { cwd: dirname(file), env: { ...env, LD_LIBRARY_PATH: libraryPath }, encoding: "utf8" });
        if (run.error) throw new Error(`the WebKit library check could not run ${ldd}: ${run.error.message}`);
        // ldd fails on a file that is no dynamic executable (a wrapper script), as Playwright's check skips it.
        if (run.status !== 0) continue;
        for (const line of run.stdout.split("\n")) {
          const found = /^\s*(\S+) => not found\s*$/.exec(line);
          if (found) missing.add(found[1]);
        }
      }
    }
  }
  return [...missing].sort();
}

export const lacksLine = (version, missing) => `WebKit ${version} lacks ${missing.join(", ")} on this machine; run \`proto install\``;

// --- Fetching -------------------------------------------------------------------------------

function sourcesOf(env) {
  const seam = env.PROTO_WEBKIT_LIBS_SOURCES;
  if (!seam) return { bases: defaultSources, hosts: defaultHosts, protocols: ["https:"] };
  const bases = seam.split(/\s+/).filter(Boolean);
  if (bases.length !== 2) throw new Error(`PROTO_WEBKIT_LIBS_SOURCES must name two base URLs, blank-separated; it names ${bases.length}`);
  const urls = bases.map((base) => new URL(base));
  return { bases, hosts: urls.map((url) => url.host), protocols: [...new Set(urls.map((url) => url.protocol))] };
}

// The bytes at `url`, following redirects only onto the sources' hosts; throws "<url>: <reason>".
async function fetchBytes(url, sources) {
  const signal = AbortSignal.timeout(fetchTimeoutMs);
  let at = new URL(url);
  try {
    for (let hop = 0; hop <= 5; hop++) {
      if (!sources.protocols.includes(at.protocol) || !sources.hosts.includes(at.host)) {
        throw new Error(hop ? `a redirect to ${at.origin} is off the sources' hosts (${sources.hosts.join(", ")})` : `${at.origin} is not a source`);
      }
      const response = await fetch(at, { redirect: "manual", signal });
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        await response.body?.cancel();
        const location = response.headers.get("location");
        if (!location) throw new Error(`HTTP ${response.status} with no location`);
        at = new URL(location, at);
        continue;
      }
      if (!response.ok) {
        await response.body?.cancel();
        throw new Error(`HTTP ${response.status}`);
      }
      return Buffer.from(await response.arrayBuffer());
    }
    throw new Error("more than 5 redirects");
  } catch (error) {
    const reason = error.name === "TimeoutError" ? `no whole answer in ${fetchTimeoutMs / 1000} s` : error.cause?.message ?? error.message;
    throw new Error(`${url}: ${reason}`);
  }
}

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

const debUrls = (bases, pool) => [new URL(pool, bases[0]).href, new URL(basename(pool), bases[1]).href];

// The pinned .deb, from the first source that answers it with the pinned SHA-256.
async function fetchPinned(pin, sources) {
  const reasons = [];
  for (const url of debUrls(sources.bases, pin.pool)) {
    try {
      const bytes = await fetchBytes(url, sources);
      const got = sha256(bytes);
      if (got !== pin.sha256) throw new Error(`${url}: SHA-256 ${got} is not the pin's ${pin.sha256}`);
      return bytes;
    } catch (error) {
      reasons.push(error.message);
    }
  }
  throw new Error(`could not fetch ${pin.name} ${pin.version}: ${reasons.join("; ")}`);
}

// --- Reading a .deb -------------------------------------------------------------------------

function arMembers(bytes) {
  if (bytes.subarray(0, 8).toString("latin1") !== "!<arch>\n") throw new Error("it is not an ar archive");
  const members = new Map();
  let at = 8;
  while (at + 60 <= bytes.length) {
    const header = bytes.subarray(at, at + 60).toString("latin1");
    if (header.slice(58, 60) !== "`\n") throw new Error("its ar archive has a broken header");
    const name = header.slice(0, 16).trim().replace(/\/$/, "");
    const size = Number.parseInt(header.slice(48, 58).trim(), 10);
    if (!Number.isSafeInteger(size) || at + 60 + size > bytes.length) throw new Error(`its ar member ${name} runs past the end`);
    members.set(name, bytes.subarray(at + 60, at + 60 + size));
    at += 60 + size + (size % 2);
  }
  return members;
}

const tarText = (block, offset, length) => {
  const field = block.subarray(offset, offset + length);
  const end = field.indexOf(0);
  return field.subarray(0, end === -1 ? length : end).toString("utf8");
};
const tarNumber = (block, offset, length) => {
  const field = block.subarray(offset, offset + length);
  if (field[0] & 0x80) return Number(field.subarray(1).reduce((value, byte) => value * 256n + BigInt(byte), 0n));
  return Number.parseInt(tarText(block, offset, length).trim() || "0", 8);
};

// Each entry of a tar: { path, type: "file" | "link" | "directory" | "other", target, mode, data }.
function tarEntries(bytes) {
  const entries = [];
  let longName = null;
  let longLink = null;
  let pax = {};
  for (let at = 0; at + 512 <= bytes.length;) {
    const block = bytes.subarray(at, at + 512);
    if (block.every((byte) => byte === 0)) break;
    const size = tarNumber(block, 124, 12);
    const flag = String.fromCharCode(block[156] || 0x30);
    const data = bytes.subarray(at + 512, at + 512 + size);
    if (data.length !== size) throw new Error("its data.tar runs past the end");
    at += 512 + Math.ceil(size / 512) * 512;
    if (flag === "L") longName = data.toString("utf8").replace(/\0+$/, "");
    else if (flag === "K") longLink = data.toString("utf8").replace(/\0+$/, "");
    else if (flag === "x") {
      for (const record of data.toString("utf8").split("\n").filter(Boolean)) {
        const pair = record.slice(record.indexOf(" ") + 1);
        const equals = pair.indexOf("=");
        pax[pair.slice(0, equals)] = pair.slice(equals + 1);
      }
    } else if (flag !== "g") {
      const prefix = tarText(block, 345, 155);
      const name = tarText(block, 0, 100);
      const path = pax.path ?? longName ?? (prefix ? `${prefix}/${name}` : name);
      const target = pax.linkpath ?? longLink ?? tarText(block, 157, 100);
      const type = flag === "0" || flag === "7" ? "file" : flag === "2" ? "link" : flag === "5" ? "directory" : "other";
      entries.push({ path, type, target, mode: tarNumber(block, 100, 8), data });
      longName = longLink = null;
      pax = {};
    }
  }
  return entries;
}

// A .deb's data entries, every path checked, by file name; throws a one-line reason.
function debEntries(bytes, label) {
  try {
    const members = arMembers(bytes);
    const dataName = [...members.keys()].find((name) => name.startsWith("data.tar"));
    if (!dataName) throw new Error("it holds no data.tar");
    const packed = members.get(dataName);
    const tar = dataName === "data.tar.zst" ? zstdDecompressSync(packed) : dataName === "data.tar.gz" ? gunzipSync(packed) : dataName === "data.tar" ? packed : null;
    if (!tar) throw new Error(`its ${dataName} is in a compression proto cannot read (zst or gz)`);
    const byName = new Map();
    for (const entry of tarEntries(tar)) {
      const path = entry.path.replace(/^\.\//, "");
      if (path.startsWith("/") || path.split("/").includes("..")) throw new Error(`its entry ${entry.path} leaves the package's root`);
      if (entry.type === "directory") continue;
      const name = basename(path);
      if (!byName.has(name)) byName.set(name, []);
      byName.get(name).push(entry);
    }
    return byName;
  } catch (error) {
    throw new Error(`${label} is refused: ${error.message}`);
  }
}

// From a .deb's entries, each soname's link checked to name its real file beside it: [{ soname,
// real, bytes, mode }].
function takeLinks(entries, links, label) {
  const one = (name) => {
    const found = entries.get(name) ?? [];
    if (found.length !== 1) throw new Error(`${label} is refused: it holds ${found.length ? "more than one" : "no"} ${name}`);
    return found[0];
  };
  return Object.entries(links).sort(([a], [b]) => a.localeCompare(b)).map(([soname, real]) => {
    const link = one(soname);
    if (link.type !== "link") throw new Error(`${label} is refused: its ${soname} is not a soname link`);
    if (!plainName(link.target)) throw new Error(`${label} is refused: its link ${soname} -> ${link.target} points out of sys/lib`);
    if (link.target !== real) throw new Error(`${label} is refused: its link ${soname} -> ${link.target} is not the pin's ${real}`);
    if (dirname(link.path) !== dirname(one(real).path)) throw new Error(`${label} is refused: its ${real} is not beside ${soname}`);
    const file = one(real);
    if (file.type !== "file") throw new Error(`${label} is refused: its ${real} is not a regular file`);
    return { soname, real, bytes: file.data, mode: (file.mode & 0o755) | 0o444 };
  });
}

// --- Placing --------------------------------------------------------------------------------

const staged = (dir, name) => join(dir, `.${name}.proto-${process.pid}-${randomBytes(4).toString("hex")}`);

function placeFile(dir, name, bytes, mode) {
  const temporary = staged(dir, name);
  try {
    writeFileSync(temporary, bytes, { mode });
    renameSync(temporary, join(dir, name));
  } catch (error) {
    rmSync(temporary, { force: true });
    throw new Error(`could not write ${join(dir, name)}: ${error.code ?? error.message}`);
  }
}

function placeLink(dir, name, target) {
  const temporary = staged(dir, name);
  try {
    symlinkSync(target, temporary);
    renameSync(temporary, join(dir, name));
  } catch (error) {
    rmSync(temporary, { force: true });
    throw new Error(`could not write ${join(dir, name)}: ${error.code ?? error.message}`);
  }
}

const libDirs = (revisionDir) => bundles.map((bundle) => join(revisionDir, bundle, "sys", "lib"));

// Each soname's real file into both bundles' sys/lib, then its link the same way.
function writeLinks(revisionDir, taken) {
  for (const { soname, real, bytes, mode } of taken) {
    for (const dir of libDirs(revisionDir)) placeFile(dir, real, bytes, mode);
    for (const dir of libDirs(revisionDir)) placeLink(dir, soname, real);
  }
}

function revisionWarning(pins, build, warn) {
  if (pins.checkedFor?.webkitRevision !== build.revision) {
    warn(`the pins were checked for WebKit revision ${pins.checkedFor?.webkitRevision}; refresh them (README, "WebKit on Linux")`);
  }
}

const stillLacks = (version, missing) => `WebKit ${version} still lacks ${missing.join(", ")}; no pinned package provides them: ${readme}`;

export async function placeWebkitLibs(revisionDir, { file = pinsFile(), env = process.env, build = webkitBuild(), say, warn }) {
  const missing = checkWebkitLibs(revisionDir, { env });
  if (!missing.length) return say("WebKit's libraries resolve; nothing to place");
  const pins = readPins(file);
  revisionWarning(pins, build, warn);
  const sources = sourcesOf(env);
  // Every package fetched and read before anything is written, so a refusal places nothing.
  const work = [];
  for (const pin of pins.packages) {
    const wanted = Object.fromEntries(Object.entries(pin.links).filter(([soname]) => missing.includes(soname)));
    if (!Object.keys(wanted).length) continue;
    const label = `${pin.name} ${pin.version}`;
    const bytes = await fetchPinned(pin, sources);
    work.push({ pin, taken: takeLinks(debEntries(bytes, label), wanted, label) });
  }
  for (const { pin, taken } of work) {
    writeLinks(revisionDir, taken);
    say(`placed ${taken.map((each) => each.soname).join(", ")} from ${pin.name} ${pin.version} into WebKit ${build.version}`);
  }
  const left = checkWebkitLibs(revisionDir, { env });
  if (left.length) throw new Error(stillLacks(build.version, left));
}

// --- Refreshing the pins --------------------------------------------------------------------

// A Packages index: each package's { Version, Filename, SHA256 }, by name.
function packagesIndex(bytes, url) {
  const index = new Map();
  for (const paragraph of gunzipSync(bytes).toString("utf8").split(/\n\s*\n/)) {
    const fields = {};
    for (const line of paragraph.split("\n")) {
      const match = /^([A-Za-z0-9-]+): (.*)$/.exec(line);
      if (match) fields[match[1]] = match[2].trim();
    }
    if (!fields.Package || index.has(fields.Package)) continue;
    for (const key of ["Version", "Filename", "SHA256"]) if (!fields[key]) throw new Error(`${url}: ${fields.Package} has no ${key}`);
    index.set(fields.Package, fields);
  }
  return index;
}

// The OS the pins were checked on, never the machine's name, since the pin file is published.
function operatingSystem() {
  try {
    return /^NAME="?([^"\n]+)"?$/m.exec(readFileSync("/etc/os-release", "utf8"))?.[1] ?? process.platform;
  } catch {
    return process.platform; // No os-release: the platform's name stands.
  }
}

export async function refreshPins(revisionDir, { file = pinsFile(), env = process.env, build = webkitBuild(), series, add = [], say }) {
  const old = readPins(file);
  series ??= old.series;
  const sources = sourcesOf(env);
  const indexes = {};
  const index = async (pocket) => {
    if (!indexes[pocket]) {
      const url = new URL(`dists/${pocket}/main/binary-amd64/Packages.gz`, sources.bases[0]).href;
      indexes[pocket] = packagesIndex(await fetchBytes(url, sources), url);
    }
    return indexes[pocket];
  };
  const missingBefore = checkWebkitLibs(revisionDir, { env });
  const names = [...new Set([...old.packages.map((pin) => pin.name), ...add])];
  const pinned = new Set(old.packages.flatMap((pin) => Object.keys(pin.links)));
  const work = [];
  for (const name of names) {
    const entry = (await index(`${series}-updates`)).get(name) ?? (await index(series)).get(name);
    if (!entry) throw new Error(`no package ${name} in ${series}-updates or ${series}`);
    const label = `${name} ${entry.Version}`;
    const reasons = [];
    let bytes;
    for (const url of debUrls(sources.bases, entry.Filename)) {
      try {
        const got = await fetchBytes(url, sources);
        const digest = sha256(got);
        if (digest !== entry.SHA256) throw new Error(`${url}: SHA-256 ${digest} is not the index's ${entry.SHA256}`);
        bytes = got;
      } catch (error) {
        reasons.push(error.message);
      }
    }
    if (reasons.length) throw new Error(`${label} is not taken, since both sources must serve the index's file: ${reasons.join("; ")}`);
    const entries = debEntries(bytes, label);
    const before = old.packages.find((pin) => pin.name === name);
    let links;
    if (before) {
      links = {};
      for (const soname of Object.keys(before.links)) {
        const link = entries.get(soname)?.find((each) => each.type === "link");
        if (!link) throw new Error(`${label} no longer holds ${soname}, which the pins list`);
        links[soname] = link.target;
      }
    } else {
      const wanted = missingBefore.filter((soname) => !pinned.has(soname) && entries.get(soname)?.some((each) => each.type === "link"));
      if (!wanted.length) throw new Error(`${label} holds none of the sonames WebKit lacks (${missingBefore.join(", ") || "none"})`);
      links = Object.fromEntries(wanted.map((soname) => [soname, entries.get(soname).find((each) => each.type === "link").target]));
    }
    work.push({ before, pin: { name, version: entry.Version, pool: entry.Filename, sha256: entry.SHA256, links }, taken: takeLinks(entries, links, label) });
  }
  for (const { before, pin, taken } of work) {
    writeLinks(revisionDir, taken);
    // The old pins' real files no new link names, so sys/lib holds only what the pins place.
    const kept = new Set(Object.values(pin.links));
    for (const real of Object.values(before?.links ?? {})) if (!kept.has(real)) for (const dir of libDirs(revisionDir)) rmSync(join(dir, real), { force: true });
    say(`placed ${taken.map((each) => each.soname).join(", ")} from ${pin.name} ${pin.version} into WebKit ${build.version}`);
  }
  const left = checkWebkitLibs(revisionDir, { env });
  if (left.length) {
    throw new Error(`WebKit ${build.version} still lacks ${left.join(", ")}; the pins are unchanged: find the package that provides each and rerun with --add <package> (README, "WebKit on Linux")`);
  }
  const playwrightCore = JSON.parse(readFileSync(join(serversDir, "node_modules", "playwright-core", "package.json"), "utf8")).version;
  const pins = {
    checkedFor: { playwrightCore, webkitRevision: build.revision, webkitVersion: build.version },
    series,
    checked: `${new Date().toISOString().slice(0, 10)}, ${operatingSystem()}`,
    packages: work.map((each) => each.pin),
  };
  const temporary = staged(dirname(file), basename(file));
  writeFileSync(temporary, formatPins(pins));
  renameSync(temporary, file);
  say(`wrote ${file}: ${pins.packages.map((pin) => `${pin.name} ${pin.version}`).join(", ")}, checked for WebKit ${build.version} (revision ${build.revision})`);
}
