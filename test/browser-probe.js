/* Browser effects in these probes pass through the same audited GLUE as the host. */
(function (root) {
  "use strict";
  const isPage = typeof document !== "undefined";
  if (!isPage) importScripts("/browser/glue.js");
  const glue = root.KiteGlue;
  const sleep = ms => new Promise(done => setTimeout(done, ms));
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const value = (outcome, label) => {
    assert(outcome && outcome.ok, `${label}: ${outcome?.error || "missing outcome"}`);
    return outcome.value;
  };
  const equal = (actual, expected, label) =>
    assert(JSON.stringify(actual) === JSON.stringify(expected), `${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  const url = (role, fields = {}) => {
    const address = new URL("/test/browser-probe.js", root.location.href);
    address.search = new URLSearchParams({ role, ...fields }).toString();
    return address.href;
  };

  if (!isPage) {
    const role = new URL(root.location.href).searchParams.get("role");
    const send = message => value(glue.send(root, message), "worker reply");
    const fail = error => glue.send(root, { kind: "failure", error: String(error.stack || error) });
    let lease = null;
    let timer = null;
    let workCount = 0;
    const children = new Map();
    let writer;
    value(glue.listen(message => {
      (async () => {
        if (role === "node") {
          if (message.kind === "spawn") {
            const started = performance.now();
            const worker = value(glue.spawn(url("pod", { lock: message.lock }), data => {
              send({ kind: "child", id: message.id, data,
                nestedSpawnMs: data.kind === "ready" ? performance.now() - started : undefined });
            }, error => fail(error)), "nested spawn");
            children.set(message.id, worker);
          } else if (message.kind === "child") {
            value(glue.send(children.get(message.id), message.data), "nested command");
          } else if (message.kind === "kill") {
            value(glue.kill(children.get(message.id)), "nested kill");
            children.delete(message.id);
          }
        } else if (role === "pod") {
          if (message.kind === "begin") {
            if (!lease) { send({ kind: "begin-refused", workCount }); return; }
            if (!timer) {
              let previous = performance.now();
              timer = setInterval(() => {
                const now = performance.now();
                workCount += 1;
                send({ kind: "work", workCount, elapsedMs: now - previous });
                previous = now;
              }, 40);
            }
          } else if (message.kind === "status") send({ kind: "status", workCount });
          else if (message.kind === "stop") {
            clearInterval(timer);
            if (lease) value(await lease.release(), "pod release");
            lease = null;
            send({ kind: "stopped", workCount });
          }
        } else if (role === "writer") {
          if (message.kind === "open") {
            writer = value(await glue.open(message.name), "writer open");
            if (message.lock) {
              lease = value(await glue.lock(message.lock), "writer leader lock");
              assert(lease !== null, "writer leader lock busy");
            }
            send({ kind: "opened" });
          } else if (message.kind === "append") {
            const payload = { kind: message.tag, body: "x".repeat(message.bytes) };
            // append starts its transaction synchronously. This marker witnesses
            // transaction creation, without claiming that requests have committed.
            const pending = writer.append(message.epoch, payload);
            send({ kind: "append-issued", tag: message.tag, bytes: message.bytes });
            if (message.close) value(writer.close(), "close while transaction pending");
            const result = await pending;
            send({ kind: "append-complete", tag: message.tag, result });
          }
        }
      })().catch(fail);
    }), "worker listener");
    if (role === "pod") {
      glue.lock(new URL(root.location.href).searchParams.get("lock")).then(result => {
        lease = value(result, "pod lock");
        send({ kind: "ready", granted: lease !== null, workCount });
      }).catch(fail);
    } else send({ kind: "ready" });
    return;
  }

  let hiddenSince = document.hidden ? performance.now() : null;
  document.addEventListener("visibilitychange", () => {
    hiddenSince = document.hidden ? performance.now() : null;
  });
  const visibility = () => ({ hidden: document.hidden,
    hiddenForMs: hiddenSince === null ? 0 : performance.now() - hiddenSince });
  const actors = new Set();
  const stores = new Set();
  const heldLeases = new Set();
  const lines = [];
  const unique = label => `kite-test-${label}-${crypto.randomUUID()}`;
  const record = line => {
    lines.push(line);
    document.getElementById("results").textContent = lines.join("\n");
  };
  const pass = label => record(`PASS ${label}`);

  function actor(role) {
    const messages = [];
    const waiters = [];
    let failure = null;
    const deliver = message => {
      if (message.kind === "failure") {
        failure = new Error(message.error);
        for (const waiter of waiters.splice(0)) { clearTimeout(waiter.timer); waiter.reject(failure); }
        return;
      }
      const index = waiters.findIndex(waiter => waiter.predicate(message));
      if (index < 0) messages.push(message);
      else {
        const waiter = waiters.splice(index, 1)[0];
        clearTimeout(waiter.timer);
        waiter.resolve(message);
      }
    };
    const worker = value(glue.spawn(url(role), deliver, error => deliver({ kind: "failure", error })), `${role} spawn`);
    const result = {
      send: message => value(glue.send(worker, message), `${role} send`),
      next(predicate, timeout = 15000) {
        if (failure) return Promise.reject(failure);
        const index = messages.findIndex(predicate);
        if (index >= 0) return Promise.resolve(messages.splice(index, 1)[0]);
        return new Promise((resolve, reject) => {
          const waiter = { predicate, resolve, reject, timer: null };
          waiter.timer = setTimeout(() => {
            const found = waiters.indexOf(waiter);
            if (found >= 0) waiters.splice(found, 1);
            reject(new Error(`${role} message timeout`));
          }, timeout);
          waiters.push(waiter);
        });
      },
      kill() {
        value(glue.kill(worker), `${role} kill`);
        actors.delete(result);
      }
    };
    actors.add(result);
    return result;
  }

  async function open(name) {
    const store = value(await glue.open(name), "store open");
    stores.add(store);
    return store;
  }

  async function lock(name) {
    const lease = value(await glue.lock(name), "lock acquisition");
    assert(lease !== null, "lock unexpectedly busy");
    heldLeases.add(lease);
    return lease;
  }

  async function release(lease) {
    value(await lease.release(), "lock release");
    heldLeases.delete(lease);
  }

  function prefix(state) {
    equal(state.entries.map(entry => entry.seq), Array.from({ length: state.seq }, (_, index) => index + 1), "committed contiguous sequence");
    for (let index = 0; index < state.entries.length; index += 1) {
      const entry = state.entries[index];
      assert(entry.epoch > 0 && entry.epoch <= state.epoch, "entry epoch in committed range");
      if (index > 0) assert(entry.epoch >= state.entries[index - 1].epoch, "epochs monotone");
    }
  }

  function modelProbe() {
    const model = root.KiteModel;
    assert(model, "native model bridge loaded");
    let state = model.create("nodeA", 1);
    assert(state.ok, "model creation");
    equal(model.view(state.state), state.view, "model view roundtrip");
    const step = event => {
      state = model.step(state.state, event);
      assert(state.ok, `model step ${event.kind}: ${state.error}`);
      return state;
    };
    step({ kind: "node_acquired", incarnation: 1 });
    step({ kind: "observe_epoch", epoch: 1 });
    equal(step({ kind: "start", epoch: 1, pod: 0, incarnation: 1 }).actions.map(action => action.kind), ["spawn"], "spawn before work");
    const ticket = state.view.workers[0].ticket;
    equal(step({ kind: "pod_lock", ticket, granted: true }).actions.map(action => action.kind), ["publish_place", "begin_work"], "grant orders publication before work");
    step({ kind: "stop", epoch: 1, pod: 0, incarnation: 1 });
    assert(!model.step(state.state, { kind: "start", epoch: 1, pod: 0, incarnation: 1 }).ok, "stopping slot reserved");
    step({ kind: "worker_exited", ticket });
    step({ kind: "start", epoch: 1, pod: 0, incarnation: 1 });
    assert(state.view.workers[0].ticket > ticket, "ticket history survives empty worker list");
    const delayed = model.step(state.state, { kind: "node_acquired", incarnation: 2 });
    assert(delayed.ok, "delayed callback produces outcome");
    equal(delayed.actions, [{ kind: "release_node", incarnation: 2 }], "release callback generation only");
    const snapshot = { now: 10, epoch: 1, nodes: [
      { nodeId: "nodeB", incarnation: 1, lockHeld: true, heartbeat: 10, phase: "active" },
      { nodeId: "nodeA", incarnation: 1, lockHeld: true, heartbeat: 10, phase: "active" }
    ], placements: [], podLocks: [] };
    const plan = model.plan(snapshot, 1, 3, 5, 8);
    assert(plan.ok, "native planner bridge");
    equal(plan.commands.map(command => [command.pod, command.owner]), [[0, "nodeA"], [1, "nodeB"], [2, "nodeA"]], "planner deterministic balance");
    assert(!model.plan(snapshot, 2, 3, 5, 8).ok, "planner stale epoch rejected");
    for (const invalid of [null, undefined, true, "1", 1.5, NaN, Infinity, 2147483648]) {
      assert(!model.create("nodeA", invalid).ok, "invalid model incarnation rejected");
      assert(!model.step(state.state, { kind: "observe_epoch", epoch: invalid }).ok, "invalid model epoch rejected");
      assert(!model.plan(snapshot, 1, invalid, 5, 8).ok, "invalid model desired rejected");
    }
    for (const invalid of [null, undefined, [], "freeze", 2]) {
      assert(!model.step(state.state, invalid).ok, "invalid model event rejected");
    }
    assert(!model.step({}, { kind: "freeze" }).ok, "invalid model state rejected");
    assert(!model.step(state.state, { kind: "pod_lock", ticket, granted: "true" }).ok, "invalid model boolean rejected");
    pass("native-model-bridge-lifecycle-planner-and-invalid-inputs");
  }

  async function locksProbe() {
    const name = unique("lock");
    const first = await lock(name);
    equal(value(await glue.lock(name), "contended lock"), null, "busy lock refusal");
    assert(value(await glue.locks(), "lock snapshot").includes(name), "held lock snapshot");
    const aborter = new AbortController();
    const queued = glue.lock(name, { wait: true, signal: aborter.signal });
    await sleep(20);
    aborter.abort();
    equal(await queued, { ok: false, error: "AbortError" }, "queued cancellation");
    await release(first);
    const second = await lock(name);
    value(await first.release(), "repeated old release");
    equal(value(await glue.lock(name), "new generation still held"), null, "old release cannot release new generation");
    await release(second);
    const third = await lock(name);
    await release(third);
    assert(!value(await glue.locks(), "released lock snapshot").includes(name), "release reflected in lock manager");
    pass("real-lock-contention-cancellation-and-generation-local-release");
  }

  async function storeProbe() {
    const name = unique("store");
    const first = await open(name);
    const second = await open(name);
    equal(value(await first.read(), "initial read"), { epoch: 0, seq: 0, owner: null, entries: [] }, "initial store");
    const claims = await Promise.all([first.claim(0, "nodeA"), second.claim(0, "nodeB")]);
    assert(claims.filter(result => result.ok).length === 1, "exactly one concurrent CAS wins");
    equal(claims.find(result => !result.ok).error, "stale_epoch", "losing CAS refused");
    const writes = await Promise.all(Array.from({ length: 12 }, (_, index) =>
      (index % 2 ? first : second).append(1, { kind: "data", index })));
    equal(writes.map((result, index) => value(result, `append ${index}`).seq).sort((a, b) => a - b),
      Array.from({ length: 12 }, (_, index) => index + 2), "concurrent writes have distinct contiguous sequence");
    const before = value(await first.read(), "before stale write");
    prefix(before);
    equal(await second.append(0, { kind: "stale" }), { ok: false, error: "stale_epoch" }, "stale append refused");
    equal(value(await first.read(), "after stale write"), before, "stale append rolls back metadata and log");
    value(first.close(), "first close");
    value(second.close(), "second close");
    const reopened = await open(name);
    equal(value(await reopened.read(), "reopened read"), before, "reopen preserves log and fence");
    const next = value(await reopened.claim(1, "nodeC"), "new leader CAS");
    equal(next, { epoch: 2, seq: 14 }, "claim advances epoch and sequence");
    equal(await reopened.append(1, { kind: "old leader" }), { ok: false, error: "stale_epoch" }, "prior leader fenced");
    const competitor = await open(name);
    const plans = await Promise.all([
      reopened.append(2, { kind: "plan", source: "first" }, next.seq),
      competitor.append(2, { kind: "plan", source: "second" }, next.seq)
    ]);
    assert(plans.filter(result => result.ok).length === 1, "one write from a shared snapshot sequence wins");
    equal(plans.find(result => !result.ok).error, "stale_sequence", "superseded snapshot cannot publish a plan");
    const planned = value(await reopened.read(), "sequence fenced log");
    equal(planned.seq, next.seq + 1, "failed sequence CAS leaves no log entry");
    equal(await competitor.append(2, { kind: "invalid sequence" }, 0.5),
      { ok: false, error: "invalid_sequence" }, "malformed expected sequence refused");
    equal(value(await reopened.read(), "after malformed sequence"), planned, "invalid sequence preserves committed state");
    equal(await competitor.append(2, { kind: "clone failure", invalid: () => 0 }),
      { ok: false, error: "DataCloneError" }, "uncloneable payload refused");
    equal(value(await reopened.read(), "after clone failure"), planned, "failed log insertion rolls back queued metadata update");
    prefix(planned);
    pass("idb-concurrent-cas-append-rollback-and-reopen");
  }

  async function nestedProbe(hidden) {
    const name = unique(hidden ? "hidden-pod" : "pod");
    const started = performance.now();
    const node = actor("node");
    await node.next(message => message.kind === "ready");
    const rootSpawnMs = performance.now() - started;
    node.send({ kind: "spawn", id: 1, lock: name });
    const ready = await node.next(message => message.kind === "child" && message.id === 1 && message.data.kind === "ready", 30000);
    assert(ready.data.granted, "nested worker acquires pod lock");
    assert(value(await glue.locks(), "nested pod lock snapshot").includes(name), "pod lock held by nested context");
    await sleep(60);
    node.send({ kind: "child", id: 1, data: { kind: "status" } });
    const before = await node.next(message => message.kind === "child" && message.id === 1 && message.data.kind === "status");
    equal(before.data.workCount, 0, "nested worker does no work before begin");
    node.send({ kind: "spawn", id: 2, lock: name });
    const busy = await node.next(message => message.kind === "child" && message.id === 2 && message.data.kind === "ready");
    assert(!busy.data.granted, "second nested worker refuses occupied pod");
    node.send({ kind: "child", id: 2, data: { kind: "begin" } });
    const refused = await node.next(message => message.kind === "child" && message.id === 2 && message.data.kind === "begin-refused");
    equal(refused.data.workCount, 0, "busy worker cannot begin work");
    const beginAt = performance.now();
    node.send({ kind: "child", id: 1, data: { kind: "begin" } });
    const cadence = [];
    let firstWorkMs;
    for (let index = 0; index < 6; index += 1) {
      const tick = await node.next(message => message.kind === "child" && message.id === 1 && message.data.kind === "work", 30000);
      if (index === 0) firstWorkMs = performance.now() - beginAt;
      cadence.push(Math.round(tick.data.elapsedMs));
    }
    node.send({ kind: "child", id: 1, data: { kind: "stop" } });
    await node.next(message => message.kind === "child" && message.id === 1 && message.data.kind === "stopped");
    assert(!value(await glue.locks(), "stopped pod lock snapshot").includes(name), "nested stop releases pod lock");
    node.kill();
    record(`PR-2 mode=${hidden ? "hidden" : "foreground"} hidden_age_ms=${Math.round(visibility().hiddenForMs)} root_spawn_ms=${Math.round(rootSpawnMs)} nested_spawn_ms=${Math.round(ready.nestedSpawnMs)} first_work_ms=${Math.round(firstWorkMs)} timer_interval_ms=40 observed_cadence_ms=${cadence.join(",")} spawn_within_3s=${ready.nestedSpawnMs <= 3000}`);
    pass(hidden ? "hidden-nested-worker-lock-begin-and-cadence" : "nested-worker-pod-lock-begin-and-busy-refusal");
  }

  async function interruptedWriteProbe() {
    const name = unique("interruption");
    const observer = await open(name);
    value(await observer.claim(0, "oldLeader"), "initial interrupt-test claim");
    const draining = actor("writer");
    await draining.next(message => message.kind === "ready");
    draining.send({ kind: "open", name });
    await draining.next(message => message.kind === "opened");
    draining.send({ kind: "append", epoch: 1, bytes: 1024 * 1024, tag: "close-drain", close: true });
    await draining.next(message => message.kind === "append-issued");
    const completion = await draining.next(message => message.kind === "append-complete");
    value(completion.result, "pending transaction drains after connection close");
    draining.kill();
    const recovered = await open(name);
    const leaderLock = unique("interrupted-leader");
    let interrupted = 0;
    let committed = 0;
    let attempts = 0;
    let recoveredEpoch = 1;
    for (; attempts < 5 && interrupted === 0; attempts += 1) {
      const writer = actor("writer");
      await writer.next(message => message.kind === "ready");
      writer.send({ kind: "open", name, lock: leaderLock });
      await writer.next(message => message.kind === "opened");
      const before = value(await observer.read(), "before context termination");
      equal(value(await glue.lock(leaderLock), "writer holds leader lock"), null, "writer owns real exclusive leader lock");
      const takeover = glue.lock(leaderLock, { wait: true });
      const tag = `terminated-${attempts}`;
      writer.send({ kind: "append", epoch: before.epoch, bytes: 32 * 1024 * 1024, tag });
      const issued = await writer.next(message => message.kind === "append-issued");
      equal(issued.tag, tag, "termination follows transaction initiation marker");
      writer.kill();
      const successor = value(await takeover, "successor acquires terminated writer lock");
      assert(successor !== null, "queued successor owns leader lock");
      heldLeases.add(successor);
      // Claim immediately after the lock handoff. IndexedDB must serialize this
      // fence with any unfinished transaction from the terminated context.
      const claim = value(await recovered.claim(before.epoch, `newLeader${attempts}`), "lock successor epoch claim");
      recoveredEpoch = claim.epoch;
      const after = value(await observer.read(), "after context termination");
      prefix(after);
      assert(after.seq === before.seq + 1 || after.seq === before.seq + 2, "terminated write plus successor claim is an atomic prefix");
      equal(after.entries.slice(0, before.entries.length), before.entries, "termination preserves prior committed prefix");
      equal(after.entries.at(-1).payload.kind, "leader", "successor claim follows prior transaction");
      equal(after.epoch, before.epoch + 1, "lock successor advances epoch");
      if (after.seq === before.seq + 1) interrupted += 1;
      else {
        committed += 1;
        const last = after.entries.at(-2);
        equal([last.epoch, last.payload.kind, last.payload.body.length], [before.epoch, tag, issued.bytes], "committed large payload is intact");
      }
      equal(await observer.append(before.epoch, { kind: "stale-after-recovery" }),
        { ok: false, error: "stale_epoch" }, "old context fenced after lock successor claim");
      equal(value(await recovered.read(), "after stale recovery write"), after, "old epoch failure preserves recovered prefix");
      await release(successor);
    }
    assert(interrupted > 0, "PR-4 requires an observed interrupted transaction, all attempts committed");
    prefix(value(await recovered.read(), "recovered prefix"));
    record(`PR-4 transaction_started_before_termination=true marker=append-returned writes_queued_before_termination=unobserved attempts=${attempts} interrupted=${interrupted} committed=${committed} connection_close_drained=true atomic_prefix=true lock_handoff=true recovery_epoch=${recoveredEpoch} stale_append=refused`);
    pass("idb-close-pending-transaction-and-writer-termination-recovery");
  }

  async function cleanup() {
    for (const current of actors) current.kill();
    for (const current of stores) value(current.close(), "cleanup store close");
    stores.clear();
    for (const current of heldLeases) await release(current);
  }

  let tabObserver;
  let tabWriter;
  async function setupTabInterruption(name) {
    tabObserver = await open(name);
    value(await tabObserver.claim(0, "tabWriter"), "tab interruption initial claim");
    return { ok: true };
  }

  async function prepareTabWriter(name, lockName) {
    tabWriter = actor("writer");
    await tabWriter.next(message => message.kind === "ready");
    tabWriter.send({ kind: "open", name, lock: lockName });
    await tabWriter.next(message => message.kind === "opened");
    return { ok: true };
  }

  async function queueTabSuccessor(lockName) {
    const before = value(await tabObserver.read(), "before writer tab closes");
    const busy = value(await glue.lock(lockName), "writer tab owns leader lock");
    if (busy) await busy.release();
    assert(busy === null, "writer tab must own leader lock before successor queues");
    root.KiteBrowserTests.tabResult = null;
    const queued = glue.lock(lockName, { wait: true });
    queued.then(async outcome => {
      const successor = value(outcome, "tab successor acquires leader lock");
      assert(successor !== null, "tab successor owns queued leader lock");
      heldLeases.add(successor);
      // This claim is issued as soon as tab closure releases the lock, before
      // any observer read can wait for the old IndexedDB transaction to settle.
      const claim = value(await tabObserver.claim(before.epoch, "tabSuccessor"), "tab successor epoch claim");
      const after = value(await tabObserver.read(), "read after tab successor claim");
      prefix(after);
      const interrupted = after.seq === before.seq + 1;
      assert(interrupted || after.seq === before.seq + 2, "closed tab leaves whole write or no write before successor claim");
      equal(after.entries.slice(0, before.entries.length), before.entries, "tab closure preserves committed prefix");
      equal(after.entries.at(-1).payload.kind, "leader", "tab successor claim follows closed writer transaction");
      equal(claim.epoch, before.epoch + 1, "tab successor advances epoch");
      if (!interrupted) {
        const entry = after.entries.at(-2);
        equal([entry.epoch, entry.payload.kind, entry.payload.body.length],
          [before.epoch, "tab-terminated", 32 * 1024 * 1024], "closed-tab committed payload intact");
      }
      equal(await tabObserver.append(before.epoch, { kind: "stale-after-tab-close" }),
        { ok: false, error: "stale_epoch" }, "closed writer epoch fenced after tab successor claim");
      equal(value(await tabObserver.read(), "tab stale append rollback"), after, "tab stale append leaves recovered prefix unchanged");
      await release(successor);
      return { ok: true, value: { interrupted, epoch: claim.epoch,
        sequence: after.seq, atomicPrefix: true, staleAppend: "refused" } };
    }).then(result => { root.KiteBrowserTests.tabResult = result; })
      .catch(error => { root.KiteBrowserTests.tabResult = { ok: false, error: String(error.stack || error) }; });
    return { ok: true, value: { epoch: before.epoch } };
  }

  async function startTabWrite(epoch) {
    tabWriter.send({ kind: "append", epoch, bytes: 32 * 1024 * 1024, tag: "tab-terminated" });
    const marker = await tabWriter.next(message => message.kind === "append-issued");
    return { ok: true, value: marker };
  }

  const protectedProbe = operation => async (...args) => {
    try { return await operation(...args); }
    catch (error) { return { ok: false, error: String(error.stack || error) }; }
  };

  async function execute(hidden) {
    root.KiteBrowserTests.result = null;
    lines.length = 0;
    let failure;
    try {
      if (hidden) {
        assert(document.hidden && visibility().hiddenForMs >= 305000, "page hidden past five minutes before nested spawn");
        await nestedProbe(true);
      } else {
        modelProbe();
        await locksProbe();
        await storeProbe();
        await nestedProbe(false);
        await interruptedWriteProbe();
      }
      assert(root.kiteBrowserErrors.length === 0, "no uncaught browser errors");
    } catch (error) { failure = String(error.stack || error); }
    try { await cleanup(); }
    catch (error) { failure = failure || String(error.stack || error); }
    root.KiteBrowserTests.result = { ok: !failure, lines: [...lines], error: failure };
  }

  root.KiteBrowserTests = { result: null, tabResult: null, visibility,
    setupTabInterruption: protectedProbe(setupTabInterruption),
    prepareTabWriter: protectedProbe(prepareTabWriter),
    queueTabSuccessor: protectedProbe(queueTabSuccessor),
    startTabWrite: protectedProbe(startTabWrite),
    finishTabInterruption: protectedProbe(async () => { await cleanup(); return { ok: true }; }),
    run: () => { void execute(false); },
    runHidden: () => { void execute(true); } };
})(globalThis);
