/* M2-C durable faults use real IndexedDB, Web Locks and BroadcastChannel. */
(function (root) {
  "use strict";
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const value = (result, label) => {
    assert(result && result.ok, `${label}: ${result && result.error}`);
    return result.value;
  };
  const equal = (actual, expected, label) => assert(JSON.stringify(actual) === JSON.stringify(expected),
    `${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  const ok = value => ({ok: true, value});
  const outcome = result => result.ok ? "committed" : result.error;
  const sleep = milliseconds => new Promise(done => setTimeout(done, milliseconds));
  async function until(predicate, label) {
    const deadline = Date.now() + 5000;
    while (!predicate() && Date.now() < deadline) await sleep(10);
    assert(predicate(), `${label}: timed out`);
  }
  const metadata = {store: "meta", key: "state", as: "state"};
  const volumeRow = {store: "volumes", key: "state:0", as: "volume"};
  const volumeReads = [metadata, volumeRow];

  async function fixture(run) {
    const glue = root.KiteGlue;
    const model = root.KiteDurableModel;
    const durable = root.KiteDurable;
    const prefix = `kite-m2c-durable-${crypto.randomUUID()}`;
    const store = value(await glue.open(prefix), "open fault database");
    const cleanup = [];
    const defer = operation => cleanup.push(operation);
    try {
      value(await store.claim(0, "leaderA"), "claim initial epoch");
      const readVolume = async (connection = store) => value(await connection.atomic({
        mode: "readonly", reads: volumeReads, plan: read => ok({receipt: read.volume})
      }), "read committed volume");
      const reopenVolume = async () => {
        const reopened = value(await glue.open(prefix), "reopen volume connection");
        try { return await readVolume(reopened); }
        finally { value(reopened.close(), "close recovery connection"); }
      };
      return await run({glue, model, durable, prefix, store, defer, readVolume, reopenVolume});
    } finally {
      for (const operation of cleanup.reverse()) await operation();
      value(store.close(), "close fault database");
    }
  }

  function volumeHarness(f) {
    const events = [];
    const hooks = {};
    let lease;
    let write;
    const name = `${f.prefix}:volume:state:0`;
    const hostGlue = {...f.glue, async lock(lockName) {
      const acquired = await f.glue.lock(lockName);
      if (acquired.ok && acquired.value) {
        lease = acquired.value;
        const original = lease.release.bind(lease);
        // Preserve the actual lease identity checked by Glue's WeakMap.
        lease.release = async () => {
          events.push({event: "release_requested"});
          const released = await original();
          events.push({event: "released", outcome: released.ok ? "released" : released.error});
          return released;
        };
      }
      return acquired;
    }};
    let currentOperation;
    const hostModel = {...f.model, atomicVolume(snapshot, operation) {
      currentOperation = operation.kind;
      if (operation.kind === "commit_checkpoint") write = operation;
      const applied = f.model.atomicVolume(snapshot, operation);
      events.push({event: "planned", operation: operation.kind,
        outcome: applied.ok ? "accepted" : applied.error});
      if (hooks.onPlan) hooks.onPlan(operation, applied);
      return applied;
    }};
    const hostStore = {atomic(request) {
      let operation = "read";
      const pending = f.store.atomic({...request, plan: read => {
        currentOperation = "read";
        const planned = request.plan(read);
        operation = currentOperation;
        return planned;
      }});
      // The real promise settles only from the IDB transaction terminal event.
      const observed = pending.then(result => {
        events.push({event: "terminal", operation, outcome: outcome(result)});
        if (hooks.onTerminal) hooks.onTerminal(operation, result);
        return result;
      });
      observed.abort = () => {
        const result = pending.abort ? pending.abort() : {ok: false, error: "transaction_unavailable"};
        events.push({event: "abort_requested", operation,
          outcome: result.ok ? "requested" : result.error});
        return result;
      };
      return observed;
    }};
    const host = value(f.durable.volume(hostGlue, hostStore, hostModel,
      {prefix: f.prefix, namespace: "state", ordinal: 0,
        onCommit: checkpoint => {
          events.push({event: hooks.dropNotification ? "notification_dropped" : "notification_delivered",
            revision: checkpoint.revision});
        }}), "create volume host");
    f.defer(() => host.discard());
    return {host, events, hooks, name, lease: () => lease, write: () => write};
  }

  async function droppedDoorbell() {
    return fixture(async f => {
      const delivered = [];
      const errors = [];
      let ticks = 0;
      let reads = 0;
      const observedGlue = {...f.glue, every(milliseconds, callback) {
        return f.glue.every(milliseconds, () => { ticks += 1; callback(); });
      }};
      // Count every read of the durable connection. A read that the probe
      // issues by itself raises this count without raising the feed count,
      // so the witness below can fail.
      let storeReads = 0;
      const readStore = () => { storeReads += 1; return f.store.read(); };
      const observedStore = {async read() { reads += 1; return readStore(); }};
      const probeStore = {read: () => readStore(),
        append: (epoch, payload) => f.store.append(epoch, payload)};
      const feed = value(f.durable.feed(observedGlue, observedStore, f.model, {
        prefix: f.prefix, interval: 20, doorbells: false,
        onEntries: entries => delivered.push(...entries.map(entry => entry.seq)),
        onError: error => errors.push(error)
      }), "create polling feed");
      f.defer(() => feed.stop());
      value(await feed.poll(), "read initial prefix");
      const beforeTicks = ticks;
      const beforeReads = reads;
      const committed = value(await probeStore.append(1, {kind: "final_without_hint"}), "commit final write");
      const manualAtAppend = storeReads - reads;
      await until(() => feed.view().cursor === committed.seq, "periodic discovery of final write");
      assert(ticks > beforeTicks && reads > beforeReads, "a real timer caused a durable read");
      const manualReadsAfterAppend = storeReads - reads - manualAtAppend;
      assert(manualReadsAfterAppend === 0, "no probe read of its own discovered the final write");
      equal(delivered, Array.from({length: committed.seq}, (_, index) => index + 1), "contiguous delivery");
      equal(errors, [], "valid polling outcomes");
      return {id: 1, fault: "Drop the final doorbell",
        injection: "Commit the final record without sending a BroadcastChannel hint; disable feed doorbells.",
        outcome: "committed_then_discovered_by_periodic_read",
        witness: {committedSequence: committed.seq, cursor: feed.view().cursor,
          periodicTicks: ticks - beforeTicks, durableReads: reads - beforeReads,
          manualReadsAfterAppend, delivered}};
    });
  }

  async function reorderedDoorbells() {
    return fixture(async f => {
      const received = [];
      const delivered = [];
      const errors = [];
      const observedGlue = {...f.glue, doorbell(name, callback) {
        return f.glue.doorbell(name, seq => { received.push(seq); callback(seq); });
      }};
      const feed = value(f.durable.feed(observedGlue, f.store, f.model, {
        prefix: f.prefix, interval: null,
        onEntries: entries => delivered.push(...entries.map(entry => entry.seq)),
        onError: error => errors.push(error)
      }), "create doorbell feed");
      f.defer(() => feed.stop());
      value(await feed.poll(), "initial doorbell feed prefix");
      value(await f.store.append(1, {kind: "hint_order_first"}), "first hinted write");
      const committed = value(await f.store.append(1, {kind: "hint_order_final"}), "final hinted write");
      const bell = value(f.glue.doorbell(`${f.prefix}:feed`, () => {}), "create actual hint sender");
      f.defer(() => bell.close());
      const sent = [committed.seq, 1, committed.seq, 0];
      for (const seq of sent) value(bell.ring(seq), "send reordered duplicate hint");
      await until(() => received.length === sent.length && feed.view().cursor === committed.seq,
        "actual BroadcastChannel deliveries and durable projection");
      value(await feed.poll(), "replay complete durable prefix");
      equal(received, sent, "actual delivered hints preserve the injected duplicate and reordered values");
      equal(delivered, Array.from({length: committed.seq}, (_, index) => index + 1), "one contiguous projection");
      equal(new Set(delivered).size, delivered.length, "duplicate hint delivers no duplicate entry");
      equal(errors, [], "valid hint outcomes");
      return {id: 2, fault: "Reorder and duplicate doorbells",
        injection: "Send descending and repeated sequence hints through a separate real BroadcastChannel.",
        outcome: "contiguous_once_only_delivery", witness: {sent, received, delivered,
          cursor: feed.view().cursor, uniqueDeliveries: new Set(delivered).size}};
    });
  }

  async function oldEpoch() {
    return fixture(async f => {
      value(await f.store.append(1, {kind: "old_leader_checkpoint"}), "old leader progress");
      value(await f.store.claim(1, "leaderB"), "successor epoch claim");
      const before = value(await f.store.read(), "read before old epoch write");
      const refused = await f.store.append(1, {kind: "stale_leader_write"});
      equal(refused, {ok: false, error: "stale_epoch"}, "old leader transaction refused");
      const after = value(await f.store.read(), "read after old epoch write");
      const committedDataUnchanged = JSON.stringify(after) === JSON.stringify(before);
      equal(after, before, "old leader refusal preserves all committed records");
      return {id: 3, fault: "Write from an old leader epoch",
        injection: "Append with epoch 1 after the real IndexedDB successor claim commits epoch 2.",
        outcome: refused.error, witness: {attemptedEpoch: 1, durableEpoch: after.epoch,
          sequenceBefore: before.seq, sequenceAfter: after.seq, committedDataUnchanged}};
    });
  }

  async function oldGeneration() {
    return fixture(async f => {
      const h = volumeHarness(f);
      value(await h.host.attach(1), "attach initial volume writer");
      value(await h.host.checkpoint(["before-handoff"]), "commit initial checkpoint");
      const oldWrite = h.write();
      const oldFence = {...h.host.view().writer};
      value(await h.host.freeze(), "release initial writer");
      value(await h.host.resume(1), "same epoch writer handoff");
      const before = await f.readVolume();
      assert(before.generation > oldFence.generation && before.epoch === oldFence.epoch,
        "handoff obtains a fresh generation in the same epoch");
      const refused = await f.store.atomic({reads: volumeReads,
        lease: {name: h.name, value: h.lease()}, plan: read => {
          const applied = f.model.atomicVolume({...read.volume, epoch: read.state.epoch}, oldWrite);
          return applied.ok ? ok({writes: [{store: "volumes", key: "state:0", value: applied.value.snapshot}],
            receipt: applied.value.receipt}) : applied;
        }});
      equal(refused, {ok: false, error: "stale_generation"}, "captured native write capability refused");
      const after = await f.reopenVolume();
      const checkpointUnchanged = JSON.stringify(after) === JSON.stringify(before);
      equal(after, before, "generation refusal preserves durable checkpoint");
      return {id: 4, fault: "Write from an old volume generation in the same epoch",
        injection: "Replay the previous writer's genuine native operation in a real transaction under the successor lease.",
        outcome: refused.error, witness: {epoch: after.epoch, attemptedGeneration: oldFence.generation,
          durableGeneration: after.generation, revision: after.committed.revision, checkpointUnchanged}};
    });
  }

  async function duplicateServiceSend() {
    return fixture(async f => {
      const service = f.durable.services(f.store, f.model);
      const source = {service: "events", sender: "senderA", incarnation: 1, session: 1};
      const publication = {source, sequence: 1, payload: "once"};
      value(await service.register(1, "events"), "register named service");
      value(await service.handshake(1, source), "first sender handshake");
      value(await service.send(1, publication), "first logical send");
      const before = value(await f.store.read(), "read before duplicate send");
      const replay = value(await service.send(1, publication), "identical logical send replay");
      assert(replay.duplicate, "identical logical send is classified as duplicate");
      const changed = await service.send(1, {...publication, payload: "changed"});
      equal(changed, {ok: false, error: "conflicting_replay"}, "changed logical send refused");
      const after = value(await f.store.read(), "read after logical send replays");
      equal(after, before, "replays append no new records");
      const restored = value(await service.restore(), "restore actual recorded service deliveries");
      equal(restored.messages.length, 1, "one recorded service delivery");
      equal(restored.messages[0].publication, publication, "original payload remains authoritative");
      return {id: 5, fault: "Duplicate a logical Service send",
        injection: "Resubmit one publication identity unchanged, then with a changed payload.",
        outcome: "duplicate_then_conflicting_replay", witness: {duplicate: replay.duplicate,
          changedPayloadRefusal: changed.error, recordedDeliveries: restored.messages.length,
          sequenceBefore: before.seq, sequenceAfter: after.seq, publication}};
    });
  }

  async function oldHandshake() {
    return fixture(async f => {
      const service = f.durable.services(f.store, f.model);
      const old = {service: "events", sender: "senderA", incarnation: 1, session: 1};
      const fresh = {...old, session: 2};
      value(await service.register(1, "events"), "register handshake service");
      value(await service.handshake(1, old), "initial handshake");
      value(await service.handshake(1, fresh), "new session handshake");
      value(await service.send(1, {source: fresh, sequence: 1, payload: "new-session-first"}), "new session progress");
      const before = value(await f.store.read(), "read before stale handshake");
      const refused = await service.handshake(1, old);
      equal(refused, {ok: false, error: "stale_session"}, "old handshake refused");
      const afterRefusal = value(await f.store.read(), "read after stale handshake");
      const refusedHandshakePreservedLog = JSON.stringify(afterRefusal) === JSON.stringify(before);
      equal(afterRefusal, before, "stale handshake appends nothing");
      value(await service.send(1, {source: fresh, sequence: 2, payload: "new-session-second"}),
        "new session sequence remains authoritative");
      const restored = value(await service.restore(), "restore session after stale handshake");
      equal(restored.sessions, [{source: fresh, nextSequence: 3}], "latest session and progress retained");
      equal(restored.messages.map(message => message.publication.source.session), [2, 2], "only fresh session delivers");
      return {id: 6, fault: "Replay an old Service handshake",
        injection: "Replay session 1 after session 2 has committed its first message, then send session 2 sequence 2.",
        outcome: refused.error, witness: {attemptedSession: old.session, activeSession: fresh.session,
          nextSequence: restored.sessions[0].nextSequence, recordedDeliveries: restored.messages.length,
          refusedHandshakePreservedLog}};
    });
  }

  async function freezePrepared() {
    return fixture(async f => {
      const h = volumeHarness(f);
      value(await h.host.attach(1), "attach prepared-freeze writer");
      value(await h.host.checkpoint(["recoverable"]), "commit prior checkpoint");
      const before = await f.readVolume();
      h.events.length = 0;
      value(await h.host.prepare(["drop-prepared"]), "prepare unpublished changes");
      equal(h.host.view().phase, "prepared", "preparation exists before freeze");
      const frozen = value(await h.host.freeze(), "freeze before transaction submission");
      equal(frozen.mode, "frozen", "freeze completes");
      equal(frozen.lockHeld, false, "freeze releases volume lease");
      assert(!h.events.some(event => event.operation === "commit_checkpoint"), "prepared freeze submits no transaction");
      const recovered = await f.reopenVolume();
      equal(recovered, before, "reopening recovers the exact prior checkpoint");
      equal(frozen.pending, null, "prepared changes are dropped");
      return {id: 10, fault: "Freeze before checkpoint submission",
        injection: "Freeze an attached writer after prepare and before begin_write.",
        outcome: "frozen_without_checkpoint_submission", witness: {preparedPhaseObserved: "prepared",
          checkpointTransactions: 0, recovered: recovered.committed, pending: frozen.pending,
          lockHeld: frozen.lockHeld, events: h.events}};
    });
  }

  async function freezeDuringTransaction() {
    return fixture(async f => {
      const h = volumeHarness(f);
      value(await h.host.attach(1), "attach transaction-freeze writer");
      value(await h.host.checkpoint(["prior"]), "commit transaction-freeze baseline");
      const before = await f.readVolume();
      h.events.length = 0;
      let frozen;
      h.hooks.onPlan = (operation, applied) => {
        if (operation.kind !== "commit_checkpoint" || !applied.ok) return;
        h.hooks.onPlan = undefined;
        // The native plan returns to Glue, which queues the real writes before
        // this microtask requests freeze, while the IDB transaction is active.
        queueMicrotask(() => {
          h.events.push({event: "freeze_injected"});
          frozen = h.host.freeze();
        });
      };
      const racing = await h.host.checkpoint(["transaction-race"]);
      assert(frozen, "freeze was injected from the actual transaction plan callback");
      const frozenView = value(await frozen, "freeze waits for actual transaction settlement");
      const terminal = h.events.findIndex(event => event.event === "terminal" && event.operation === "commit_checkpoint");
      const release = h.events.findIndex(event => event.event === "release_requested");
      const injected = h.events.findIndex(event => event.event === "freeze_injected");
      assert(injected >= 0 && terminal > injected && release > terminal,
        "real terminal outcome follows freeze and precedes lease release");
      assert(h.events.some(event => event.event === "abort_requested"), "freeze requests actual transaction abort");
      equal(frozenView.lockHeld, false, "lease absent after settlement");
      const recovered = await f.reopenVolume();
      equal(frozenView.committed, recovered.committed, "in-memory settlement agrees with reopened durable prefix");
      equal(recovered.committed, racing.ok
        ? {revision: before.committed.revision + 1, entries: [...before.committed.entries, "transaction-race"]}
        : before.committed, "transaction leaves a complete write or unchanged prior checkpoint");
      const successor = value(await f.glue.lock(h.name), "successor tests released volume lease");
      const successorAcquired = Boolean(successor);
      assert(successorAcquired, "successor obtains real volume lease after settlement");
      value(await successor.release(), "release witness successor");
      return {id: 11, fault: "Freeze during the transaction",
        injection: "Queue freeze from the real transaction plan callback after Glue queues checkpoint writes.",
        outcome: outcome(racing), witness: {events: h.events, freezeIndex: injected, terminalIndex: terminal,
          releaseIndex: release, recovered: recovered.committed, lockHeld: frozenView.lockHeld,
          successorAcquired}};
    });
  }

  async function freezeBeforeNotification() {
    return fixture(async f => {
      const h = volumeHarness(f);
      value(await h.host.attach(1), "attach notification-freeze writer");
      value(await h.host.checkpoint(["prior"]), "commit notification-freeze baseline");
      const before = await f.readVolume();
      h.events.length = 0;
      let frozen;
      h.hooks.dropNotification = true;
      h.hooks.onTerminal = (operation, result) => {
        if (operation !== "commit_checkpoint" || !result.ok) return;
        h.hooks.onTerminal = undefined;
        h.events.push({event: "freeze_injected_before_receipt"});
        // Forward the genuine receipt after starting freeze. Awaiting freeze
        // here would deadlock its wait for this same transaction task.
        frozen = h.host.freeze();
      };
      value(await h.host.checkpoint(["committed-without-notification"]), "actual checkpoint commits");
      assert(frozen, "freeze was injected after actual IDB completion");
      value(await frozen, "postcommit freeze settles");
      const terminal = h.events.findIndex(event => event.event === "terminal" && event.operation === "commit_checkpoint");
      const injected = h.events.findIndex(event => event.event === "freeze_injected_before_receipt");
      const dropped = h.events.findIndex(event => event.event === "notification_dropped");
      assert(terminal >= 0 && injected > terminal && dropped > injected,
        "commit precedes freeze and the discarded observer notification");
      const notificationsDelivered = h.events.filter(event => event.event === "notification_delivered").length;
      const notificationsDropped = h.events.filter(event => event.event === "notification_dropped").length;
      equal(notificationsDelivered + notificationsDropped, 1,
        "the committed checkpoint raises exactly one observer notification");
      equal(notificationsDropped, 1, "one committed notification is deliberately discarded");
      const recovered = await f.reopenVolume();
      equal(recovered.committed, {revision: before.committed.revision + 1,
        entries: [...before.committed.entries, "committed-without-notification"]},
      "reopen discovers committed write despite notification loss");
      return {id: 12, fault: "Freeze after commit before notification",
        injection: "Start freeze after real IDB completion before forwarding its receipt; discard the onCommit observer notification.",
        outcome: "committed_and_recovered_without_notification", witness: {events: h.events,
          terminalIndex: terminal, freezeIndex: injected, droppedNotificationIndex: dropped,
          notificationsDelivered, notificationsDropped, recovered: recovered.committed}};
    });
  }

  root.KiteM2DurableTests = {async run() {
    try {
      const rows = [];
      for (const run of [droppedDoorbell, reorderedDoorbells, oldEpoch, oldGeneration,
        duplicateServiceSend, oldHandshake, freezePrepared, freezeDuringTransaction, freezeBeforeNotification]) {
        rows.push(await run());
      }
      return ok({rows});
    } catch (error) { return {ok: false, error: String(error.stack || error)}; }
  }};
})(globalThis);
