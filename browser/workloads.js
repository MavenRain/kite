/* Each manifest owns a control session and an independent placement namespace. */
(function (root) {
  'use strict';
  const ok = value => ({ok: true, value});
  const fail = error => ({ok: false, error});
  const name = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value);
  function create(glue, options) {
    if (!name(options.cluster) || !name(options.nodeId)) return fail('invalid_identity');
    const nodes = new Map();
    const bindings = new Map();
    let program;
    let frozen = false;
    let closed = false;
    let starting;
    let freezing;
    let freezeResult;
    let resuming;
    let closing;
    let ready = false;
    let lifecycle = 0;
    let sequence = 0;
    let freezeSequence = 0;
    function control(manifest) {
      const pending = new Map();
      let nextId = 0;
      let error;
      let ending;
      let closeReply;
      const spawned = glue.spawn('control.js', message => {
        const finish = pending.get(message.id);
        if (finish) { pending.delete(message.id); finish(message); }
      }, reason => {
        error = reason;
        for (const finish of pending.values()) finish(fail(reason));
        pending.clear();
      });
      if (!spawned.ok) return spawned;
      const node = {
        manifest,
        request(op, args = {}) {
          if (error) return Promise.resolve(fail(error));
          const id = ++nextId;
          return new Promise(resolve => {
            const timer = setTimeout(() => {
              pending.delete(id);
              resolve(fail('request_timeout'));
            }, 10000);
            pending.set(id, result => { clearTimeout(timer); resolve(result); });
            const sent = glue.send(spawned.value, {...args, id, op});
            if (!sent.ok) { pending.delete(id); clearTimeout(timer); resolve(sent); }
          });
        },
        close() {
          if (ending) return ending;
          ending = (async () => {
            const result = closeReply || await node.request('close');
            closeReply = result;
            error = 'closed';
            const killed = glue.kill(spawned.value);
            for (const finish of pending.values()) finish(fail('closed'));
            pending.clear();
            return result.ok ? killed : result;
          })().finally(() => { ending = undefined; });
          return ending;
        }
      };
      return ok(node);
    }
    async function each(operation) {
      const results = await Promise.all([...nodes.values()].map(operation));
      return results.find(result => !result.ok) || ok(results.map(result => result.value));
    }
    async function observe() {
      if (closed || frozen) return fail('node_unavailable');
      const version = lifecycle;
      const current = ++sequence;
      const visibility = options.visibility();
      return each(async node => {
        const view = await node.request('view');
        if (!view.ok) return view;
        if (version !== lifecycle) return fail('lifecycle_changed');
        return node.request('visibility', {observation: {visibility,
          incarnation: view.value.node.incarnation, sequence: current}});
      });
    }
    async function install(manifests, version) {
      if (!Array.isArray(manifests) || manifests.some(value => !value || typeof value !== 'object'))
        return fail('invalid_manifest');
      const names = new Set();
      const workloads = manifests.filter(value => ['deployment', 'stateful_set'].includes(value.kind));
      for (const value of manifests) {
        if (!name(value.name) || names.has(value.name)) return fail('invalid_manifest_name');
        names.add(value.name);
        if (!['deployment', 'stateful_set', 'service', 'drain'].includes(value.kind))
          return fail('invalid_manifest_kind');
        if (['service', 'drain'].includes(value.kind) &&
            !workloads.some(workload => workload.name === value.target)) return fail('unknown_target');
      }
      for (const manifest of workloads) {
        if (closed || frozen || version !== lifecycle) return fail('lifecycle_changed');
        const created = control(manifest);
        if (!created.ok) return created;
        nodes.set(manifest.name, created.value);
        const booted = await created.value.request('boot', {cluster: options.cluster,
          nodeId: options.nodeId, manifest, visibility: options.visibility()});
        if (!booted.ok) return booted;
      }
      for (const value of manifests.filter(value => value.kind === 'service'))
        bindings.set(value.name, value.target);
      if (closed || frozen || version !== lifecycle) return fail('lifecycle_changed');
      return ok(manifests);
    }
    async function checkpoint(target) {
      const node = nodes.get(target);
      if (closed || !node || node.manifest.kind !== 'stateful_set')
        throw new Error('unknown_stateful_set');
      const result = await node.request('checkpoint');
      if (!result.ok) throw new Error(result.error);
      return null;
    }
    const host = {
      observe,
      async start(artifact, effect) {
        if (closed || program || starting) return fail('already_started');
        if (frozen) return fail('node_unavailable');
        const version = lifecycle;
        program = root.KiteSource.createSession(artifact, (name, argument) => {
          if (name === 'host_checkpoint') return checkpoint(argument);
          if (typeof effect === 'function') return effect(name, argument);
          throw new Error(`unavailable:${name}`);
        });
        starting = (async () => {
          const executed = await program.start();
          if (!executed.ok) return executed;
          const installed = await install(executed.manifests || [], version);
          if (!installed.ok) {
            program.close();
            const stopped = await each(node => node.close());
            if (stopped.ok) nodes.clear();
          }
          ready = installed.ok;
          return installed.ok ? {...executed, value: {result: executed.value,
            manifests: installed.value}} : installed;
        })().finally(() => { starting = undefined; });
        return starting;
      },
      request(workload, op, args) {
        if (closed || frozen) return Promise.resolve(fail('node_unavailable'));
        const node = nodes.get(workload);
        return node ? node.request(op, args) : Promise.resolve(fail('unknown_workload'));
      },
      async service(service, event) {
        const node = nodes.get(bindings.get(service));
        if (!node || closed || frozen) return fail('unknown_service');
        const version = lifecycle;
        const read = await node.request('view');
        if (!read.ok) return read;
        if (version !== lifecycle) return fail('lifecycle_changed');
        const epoch = read.value.node.epoch;
        const registered = await node.request('service', {epoch, event: {kind: 'register', name: service}});
        if (version !== lifecycle) return fail('lifecycle_changed');
        return registered.ok ? node.request('service', {epoch, event}) : registered;
      },
      freeze() {
        if (resuming) lifecycle += 1;
        if (freezing) return freezing;
        if (frozen && !resuming) return Promise.resolve(freezeResult || ok(undefined));
        const wasFrozen = frozen;
        frozen = true;
        lifecycle += 1;
        // Cancel unfinished startup before its next host reply can run source work.
        if (program && !ready) program.close();
        const handler = wasFrozen ? Promise.resolve(freezeResult || ok(undefined))
          : program && ready && !closed
          ? program.freeze({session: program.token, sequence: ++freezeSequence})
          : Promise.resolve(ok(undefined));
        // The handler submits its first host call before drains are dispatched.
        // Both then race under the transaction fences; a final write is optional.
        const drained = Promise.resolve().then(() => each(node => node.request('freeze')));
        freezing = (async () => {
          const result = await handler;
          const released = await drained;
          freezeResult = !released.ok ? released : result;
          return freezeResult;
        })().finally(() => { freezing = undefined; });
        return freezing;
      },
      resume() {
        if (resuming) return resuming;
        const version = ++lifecycle;
        resuming = (async () => {
          if (freezing) await freezing;
          if (closed) return fail('closed');
          if (version !== lifecycle) return fail('lifecycle_changed');
          const resumed = await each(node => node.request('resume'));
          if (version !== lifecycle || closed) return fail('lifecycle_changed');
          if (!resumed.ok) return resumed;
          frozen = false;
          freezeResult = undefined;
          return observe();
        })().finally(() => { resuming = undefined; });
        return resuming;
      },
      close() {
        if (closing) return closing;
        closed = true;
        lifecycle += 1;
        if (program) program.close();
        closing = (async () => {
          await host.freeze();
          const result = await each(node => node.close());
          if (result.ok) nodes.clear();
          return result;
        })().finally(() => { closing = undefined; });
        return closing;
      }
    };
    return ok(host);
  }
  root.KiteWorkloads = {create};
})(globalThis);
