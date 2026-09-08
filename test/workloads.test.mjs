import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../browser/source.js', import.meta.url), 'utf8');
const workloads = await readFile(new URL('../browser/workloads.js', import.meta.url), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
const ok = value => ({ok: true, value});
const done = value => ({kind: 'done', value});
const workload = (kind, name) => ({kind, name, replicas: 1, bound: 2, tolerateHidden: true});
const turn = () => new Promise(resolve => setTimeout(resolve, 0));
function harness(manifests, options = {}) {
  const calls = [];
  const workers = [];
  const glue = {
    spawn(url, receive) {
      const worker = {url, receive, id: workers.length};
      workers.push(worker);
      return ok(worker);
    },
    send(worker, message) {
      calls.push([worker.id, message.op, message]);
      const normal = () => message.op === 'view'
        ? ok({node: {incarnation: 1, epoch: 1}}) : ok(null);
      Promise.resolve(options.request ? options.request(worker, message, normal) : normal())
        .then(result => worker.receive({...result, id: message.id}));
      return ok(null);
    },
    kill(worker) {
      calls.push([worker.id, 'kill']);
      return options.kill ? options.kill(worker) : ok(null);
    }
  };
  const context = vm.createContext({setTimeout, clearTimeout,
    KiteProgram: {openSession: artifact => artifact.open()}});
  vm.runInContext(source, context);
  vm.runInContext(workloads, context);
  const created = context.KiteWorkloads.create(glue, {cluster: 'test', nodeId: 'node',
    visibility: () => 'visible'});
  assert.equal(created.ok, true);
  const complete = () => ({...done(7), manifests,
    session: {freeze: options.freeze || (() => done(null))}});
  const artifact = {open: options.open ? () => options.open(complete) : complete};
  return {host: created.value, artifact, calls, workers};
}

test('workloads install distinct manifests and route the retained checkpoint contract', async () => {
  const h = harness([workload('deployment', 'web'), workload('stateful_set', 'data'),
    {kind: 'service', name: 'api', target: 'web'}], {
    freeze: () => ({kind: 'call', name: 'host_checkpoint', argument: 'data', deadlineMs: 500,
      resume: reply => reply.ok ? done(reply.value) : {kind: 'error', error: reply.error}})
  });
  assert.equal((await h.host.start(h.artifact)).ok, true);
  assert.deepEqual(h.calls.filter(call => call[1] === 'boot').map(call => call[2].manifest.name), ['web', 'data']);
  assert.deepEqual(plain(await h.host.freeze()), {ok: true, value: null});
  const checkpoint = h.calls.findIndex(call => call[1] === 'checkpoint');
  const drain = h.calls.findIndex(call => call[1] === 'freeze');
  assert.ok(checkpoint >= 0 && checkpoint < drain);
  assert.equal(h.calls[checkpoint][0], 1);
  assert.equal((await h.host.request('data', 'view')).error, 'node_unavailable');
  assert.equal((await h.host.resume()).ok, true);
  // Each observation round carries one sequence, and rounds strictly increase.
  const sequences = () => h.calls.filter(call => call[1] === 'visibility')
    .map(call => call[2].observation.sequence);
  assert.deepEqual(sequences(), [1, 1]);
  assert.equal((await h.host.observe()).ok, true);
  assert.deepEqual(sequences(), [1, 1, 2, 2]);
  await h.host.close();
});

test('freeze cancels pending startup before a late reply can run another source effect', async () => {
  let complete;
  const effects = [];
  const h = harness([workload('deployment', 'web')], {
    open: finish => ({kind: 'call', name: 'slow', argument: null, deadlineMs: 500,
      resume: () => ({kind: 'call', name: 'later', argument: null, deadlineMs: 500,
        resume: finish})})
  });
  const started = h.host.start(h.artifact, name => {
    effects.push(name);
    return new Promise(resolve => { complete = resolve; });
  });
  await turn();
  assert.equal((await h.host.freeze()).ok, true);
  complete(null);
  assert.equal((await started).error, 'session_closed');
  assert.deepEqual(effects, ['slow']);
  assert.equal(h.workers.length, 0);
  await h.host.close();
});

test('freeze during installation prevents late boot from installing another workload', async () => {
  let complete;
  const h = harness([workload('deployment', 'web'), workload('stateful_set', 'data')], {
    request: (_worker, message, normal) => message.op === 'boot'
      ? new Promise(resolve => { complete = resolve; }) : normal()
  });
  const started = h.host.start(h.artifact);
  await turn();
  assert.equal((await h.host.freeze()).ok, true);
  complete(ok(null));
  assert.equal((await started).error, 'lifecycle_changed');
  assert.equal(h.workers.length, 1);
  assert.equal(h.calls.filter(call => call[1] === 'kill').length, 1);
  await h.host.close();
});

test('a freeze that overtakes resume preserves the frozen lifecycle', async () => {
  let complete;
  const h = harness([workload('deployment', 'web')], {
    request: (_worker, message, normal) => message.op === 'resume'
      ? new Promise(resolve => { complete = resolve; }) : normal()
  });
  await h.host.start(h.artifact);
  await h.host.freeze();
  const resumed = h.host.resume();
  await turn();
  // A fresh freeze event invalidates an in-flight resume even while locally frozen.
  await h.host.freeze();
  complete(ok(null));
  assert.equal((await resumed).error, 'lifecycle_changed');
  assert.equal((await h.host.request('web', 'view')).error, 'node_unavailable');
  await h.host.close();
});

test('failed checkpoint drain stays visible on repeated freeze without replaying the handler', async () => {
  let handlers = 0;
  const h = harness([workload('stateful_set', 'data')], {
    freeze: () => {
      handlers += 1;
      return {kind: 'call', name: 'host_checkpoint', argument: 'data', deadlineMs: 500,
        resume: reply => reply.ok ? done(null) : {kind: 'error', error: reply.error}};
    },
    request: (_worker, message, normal) => message.op === 'checkpoint'
      ? {ok: false, error: 'checkpoint_aborted'} : normal()
  });
  await h.host.start(h.artifact);
  assert.equal((await h.host.freeze()).error, 'checkpoint_aborted');
  assert.equal((await h.host.freeze()).error, 'checkpoint_aborted');
  assert.equal(handlers, 1);
  await h.host.close();
});

test('failed worker termination preserves its handle for a later close retry', async () => {
  let attempts = 0;
  const h = harness([workload('deployment', 'web')], {
    kill: () => ++attempts === 1 ? {ok: false, error: 'kill_failed'} : ok(null)
  });
  await h.host.start(h.artifact);
  assert.equal((await h.host.close()).error, 'kill_failed');
  assert.equal((await h.host.close()).ok, true);
  assert.equal(attempts, 2);
});

test('a stale service lookup cannot publish after a lifecycle transition', async () => {
  let complete;
  const h = harness([workload('deployment', 'web'), {kind: 'service', name: 'api', target: 'web'}], {
    request: (_worker, message, normal) => message.op === 'view'
      ? new Promise(resolve => { complete = resolve; }) : normal()
  });
  await h.host.start(h.artifact);
  const sent = h.host.service('api', {kind: 'register', name: 'api'});
  await turn();
  await h.host.freeze();
  complete(ok({node: {incarnation: 1, epoch: 1}}));
  assert.equal((await sent).error, 'lifecycle_changed');
  assert.equal(h.calls.some(call => call[1] === 'service'), false);
  await h.host.close();
});
