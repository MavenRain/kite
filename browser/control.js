/* One control Worker owns its node lease and every local pod handle. */
importScripts('glue.js', '../_build/default/browser/model.bc.js', 'node-host.js');
const glue = globalThis.KiteGlue;
const model = globalThis.KiteModel;
let host;
let store;
let prefix;
let leader;
let election;
let leaderEpoch = 0;
let cursor = 0;
let heartbeat = -1;
let lastRead;
let lastPlan;
let closed = false;
let generation = 0;
let queue = Promise.resolve();
let freezing;
let resuming;
const ticks = new Map();
// Seconds from a fixed origin fit the shared js_of_ocaml integer range.
const nowTick = () => Math.floor(Date.now() / 1000) - 1700000000;
const append = (epoch, payload, expectedSeq) => store.append(epoch, payload, expectedSeq);
const failure = error => ({ok: false, error: String(error && error.message || error)});
function enqueue(operation) {
  const result = queue.then(operation).catch(failure);
  queue = result.then(() => undefined);
  return result;
}
function elect() {
  if (election || leader || closed || !host ||
      host.view().mode !== 'ready' || !host.view().nodeLock) return;
  const attempt = {abort: new AbortController(), generation,
    incarnation: host.view().incarnation};
  election = attempt;
  const current = () => election === attempt && !closed &&
    generation === attempt.generation && host.view().mode === 'ready' &&
    host.view().nodeLock && host.view().incarnation === attempt.incarnation;
  attempt.done = (async () => {
    const lease = await glue.lock(`${prefix}:leader`, {wait: true, signal: attempt.abort.signal});
    if (!lease.ok || !lease.value) return;
    let adopted = false;
    try {
      if (!current()) return;
      const read = await store.read();
      if (!current() || !read.ok) return;
      const claimed = await store.claim(read.value.epoch, host.view().nodeId);
      if (!claimed.ok || !current()) return;
      leader = lease.value;
      leaderEpoch = claimed.value.epoch;
      adopted = true;
    } finally {
      if (!adopted) await lease.value.release();
    }
  })().catch(error => glue.send(self, {kind: 'diagnostic', ...failure(error)}))
    .finally(() => { if (election === attempt) election = null; });
}
function snapshot(read, held) {
  const nodes = new Map();
  let desired = 0;
  for (const entry of read.entries) {
    const payload = entry.payload;
    if (payload.kind === 'desired') desired = payload.count;
    if (payload.kind === 'heartbeat') nodes.set(payload.nodeId, payload);
  }
  const names = held.filter(name => name.startsWith(`${prefix}:`))
    .map(name => name.slice(prefix.length + 1).split(':'));
  const placements = names.filter(parts => parts[0] === 'place' && parts.length === 4)
    .map(parts => ({pod: Number(parts[1]), owner: parts[2], incarnation: Number(parts[3])}));
  const podLocks = names.filter(parts => parts[0] === 'pod' && parts.length === 2)
    .map(parts => Number(parts[1]));
  const now = nowTick();
  return {desired, now, epoch: read.epoch, placements, podLocks,
    nodes: [...nodes.values()].map(node => ({...node,
      lockHeld: held.includes(`${prefix}:node:${node.nodeId}`)}))};
}
async function reconcile() {
  const startedAt = generation;
  const current = () => !closed && generation === startedAt &&
    host.view().mode === 'ready' && host.view().nodeLock;
  const read = await store.read();
  if (!current()) return {ok: true};
  if (!read.ok) return read;
  lastRead = read.value;
  if (lastRead.epoch > 0) {
    const observed = await host.event({kind: 'observe_epoch', epoch: lastRead.epoch});
    if (!observed.ok) return observed;
    if (!current()) return {ok: true};
  }
  if (host.view().mode !== 'ready' || !host.view().nodeLock) return {ok: true};
  const commands = new Map();
  let desired = 0;
  for (const entry of lastRead.entries) {
    if (entry.payload.kind === 'desired') desired = entry.payload.count;
    if (entry.seq <= cursor) continue;
    cursor = entry.seq;
    const payload = entry.payload;
    if (payload.kind === 'command' && entry.epoch === host.view().epoch &&
        payload.command.owner === host.view().nodeId) {
      commands.set(payload.command.pod, {...payload.command, epoch: entry.epoch});
    }
  }
  for (const command of commands.values()) {
    if (command.incarnation !== host.view().incarnation ||
        (command.kind === 'start' && command.pod >= desired)) continue;
    const applied = await host.event(command);
    if (!applied.ok && applied.error !== 'duplicate_pod') return applied;
    if (!current()) return {ok: true};
  }
  const now = nowTick();
  if (lastRead.epoch > 0 && now !== heartbeat && host.view().nodeLock) {
    const saved = await append(lastRead.epoch, {kind: 'heartbeat',
      nodeId: host.view().nodeId, incarnation: host.view().incarnation,
      heartbeat: now, phase: 'active'});
    if (!saved.ok) return saved;
    // A freeze may have run while the append was open. Its resume resets the
    // heartbeat, so this cycle records the tick only while it is still fresh.
    if (!current()) return {ok: true};
    heartbeat = now;
  }
  const watched = await host.watchdog(Date.now());
  if (watched && !watched.ok) return watched;
  if (!current()) return {ok: true};
  // The election may have claimed its epoch after this cycle took its snapshot.
  if (leader && leaderEpoch < lastRead.epoch) {
    const held = leader;
    leader = null;
    leaderEpoch = 0;
    await held.release();
    if (!current()) return {ok: true};
  }
  if (!leader) { elect(); return {ok: true}; }
  // A heartbeat or another tab may have advanced the log since command replay.
  const fresh = await store.read();
  if (!current()) return {ok: true};
  if (!fresh.ok) return fresh;
  if (fresh.value.epoch !== leaderEpoch) return {ok: false, error: 'stale_epoch'};
  lastRead = fresh.value;
  const locks = await glue.locks();
  if (!current()) return {ok: true};
  if (!locks.ok) return locks;
  const snap = snapshot(lastRead, locks.value);
  const plan = model.plan(snap, leaderEpoch, snap.desired, 5, 64);
  lastPlan = {snapshot: snap, plan};
  if (!plan.ok) return plan;
  let expectedSeq = lastRead.seq;
  for (const command of plan.commands) {
    if (!current()) return {ok: true};
    const saved = await append(leaderEpoch, {kind: 'command', command}, expectedSeq);
    if (!saved.ok) return saved;
    expectedSeq = saved.value.seq;
  }
  return {ok: true};
}
async function loop() {
  if (closed) return;
  const result = await enqueue(() => closed ? {ok: true} : reconcile());
  if (!result.ok) glue.send(self, {kind: 'diagnostic', error: result.error});
  if (!closed) setTimeout(loop, 250);
}
function freeze() {
  generation += 1;
  if (freezing) return freezing;
  const pending = election;
  if (pending) pending.abort.abort();
  const held = leader;
  leader = null;
  leaderEpoch = 0;
  // Invalidate model state before waiting for any ongoing publication.
  const effects = host.event({kind: 'freeze'});
  freezing = Promise.all([effects, held ? held.release() : {ok: true},
    pending ? pending.done : undefined]).then(([result, released]) =>
      result.ok && released && !released.ok ? released : result)
    .finally(() => { freezing = undefined; });
  return freezing;
}
function resume() {
  if (resuming && resuming.generation === generation) return resuming.done;
  const attempt = {generation};
  resuming = attempt;
  attempt.done = (async () => {
    if (freezing) await freezing;
    if (closed) return {ok: false, error: 'closed'};
    if (generation !== attempt.generation) return {ok: false, error: 'lifecycle_changed'};
    const result = await host.event({kind: 'resume'});
    if (closed) return {ok: false, error: 'closed'};
    if (generation !== attempt.generation) return {ok: false, error: 'lifecycle_changed'};
    if (result.ok && !host.view().nodeLock) return {ok: false, error: 'node_unavailable'};
    if (result.ok) { heartbeat = -1; elect(); }
    return result;
  })().finally(() => { if (resuming === attempt) resuming = undefined; });
  return attempt.done;
}
async function request(message) {
  if (message.op === 'boot') {
    if (closed) return {ok: false, error: 'closed'};
    if (host) return {ok: false, error: 'already_booted'};
    if (typeof message.cluster !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(message.cluster))
      return {ok: false, error: 'invalid_cluster'};
    if (typeof message.nodeId !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(message.nodeId))
      return {ok: false, error: 'invalid_node'};
    const startedAt = generation;
    const opened = await glue.open(`kite-${message.cluster}`);
    if (!opened.ok) return opened;
    if (closed || generation !== startedAt) {
      opened.value.close();
      return {ok: false, error: 'lifecycle_changed'};
    }
    store = opened.value;
    prefix = `kite:${message.cluster}`;
    const candidate = new KiteNode(model, glue, {nodeId: message.nodeId, prefix,
      podUrl: 'pod.js', append,
      onTick: tick => { ticks.set(tick.pod, tick); glue.send(self, {kind: 'tick', ...tick}); }});
    const started = candidate.error ? {ok: false, error: candidate.error} : await candidate.boot();
    if (!started.ok || closed || generation !== startedAt) {
      if (!candidate.error) await candidate.event({kind: 'freeze'});
      store.close();
      store = undefined;
      return started.ok ? {ok: false, error: 'lifecycle_changed'} : started;
    }
    host = candidate;
    elect();
    loop();
    return started;
  }
  if (!host) {
    if (message.op === 'freeze' || message.op === 'close') generation += 1;
    if (message.op === 'close') { closed = true; return {ok: true}; }
    return {ok: false, error: 'not_booted'};
  }
  if (closed && message.op !== 'view' && message.op !== 'close')
    return {ok: false, error: 'closed'};
  switch (message.op) {
    case 'view': return {ok: true, value: {node: host.view(), leaderEpoch, cursor,
      duplicateRefusals: host.duplicateRefusals,
      log: lastRead, planning: lastPlan, ticks: [...ticks.values()], error: host.error}};
    case 'desired': {
      if (!Number.isInteger(message.count) || message.count < 0 || message.count > 64)
        return {ok: false, error: 'invalid_desired'};
      const read = await store.read();
      if (!read.ok) return read;
      const payload = {kind: 'desired', count: message.count};
      const saved = await append(read.value.epoch, payload);
      if (saved.ok || saved.error !== 'stale_epoch') return saved;
      // An election claimed a new epoch while this read was open. Retry once
      // at the epoch the log now holds, so the count is not discarded.
      const fresh = await store.read();
      return fresh.ok ? append(fresh.value.epoch, payload) : fresh;
    }
    case 'freeze': return freeze();
    case 'resume': return resume();
    case 'close': {
      if (closed) return freezing || {ok: true};
      closed = true;
      const frozen = await freeze();
      const disconnected = store.close();
      return frozen.ok ? disconnected : frozen;
    }
    default: return {ok: false, error: 'unknown_operation'};
  }
}
glue.listen(message => {
  if (!message || typeof message !== 'object' || Array.isArray(message) ||
      typeof message.op !== 'string') {
    // The refusal echoes the correlation id, so the caller settles at once.
    glue.send(self, {id: message && message.id, ok: false, error: 'invalid_request'});
    return;
  }
  const lifecycle = ['freeze', 'resume', 'close', 'view'].includes(message.op);
  const result = lifecycle ? request(message).catch(failure) : enqueue(() => request(message));
  result.then(answer => glue.send(self, {id: message.id, ...answer}));
});
