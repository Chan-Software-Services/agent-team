// The overlay's Playwright side, one for every engine's driver: the init script and the binding
// on a context, the state pushed to a page, and the test seam's acts on a page's toolbar, by role
// and accessible name as Daniel's clicks are.
//
//   await installOverlay(context, ownPage, onMessage)
//                              adds the binding window.__protoHost and then overlay.js as an init
//                              script on `context`, so every page and frame of it has both
//                              before its own scripts (overlay.js itself runs in the top frame
//                              alone); each message is answered by onMessage(message, { own }),
//                              `own` true only for the main frame of ownPage(), the window's page
//                              (null while it is not made yet); a page that is not it is
//                              answered { show: false } to hello by the host
//   pushState(page, state)     window.__protoOverlay.update(state) in `page`; a page between
//                              documents is skipped, its next hello reads the state
//   await toolbarAction(page, { action, name, value })
//                              the test seam's act on the page's toolbar: "select" the option
//                              `value` (its value or its text) of the combobox `name`, "fill" the
//                              spinbutton `name` with `value`, "click" the button `name`, each by
//                              Playwright's role locators inside <proto-overlay>; "read" answers
//                              { drawn, collapsed, status, controls, aria }: each control by its
//                              accessible name, { role, value, disabled } and a combobox's
//                              options [{ value, text, disabled, title }], from Playwright's aria
//                              snapshot of the element, which `aria` holds
//   await popupReport(context, url)
//                              a second page of the window's context opened at `url`, as another
//                              tab sharing it is: { overlay, shown, drawn }, the type of its
//                              window.__protoOverlay, the answer to its hello and its count of
//                              <proto-overlay> elements; then closed
import { fileURLToPath } from "node:url";

export const overlayScript = fileURLToPath(new URL("./overlay.js", import.meta.url));

const actionTimeoutMs = 5_000;
const roles = ["combobox", "spinbutton", "button"];

export async function installOverlay(context, ownPage, onMessage) {
  await context.exposeBinding("__protoHost", async (source, message) => {
    const page = ownPage();
    const own = page !== null && source.page === page && source.frame === page.mainFrame();
    return onMessage ? onMessage(message, { own }) : { show: false };
  });
  await context.addInitScript({ path: overlayScript });
}

export const pushState = (page, state) => page.evaluate((next) => window.__protoOverlay?.update(next), state).catch(() => {});

// The aria snapshot's nodes, depth first.
function* nodes(list) {
  for (const node of Array.isArray(list) ? list : [list]) {
    if (node === null || typeof node !== "object") continue;
    yield node;
    if (node.children) yield* nodes(node.children);
  }
}

async function read(page) {
  const overlay = page.locator("proto-overlay");
  if ((await overlay.count()) === 0) return { drawn: false };
  const aria = await overlay.ariaSnapshotJSON({ timeout: actionTimeoutMs });
  const controls = {};
  let status = null;
  let toolbar = false;
  for (const node of nodes(aria)) {
    if (node.role === "toolbar" && node.name === "Prototype targets") toolbar = true;
    if (node.role === "status") status = [...nodes(node.children ?? [])].filter((each) => each.role === "text").map((each) => each.text).join("") || node.text || null;
    if (!roles.includes(node.role) || !node.name) continue;
    const control = overlay.getByRole(node.role, { name: node.name, exact: true });
    controls[node.name] = await control.evaluate((field, role) => ({
      role,
      value: field.tagName === "BUTTON" ? null : field.value,
      disabled: field.disabled,
      ...(field.tagName === "SELECT"
        ? { options: [...field.options].map((option) => ({ value: option.value, text: option.text, disabled: option.disabled, title: option.title || null })) }
        : {}),
    }), node.role, { timeout: actionTimeoutMs });
  }
  return { drawn: true, collapsed: !toolbar && "proto" in controls, status, controls, aria };
}

export async function toolbarAction(page, { action, name, value }) {
  if (action === "read") return read(page);
  const overlay = page.locator("proto-overlay");
  const options = { timeout: actionTimeoutMs };
  if (action === "select") {
    const select = overlay.getByRole("combobox", { name, exact: true });
    // Its value, else its text, as a click on the option is.
    const values = await select.evaluate((field) => [...field.options].map((option) => [option.value, option.text]), undefined, options);
    const match = values.find(([optionValue]) => optionValue === value) ?? values.find(([, text]) => text === value);
    if (!match) throw new Error(`the ${name} select has no option ${JSON.stringify(value)}`);
    await select.selectOption(match[0], options);
  } else if (action === "fill") {
    await overlay.getByRole("spinbutton", { name, exact: true }).fill(String(value), options);
  } else if (action === "click") {
    await overlay.getByRole("button", { name, exact: true }).click(options);
  }
  return { done: action };
}

export async function popupReport(context, url) {
  const page = await context.newPage();
  try {
    await page.goto(url, { waitUntil: "load", timeout: 30_000 });
    return await page.evaluate(async () => ({
      overlay: typeof window.__protoOverlay,
      shown: window.__protoOverlay ? await window.__protoOverlay.ready : null,
      drawn: document.querySelectorAll("proto-overlay").length,
    }));
  } finally {
    await page.close().catch(() => {});
  }
}
