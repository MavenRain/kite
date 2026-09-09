import assert from 'node:assert/strict';
import test from 'node:test';
import {runLifecycleFaults} from '../dev/m2-lifecycle-faults.mjs';

const observerTarget = 'observer-target';
const cleanupError = new Error('victim tab cleanup failed');

// The stub covers the runner cleanup path only. It emits no fault record and
// stands in for no durable browser interface.
function harness(options = {}) {
  const sent = [];
  const view = (epoch, generation, entries, ticket) => ({
    node: {epoch, nodeLock: `node-lock-${epoch}`, workers: [{phase: 'running', ticket}]},
    volumes: [{key: 'volume:state:0', phase: 'attached', writer: {generation},
      committed: {revision: generation, entries}}],
    ticks: [{ticket}]
  });
  const base = view(4, 2, ['first', 'second'], 'ticket-a');
  let marker;
  let views = 0;
  return {
    sent,
    rows: [{id: 7, fault: 'kill_node_starting', injection: 'stub', outcome: 'stub', witness: {stub: true}},
      {id: 9, fault: 'kill_node_stopping', injection: 'stub', outcome: 'stub', witness: {stub: true}}],
    build(rows) {
      return {
        origin: 'http://127.0.0.1:65535',
        artifacts: {'stateful-set': 'globalThis.KiteArtifact = {};'},
        cdp: {send: async (method, params) => { sent.push({method, params}); return {success: true}; }},
        page: async () => ({session: 'observer-session', target: observerTarget}),
        evaluate: async () => true,
        delay: async () => undefined,
        poll: async () => {
          if (options.probeFails) throw new Error('browser probe timed out after 15000ms');
          return true;
        },
        outcome: async () => rows,
        sourcePage: async (origin, artifact, cluster, node) => ({session: node, target: `${node}-target`}),
        sourceCheckpoint: async (tab, requested) => { marker = requested; return base; },
        sourceView: async (tab, workload, predicate, label) => {
          views += 1;
          const observed = views === 1 ? base : view(5, 3, ['first', 'second', marker], 'ticket-b');
          if (!predicate(observed)) throw new Error(`${label}: ${JSON.stringify(observed)}`);
          return observed;
        },
        killSource: async () => ({workerTerminated: true, nativeLeasesAfterDeath: 0,
          lifecycleEventsBeforeDeath: [], targetClosedAfterDeath: true}),
        closeSource: async () => {
          if (options.cleanupFails) throw cleanupError;
          return undefined;
        }
      };
    }
  };
}

const closedObserver = sent => sent.some(entry => entry.method === 'Target.closeTarget' &&
  entry.params.targetId === observerTarget);

test('a matrix failure survives a failing cleanup and still closes the observer target', async () => {
  const stub = harness({probeFails: true, cleanupFails: true});
  await assert.rejects(() => runLifecycleFaults(stub.build(stub.rows)),
    /browser probe timed out/);
  assert.equal(closedObserver(stub.sent), true);
});

test('a cleanup failure alone fails the runner and still closes the observer target', async () => {
  const stub = harness({cleanupFails: true});
  await assert.rejects(() => runLifecycleFaults(stub.build(stub.rows)),
    /victim tab cleanup failed/);
  assert.equal(closedObserver(stub.sent), true);
});

test('the Running death record reports the observed epoch and generation', async () => {
  const stub = harness();
  const rows = await runLifecycleFaults(stub.build(stub.rows));
  assert.deepEqual(rows.map(row => row.id), [7, 8, 9]);
  const running = rows.find(row => row.id === 8);
  assert.notEqual(running.outcome, 'ok');
  assert.match(running.outcome, /epoch_5/);
  assert.match(running.outcome, /generation_3/);
  assert.equal(running.witness.markerRecovered, true);
  assert.equal(closedObserver(stub.sent), true);
});
