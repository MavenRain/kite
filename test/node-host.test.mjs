import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const { KiteModel } = require('../_build/default/browser/model.bc.js');
const source = await readFile(new URL('../browser/node-host.js', import.meta.url), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
function fixture() {
  const timers = [];
  const held = new Set();
  const nativeWorkers = [];
  const sent = [];
  const appended = [];
  const released = [];
  const settings = {};
  let seq = 0;
  function lease(name) {
    held.add(name);
    let pending;
    return { release() {
      if (!pending) {
        released.push(name);
        held.delete(name);
        pending = Promise.resolve({ok: true});
      }
      return pending;
    } };
  }
  const glue = {
    async lock(name) {
      if (settings.nodeFailure && name.includes(':node:')) return settings.nodeFailure;
      if (settings.node && name.includes(':node:')) {
        const wait = settings.node;
        settings.node = null;
        wait.name = name;
        return wait.promise;
      }
      if (settings.place && name.includes(':place:')) {
        const wait = settings.place;
        settings.place = null;
        wait.name = name;
        return wait.promise;
      }
      return {ok: true, value: lease(name)};
    },
    spawn(url, onMessage, onError) {
      if (settings.spawnFailure) return {ok: false, error: 'SecurityError'};
      const native = {onMessage, onError, kills: 0};
      nativeWorkers.push(native);
      return {ok: true, value: native};
    },
    send(native, message) {
      sent.push({native, message});
      if (message.kind === 'init') native.lifeLock = message.lifeLock;
      return settings.sendFailure === message.kind
        ? {ok: false, error: 'DataCloneError'} : {ok: true};
    },
    kill(native) {
      if (settings.killFailure) return {ok: false, error: 'InvalidStateError'};
      native.kills += 1;
      if (!settings.holdLife) held.delete(native.lifeLock);
      return {ok: true};
    },
    async locks() {
      return settings.queryFailure || {ok: true, value: [...held]};
    }
  };
  const context = vm.createContext({setTimeout(callback) { timers.push(callback); }});
  vm.runInContext(source, context);
  const host = new context.KiteNode(KiteModel, glue, {
    nodeId: 'test-node', prefix: 'test', podUrl: 'pod.js', onTick() {},
    async append(epoch, payload) {
      appended.push({epoch, payload});
      if (settings.append) {
        const wait = settings.append;
        settings.append = null;
        return wait.promise;
      }
      return {ok: true, value: {epoch, seq: ++seq}};
    }
  });
  async function start(pod = 0) {
    const view = host.view();
    const started = await host.event({kind: 'start', pod,
      epoch: view.epoch, incarnation: view.incarnation});
    assert.equal(started.ok, true);
    return [...host.workers.values()].find(handle => handle.worker.pod === pod);
  }
  async function ready() {
    assert.equal((await host.boot()).ok, true);
    assert.equal((await host.event({kind: 'observe_epoch', epoch: 1})).ok, true);
  }
  const grant = handle => host.message(handle, {kind: 'pod_lock', granted: true});
  const began = native => sent.some(item => item.native === native && item.message.kind === 'begin');
  return {host, settings, held, nativeWorkers, sent, appended, released, timers,
    lease, ready, start, grant, began};
}

test('a delayed placement grant after Freeze is released without publication or Begin', async () => {
  const f = fixture();
  await f.ready();
  const handle = await f.start();
  const wait = deferred();
  f.settings.place = wait;
  const publishing = f.grant(handle);
  await tick();
  await f.host.event({kind: 'freeze'});
  wait.resolve({ok: true, value: f.lease(wait.name)});
  await publishing;
  assert.equal(f.appended.length, 0);
  assert.equal(f.held.has(wait.name), false);
  assert.equal(f.began(handle.native), false);
  assert.equal(f.host.view().workers.length, 0);
});

test('a delayed placement grant after an epoch change cannot Begin', async () => {
  const f = fixture();
  await f.ready();
  const handle = await f.start();
  const wait = deferred();
  f.settings.place = wait;
  const publishing = f.grant(handle);
  await tick();
  await f.host.event({kind: 'observe_epoch', epoch: 2});
  wait.resolve({ok: true, value: f.lease(wait.name)});
  await publishing;
  assert.equal(f.appended.length, 0);
  assert.equal(f.held.has(wait.name), false);
  assert.equal(f.began(handle.native), false);
  assert.equal(f.host.view().workers.length, 0);
});

test('old placement continuations cannot stop a replacement ticket', async () => {
  const f = fixture();
  await f.ready();
  const old = await f.start();
  const wait = deferred();
  f.settings.place = wait;
  const publishing = f.grant(old);
  await tick();
  await f.host.stop(old.worker);
  const replacement = await f.start();
  assert.notEqual(old.worker.ticket, replacement.worker.ticket);
  wait.resolve({ok: true, value: f.lease(wait.name)});
  await publishing;
  await old.native.onError('late error');
  await old.native.onMessage({kind: 'failed'});
  assert.equal(f.host.view().workers.length, 1);
  assert.equal(f.host.view().workers[0].ticket, replacement.worker.ticket);
  assert.equal(f.host.view().workers[0].phase, 'starting');
  assert.equal(replacement.native.kills, 0);
});

for (const cancellation of ['freeze', 'epoch', 'replace']) {
  test(`append completion after ${cancellation} cannot Begin or stop a later ticket`, async () => {
    const f = fixture();
    await f.ready();
    const old = await f.start();
    const wait = deferred();
    f.settings.append = wait;
    const publishing = f.grant(old);
    await tick();
    assert.equal(f.appended.length, 1);
    let replacement;
    if (cancellation === 'freeze') await f.host.event({kind: 'freeze'});
    if (cancellation === 'epoch') await f.host.event({kind: 'observe_epoch', epoch: 2});
    if (cancellation === 'replace') {
      await f.host.stop(old.worker);
      replacement = await f.start();
    }
    wait.resolve({ok: true, value: {epoch: 1, seq: 1}});
    await publishing;
    assert.equal(f.began(old.native), false);
    assert.equal(old.native.kills, 1);
    if (replacement) {
      assert.equal(f.host.view().workers[0].ticket, replacement.worker.ticket);
      assert.equal(replacement.native.kills, 0);
    } else assert.equal(f.host.view().workers.length, 0);
  });
}

test('failed placement publication and failed Begin delivery terminate the worker', async () => {
  for (const failure of ['append', 'begin']) {
    const f = fixture();
    await f.ready();
    const handle = await f.start();
    if (failure === 'append') {
      f.settings.append = {promise: Promise.resolve({ok: false, error: 'stale_epoch'})};
    } else f.settings.sendFailure = 'begin';
    await f.grant(handle);
    if (failure === 'append') assert.equal(f.began(handle.native), false);
    assert.equal(handle.native.kills, 1);
    assert.equal(f.host.view().workers.length, 0);
    assert.equal([...f.held].some(name => name.includes(':place:')), false);
  }
});

test('spawn and init delivery failures leave no Starting worker', async () => {
  for (const failure of ['spawn', 'init']) {
    const f = fixture();
    await f.ready();
    if (failure === 'spawn') f.settings.spawnFailure = true;
    else f.settings.sendFailure = 'init';
    await f.start();
    assert.equal(f.host.view().workers.length, 0);
    assert.equal(f.host.workers.size, 0);
    if (failure === 'init') assert.equal(f.nativeWorkers[0].kills, 1);
  }
});

test('a killed worker retains its slot until its unique life lock disappears', async () => {
  const f = fixture();
  await f.ready();
  const handle = await f.start();
  f.held.add(handle.native.lifeLock);
  f.held.add('test:life:unrelated:99');
  f.settings.holdLife = true;
  await f.grant(handle);
  await f.host.stop(handle.worker);
  assert.equal(handle.native.kills, 1);
  assert.equal(f.host.view().workers[0].phase, 'stopping');
  const blocked = await f.host.event({kind: 'start', epoch: 1, pod: 0, incarnation: 1});
  assert.equal(blocked.ok, false);
  assert.equal(blocked.error, 'duplicate_pod');
  assert.equal(f.timers.length, 1);
  f.held.delete(handle.native.lifeLock);
  await f.timers.shift()();
  assert.equal(f.host.view().workers.length, 0);
  const replacement = await f.start();
  assert.notEqual(replacement.worker.ticket, handle.worker.ticket);
  assert.equal(f.held.has('test:life:unrelated:99'), true);
});

test('kill and lock-query refusals retain the occupied slot and report diagnostics', async () => {
  for (const failure of ['kill', 'query']) {
    const f = fixture();
    await f.ready();
    const handle = await f.start();
    if (failure === 'kill') f.settings.killFailure = true;
    else f.settings.queryFailure = {ok: false, error: 'SecurityError'};
    await f.host.stop(handle.worker);
    assert.equal(f.host.view().workers[0].phase, 'stopping');
    assert.equal(f.host.workers.size, 1);
    assert.equal(f.host.error, failure === 'kill' ? 'InvalidStateError' : 'SecurityError');
  }
});

test('node lock refusal preserves its browser diagnostic and malformed messages are values', async () => {
  const f = fixture();
  f.settings.nodeFailure = {ok: false, error: 'SecurityError'};
  const denied = await f.host.boot();
  assert.equal(denied.ok, false);
  assert.equal(denied.error, 'SecurityError');
  f.settings.nodeFailure = null;
  assert.equal((await f.host.event({kind: 'resume'})).ok, true);
  await f.host.event({kind: 'observe_epoch', epoch: 1});
  const handle = await f.start();
  for (const message of [null, undefined, 3, 'bad', []]) {
    const result = await f.host.message(handle, message);
    assert.equal(result.ok, false);
    assert.equal(result.error, 'invalid_worker_message');
  }
});

test('failed Resume acquisition is explicit and can retry from Frozen', async () => {
  for (const refusal of [{ok: false, error: 'SecurityError'}, {ok: true, value: null}]) {
    const f = fixture();
    await f.ready();
    await f.host.event({kind: 'freeze'});
    f.settings.nodeFailure = refusal;
    const failed = await f.host.event({kind: 'resume'});
    assert.equal(failed.ok, false);
    assert.equal(failed.error, refusal.ok ? 'node_lock_busy' : 'SecurityError');
    assert.equal(f.host.view().mode, 'frozen');
    assert.equal(f.host.view().nodeLock, false);
    f.settings.nodeFailure = null;
    const resumed = await f.host.event({kind: 'resume'});
    assert.equal(resumed.ok, true);
    assert.equal(f.host.view().incarnation, 3);
    assert.equal(f.host.view().mode, 'ready');
    assert.equal(f.host.view().nodeLock, true);
  }
});

test('a delayed old node acquisition cannot change the current generation', async () => {
  for (const granted of [false, true]) {
    const f = fixture();
    const wait = deferred();
    f.settings.node = wait;
    const booting = f.host.boot();
    await tick();
    await f.host.event({kind: 'freeze'});
    await f.host.event({kind: 'resume'});
    const currentLease = f.host.nodes.get(2);
    const lateLease = granted ? f.lease('late-node-generation') : null;
    wait.resolve(granted ? {ok: true, value: lateLease} : {ok: false, error: 'AbortError'});
    await booting;
    assert.equal(f.host.view().mode, 'ready');
    assert.equal(f.host.view().incarnation, 2);
    assert.equal(f.host.view().nodeLock, true);
    assert.equal(f.host.nodes.get(2), currentLease);
    assert.equal(f.host.nodes.has(1), false);
    assert.equal(f.held.has('late-node-generation'), false);
    assert.equal(f.host.error, null);
  }
});
