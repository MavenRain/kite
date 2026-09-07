/* The page owns only the control handle.  Pods belong to that Worker. */
const pending = new Map();
let requestId = 0;
let controlError;
let stopped = false;
let pollingGeneration = 0;
let updateTimer;
const received = message => {
  if (!message || typeof message !== 'object') return;
  if (message.kind === 'diagnostic') document.getElementById('status').textContent = message.error;
  const callback = pending.get(message.id);
  if (callback) { pending.delete(message.id); callback(message); }
};
const control = KiteGlue.spawn('control.js', received, error => {
  controlError = error;
  document.getElementById('status').textContent = error;
  for (const finish of pending.values()) finish({ok: false, error});
  pending.clear();
});
globalThis.kite = {
  request(op, args = {}) {
    if (!control.ok) return Promise.resolve(control);
    if (controlError) return Promise.resolve({ok: false, error: controlError});
    if (!args || typeof args !== 'object' || Array.isArray(args))
      return Promise.resolve({ok: false, error: 'invalid_arguments'});
    const id = ++requestId;
    return new Promise(resolve => {
      const timer = setTimeout(() => {
        pending.delete(id);
        resolve({ok: false, error: 'request_timeout'});
      }, 10000);
      pending.set(id, result => { clearTimeout(timer); resolve(result); });
      const sent = KiteGlue.send(control.value, {...args, id, op});
      if (!sent.ok) { clearTimeout(timer); pending.delete(id); resolve(sent); }
    });
  }
};
const parameters = new URLSearchParams(location.search);
const cluster = parameters.get('cluster') || 'demo';
const nodeId = parameters.get('node') || crypto.randomUUID();
const status = document.getElementById('status');
async function update(version = pollingGeneration) {
  if (stopped || controlError || version !== pollingGeneration) return;
  const result = await kite.request('view');
  if (stopped || controlError || version !== pollingGeneration) return;
  document.getElementById('view').textContent = JSON.stringify(result, null, 2);
  updateTimer = setTimeout(() => update(version), 1000);
}
kite.ready = kite.request('boot', {cluster, nodeId}).then(result => {
  status.textContent = result.ok ? `Node ${nodeId} joined ${cluster}.` : result.error;
  if (result.ok) update();
  return result;
});
document.getElementById('apply').onclick = async () => {
  const result = await kite.request('desired', {count: Number(document.getElementById('desired').value)});
  status.textContent = result.ok ? 'Desired count saved.' : result.error;
};
for (const op of ['freeze', 'resume']) {
  document.getElementById(op).onclick = async () => {
    const result = await kite.request(op);
    status.textContent = result.ok ? `Node ${op} complete.` : result.error;
  };
}
document.addEventListener('freeze', () => kite.request('freeze'));
document.addEventListener('resume', () => kite.request('resume'));
addEventListener('pagehide', event => {
  stopped = true;
  pollingGeneration += 1;
  clearTimeout(updateTimer);
  kite.request(event.persisted ? 'freeze' : 'close');
});
addEventListener('pageshow', event => {
  if (!event.persisted) return;
  stopped = false;
  kite.request('resume').then(result => {
    if (!result.ok) status.textContent = result.error;
    else update();
  });
});
