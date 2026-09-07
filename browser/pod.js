/* A host-test payload.  Source-language Wasm emission arrives later. */
importScripts('glue.js');
const glue = globalThis.KiteGlue;
let initialized = false;
let acquired = false;
let running = false;
let value = 0;
let increment;
let lifeLease;
let podLease;
const bytes = new Uint8Array([
  0,97,115,109,1,0,0,0,1,6,1,96,1,127,1,127,
  3,2,1,0,7,8,1,4,116,105,99,107,0,0,
  10,9,1,7,0,32,0,65,1,106,11
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
    module => ({ok: true, value: module.instance.exports.tick}),
    () => ({ok: false}));
  if (!result.ok || typeof result.value !== 'function') {
    acquired = false;
    running = false;
    await podLease.release();
    await lifeLease.release();
    glue.send(self, {kind: 'failed', error: 'wasm_init_failed'});
    return;
  }
  increment = result.value;
  if (running) tick();
}
function tick() {
  if (!running || !increment) return;
  value = increment(value);
  glue.send(self, {kind: 'tick', value});
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
