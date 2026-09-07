import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../browser/source.js', import.meta.url), 'utf8');
function runner(start, globals = {}) {
  const context = vm.createContext({KiteProgram: {start}, setTimeout, clearTimeout, ...globals});
  vm.runInContext(source, context);
  return context.KiteSource;
}
const plain = value => JSON.parse(JSON.stringify(value));

test('cooperative yield permits timers before resuming source', async () => {
  let timerRan = false;
  setTimeout(() => { timerRan = true; }, 0);
  const runtime = runner(() => ({kind: 'yield', resume() {
    assert.equal(timerRan, true);
    return {kind: 'done', value: 42};
  }}));
  assert.deepEqual(plain(await runtime.run({}, () => {})), {ok: true, value: 42});
});

test('host failure is an explicit reply and suppresses later source work', async () => {
  const runtime = runner(() => ({kind: 'call', name: 'read', argument: 7,
    deadlineMs: 1000, resume(reply) {
      assert.equal(reply.ok, false);
      return {kind: 'error', error: reply.error};
    }}));
  const result = await runtime.run({}, async (name, argument) => {
    assert.equal(name, 'read');
    assert.equal(argument, 7);
    throw new Error('unavailable');
  });
  assert.deepEqual(plain(result), {ok: false, error: 'unavailable'});
});

test('deadline resumes once and ignores a late host reply', async () => {
  let finish;
  let resumed = 0;
  const runtime = runner(() => ({kind: 'call', name: 'slow', argument: null,
    deadlineMs: 10, resume(reply) {
      resumed += 1;
      assert.equal(reply.ok, false);
      return {kind: 'error', error: reply.error};
    }}));
  const result = await runtime.run({}, () => new Promise(resolve => { finish = resolve; }));
  assert.deepEqual(plain(result), {ok: false, error: 'host_deadline:slow'});
  finish(42);
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(resumed, 1);
});

test('elapsed deadline rejects a synchronous host result before its timer can fire', async () => {
  let elapsed = 0;
  const runtime = runner(() => ({kind: 'call', name: 'blocked', argument: null,
    deadlineMs: 5, resume(reply) {
      assert.equal(reply.ok, false);
      return {kind: 'error', error: reply.error};
    }}), {performance: {now: () => elapsed}});
  const result = await runtime.run({}, () => { elapsed = 6; return 42; });
  assert.deepEqual(plain(result), {ok: false, error: 'host_deadline:blocked'});
});

test('a thrown value that resists conversion still returns an explicit failure', async () => {
  const runtime = runner(() => ({kind: 'call', name: 'object', argument: null,
    deadlineMs: 1000, resume(reply) {
      return {kind: 'done', value: reply.value.field};
    }}));
  const result = await runtime.run({}, () => Object.defineProperty({}, 'field', {
    get() { throw Object.create(null); }
  }));
  assert.equal(result.ok, false);
  assert.equal(typeof result.error, 'string');
});

test('host decoding errors return an explicit failure', async () => {
  const runtime = runner(() => ({kind: 'call', name: 'object', argument: null,
    deadlineMs: 1000, resume(reply) {
      return {kind: 'done', value: reply.value.field};
    }}));
  const result = await runtime.run({}, () => Object.defineProperty({}, 'field', {
    get() { throw new Error('getter_failed'); }
  }));
  assert.deepEqual(plain(result), {ok: false, error: 'getter_failed'});
});
