import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../browser/glue.js', import.meta.url), 'utf8');
function load(globals = {}) {
  const context = vm.createContext(globals);
  vm.runInContext(source, context);
  return context.KiteGlue;
}
const plain = value => JSON.parse(JSON.stringify(value));
const tick = () => new Promise(resolve => setImmediate(resolve));

test('messaging and worker boundaries return browser refusals', () => {
  let message;
  let killed = false;
  const glue = load({ Worker: class {
    constructor(url, options) {
      assert.equal(url, 'worker.js');
      assert.equal(options.type, 'classic');
    }
    terminate() { killed = true; }
  } });
  const spawned = glue.spawn('worker.js', value => { message = value; }, () => {});
  assert.equal(spawned.ok, true);
  spawned.value.onmessage({ data: 42 });
  assert.equal(message, 42);
  assert.equal(glue.kill(spawned.value).ok, true);
  assert.equal(killed, true);
  const refusal = glue.send({ postMessage() {
    throw new DOMException('uncloneable', 'DataCloneError');
  } }, {});
  assert.deepEqual(plain(refusal), { ok: false, error: 'DataCloneError' });
});

test('lock delivery precedes completion and release waits for completion', async () => {
  let finishRequest;
  let calls = 0;
  const glue = load({ navigator: { locks: {
    async request(name, options, callback) {
      calls += 1;
      assert.equal(name, 'node');
      assert.equal(options.ifAvailable, true);
      await callback({ name });
      await new Promise(resolve => { finishRequest = resolve; });
    }
  } } });
  const acquired = await glue.lock('node');
  assert.equal(acquired.ok, true);
  const pending = acquired.value.release();
  assert.equal(acquired.value.release(), pending);
  let released = false;
  pending.then(() => { released = true; });
  await tick();
  assert.equal(released, false);
  finishRequest();
  assert.equal((await pending).ok, true);
  const next = await glue.lock('node');
  acquired.value.release();
  assert.equal(calls, 2);
  let nextReleased = false;
  const nextPending = next.value.release().then(() => { nextReleased = true; });
  await tick();
  assert.equal(nextReleased, false);
  finishRequest();
  await nextPending;
});

test('lock busy, rejected, throwing, and aborted requests are explicit', async () => {
  const busy = load({ navigator: { locks: {
    request(name, options, callback) { return Promise.resolve(callback(null)); }
  } } });
  assert.deepEqual(plain(await busy.lock('busy')), { ok: true, value: null });
  for (const request of [
    () => Promise.reject(new DOMException('refused', 'SecurityError')),
    () => { throw new DOMException('refused', 'SecurityError'); }
  ]) {
    const glue = load({ navigator: { locks: { request } } });
    assert.deepEqual(plain(await glue.lock('denied')), {
      ok: false, error: 'SecurityError'
    });
  }
  assert.deepEqual(plain(await busy.lock('aborted', { signal: { aborted: true } })), {
    ok: false, error: 'AbortError'
  });
});

test('open reports blocking once and closes a late connection', async () => {
  const request = {};
  let closed = 0;
  const glue = load({ indexedDB: { open() { return request; } } });
  const pending = glue.open('db');
  request.onblocked();
  assert.deepEqual(plain(await pending), { ok: false, error: 'open_blocked' });
  request.result = { close() { closed += 1; } };
  request.onsuccess();
  assert.equal(closed, 1);
  request.result.onversionchange();
  assert.equal(closed, 2);
});

function fakeStore() {
  const transactions = [];
  const request = {};
  const db = {
    transaction(names, mode) {
      const tx = { mode, requests: [], writes: [], error: null };
      tx.objectStore = name => ({
        get() {
          const request = {};
          tx.requests.push(request);
          return request;
        },
        getAll() {
          const request = {};
          tx.requests.push(request);
          return request;
        },
        put(value) { tx.writes.push({ name, value }); },
        add(value) {
          if (tx.refuseWrite) throw new DOMException('quota', 'QuotaExceededError');
          tx.writes.push({ name, value });
        }
      });
      tx.abort = () => { queueMicrotask(() => tx.onabort()); };
      transactions.push(tx);
      return tx;
    },
    close() {}
  };
  const glue = load({ indexedDB: { open() { return request; } } });
  const pending = glue.open('db');
  request.result = db;
  request.onsuccess();
  return { pending: pending.then(result => result.value), transactions };
}

test('write success waits for transaction commit and fences stale epochs', async () => {
  const fake = fakeStore();
  const store = await fake.pending;
  const pending = store.claim(0, 'tab-a');
  const tx = fake.transactions[0];
  tx.requests[0].result = { epoch: 0, seq: 0, owner: null };
  tx.requests[0].onsuccess();
  assert.equal(tx.writes.length, 2);
  let settled = false;
  pending.then(() => { settled = true; });
  await tick();
  assert.equal(settled, false);
  tx.oncomplete();
  assert.deepEqual(plain(await pending), { ok: true, value: { epoch: 1, seq: 1 } });
  const stale = store.append(0, 'stale');
  const staleTx = fake.transactions[1];
  staleTx.requests[0].result = { epoch: 1, seq: 1, owner: 'tab-a' };
  staleTx.requests[0].onsuccess();
  assert.deepEqual(plain(await stale), { ok: false, error: 'stale_epoch' });
  assert.equal(staleTx.writes.length, 0);
});

test('browser write refusal aborts the transaction and counters are bounded', async () => {
  const fake = fakeStore();
  const store = await fake.pending;
  const pending = store.append(1, 'payload');
  const tx = fake.transactions[0];
  tx.refuseWrite = true;
  tx.requests[0].result = { epoch: 1, seq: 1, owner: 'tab-a' };
  tx.requests[0].onsuccess();
  assert.deepEqual(plain(await pending), { ok: false, error: 'QuotaExceededError' });
  for (const epoch of [-1, 0.5, NaN, Infinity, 1000000001]) {
    assert.deepEqual(plain(await store.append(epoch, 'invalid')), {
      ok: false, error: 'invalid_epoch'
    });
  }
  const exhausted = store.append(1, 'overflow');
  const exhaustedTx = fake.transactions[1];
  exhaustedTx.requests[0].result = { epoch: 1, seq: 1000000000, owner: 'tab-a' };
  exhaustedTx.requests[0].onsuccess();
  assert.deepEqual(plain(await exhausted), { ok: false, error: 'counter_exhausted' });
  assert.equal(exhaustedTx.writes.length, 0);
});

test('read waits for the entire readonly transaction to complete', async () => {
  const fake = fakeStore();
  const store = await fake.pending;
  const pending = store.read();
  const tx = fake.transactions[0];
  tx.requests[0].result = { epoch: 1, seq: 1, owner: 'tab-a' };
  tx.requests[0].onsuccess();
  tx.requests[1].result = [{ epoch: 1, seq: 1, payload: 'entry' }];
  tx.requests[1].onsuccess();
  let settled = false;
  pending.then(() => { settled = true; });
  await tick();
  assert.equal(settled, false);
  tx.oncomplete();
  assert.deepEqual(plain(await pending), { ok: true, value: {
    epoch: 1, seq: 1, owner: 'tab-a', entries: [{ epoch: 1, seq: 1, payload: 'entry' }]
  } });
});

test('optional sequence fence rejects stale plans without enqueuing writes', async () => {
  const fake = fakeStore();
  const store = await fake.pending;
  const stale = store.append(1, 'command', 2);
  const tx = fake.transactions[0];
  tx.requests[0].result = { epoch: 1, seq: 3, owner: 'tab-a' };
  tx.requests[0].onsuccess();
  assert.deepEqual(plain(await stale), { ok: false, error: 'stale_sequence' });
  assert.equal(tx.writes.length, 0);
  for (const seq of [-1, 0.5, NaN, Infinity, 1000000001]) {
    assert.deepEqual(plain(await store.append(1, 'invalid', seq)), {
      ok: false, error: 'invalid_sequence'
    });
  }
  const fresh = store.append(1, 'command', 3);
  const freshTx = fake.transactions[1];
  freshTx.requests[0].result = { epoch: 1, seq: 3, owner: 'tab-a' };
  freshTx.requests[0].onsuccess();
  freshTx.oncomplete();
  assert.deepEqual(plain(await fresh), { ok: true, value: { epoch: 1, seq: 4 } });
});
