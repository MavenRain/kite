import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const [modelSource, hostSource, controlSource, podSource] = await Promise.all([
  '../_build/default/browser/model.bc.js', '../browser/node-host.js',
  '../browser/control.js', '../browser/pod.js'
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
    nodeRequests: 0, releases: [], readStarted: deferred(), placedStarted: deferred(),
    openStarted: deferred(), ...options };
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
  const store = {
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
      if (epoch !== state.epoch) return { ok: false, error: 'stale_epoch' };
      if (expectedSeq !== undefined && expectedSeq !== state.seq)
        return { ok: false, error: 'stale_sequence' };
      f.writes.push({ payload, expectedSeq });
      return record(epoch, payload);
    },
    close() { f.closes += 1; return { ok: true }; }
  };
  const glue = {
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
    importScripts() {}, self: {}, console,
    setTimeout(callback, delay) { f.timers.push({ callback, delay }); } };
  vm.createContext(world);
  for (const source of [modelSource, hostSource, controlSource]) vm.runInContext(source, world);
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
  await f.request('close');
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
  assert.equal(f.messages.find(message => message.kind === 'tick').value, 1);
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
