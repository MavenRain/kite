/* Drive the pure evaluator through explicit host calls and cooperative yields. */
(function (root) {
  'use strict';
  // A thrown value may refuse every conversion, so the name is fixed then.
  const fail = error => {
    try { return {ok: false, error: String(error?.message || error)}; }
    catch (refused) { return {ok: false, error: 'host_error'}; }
  };
  const now = () => root.performance ? root.performance.now() : Date.now();
  let serial = 0;
  async function execute(state, host, active = () => true, completed = () => {}) {
      for (;;) {
        if (!active()) return fail('session_closed');
        if (state.kind === 'done') {
          completed(state);
          return Array.isArray(state.manifests)
            ? {ok: true, value: state.value, manifests: state.manifests}
            : {ok: true, value: state.value};
        }
        if (state.kind === 'error') return fail(state.error);
        if (state.kind === 'yield') {
          await new Promise(resolve => setTimeout(resolve, 0));
          if (!active()) return fail('session_closed');
          state = state.resume();
        } else if (state.kind === 'call') {
          const call = state;
          const due = now() + call.deadlineMs;
          let timer;
          const deadline = new Promise(resolve => {
            timer = setTimeout(() => resolve(fail(`host_deadline:${call.name}`)), call.deadlineMs);
          });
          const invoked = Promise.resolve().then(() => {
            if (!active()) throw new Error('session_closed');
            return host(call.name, call.argument);
          })
            .then(value => ({ok: true, value}), fail);
          const observed = await Promise.race([invoked, deadline]);
          clearTimeout(timer);
          const reply = now() >= due ? fail(`host_deadline:${call.name}`) : observed;
          if (!active()) return fail('session_closed');
          state = call.resume(reply);
        } else return fail('invalid_evaluator_state');
      }
  }
  root.KiteSource = {
    async run(artifact, host) {
      try { return await execute(root.KiteProgram.start(artifact), host); }
      catch (error) { return fail(error); }
    },
    createSession(artifact, host) {
      const token = `source-session:${++serial}`;
      let phase = 'idle';
      let engine;
      let lastSequence = 0;
      const active = () => phase !== 'closed';
      const drive = async (action, nextPhase, completed) => {
        try {
          const result = await execute(action(), host, active, completed);
          if (active()) phase = result.ok ? nextPhase : 'closed';
          if (!result.ok) engine = undefined;
          return result;
        } catch (error) {
          phase = 'closed';
          engine = undefined;
          return fail(error);
        }
      };
      return Object.freeze({
        token,
        async start() {
          if (phase !== 'idle') return fail('session_started');
          phase = 'starting';
          return drive(() => root.KiteProgram.openSession(artifact), 'ready',
            state => { engine = state.session; });
        },
        async freeze(observation) {
          if (!observation || observation.session !== token
              || !Number.isSafeInteger(observation.sequence)
              || observation.sequence <= lastSequence) return fail('stale_observation');
          if (phase !== 'ready') return fail('session_not_ready');
          lastSequence = observation.sequence;
          phase = 'freezing';
          return drive(() => engine.freeze(), 'ready');
        },
        close() {
          phase = 'closed';
          engine = undefined;
        }
      });
    }
  };
})(globalThis);
