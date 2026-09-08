import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const [modelSource, hostSource, controlSource, podSource, durableSource] = await Promise.all([
  '../_build/default/browser/model.bc.js', '../browser/node-host.js',
  '../browser/control.js', '../browser/pod.js',
  '../browser/durable.js'
].map(path => readFile(new URL(path, import.meta.url), 'utf8')));
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
async function until(predicate) {
  for (let turn = 0; turn < 100; turn += 1) {
    if (await predicate()) return;
    await tick();
  }
  assert.fail('expected asynchronous result did not arrive');
}

// Only the browser effects are simulated. The compiled OCaml model and the
// production node adapter, control loop and request dispatch execute unchanged.
function control(options = {}) {
  const f = { replies: [], timers: [], workers: [], held: new Map(),
    elections: [], claims: [], writes: [], opens: 0, closes: 0,
    nodeRequests: 0, now: 1700000100000, releases: [], readStarted: deferred(), placedStarted: deferred(),
    openStarted: deferred(), heartbeatStarted: deferred(), atomicStarted: deferred(), ...options };
  let listener;
  let nextId = 0;
  const state = { epoch: 1, seq: 0, owner: 'previous', entries: [] };
  function record(epoch, payload) {
    state.seq += 1;
    state.entries.push({ seq: state.seq, epoch, payload });
    return { ok: true, value: { epoch, seq: state.seq } };
  }
  for (const payload of options.entries || [{ kind: 'desired', count: 1 }])
    record(state.epoch, payload);
  function lease(name) {
    const value = { release: async () => {
      if (f.held.get(name) === value) f.held.delete(name);
      f.releases.push(name);
      return { ok: true };
    } };
    f.held.set(name, value);
    return value;
  }
  const snapshotOf = read => read.all ? structuredClone(state.entries)
    : read.store === 'meta' && read.key === 'state'
      ? {epoch: state.epoch, seq: state.seq, owner: state.owner} : f.manifest;
  const applyWrite = write => {
    if (write.store === 'log') state.entries.push(write.value);
    else if (write.key === 'manifest') f.manifest = write.value;
    else { state.epoch = write.value.epoch; state.seq = write.value.seq; }
  };
  const store = {
    async atomic({reads = [], plan}) {
      if (f.atomicGate) {
        const gate = f.atomicGate;
        f.atomicGate = undefined;
        f.atomicStarted.resolve();
        await gate.promise;
      }
      const result = plan(Object.fromEntries(reads.map(read => [read.as, snapshotOf(read)])));
      if (!result.ok) return result;
      (result.value.writes || []).forEach(applyWrite);
      return {ok: true, value: result.value.receipt};
    },
    async read() {
      const snapshot = structuredClone(state);
      if (f.readGate) {
        const gate = f.readGate;
        f.readGate = undefined;
        f.readStarted.resolve();
        await gate.promise;
      }
      return { ok: true, value: snapshot };
    },
    claim(epoch, owner) {
      const gate = deferred();
      f.claims.push({ resolve() {
        if (epoch !== state.epoch) gate.resolve({ ok: false, error: 'stale_epoch' });
        else {
          state.epoch += 1;
          state.owner = owner;
          gate.resolve(record(state.epoch, { kind: 'leader', owner }));
        }
      } });
      return gate.promise;
    },
    async append(epoch, payload, expectedSeq) {
      if (payload.kind === 'placed' && f.placedGate) {
        f.placedStarted.resolve();
        await f.placedGate.promise;
      }
      if (payload.kind === 'heartbeat' && f.heartbeatGate) {
        const gate = f.heartbeatGate;
        f.heartbeatGate = undefined;
        f.heartbeatStarted.resolve();
        await gate.promise;
      }
      if (epoch !== state.epoch) return { ok: false, error: 'stale_epoch' };
      if (expectedSeq !== undefined && expectedSeq !== state.seq)
        return { ok: false, error: 'stale_sequence' };
      f.writes.push({ payload, expectedSeq });
      return record(epoch, payload);
    },
    close() { f.closes += 1; return { ok: true }; }
  };
  const glue = {
    doorbell() { return {ok: false, error: 'unavailable'}; },
    async open() {
      f.opens += 1;
      f.openStarted.resolve();
      if (f.openGate) await f.openGate.promise;
      return { ok: true, value: store };
    },
    listen(callback) { listener = callback; },
    send(target, message) {
      if (f.workers.includes(target)) target.sent.push(message);
      else f.replies.push(message);
      return { ok: true };
    },
    lock(name, { signal } = {}) {
      if (name.endsWith(':leader')) {
        const gate = deferred();
        f.elections.push({ grant: () => gate.resolve({ ok: true, value: lease(name) }) });
        signal.addEventListener('abort', () => gate.resolve({ ok: false, error: 'AbortError' }));
        return gate.promise;
      }
      if (name.includes(':node:')) {
        f.nodeRequests += 1;
        if (f.failFirstNode && f.nodeRequests === 1)
          return Promise.resolve({ ok: true, value: null });
        if (f.nodeGate) {
          const gate = f.nodeGate;
          f.nodeGate = undefined;
          return gate.promise.then(() => ({ ok: true,
            value: f.held.has(name) ? null : lease(name) }));
        }
      }
      return Promise.resolve({ ok: true, value: f.held.has(name) ? null : lease(name) });
    },
    async locks() {
      if (f.changeDuringLocks) {
        f.changeDuringLocks = false;
        record(state.epoch, { kind: 'desired', count: 0 });
      }
      return { ok: true, value: [...f.held.keys()] };
    },
    spawn(url, onMessage, onError) {
      const worker = { url, onMessage, onError, sent: [], killed: false };
      f.workers.push(worker);
      return { ok: true, value: worker };
    },
    kill(worker) { worker.killed = true; return { ok: true }; }
  };
  const world = { KiteGlue: glue, TextDecoder, TextEncoder, AbortController,
    Date: class extends Date { static now() { return f.now; } },
    importScripts() {}, self: {}, console,
    setTimeout(callback, delay) { f.timers.push({ callback, delay }); } };
  vm.createContext(world);
  for (const source of [modelSource, durableSource, hostSource, controlSource])
    vm.runInContext(source, world);
  f.send = (op, args = {}) => {
    const id = ++nextId;
    listener({ id, op, ...args });
    return id;
  };
  f.response = async id => {
    await until(() => f.replies.some(reply => reply.id === id));
    return f.replies.find(reply => reply.id === id);
  };
  f.request = (op, args) => f.response(f.send(op, args));
  f.log = () => structuredClone(state.entries);
  f.boot = () => f.request('boot', { cluster: 'test', nodeId: 'a' });
  f.runLoop = async () => {
    await until(() => f.timers.some(timer => timer.delay === 250));
    const index = f.timers.findIndex(timer => timer.delay === 250);
    return f.timers.splice(index, 1)[0].callback();
  };
  return f;
}

test('failed boot retries, concurrent duplicate boot opens one host, close disconnects', async () => {
  const f = control({ failFirstNode: true });
  assert.equal((await f.boot()).error, 'node_lock_busy');
  assert.equal(f.closes, 1);
  const first = f.send('boot', { cluster: 'test', nodeId: 'a' });
  const second = f.send('boot', { cluster: 'test', nodeId: 'a' });
  assert.equal((await f.response(first)).ok, true);
  assert.equal((await f.response(second)).error, 'already_booted');
  assert.equal(f.opens, 2);
  assert.equal((await f.request('close')).ok, true);
  assert.equal(f.closes, 2);
  assert.equal((await f.request('resume')).error, 'closed');
});

test('malformed boot is refused before opening and close cancels a pending open', async () => {
  const gate = deferred();
  const f = control({ openGate: gate });
  assert.equal((await f.request('boot', { cluster: ['test'], nodeId: 'a' })).error, 'invalid_cluster');
  assert.equal((await f.request('boot', { cluster: 'test', nodeId: null })).error, 'invalid_node');
  assert.equal(f.opens, 0);
  const boot = f.boot();
  await f.openStarted.promise;
  assert.equal((await f.request('close')).ok, true);
  gate.resolve();
  assert.equal((await boot).error, 'lifecycle_changed');
  assert.equal(f.closes, 1);
  assert.equal(f.nodeRequests, 0);
});

test('a claim completed after freeze cannot install leadership after resume', async () => {
  const f = control();
  assert.equal((await f.boot()).ok, true);
  f.elections[0].grant();
  await until(() => f.claims.length === 1);
  const frozen = f.request('freeze');
  const resumed = f.request('resume');
  assert.equal((await f.request('view')).value.node.mode, 'frozen');
  f.claims[0].resolve();
  assert.equal((await frozen).ok, true);
  assert.equal((await resumed).ok, true);
  const view = (await f.request('view')).value;
  assert.equal(view.leaderEpoch, 0);
  assert.equal(view.node.incarnation, 2);
  assert.equal(f.releases.filter(name => name.endsWith(':leader')).length, 1);
  await f.request('close');
});

test('a reconcile snapshot taken before an epoch claim retains the newly adopted leader', async () => {
  const f = control();
  assert.equal((await f.boot()).ok, true);
  await until(() => f.writes.some(write => write.payload.kind === 'heartbeat'));
  f.elections[0].grant();
  await until(() => f.claims.length === 1);
  const read = deferred();
  f.readGate = read;
  const reconciliation = f.runLoop();
  await f.readStarted.promise;
  f.claims[0].resolve();
  await until(async () => (await f.request('view')).value.leaderEpoch === 2);
  read.resolve();
  await reconciliation;
  assert.equal((await f.request('view')).value.leaderEpoch, 2);
  assert.equal(f.releases.filter(name => name.endsWith(':leader')).length, 0);
  assert.equal(f.elections.length, 1);
  await f.request('close');
});

test('a resume during an open heartbeat append republishes the new incarnation', async () => {
  const f = control();
  assert.equal((await f.boot()).ok, true);
  await until(() => f.writes.some(write => write.payload.kind === 'heartbeat'));
  f.now += 1000;
  const gate = deferred();
  f.heartbeatGate = gate;
  const cycle = f.runLoop();
  await f.heartbeatStarted.promise;
  assert.equal((await f.request('freeze')).ok, true);
  assert.equal((await f.request('resume')).ok, true);
  gate.resolve();
  await cycle;
  await f.runLoop();
  assert.equal(f.writes.some(write => write.payload.kind === 'heartbeat' &&
    write.payload.incarnation === 2), true);
  await f.request('close');
});

test('a desired count written across an epoch claim is retried, not discarded', async () => {
  const f = control();
  assert.equal((await f.boot()).ok, true);
  await until(() => f.writes.some(write => write.payload.kind === 'heartbeat'));
  f.elections[0].grant();
  await until(() => f.claims.length === 1);
  const read = deferred();
  f.readGate = read;
  const desired = f.request('desired', { count: 3 });
  await f.readStarted.promise;
  f.claims[0].resolve();
  await until(async () => (await f.request('view')).value.leaderEpoch === 2);
  read.resolve();
  assert.equal((await desired).ok, true);
  assert.equal(f.writes.some(write => write.payload.kind === 'desired' &&
    write.payload.count === 3), true);
  await f.request('close');
});

test('a malformed request is refused with its own correlation id', async () => {
  const f = control();
  assert.equal((await f.request(5)).error, 'invalid_request');
  assert.equal((await f.request('boot')).error, 'invalid_cluster');
});

test('a later freeze cancels a resume waiting for an earlier freeze', async () => {
  const f = control();
  assert.equal((await f.boot()).ok, true);
  f.elections[0].grant();
  await until(() => f.claims.length === 1);
  const firstFreeze = f.request('freeze');
  const resume = f.request('resume');
  const lastFreeze = f.request('freeze');
  f.claims[0].resolve();
  assert.equal((await firstFreeze).ok, true);
  assert.equal((await lastFreeze).ok, true);
  assert.equal((await resume).error, 'lifecycle_changed');
  const view = (await f.request('view')).value.node;
  assert.equal(view.mode, 'frozen');
  assert.equal(view.nodeLock, false);
  assert.equal(f.nodeRequests, 1);
  await f.request('close');
});

test('a freeze invalidates a resume waiting for its node lease', async () => {
  const f = control();
  assert.equal((await f.boot()).ok, true);
  assert.equal((await f.request('freeze')).ok, true);
  const node = deferred();
  f.nodeGate = node;
  const resumed = f.request('resume');
  await until(() => f.nodeRequests === 2);
  assert.equal((await f.request('freeze')).ok, true);
  node.resolve();
  assert.equal((await resumed).error, 'lifecycle_changed');
  const view = (await f.request('view')).value.node;
  assert.equal(view.mode, 'frozen');
  assert.equal(view.nodeLock, false);
  assert.equal(f.held.has('kite:test:node:a'), false);
  await f.request('close');
});

test('concurrent resumes share their pending node acquisition', async () => {
  const f = control();
  assert.equal((await f.boot()).ok, true);
  assert.equal((await f.request('freeze')).ok, true);
  const node = deferred();
  f.nodeGate = node;
  const first = f.request('resume');
  await until(() => f.nodeRequests === 2);
  const second = f.send('resume');
  await tick();
  assert.equal(f.replies.some(reply => reply.id === second), false);
  node.resolve();
  assert.equal((await first).ok, true);
  assert.equal((await f.response(second)).ok, true);
  const view = (await f.request('view')).value.node;
  assert.equal(view.incarnation, 2);
  assert.equal(view.nodeLock, true);
  assert.equal(f.nodeRequests, 2);
  await f.request('close');
});

test('freeze and close bypass unresolved reconciliation and publication', async () => {
  const placed = deferred();
  const read = deferred();
  const f = control({ placedGate: placed, entries: [
    { kind: 'desired', count: 1 },
    { kind: 'command', command: { kind: 'start', pod: 0, owner: 'a', incarnation: 1 } }
  ] });
  assert.equal((await f.boot()).ok, true);
  await until(() => f.workers.length === 1);
  const worker = f.workers[0];
  const publication = worker.onMessage({ kind: 'pod_lock', granted: true });
  await f.placedStarted.promise;
  f.readGate = read;
  const reconciliation = f.runLoop();
  await f.readStarted.promise;
  assert.equal((await f.request('freeze')).ok, true);
  assert.equal((await f.request('view')).value.node.mode, 'frozen');
  assert.equal((await f.request('resume')).ok, true);
  assert.equal((await f.request('close')).ok, true);
  assert.equal(f.closes, 1);
  assert.equal(worker.killed, true);
  assert.equal(worker.sent.some(message => message.kind === 'begin'), false);
  read.resolve();
  placed.resolve();
  await Promise.all([reconciliation, publication]);
  assert.equal(worker.sent.some(message => message.kind === 'begin'), false);
});

test('same-epoch desired changes between snapshot and append refuse the plan', async () => {
  const f = control();
  assert.equal((await f.boot()).ok, true);
  f.elections[0].grant();
  await until(() => f.claims.length === 1);
  f.claims[0].resolve();
  await until(async () => (await f.request('view')).value.leaderEpoch === 2);
  f.changeDuringLocks = true;
  await f.runLoop();
  assert.equal(f.replies.some(reply => reply.kind === 'diagnostic' && reply.error === 'stale_sequence'), true);
  assert.equal(f.writes.some(write => write.payload.kind === 'command'), false);
  await f.request('close');
});

test('replay does not start a pod removed by a later desired record', async () => {
  const f = control({ entries: [
    { kind: 'desired', count: 1 },
    { kind: 'command', command: { kind: 'start', pod: 0, owner: 'a', incarnation: 1 } },
    { kind: 'desired', count: 0 }
  ] });
  assert.equal((await f.boot()).ok, true);
  await f.runLoop();
  assert.equal(f.workers.length, 0);
  const view = (await f.request('view')).value;
  assert.ok(view.cursor >= 3);
  assert.equal(view.duplicateRefusals.count, 0);
  assert.equal(view.duplicateRefusals.last, null);
  await f.request('close');
});

test('manifest admission requires fresh visibility and enforces its bound and namespace', async () => {
  const f = control();
  const manifest = {kind: 'deployment', name: 'web', replicas: 1, bound: 2,
    tolerateHidden: false};
  assert.equal((await f.request('boot', {cluster: 'test', nodeId: 'a',
    manifest: {...manifest, replicas: 3}})).error, 'invalid_manifest_replicas');
  assert.equal(f.opens, 0);
  assert.equal((await f.request('boot', {cluster: 'test', nodeId: 'a', manifest})).ok, true);
  assert.ok(f.held.has('kite:test:workload:web:node:a'));
  f.elections[0].grant();
  await until(() => f.claims.length === 1);
  f.claims[0].resolve();
  await until(async () => (await f.request('view')).value.leaderEpoch === 2);
  await f.runLoop();
  assert.equal((await f.request('view')).value.planning.plan.error, 'Admit_denied:no_eligible_nodes');
  assert.equal(f.writes.some(write => write.payload.kind === 'command'), false);
  assert.equal((await f.request('desired', {count: 3})).error, 'invalid_desired');
  // The stored bound is inclusive, so the count at the bound is accepted.
  assert.equal((await f.request('desired', {count: 2})).ok, true);
  assert.equal(f.writes.some(write => write.payload.kind === 'desired' &&
    write.payload.count === 2), true);
  assert.equal((await f.request('visibility', {observation: {
    incarnation: 1, sequence: 1, visibility: 'hidden'}})).ok, true);
  await f.runLoop();
  assert.equal((await f.request('view')).value.planning.plan.error, 'Admit_denied:no_eligible_nodes');
  assert.equal((await f.request('visibility', {observation: {
    incarnation: 1, sequence: 2, visibility: 'visible'}})).ok, true);
  await f.runLoop();
  assert.equal(f.writes.some(write => write.payload.kind === 'command'), true);
  assert.equal((await f.request('freeze')).ok, true);
  assert.equal((await f.request('resume')).ok, true);
  assert.equal((await f.request('visibility', {observation: {
    incarnation: 1, sequence: 3, visibility: 'visible'}})).error, 'stale_observation');
  assert.equal((await f.request('view')).value.observation, undefined);
  await f.request('close');
});

test('every stored contract field refuses a conflicting join before node acquisition', async () => {
  const manifest = {kind: 'deployment', name: 'web', replicas: 1, bound: 2,
    tolerateHidden: true};
  // Each clause of the stored contract refuses on its own.
  for (const change of [{kind: 'stateful_set'}, {replicas: 0}, {bound: 3},
    {tolerateHidden: false}]) {
    const f = control({manifest});
    const joined = await f.request('boot', {cluster: 'test', nodeId: 'a',
      manifest: {...manifest, ...change}, visibility: 'visible'});
    assert.equal(joined.error, 'manifest_conflict', JSON.stringify(change));
    assert.equal(f.nodeRequests, 0);
    assert.equal(f.closes, 1);
    assert.deepEqual(f.manifest, manifest);
    assert.equal((await f.request('close')).ok, true);
    assert.equal(f.closes, 1);
  }
});

test('a service send committed while close clears the feed keeps its receipt', async () => {
  const manifest = {kind: 'deployment', name: 'web', replicas: 1, bound: 2,
    tolerateHidden: true};
  const f = control();
  assert.equal((await f.request('boot', {cluster: 'test', nodeId: 'a', manifest,
    visibility: 'visible'})).ok, true);
  const gate = deferred();
  f.atomicGate = gate;
  const sent = f.request('service', {epoch: 1, event: {kind: 'register', name: 'api'}});
  await f.atomicStarted.promise;
  assert.equal((await f.request('close')).ok, true);
  gate.resolve();
  const reply = await sent;
  assert.equal(reply.ok, true, reply.error);
  assert.deepEqual(f.replies.filter(reply => reply.kind === 'diagnostic'), []);
  const records = f.log().filter(entry => entry.payload.kind === 'service');
  assert.equal(records.length, 1);
  assert.equal(reply.value.seq, records[0].seq);
  assert.deepEqual(records[0].payload.event, {kind: 'register', name: 'api'});
});

function pod(options = {}) {
  let listener;
  let calls = 0;
  const f = { messages: [], timers: [], releases: 0 };
  const glue = {
    listen(callback) { listener = callback; },
    async lock() {
      calls += 1;
      return { ok: true, value: options.deny && calls === 2 ? null : {
        async release() { f.releases += 1; return { ok: true }; }
      } };
    },
    send(target, message) {
      f.messages.push(message);
      if (message.kind === 'pod_lock' && message.granted) listener({ kind: 'begin' });
      return { ok: true };
    }
  };
  const world = { KiteGlue: glue, importScripts() {}, self: {}, Uint8Array,
    WebAssembly: options.wasm || WebAssembly,
    setTimeout(callback) { f.timers.push(callback); } };
  vm.createContext(world);
  vm.runInContext(podSource, world);
  f.send = message => listener(message);
  f.init = () => listener({ kind: 'init', pod: 0, lifeLock: 'life', podLock: 'pod' });
  return f;
}

test('real Wasm starts once when begin arrives before compilation completes', async () => {
  const f = pod();
  f.send(null);
  f.init();
  await until(() => f.messages.some(message => message.kind === 'tick'));
  assert.equal(f.messages.find(message => message.kind === 'tick').value, -1734620768);
  assert.equal(f.timers.length, 1);
  f.send({ kind: 'begin' });
  f.init();
  await tick();
  assert.equal(f.timers.length, 1);
});

test('pod lock refusal and Wasm startup failure release acquired leases', async () => {
  const denied = pod({ deny: true });
  denied.init();
  await until(() => denied.releases === 1);
  assert.equal(denied.messages.find(message => message.kind === 'pod_lock').granted, false);
  const failed = pod({ wasm: { instantiate: () => Promise.reject(new Error('unsupported')) } });
  failed.init();
  await until(() => failed.messages.some(message => message.kind === 'failed'));
  assert.equal(failed.releases, 2);
  assert.equal(failed.timers.length, 0);
});
