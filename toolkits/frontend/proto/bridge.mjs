// The bridge: the MCP server `proto` of the frontend toolkit's .mcp.json, which Claude Code
// starts over stdio for Daniel's own session as `node ${CLAUDE_PLUGIN_ROOT}/proto/bridge.mjs`.
// A thin client of the prototyping host through client.mjs, it starts the host when none runs,
// so Daniel need not run `proto open` first.
//
// Usage: node bridge.mjs   (no arguments; MCP over stdin and stdout)
//
// Its tools, each answering text, never an image:
//   list_targets                  read-only: the engines with their versions, availability or
//                                 reason, and capabilities, then the sizes, as `proto targets`
//                                 prints them (catalogue.mjs's targetsText)
//   set_target { target, url? }   switches Daniel's window to the target (<engine>/<size>, or an
//                                 engine or a size alone, keeping the other), on its page now or
//                                 at `url`, as `proto set` does, or opens the window there when
//                                 none is open, as `proto open` does; answers the window's one
//                                 line, "<engine> <version> at <size> (<w>x<h>@<scale>) on <url>"
//   capture_matrix { url?, engines?, sizes?, selector?, full_page? }
//                                 the capture of `proto capture`, in headless browsers of the
//                                 host's, never in Daniel's window, into
//                                 <checkout>/.scratch/ui/matrix-<UTC YYYYMMDD-HHMMSS>/ of the git
//                                 checkout of the server's working directory (the session's);
//                                 answers "<target>: <file's absolute path>" or "<target>:
//                                 <error>" per target, then "index: <matrix.md>", and is a tool
//                                 error when no target was captured
// It answers paths rather than images, since a matrix of 15 would pass Claude Code's MCP output
// budget; the session reads the files it needs. The project file is the working directory's
// checkout's .proto.json, sent with every open and capture as the CLI sends it.
// A refusal or a failure is a tool error whose text is one line: the host's own (a bad target,
// a URL off localhost, an unavailable engine), the client's (a host that cannot start, naming
// host.log), or the project file's.
//
// It refuses to start in a team session (AGENT_TEAM_ROLE set), exit 1 with the gate's line on
// stderr, before anything is read, and each tool call checks the gate again before it reaches
// the host. The host's seams (host.mjs's header) pass to the host it starts through its
// environment.
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { refuseTeamSession, teamSessionRefusal } from "./guards.mjs";

refuseTeamSession();

const { readProject, targetsText, windowLine } = await import("./catalogue.mjs");
const { checkout, connect } = await import("./client.mjs");
const { defaultOutDir } = await import("./capture.mjs");
const { serversDir } = await import("./playwright.mjs");

const sdkDir = join(serversDir, "node_modules", "@modelcontextprotocol", "sdk", "dist", "esm");
const sdk = async (path) => import(pathToFileURL(join(sdkDir, path)).href);
const [{ Server }, { StdioServerTransport }, { CallToolRequestSchema, ListToolsRequestSchema }, { AjvJsonSchemaValidator }] = await Promise.all([
  sdk("server/index.js"),
  sdk("server/stdio.js"),
  sdk("types.js"),
  sdk("validation/ajv-provider.js"),
]);

const localOnly = "Only http or https URLs on localhost or 127.0.0.1 are taken; any other is refused before anything opens.";

const projectBody = (settings) => ({ file: settings.file, settings: settings.settings });

// The working directory's checkout and its project file, read at each call, so an edit of
// .proto.json counts at once.
function session() {
  const root = checkout();
  return { root, settings: readProject(root) };
}

class ToolRefusal extends Error {}

const tools = [
  {
    name: "list_targets",
    description: "List the prototyping host's targets: each engine (chromium, firefox, webkit, launched; agent-chrome, Daniel's Agent Chrome, attached) with its version, whether it is available or why not and how to fix it, and what it can do, then every size (the presets, the project's own, any Playwright device by name, <width>x<height>[@<scale>]), and the target Daniel's window shows. It changes nothing on Daniel's screen; it starts the host when none runs. It takes no URL; the host opens only localhost.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    async run() {
      const { settings } = session();
      const host = await connect({ start: true });
      return { text: targetsText(await host.request("GET", "/v1/targets"), settings) };
    },
  },
  {
    name: "set_target",
    description: `Switch Daniel's prototyping window to a target, as the toolbar in it does: this changes what Daniel sees on their screen. Another launched engine reopens the page there with the window's localhost login and closes the old browser (a switch to the Agent Chrome writes no login into it, and a switch away from it detaches rather than closing it); another width and height alone resize the window in place. With no window open it opens one, starting the host when none runs. Answers the window's engine, version, size and URL in one line; a switch that fails leaves the window as it was. ${localOnly}`,
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", description: "<engine>/<size> (webkit/phone, firefox/1024x768, chromium/iPhone 15), or an engine or a size alone, keeping the window's other. Engines: chromium, firefox, webkit, agent-chrome. Sizes: phone-small, phone, tablet, laptop, desktop, the project's own, a Playwright device by its exact name, <width>x<height> or <width>x<height>@<scale>, and window for agent-chrome." },
        url: { type: "string", description: `The page to show; by default the page the window shows now, or the project's URL when no window is open. ${localOnly}` },
      },
      required: ["target"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    async run({ target, url }) {
      const { settings } = session();
      const host = await connect({ start: true });
      const fields = { target, ...(url === undefined ? {} : { url }) };
      const open = () => host.request("POST", "/v1/open", { ...fields, project: projectBody(settings) }, { timeoutMs: 90_000 });
      const { window } = await host.request("GET", "/v1/status");
      if (!window) return { text: windowLine(await open()) };
      try {
        return { text: windowLine(await host.request("POST", "/v1/target", fields, { timeoutMs: 90_000 })) };
      } catch (error) {
        // Daniel closed the window between the two requests.
        if (error.status === 400 && /^no window is open/.test(error.message)) return { text: windowLine(await open()) };
        throw error;
      }
    },
  },
  {
    name: "capture_matrix",
    description: `Capture a page at many targets at once, one PNG per target, each in a headless browser of the prototyping host's own: Daniel's window and screen are not touched, and no toolbar is in the images. Each page carries the window's localhost login. The files go in a new .scratch/ui/matrix-<UTC time>/ of the session's git checkout; answers one line per target with its PNG's absolute path or its error, then the path of matrix.md, the index. Read the PNGs it names to see them. Starts the host when none runs. ${localOnly}`,
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: `The page; by default the page Daniel's window shows, else the project's URL. ${localOnly}` },
        engines: { type: "array", items: { type: "string" }, description: "The engines, of chromium, firefox and webkit (never agent-chrome, Daniel's own window); by default the project's matrix, else all three." },
        sizes: { type: "array", items: { type: "string" }, description: "The sizes, each a preset (phone-small, phone, tablet, laptop, desktop), a project size, a Playwright device by its exact name, or <width>x<height>[@<scale>]; by default the project's matrix, else the five presets." },
        selector: { type: "string", description: "A CSS selector: each image is the first element matching it, once visible (10 s at most), rather than the viewport." },
        full_page: { type: "boolean", description: "Take the whole page, not just the viewport." },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    async run({ url, engines, sizes, selector, full_page: fullPage }) {
      const { root, settings } = session();
      if (root === null) throw new ToolRefusal(`the session's working directory ${process.cwd()} is in no git checkout, so capture_matrix has no .scratch/ui to write in; run \`proto capture --out <an absolute directory>\` there instead`);
      const body = { outDir: defaultOutDir(root), url, engines, sizes, selector, fullPage, project: projectBody(settings) };
      for (const key of Object.keys(body)) if (body[key] === undefined) delete body[key];
      const host = await connect({ start: true });
      const { rows, index } = await host.request("POST", "/v1/capture", body, { timeoutMs: 600_000 });
      const lines = [...rows.map((row) => `${row.target}: ${row.file ?? row.error}`), `index: ${index}`];
      return { text: lines.join("\n"), isError: !rows.some((row) => row.file) };
    },
  },
];

for (const tool of tools) tool.validate = new AjvJsonSchemaValidator().getValidator(tool.inputSchema);

const server = new Server({ name: "proto", version: "1.0.0" }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: tools.map(({ name, description, inputSchema, annotations }) => ({ name, description, inputSchema, annotations })),
}));
server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
  const refuse = (text) => ({ content: [{ type: "text", text }], isError: true });
  const tool = tools.find((each) => each.name === params.name);
  if (!tool) return refuse(`${params.name} is not a tool of proto; its tools are ${tools.map((each) => each.name).join(", ")}`);
  const refusal = teamSessionRefusal();
  if (refusal !== null) return refuse(refusal);
  const input = params.arguments ?? {};
  const checked = tool.validate(input);
  if (!checked.valid) return refuse(`${tool.name} refused its input: ${checked.errorMessage.replace(/\bdata\//g, "").replace(/\bdata\b/g, "the input")}`);
  try {
    const { text, isError = false } = await tool.run(input);
    return { content: [{ type: "text", text }], ...(isError ? { isError } : {}) };
  } catch (error) {
    return refuse(error.message.split("\n")[0]);
  }
});
process.stdin.on("end", () => process.exit(0));
await server.connect(new StdioServerTransport());
