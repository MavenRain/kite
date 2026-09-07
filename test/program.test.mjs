import assert from 'node:assert/strict';
import {readFile, mkdtemp, writeFile, rm, access} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import test from 'node:test';

const root = path.resolve(import.meta.dirname, '..');
const compiler = path.join(root, '_build/default/bin/kite.exe');
const bridge = await readFile(path.join(root, '_build/default/browser/program.bc.js'), 'utf8');
const pump = await readFile(path.join(root, 'browser/source.js'), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
async function compiled(source, action) {
  const folder = await mkdtemp(path.join(tmpdir(), 'kite-program-test-'));
  const file = path.join(folder, 'program.kite');
  try {
    await writeFile(file, source);
    const built = spawnSync(compiler, ['build', file], {encoding: 'utf8'});
    assert.equal(built.status, 0, built.stdout + built.stderr);
    const context = vm.createContext({setTimeout, clearTimeout, console, TextDecoder, TextEncoder});
    vm.runInContext(bridge, context);
    vm.runInContext(pump, context);
    vm.runInContext(await readFile(path.join(folder, 'program.kite.js'), 'utf8'), context);
    return await action(context, file);
  } finally { await rm(folder, {recursive: true, force: true}); }
}

test('compiled checked IR preserves closure capture, recursion and scoped rows', async () => {
  await compiled(`
    let origin = 5
    let capture = fun _ -> origin
    let origin = 90
    let rec sum n = if n == 0 then 0 else n + sum (n - 1)
    let row = { a = 2 | { a = 3, b = 4 } }
    let result = let { a ^ 1 = x | rest } = row in
      capture () + sum 100 + x + rest.a + rest.b
  `, async context => {
    const answer = await context.KiteSource.run(context.KiteArtifact, () => assert.fail('unexpected host call'));
    assert.deepEqual(plain(answer), {ok: true, value: 5064});
  });
});

test('host calls receive records and resume through checked result contracts', async () => {
  await compiled(`
    import exchange : { text : Str, count : Int } -> { value : Int, ready : Bool } cost 1 deadline 500
    let result = let reply = exchange { text = "kite", count = 7 } in
      if reply.ready then reply.value + 1 else 0
  `, async context => {
    const calls = [];
    const answer = await context.KiteSource.run(context.KiteArtifact, (name, argument) => {
      calls.push([name, plain(argument)]);
      return {ready: true, value: argument.count * 2};
    });
    assert.deepEqual(calls, [['exchange', {text: 'kite', count: 7}]]);
    assert.deepEqual(plain(answer), {ok: true, value: 15});
  });
});

test('host return contracts reject missing, extra, and mistyped fields', async () => {
  await compiled(`import read : Unit -> { value : Int } cost 1 deadline 500
    let result = (read ()).value`, async context => {
    for (const reply of [{}, {value: 2, extra: 3}, {value: 'wrong'}, {value: 2147483648}]) {
      const answer = await context.KiteSource.run(context.KiteArtifact, () => reply);
      assert.equal(answer.ok, false);
      assert.match(answer.error, /host_failed: invalid_host_/);
    }
  });
});

test('host variants retain scoped occurrence indices', async () => {
  await compiled(`import read : Unit -> < ok : Int, ok : Int > cost 1 deadline 500
    let result = match read () with | < ok x > -> 0 | < ok ^ 1 x > -> x`, async context => {
    const answer = await context.KiteSource.run(context.KiteArtifact, () => ({tag: 'ok', occ: 1, value: 9}));
    assert.deepEqual(plain(answer), {ok: true, value: 9});
    const refused = await context.KiteSource.run(context.KiteArtifact, () => ({tag: 'ok', occ: 2, value: 9}));
    assert.equal(refused.ok, false);
  });
});

test('strings and signed 32-bit arithmetic survive emitted JSON and browser evaluation', async () => {
  await compiled('let result = { text = "snow: 雪\\n\\\"\\\\", number = 2147483647 + 1 }', async context => {
    const answer = await context.KiteSource.run(context.KiteArtifact, () => assert.fail('unexpected host call'));
    assert.deepEqual(plain(answer), {ok: true, value: {text: 'snow: 雪\n"\\', number: -2147483648}});
  });
});

test('emitted artifacts are ascii only and keep the source string', async () => {
  await compiled('let result = "snow: 雪"', async (context, file) => {
    const emitted = await readFile(`${file}.js`);
    assert.equal(emitted.every(byte => byte < 128), true);
    const answer = await context.KiteSource.run(context.KiteArtifact, () => assert.fail('unexpected host call'));
    assert.deepEqual(plain(answer), {ok: true, value: 'snow: 雪'});
  });
});

test('deep non-tail source recursion returns the native value in the browser', async () => {
  await compiled(`
    let rec sum n = if n == 0 then 0 else n + sum (n - 1)
    let result = sum 20000
  `, async context => {
    const answer = await context.KiteSource.run(context.KiteArtifact, () => assert.fail('unexpected host call'));
    assert.deepEqual(plain(answer), {ok: true, value: 200010000});
  });
});

test('freeze expressions remain deferred during source initialization', async () => {
  await compiled('let result = 7 freeze { store } = 1 / 0', async context => {
    const answer = await context.KiteSource.run(context.KiteArtifact, () => assert.fail('unexpected host call'));
    assert.deepEqual(plain(answer), {ok: true, value: 7});
  });
});

test('divergent recursion cooperatively yields and malformed artifacts return values', async () => {
  await compiled('let rec spin x = spin x let result = spin 0', async context => {
    const state = context.KiteProgram.start(context.KiteArtifact);
    assert.equal(state.kind, 'yield');
    assert.equal(state.resume().kind, 'yield');
    for (const artifact of [null, {version: 2, items: []}, {version: 1, items: [{tag: 'unknown'}]}]) {
      assert.equal(context.KiteProgram.start(artifact).kind, 'error');
    }
  });
});

test('unsupported recursive values and out-of-range integers produce no artifact', async () => {
  const folder = await mkdtemp(path.join(tmpdir(), 'kite-refused-test-'));
  try {
    for (const [index, source] of [
      'let result = let rec x = 1 / 0 in 42',
      'let result = 2147483648',
      'import read : {a:Int,a:Int} -> Int cost 1 deadline 20 let result = 7'
    ].entries()) {
      const file = path.join(folder, `case${index}.kite`);
      await writeFile(file, source);
      const built = spawnSync(compiler, ['build', file], {encoding: 'utf8'});
      assert.equal(built.status, 1);
      assert.match(built.stdout, /executable/);
      await assert.rejects(access(path.join(folder, `case${index}.kite.js`)));
    }
  } finally { await rm(folder, {recursive: true, force: true}); }
});

test('executable structural depth agrees at 256 and refuses 257 before decoding', async () => {
  const nested = depth => '@budget { atoms = 4096, constraints = 4096 } let result = '
    + 'if true then '.repeat(depth) + '0' + ' else 0'.repeat(depth);
  await compiled(nested(256), async (context, file) => {
    const native = spawnSync(compiler, ['run', file], {encoding: 'utf8'});
    assert.equal(native.status, 0, native.stdout + native.stderr);
    const answer = await context.KiteSource.run(context.KiteArtifact, () => assert.fail('unexpected host call'));
    assert.deepEqual(plain(answer), {ok: true, value: 0});
    const body = context.KiteArtifact.items[0].body;
    context.KiteArtifact.items[0].body = {tag: 'if', condition: {tag: 'lit', value: {tag: 'bool', value: true}},
      yes: body, no: {tag: 'lit', value: {tag: 'int', value: 0}}};
    assert.deepEqual(plain(context.KiteProgram.start(context.KiteArtifact)), {kind: 'error', error: 'artifact_depth'});
    await writeFile(file, nested(257));
    for (const verb of ['run', 'build']) {
      const refused = spawnSync(compiler, [verb, file], {encoding: 'utf8'});
      assert.equal(refused.status, 1);
      assert.match(refused.stdout, /artifact_depth/);
    }
  });
});
