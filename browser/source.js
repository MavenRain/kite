/* Drive the pure evaluator through explicit host calls and cooperative yields. */
(function (root) {
  'use strict';
  // A thrown value may refuse every conversion, so the name is fixed then.
  const fail = error => {
    try { return {ok: false, error: String(error?.message || error)}; }
    catch (refused) { return {ok: false, error: 'host_error'}; }
  };
  const now = () => root.performance ? root.performance.now() : Date.now();
  async function execute(artifact, host) {
      let state = root.KiteProgram.start(artifact);
      for (;;) {
        if (state.kind === 'done') return {ok: true, value: state.value};
        if (state.kind === 'error') return fail(state.error);
        if (state.kind === 'yield') {
          await new Promise(resolve => setTimeout(resolve, 0));
          state = state.resume();
        } else if (state.kind === 'call') {
          const call = state;
          const due = now() + call.deadlineMs;
          let timer;
          const deadline = new Promise(resolve => {
            timer = setTimeout(() => resolve(fail(`host_deadline:${call.name}`)), call.deadlineMs);
          });
          const invoked = Promise.resolve().then(() => host(call.name, call.argument))
            .then(value => ({ok: true, value}), fail);
          const observed = await Promise.race([invoked, deadline]);
          clearTimeout(timer);
          const reply = now() >= due ? fail(`host_deadline:${call.name}`) : observed;
          state = call.resume(reply);
        } else return fail('invalid_evaluator_state');
      }
  }
  root.KiteSource = {
    async run(artifact, host) {
      try { return await execute(artifact, host); }
      catch (error) { return fail(error); }
    }
  };
})(globalThis);
