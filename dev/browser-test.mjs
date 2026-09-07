#!/usr/bin/env node
// Real Chromium probes over CDP pipe, with no package dependencies.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile, mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = new Set(process.argv.slice(2));
if ([...args].some(arg => !["--hidden", "--help"].includes(arg))) {
  console.error("usage: node dev/browser-test.mjs [--hidden]");
  process.exit(64);
}
if (args.has("--help")) {
  console.log("usage: node dev/browser-test.mjs [--hidden]");
  console.log("Build browser/model.bc.js first. Default runs quick real-browser probes.");
  console.log("--hidden also hides the page for 306 seconds before nested Worker spawn.");
  console.log("CHROME_BIN may select a Chromium binary; no throttling flags are disabled.");
  process.exit(0);
}

const delay = ms => new Promise(done => setTimeout(done, ms));
const browserErrors = [];
let profile;
let chrome;
let server;
let cdp;
let chromeExit;
let stderr = "";

function connect(process) {
  let sequence = 0;
  let buffer = "";
  const pending = new Map();
  const events = new Set();
  let closed = false;
  function stop(reason) {
    if (closed) return;
    closed = true;
    for (const { reject, timer } of pending.values()) {
      clearTimeout(timer);
      reject(new Error(reason));
    }
    pending.clear();
  }
  process.stdio[4].setEncoding("utf8");
  process.stdio[4].on("data", data => {
    buffer += data;
    for (;;) {
      const end = buffer.indexOf("\0");
      if (end < 0) break;
      const frame = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      if (!frame) continue;
      let message;
      try { message = JSON.parse(frame); }
      catch (error) { stop(`invalid CDP response: ${error.message}`); return; }
      if (message.id) {
        const call = pending.get(message.id);
        if (!call) continue;
        pending.delete(message.id);
        clearTimeout(call.timer);
        if (message.error) call.reject(new Error(JSON.stringify(message.error)));
        else call.resolve(message.result);
      } else {
        for (const event of events) event(message);
      }
    }
  });
  process.stdio[3].on("error", error => stop(`CDP pipe: ${error.message}`));
  process.stdio[4].on("error", error => stop(`CDP pipe: ${error.message}`));
  process.on("exit", (code, signal) => stop(`Chrome exited: code=${code} signal=${signal}`));
  process.on("error", error => stop(`Chrome could not start: ${error.message}`));
  return {
    onEvent: callback => events.add(callback),
    send(method, params = {}, sessionId) {
      if (closed) return Promise.reject(new Error("CDP connection closed"));
      const id = ++sequence;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }, 30000);
        pending.set(id, { resolve, reject, timer });
        const message = { id, method, params };
        if (sessionId) message.sessionId = sessionId;
        process.stdio[3].write(`${JSON.stringify(message)}\0`);
      });
    },
    close: () => stop("browser test finished")
  };
}

async function evaluate(session, expression) {
  const result = await cdp.send("Runtime.evaluate", {
    expression, returnByValue: true, awaitPromise: false
  }, session);
  if (result.exceptionDetails) {
    throw new Error(`browser evaluation: ${result.exceptionDetails.text}`);
  }
  return result.result.value;
}

async function outcome(session, expression) {
  const evaluated = await cdp.send("Runtime.evaluate", {
    expression, returnByValue: true, awaitPromise: true
  }, session);
  if (evaluated.exceptionDetails) throw new Error(`browser promise: ${evaluated.exceptionDetails.text}`);
  const result = evaluated.result.value;
  if (!result?.ok) throw new Error(`production host outcome: ${JSON.stringify(result)}`);
  return result.value;
}

async function poll(session, expression, timeoutMs = 120000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (browserErrors.length) throw new Error(browserErrors.join("\n"));
    const value = await evaluate(session, expression);
    if (value) return value;
    await delay(100);
  }
  throw new Error(`browser probe timed out after ${timeoutMs}ms`);
}

async function page(url) {
  const target = await cdp.send("Target.createTarget", { url: "about:blank" });
  const attached = await cdp.send("Target.attachToTarget", { targetId: target.targetId, flatten: true });
  const session = attached.sessionId;
  await cdp.send("Runtime.enable", {}, session);
  await cdp.send("Log.enable", {}, session);
  await cdp.send("Page.enable", {}, session);
  if (url !== "about:blank") await cdp.send("Page.navigate", { url }, session);
  return { session, target: target.targetId };
}

async function runProbe(session, method, timeoutMs = 120000) {
  await evaluate(session, `KiteBrowserTests.${method}(); true`);
  const result = await poll(session, "KiteBrowserTests.result", timeoutMs);
  for (const line of result.lines) console.log(line);
  if (!result.ok) throw new Error(result.error || "browser probe failed");
}

async function productionProbe(origin) {
  const cluster = `probe-${Date.now()}`;
  const tabs = [];
  const views = () => Promise.all(tabs.map(tab => outcome(tab.session, "kite.request('view')")));
  async function converge(predicate, label) {
    const deadline = Date.now() + 25000;
    let observed;
    while (Date.now() < deadline) {
      if (browserErrors.length) throw new Error(browserErrors.join("\n"));
      observed = await views();
      for (const view of observed) {
        if (view.error) throw new Error(`production host error: ${view.error}`);
      }
      if (predicate(observed)) return observed;
      await delay(150);
    }
    throw new Error(`${label} did not converge: ${JSON.stringify(observed)}`);
  }
  const running = view => view.node.workers.filter(worker => worker.phase === "running");
  const working = (view, worker) => view.ticks.some(tick => tick.pod === worker.pod && tick.ticket === worker.ticket);
  try {
    for (const node of ["nodeA", "nodeB"]) {
      const tab = await page(`${origin}/browser/index.html?cluster=${cluster}&node=${node}`);
      tabs.push(tab);
      await poll(tab.session, "typeof kite !== 'undefined' && !!kite.ready", 10000);
      await outcome(tab.session, "kite.ready");
    }
    await converge(states => states.every(state => state.node.nodeLock) &&
      states.some(state => state.leaderEpoch > 0 &&
        new Set(state.log?.entries.filter(entry => entry.payload.kind === "heartbeat")
          .map(entry => entry.payload.nodeId)).size === 2), "two registered nodes");
    await outcome(tabs[0].session, "kite.request('desired', {count: 2})");
    const settled = await converge(states => states.every(state => running(state).length === 1 &&
      running(state).every(worker => working(state, worker))) &&
      new Set(states.flatMap(state => running(state).map(worker => worker.pod))).size === 2,
    "two running pod owners with work");
    console.log("PASS production-two-tab-desired-placement-and-work");
    const frozenIndex = settled.findIndex(state => state.leaderEpoch > 0);
    if (frozenIndex < 0) throw new Error("missing leader before freeze");
    const survivorIndex = 1 - frozenIndex;
    const incarnation = settled[frozenIndex].node.incarnation;
    const oldEpoch = settled[frozenIndex].leaderEpoch;
    await outcome(tabs[frozenIndex].session, "kite.request('freeze')");
    await converge(states => states[frozenIndex].node.mode === "frozen" &&
      !states[frozenIndex].node.nodeLock && states[frozenIndex].node.workers.length === 0 &&
      states[survivorIndex].leaderEpoch > oldEpoch && running(states[survivorIndex]).length === 2 &&
      running(states[survivorIndex]).every(worker => working(states[survivorIndex], worker)),
    "leader freeze, lock release and survivor takeover");
    console.log("PASS production-leader-freeze-pod-replacement-and-epoch-takeover");
    await outcome(tabs[frozenIndex].session, "kite.request('resume')");
    await converge(states => states[frozenIndex].node.mode === "ready" &&
      states[frozenIndex].node.nodeLock && states[frozenIndex].node.incarnation > incarnation,
    "resume acquires new node incarnation");
    console.log("PASS production-resume-fresh-incarnation");
  } finally {
    for (const tab of tabs) {
      try { await outcome(tab.session, "kite.request('close')"); }
      finally { await cdp.send("Target.closeTarget", { targetId: tab.target }); }
    }
  }
}

async function tabCloseProbe(origin, observer) {
  const name = `kite-tab-interruption-${Date.now()}`;
  const lockName = `${name}:leader`;
  let writer;
  let interrupted = 0;
  let committed = 0;
  let attempts = 0;
  let recovery;
  await outcome(observer.session, `KiteBrowserTests.setupTabInterruption(${JSON.stringify(name)})`);
  try {
    for (; attempts < 5 && interrupted === 0; attempts += 1) {
      writer = await page(`${origin}/test/browser.html?writer=1`);
      await poll(writer.session, "typeof KiteBrowserTests !== 'undefined'", 10000);
      await outcome(writer.session,
        `KiteBrowserTests.prepareTabWriter(${JSON.stringify(name)}, ${JSON.stringify(lockName)})`);
      const before = await outcome(observer.session,
        `KiteBrowserTests.queueTabSuccessor(${JSON.stringify(lockName)})`);
      const marker = await outcome(writer.session, `KiteBrowserTests.startTabWrite(${before.epoch})`);
      if (marker.kind !== "append-issued" || marker.bytes !== 32 * 1024 * 1024) {
        throw new Error("writer tab did not acknowledge transaction initiation");
      }
      const closed = await cdp.send("Target.closeTarget", { targetId: writer.target });
      if (!closed.success) throw new Error("CDP did not close writer tab");
      writer = null;
      const result = await poll(observer.session, "KiteBrowserTests.tabResult", 30000);
      if (!result.ok) throw new Error(`tab-close recovery: ${result.error}`);
      recovery = result.value;
      if (recovery.interrupted) interrupted += 1;
      else committed += 1;
    }
    if (interrupted === 0) throw new Error("PR-4 tab closure requires observed interruption; all attempts committed");
    console.log(`PR-4 mode=tab-close close=Target.closeTarget independent_observer=true transaction_started_before_close=true marker=append-returned writes_queued_before_close=unobserved attempts=${attempts} interrupted=${interrupted} committed=${committed} lock_handoff=true claim_before_observer_read=true atomic_prefix=${recovery.atomicPrefix} recovery_epoch=${recovery.epoch} stale_append=${recovery.staleAppend}`);
    console.log("PASS idb-writer-tab-close-lock-handoff-and-fenced-recovery");
  } finally {
    if (writer) await cdp.send("Target.closeTarget", { targetId: writer.target });
    await outcome(observer.session, "KiteBrowserTests.finishTabInterruption()");
  }
}

async function cleanup() {
  cdp?.close();
  if (chrome && chrome.exitCode === null && chrome.signalCode === null) {
    chrome.kill("SIGTERM");
    await Promise.race([chromeExit, delay(3000)]);
    if (chrome.exitCode === null && chrome.signalCode === null) {
      chrome.kill("SIGKILL");
      await chromeExit;
    }
  }
  if (server) {
    server.closeAllConnections();
    await new Promise(done => server.close(done));
  }
  if (profile) await rm(profile, { recursive: true, force: true });
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    cleanup().finally(() => process.exit(signal === "SIGINT" ? 130 : 143));
  });
}

try {
  await stat(join(root, "_build/default/browser/model.bc.js"));
  server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
      if (pathname === "/favicon.ico") { response.writeHead(204).end(); return; }
      const path = resolve(root, `.${pathname}`);
      if (!path.startsWith(`${root}${sep}`)) { response.writeHead(403).end(); return; }
      const body = await readFile(path);
      const type = { ".js": "text/javascript", ".mjs": "text/javascript", ".html": "text/html", ".css": "text/css" }[extname(path)] || "application/octet-stream";
      response.writeHead(200, { "Content-Type": type, "Cache-Control": "no-store" });
      response.end(body);
    } catch (error) {
      response.writeHead(error.code === "ENOENT" ? 404 : 500).end();
    }
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  profile = await mkdtemp(join(tmpdir(), "kite-browser-"));
  const executable = process.env.CHROME_BIN || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  chrome = spawn(executable, [
    "--headless=new", "--remote-debugging-pipe", `--user-data-dir=${profile}`,
    "--no-first-run", "--no-default-browser-check", "about:blank"
  ], { stdio: ["ignore", "ignore", "pipe", "pipe", "pipe"] });
  chromeExit = new Promise(done => { chrome.once("exit", done); chrome.once("error", done); });
  chrome.stderr.setEncoding("utf8");
  chrome.stderr.on("data", data => { stderr = (stderr + data).slice(-12000); });
  cdp = connect(chrome);
  cdp.onEvent(event => {
    if (event.method === "Runtime.exceptionThrown") {
      const detail = event.params.exceptionDetails;
      browserErrors.push(`uncaught browser error: ${detail.exception?.description || detail.text}`);
    }
    if (event.method === "Runtime.consoleAPICalled" && event.params.type === "error") {
      browserErrors.push(`browser console error: ${event.params.args.map(arg => arg.value || arg.description).join(" ")}`);
    }
    if (event.method === "Log.entryAdded" && event.params.entry.level === "error") {
      browserErrors.push(`browser log error: ${event.params.entry.text}`);
    }
  });
  const version = await cdp.send("Browser.getVersion");
  console.log(`BROWSER ${version.product} revision=${version.revision} mode=headless`);
  const testPage = await page(`${origin}/test/browser.html`);
  await cdp.send("Page.bringToFront", {}, testPage.session);
  await poll(testPage.session, "typeof KiteBrowserTests !== 'undefined'", 30000);
  await runProbe(testPage.session, "run");
  await tabCloseProbe(origin, testPage);
  await productionProbe(origin);
  if (args.has("--hidden")) {
    await cdp.send("Page.bringToFront", {}, testPage.session);
    const foreground = await page("about:blank");
    await cdp.send("Page.bringToFront", {}, foreground.session);
    await poll(testPage.session, "document.hidden", 5000);
    console.log("PR-2 background page verified hidden, waiting 306 seconds without throttling overrides");
    let nextProgress = Date.now() + 60000;
    for (;;) {
      const visibility = await evaluate(testPage.session, "KiteBrowserTests.visibility()");
      if (!visibility.hidden) throw new Error("PR-2 page became visible during hidden aging");
      if (visibility.hiddenForMs >= 306000) break;
      if (Date.now() >= nextProgress) {
        console.log(`PR-2 hidden_age_ms=${Math.round(visibility.hiddenForMs)}`);
        nextProgress = Date.now() + 60000;
      }
      await delay(Math.min(1000, 306000 - visibility.hiddenForMs));
    }
    await runProbe(testPage.session, "runHidden", 90000);
  }
  const errors = await evaluate(testPage.session, "kiteBrowserErrors");
  if (browserErrors.length || errors.length) throw new Error([...browserErrors, ...errors].join("\n"));
  console.log("BROWSER-OK");
} catch (error) {
  console.error(`BROWSER-FAIL ${error.stack || error}`);
  if (stderr) console.error(`Chrome stderr tail:\n${stderr}`);
  process.exitCode = 1;
} finally {
  await cleanup();
}
