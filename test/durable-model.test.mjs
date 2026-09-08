import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../_build/default/browser/model.bc.js', import.meta.url), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
function model() {
  const context = vm.createContext({console, TextDecoder, TextEncoder});
  vm.runInContext(source, context);
  return context.KiteDurableModel;
}
function value(result) {
  assert.equal(result.ok, true, result.error);
  return result.value;
}
const entry = (seq, epoch, payload) => ({seq, epoch, payload});
const snapshot = entries => ({seq: entries.length, epoch: entries.at(-1)?.epoch || 0, entries});
const emptyVolume = () => ({key: 'data:0', epoch: 1, generation: 0,
  committed: {revision: 0, entries: []}});
function claiming(m) {
  let state = value(m.volume('data', 0, 0));
  let result = value(m.volumeStep(state, {kind: 'attach', epoch: 1}));
  assert.equal(result.actions[0].kind, 'acquire_lock');
  assert.deepEqual(plain(result.actions[0].lease), {key: 'data:0', ticket: 1});
  state = result.state;
  result = value(m.volumeStep(state, {kind: 'lock_acquired', ticket: 1, durable: emptyVolume()}));
  assert.equal(result.actions[0].kind, 'claim_writer');
  return {state: result.state, action: result.actions[0]};
}
function attached(m) {
  const claim = claiming(m);
  const committed = value(m.atomicVolume(emptyVolume(), claim.action));
  const result = value(m.volumeStep(claim.state, {kind: 'claimed', ticket: 1,
    result: {ok: true, value: committed.receipt}}));
  assert.equal(result.view.phase, 'attached');
  return {state: result.state, snapshot: committed.snapshot};
}
function writing(m, entries = ['one']) {
  const attachedState = attached(m);
  let result = value(m.volumeStep(attachedState.state, {kind: 'prepare', entries}));
  assert.equal(result.view.phase, 'prepared');
  assert.equal(result.actions.length, 0);
  result = value(m.volumeStep(result.state, {kind: 'begin_write', ticket: result.view.ticket}));
  assert.equal(result.view.phase, 'in_flight');
  return {state: result.state, action: result.actions[0], snapshot: attachedState.snapshot};
}

test('native feed ignores doorbell order and validates immutable replay payloads', () => {
  const m = model();
  let state = m.feed();
  state = value(m.feedNotify(state, 8));
  state = value(m.feedNotify(state, 1));
  const first = entry(1, 1, {kind: 'record', fields: {a: 1, b: 2}});
  let result = value(m.feedApply(state, snapshot([first])));
  assert.equal(result.cursor, 1);
  assert.deepEqual(plain(result.accepted), [first]);
  state = result.state;
  result = value(m.feedApply(state, snapshot([entry(1, 1, {fields: {b: 2, a: 1}, kind: 'record'})])));
  assert.equal(result.accepted.length, 0);
  assert.equal(m.feedApply(state, snapshot([entry(1, 1, {kind: 'changed'})])).ok, false);
  const gap = m.feedApply(state, {seq: 3, epoch: 1, entries: [entry(3, 1, null)]});
  assert.equal(gap.ok, false);
  assert.match(gap.error, /gap/);
  result = value(m.feedApply(state, snapshot([first, entry(2, 1, ['second'])])));
  assert.equal(result.cursor, 2);
  assert.equal(result.accepted.length, 1);
});

test('native feed rejects malformed snapshots and non-JSON data explicitly', () => {
  const m = model();
  const state = m.feed();
  for (const input of [null, {}, {seq: '1', epoch: 1, entries: []},
    {seq: 1, epoch: 1, entries: [entry(1, 1, Infinity)]},
    {seq: 1, epoch: 1, entries: [entry(1, 1, () => 1)]}]) {
    assert.equal(m.feedApply(state, input).ok, false);
  }
  const cyclic = {};
  cyclic.self = cyclic;
  assert.equal(m.feedApply(state, snapshot([entry(1, 1, cyclic)])).ok, false);
  assert.equal(value(m.feedApply(state, snapshot([]))).cursor, 0);
});

test('native service reconstructs committed history and invalidates old sessions', () => {
  const m = model();
  const sender = {service: 'api', sender: 'web', incarnation: 1, session: 1};
  const publication = {source: sender, sequence: 1, payload: 'hello'};
  const records = [entry(1, 1, {kind: 'leader'}),
    entry(2, 1, {kind: 'service', event: {kind: 'register', name: 'api'}}),
    entry(3, 1, {kind: 'service', event: {kind: 'handshake', source: sender}}),
    entry(4, 1, {kind: 'service', event: {kind: 'send', publication}})];
  const restored = value(m.serviceRestore(snapshot(records)));
  assert.deepEqual(plain(restored.services), ['api']);
  assert.equal(restored.messages.length, 1);
  const duplicate = value(m.serviceCheck(snapshot(records), 1, {kind: 'send', publication}));
  assert.equal(duplicate.duplicate, true);
  assert.equal(duplicate.message, null);
  assert.equal(m.serviceCheck(snapshot(records), 1,
    {kind: 'send', publication: {...publication, payload: 'different'}}).ok, false);
  records.push(entry(5, 2, {kind: 'leader'}));
  assert.equal(value(m.serviceRestore(snapshot(records))).sessions.length, 0);
  assert.equal(m.serviceCheck(snapshot(records), 2, {kind: 'send', publication}).ok, false);
  assert.equal(m.serviceCheck(snapshot(records), 1, {kind: 'handshake', source: sender}).ok, false);
});

test('service reconstruction rejects incomplete prefixes and malformed service records', () => {
  const m = model();
  const incomplete = {seq: 2, epoch: 1, entries: [entry(1, 1, {kind: 'leader'})]};
  assert.equal(m.serviceRestore(incomplete).ok, false);
  assert.equal(m.serviceCheck(incomplete, 1, {kind: 'register', name: 'api'}).ok, false);
  for (const payload of [{kind: 'service'}, {kind: 'service', event: {}},
    {kind: 'service', event: {kind: 'register', name: false}}]) {
    assert.equal(m.serviceRestore(snapshot([entry(1, 1, payload)])).ok, false);
  }
});

test('native volume claims and writes retain opaque receipts and refuse all stale fences', () => {
  const m = model();
  const current = writing(m);
  const {snapshot: saved, receipt} = value(m.atomicVolume(current.snapshot, current.action));
  assert.equal(saved.generation, 1);
  assert.deepEqual(plain(saved.committed), {revision: 1, entries: ['one']});
  assert.deepEqual(plain(receipt), {});
  const refused = [
    [{...current.snapshot, epoch: 2}, 'stale_epoch'],
    [{...current.snapshot, generation: 2}, 'stale_generation'],
    [{...current.snapshot, committed: {revision: 1, entries: ['old']}}, 'stale_revision']
  ];
  for (const [snapshot, error] of refused) {
    assert.deepEqual(plain(m.atomicVolume(snapshot, current.action)), {ok: false, error});
  }
  const stale = m.volumeStep(current.state, {kind: 'completed', ticket: current.action.ticket + 1,
    result: {ok: true, value: receipt}});
  assert.equal(stale.ok, false);
  const completed = value(m.volumeStep(current.state, {kind: 'completed', ticket: current.action.ticket,
    result: {ok: true, value: receipt}}));
  assert.deepEqual(plain(completed.view.lastResult), {ok: true, value: plain(saved.committed)});
  assert.deepEqual(plain(value(m.volumeView(current.state)).committed), {revision: 0, entries: []});
});

test('native volume freeze during claim waits for receipt before exact lease release', () => {
  const m = model();
  const current = claiming(m);
  const frozen = value(m.volumeStep(current.state, {kind: 'freeze'}));
  assert.equal(frozen.actions[0].kind, 'abort_claim');
  assert.equal(frozen.view.lockHeld, true);
  const claimed = value(m.atomicVolume(emptyVolume(), current.action));
  const completed = value(m.volumeStep(frozen.state, {kind: 'claimed', ticket: 1,
    result: {ok: true, value: claimed.receipt}}));
  assert.equal(completed.view.phase, 'releasing');
  assert.deepEqual(plain(completed.actions[0]), {kind: 'release_lock', lease: {key: 'data:0', ticket: 1}});
  const released = value(m.volumeStep(completed.state, {kind: 'released', ticket: 1}));
  assert.equal(released.view.lockHeld, false);
  assert.equal(released.view.mode, 'frozen');
});

test('native volume freeze after write commit preserves checkpoint through release', () => {
  const m = model();
  const current = writing(m);
  const committed = value(m.atomicVolume(current.snapshot, current.action));
  const frozen = value(m.volumeStep(current.state, {kind: 'freeze'}));
  assert.equal(frozen.actions[0].kind, 'abort_write');
  const completed = value(m.volumeStep(frozen.state, {kind: 'completed', ticket: current.action.ticket,
    result: {ok: true, value: committed.receipt}}));
  assert.deepEqual(plain(completed.view.committed), {revision: 1, entries: ['one']});
  assert.equal(completed.actions[0].kind, 'release_lock');
  assert.equal(completed.actions[0].lease.ticket, 1);
});

test('volume callback rejects copied, wrong-kind and forged receipt capabilities', () => {
  const m = model();
  const current = claiming(m);
  const claimed = value(m.atomicVolume(emptyVolume(), current.action));
  let called = false;
  const forged = () => { called = true; throw new Error('forged'); };
  for (const receipt of [null, {}, plain(claimed.receipt), forged, 3, 'receipt']) {
    const result = m.volumeStep(current.state, {kind: 'claimed', ticket: 1,
      result: {ok: true, value: receipt}});
    assert.deepEqual(plain(result), {ok: false, error: 'invalid_receipt'});
  }
  assert.equal(called, false);
  const write = writing(m);
  const wrong = m.volumeStep(write.state, {kind: 'completed', ticket: write.action.ticket,
    result: {ok: true, value: claimed.receipt}});
  assert.deepEqual(plain(wrong), {ok: false, error: 'invalid_receipt_kind'});
  assert.deepEqual(plain(m.atomicVolume(emptyVolume(), {operation: forged})),
    {ok: false, error: 'invalid_volume_operation'});
  assert.deepEqual(plain(m.volumeView(forged)), {ok: false, error: 'invalid_state'});
  assert.deepEqual(plain(m.feedNotify(forged, 1)), {ok: false, error: 'invalid_state'});
  assert.equal(called, false);
});

test('volume boundary refuses malformed durable snapshots without changing session', () => {
  const m = model();
  let state = value(m.volume('data', 0, 0));
  state = value(m.volumeStep(state, {kind: 'attach', epoch: 1})).state;
  for (const durable of [null, {...emptyVolume(), key: 'data:00'},
    {...emptyVolume(), epoch: 0}, {...emptyVolume(), generation: -1},
    {...emptyVolume(), committed: {revision: 0, entries: ['invalid']}}]) {
    assert.equal(m.volumeStep(state, {kind: 'lock_acquired', ticket: 1, durable}).ok, false);
  }
  assert.equal(value(m.volumeView(state)).phase, 'acquiring');
});
