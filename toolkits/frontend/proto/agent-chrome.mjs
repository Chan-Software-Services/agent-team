// The engine driver for the Agent Chrome, Daniel's own window (toolkits/frontend/scripts/
// agent-chrome), which the host attaches to and never starts, at PROTO_AGENT_CHROME_URL (default
// http://127.0.0.1:9222, where agent-chrome starts it). The same operations as launched.mjs's
// driver, so the host switches between them alike.
//
//   const driver = agentChromeDriver({ address })
//   driver.name, driver.capabilities    "agent-chrome", and what it can do: sizeBy "emulation",
//                              overlayBeforePageScripts true (the host's tab is opened after the
//                              init script is added), matchedRules "cdp", navigationGuard false
//                              (Daniel's own window: no route is put on it)
//   await driver.available()   { available: true } once GET <address>/json/version answers within
//                              2 s, else { available: false, reason }, naming the address and the
//                              agent-chrome script
//   driver.version()           the Chrome's version, from /json/version's Browser at the last
//                              reading of available(), or null before one answered
//   const window = await driver.open(url, target, storageState, hooks)
//                              attached over the DevTools protocol (Playwright's connectOverCDP,
//                              with noDefaults, so the Chrome's downloads, focus and media are left
//                              at its own settings), the overlay's binding and init script added to the Chrome's default
//                              context, then the host's own tab opened (the one it opened before,
//                              when it is still open, else a new one) at the target's size, loaded
//                              at `url` and brought to the front. The storage state is never
//                              written into the Agent Chrome. On a failure a tab it opened is
//                              closed and it detaches; a reused tab stays
//   hooks                      as launched.mjs's, but for onBlocked, which never runs here
//   window.url(), metrics(), reload(), push(state), toolbar(body), popup(url), send(message),
//   follow(url), gone          as launched.mjs's window's; follow has no guard to meet
//   window.resize(target)      the emulation set to the target, the page not loaded again
//   await window.reopen(url, target, storageState, hooks)
//                              the same tab, at the target's size and at `url` (loaded again only
//                              when it differs), as a new window answering to `hooks`, which this
//                              one hands its tab to: this window's close() then leaves the tab
//                              alone. On a failure the tab is put back at this window's size and
//                              URL, and this window keeps it
//   await window.storageState()   the Chrome's cookies of localhost and 127.0.0.1 and the host's
//                              tab's localStorage when it is on localhost, what a switch away
//                              carries; read from the tab and the cookie store alone, no page
//                              opened for it
//   await window.closeBrowser()   the Chrome quit (Browser.close), as Daniel quits it
//   window.close()             detaches, leaving the Chrome as it was: the overlay's element
//                              removed from the host's tab, the size emulation cleared, the
//                              host's protocol session closed and the connection closed; the tab
//                              stays open at its page, and its next load has no overlay or binding
//
// A size is applied by one DevTools protocol session of the host's on its tab:
// Emulation.setDeviceMetricsOverride (width, height, scale and the mobile flag) and
// Emulation.setTouchEmulationEnabled; `window` clears both, and a device's user agent is not
// applied. No other tab is navigated, sized or closed: the binding and the init script reach the
// context's other tabs, where the overlay asks the host and is told not to show itself.
import { localStorageState, isLocalUrl } from "./guards.mjs";
import { installOverlay, popupReport, pushState, toolbarAction } from "./overlay-page.mjs";
import { playwright } from "./playwright.mjs";

export const defaultAgentChromeUrl = "http://127.0.0.1:9222";
const answerTimeoutMs = 2_000;
const loadTimeoutMs = 30_000;
const followTimeoutMs = 10_000;

export function agentChromeDriver({ address = defaultAgentChromeUrl } = {}) {
  const where = new URL(address).host;
  const unavailable = { available: false, reason: `no Agent Chrome answers on ${where}; start it with \`toolkits/frontend/scripts/agent-chrome\`` };
  let version = null;
  // The host's tab, by its target id, kept across detaches so a later switch reuses it.
  let tabId = null;
  return {
    name: "agent-chrome",
    capabilities: { sizeBy: "emulation", overlayBeforePageScripts: true, matchedRules: "cdp", navigationGuard: false },
    version: () => version,
    async available() {
      try {
        const response = await fetch(new URL("/json/version", address), { signal: AbortSignal.timeout(answerTimeoutMs) });
        if (!response.ok) return unavailable;
        const { Browser: browser } = await response.json();
        version = typeof browser === "string" && browser.includes("/") ? browser.slice(browser.indexOf("/") + 1) : browser ?? null;
        return { available: true };
      } catch {
        return unavailable;
      }
    },
    async open(url, target, _storageState, hooks = {}) {
      // noDefaults: Playwright's overrides of an attached default context (its downloads into
      // Playwright's own directory, focus emulation, the colour scheme and other media) stay off
      // Daniel's window.
      const browser = await playwright().chromium.connectOverCDP(address, { timeout: loadTimeoutMs, noDefaults: true });
      let page = null;
      let opened = false;
      const [context] = browser.contexts();
      const tab = { browser, context, page: null, session: null, owner: null };
      try {
        await installOverlay(context, () => tab.page, (message, info) => tab.owner?.hooks.onMessage?.(message, info) ?? { show: false });
        page = await findTab(context, tabId);
        if (!page) {
          page = await context.newPage();
          opened = true;
        }
        const session = await context.newCDPSession(page);
        Object.assign(tab, { page, session });
        tabId = (await session.send("Target.getTargetInfo")).targetInfo.targetId;
        await emulate(session, target);
        const handle = makeWindow(tab, hooks, target);
        tab.owner = handle;
        watch(tab);
        await page.goto(url, { waitUntil: "load", timeout: loadTimeoutMs });
        await page.bringToFront();
        return handle;
      } catch (error) {
        if (opened) await page.close().catch(() => {});
        else if (page) await clear(page, tab.session);
        await browser.close().catch(() => {});
        throw error;
      }
    },
  };
}

// The tab whose target id is `id` among the context's pages, or null.
async function findTab(context, id) {
  if (id === null) return null;
  for (const page of context.pages()) {
    const session = await context.newCDPSession(page).catch(() => null);
    if (!session) continue;
    try {
      if ((await session.send("Target.getTargetInfo")).targetInfo.targetId === id) return page;
    } catch {
      // A tab closing as it is asked.
    } finally {
      await session.detach().catch(() => {});
    }
  }
  return null;
}

async function emulate(session, target) {
  if (target.width === null) {
    await session.send("Emulation.clearDeviceMetricsOverride");
    await session.send("Emulation.setTouchEmulationEnabled", { enabled: false });
    return;
  }
  await session.send("Emulation.setDeviceMetricsOverride", { width: target.width, height: target.height, deviceScaleFactor: target.scale, mobile: target.mobile });
  await session.send("Emulation.setTouchEmulationEnabled", target.touch ? { enabled: true, maxTouchPoints: 5 } : { enabled: false });
}

// The overlay's element removed from the tab, and the emulation cleared on `session`.
async function clear(page, session) {
  await page.evaluate(() => {
    for (const element of document.querySelectorAll("proto-overlay")) element.remove();
  }).catch(() => {});
  if (session) {
    await session.send("Emulation.clearDeviceMetricsOverride").catch(() => {});
    await session.send("Emulation.setTouchEmulationEnabled", { enabled: false }).catch(() => {});
  }
}

// The tab's and the Chrome's ends, told to whichever window holds the tab now.
function watch(tab) {
  const lost = () => tab.owner?.lost();
  tab.page.on("close", lost);
  tab.browser.on("disconnected", lost);
  tab.page.on("framenavigated", (frame) => {
    if (frame === tab.page.mainFrame()) tab.owner?.hooks.onNavigated?.(frame.url());
  });
}

function makeWindow(tab, hooks, target) {
  const { browser, context, page, session } = tab;
  let closed = null;
  let markGone;
  const gone = new Promise((resolve) => (markGone = resolve));
  const handle = {
    hooks,
    target,
    // Closed by someone else, the tab or the Chrome: the host is told, and the window let go.
    lost() {
      if (closed) return;
      hooks.onGone?.();
      handle.close();
    },
    url: () => page.url(),
    metrics: () => page.evaluate(() => ({
      innerWidth,
      innerHeight,
      devicePixelRatio,
      maxTouchPoints: navigator.maxTouchPoints,
      userAgent: navigator.userAgent,
      cookie: document.cookie,
      url: location.href,
    })),
    async resize(next) {
      await emulate(session, next);
      handle.target = next;
    },
    reload: () => page.reload({ waitUntil: "load", timeout: loadTimeoutMs }),
    push: (state) => pushState(page, state),
    toolbar: (body) => toolbarAction(page, body),
    popup: (url) => popupReport(context, url),
    send: (message) => page.evaluate((sent) => window.__protoHost(sent), message),
    async reopen(url, next, _storageState, newHooks) {
      const from = page.url();
      const reopened = makeWindow(tab, newHooks, next);
      tab.owner = reopened;
      try {
        await emulate(session, next);
        if (url !== from) await page.goto(url, { waitUntil: "load", timeout: loadTimeoutMs });
        return reopened;
      } catch (error) {
        tab.owner = handle;
        reopened.handOver();
        await emulate(session, handle.target).catch(() => {});
        if (page.url() !== from) await page.goto(from, { waitUntil: "load", timeout: loadTimeoutMs }).catch(() => {});
        throw error;
      }
    },
    async storageState() {
      const origins = [];
      if (isLocalUrl(page.url())) {
        const localStorage = await page.evaluate(() => Object.entries(window.localStorage).map(([name, value]) => ({ name, value })));
        origins.push({ origin: new URL(page.url()).origin, localStorage });
      }
      return localStorageState({ cookies: await context.cookies(), origins });
    },
    async follow(url) {
      const href = new URL(url).href;
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
        await link.asElement().click();
        await loaded;
      } finally {
        await link.dispose().catch(() => {});
      }
    },
    async closeBrowser() {
      const control = await browser.newBrowserCDPSession();
      await control.send("Browser.close").catch(() => {});
      await gone;
    },
    gone,
    // Let go of the tab without detaching: another window holds it now.
    handOver() {
      closed ??= Promise.resolve();
      markGone();
    },
    close() {
      closed ??= (async () => {
        if (tab.owner === handle) {
          tab.owner = null;
          await clear(page, session);
          await session.detach().catch(() => {});
          await browser.close().catch(() => {});
        }
        markGone();
      })();
      return closed;
    },
  };
  return handle;
}
