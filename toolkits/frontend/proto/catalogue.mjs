// The catalogue: the engines and sizes a prototyping window can take, and the one reader of a
// target and of a project's .proto.json, so the CLI, the host, the toolbar and the bridge read
// one list. Data and pure functions only, but for readProject's one file read.
//
// A target is an engine and a size, written <engine>/<size> (webkit/phone, firefox/1024x768,
// chromium/iPhone 15). A size is a preset id, a size the project file names, a Playwright device
// name exactly as playwright-core's devices has it, a free size <width>x<height> or
// <width>x<height>@<scale> (whole pixels from 120 to 7680, a scale from 0.5 to 4, default 1,
// mobile and touch off), or `window`, the Agent Chrome's own window size, for agent-chrome only.
//
//   engines, launchedEngines   ["chromium", "firefox", "webkit", "agent-chrome"], and the first
//                              three, Playwright's builds the host launches
//   presets                    the five preset sizes by id
//   defaultUrl, defaultTarget  http://localhost:5173/ and chromium/laptop
//   readProject(dir)           .proto.json at `dir` (a git checkout's root; null for none)
//                              checked, as { file, url, sizes, matrix }, the defaults when it is
//                              missing, and `settings`, the file's JSON as written, which a
//                              client sends the host; throws "<file>: <key>: <reason>" for a bad one
//   checkProject(settings, name)   the same check of a project's JSON already parsed, named
//                              `name` in its reasons
//   resolveTarget(text, project, base)   the full target { engine, size, width, height, scale,
//                              mobile, touch, userAgent } of `text`, or throws a one-line reason;
//                              an engine or a size alone keeps the other from `base`, a target's
//                              text (default chromium/laptop)
//   targetText(target), sizeText(target)   "webkit/phone", and "390x844@3"
//   catalogue(project)         { engines, sizes, devices }: the engine names, each size the
//                              toolbar lists (the presets, then the project's) with its metrics,
//                              and the count of Playwright devices
//   windowLine(window)         a window answer of the host's as one line, "<engine> <version> at
//                              <size> (<width>x<height>@<scale>) on <url>", as the CLI and the
//                              bridge print it
//   targetsText(listing, project)   GET /v1/targets's answer as `proto targets` and the bridge's
//                              list_targets print it: the engines, each with its version,
//                              availability or reason, and capabilities, then the sizes of
//                              `project` (the client's own) with their metrics, then the window's
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { checkLocalUrl } from "./guards.mjs";
import { playwright } from "./playwright.mjs";

export const launchedEngines = ["chromium", "firefox", "webkit"];
export const engines = [...launchedEngines, "agent-chrome"];

const preset = (width, height, scale, mobile) => ({ width, height, scale, mobile, touch: mobile });
export const presets = {
  "phone-small": preset(360, 800, 3, true),
  phone: preset(390, 844, 3, true),
  tablet: preset(768, 1024, 2, true),
  laptop: preset(1440, 900, 1, false),
  desktop: preset(1920, 1080, 1, false),
};

export const defaultUrl = "http://localhost:5173/";
export const defaultTarget = "chromium/laptop";
const projectName = ".proto.json";

const freeSize = /^(\d+)x(\d+)(?:@(\d+(?:\.\d+)?))?$/;
const pixels = { min: 120, max: 7680 };
const scales = { min: 0.5, max: 4 };
const pixelRule = `whole pixels from ${pixels.min} to ${pixels.max}`;
const scaleRule = `a scale is from ${scales.min} to ${scales.max}`;
const inPixels = (n) => Number.isInteger(n) && n >= pixels.min && n <= pixels.max;
const inScales = (n) => typeof n === "number" && Number.isFinite(n) && n >= scales.min && n <= scales.max;

const devices = () => playwright().devices;
const fromDevice = (device) => ({
  width: device.viewport.width,
  height: device.viewport.height,
  scale: device.deviceScaleFactor,
  mobile: device.isMobile,
  touch: device.hasTouch,
  userAgent: device.userAgent,
});

const emptyProject = (file) => ({ file, settings: {}, url: defaultUrl, sizes: {}, matrix: null });

export function readProject(dir) {
  if (dir === null || dir === undefined) return emptyProject(null);
  const file = join(dir, projectName);
  if (!existsSync(file)) return emptyProject(null);
  let value;
  try {
    value = JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`${file}: not JSON: ${error.message.split("\n")[0]}`);
  }
  return { ...checkProject(value, file), file, settings: value };
}

export function checkProject(value, name) {
  const bad = (key, reason) => new Error(`${name}: ${key}: ${reason}`);
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name}: must be a JSON object`);
  for (const key of Object.keys(value)) {
    if (!["url", "sizes", "matrix"].includes(key)) {
      throw new Error(`${name}: unknown key "${key}"; the keys are url, sizes and matrix`);
    }
  }
  const project = emptyProject(null);
  if (value.url !== undefined) {
    if (typeof value.url !== "string") throw bad("url", "must be a string");
    try {
      project.url = checkLocalUrl(value.url);
    } catch (error) {
      throw bad("url", error.message);
    }
  }
  if (value.sizes !== undefined) {
    if (value.sizes === null || typeof value.sizes !== "object" || Array.isArray(value.sizes)) throw bad("sizes", "must be an object of sizes by id");
    for (const [id, size] of Object.entries(value.sizes)) project.sizes[id] = checkProjectSize(id, size, bad);
  }
  if (value.matrix !== undefined) project.matrix = checkMatrix(value.matrix, project, bad);
  return project;
}

function checkProjectSize(id, size, bad) {
  const key = `sizes.${id}`;
  if (Object.hasOwn(presets, id)) throw bad(key, `"${id}" is a preset's id`);
  if (id === "window") throw bad(key, `"window" is the Agent Chrome's own size`);
  if (freeSize.test(id)) throw bad(key, `"${id}" is shaped like a free size`);
  if (!/^[^/]+$/.test(id) || id.trim() !== id) throw bad(key, "an id is not empty, holds no \"/\" and has no blank at either end");
  if (size === null || typeof size !== "object" || Array.isArray(size)) throw bad(key, `must be { "width", "height", "scale", "mobile", "touch" } or { "device" }`);
  if (Object.hasOwn(size, "device")) {
    for (const field of Object.keys(size)) if (field !== "device") throw bad(`${key}.${field}`, "a device size takes no other key");
    const device = devices()[size.device];
    if (typeof size.device !== "string" || device === undefined) throw bad(`${key}.device`, `no Playwright device is named ${JSON.stringify(size.device)}`);
    return { ...fromDevice(device), device: size.device };
  }
  for (const field of Object.keys(size)) {
    if (!["width", "height", "scale", "mobile", "touch"].includes(field)) throw bad(`${key}.${field}`, "unknown key; a size takes width, height, scale, mobile and touch, or device alone");
  }
  for (const field of ["width", "height"]) {
    if (!inPixels(size[field])) throw bad(`${key}.${field}`, `${JSON.stringify(size[field])} is not ${pixelRule}`);
  }
  if (size.scale !== undefined && !inScales(size.scale)) throw bad(`${key}.scale`, `${JSON.stringify(size.scale)} is out of range; ${scaleRule}`);
  for (const field of ["mobile", "touch"]) {
    if (size[field] !== undefined && typeof size[field] !== "boolean") throw bad(`${key}.${field}`, "must be true or false");
  }
  return { width: size.width, height: size.height, scale: size.scale ?? 1, mobile: size.mobile ?? false, touch: size.touch ?? false, userAgent: null };
}

function checkMatrix(matrix, project, bad) {
  if (matrix === null || typeof matrix !== "object" || Array.isArray(matrix)) throw bad("matrix", `must be { "engines": [...], "sizes": [...] }`);
  for (const key of Object.keys(matrix)) if (key !== "engines" && key !== "sizes") throw bad(`matrix.${key}`, "unknown key; a matrix takes engines and sizes");
  const checked = { engines: null, sizes: null };
  if (matrix.engines !== undefined) {
    if (!Array.isArray(matrix.engines) || matrix.engines.length === 0) throw bad("matrix.engines", "must be a list of engines");
    for (const engine of matrix.engines) {
      if (!launchedEngines.includes(engine)) throw bad("matrix.engines", `${JSON.stringify(engine)} is not one of ${launchedEngines.join(", ")}, the engines a capture launches`);
    }
    checked.engines = matrix.engines;
  }
  if (matrix.sizes !== undefined) {
    if (!Array.isArray(matrix.sizes) || matrix.sizes.length === 0) throw bad("matrix.sizes", "must be a list of sizes");
    for (const size of matrix.sizes) {
      try {
        if (typeof size !== "string") throw new Error(`${JSON.stringify(size)} is not a size`);
        resolveSize(size, project, "chromium");
      } catch (error) {
        throw bad("matrix.sizes", error.message);
      }
    }
    checked.sizes = matrix.sizes;
  }
  return checked;
}

// The size `text` names, for `engine`: { size, width, height, scale, mobile, touch, userAgent }.
function resolveSize(text, project, engine) {
  if (text === "window") {
    if (engine !== "agent-chrome") throw new Error(`the size "window" is the Agent Chrome's own window, for agent-chrome only, not ${engine}`);
    return { size: "window", width: null, height: null, scale: null, mobile: false, touch: false, userAgent: null };
  }
  if (Object.hasOwn(presets, text)) return { size: text, ...presets[text], userAgent: null };
  if (Object.hasOwn(project?.sizes ?? {}, text)) {
    const { device: _device, ...size } = project.sizes[text];
    return { size: text, ...size };
  }
  const device = devices()[text];
  if (device !== undefined) return { size: text, ...fromDevice(device) };
  const free = freeSize.exec(text);
  if (free === null) {
    throw new Error(`unknown size "${text}"; a size is a preset (${Object.keys(presets).join(", ")}), a project size, a Playwright device name, or <width>x<height>[@<scale>]`);
  }
  const [width, height] = [Number(free[1]), Number(free[2])];
  const scale = free[3] === undefined ? 1 : Number(free[3]);
  if (!inPixels(width) || !inPixels(height)) throw new Error(`the size "${text}" is out of range; width and height are ${pixelRule}`);
  if (!inScales(scale)) throw new Error(`the scale of "${text}" is out of range; ${scaleRule}`);
  return { size: scale === 1 ? `${width}x${height}` : `${width}x${height}@${scale}`, width, height, scale, mobile: false, touch: false, userAgent: null };
}

export function resolveTarget(text, project, base = defaultTarget) {
  if (typeof text !== "string" || text.trim() === "") throw new Error(`a target is <engine>/<size>, an engine or a size, not ${JSON.stringify(text)}`);
  const [baseEngine, baseSize] = splitTarget(base);
  let engine;
  let size;
  if (text.includes("/")) [engine, size] = splitTarget(text);
  else if (engines.includes(text)) [engine, size] = [text, baseSize];
  else [engine, size] = [baseEngine, text];
  if (!engines.includes(engine)) throw new Error(`unknown engine "${engine}" in "${text}"; the engines are ${engines.join(", ")}`);
  // An engine alone keeps the size, but the Agent Chrome's own size has no meaning elsewhere.
  if (size === "window" && engine !== "agent-chrome" && text === engine) size = splitTarget(defaultTarget)[1];
  return { engine, ...resolveSize(size, project, engine) };
}

const splitTarget = (text) => {
  const slash = text.indexOf("/");
  return slash < 0 ? [text, ""] : [text.slice(0, slash), text.slice(slash + 1)];
};

export const targetText = (target) => `${target.engine}/${target.size}`;
export const sizeText = (target) => (target.width === null ? "its own window size" : `${target.width}x${target.height}@${target.scale}`);

export function catalogue(project) {
  const sizes = [];
  for (const [id, size] of Object.entries(presets)) sizes.push({ id, source: "preset", ...size });
  for (const [id, size] of Object.entries(project?.sizes ?? {})) {
    sizes.push({ id, source: size.device ? `project, the device ${size.device}` : "project", width: size.width, height: size.height, scale: size.scale, mobile: size.mobile, touch: size.touch });
  }
  return { engines: [...engines], sizes, devices: Object.keys(devices()).length };
}

export const windowLine = (window) => `${window.engine} ${window.version} at ${window.size} (${sizeText(window)}) on ${window.url}`;

export function targetsText(listing, project) {
  const lines = ["engines:"];
  for (const engine of listing.engines) {
    const capabilities = Object.entries(engine.capabilities).map(([name, value]) => `${name}=${value}`).join(" ");
    const state = engine.available ? "available" : `unavailable: ${engine.reason}`;
    lines.push(`  ${engine.name} ${engine.version ?? "(no version)"}: ${state}; ${capabilities}`);
  }
  // The sizes of the client's own project file, which may differ from the window's.
  const { sizes, devices: count } = catalogue(project);
  lines.push("sizes:");
  for (const size of sizes) {
    const flags = [size.mobile && "mobile", size.touch && "touch"].filter(Boolean).join(", ");
    lines.push(`  ${size.id}: ${size.width}x${size.height}@${size.scale}${flags ? `, ${flags}` : ""} (${size.source})`);
  }
  lines.push(`  any of Playwright's ${count} devices by name, <width>x<height>[@<scale>], and window for agent-chrome`);
  if (listing.current) lines.push(`window: ${listing.current}`);
  return lines.join("\n");
}
