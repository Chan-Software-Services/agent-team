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
//   const window = await driver.open(url, target, storageState, hooks)
//                              a browser launched headed (headless with `headless`) with one
//                              window in it, as window.reopen makes one; on any failure the
//                              browser is closed and the error thrown
//   hooks                      { onGone(), onBlocked(url), onNavigated(url) }, each optional:
//                              the window's page or browser was closed by someone else (Daniel,
//                              or the test seam), never by window.close(); a main-frame
//                              navigation off localhost was blocked; the main frame navigated
//   window.url()               the page's URL now
//   window.metrics()           what the page reports: innerWidth, innerHeight, devicePixelRatio,
//                              userAgent, cookie and url
//   window.resize(target)      the viewport set to the target's width and height, in place: the
//                              page is not loaded again
//   await window.reopen(url, target, storageState, hooks)
//                              a new window in the same browser: a fresh context at the target
//                              (its viewport, scale, mobile and touch, and a device's user agent)
//                              with the storage state, the localhost guard's route on it, and
//                              its page loaded at `url`; on any failure that context is closed
//                              and the error thrown, this window left as it was
//   await window.storageState()   the context's cookies and localStorage, localhost's alone
//                              (guards.mjs's localStorageState), what a switch carries
//   await window.follow(url)   a link to `url` added to the page and clicked, as a user does,
//                              resolving once the page has loaded there or the guard blocked it
//                              (10 s at most); the test seam's navigate
//   await window.closeBrowser()   the browser closed as Daniel quits it, so hooks.onGone runs
//   window.gone                a promise resolved once the window is closed, by anyone
//   window.close()             closes the window's context, and its browser when no other
//                              context is left in it, its process exited when it resolves
//
// The localhost guard: a route on each context takes every request off localhost (guards.mjs's
// isLocalUrl) and answers a main-frame navigation 204, which leaves the page where it was in
// every engine (an abort shows Chromium's error page in its place), and lets any other request,
// a frame's, a font's or a script's, go on unrouted. A redirect is never routed (Playwright
// routes only a navigation's first request), so a localhost page redirecting off localhost is
// not caught.
// Chromium runs Playwright's "chromium" channel, the full browser headed or headless, so one
// executable serves both and its availability is that file's.
import { existsSync } from "node:fs";
import { dirname } from "node:path";
import { isLocalUrl, localStorageState } from "./guards.mjs";
import { pinnedBrowsers, playwright } from "./playwright.mjs";
import { checkWebkitLibs, lacksLine } from "./webkit-libs.mjs";

const loadTimeoutMs = 30_000;
const followTimeoutMs = 10_000;

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
    async open(url, target, storageState, hooks) {
      const browser = await type().launch({ headless, timeout: loadTimeoutMs, ...(name === "chromium" ? { channel: "chromium" } : {}) });
      try {
        return await openWindow(browser, url, target, storageState, hooks);
      } catch (error) {
        await browser.close().catch(() => {});
        throw error;
      }
    },
  };
}

async function openWindow(browser, url, target, storageState, hooks = {}) {
  const context = await browser.newContext({
    viewport: { width: target.width, height: target.height },
    deviceScaleFactor: target.scale,
    isMobile: target.mobile,
    hasTouch: target.touch,
    ...(target.userAgent ? { userAgent: target.userAgent } : {}),
    ...(storageState ? { storageState } : {}),
  });
  const blockedWaiters = new Set();
  try {
    await context.route((address) => !isLocalUrl(address.href), async (route) => {
      const request = route.request();
      let mainFrame = false;
      try {
        mainFrame = request.isNavigationRequest() && request.frame().parentFrame() === null;
      } catch {
        // A service worker's request has no frame.
      }
      if (!mainFrame) return route.continue();
      hooks.onBlocked?.(request.url());
      for (const resolve of blockedWaiters) resolve(request.url());
      return route.fulfill({ status: 204 });
    });
    const page = await context.newPage();
    await page.goto(url, { waitUntil: "load", timeout: loadTimeoutMs });
    return makeWindow(browser, context, page, hooks, blockedWaiters);
  } catch (error) {
    await context.close().catch(() => {});
    throw error;
  }
}

function makeWindow(browser, context, page, hooks, blockedWaiters) {
  let closed = null;
  let markGone;
  const gone = new Promise((resolve) => (markGone = resolve));
  const close = () => {
    closed ??= (async () => {
      browser.off("disconnected", lost);
      await context.close().catch(() => {});
      if (browser.isConnected() && browser.contexts().length === 0) await browser.close().catch(() => {});
      markGone();
    })();
    return closed;
  };
  // Closed by someone else: the host is told, and what is left of the window is closed.
  const lost = () => {
    if (closed) return;
    hooks.onGone?.();
    close();
  };
  page.on("close", lost);
  browser.on("disconnected", lost);
  page.on("framenavigated", (frame) => {
    if (frame === page.mainFrame()) hooks.onNavigated?.(frame.url());
  });
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
    resize: (target) => page.setViewportSize({ width: target.width, height: target.height }),
    reopen: (url, target, storageState, newHooks) => openWindow(browser, url, target, storageState, newHooks),
    storageState: async () => localStorageState(await context.storageState()),
    async follow(url) {
      const href = new URL(url).href;
      let onBlocked;
      let wasBlocked = false;
      const blocked = new Promise((resolve) => {
        onBlocked = (address) => {
          wasBlocked = true;
          resolve(address);
        };
        blockedWaiters.add(onBlocked);
      });
      const link = await page.evaluateHandle((to) => {
        const anchor = document.createElement("a");
        anchor.href = to;
        anchor.textContent = "proto test link";
        anchor.style.cssText = "position: fixed; left: 0; top: 0; z-index: 2147483647; background: white; padding: 4px";
        document.body.append(anchor);
        return anchor;
      }, href);
      try {
        const loaded = page.waitForURL((address) => address.href === href, { waitUntil: "load", timeout: followTimeoutMs });
        // Still waiting when the guard blocks it, so its later timeout is nobody's error.
        loaded.catch(() => {});
        try {
          await link.asElement().click();
        } catch (error) {
          // The click waits for the navigation it starts, which a block ends as aborted.
          if (!wasBlocked) throw error;
        }
        // A blocked navigation fails the wait for its URL too.
        await Promise.race([blocked, loaded.catch((error) => {
          if (!wasBlocked) throw error;
        })]);
      } finally {
        blockedWaiters.delete(onBlocked);
        await link.evaluate((anchor) => anchor.remove()).catch(() => {});
        await link.dispose().catch(() => {});
      }
    },
    async closeBrowser() {
      await browser.close();
      await gone;
    },
    gone,
    close,
  };
}
