#!/usr/bin/env node
// Real Chromium probes over CDP pipe, with no package dependencies.
import { spawn, execFile } from "node:child_process";
import { createServer } from "node:http";
import { readFile, writeFile, mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { validateEvidence } from "./m2-evidence.mjs";
import { runLifecycleFaults } from "./m2-lifecycle-faults.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = new Set(process.argv.slice(2));
if ([...args].some(arg => !["--hidden", "--pressure", "--help"].includes(arg))) {
  console.error("usage: node dev/browser-test.mjs [--hidden] [--pressure]");
  process.exit(64);
}
if (args.has("--help")) {
  console.log("usage: node dev/browser-test.mjs [--hidden] [--pressure]");
  console.log("Build browser/model.bc.js first. Default runs quick real-browser probes.");
  console.log("--hidden also hides the page for 306 seconds before nested Worker spawn.");
  console.log("--pressure adds PR-1 lifecycle and memory pressure diagnostics, reporting observed discard separately.");
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

async function sourceArtifacts() {
  const folder = await mkdtemp(join(tmpdir(), "kite-source-browser-"));
  const artifacts = {};
  try {
    for (const name of ["deployment", "stateful-set", "service", "freeze-drain"]) {
      const file = join(folder, `${name}.kite`);
      await writeFile(file, await readFile(join(root, `test/source/${name}.kite`)));
      await promisify(execFile)(join(root, "_build/default/bin/kite.exe"), ["build", file],
        {timeout: 30000, maxBuffer: 65536});
      artifacts[name] = await readFile(`${file}.js`, "utf8");
    }
    return artifacts;
  } finally { await rm(folder, {recursive: true, force: true}); }
}

const observed = (session, expression) => outcome(session,
  `Promise.resolve(${expression}).then(value => ({ok:true,value}))`);
const requireSource = (condition, message) => { if (!condition) throw new Error(`source probe: ${message}`); };
async function sourcePage(origin, artifact, cluster, node = "sourceA") {
  const tab = await page(`${origin}/browser/index.html?cluster=${cluster}&node=${node}`);
  try {
    await cdp.send("Page.bringToFront", {}, tab.session);
    await poll(tab.session, "typeof kite !== 'undefined' && !!kite.ready && !!kite.workloads", 15000);
    await outcome(tab.session, "kite.ready");
    await evaluate(tab.session, `${artifact}\n(() => {
      globalThis.sourceProbe = {calls:[], workers:[], lifecycle:[]};
      const spawn = KiteGlue.spawn;
      KiteGlue.spawn = (...args) => {
        const result = spawn(...args);
        if (result.ok) sourceProbe.workers.push({url:args[0], native:result.value});
        return result;
      };
    })(); true`);
    tab.loaded = await outcome(tab.session,
      "kite.load(KiteArtifact, (name, argument) => {sourceProbe.calls.push({name, argument}); return null})");
    return tab;
  } catch (error) {
    await cdp.send("Target.closeTarget", {targetId: tab.target});
    throw error;
  }
}
async function closeSource(tab) {
  if (!tab) return;
  try {
    await outcome(tab.session, "Promise.all([kite.workloads.close(), kite.request('close')])" +
      ".then(results => results.find(result => !result.ok) || {ok:true})");
  } finally { await cdp.send("Target.closeTarget", {targetId: tab.target}); }
}
async function killSource(tab) {
  const killed = await outcome(tab.session, `(() => {
    if (sourceProbe.workers.length !== 1 ||
        !sourceProbe.workers[0].url.endsWith('control.js'))
      return {ok:false,error:'expected_one_workload_control_worker'};
    sourceProbe.lifecycle = [];
    addEventListener('pagehide', () => sourceProbe.lifecycle.push('pagehide'),
      {capture:true,once:true});
    document.addEventListener('freeze', () => sourceProbe.lifecycle.push('freeze'),
      {capture:true,once:true});
    const result = KiteGlue.kill(sourceProbe.workers[0].native);
    return result.ok ? {ok:true,value:{prefix:'kite:' +
      new URL(location.href).searchParams.get('cluster') + ':workload:'}} : result;
  })()`);
  const deadline = Date.now() + 15000;
  let remaining;
  do {
    remaining = (await outcome(tab.session, "KiteGlue.locks()"))
      .filter(name => name.startsWith(killed.prefix));
    if (remaining.length) await delay(20);
  } while (remaining.length && Date.now() < deadline);
  requireSource(remaining.length === 0, "terminated workload retains native leases");
  const lifecycle = await evaluate(tab.session, "sourceProbe.lifecycle");
  requireSource(lifecycle.length === 0, `node death invoked lifecycle drain: ${lifecycle}`);
  const closed = await cdp.send("Target.closeTarget", {targetId: tab.target});
  requireSource(closed.success, "dead node tab cleanup was not acknowledged");
  return {workerTerminated: true, nativeLeasesAfterDeath: remaining.length,
    lifecycleEventsBeforeDeath: lifecycle, targetClosedAfterDeath: closed.success};
}
async function sourceView(tab, workload, predicate, label, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  let view;
  while (Date.now() < deadline) {
    if (browserErrors.length) throw new Error(browserErrors.join("\n"));
    view = await outcome(tab.session, `kite.workloads.request(${JSON.stringify(workload)}, 'view')`);
    if (view.error) throw new Error(`source workload error: ${view.error}`);
    if (predicate(view)) return view;
    await delay(125);
  }
  throw new Error(`${label} did not converge: ${JSON.stringify(view)}`);
}
const runningSource = (view, count) => view.node.nodeLock && view.node.workers.length === count &&
  view.node.workers.every(worker => worker.phase === "running" &&
    view.ticks.some(tick => tick.pod === worker.pod && tick.ticket === worker.ticket));
const attachedSource = view => runningSource(view, 1) && view.volumes.length === 1 &&
  view.volumes[0].phase === "attached" && view.volumes[0].writer;
async function sourceCheckpoint(tab, marker) {
  const deadline = Date.now() + 15000;
  let result;
  while (Date.now() < deadline) {
    result = await observed(tab.session,
      `kite.workloads.request('data','checkpoint',{entries:[${JSON.stringify(marker)}]})`);
    if (result.ok) {
      return sourceView(tab, "data", view => attachedSource(view) &&
        view.volumes[0].committed.entries.includes(marker), "source committed checkpoint");
    }
    if (!["invalid_phase", "stale_callback"].includes(result.error))
      throw new Error(`source checkpoint: ${JSON.stringify(result)}`);
    await delay(125);
  }
  throw new Error(`source checkpoint timed out: ${JSON.stringify(result)}`);
}
async function sourceLeaseRelease(tab, cluster) {
  const prefix = `kite:${cluster}:workload:`;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const held = await outcome(tab.session,
      "navigator.locks.query().then(value => ({ok:true,value:value.held.map(lock => lock.name)}))");
    if (!held.some(name => name.startsWith(prefix))) return;
    await delay(125);
  }
  throw new Error("source freeze retained workload leases after settling");
}
async function sourceIntegrationProbe(origin, artifacts) {
  const run = Date.now();
  const manifests = [];
  let tab;
  try {
    tab = await sourcePage(origin, artifacts.deployment, `source-deploy-${run}`);
    requireSource(tab.loaded.manifests[0].bound === 3, "Deployment bound did not survive emission");
    await sourceView(tab, "web", view => runningSource(view, 2), "source Deployment starts");
    const refused = await observed(tab.session, "kite.workloads.request('web','desired',{count:4})");
    requireSource(!refused.ok && refused.error === "invalid_desired", "Deployment exceeded checked bound");
    const retained = await sourceView(tab, "web", view => runningSource(view, 2), "bound refusal retains placements");
    requireSource(!retained.log.entries.some(entry => entry.payload.kind === "desired" && entry.payload.count === 4),
      "refused desired count entered the durable log");
    console.log("PASS source-deployment emitted-bound=3 refused-count=4 running=2 namespace=web");
    manifests.push({name: "deployment", outcome: refused.error, witness: {
      bound: tab.loaded.manifests[0].bound, refusedCount: 4,
      running: retained.node.workers.length, refusedCountRecorded: false}});
    await closeSource(tab); tab = undefined;

    const stateCluster = `source-state-${run}`;
    const marker = `source-checkpoint-${run}`;
    tab = await sourcePage(origin, artifacts["stateful-set"], stateCluster);
    await sourceView(tab, "data", attachedSource, "source StatefulSet volume claim");
    const saved = await sourceCheckpoint(tab, marker);
    const prior = saved.volumes[0];
    const death = await killSource(tab);
    tab = undefined;
    tab = await sourcePage(origin, artifacts["stateful-set"], stateCluster, "sourceB");
    const recovered = await sourceView(tab, "data", view => attachedSource(view) &&
      view.volumes[0].committed.entries.includes(marker), "source StatefulSet durable reopen");
    requireSource(recovered.volumes[0].key === prior.key &&
      recovered.volumes[0].writer.generation > prior.writer.generation, "StatefulSet identity or writer generation changed incorrectly");
    console.log("PASS source-stateful-set death=Worker.terminate close=cleanup-after-death namespace=data ordinal=0 committed-prefix=true fresh-generation=true");
    manifests.push({name: "stateful-set", outcome: "recovered", witness: {
      injection: "Worker.terminate-without-drain", ...death, key: prior.key, marker,
      previousGeneration: prior.writer.generation,
      recoveredGeneration: recovered.volumes[0].writer.generation,
      recoveredEntries: recovered.volumes[0].committed.entries}});
    await closeSource(tab); tab = undefined;

    const serviceCluster = `source-service-${run}`;
    tab = await sourcePage(origin, artifacts.service, serviceCluster);
    const serviceView = await sourceView(tab, "web", view => runningSource(view, 1), "source Service workload");
    const source = {service: "api", sender: "client", incarnation: 1, session: 1};
    const publication = {source, sequence: 1, payload: `message-${run}`};
    await outcome(tab.session, `kite.workloads.service('api',${JSON.stringify({kind: "handshake", source})})`);
    const sent = await outcome(tab.session,
      `kite.workloads.service('api',${JSON.stringify({kind: "send", publication})})`);
    const duplicate = await outcome(tab.session,
      `kite.workloads.service('api',${JSON.stringify({kind: "send", publication})})`);
    requireSource(!sent.duplicate && duplicate.duplicate, "Service logical send did not deduplicate");
    const conflicting = await observed(tab.session,
      `kite.workloads.service('api',${JSON.stringify({kind: "send", publication: {...publication, payload: "conflict"}})})`);
    requireSource(!conflicting.ok, "Service accepted changed payload for one logical send");
    await closeSource(tab); tab = undefined;
    tab = await sourcePage(origin, artifacts.service, serviceCluster, "sourceB");
    await sourceView(tab, "web", view => runningSource(view, 1) &&
      view.node.epoch > serviceView.node.epoch, "source Service fresh leader epoch");
    const history = await outcome(tab.session, "kite.workloads.request('web','services')");
    requireSource(history.services.includes("api") && history.messages.filter(message =>
      message.publication.payload === publication.payload).length === 1, "Service durable history was lost or duplicated");
    const stale = await observed(tab.session, `kite.workloads.request('web','service',${JSON.stringify({
      epoch: serviceView.node.epoch, event: {kind: "handshake", source}})})`);
    requireSource(!stale.ok && stale.error === "stale_epoch", "Service old epoch handshake was accepted");
    console.log("PASS source-service named-channel=api duplicate-send=true conflicting-send=refused reopen-history=1 old-epoch=refused external-exactly-once=unclaimed");
    manifests.push({name: "service", outcome: stale.error, witness: {
      name: "api", duplicate: duplicate.duplicate, conflict: conflicting.error,
      recoveredMessages: history.messages.filter(message =>
        message.publication.payload === publication.payload).length}});
    await closeSource(tab); tab = undefined;

    const drainCluster = `source-drain-${run}`;
    tab = await sourcePage(origin, artifacts["freeze-drain"], drainCluster);
    const before = await sourceView(tab, "data", attachedSource, "source FreezeDrain volume");
    const frozen = await observed(tab.session, "kite.workloads.freeze()");
    requireSource(typeof frozen.ok === "boolean" && (frozen.ok || typeof frozen.error === "string"),
      "freeze checkpoint had no explicit outcome");
    await sourceLeaseRelease(tab, drainCluster);
    const calls = await evaluate(tab.session, "sourceProbe.calls");
    requireSource(calls.filter(call => call.name === "host_probe" && call.argument === "startup").length === 1 &&
      calls.filter(call => call.name === "host_probe" && call.argument === "retained").length === 1 &&
      !calls.some(call => call.argument === "shadowed"), "freeze lost its captured source closure or replayed startup");
    await outcome(tab.session, "kite.workloads.resume()");
    await sourceView(tab, "data", view => attachedSource(view) &&
      view.node.incarnation > before.node.incarnation, "source resume fresh lifecycle");
    requireSource(await evaluate(tab.session, "sourceProbe.calls.filter(call => call.argument === 'startup').length") === 1,
      "resume replayed source startup");
    console.log(`PASS source-freeze-drain retained-closure=true startup-calls=1 leases-released=true checkpoint=${frozen.ok ? "completed" : `refused:${frozen.error}`} fresh-resume=true`);
    manifests.push({name: "freeze-drain", outcome: frozen.ok ? "completed" : frozen.error,
      witness: {startupCalls: calls.filter(call => call.argument === "startup").length,
        retainedCalls: calls.filter(call => call.argument === "retained").length,
        leasesReleased: true, freshResume: true}});
  } finally { await closeSource(tab); }
  return manifests;
}

async function pressureProbe(origin, artifact) {
  const run = Date.now();
  const cluster = `source-pressure-${run}`;
  const marker = `pressure-checkpoint-${run}`;
  let tab;
  try {
    tab = await sourcePage(origin, artifact, cluster);
    await sourceView(tab, "data", attachedSource, "PR-1 initial volume claim");
    await sourceCheckpoint(tab, marker);
    const storage = `kite-pressure-events-${run}`;
    const recorder = `(() => {
      const key=${JSON.stringify(storage)};
      const record=type => { const events=JSON.parse(sessionStorage.getItem(key)||'[]');
        events.push({type,wasDiscarded:!!document.wasDiscarded,hidden:document.hidden});
        sessionStorage.setItem(key,JSON.stringify(events.slice(-20))); };
      record('context');
      for(const type of ['freeze','resume']) document.addEventListener(type,()=>record(type));
      addEventListener('pagehide',()=>record('pagehide'));
    })()`;
    await cdp.send("Page.addScriptToEvaluateOnNewDocument", {source: recorder}, tab.session);
    await evaluate(tab.session, `${recorder}; globalThis.pressureSentinel=${JSON.stringify(marker)}; true`);
    await cdp.send("Memory.simulatePressureNotification", {level: "critical"}, tab.session);
    await cdp.send("Page.setWebLifecycleState", {state: "frozen"}, tab.session);
    await delay(300);
    await cdp.send("Page.setWebLifecycleState", {state: "active"}, tab.session);
    await cdp.send("Page.bringToFront", {}, tab.session);
    const observation = await evaluate(tab.session, `({wasDiscarded:!!document.wasDiscarded,
      localStateLost:globalThis.pressureSentinel!==${JSON.stringify(marker)},
      events:JSON.parse(sessionStorage.getItem(${JSON.stringify(storage)})||'[]')})`);
    if (observation.localStateLost) {
      await poll(tab.session, "typeof kite !== 'undefined' && !!kite.ready", 15000);
      await outcome(tab.session, "kite.ready");
      await evaluate(tab.session, `${artifact}; true`);
      await outcome(tab.session, "kite.load(KiteArtifact)");
    } else await outcome(tab.session, "kite.workloads.resume()");
    await sourceView(tab, "data", view => attachedSource(view) &&
      view.volumes[0].committed.entries.includes(marker), "PR-1 recovery after lifecycle pressure");
    const types = observation.events.map(event => event.type);
    const discarded = observation.wasDiscarded && observation.localStateLost;
    console.log(`PR-1 mode=memory-pressure-and-lifecycle diagnostic=true pressure=critical freeze-injection=Page.setWebLifecycleState events=${types.join(',')} pagehide=${types.includes('pagehide')} wasDiscarded=${observation.wasDiscarded} local-state-lost=${observation.localStateLost} recovered-prefix=true discard=${discarded ? 'observed' : 'not-observed'} target-close=cleanup-after-observation`);
  } finally { await closeSource(tab); }
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
  const durable = await outcome(testPage.session, "KiteDurableTests.run()");
  for (const line of durable.lines) console.log(line);
  await tabCloseProbe(origin, testPage);
  await productionProbe(origin);
  const artifacts = await sourceArtifacts();
  const manifests = await sourceIntegrationProbe(origin, artifacts);
  await cdp.send("Page.bringToFront", {}, testPage.session);
  const durableFaults = await outcome(testPage.session, "KiteM2DurableTests.run()");
  const lifecycleFaults = await runLifecycleFaults({origin, page, evaluate, outcome,
    poll, delay, cdp, artifacts, sourcePage, sourceView, sourceCheckpoint, closeSource,
    killSource});
  const faults = [...durableFaults.rows, ...lifecycleFaults].sort((a, b) => a.id - b.id);
  validateEvidence({faults, manifests});
  for (const manifest of manifests) console.log(`M2-MANIFEST ${JSON.stringify(manifest)}`);
  for (const fault of faults) console.log(`M2-FAULT ${JSON.stringify(fault)}`);
  console.log("M2-OK manifests=4 faults=12 browser=real");
  if (args.has("--pressure")) await pressureProbe(origin, artifacts["stateful-set"]);
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
