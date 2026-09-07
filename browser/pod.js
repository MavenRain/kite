/* M1 uses the fixed Stage 0 workload, step(200000), in each nested pod.
   Bytes compiled from tab-cluster-spike/web/pod.wat, see PROVENANCE.md. */
importScripts('glue.js');
const glue = globalThis.KiteGlue;
let initialized = false;
let acquired = false;
let running = false;
let step;
let lifeLease;
let podLease;
const bytes = new Uint8Array([
  0,97,115,109,1,0,0,0,1,6,1,96,1,127,1,127,
  3,2,1,0,7,8,1,4,115,116,101,112,0,0,
  10,40,1,38,1,2,127,2,64,3,64,32,1,32,0,79,13,1,
  32,2,32,1,65,7,108,106,33,2,32,1,65,1,106,33,1,12,0,
  11,11,32,2,11
]);
async function init(message) {
  if (initialized) return;
  if (typeof message.lifeLock !== 'string' || typeof message.podLock !== 'string' ||
      !message.lifeLock || !message.podLock || !Number.isInteger(message.pod) || message.pod < 0) {
    glue.send(self, {kind: 'failed', error: 'invalid_init'});
    return;
  }
  initialized = true;
  const life = await glue.lock(message.lifeLock);
  if (!life.ok || !life.value) { glue.send(self, {kind: 'failed'}); return; }
  lifeLease = life.value;
  const pod = await glue.lock(message.podLock);
  acquired = pod.ok && !!pod.value;
  if (acquired) podLease = pod.value;
  glue.send(self, {kind: 'pod_lock', granted: acquired});
  if (!acquired) { await lifeLease.release(); return; }
  const result = await WebAssembly.instantiate(bytes).then(
    module => ({ok: true, value: module.instance.exports.step}),
    () => ({ok: false}));
  if (!result.ok || typeof result.value !== 'function') {
    acquired = false;
    running = false;
    await podLease.release();
    await lifeLease.release();
    glue.send(self, {kind: 'failed', error: 'wasm_init_failed'});
    return;
  }
  step = result.value;
  if (running) tick();
}
function tick() {
  if (!running || !step) return;
  glue.send(self, {kind: 'tick', value: step(200000)});
  setTimeout(tick, 250);
}
glue.listen(message => {
  if (!message || typeof message !== 'object') return;
  if (message.kind === 'init') init(message);
  else if (message.kind === 'begin' && acquired && !running) {
    running = true;
    tick();
  }
});
