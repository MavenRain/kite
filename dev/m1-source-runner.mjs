// Browser observations enter Kite through narrow, first-order import contracts.
export async function runAcceptance(host, {quick = false} = {}) {
  const origin = Date.now();
  let desiredAt = Infinity;
  let nextProgress = Date.now();
  const metrics = {};
  async function view(id) {
    const observed = await host.view(id);
    const locks = await host.locks();
    const prefix = `kite:${host.cluster}:`;
    const nodes = new Map();
    let desired = 0;
    for (const entry of observed.log?.entries || []) {
      if (entry.payload.kind === 'heartbeat') nodes.set(entry.payload.nodeId, entry.payload);
      if (entry.payload.kind === 'desired') desired = entry.payload.count;
    }
    const running = observed.node.workers.filter(worker => worker.phase === 'running');
    const ticks = running.map(worker => observed.ticks.find(tick =>
      tick.pod === worker.pod && tick.ticket === worker.ticket &&
      tick.incarnation === worker.incarnation)).filter(Boolean);
    const snapshot = observed.planning?.snapshot;
    const currentPlan = observed.leaderEpoch > 0 && snapshot?.epoch === observed.leaderEpoch &&
      snapshot.epoch === observed.node.epoch;
    return {
      registered: [...nodes.values()].filter(node =>
        locks.held.includes(`${prefix}node:${node.nodeId}`)).length,
      running: running.length,
      working: ticks.length,
      fresh: ticks.filter(tick => tick.at >= desiredAt).length,
      checksum: ticks.every(tick => tick.value === -1734620768),
      leader_epoch: observed.leaderEpoch,
      epoch: observed.node.epoch,
      desired,
      placements: currentPlan ? snapshot.placements.length : 0,
      pod_locks: currentPlan ? snapshot.podLocks.length : 0,
      pending: locks.pending.filter(name => name === `${prefix}leader`).length
    };
  }
  async function dispatch(name, argument) {
    switch (name) {
      case 'host_open': await host.open(argument); return null;
      case 'host_close': await host.close(argument); return null;
      case 'host_desired': {
        const changed = await host.desired(argument.id, argument.count);
        desiredAt = changed.startedAt;
        return desiredAt - origin;
      }
      case 'host_view': return view(argument);
      case 'host_duplicate': {
        const proof = await host.duplicate(argument.id, argument.index);
        console.log(`M1 duplicate ${JSON.stringify(proof)}`);
        return proof.soleOwner && !proof.loserWorked && proof.refusal.exited &&
          proof.replayedSeq >= proof.appendedSeq;
      }
      case 'host_hide': await host.hide(); return null;
      case 'host_age': {
        const ages = await host.hiddenAges();
        if (ages.length !== 2 || !ages.every(age => age.hidden)) {
          throw new Error('both cluster tabs must remain hidden');
        }
        const age = Math.floor(Math.min(...ages.map(value => value.hiddenForMs)));
        if (Date.now() >= nextProgress) {
          console.log(`M1 hidden_age_ms=${age} nodes=${ages.map(value => value.node).join(',')}`);
          nextProgress = Date.now() + 30000;
        }
        return age;
      }
      case 'host_wait': await host.wait(argument); return null;
      case 'host_now': return Date.now() - origin;
      case 'host_quick': return quick;
      case 'host_assert': host.assert(argument.condition, argument.label); return null;
      case 'host_report': await host.report(argument, {...metrics}); return null;
      case 'host_metric':
        metrics[argument.label] = argument.value;
        console.log(`M1 ${argument.label}=${argument.value}`);
        return null;
      default: throw new Error(`unavailable source import: ${name}`);
    }
  }
  const result = await host.runPage(
    'KiteAcceptance.run(() => KiteSource.run(KiteArtifact, (name, argument) => KiteAcceptance.call(name, argument)))',
    dispatch);
  if (!result?.ok) throw new Error(`Kite acceptance source failed: ${JSON.stringify(result)}`);
  console.log('SOURCE-ACCEPTANCE OK file=test/acceptance.kite');
}
