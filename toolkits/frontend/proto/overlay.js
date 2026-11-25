// The prototyping window's overlay (M3): plain DOM in the page, framework-blind, no build step.
// The host adds it as an init script on the window's context (overlay-page.mjs's installOverlay),
// so it is in before the page's own scripts in every engine; it runs in the top frame alone, and
// draws itself only once the host has answered that this page is its window's.
//
//   window.__protoOverlay.update(state)   draws the host's state; the host pushes each change
//                                         with page.evaluate
//   window.__protoOverlay.ready           a promise of the answer to hello: true once the
//                                         toolbar is drawn, false when the host said { show: false }
//
// The binding, window.__protoHost(message) -> answer, which the host adds beside this script:
// every message is { type, ...body }, and the host dispatches on `type`, answering { error } for
// one it does not know, so a later phase's message (phase 2's `selection`) is a new type:
//   hello                        on DOMContentLoaded: { show: false } for a page that is not the
//                                window's (another tab of the context, or the window's page off
//                                localhost), else the state
//   set_target { target }        the state, a switch begun (an engine or a size alone keeps the
//                                other), or { error }
//   reload                       { reloading: true }; the page reloads
//   collapse { collapsed }       the state, the collapsed flag kept by the host across reloads
//                                and switches
// The state: { show: true, engines: [{ name, available, reason }], sizes: [{ id, width, height,
// scale }], current: { engine, size, width, height, scale }, switching, status, collapsed }.
//
// The element: one custom element, <proto-overlay>, appended to document.documentElement, with
// an open shadow root holding its own styles (:host { all: initial !important }, fixed at the
// bottom right, the top z-index; no CSS variable and no rem, which the page's :root would reach),
// so the page's CSS cannot reach it and its CSS cannot reach the page.
// The toolbar, role="toolbar" named "Prototype targets", is built from a list of sections, each a
// function of the state that returns its elements, so phase 2's selection modes and prompt box
// are new sections:
//   target    the "Engine" select (an unavailable engine disabled, "<engine> (unavailable)", its
//             title the reason) and the "Size" select (the presets, the project's sizes, the
//             window's own size when no listed one, "window" on agent-chrome, and "Custom...",
//             which shows "Width", "Height" and "Scale" and "Apply")
//   reload    the "Reload" button
//   collapse  the "Hide toolbar" button; collapsed, the toolbar is one "proto" button that shows
//             it again
//   status    the status line, role="status": what is happening ("Opening <engine> at
//             <size>...", "Blocked <url>: off localhost") or an error's one line; empty when idle
// While a switch runs every control but "Hide toolbar" is disabled.
(() => {
  if (window.top !== window || window.__protoOverlay) return;

  const css = `
    :host {
      all: initial !important;
      position: fixed !important;
      right: 8px !important;
      bottom: 8px !important;
      z-index: 2147483647 !important;
      display: block !important;
      color-scheme: dark !important;
    }
    * { box-sizing: border-box; }
    .bar {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: flex-end;
      row-gap: 4px;
      max-width: min(420px, calc(100vw - 16px));
      padding: 4px;
      border: 1px solid #3c404a;
      border-radius: 6px;
      background: #181a1f;
      color: #e6e7ea;
      font: 12px/16px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
      box-shadow: 0 2px 10px rgba(0, 0, 0, 0.45);
    }
    select, input, button {
      height: 24px;
      margin: 0;
      padding: 0 6px;
      border: 1px solid #4a4f5a;
      border-radius: 4px;
      background: #262930;
      color: #e6e7ea;
      font: 12px/16px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    }
    /* Drawn alike in every engine (WebKit's own select sets its text low and clips it), the
       arrow two gradients rather than an image a page's CSP could refuse. Fixed widths: a
       select is as wide as its widest option, "agent-chrome (unavailable)". */
    select {
      appearance: none;
      padding: 0 18px 0 6px;
      text-overflow: ellipsis;
      white-space: nowrap;
      background-image: linear-gradient(45deg, transparent 50%, #b8bcc4 50%), linear-gradient(135deg, #b8bcc4 50%, transparent 50%);
      background-position: calc(100% - 11px) 50%, calc(100% - 7px) 50%;
      background-size: 4px 4px;
      background-repeat: no-repeat;
    }
    select.engine { width: 88px; }
    select.size { width: 100px; }
    input { width: 60px; }
    input.scale { width: 48px; }
    button { cursor: pointer; }
    button.icon { width: 24px; padding: 0; font-size: 14px; }
    button:hover:not(:disabled), select:hover:not(:disabled) { background: #31353d; }
    :disabled { opacity: 0.5; cursor: default; }
    :focus-visible { outline: 2px solid #78a9ff; outline-offset: 1px; }
    /* Margins, not a column gap: a flex container's max-content counts a gap beside each row's
       item, which would widen the bar by one for each row below the controls. */
    .bar > * + * { margin-left: 4px; }
    .group { display: flex; align-items: center; gap: 4px; }
    /* The custom size's fields: a row of their own under the controls, which stay where they were. */
    .bar > .custom, .bar > .status { margin-left: 0; }
    .custom { order: 1; flex-basis: 100%; justify-content: flex-end; contain: inline-size; }
    /* No intrinsic width of its own, so a long line wraps under the controls, never widening the bar. */
    .status {
      flex-basis: 100%;
      contain: inline-size;
      overflow-wrap: anywhere;
      order: 2;
      color: #c9ccd2;
    }
    /* Kept in the tree when empty, so the live region is there before its first line. */
    .status:empty { height: 0; margin-top: -4px; }
    .collapsed {
      height: 24px;
      padding: 0 8px;
      border: 1px solid #3c404a;
      border-radius: 6px;
      background: #181a1f;
      box-shadow: 0 2px 10px rgba(0, 0, 0, 0.45);
    }
  `;

  // Taken now, before the page's scripts run, so a page that replaces them changes nothing here.
  const createElement = Document.prototype.createElement.bind(document);
  const element = (tag, props = {}, children = []) => {
    const node = createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (value === undefined || value === null || value === false) continue;
      if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else if (key in node && key !== "role") node[key] = value;
      else node.setAttribute(key, value === true ? "" : value);
    }
    node.append(...children);
    return node;
  };

  let state = null;
  let host = null;
  let shadow = null;
  // What the page alone keeps: the custom size being typed, { width, height, scale }, or null.
  const local = { custom: null };
  let markReady;
  const ready = new Promise((resolve) => (markReady = resolve));

  async function send(message) {
    let answer;
    try {
      answer = await window.__protoHost(message);
    } catch (error) {
      answer = { error: String(error?.message ?? error).split("\n")[0] };
    }
    if (answer?.show === true) update(answer);
    else if (answer?.error && state) draw({ ...state, status: answer.error });
    return answer;
  }

  const sizeText = (size) => (size.scale === 1 ? `${size.width}x${size.height}` : `${size.width}x${size.height}@${size.scale}`);

  // Each section: a function of the state, returning its elements.
  const sections = {
    target(view) {
      const busy = view.switching;
      const engine = element("select", {
        "aria-label": "Engine",
        class: "engine",
        title: "Engine",
        disabled: busy,
        onchange: (event) => {
          local.custom = null;
          send({ type: "set_target", target: event.target.value });
        },
      }, view.engines.map((each) => element("option", {
        value: each.name,
        text: each.available ? each.name : `${each.name} (unavailable)`,
        title: each.available ? undefined : each.reason,
        disabled: !each.available,
        selected: each.name === view.current.engine,
      })));
      const listed = [...view.sizes];
      if (view.current.engine === "agent-chrome") listed.push({ id: "window", width: null });
      if (!listed.some((size) => size.id === view.current.size)) listed.push({ id: view.current.size, width: view.current.width, height: view.current.height, scale: view.current.scale });
      const options = listed.map((size) => element("option", {
        value: size.id,
        text: size.id,
        title: size.width === null ? "the window's own size" : sizeText(size),
        selected: local.custom === null && size.id === view.current.size,
      }));
      options.push(element("option", { value: "custom", text: "Custom...", selected: local.custom !== null }));
      const size = element("select", {
        "aria-label": "Size",
        class: "size",
        title: view.current.width === null ? `Size: ${view.current.size}, the window's own` : `Size: ${view.current.size}, ${sizeText(view.current)}`,
        disabled: busy,
        onchange: (event) => {
          if (event.target.value === "custom") {
            const { width, height, scale } = view.current;
            local.custom = { width: width ?? 1280, height: height ?? 800, scale: scale ?? 1 };
            draw(state);
            shadow.querySelector("input")?.focus();
            return;
          }
          local.custom = null;
          send({ type: "set_target", target: `${view.current.engine}/${event.target.value}` });
        },
      }, options);
      const parts = [element("div", { class: "group" }, [engine, size])];
      if (local.custom !== null) {
        const field = (name, key, limits) => element("input", {
          type: "number",
          "aria-label": name,
          title: name,
          class: key,
          disabled: busy,
          value: String(local.custom[key]),
          ...limits,
          oninput: (event) => (local.custom[key] = event.target.value),
        });
        const apply = async () => {
          const { width, height, scale } = local.custom;
          const answer = await send({ type: "set_target", target: `${view.current.engine}/${width}x${height}@${scale}` });
          if (!answer?.error) {
            local.custom = null;
            draw(state);
          }
        };
        parts.push(element("div", { class: "group custom" }, [
          field("Width", "width", { min: "120", max: "7680", step: "1" }),
          field("Height", "height", { min: "120", max: "7680", step: "1" }),
          field("Scale", "scale", { min: "0.5", max: "4", step: "0.25" }),
          element("button", { type: "button", text: "Apply", disabled: busy, onclick: apply }),
        ]));
      }
      return parts;
    },
    reload: (view) => [element("button", {
      type: "button",
      class: "icon",
      "aria-label": "Reload",
      title: "Reload the page",
      text: "↻",
      disabled: view.switching,
      onclick: () => send({ type: "reload" }),
    })],
    collapse: () => [element("button", {
      type: "button",
      class: "icon",
      "aria-label": "Hide toolbar",
      title: "Hide the toolbar",
      text: "−",
      onclick: () => send({ type: "collapse", collapsed: true }),
    })],
    status: (view) => [element("div", { role: "status", class: "status", text: view.status ?? "" })],
  };
  const order = ["target", "reload", "collapse", "status"];

  function draw(view) {
    if (!shadow) {
      host = createElement("proto-overlay");
      shadow = host.attachShadow({ mode: "open" });
    }
    if (!host.isConnected) document.documentElement.append(host);
    const style = element("style", { text: css });
    if (view.collapsed) {
      shadow.replaceChildren(style, element("button", {
        type: "button",
        class: "collapsed",
        title: "Show the prototype targets toolbar",
        text: "proto",
        onclick: () => send({ type: "collapse", collapsed: false }),
      }));
      return;
    }
    const bar = element("div", { role: "toolbar", "aria-label": "Prototype targets", class: "bar" }, order.flatMap((name) => sections[name](view)));
    shadow.replaceChildren(style, bar);
  }

  function update(next) {
    state = next;
    if (!next || next.show !== true) return;
    if (document.documentElement) draw(next);
    else document.addEventListener("DOMContentLoaded", () => draw(state), { once: true });
  }

  async function hello() {
    let answer;
    try {
      answer = await window.__protoHost({ type: "hello" });
    } catch {
      answer = { show: false };
    }
    if (answer?.show === true) update(answer);
    markReady(answer?.show === true);
  }

  if (!customElements.get("proto-overlay")) customElements.define("proto-overlay", class extends HTMLElement {});
  Object.defineProperty(window, "__protoOverlay", {
    value: Object.freeze({ update, ready }),
    configurable: false,
    enumerable: false,
    writable: false,
  });
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", hello, { once: true });
  else hello();
})();
