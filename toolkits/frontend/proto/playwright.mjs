// The pinned playwright-core, loaded from servers/node_modules (installed by servers/install),
// for the catalogue, the engine drivers and the CLI.
//
//   serversDir            the code checkout's servers/
//   playwright()          playwright-core's exports ({ chromium, firefox, webkit, devices }),
//                         loaded on the first call, so the host sets PLAYWRIGHT_BROWSERS_PATH
//                         first (Playwright reads it once, as it loads); throws a one-line reason
//                         naming servers/install when it is not installed
//   pinnedBrowsers()      playwright-core's browsers.json: each browser's revision and version
//   installerPath         playwright-core's own installer, cli.js
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const serversDir = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "servers");
const packageDir = join(serversDir, "node_modules", "playwright-core");
export const installerPath = join(packageDir, "cli.js");

let loaded;
export function playwright() {
  if (loaded) return loaded;
  try {
    loaded = createRequire(import.meta.url)(packageDir);
  } catch (error) {
    if (error.code !== "MODULE_NOT_FOUND") throw error;
    throw new Error(`playwright-core is not installed in ${serversDir}; run ${join(serversDir, "install")}`);
  }
  return loaded;
}

let browsers;
export function pinnedBrowsers() {
  browsers ??= JSON.parse(readFileSync(join(packageDir, "browsers.json"), "utf8")).browsers;
  return browsers;
}
