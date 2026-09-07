/* Executes Kubelet effects.  The OCaml model owns lifecycle decisions. */
globalThis.KiteNode = class {
  constructor(model, glue, options) {
    this.model = model;
    this.glue = glue;
    this.options = options;
    this.nodes = new Map();
    this.workers = new Map();
    this.duplicateRefusals = {count: 0, last: null};
    const initial = model.create(options.nodeId, 1);
    this.state = initial.ok ? initial.state : null;
    this.error = initial.ok ? null : initial.error;
  }
  view() { return this.model.view(this.state); }
  name(kind, suffix) { return `${this.options.prefix}:${kind}:${suffix}`; }
  async boot() { return this.acquire(1); }
  async event(event) {
    const result = this.model.step(this.state, event);
    if (!result.ok) return result;
    this.state = result.state;
    let failure;
    for (const action of result.actions) {
      const outcome = await this.effect(action);
      if (outcome && !outcome.ok) failure = failure || outcome;
    }
    return failure || {ok: true, value: this.view()};
  }
  current(worker, phase) {
    const view = this.view();
    return view.mode === 'ready' && view.nodeLock &&
      view.workers.some(w => w.ticket === worker.ticket &&
        w.incarnation === worker.incarnation && w.phase === phase);
  }
  async acquire(incarnation) {
    const result = await this.glue.lock(this.name('node', this.options.nodeId));
    if (!result.ok || !result.value) {
      const failure = result.ok ? {ok: false, error: 'node_lock_busy'} : result;
      const view = this.view();
      if (view.incarnation === incarnation) this.error = failure.error;
      if (view.incarnation === incarnation && view.mode === 'ready' && !view.nodeLock) {
        await this.event({kind: 'freeze'});
      }
      return failure;
    }
    this.nodes.set(incarnation, result.value);
    return this.event({kind: 'node_acquired', incarnation});
  }
  async release(map, key) {
    const lease = map.get(key);
    map.delete(key);
    if (lease) await lease.release();
  }
  async stop(worker) {
    const view = this.view();
    // Stop names a pod, so reject stale tickets before dispatching it.
    if (!view.workers.some(current => current.ticket === worker.ticket &&
        current.incarnation === worker.incarnation && current.pod === worker.pod)) {
      return {ok: true, value: view};
    }
    return this.event({kind: 'stop', pod: worker.pod,
      incarnation: worker.incarnation, epoch: view.epoch});
  }
  async spawned(worker) {
    if (!this.current(worker, 'starting')) return;
    const handle = {worker, epoch: this.view().epoch, place: null, published: false,
      startedAt: Date.now()};
    const result = this.glue.spawn(this.options.podUrl,
      message => this.message(handle, message), () => this.stop(worker));
    if (!result.ok) {
      await this.event({kind: 'worker_exited', ticket: worker.ticket});
      return;
    }
    handle.native = result.value;
    this.workers.set(worker.ticket, handle);
    const sent = this.glue.send(handle.native, {kind: 'init', pod: worker.pod,
      podLock: this.name('pod', worker.pod),
      lifeLock: this.name('life', `${this.options.nodeId}:${worker.ticket}`)});
    if (!sent.ok) await this.stop(worker);
  }
  async message(handle, message) {
    const worker = handle.worker;
    if (this.workers.get(worker.ticket) !== handle) return;
    if (!message || typeof message !== 'object' || Array.isArray(message)) {
      return {ok: false, error: 'invalid_worker_message'};
    }
    if (message.kind === 'pod_lock') {
      if (!this.current(worker, 'starting')) return;
      if (message.granted === false) {
        this.duplicateRefusals.count += 1;
        this.duplicateRefusals.last = {pod: worker.pod, ticket: worker.ticket,
          incarnation: worker.incarnation, exited: false};
      }
      await this.event({kind: 'pod_lock', ticket: worker.ticket, granted: message.granted});
    } else if (message.kind === 'tick' && this.current(worker, 'running') && handle.published) {
      handle.lastTick = Date.now();
      this.options.onTick({...worker, value: message.value, at: handle.lastTick});
    } else if (message.kind === 'failed') await this.stop(worker);
  }
  async publish(worker) {
    const handle = this.workers.get(worker.ticket);
    if (!handle || !this.current(worker, 'running')) return;
    const epoch = handle.epoch;
    const name = this.name('place', `${worker.pod}:${this.options.nodeId}:${worker.incarnation}`);
    const acquired = await this.glue.lock(name);
    if (!acquired.ok || !acquired.value) { await this.stop(worker); return; }
    if (!this.current(worker, 'running') || epoch !== this.view().epoch) {
      await acquired.value.release();
      await this.stop(worker);
      return;
    }
    handle.place = acquired.value;
    const saved = await this.options.append(epoch, {kind: 'placed',
      nodeId: this.options.nodeId, pod: worker.pod, incarnation: worker.incarnation});
    if (!saved.ok || !this.current(worker, 'running') || epoch !== this.view().epoch) {
      await this.stop(worker);
      return;
    }
    handle.published = true;
  }
  async terminate(worker) {
    const handle = this.workers.get(worker.ticket);
    if (!handle) { await this.event({kind: 'worker_exited', ticket: worker.ticket}); return; }
    if (handle.terminating) return handle.terminating;
    const retry = () => {
      if (handle.retrying) return;
      handle.retrying = true;
      setTimeout(() => {
        handle.retrying = false;
        if (this.workers.get(worker.ticket) === handle) return this.terminate(worker);
      }, 20);
    };
    handle.terminating = (async () => {
      if (this.workers.get(worker.ticket) !== handle) return;
      if (!handle.killed) {
        const killed = this.glue.kill(handle.native);
        if (!killed.ok) { this.error = killed.error; retry(); return; }
        handle.killed = true;
      }
      if (handle.place) await handle.place.release();
      handle.place = null;
      const marker = this.name('life', `${this.options.nodeId}:${worker.ticket}`);
      const locks = await this.glue.locks();
      if (!locks.ok) { this.error = locks.error; retry(); return; }
      if (locks.value.includes(marker)) { retry(); return; }
      if (this.workers.get(worker.ticket) !== handle) return;
      this.workers.delete(worker.ticket);
      const refusal = this.duplicateRefusals.last;
      if (refusal && refusal.ticket === worker.ticket) refusal.exited = true;
      await this.event({kind: 'worker_exited', ticket: worker.ticket});
    })().finally(() => { handle.terminating = undefined; });
    return handle.terminating;
  }
  async effect(action) {
    const worker = action.worker;
    switch (action.kind) {
      case 'acquire_node': return this.acquire(action.incarnation);
      case 'release_node': return this.release(this.nodes, action.incarnation);
      case 'spawn': return this.spawned(worker);
      case 'publish_place': return this.publish(worker);
      case 'release_place': {
        const handle = this.workers.get(worker.ticket);
        if (handle && handle.place) {
          const lease = handle.place;
          handle.place = null;
          handle.published = false;
          await lease.release();
        }
        return;
      }
      case 'begin_work': {
        const handle = this.workers.get(worker.ticket);
        if (handle && handle.published && handle.epoch === this.view().epoch &&
            this.current(worker, 'running')) {
          handle.lastTick = Date.now();
          const sent = this.glue.send(handle.native, {kind: 'begin'});
          if (!sent.ok) await this.stop(worker);
        } else await this.stop(worker);
        return;
      }
      case 'terminate': return this.terminate(worker);
      default: this.error = 'unknown_model_action';
    }
  }
  async watchdog(now) {
    for (const handle of this.workers.values()) {
      const worker = this.view().workers.find(current => current.ticket === handle.worker.ticket);
      if (!worker) continue;
      if (worker.phase === 'stopping') await this.terminate(handle.worker);
      else if (now - (handle.published ? handle.lastTick : handle.startedAt) >= 5000)
        await this.stop(handle.worker);
    }
  }
};
