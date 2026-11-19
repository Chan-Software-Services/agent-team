// A preload (node --require) that forces the race a server picking a port and then binding it can
// lose: the first time any process started with it binds an HTTP server to a port it names, a
// listener of its own takes that port on the same host first, as another server of the run landing
// on it between the pick and the bind would, so the bind fails with EADDRINUSE.
//
//   NODE_OPTIONS="--require <this file>" TAKE_PORT_ONCE=<path> <command>
//
// TAKE_PORT_ONCE names a file that does not exist yet: the process that creates it takes the
// port, and every process started after it, which finds the file, binds as it would have, so a
// retry of the same command after the loss shows what a second attempt does.
// Vite's dev server picks its port in a probe of plain net servers and binds its HTTP server after
// them, so only an HTTP server's bind to a named port is raced, never a probe or a bind to port 0.
"use strict";
const { closeSync, openSync } = require("node:fs");
const http = require("node:http");
const net = require("node:net");

const marker = process.env.TAKE_PORT_ONCE;
const listen = net.Server.prototype.listen;
let armed = false;
if (marker) {
  try {
    closeSync(openSync(marker, "wx"));
    armed = true;
  } catch {}
}

net.Server.prototype.listen = function (...args) {
  const [port, host] = args;
  if (!armed || !(this instanceof http.Server) || typeof port !== "number" || port === 0) return listen.apply(this, args);
  armed = false;
  const taker = net.createServer();
  taker.unref();
  listen.call(taker, port, host, () => listen.apply(this, args));
  return this;
};
