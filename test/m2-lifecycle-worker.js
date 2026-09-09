/* Test node: production Kubelet, pod Worker and GLUE with explicit fault barriers. */
importScripts('/browser/glue.js', '/_build/default/browser/model.bc.js', '/browser/node-host.js');
const glue = globalThis.KiteGlue;
const ok = value => ({ok: true, value});
let host;
let store;
let settings;
const messages = [];
const ticks = [];
const pending = [];
function snapshot() {
  return {node: host.view(), messages: [...messages], ticks: [...ticks],
    handles: [...host.workers.values()].map(handle => ({worker: handle.worker,
      epoch: handle.epoch, published: handle.published})),
    blockedStop: !!settings.blockedStop, pendingCallbacks: pending.length};
}
async function request(message) {
  if (message.op === 'boot') {
    settings = message;
    const opened = await glue.open(message.prefix);
    if (!opened.ok) return opened;
    store = opened.value;
    const adapter = {...glue, spawn(url, onMessage, onError) {
      return glue.spawn(url, data => {
        messages.push(data);
        if (settings.holdStart && data.kind === 'pod_lock') pending.push(() => onMessage(data));
        else onMessage(data);
      }, onError);
    }};
    host = new KiteNode(KiteModel, adapter, {nodeId: 'nodeA', prefix: message.prefix,
      podUrl: '/browser/pod.js', append: (epoch, payload) => store.append(epoch, payload),
      onTick: tick => ticks.push(tick),
      onStop: async () => {
        if (settings.stopBarrier) {
          settings.blockedStop = true;
          const acquired = await glue.lock(settings.stopBarrier, {wait: true});
          if (!acquired.ok) return acquired;
          await acquired.value.release();
          settings.blockedStop = false;
        }
        return ok();
      }});
    const booted = await host.boot();
    if (!booted.ok) return booted;
    const read = await store.read();
    if (!read.ok) return read;
    const claimed = await store.claim(read.value.epoch, 'nodeA');
    if (!claimed.ok) return claimed;
    return host.event({kind: 'observe_epoch', epoch: claimed.value.epoch});
  }
  if (message.op === 'view') return ok(snapshot());
  if (message.op === 'release_start') {
    settings.holdStart = false;
    for (const receive of pending.splice(0)) await receive();
    return ok(snapshot());
  }
  if (message.op === 'start') return host.event({kind: 'start', pod: 0,
    incarnation: host.view().incarnation, epoch: host.view().epoch});
  if (message.op === 'stop') return host.stop([...host.workers.values()][0].worker);
  if (message.op === 'replay') {
    const before = snapshot();
    await host.message(message.handle, message.message);
    return ok({before, after: snapshot()});
  }
  return {ok: false, error: 'unknown_request'};
}
glue.listen(message => {
  request(message).then(result => glue.send(self, {id: message.id, ...result}),
    error => glue.send(self, {id: message.id, ok: false, error: String(error.stack || error)}));
});
