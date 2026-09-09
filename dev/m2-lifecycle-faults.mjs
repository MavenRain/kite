/* Harness-level node death and source StatefulSet recovery witnesses. */
export async function runLifecycleFaults(harness) {
  const {origin, page, outcome, poll, cdp, artifacts, sourcePage, sourceView,
    sourceCheckpoint, closeSource, killSource} = harness;
  const observer = await page(`${origin}/test/browser.html`);
  let tab;
  let failure;
  const require = (condition, message) => { if (!condition) throw new Error(`M2 lifecycle: ${message}`); };
  const attached = view => view.node.nodeLock && view.node.workers.length === 1 &&
    view.node.workers[0].phase === 'running' && view.volumes.length === 1 &&
    view.volumes[0].phase === 'attached' && view.volumes[0].writer &&
    view.ticks.some(tick => tick.ticket === view.node.workers[0].ticket);
  try {
    await poll(observer.session, "typeof KiteLifecycleTests !== 'undefined'", 15000);
    const rows = await outcome(observer.session, 'KiteLifecycleTests.run()');
    const cluster = `m2-running-${Date.now()}`;
    const marker = `running-prefix-${Date.now()}`;
    tab = await sourcePage(origin, artifacts['stateful-set'], cluster, 'killedA');
    await sourceView(tab, 'data', attached, 'M2 Running injection ready');
    const before = await sourceCheckpoint(tab, marker);
    const prior = before.volumes[0];
    const death = await killSource(tab);
    tab = undefined;
    tab = await sourcePage(origin, artifacts['stateful-set'], cluster, 'replacementB');
    const after = await sourceView(tab, 'data', view => attached(view) &&
      view.volumes[0].committed.entries.includes(marker), 'M2 Running durable recovery');
    const recovered = after.volumes[0];
    require(recovered.key === prior.key && recovered.writer.generation > prior.writer.generation &&
      after.node.epoch > before.node.epoch, 'Running replacement requires stable identity and a fresh writer fence');
    require(prior.committed.entries.every((entry, index) => recovered.committed.entries[index] === entry),
      'Running recovery must preserve the complete committed prefix');
    rows.push({id: 8, fault: 'kill_node_running',
      injection: 'Worker.terminate at observed running without graceful drain',
      outcome: `running_death_recovered_at_epoch_${after.node.epoch}` +
        `_generation_${recovered.writer.generation}`,
      witness: {...death,
        observedPhase: before.node.workers[0].phase, key: recovered.key,
        oldEpoch: before.node.epoch, newEpoch: after.node.epoch,
        oldGeneration: prior.writer.generation, newGeneration: recovered.writer.generation,
        committedPrefixLength: prior.committed.entries.length,
        recoveredLength: recovered.committed.entries.length,
        markerRecovered: recovered.committed.entries.includes(marker)}});
    return rows.sort((left, right) => left.id - right.id);
  } catch (error) {
    failure = error;
    throw error;
  } finally {
    // Close the observer target even when the victim tab cleanup fails, and
    // keep the matrix error. A cleanup failure alone must fail the runner.
    const cleanup = await closeSource(tab).then(() => undefined, error => error);
    const closed = await cdp.send('Target.closeTarget', {targetId: observer.target})
      .then(() => undefined, error => error);
    const trouble = cleanup || closed;
    if (trouble && failure)
      console.error(`lifecycle cleanup failed after the matrix failure: ${String(trouble.message || trouble)}`);
    if (trouble && !failure) throw trouble;
  }
}
