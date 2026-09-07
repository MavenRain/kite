#!/usr/bin/env node
// M1 acceptance driver. Browser operations remain real CDP and host requests.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile, mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const delay = ms => new Promise(done => setTimeout(done, ms));
// A thrown value may refuse every conversion, so the name is fixed then.
const named = error => {
  try { return String(error?.message || error); }
  catch (refused) { return "host_error"; }
};
const required = ["registry", "fifo-election", "least-loaded-placement",
  "leader-death-failover", "duplicate-rejection", "hidden-tab-operation"];

function connect(child) {
  let sequence = 0;
  let buffer = "";
  let closed = false;
  const pending = new Map();
  const events = new Set();
  function stop(reason) {
    if (closed) return;
    closed = true;
    for (const call of pending.values()) {
      clearTimeout(call.timer);
      call.reject(new Error(reason));
    }
    pending.clear();
  }
  child.stdio[4].setEncoding("utf8");
  child.stdio[4].on("data", data => {
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
  for (const pipe of [child.stdio[3], child.stdio[4]]) {
    pipe.on("error", error => stop(`CDP pipe: ${error.message}`));
  }
  child.on("exit", (code, signal) => stop(`Chrome exited: code=${code} signal=${signal}`));
  child.on("error", error => stop(`Chrome could not start: ${error.message}`));
  return {
    onEvent: callback => events.add(callback),
    send(method, params = {}, sessionId) {
      if (closed) return Promise.reject(new Error("CDP connection closed"));
      const id = ++sequence;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`CDP timeout: ${method} session=${sessionId || 'browser'} expression=${String(params.expression || '').slice(0, 180)}`));
        }, 30000);
        pending.set(id, {resolve, reject, timer, method, sessionId, startedAt: Date.now()});
        const message = {id, method, params};
        if (sessionId) message.sessionId = sessionId;
        child.stdio[3].write(`${JSON.stringify(message)}\0`);
      });
    },
    pending: () => [...pending.values()].map(call => ({method: call.method,
      session: call.sessionId, elapsedMs: Date.now() - call.startedAt})),
    close: () => stop("acceptance driver finished")
  };
}

export async function withBrowser(run, {quick = false} = {}) {
  const errors = [];
  const tabs = new Map();
  const passed = new Set();
  const cluster = `m1c-${Date.now()}`;
  let profile;
  let chrome;
  let chromeExit;
  let server;
  let cdp;
  let foreground;
  let stderr = "";
  let progress;
  let lastCall;
  let cleanupPromise;
  const startedAt = Date.now();
  const checkErrors = () => {
    if (errors.length) throw new Error(errors.join("\n"));
  };
  const cleanup = () => cleanupPromise ||= (async () => {
    clearInterval(progress);
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
    if (profile) await rm(profile, {recursive: true, force: true});
  })();
  const signals = new Map(["SIGINT", "SIGTERM"].map(signal => [signal, () => {
    cleanup().finally(() => process.exit(signal === "SIGINT" ? 130 : 143));
  }]));
  for (const [signal, handler] of signals) process.once(signal, handler);

  async function evaluate(session, expression, awaitPromise = true) {
    checkErrors();
    const result = await cdp.send("Runtime.evaluate", {
      expression, returnByValue: true, awaitPromise
    }, session);
    if (result.exceptionDetails) {
      throw new Error(`browser evaluation: ${result.exceptionDetails.exception?.description || result.exceptionDetails.text}`);
    }
    checkErrors();
    return result.result.value;
  }
  async function outcome(session, expression) {
    const result = await evaluate(session, expression);
    if (!result?.ok) throw new Error(`production host outcome: ${JSON.stringify(result)}`);
    return result.value;
  }
  async function poll(action, predicate, label, timeoutMs = 25000) {
    const deadline = Date.now() + timeoutMs;
    let value;
    do {
      checkErrors();
      value = await action();
      if (await predicate(value)) return value;
      await delay(50);
    } while (Date.now() < deadline);
    throw new Error(`${label} timed out: ${JSON.stringify(value)}`);
  }
  async function page(url, observeVisibility = false) {
    const target = await cdp.send("Target.createTarget", {url: "about:blank"});
    const attached = await cdp.send("Target.attachToTarget", {targetId: target.targetId, flatten: true});
    const session = attached.sessionId;
    await cdp.send("Runtime.enable", {}, session);
    await cdp.send("Log.enable", {}, session);
    await cdp.send("Page.enable", {}, session);
    if (observeVisibility) {
      await cdp.send("Page.addScriptToEvaluateOnNewDocument", {source: `
        globalThis.kiteAcceptanceVisibility = {hiddenSince: document.hidden ? Date.now() : null,
          changes: 0};
        document.addEventListener('visibilitychange', () => {
          kiteAcceptanceVisibility.hiddenSince = document.hidden ? Date.now() : null;
          kiteAcceptanceVisibility.changes += 1;
        });
      `}, session);
    }
    if (url !== "about:blank") await cdp.send("Page.navigate", {url}, session);
    return {session, target: target.targetId};
  }
  const tabFor = node => {
    const tab = tabs.get(node);
    if (!tab) throw new Error(`unknown cluster node: ${node}`);
    return tab;
  };
  let hiddenChange;
  const trackHidden = view => {
    if (!hiddenChange) return;
    const {count, startedAt} = hiddenChange;
    for (const tick of view.ticks || []) {
      if (tick.at >= startedAt && tick.pod < count && tick.value === -1734620768 &&
          view.node.workers.some(worker => worker.phase === "running" &&
            worker.pod === tick.pod && worker.ticket === tick.ticket &&
            worker.incarnation === tick.incarnation)) {
        hiddenChange.workMs = Math.min(hiddenChange.workMs, tick.at - startedAt);
      }
    }
    const snapshot = view.planning?.snapshot;
    const pods = Array.from({length: count}, (_, pod) => pod);
    if (view.leaderEpoch > 0 && snapshot?.epoch === view.leaderEpoch &&
        snapshot.desired === count && view.planning.plan?.ok &&
        view.planning.plan.commands.length === 0 &&
        snapshot.podLocks.length === count && snapshot.placements.length === count &&
        pods.every(pod => snapshot.podLocks.filter(held => held === pod).length === 1 &&
          snapshot.placements.filter(place => place.pod === pod &&
            hiddenChange.nodes.includes(place.owner)).length === 1)) {
      hiddenChange.convergedMs = Math.min(hiddenChange.convergedMs, Date.now() - startedAt);
    }
  };
  const host = {
    cluster,
    async open(node) {
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(node) || tabs.has(node)) {
        throw new Error(`invalid or already open node: ${node}`);
      }
      const origin = `http://127.0.0.1:${server.address().port}`;
      const tab = await page(`${origin}/browser/index.html?cluster=${cluster}&node=${node}`, true);
      tabs.set(node, tab);
      await poll(() => evaluate(tab.session, "typeof kite !== 'undefined' && !!kite.ready", false),
        Boolean, `node ${node} page ready`, 10000);
      await outcome(tab.session, "kite.ready");
      return host.view(node);
    },
    async close(node) {
      const tab = tabFor(node);
      // Destruction must exercise browser lock release, without a graceful close request.
      const result = await cdp.send("Target.closeTarget", {targetId: tab.target});
      if (!result.success) throw new Error(`Chrome refused to close ${node}`);
      tabs.delete(node);
      return {closed: true};
    },
    async desired(node, count) {
      const ages = await host.hiddenAges();
      const result = await evaluate(tabFor(node).session, `(async () => {
        const startedAt = Date.now();
        const reply = await kite.request('desired', {count: ${JSON.stringify(count)}});
        return {...reply, startedAt, committedAt: Date.now()};
      })()`);
      if (!result?.ok) throw new Error(`desired request failed: ${JSON.stringify(result)}`);
      const changed = {...result.value, startedAt: result.startedAt, committedAt: result.committedAt};
      if (count > 0 && ages.length === 2 && ages.every(age => age.hidden && age.hiddenForMs >= 306000)) {
        hiddenChange = {...changed, count, ages, nodes: ages.map(age => age.node),
          workMs: Infinity, convergedMs: Infinity};
      }
      return changed;
    },
    async view(node) {
      const value = await outcome(tabFor(node).session, "kite.request('view')");
      if (value.error) throw new Error(`node ${node}: ${value.error}`);
      trackHidden(value);
      return value;
    },
    views: () => Promise.all([...tabs.keys()].map(node => host.view(node))),
    locks: () => evaluate(foreground.session, "KiteAcceptance.locks()"),
    async pending() {
      const locks = await host.locks();
      return locks.pending.filter(name => name === `kite:${cluster}:leader`).length;
    },
    async duplicate(node, pod) {
      const before = await host.views();
      const loser = before.find(view => view.node.nodeId === node);
      const owners = before.filter(view => view.node.workers.some(worker =>
        worker.pod === pod && worker.phase === "running"));
      if (!loser || owners.length !== 1 || owners[0].node.nodeId === node) {
        throw new Error("duplicate probe requires one existing owner and a different target node");
      }
      const original = owners[0].node.workers.find(worker => worker.pod === pod);
      const previousCount = loser.duplicateRefusals?.count ?? 0;
      const command = {kind: "start", pod, owner: node, incarnation: loser.node.incarnation};
      const appended = await outcome(foreground.session,
        `KiteAcceptance.append(${JSON.stringify(cluster)}, ${JSON.stringify(command)})`);
      const views = await poll(host.views, states => {
        const target = states.find(view => view.node.nodeId === node);
        const refusal = target?.duplicateRefusals;
        if (!(target?.cursor >= appended.seq && refusal?.count > previousCount &&
            refusal.last?.pod === pod && refusal.last.incarnation === loser.node.incarnation &&
            refusal.last.exited)) return false;
        if (target.node.workers.some(worker => worker.pod === pod) ||
            target.ticks.some(tick => tick.pod === pod && tick.ticket === refusal.last.ticket)) {
          throw new Error("duplicate loser remained alive or performed payload work");
        }
        const liveOwners = states.filter(view => view.node.workers.some(worker =>
          worker.pod === pod && worker.phase === "running"));
        return liveOwners.length === 1 && liveOwners[0].node.nodeId === owners[0].node.nodeId &&
          liveOwners[0].node.workers.some(worker => worker.pod === pod && worker.ticket === original.ticket);
      }, "duplicate refusal and observed worker exit");
      const after = views.find(view => view.node.nodeId === node);
      const locks = await host.locks();
      if (locks.held.filter(name => name === `kite:${cluster}:pod:${pod}`).length !== 1) {
        throw new Error("duplicate probe did not retain exactly one pod lock");
      }
      return {replayedSeq: after.cursor, appendedSeq: appended.seq,
        owner: owners[0].node.nodeId, refusal: after.duplicateRefusals.last,
        refusalCount: after.duplicateRefusals.count, soleOwner: true, loserWorked: false};
    },
    async hide() {
      await cdp.send("Page.bringToFront", {}, foreground.session);
      return poll(host.hiddenAges, ages => ages.length > 0 && ages.every(age => age.hidden),
        "all cluster tabs hidden", 5000);
    },
    hiddenAges: () => Promise.all([...tabs].map(async ([node, tab]) => ({node,
      ...await evaluate(tab.session, `({hidden: document.hidden,
        hiddenForMs: document.hidden && kiteAcceptanceVisibility.hiddenSince !== null ?
          Date.now() - kiteAcceptanceVisibility.hiddenSince : 0,
        changes: kiteAcceptanceVisibility.changes})`, false)}))),
    async wait(ms) {
      if (!Number.isFinite(ms) || ms < 0 || ms > 360000) throw new Error("invalid wait duration");
      const until = Date.now() + ms;
      while (Date.now() < until) {
        checkErrors();
        await delay(Math.min(1000, until - Date.now()));
      }
      checkErrors();
      return true;
    },
    assert(condition, label) {
      if (condition !== true) throw new Error(`acceptance assertion failed: ${label}`);
      return true;
    },
    async report(label, value = null) {
      if (!required.includes(label)) throw new Error(`unknown acceptance behavior: ${label}`);
      if (label === "hidden-tab-operation") {
        const ages = await host.hiddenAges();
        if (!hiddenChange || ages.length !== 2 || !ages.every(age => age.hidden && age.hiddenForMs >= 306000) ||
            !(hiddenChange.workMs <= 3000 && hiddenChange.convergedMs <= 5000)) {
          throw new Error(`hidden timing gate failed: ${JSON.stringify(hiddenChange)}`);
        }
        value = {...value, hiddenAgeMs: hiddenChange.ages.map(age => Math.round(age.hiddenForMs)),
          workMs: hiddenChange.workMs, leaderViewMs: hiddenChange.convergedMs};
      }
      passed.add(label);
      console.log(`PASS M1 ${label} ${JSON.stringify(value)}`);
      return true;
    }
  };
  host.runPage = async (expression, dispatch) => {
    if (typeof dispatch !== "function") throw new Error("source dispatch function required");
    await evaluate(foreground.session, expression, false);
    const deadline = Date.now() + 600000;
    while (Date.now() < deadline) {
      const state = await evaluate(foreground.session,
        "({calls: KiteAcceptance.take(), result: KiteAcceptance.result})", false);
      for (const call of state.calls) {
        lastCall = {name: call.name, argument: call.argument, startedAt: Date.now()};
        if (["host_open", "host_close", "host_hide"].includes(call.name)) {
          console.log(`M1 operation ${call.name} argument=${JSON.stringify(call.argument)}`);
        }
        let reply;
        try { reply = {ok: true, value: await dispatch(call.name, call.argument)}; }
        catch (error) { reply = {ok: false, error: named(error)}; }
        lastCall = {...lastCall, elapsedMs: Date.now() - lastCall.startedAt, ok: reply.ok,
          ...(reply.ok ? {} : {error: reply.error})};
        if (!reply.ok || (lastCall.elapsedMs >= 2000 && call.name !== "host_wait")) {
          console.log(`M1 operation-result ${JSON.stringify(lastCall)}`);
        }
        await evaluate(foreground.session,
          `KiteAcceptance.settle(${call.id}, ${JSON.stringify(reply)})`, false);
      }
      if (state.result) {
        if (!state.result.ok) throw new Error(`source execution: ${state.result.error}`);
        return state.result.value;
      }
      await delay(10);
    }
    throw new Error("source acceptance timed out after ten minutes");
  };

  try {
    await stat(join(root, "_build/default/browser/model.bc.js"));
    await stat(join(root, "_build/default/browser/program.bc.js"));
    await stat(join(root, "test/acceptance.kite.js"));
    server = createServer(async (request, response) => {
      try {
        const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
        if (pathname === "/favicon.ico") { response.writeHead(204).end(); return; }
        const path = resolve(root, `.${pathname}`);
        if (!path.startsWith(`${root}${sep}`)) { response.writeHead(403).end(); return; }
        const body = await readFile(path);
        const type = {".js": "text/javascript", ".mjs": "text/javascript",
          ".html": "text/html", ".css": "text/css"}[extname(path)] || "application/octet-stream";
        response.writeHead(200, {"Content-Type": type, "Cache-Control": "no-store"});
        response.end(body);
      } catch (error) {
        response.writeHead(error.code === "ENOENT" ? 404 : 500).end();
      }
    });
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    profile = await mkdtemp(join(tmpdir(), "kite-m1-acceptance-"));
    chrome = spawn(process.env.CHROME_BIN || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
      "--headless=new", "--remote-debugging-pipe", `--user-data-dir=${profile}`,
      "--no-first-run", "--no-default-browser-check", "about:blank"
    ], {stdio: ["ignore", "ignore", "pipe", "pipe", "pipe"]});
    chromeExit = new Promise(done => { chrome.once("exit", done); chrome.once("error", done); });
    chrome.stderr.setEncoding("utf8");
    chrome.stderr.on("data", data => { stderr = (stderr + data).slice(-12000); });
    cdp = connect(chrome);
    cdp.onEvent(event => {
      if (event.method === "Runtime.exceptionThrown") {
        const detail = event.params.exceptionDetails;
        errors.push(`uncaught browser error: ${detail.exception?.description || detail.text}`);
      }
      if (event.method === "Runtime.consoleAPICalled" && event.params.type === "error") {
        errors.push(`browser console error: ${event.params.args.map(arg => arg.value || arg.description).join(" ")}`);
      }
      if (event.method === "Log.entryAdded" && event.params.entry.level === "error") {
        errors.push(`browser log error: ${event.params.entry.text}`);
      }
    });
    const version = await cdp.send("Browser.getVersion");
    console.log(`M1 BROWSER ${version.product} revision=${version.revision} mode=headless full=${!quick}`);
    console.log("M1 source=test/acceptance.kite source_artifact=test/acceptance.kite.js");
    progress = setInterval(() => {
      console.log(`M1 progress elapsed_ms=${Date.now() - startedAt} nodes=${[...tabs.keys()].join(",")} passed=${passed.size}/6`);
      if (lastCall && lastCall.elapsedMs === undefined) {
        console.log(`M1 pending ${JSON.stringify({...lastCall,
          elapsedMs: Date.now() - lastCall.startedAt, cdp: cdp.pending()})}`);
      }
    }, 45000);
    const origin = `http://127.0.0.1:${server.address().port}`;
    foreground = await page(`${origin}/test/acceptance.html`);
    await poll(() => evaluate(foreground.session,
      "typeof KiteAcceptance !== 'undefined' && typeof KiteSource !== 'undefined' && typeof KiteArtifact !== 'undefined'",
      false), Boolean, "source acceptance page loaded", 10000);
    await run(host, {quick});
    checkErrors();
    const missing = required.filter(label => !(quick && label === "hidden-tab-operation") && !passed.has(label));
    if (missing.length) throw new Error(`missing source acceptance behaviors: ${missing.join(", ")}`);
    if (quick) {
      console.log("M1-QUICK-OK hidden-tab-operation=NOT-RUN full-milestone-gate=NOT-RUN");
    } else {
      console.log("M1-OK behaviors=6 hidden-threshold-ms=306000 pod-work-limit-ms=3000 leader-view-limit-ms=5000");
    }
    return {passed: [...passed], quick, hidden: hiddenChange};
  } catch (error) {
    console.error(`M1 diagnostic ${JSON.stringify({lastCall, cdp: cdp?.pending()})}`);
    if (stderr) console.error(`Chrome stderr tail:\n${stderr}`);
    throw error;
  } finally {
    await cleanup();
    for (const [signal, handler] of signals) process.removeListener(signal, handler);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = new Set(process.argv.slice(2));
  if ([...args].some(arg => !["--quick", "--help"].includes(arg))) {
    console.error("usage: node dev/drive.mjs [--quick]");
    process.exitCode = 64;
  } else if (args.has("--help")) {
    console.log("usage: node dev/drive.mjs [--quick]");
    console.log("Default runs all six source-driven M1 behaviors, including 306 hidden seconds.");
    console.log("--quick omits hidden aging and does not establish the full milestone gate.");
    console.log("Build browser model, program bridge and acceptance.kite.js before running.");
    console.log("CHROME_BIN selects Chromium; no background throttling flags are disabled.");
  } else {
    try {
      const {runAcceptance} = await import("./m1-source-runner.mjs");
      await withBrowser(runAcceptance, {quick: args.has("--quick")});
    } catch (error) {
      console.error(`M1-FAIL ${error.stack || error}`);
      process.exitCode = 1;
    }
  }
}
