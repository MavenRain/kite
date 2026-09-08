/* Browser orchestration. Feed, Service and Volume policy stays in native models. */
(function (root) {
  "use strict";
  const ok = value => ({ok: true, value});
  const fail = error => ({ok: false, error});
  const metadata = {store: "meta", key: "state", as: "state"};
  const log = {store: "log", all: true, as: "entries"};
  const snapshot = read => ({...read.state, entries: read.entries});
  const refused = error => fail(String(error && error.message || error));

  function volume(glue, store, model, options) {
    const {prefix, namespace, ordinal, firstTicket = 0, onCommit = () => {}} = options;
    const created = model.volume(namespace, ordinal, firstTicket);
    if (!created.ok) return created;
    let state = created.value;
    const key = `${namespace}:${ordinal}`;
    const name = `${prefix}:volume:${key}`;
    const row = {store: "volumes", key, as: "volume"};
    const leases = new Map();
    const transactions = new Map();
    const tasks = new Set();
    let discarded = false;
    const view = () => model.volumeView(state).value;
    const durable = read => read.volume || {
      key, epoch: read.state.epoch, generation: 0, committed: {revision: 0, entries: []}
    };
    function dispatch(event) {
      const stepped = model.volumeStep(state, event);
      if (!stepped.ok) return Promise.resolve(stepped);
      state = stepped.value.state;
      const pending = stepped.value.actions.map(action => {
        const task = perform(action).catch(refused);
        tasks.add(task);
        task.finally(() => tasks.delete(task));
        return task;
      });
      return Promise.all(pending).then(results =>
        results.find(result => !result.ok) || ok(view()));
    }
    async function acquire(action) {
      const acquired = await glue.lock(name);
      if (!acquired.ok || !acquired.value) {
        return discarded ? acquired : dispatch({kind: "lock_refused", ticket: action.lease.ticket});
      }
      const lease = acquired.value;
      leases.set(action.lease.ticket, lease);
      if (discarded) {
        leases.delete(action.lease.ticket);
        return lease.release();
      }
      const read = await store.atomic({mode: "readonly", reads: [metadata, row],
        lease: {name, value: lease}, plan: read => durable(read).epoch > read.state.epoch
          ? fail("invalid_snapshot") : ok({receipt: {...durable(read), epoch: read.state.epoch}})});
      if (discarded) {
        leases.delete(action.lease.ticket);
        await lease.release();
        return fail("discarded");
      }
      if (!read.ok) {
        leases.delete(action.lease.ticket);
        await lease.release();
        return dispatch({kind: "lock_refused", ticket: action.lease.ticket});
      }
      return dispatch({kind: "lock_acquired", ticket: action.lease.ticket, durable: read.value});
    }
    async function commit(action) {
      const ticket = action.kind === "claim_writer" ? action.lease.ticket : action.ticket;
      const lease = leases.get(action.lease.ticket);
      const pending = store.atomic({reads: [metadata, row], lease: {name, value: lease},
        plan: read => {
          const previous = durable(read);
          if (previous.epoch > read.state.epoch) return fail("invalid_snapshot");
          const applied = model.atomicVolume({...previous, epoch: read.state.epoch}, action);
          if (!applied.ok) return applied;
          return ok({writes: [{store: "volumes", key, value: applied.value.snapshot}],
            receipt: applied.value.receipt});
        }});
      transactions.set(ticket, pending);
      const result = await pending;
      transactions.delete(ticket);
      if (discarded) return result;
      const stepped = await dispatch({kind: action.kind === "claim_writer" ? "claimed" : "completed",
        ticket, result});
      if (result.ok && action.kind === "commit_checkpoint") onCommit(view().committed);
      return result.ok ? stepped : result;
    }
    async function perform(action) {
      switch (action.kind) {
        case "acquire_lock": return acquire(action);
        case "claim_writer":
        case "commit_checkpoint": return commit(action);
        case "abort_claim":
        case "abort_write": {
          const ticket = action.kind === "abort_claim" ? action.lease.ticket : action.ticket;
          const pending = transactions.get(ticket);
          if (pending && pending.abort) pending.abort();
          return ok(undefined);
        }
        case "release_lock": {
          const lease = leases.get(action.lease.ticket);
          if (!lease) return ok(undefined);
          const released = await lease.release();
          if (!released.ok) return released;
          leases.delete(action.lease.ticket);
          const current = view();
          return !discarded && current.phase === "releasing" && current.ticket >= action.lease.ticket
            ? dispatch({kind: "released", ticket: action.lease.ticket}) : released;
        }
        default: return fail("invalid_action");
      }
    }
    async function settled() {
      while (tasks.size) await Promise.all([...tasks]);
      return ok(view());
    }
    const host = {
      view, settled,
      async attach(epoch) {
        if (discarded) return fail("discarded");
        const attached = await dispatch({kind: "attach", epoch});
        if (!attached.ok) return attached;
        const current = view();
        return current.mode === "active" && current.phase === "attached" ? ok(current)
          : current.lastResult && !current.lastResult.ok ? current.lastResult : fail("volume_not_attached");
      },
      prepare: entries => dispatch({kind: "prepare", entries}),
      begin: () => dispatch({kind: "begin_write", ticket: view().ticket}),
      async checkpoint(entries) {
        const prepared = await host.prepare(entries);
        return prepared.ok ? host.begin() : prepared;
      },
      async freeze() {
        const frozen = await dispatch({kind: "freeze"});
        await settled();
        if (!frozen.ok) return frozen;
        const current = view();
        return current.mode === "frozen" && !current.lockHeld ? ok(current) : fail("freeze_incomplete");
      },
      async resume(epoch) {
        await settled();
        return discarded ? fail("discarded") : host.attach(epoch);
      },
      async discard() {
        discarded = true;
        for (const pending of transactions.values()) if (pending.abort) pending.abort();
        await settled();
        for (const lease of leases.values()) {
          const released = await lease.release();
          if (!released.ok) return released;
        }
        leases.clear();
        return dispatch({kind: "discard"});
      }
    };
    return ok(host);
  }

  function feed(glue, store, model, options) {
    const {prefix, interval = 1000, onEntries = () => {}, onError = () => {},
      doorbells = true} = options;
    if (interval !== null && (!Number.isSafeInteger(interval) || interval <= 0)) {
      return fail("invalid_interval");
    }
    let state = model.feed();
    let cursor = 0;
    let running;
    let stopped = false;
    async function read() {
      const read = await store.read();
      if (!read.ok || stopped) return read;
      const applied = model.feedApply(state, read.value);
      if (!applied.ok) return applied;
      state = applied.value.state;
      cursor = applied.value.cursor;
      if (applied.value.accepted.length) onEntries(applied.value.accepted, read.value);
      return ok(read.value);
    }
    function poll() {
      if (stopped) return Promise.resolve(fail("stopped"));
      if (running) return running;
      running = read().catch(refused).then(result => {
        if (!result.ok) onError(result.error);
        return result;
      }).finally(() => { running = undefined; });
      return running;
    }
    const channel = doorbells ? glue.doorbell(`${prefix}:feed`, seq => {
      const hinted = model.feedNotify(state, seq);
      if (!hinted.ok) { onError(hinted.error); return; }
      state = hinted.value;
      void poll();
    }) : fail("doorbells_disabled");
    const timer = interval === null ? ok(() => {}) : glue.every(interval, () => { void poll(); });
    if (!timer.ok) {
      if (channel.ok) channel.value.close();
      return timer;
    }
    return ok({poll, view: () => ({cursor, state}),
      ring: seq => channel.ok ? channel.value.ring(seq) : ok(undefined),
      stop() {
        stopped = true;
        timer.value();
        if (channel.ok) channel.value.close();
        return running || Promise.resolve(ok(undefined));
      }});
  }

  function services(store, model, {ring = () => {}, onError = () => {}} = {}) {
    // The doorbell runs after the transaction. A doorbell failure must not
    // rewrite a settled receipt, so this reports the failure instead.
    async function notify(seq) {
      try {
        await ring(seq);
      } catch (error) {
        onError(String(error && error.message || error));
      }
    }
    async function submit(epoch, event) {
      const result = await store.atomic({reads: [metadata, log], plan: read => {
        if (read.state.epoch !== epoch) return fail("stale_epoch");
        const checked = model.serviceCheck(snapshot(read), epoch, event);
        if (!checked.ok) return checked;
        if (checked.value.duplicate) return ok({receipt: {...checked.value, seq: read.state.seq}});
        if (read.state.seq >= 1000000000) return fail("counter_exhausted");
        const seq = read.state.seq + 1;
        return ok({writes: [
          {store: "meta", key: "state", value: {...read.state, seq}},
          {store: "log", add: true, value: {seq, epoch, payload: {kind: "service", event}}}
        ], receipt: {...checked.value, seq}});
      }});
      if (result.ok && !result.value.duplicate) await notify(result.value.seq);
      return result;
    }
    return {submit,
      register: (epoch, name) => submit(epoch, {kind: "register", name}),
      handshake: (epoch, source) => submit(epoch, {kind: "handshake", source}),
      send: (epoch, publication) => submit(epoch, {kind: "send", publication}),
      async restore() {
        const read = await store.read();
        return read.ok ? model.serviceRestore(read.value) : read;
      }};
  }
  root.KiteDurable = {volume, feed, services};
})(globalThis);
