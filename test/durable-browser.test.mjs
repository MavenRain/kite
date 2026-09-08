import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const sources = await Promise.all(['glue.js', 'durable.js'].map(name =>
  readFile(new URL(`../browser/${name}`, import.meta.url), 'utf8')));
const modelSource = await readFile(
  new URL('../_build/default/browser/model.bc.js', import.meta.url), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
const tick = () => new Promise(done => setImmediate(done));
const ok = value => ({ok: true, value});
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise, resolve};
}

// One name at a time, and an unavailable name refuses an ifAvailable request.
function locking() {
  const held = new Set();
  return {held,
    request(name, options, callback) {
      if (held.has(name)) {
        return options && options.ifAvailable ? callback(null)
          : Promise.reject(new Error('wait_unsupported'));
      }
      held.add(name);
      return Promise.resolve(callback({name})).finally(() => held.delete(name));
    }};
}

async function fixture() {
  const opened = {};
  const transactions = [];
  const context = vm.createContext({queueMicrotask, navigator: {locks: locking()},
    indexedDB: {open: () => opened}});
  for (const source of sources) vm.runInContext(source, context);
  const pending = context.KiteGlue.open('test');
  opened.result = {
    transaction(names, mode) {
      const tx = {names, mode, requests: [], writes: [], error: null};
      tx.objectStore = store => ({
        get(key) { const request = {store, key}; tx.requests.push(request); return request; },
        getAll() { const request = {store}; tx.requests.push(request); return request; },
        put(value, key) { tx.writes.push({store, key, value}); },
        add(value) { tx.writes.push({store, value}); }
      });
      tx.abort = () => { tx.abortRequested = true; };
      transactions.push(tx);
      return tx;
    }, close() {}
  };
  opened.onsuccess();
  return {glue: context.KiteGlue, durable: context.KiteDurable,
    store: (await pending).value, transactions};
}
const reads = [{store: 'meta', key: 'state', as: 'state'},
  {store: 'volumes', key: 'work:0', as: 'volume'}];
function answer(tx, index, value) {
  tx.requests[index].result = value;
  tx.requests[index].onsuccess();
}

test('atomic volume snapshot is consistent and publishes only on transaction completion', async () => {
  const {store, transactions} = await fixture();
  let called = 0;
  const pending = store.atomic({reads, plan: read => {
    called += 1;
    assert.deepEqual(plain(read), {state: {epoch: 2}, volume: {generation: 3}});
    return ok({writes: [{store: 'volumes', key: 'work:0', value: {generation: 4}}],
      receipt: {generation: 4}});
  }});
  const tx = transactions[0];
  assert.deepEqual(plain(tx.names), ['meta', 'volumes']);
  answer(tx, 1, {generation: 3});
  assert.equal(called, 0);
  answer(tx, 0, {epoch: 2});
  assert.equal(called, 1);
  assert.equal(tx.writes.length, 1);
  let complete = false;
  pending.then(() => { complete = true; });
  await tick();
  assert.equal(complete, false);
  tx.oncomplete();
  assert.deepEqual(plain(await pending), ok({generation: 4}));
});

test('abort and an abort losing its race settle only from transaction terminal events', async () => {
  const {store, transactions} = await fixture();
  const pending = store.atomic({reads, plan: () => ok({receipt: 'saved'})});
  const tx = transactions[0];
  answer(tx, 0, {epoch: 1});
  answer(tx, 1, {});
  let complete = false;
  pending.then(() => { complete = true; });
  assert.equal(pending.abort().ok, true);
  await tick();
  assert.equal(complete, false);
  tx.error = {name: 'AbortError'};
  tx.onabort();
  assert.deepEqual(plain(await pending), {ok: false, error: 'AbortError'});
  const winner = store.atomic({reads, plan: () => ok({receipt: 'committed'})});
  const winnerTx = transactions[1];
  answer(winnerTx, 0, {});
  answer(winnerTx, 1, {});
  winnerTx.abort = () => { throw new DOMException('already committing', 'InvalidStateError'); };
  assert.equal(winner.abort().ok, false);
  let won = false;
  winner.then(() => { won = true; });
  await tick();
  assert.equal(won, false);
  winnerTx.oncomplete();
  assert.deepEqual(plain(await winner), ok('committed'));
});

test('exact held lease is checked before transaction and again before writes', async () => {
  const {glue, store, transactions} = await fixture();
  const name = 'cluster:volume:work:0';
  const lease = (await glue.lock(name)).value;
  let planned = 0;
  const request = value => ({reads, lease: {name, value}, plan: () => {
    planned += 1;
    return ok({receipt: true});
  }});
  assert.equal((await store.atomic(request({release() {}}))).error, 'lock_denied');
  assert.equal(transactions.length, 0);
  const pending = store.atomic(request(lease));
  await lease.release();
  const replacement = (await glue.lock(name)).value;
  const tx = transactions[0];
  answer(tx, 0, {});
  answer(tx, 1, {});
  assert.equal(planned, 0);
  assert.equal(tx.abortRequested, true);
  tx.onabort();
  assert.equal((await pending).error, 'lock_denied');
  assert.equal((await store.atomic(request(lease))).error, 'lock_denied');
  assert.equal(transactions.length, 1);
  await replacement.release();
});

test('fence refusals abort without queued mutations', async () => {
  for (const error of ['stale_epoch', 'stale_generation', 'stale_revision']) {
    const {store, transactions} = await fixture();
    const pending = store.atomic({reads, plan: () => ({ok: false, error})});
    const tx = transactions[0];
    answer(tx, 0, {});
    answer(tx, 1, {});
    assert.equal(tx.abortRequested, true);
    assert.deepEqual(tx.writes, []);
    tx.onabort();
    assert.equal((await pending).error, error);
  }
});

test('feed polls without a BroadcastChannel and shares overlapping reads', async () => {
  const {durable} = await fixture();
  let interval;
  let readCount = 0;
  let complete;
  let stopped = false;
  const delivered = [];
  const glue = {doorbell: () => ({ok: false, error: 'unavailable'}),
    every(milliseconds, callback) {
      assert.equal(milliseconds, 17);
      interval = callback;
      return ok(() => { stopped = true; });
    }};
  const model = {feed: () => 0, feedApply: (state, snapshot) => ok({
    state: snapshot.seq, cursor: snapshot.seq, accepted: snapshot.entries.slice(state)
  })};
  const store = {read() { readCount += 1; return new Promise(done => { complete = done; }); }};
  const feed = durable.feed(glue, store, model, {prefix: 'test', interval: 17,
    onEntries: entries => delivered.push(...entries)}).value;
  interval();
  const pending = feed.poll();
  assert.equal(readCount, 1);
  complete(ok({seq: 1, entries: [{seq: 1}]}));
  assert.equal((await pending).value.seq, 1);
  interval();
  complete(ok({seq: 2, entries: [{seq: 1}, {seq: 2}]}));
  await feed.poll();
  assert.deepEqual(delivered, [{seq: 1}, {seq: 2}]);
  assert.equal(feed.view().cursor, 2);
  await feed.stop();
  assert.equal(stopped, true);
  assert.equal((await feed.poll()).error, 'stopped');
});

test('service projection refusal rolls back and notification follows commit', async () => {
  const {durable, store, transactions} = await fixture();
  const rings = [];
  const model = {serviceCheck: () => ok({duplicate: false, message: {payload: 'hello'}})};
  const service = durable.services(store, model, {ring: seq => rings.push(seq)});
  const pending = service.register(1, 'events');
  const tx = transactions[0];
  answer(tx, 0, {epoch: 1, seq: 1, owner: 'leader'});
  answer(tx, 1, []);
  assert.equal(tx.writes.length, 2);
  await tick();
  assert.deepEqual(rings, []);
  tx.oncomplete();
  assert.equal((await pending).ok, true);
  assert.deepEqual(rings, [2]);
  model.serviceCheck = () => ({ok: false, error: 'conflicting_replay'});
  const refused = service.send(1, {});
  const refusedTx = transactions[1];
  answer(refusedTx, 0, {epoch: 1, seq: 2});
  answer(refusedTx, 1, []);
  assert.deepEqual(refusedTx.writes, []);
  refusedTx.onabort();
  assert.equal((await refused).error, 'conflicting_replay');
  assert.deepEqual(rings, [2]);
});

// A stored fixture keeps written rows, so a volume host reads back what it
// committed. Writes reach the rows only when the transaction completes.
function transaction(names, mode, rows, transactions, control) {
  const tx = {names, mode, requests: [], writes: [], error: null,
    aborted: false, settled: false};
  const gate = control.hold;
  control.hold = undefined;
  let outstanding = 0;
  const settle = () => {
    if (tx.settled || tx.aborted || outstanding > 0) return;
    tx.settled = true;
    tx.writes.forEach(write => rows.set(`${write.store}/${write.key}`, write.value));
    if (tx.oncomplete) tx.oncomplete();
  };
  const deliver = produce => {
    const request = {};
    outstanding += 1;
    tx.requests.push(request);
    Promise.resolve(gate).then(() => {
      outstanding -= 1;
      if (tx.aborted) return;
      request.result = produce();
      if (request.onsuccess) request.onsuccess();
      queueMicrotask(settle);
    });
    return request;
  };
  tx.objectStore = store => ({
    get: key => deliver(() => rows.get(`${store}/${key}`)),
    getAll: () => deliver(() => [...rows].filter(([id]) => id.startsWith(`${store}/`))
      .map(([, value]) => value)),
    put(value, key) { tx.writes.push({store, key, value}); },
    add(value) { tx.writes.push({store, key: value.seq, value}); }
  });
  tx.abort = () => {
    tx.aborted = true;
    tx.abortRequested = true;
    queueMicrotask(() => { if (tx.onabort) tx.onabort(); });
  };
  transactions.push(tx);
  return tx;
}

async function stored() {
  const opened = {};
  const transactions = [];
  const rows = new Map([['meta/state', {epoch: 1, seq: 0, owner: 'leader'}]]);
  const control = {hold: undefined};
  const context = vm.createContext({queueMicrotask, console, TextDecoder, TextEncoder,
    navigator: {locks: locking()}, indexedDB: {open: () => opened}});
  for (const source of [...sources, modelSource]) vm.runInContext(source, context);
  const pending = context.KiteGlue.open('test');
  opened.result = {
    transaction: (names, mode) => transaction(names, mode, rows, transactions, control),
    close() {}
  };
  opened.onsuccess();
  return {glue: context.KiteGlue, durable: context.KiteDurable,
    model: context.KiteDurableModel, store: (await pending).value, rows, transactions,
    hold: promise => { control.hold = promise; }};
}

const volumeName = 'cluster:volume:data:0';
function volumeHost(f) {
  const leases = [];
  const glue = {...f.glue, async lock(name) {
    const result = await f.glue.lock(name);
    if (result.ok && result.value) leases.push(result.value);
    return result;
  }};
  const created = f.durable.volume(glue, f.store, f.model,
    {prefix: 'cluster', namespace: 'data', ordinal: 0});
  assert.equal(created.ok, true, created.error);
  return {host: created.value, leases};
}
async function committed(f) {
  const opened = volumeHost(f);
  const attached = await opened.host.attach(1);
  assert.equal(attached.ok, true, attached.error);
  const saved = await opened.host.checkpoint(['one']);
  assert.equal(saved.ok, true, saved.error);
  return opened;
}
async function racingWrite(f, host) {
  const prepared = await host.prepare(['two']);
  assert.equal(prepared.ok, true, prepared.error);
  const gate = deferred();
  f.hold(gate.promise);
  const index = f.transactions.length;
  const racing = host.begin();
  const frozen = host.freeze();
  return {gate, racing, frozen, tx: f.transactions[index]};
}

test('a denied volume lock reports lock_denied and leaves the session able to retry', async () => {
  const f = await stored();
  const rival = (await f.glue.lock(volumeName)).value;
  const {host} = volumeHost(f);
  assert.deepEqual(plain(await host.attach(1)), {ok: false, error: 'lock_denied'});
  assert.equal(host.view().lockHeld, false);
  assert.equal(f.transactions.length, 0);
  await rival.release();
  const attached = await host.attach(1);
  assert.equal(attached.ok, true, attached.error);
  assert.equal(host.view().phase, 'attached');
  await host.discard();
});

test('a released volume lease fences the next checkpoint and keeps the stored row', async () => {
  const f = await stored();
  const {host, leases} = await committed(f);
  const before = plain(f.rows.get('volumes/data:0'));
  const count = f.transactions.length;
  assert.equal(leases.length, 1);
  await leases[0].release();
  assert.equal((await host.checkpoint(['two'])).error, 'lock_denied');
  assert.deepEqual(plain(f.rows.get('volumes/data:0')), before);
  assert.equal(f.transactions.length, count);
  await host.discard();
});

test('freeze during an in-flight volume write requests the transaction abort', async () => {
  const f = await stored();
  const {host} = await committed(f);
  const race = await racingWrite(f, host);
  // The brief requires the abort request, never a winner of the race.
  assert.equal(race.tx.abortRequested, true);
  race.gate.resolve();
  assert.equal((await race.racing).ok, false);
  assert.equal((await race.frozen).ok, true);
  assert.equal(host.view().lockHeld, false);
  await host.discard();
});

test('an aborted volume write keeps the previous committed checkpoint', async () => {
  const f = await stored();
  const {host} = await committed(f);
  const before = plain(f.rows.get('volumes/data:0'));
  const race = await racingWrite(f, host);
  race.gate.resolve();
  await race.racing;
  await race.frozen;
  assert.deepEqual(plain(host.view().committed), {revision: 1, entries: ['one']});
  assert.deepEqual(plain(f.rows.get('volumes/data:0')), before);
  await host.discard();
});

test('a service send at the counter bound refuses and one below it commits', async () => {
  const {durable} = await fixture();
  const model = {serviceCheck: () => ok({duplicate: false, message: null})};
  const counting = seq => {
    const writes = [];
    const store = {async atomic({plan}) {
      const outcome = plan({state: {epoch: 1, seq, owner: null}, entries: []});
      if (!outcome.ok) return outcome;
      writes.push(...(outcome.value.writes || []));
      return ok(outcome.value.receipt);
    }};
    return {writes, store};
  };
  const rings = [];
  const exhausted = counting(1000000000);
  const refused = await durable.services(exhausted.store, model,
    {ring: seq => rings.push(seq)}).send(1, {payload: 'x'});
  assert.deepEqual(plain(refused), {ok: false, error: 'counter_exhausted'});
  assert.deepEqual(exhausted.writes, []);
  assert.deepEqual(rings, []);
  const last = counting(999999999);
  const saved = await durable.services(last.store, model,
    {ring: seq => rings.push(seq)}).send(1, {payload: 'x'});
  assert.equal(saved.ok, true, saved.error);
  assert.equal(saved.value.seq, 1000000000);
  assert.equal(last.writes.length, 2);
  assert.equal(last.writes[0].value.seq, 1000000000);
  assert.deepEqual(rings, [1000000000]);
});

test('a feed read that lands after stop delivers nothing and holds the cursor', async () => {
  const {durable} = await fixture();
  let complete;
  const delivered = [];
  const glue = {doorbell: () => ({ok: false, error: 'unavailable'}),
    every: () => ok(() => {})};
  const model = {feed: () => 0, feedApply: (_state, snapshot) => ok({
    state: snapshot.seq, cursor: snapshot.seq, accepted: snapshot.entries
  })};
  const store = {read: () => new Promise(done => { complete = done; })};
  const feed = durable.feed(glue, store, model, {prefix: 'test', interval: 5,
    onEntries: entries => delivered.push(...entries)}).value;
  const pending = feed.poll();
  const stopping = feed.stop();
  complete(ok({seq: 1, entries: [{seq: 1}]}));
  assert.equal((await pending).ok, true);
  await stopping;
  assert.equal(feed.view().cursor, 0);
  assert.deepEqual(delivered, []);
});

test('a duplicate service reply rings no doorbell and a fresh record rings once', async () => {
  const {durable} = await fixture();
  const rings = [];
  const model = {serviceCheck: () => ok({duplicate: true, message: null})};
  const store = {async atomic({plan}) {
    const outcome = plan({state: {epoch: 1, seq: 4, owner: null}, entries: []});
    return outcome.ok ? ok(outcome.value.receipt) : outcome;
  }};
  const service = durable.services(store, model, {ring: seq => rings.push(seq)});
  assert.equal((await service.send(1, {payload: 'x'})).value.duplicate, true);
  assert.deepEqual(rings, []);
  model.serviceCheck = () => ok({duplicate: false, message: null});
  assert.equal((await service.send(1, {payload: 'x'})).value.seq, 5);
  assert.deepEqual(rings, [5]);
});

test('a doorbell failure reports its error and keeps the committed receipt', async () => {
  const {durable} = await fixture();
  const errors = [];
  const model = {serviceCheck: () => ok({duplicate: false, message: null})};
  const store = {async atomic({plan}) {
    const outcome = plan({state: {epoch: 1, seq: 4, owner: null}, entries: []});
    return outcome.ok ? ok({...outcome.value.receipt, writes: outcome.value.writes}) : outcome;
  }};
  const service = durable.services(store, model, {
    ring: () => { throw new TypeError("Cannot read properties of undefined (reading 'ring')"); },
    onError: error => errors.push(error)});
  const saved = await service.send(1, {payload: 'x'});
  assert.equal(saved.ok, true, saved.error);
  assert.equal(saved.value.seq, 5);
  assert.equal(saved.value.writes.length, 2);
  assert.deepEqual(errors, ["Cannot read properties of undefined (reading 'ring')"]);
  const rejecting = durable.services(store, model, {
    ring: () => Promise.reject(new Error('channel_closed')),
    onError: error => errors.push(error)});
  assert.equal((await rejecting.send(1, {payload: 'x'})).value.seq, 5);
  assert.deepEqual(errors, ["Cannot read properties of undefined (reading 'ring')", 'channel_closed']);
});

test('a feed interval outside its bound is refused before any timer or doorbell', async () => {
  const {durable} = await fixture();
  const opened = [];
  const glue = {doorbell: name => { opened.push(name); return ok({ring: () => ok(undefined), close: () => ok(undefined)}); },
    every: milliseconds => { opened.push(milliseconds); return ok(() => {}); }};
  const model = {feed: () => 0};
  const store = {read: () => Promise.resolve(ok({seq: 0, entries: []}))};
  for (const interval of [0, -1, 1.5]) {
    assert.deepEqual(plain(durable.feed(glue, store, model, {prefix: 'test', interval})),
      {ok: false, error: 'invalid_interval'});
  }
  assert.deepEqual(opened, []);
});
