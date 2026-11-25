// The engine driver for the launched engines, chromium, firefox and webkit: one code path over
// Playwright's three browser types, each its pinned build in Playwright's browsers path (its
// default cache, or PLAYWRIGHT_BROWSERS_PATH, which the host sets from PROTO_BROWSERS_PATH).
//
//   const driver = launchedDriver("firefox", { headless });
//   driver.name, driver.capabilities    the engine, and what it can do: sizeBy "context",
//                              overlayBeforePageScripts true, matchedRules "cdp" (chromium) or
//                              "stylesheet-walk" (firefox, webkit), navigationGuard true
//   driver.version()           the pinned build's version (playwright-core's browsers.json)
//   driver.available()         { available: true }, or { available: false, reason } when the
//                              pinned build's executable is missing, or, for WebKit on Linux, when
//                              webkit-libs.mjs's check names a soname it lacks (run at every
//                              reading), each naming `proto install`
//   const window = await driver.open(url, target, storageState)
//                              a browser launched headed (headless with `headless`) with one
//                              context at the target (its viewport, scale, mobile and touch, and
//                              a device's user agent) and the storage state, its page loaded at
//                              `url`; on any failure the browser is closed and the error thrown
//   window.url()               the page's URL now
//   window.metrics()           what the page reports: innerWidth, innerHeight, devicePixelRatio,
//                              userAgent, cookie and url
//   window.close()             closes the browser, its process exited when it resolves
//
// Chromium runs Playwright's "chromium" channel, the full browser headed or headless, so one
// executable serves both and its availability is that file's.
import { existsSync } from "node:fs";
import { dirname } from "node:path";
import { pinnedBrowsers, playwright } from "./playwright.mjs";
import { checkWebkitLibs, lacksLine } from "./webkit-libs.mjs";

const loadTimeoutMs = 30_000;

export const firstLine = (error) => String(error?.message ?? error).split("\n")[0].replace(/^\w+\.\w+: /, "");

export function launchedDriver(name, { headless = false } = {}) {
  const type = () => playwright()[name];
  const version = () => pinnedBrowsers().find((browser) => browser.name === name).browserVersion;
  return {
    name,
    capabilities: {
      sizeBy: "context",
      overlayBeforePageScripts: true,
      matchedRules: name === "chromium" ? "cdp" : "stylesheet-walk",
      navigationGuard: true,
    },
    version,
    available() {
      const path = type().executablePath();
      if (!existsSync(path)) return { available: false, reason: `${name} ${version()} is not installed (no ${path}); run \`proto install\`` };
      if (name !== "webkit") return { available: true };
      // Every time: Playwright checks the libraries once per revision, so one lost later would show
      // only as a loader error at launch.
      try {
        const missing = checkWebkitLibs(dirname(path));
        return missing.length ? { available: false, reason: lacksLine(version(), missing) } : { available: true };
      } catch (error) {
        return { available: false, reason: error.message };
      }
    },
    async open(url, target, storageState) {
      const browser = await type().launch({ headless, timeout: loadTimeoutMs, ...(name === "chromium" ? { channel: "chromium" } : {}) });
      try {
        const context = await browser.newContext({
          viewport: { width: target.width, height: target.height },
          deviceScaleFactor: target.scale,
          isMobile: target.mobile,
          hasTouch: target.touch,
          ...(target.userAgent ? { userAgent: target.userAgent } : {}),
          ...(storageState ? { storageState } : {}),
        });
        const page = await context.newPage();
        await page.goto(url, { waitUntil: "load", timeout: loadTimeoutMs });
        return {
          url: () => page.url(),
          metrics: () => page.evaluate(() => ({
            innerWidth,
            innerHeight,
            devicePixelRatio,
            userAgent: navigator.userAgent,
            cookie: document.cookie,
            url: location.href,
          })),
          close: () => browser.close(),
        };
      } catch (error) {
        await browser.close().catch(() => {});
        throw error;
      }
    },
  };
}
