import assert from 'node:assert/strict';
import {spawn, execFile} from 'node:child_process';
import {access, chmod, copyFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve, sep} from 'node:path';
import {promisify} from 'node:util';
import vm from 'node:vm';
import test from 'node:test';

const root = resolve(import.meta.dirname, '..');
const execute = promisify(execFile);
const pause = ms => new Promise(done => setTimeout(done, ms));
const absent = file => assert.rejects(access(file), {code: 'ENOENT'});
const compiler = `#!/bin/zsh
[[ \${KITE_PIPELINE_FAIL:-} != source ]] || exit 41
print -r -- 'fresh IR' > "\${2:r}.kir"
print -r -- 'fresh source artifact' > "$2.js"
`;
const emitter = `import {existsSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {setTimeout as pause} from 'node:timers/promises';
const args=process.argv.slice(2);
const output=args[args.indexOf('-o')+1];
const kind=args.some(value=>value.endsWith('/model.bc'))?'model':'program';
const other=kind==='model'?'program':'model';
const folder=process.env.KITE_PIPELINE_PROBE;
if(kind==='program'&&!args.includes('--effects=cps')) process.exit(65);
writeFileSync(join(folder,kind+'.started'),String(process.pid));
const deadline=Date.now()+3000;
while(!existsSync(join(folder,other+'.started'))){
  if(Date.now()>deadline) process.exit(66);
  await pause(10);
}
if(process.env.KITE_PIPELINE_MODE==='hang') await new Promise(()=>setInterval(()=>{},1000));
await pause(kind==='program'?60:20);
writeFileSync(join(folder,kind+'.finished'),'finished');
if(process.env.KITE_PIPELINE_FAIL===kind) process.exit(kind==='model'?42:43);
writeFileSync(output,kind+' fresh emission');
`;

async function fixture(action, {fake = true} = {}) {
  const folder = await mkdtemp(join(tmpdir(), 'kite-pipeline-test-'));
  const scratch = join(folder, 'scratch');
  await mkdir(scratch);
  const source = join(folder, 'input.kite');
  await writeFile(source, 'let result = 7\n');
  let script = join(root, 'dev/browser-pipeline.sh');
  if (fake) {
    const fakeRoot = join(folder, 'fixture');
    for (const name of ['dev', 'browser', '_build/default/bin', '_build/default/browser'])
      await mkdir(join(fakeRoot, name), {recursive: true});
    script = join(fakeRoot, 'dev/browser-pipeline.sh');
    await copyFile(join(root, 'dev/browser-pipeline.sh'), script);
    await writeFile(join(fakeRoot, '_build/default/bin/kite.exe'), compiler);
    await chmod(join(fakeRoot, '_build/default/bin/kite.exe'), 0o755);
    await writeFile(join(fakeRoot, 'dev/pin-dune.sh'),
      '#!/bin/zsh\nexec node "${0:A:h:h}/emitter.mjs" "$@"\n');
    await writeFile(join(fakeRoot, 'emitter.mjs'), emitter);
    await writeFile(join(fakeRoot, 'browser/index.html'), '<script src="host.js"></script>');
    await writeFile(join(fakeRoot, 'browser/host.js'), 'globalThis.hostReady = true;');
  }
  const env = {...process.env, TMPDIR: scratch + sep, KITE_PIPELINE_PROBE: folder};
  try { return await action({folder, scratch, source, script, env}); }
  finally { await rm(folder, {recursive: true, force: true}); }
}
const run = (context, args = [], environment = {}) => execute('zsh',
  [context.script, ...args, context.source],
  {env: {...context.env, ...environment}, timeout: 15000, maxBuffer: 65536});

test('shipping builder retains fresh native bundles and an executable source artifact', async () => {
  await fixture(async context => {
    const destination = join(context.folder, 'product');
    await run(context, ['--output', destination]);
    for (const file of ['program.kir', 'program.kite.js', 'browser/index.html',
      'browser/control.js', 'browser/durable.js', 'browser/workloads.js',
      '_build/default/browser/model.bc.js', '_build/default/browser/program.bc.js'])
      assert.ok((await readFile(join(destination, file))).length > 0, file);
    const browser = vm.createContext({console, TextDecoder, TextEncoder, setTimeout, clearTimeout});
    for (const file of ['_build/default/browser/model.bc.js', '_build/default/browser/program.bc.js',
      'browser/source.js', 'program.kite.js'])
      vm.runInContext(await readFile(join(destination, file), 'utf8'), browser);
    assert.equal(typeof browser.KiteModel.plan, 'function');
    assert.equal(typeof browser.KiteDurableModel.atomicVolume, 'function');
    const result = await browser.KiteSource.createSession(browser.KiteArtifact,
      () => assert.fail('unexpected source host call')).start();
    assert.equal(result.ok, true);
    assert.equal(result.value, 7);
    assert.deepEqual(await readdir(context.scratch), []);
  }, {fake: false});
});

test('both emissions overlap, settle, and clean the one-source measurement directory', async () => {
  await fixture(async context => {
    await run(context);
    for (const kind of ['model', 'program'])
      assert.equal(await readFile(join(context.folder, `${kind}.finished`), 'utf8'), 'finished');
    assert.deepEqual(await readdir(context.scratch), []);
  });
});

for (const [kind, code] of [['model', 42], ['program', 43]]) {
  test(`a failed ${kind} emission remains a failure after both children settle`, async () => {
    await fixture(async context => {
      const destination = join(context.folder, 'product');
      await assert.rejects(run(context, ['--output', destination], {KITE_PIPELINE_FAIL: kind}),
        error => error.code === code);
      for (const child of ['model', 'program'])
        assert.equal(await readFile(join(context.folder, `${child}.finished`), 'utf8'), 'finished');
      await absent(destination);
      assert.deepEqual(await readdir(context.scratch), []);
    });
  });
}

test('source compilation failure prevents emission and removes temporary products', async () => {
  await fixture(async context => {
    const destination = join(context.folder, 'product');
    await assert.rejects(run(context, ['--output', destination], {KITE_PIPELINE_FAIL: 'source'}),
      error => error.code === 41);
    await absent(join(context.folder, 'model.started'));
    await absent(join(context.folder, 'program.started'));
    await absent(destination);
    assert.deepEqual(await readdir(context.scratch), []);
  });
});

test('an existing output directory is preserved and refused before compilation', async () => {
  await fixture(async context => {
    const destination = join(context.folder, 'product');
    await mkdir(destination);
    await writeFile(join(destination, 'keep'), 'existing');
    await assert.rejects(run(context, ['--output', destination]), error => error.code === 73);
    assert.equal(await readFile(join(destination, 'keep'), 'utf8'), 'existing');
    await absent(join(context.folder, 'model.started'));
    assert.deepEqual(await readdir(context.scratch), []);
  });
});

test('termination reaps both active compilers and cleans temporary output', async () => {
  await fixture(async context => {
    const child = spawn('zsh', [context.script, context.source],
      {env: {...context.env, KITE_PIPELINE_MODE: 'hang'}, stdio: 'ignore'});
    const completed = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => resolve({code, signal}));
    });
    const pids = [];
    try {
      const deadline = Date.now() + 5000;
      for (const kind of ['model', 'program']) {
        for (;;) {
          try { pids.push(Number(await readFile(join(context.folder, `${kind}.started`), 'utf8'))); break; }
          catch (error) {
            if (error.code !== 'ENOENT' || Date.now() > deadline) throw error;
            await pause(10);
          }
        }
      }
      child.kill('SIGTERM');
      const result = await Promise.race([completed, pause(5000).then(() => { throw new Error('cleanup timed out'); })]);
      assert.equal(result.code, 143);
      for (const pid of pids) assert.throws(() => process.kill(pid, 0), {code: 'ESRCH'});
      assert.deepEqual(await readdir(context.scratch), []);
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
      for (const pid of pids) {
        try { process.kill(pid, 'SIGKILL'); }
        catch (error) { if (error.code !== 'ESRCH') throw error; }
      }
    }
  });
});
