# frontend

Front-end fixes on the element Daniel points at, and a look at the page Daniel is on: Daniel right-clicks an element in the Agent Chrome and picks Inspect, and the agent gets its HTML, matched CSS, Vue source file and line, and screenshot, with a capture of the page it is on; with nothing selected, the agent gets that page capture alone.
A page capture holds the page's URL, route, title and Vue route, a screenshot, its accessibility snapshot, and its console problems and failed requests since it last loaded.
For Daniel's own Claude Code session, and for the coordinator's intake of a fix sent from Discord; workers read the coordinator's capture, never the Agent Chrome, and `team-worker` refuses them the toolkit.
The one exception, by Daniel's decision (D1 of T216's report, 2026-11-04), which narrows their 2026-10-29 one: an interview's planner, while its task's walk is on in its own thread, takes a capture of the page Daniel is on, read-only, and Daniel alone drives the window.

## Use it

At the laptop, in Conventioner's checkout:

1. Start the dev server as usual, then the Agent Chrome once per login: `~/agent-team/toolkits/frontend/scripts/agent-chrome` (or `agent-chrome http://localhost:<port>/<path>` for another page), and log in there with a fixture account.
2. Start the session with the toolkit: `claude --plugin-dir ~/agent-team/toolkits/frontend`.
3. For each fix: right-click the element in the Agent Chrome, pick Inspect, and type the fix, for example "the selected element: give it the same height as Import responses".
   The skill captures the element, opens its `.vue` file at the line and makes the change; the dev server reloads it in the Agent Chrome.
   With nothing selected, the capture holds only the page, so the skill asks Daniel to inspect the element rather than guess.

The capture takes the page Daniel is on: the page with an element selected, else a page with DevTools open, else the visible localhost tab, else the most recently active one ("What it runs" says how).

From Discord, the coordinator's `ui-intake` skill captures with `team-ui T<n> --capture` when Daniel asks it to check, look at or capture the page, or sends a fix about the inspected element; Daniel turns a task's manual QC walk on and off by saying so in its thread, which the coordinator records with `team-ui T<n> --walk start|stop`, and while it is on the coordinator captures the page with each message Daniel posts there.
A walk in an interview thread (`team-ui T<n> --walk start --in interview`, on Daniel's word) leaves the coordinator out: its planner, on the `planner-walk` brief, captures and answers there.

## What it can see

- The Agent Chrome only: a Chrome window with its own profile (`~/.local/share/agent-team/agent-chrome`), started by `scripts/agent-chrome` with remote debugging on `127.0.0.1:9222`.
  Daniel's everyday Chrome, with its mail and any production tab, is a different browser that nothing here attaches to.
- Its `http://localhost:*` and `http://127.0.0.1:*` pages only: the server runs with an allowlist of those two and DevTools' own frontend (`devtools://devtools/*`, where the Elements panel's selection is read), so any other tab is neither listed nor read, and a navigation elsewhere is refused.
- Use it for the local dev site with fixture data, logged in with a fixture account.
  Never open production or real applicant data there: anything a capture holds can end up in a Discord thread or a task directory, and remote debugging on port 9222 lets any local process drive that window.
- No worker session takes a capture but one: `team-ui` refuses every form to a worker, which is the guard, since a worker's `team-post` can send an image off the machine, except `team-ui T<n> --capture` by a planner of T<n> while that task's walk is on in its interview thread, one such walk at a time (`team-ui T<n> --walk start --in interview`, which the coordinator runs on Daniel's word).
  That planner gets the capture alone: `team-worker` still refuses it this toolkit, so no worker has the MCP server's navigate, click and type tools.
  `ui-capture` holds a worker session to the same gate (`capture_refusal` in `bin/lib/team.sh`) when it is run directly, which guards that script alone, since any local process can reach the port.
  `settings/worker.json` also denies a Bash call naming that port (`:9222`, `port 9222`, `port=9222`) or `CHROME_DEVTOOLS_AXI_BROWSER_URL`, and its `bin/hooks/command-guard` refuses `ui-capture` run by its path or by an interpreter (`bash`, `sh`, `node`, `source`, `.`): speed bumps that another spelling gets past.
- Google's usage statistics, CrUX lookups and the server's update checks are off.
- The Agent Chrome runs with the mock keychain and the basic password store, so it never reads or adds a "Chrome Safe Storage" item in Daniel's login keychain, and no keychain prompt appears for a Chrome a test starts.
- A capture's files stay on the machine that took it: Daniel's session writes it to `.scratch/ui` in its checkout (git-ignored, and outside a task's `.scratch/task/`, which archives carry; an archive leaves out a `ui/` there anyway, and every image anywhere in it), and the coordinator's intake (`team-ui`) to the team home's `tasks/T<n>/ui/`, which the team home's git ignores, so no checkpoint or handoff carries it; `team-close` removes it with the task, and `team-doctor`'s `captures` line reports one left behind.
  A walk's planner posts `page.png` and `element.png` of a capture, and never its text, in its interview thread, under `team-post`'s guards (`bin/team-post`'s header): the page must be on the task's own stack, or on the one port named by Daniel's word, at the walk's start, that the primary was just reseeded, so `localhost` alone never clears one.

## What it runs

- `scripts/agent-chrome [--port <port>] [<url>]`: starts the Agent Chrome at the dev server (default `http://localhost:5173`), or says one already answers on the port.
- `scripts/ui-capture [--browser-url <url>] <out-dir>`: writes a page capture of the localhost page of the Agent Chrome that Daniel is on, and an element capture too when an element is selected in DevTools' Elements panel there.
  The page capture is `<out-dir>/ui-page.md` (the page's URL, route and title, why that page was taken, the other localhost tabs, the Vue route's matched records with their components and files, or "(no Vue router found)", and the page's console problems and failed requests since it last loaded), `page.png` (the viewport) and `page-snapshot.txt` (the page's accessibility snapshot).
  The element capture adds `ui-pick.md` (page, route, a pointer to `ui-page.md` for the page's state, snapshot line, the `vite-plugin-vue-inspector` source chain such as `src/views/LoginView.vue:369:11`, the component chain, its HTML and every matched CSS rule) and `element.png`, and `ui-page.md` lists them under its files.
  With nothing selected, it writes the page capture alone and exits 0.
  The page is, the first that applies: the localhost page with an element selected, "the selected element's page"; else a localhost page with DevTools open and nothing selected (DevTools' default `<body>`, or `<html>`); else the visible localhost tab, among several windows the one whose document has focus, else the most recently active; else, when no localhost tab is visible, the most recently active localhost tab.
  A capture of a tab that is not visible has no `page.png`, nor `element.png` (an element inspected before Daniel brought another tab to the front), and its `ui-page.md` and `ui-pick.md` say so: Chrome paints no hidden tab, so a screenshot of one never comes, and bringing the tab to the front would change what Daniel sees.
  Recency is the order of Chrome's `/json/list`, most recently active first.
  Visibility and focus are read before the server selects any page, over one short DevTools protocol session per localhost tab that evaluates `document.visibilityState` and `document.hasFocus()` and nothing else: the pinned server (1.12.0) turns on focus emulation for each page it selects, under which every page reads visible and focused, so its `evaluate_script` cannot tell (checked on Chrome 156, 2026-11-03).
  The console problems are the console's errors, warnings and failed asserts, uncaught exceptions, unhandled rejections and the browser's own errors and warnings; the failed requests are those that ended in a status of 400 or more or a network error; each section lists them in order, the last 50, one line each trimmed to 500 characters inside a fence longer than any backtick run in them.
  They include what happened before `ui-capture` started, which the server cannot give: it is started anew for each capture, and its `list_console_messages` and `list_network_requests` report nothing from before it attached (checked on the pinned 1.12.0, 2026-11-03).
  So `ui-capture` opens one more short DevTools protocol session of its own, on the chosen localhost page alone, whose `Runtime.enable` and `Log.enable` replay every stored console call, exception and browser log entry since the page's last load before they answer, then sends `Runtime.disable` and `Log.disable` and closes.
  It cannot see a request still pending or any request's method, a reload starts the history anew, and with no session or no answer in 10 s the capture is still written, its two sections saying the history could not be read and why.
  Those two short sessions, the visibility read and this one, are the only times it speaks the protocol to a page without the server, and neither changes the page.
  No tab off localhost is ever attached to, by the server or by either read.
  While another session's `frontend` server (Daniel's own, say) has a page selected, that page too reads visible.
  It owns those five file names in `<out-dir>`: a capture removes the ones it did not write, so no file of an earlier capture is left beside it, and a failed capture writes and removes nothing.
  It fails in one line, exit 1, when no Agent Chrome answers, the Agent Chrome has no localhost page open, the selected element carries no Vue source data (a production build), the server never attached to a tab Chrome has open, or a page does not answer within 30 s; the last two name a busy machine as a cause.
  Each script's header is its `--help`.
- The MCP server `frontend` (`.mcp.json`): the same pinned server with the same flags, so the agent can look again after a capture (`take_snapshot`, `take_screenshot`, `get_css_styles` and the rest of Chrome DevTools MCP's tools).
  Its path uses `${CLAUDE_PLUGIN_ROOT}`, which Claude Code fills in for `--plugin-dir` and not under `team-worker`'s `--mcp-config`.
  The toolkit is not for workers: every session with it shares Daniel's one Agent Chrome window, so `team-worker --toolkit frontend` is refused as a usage error, for every role and for the load check, and workers read captures instead, a walk's planner taking its own with `team-ui --capture`.
- The skill `fixing-the-selected-element` (`skills/`): when Daniel's message is about the selected element, capture it, read the capture, fix the `.vue` file it names and capture again to check.
- All of them speak to the pinned `chrome-devtools-mcp` in `servers/` (installed by `servers/install`, checked by `team-doctor`'s `servers` line).

## Prototype targets

The prototyping host opens Daniel's dev site in a window of Chromium, Firefox or WebKit (Playwright's pinned builds, from `playwright-core` in `servers/`), at a named size or any free size, so a layout is checked in each engine and at a phone's width without starting a browser by hand.
It is one long-lived local process per user, started by the first `scripts/proto open` and kept until `proto stop`, which owns the browsers and Daniel's one prototyping window.
It is for Daniel's own sessions alone: the CLI and the host refuse a team session (`AGENT_TEAM_ROLE` set) before they read anything.

At the laptop, in the project's checkout, with its dev server running:

1. Once per machine, and after each Playwright bump: `~/agent-team/toolkits/frontend/scripts/proto install`, which fetches the pinned browsers into Playwright's cache (`~/.cache/ms-playwright`) with `playwright-core`'s own installer, never with `--with-deps` and never under sudo.
2. `proto open` opens the project's URL in Chromium at `laptop`; `proto open http://localhost:5173/login --target firefox/phone` opens that page in Firefox at 390x844, scale 3, mobile and touch.
   With a window open, another `proto open` moves it: it opens the new URL and target, then closes the old window, which stays as it was when the new one fails.
   An engine or a size alone keeps the other (`--target webkit`, `--target tablet`).
3. `proto status` says whether the host runs, and which target and URL the window shows; `proto targets` lists the engines, each with its version, availability or the reason it is unavailable with its fix, and capabilities, then the sizes; `proto stop` closes the window and ends the host, leaving no socket or token.

A target is `<engine>/<size>`:

- the engines are `chromium`, `firefox`, `webkit` (launched) and `agent-chrome` (Daniel's Agent Chrome, attached);
- a size is a preset, `phone-small` 360x800@3, `phone` 390x844@3, `tablet` 768x1024@2 (each mobile and touch), `laptop` 1440x900 and `desktop` 1920x1080 (`ui-check`'s two design widths); a Playwright device by its exact name (`chromium/iPhone 15`), with its viewport, scale, mobile and touch flags and user agent; a free size `<width>x<height>` or `<width>x<height>@<scale>`, whole pixels from 120 to 7680 and a scale from 0.5 to 4; or `window`, the Agent Chrome's own size, for `agent-chrome` alone.

A project may set its dev site's URL and extra sizes in `.proto.json` at the root of its git checkout, JSON with only these keys: `url`, the start URL (default `http://localhost:5173/`); `sizes`, extra sizes by id, each `{ "width", "height", "scale", "mobile", "touch" }` (the last three optional) or `{ "device": "<Playwright device name>" }`, an id never a preset's, `window` or shaped like a free size; and `matrix`, `{ "engines": [...], "sizes": [...] }`, a capture's defaults.
A mistake in it is refused with one line naming the file, the key and the reason.

The guards:

- Only `http` or `https` on `localhost` or `127.0.0.1`, any port, is opened; any other URL a command gives is refused before anything opens.
- The host listens on a Unix socket in its runtime directory, `$XDG_RUNTIME_DIR/agent-team-proto`, else `~/.local/state/agent-team/proto`, which is mode 0700 and refused, naming it, when it is open to others; the socket and the token beside it are mode 0600, and every request carries that token, minted at each start, or is answered 401.
- A host started from older code answers another protocol number, and every command names it with its fix (`proto stop`, then retry); a host that crashed leaves a stale socket, which the next `proto open` replaces with a new host, though its browser may outlive it until Daniel closes it.
- `host.log` in the runtime directory holds the host's output, truncated at each start.

## Tests

`tests/run toolkits` runs `tests/toolkits/frontend.test.mjs`: a headless Chrome stands in for the Agent Chrome, a local fixture page shaped like Conventioner's dev build stands in for the app, and the test opens DevTools and selects an element in the Elements panel exactly as a click there does (`tests/toolkits/helpers/chrome.mjs`).
That Chrome runs off the record, so no page waits for a fresh profile's cookie database, and a Chrome too old for `open_devtools` fails the test at once.
It checks each capture (the element with its page's capture, on a tab in front and on one no longer in front, and the page with nothing selected, with a Vue router and without, with DevTools open and closed, and which tab is taken as tabs are brought to the front), the page's console problems and failed requests from before the capture, kept to the last 50 and fenced, the commands `ui-capture` sends a page over its own sessions (through a relay of the debugging address), the history it cannot read, and each refusal, that a page off localhost is never read or attached to, that the MCP server `.mcp.json` declares lists localhost pages only and sees the selection, and that `agent-chrome` starts Chrome with its own profile and port.

It also checks that a worker session running `ui-capture` directly meets the gate before anything reads a Chrome.

The bats suite checks the coordinator's side with `ui-capture` stubbed: `tests/team-ui.bats` that each capture gets a directory of its own with its kind and Daniel's note, that a failed one leaves none, that a walk turns on and off in the ledger, and who may capture during one, `tests/team-brief.bats` that the briefs name each capture with a note or an element and count the others, and what the walk's brief says, and `tests/team-state.bats` that a walk that is on shows.

`tests/toolkits/proto-host.test.mjs` runs the prototyping host through `scripts/proto` as Daniel does, headless (`PROTO_HEADLESS=1`), in a runtime directory of each test's own, against fixture pages on 127.0.0.1 (`tests/toolkits/helpers/proto.mjs`): a window in each engine at a preset, a device and a free size, read back from the page itself, moved by a second open in the same host, and every refusal and failure above.
It runs every engine the machine has; CI's `toolkits` job installs all three with their system libraries, and there a missing engine fails rather than skips.
The host's seams, read only from the environment, are in `proto/host.mjs`'s header.

`evals/` holds the skill's eval cases (`claude plugin eval ~/agent-team/toolkits/frontend`): it fires on a fix about the selected element and leaves a general front-end question alone.
Every `frontend` call there is answered by an agent mock of a Conventioner page (`evals/mocks/frontend/_server.md`), whose `_tools.json` is the server's own `tools/list`, which the toolkit test keeps in step.
Results go to `evals/results/`, which is gitignored.
