/* Test-only transport. Source import calls are dispatched by the CDP driver. */
(function (root) {
  "use strict";
  // A thrown value may refuse every conversion, so the name is fixed then.
  const named = error => {
    try { return String(error?.message || error); }
    catch (refused) { return "host_error"; }
  };
  let next = 0;
  let started = false;
  const queued = [];
  const pending = new Map();
  const bridge = {
    result: null,
    call(name, argument) {
      if (typeof name !== "string") return Promise.reject(new Error("invalid source import name"));
      const id = ++next;
      return new Promise((resolve, reject) => {
        pending.set(id, {resolve, reject});
        queued.push({id, name, argument});
      });
    },
    take() { return queued.splice(0); },
    settle(id, reply) {
      const call = pending.get(id);
      if (!call) throw new Error(`unknown source import reply: ${id}`);
      pending.delete(id);
      if (reply?.ok === true) call.resolve(reply.value);
      else call.reject(new Error(reply?.error || "host_operation_failed"));
      return true;
    },
    run(program) {
      if (started || typeof program !== "function") throw new Error("acceptance program already started or invalid");
      started = true;
      Promise.resolve().then(program).then(value => {
        bridge.result = {ok: true, value};
      }, error => {
        bridge.result = {ok: false, error: named(error)};
      });
      return true;
    },
    async locks() {
      const snapshot = await navigator.locks.query();
      return {held: snapshot.held.map(lock => lock.name), pending: snapshot.pending.map(lock => lock.name)};
    },
    async append(cluster, command) {
      const opened = await root.KiteGlue.open(`kite-${cluster}`);
      if (!opened.ok) return opened;
      try {
        const read = await opened.value.read();
        if (!read.ok) return read;
        return await opened.value.append(read.value.epoch, {kind: "command", command});
      } finally {
        opened.value.close();
      }
    }
  };
  root.KiteAcceptance = bridge;
})(globalThis);
