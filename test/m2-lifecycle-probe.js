/* Browser fault injection against production Kubelet effects and native Workers. */
(function (root) {
  'use strict';
  const glue = root.KiteGlue;
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const value = (result, label) => {
    assert(result && result.ok, `${label}: ${result && result.error}`);
    return result.value;
  };
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  function actor() {
    let sequence = 0;
    const pending = new Map();
    const native = value(glue.spawn('/test/m2-lifecycle-worker.js', message => {
      const receive = pending.get(message.id);
      if (receive) { pending.delete(message.id); receive(message); }
    }, error => {
      for (const receive of pending.values()) receive({ok: false, error});
      pending.clear();
    }), 'spawn node Worker');
    return {
      request(op, args = {}) {
        const id = ++sequence;
        return new Promise(resolve => {
          const timer = setTimeout(() => {
            pending.delete(id);
            resolve({ok: false, error: 'request_timeout'});
          }, 10000);
          pending.set(id, result => { clearTimeout(timer); resolve(result); });
          const sent = glue.send(native, {op, id, ...args});
          if (!sent.ok) { pending.delete(id); clearTimeout(timer); resolve(sent); }
        });
      },
      kill() {
        const killed = glue.kill(native);
        for (const receive of pending.values()) receive({ok: false, error: 'node_terminated'});
        pending.clear();
        return killed;
      }
    };
  }
  async function until(read, predicate, label) {
    const deadline = Date.now() + 15000;
    let current;
    while (Date.now() < deadline) {
      current = await read();
      if (predicate(current)) return current;
      await sleep(20);
    }
    throw new Error(`${label}: ${JSON.stringify(current)}`);
  }
  const view = node => node.request('view').then(result => value(result, 'node view'));
  async function fault(id) {
    const prefix = `kite-m2-life-${id}-${crypto.randomUUID()}`;
    const barrierName = `${prefix}:fault-stop`;
    const nodeName = `${prefix}:node:nodeA`;
    const actors = [];
    const held = [];
    const store = value(await glue.open(prefix), 'observer database');
    const spawn = () => { const node = actor(); actors.push(node); return node; };
    try {
      if (id === 9) held.push(value(await glue.lock(barrierName), 'hold stop barrier'));
      const old = spawn();
      value(await old.request('boot', {prefix, holdStart: id === 7,
        stopBarrier: id === 9 ? barrierName : null}), 'boot old node');
      value(await old.request('start'), 'start old pod');
      const active = await until(() => view(old), state => id === 7
        ? state.node.workers[0]?.phase === 'starting' && state.messages.some(message => message.kind === 'pod_lock')
        : state.node.workers[0]?.phase === 'running' && state.ticks.length > 0, 'observed injection phase');
      let stop;
      if (id === 9) {
        stop = old.request('stop');
        await until(() => view(old), state => state.node.workers[0]?.phase === 'stopping' &&
          state.blockedStop, 'Stopping before release');
      }
      const before = await view(old);
      const heldBefore = value(await glue.locks(), 'locks before kill');
      assert(heldBefore.includes(nodeName), 'old node lock held at injection');
      if (id === 7) assert(heldBefore.includes(`${prefix}:pod:0`) &&
        heldBefore.includes(`${prefix}:life:nodeA:1`), 'Starting pod is alive and holds its native leases');
      if (id === 9) assert(heldBefore.includes(`${prefix}:place:0:nodeA:1`),
        'Stopping retains published placement until release evidence');
      const refused = spawn();
      const blocked = await refused.request('boot', {prefix});
      assert(!blocked.ok && blocked.error === 'node_lock_busy', 'replacement refused before release');
      value(refused.kill(), 'terminate refused candidate');
      let releaseObserved = false;
      const release = glue.lock(nodeName, {wait: true}).then(result => {
        releaseObserved = true;
        return result;
      });
      await sleep(30);
      assert(!releaseObserved, 'release witness waits while node is alive');
      const killedAt = Date.now();
      const killed = old.kill();
      value(killed, 'kill node at observed phase');
      const stopResult = stop ? await stop : undefined;
      if (stop) assert(stopResult.error === 'node_terminated', 'pending stop receives explicit termination');
      const lease = value(await Promise.race([release, sleep(15000).then(() =>
        ({ok: false, error: 'lease_release_timeout'}))]), 'native node lease release observed');
      const nativeLeaseWaitMs = Date.now() - killedAt;
      held.push(lease);
      const atGrant = value(await glue.locks(), 'locks at the node lease grant');
      const childLeasesAfterDeath = atGrant.filter(name =>
        name.startsWith(`${prefix}:life:`) || name === `${prefix}:pod:0`).length;
      await until(() => glue.locks().then(result => value(result, 'released locks')),
        locks => !locks.some(name => name.startsWith(`${prefix}:life:`) ||
          name.startsWith(`${prefix}:place:`) || name === `${prefix}:pod:0`), 'nested Worker and placement release');
      value(await lease.release(), 'release witness lease');
      held.splice(held.indexOf(lease), 1);
      const replacement = spawn();
      value(await replacement.request('boot', {prefix, holdStart: id === 7}), 'boot replacement after release');
      value(await replacement.request('start'), 'replacement pod starts');
      await until(() => view(replacement), state => id === 7
        ? state.node.workers[0]?.phase === 'starting' && state.pendingCallbacks === 1
        : state.node.workers[0]?.phase === 'running' && state.ticks.length > 0,
      'replacement reaches callback replay phase');
      const captured = active.messages.find(message => message.kind === (id === 7 ? 'pod_lock' : 'tick'));
      assert(captured, 'capture actual old Worker callback');
      const replay = value(await replacement.request('replay', {handle: active.handles[0], message: captured}),
        'deliver captured old callback to replacement');
      const detachedCallbackChangedState = JSON.stringify(replay.before.node) !== JSON.stringify(replay.after.node) ||
        replay.before.ticks.length !== replay.after.ticks.length;
      assert(!detachedCallbackChangedState, 'stale callback leaves replacement unchanged');
      if (id === 7) value(await replacement.request('release_start'), 'deliver current pod callback');
      const after = await until(() => view(replacement), state => state.node.workers[0]?.phase === 'running' &&
        state.ticks.length > 0, 'replacement publishes live work');
      assert(after.node.epoch > before.node.epoch, 'replacement has fresh durable epoch');
      const committed = value(await store.read(), 'committed placements after replacement');
      const placements = committed.entries.filter(entry => entry.payload.kind === 'placed');
      assert(placements.filter(entry => entry.epoch === after.node.epoch).length === 1,
        'replacement publishes exactly one placement');
      if (id === 7) assert(!placements.some(entry => entry.epoch === before.node.epoch),
        'pending old worker never publishes a placement');
      return {id, fault: id === 7 ? 'kill_node_starting' : 'kill_node_stopping',
        injection: `Worker.terminate at observed ${before.node.workers[0].phase}`,
        outcome: `${before.node.workers[0].phase}_death_replaced_at_epoch_${after.node.epoch}`,
        witness: {killOutcome: killed.ok, replacementBeforeRelease: blocked.error,
          capturedMessage: captured.kind, capturedMessageReplay: 'detached_handle_ignored',
          pendingCallbacksBeforeKill: before.pendingCallbacks,
          oldEpoch: before.node.epoch, newEpoch: after.node.epoch,
          nativeLeaseWaitMs, childLeasesAfterDeath,
          oldPlacements: placements.filter(entry => entry.epoch === before.node.epoch).length,
          newPlacements: placements.filter(entry => entry.epoch === after.node.epoch).length,
          replacementTicks: after.ticks.length, detachedCallbackChangedState,
          ...(id === 9 ? {stoppingPlacementHeld: heldBefore.includes(`${prefix}:place:0:nodeA:1`),
            pendingStopOutcome: stopResult.error} : {})}};
    } finally {
      for (const node of actors) node.kill();
      for (const lease of held) await lease.release();
      store.close();
    }
  }
  root.KiteLifecycleTests = {async run() {
    try { return {ok: true, value: [await fault(7), await fault(9)]}; }
    catch (error) { return {ok: false, error: String(error.stack || error)}; }
  }};
})(globalThis);
