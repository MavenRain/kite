import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtemp, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';
import {faultNames, validateEvidence, validateTranscript} from '../dev/m2-evidence.mjs';

const summary = 'M2-OK manifests=4 faults=12 browser=real';
const cli = fileURLToPath(new URL('../dev/m2-evidence.mjs', import.meta.url));

function fixture() {
  return {
    faults: Array.from({length: 12}, (_, index) => ({
      id: index + 1, fault: faultNames[index + 1],
      injection: 'test fixture injection', outcome: 'test fixture outcome',
      witness: {fixture: true, observed: index + 1}
    })),
    manifests: ['deployment', 'stateful-set', 'service', 'freeze-drain'].map(name => ({
      name, outcome: 'test fixture outcome', witness: {fixture: true, name}
    }))
  };
}

function transcript(evidence = fixture()) {
  return [...evidence.faults.map(fault => `M2-FAULT ${JSON.stringify(fault)}`),
    ...evidence.manifests.map(manifest => `M2-MANIFEST ${JSON.stringify(manifest)}`),
    summary].join('\n');
}

test('complete evidence is accepted regardless of row order', () => {
  const evidence = fixture();
  evidence.faults.reverse();
  evidence.manifests.reverse();
  assert.deepEqual(validateEvidence(evidence), evidence);
  assert.deepEqual(validateTranscript(transcript(evidence)), evidence);
});

test('transcripts tolerate ordinary browser logs and CRLF line endings', () => {
  const text = `BROWSER Chromium\n${transcript()}\nBROWSER-OK\n`.replaceAll('\n', '\r\n');
  assert.deepEqual(validateTranscript(text), fixture());
});

test('each skipped fault is refused even when the success summary is present', () => {
  for (let id = 1; id <= 12; id += 1) {
    const evidence = fixture();
    evidence.faults = evidence.faults.filter(fault => fault.id !== id);
    assert.throws(() => validateTranscript(transcript(evidence)), new RegExp(`missing fault id ${id}$`));
  }
});

test('duplicate fault ids cannot substitute for a skipped fault or add an extra row', () => {
  for (const append of [false, true]) {
    const evidence = fixture();
    if (append) evidence.faults.push(evidence.faults[0]);
    else evidence.faults[11] = evidence.faults[0];
    assert.throws(() => validateTranscript(transcript(evidence)), /duplicate fault id 1/);
  }
});

test('renumbered clones of one row cannot stand in for the twelve plan rows', () => {
  const clones = fixture();
  clones.faults = clones.faults.map((fault, index) => ({...clones.faults[0], id: index + 1}));
  assert.throws(() => validateTranscript(transcript(clones)),
    /faults\[1\]\.fault must be the plan row of id 2/);
  const swapped = fixture();
  swapped.faults[7] = {...swapped.faults[7], id: 9};
  swapped.faults[8] = {...swapped.faults[8], id: 8};
  assert.throws(() => validateTranscript(transcript(swapped)),
    /faults\[7\]\.fault must be the plan row of id 9/);
  for (let id = 1; id <= 12; id += 1) {
    const renamed = fixture();
    renamed.faults[id - 1].fault = 'test fault';
    assert.throws(() => validateEvidence(renamed),
      new RegExp(`faults\\[${id - 1}\\].fault must be the plan row of id ${id}`));
  }
});

test('a record after the success summary is refused', () => {
  const rows = transcript().split('\n');
  const body = rows.slice(0, rows.length - 1);
  const lastFault = body[11];
  const moved = [...body.slice(0, 11), ...body.slice(12), summary, lastFault].join('\n');
  assert.throws(() => validateTranscript(moved), /line 17: record follows the M2-OK summary/);
  const inverted = [summary, ...body].join('\n');
  assert.throws(() => validateTranscript(inverted), /line 2: record follows the M2-OK summary/);
  assert.deepEqual(validateTranscript(rows.join('\n')), fixture());
});

test('fault ids must be numeric integers in the exact matrix range', () => {
  for (const id of ['1', 0, 13, 1.5, null, true, undefined, NaN, Infinity]) {
    const evidence = fixture();
    evidence.faults[0].id = id;
    assert.throws(() => validateEvidence(evidence), /id must be a numeric integer/);
  }
});

test('every manifest is required despite a complete fault matrix and success summary', () => {
  for (const {name} of fixture().manifests) {
    const evidence = fixture();
    evidence.manifests = evidence.manifests.filter(manifest => manifest.name !== name);
    assert.throws(() => validateTranscript(transcript(evidence)), new RegExp(`missing manifest ${name}$`));
  }
});

test('duplicate manifests and names outside the four required manifests are refused', () => {
  const duplicated = fixture();
  duplicated.manifests[3] = duplicated.manifests[0];
  assert.throws(() => validateTranscript(transcript(duplicated)), /duplicate manifest deployment/);
  const extra = fixture();
  extra.manifests.push({...extra.manifests[0], name: 'daemon-set'});
  assert.throws(() => validateTranscript(transcript(extra)), /name is unknown: daemon-set/);
  const alias = fixture();
  alias.manifests[1].name = 'stateful_set';
  assert.throws(() => validateTranscript(transcript(alias)), /name is unknown: stateful_set/);
});

test('required descriptions must contain text for both record kinds', () => {
  for (const [collection, fields] of [['faults', ['fault', 'injection', 'outcome']],
    ['manifests', ['name', 'outcome']]]) {
    for (const field of fields) {
      for (const invalid of ['', ' \t\n ', null, undefined, 1, true, {}, []]) {
        const evidence = fixture();
        evidence[collection][0][field] = invalid;
        assert.throws(() => validateEvidence(evidence), /must be nonblank text/);
      }
    }
  }
});

test('witnesses must be nonempty plain objects, with no array or primitive shortcuts', () => {
  for (const collection of ['faults', 'manifests']) {
    for (const invalid of [{}, [], [1], '', 'observed', null, undefined, true, 1,
      new Date(), new Map([['observed', 1]]), Object.create({observed: 1})]) {
      const evidence = fixture();
      evidence[collection][0].witness = invalid;
      assert.throws(() => validateEvidence(evidence), /witness must be a nonempty plain object/);
    }
    const evidence = fixture();
    evidence[collection][0].witness = {};
    assert.throws(() => validateTranscript(transcript(evidence)), /witness must be a nonempty plain object/);
  }
});

test('malformed records and missing arrays are refused', () => {
  for (const invalid of [undefined, null, [], {}, {faults: []}, {manifests: []},
    {faults: {}, manifests: []}, {faults: [], manifests: {}}]) {
    assert.throws(() => validateEvidence(invalid), /must be (a plain object|an array)/);
  }
  for (const collection of ['faults', 'manifests']) {
    for (const invalid of [null, [], 'observed', 1]) {
      const evidence = fixture();
      evidence[collection][0] = invalid;
      assert.throws(() => validateTranscript(transcript(evidence)), /must be a plain object/);
    }
  }
});

test('a fabricated summary alone cannot supply any evidence', () => {
  assert.throws(() => validateTranscript(summary), /missing fault id 1/);
  assert.throws(() => validateTranscript('BROWSER-OK\n'), /expected exactly one M2-OK summary/);
});

test('exactly one literal real-browser success summary is required', () => {
  const complete = transcript();
  assert.throws(() => validateTranscript(complete.replace(summary, '')), /found 0/);
  assert.throws(() => validateTranscript(`${complete}\n${summary}`), /found 2/);
  for (const invalid of [summary.replace('12', '11'), summary.replace('real', 'mock'),
    `${summary} `, ` ${summary}`, `${summary} extra=true`]) {
    assert.throws(() => validateTranscript(complete.replace(summary, invalid)), /malformed M2 evidence/);
  }
});

test('malformed JSON and reserved evidence prefixes cannot be ignored as browser logs', () => {
  for (const invalid of ['M2-FAULT {', 'M2-MANIFEST {"name":',
    'M2-FAULT {} trailing', 'M2-FAULT', 'M2-MANIFEST', 'M2-FAULT\t{}',
    ' M2-FAULT {}', 'M2-FAULTY {}', 'M2_FAULT {}', 'M2-MANIFES {}']) {
    assert.throws(() => validateTranscript(`${transcript()}\n${invalid}`), /malformed M2/);
  }
  assert.throws(() => validateTranscript(null), /transcript must be text/);
});

test('CLI prints success only for a complete transcript and refuses invalid inputs', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'kite-m2-evidence-'));
  t.after(() => rm(directory, {recursive: true, force: true}));
  const logfile = join(directory, 'browser.log');
  await writeFile(logfile, transcript());
  const accepted = spawnSync(process.execPath, [cli, logfile], {encoding: 'utf8'});
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.equal(accepted.stdout, 'M2-EVIDENCE OK manifests=4 faults=12\n');
  assert.equal(accepted.stderr, '');

  for (const args of [[], [logfile, 'extra']]) {
    const refused = spawnSync(process.execPath, [cli, ...args], {encoding: 'utf8'});
    assert.equal(refused.status, 1);
    assert.equal(refused.stdout, '');
    assert.match(refused.stderr, /^M2-EVIDENCE REFUSED: usage: node dev\/m2-evidence\.mjs LOGFILE/);
  }

  await writeFile(logfile, summary);
  for (const args of [[logfile], [join(directory, 'absent.log')]]) {
    const refused = spawnSync(process.execPath, [cli, ...args], {encoding: 'utf8'});
    assert.equal(refused.status, 1);
    assert.equal(refused.stdout, '');
    assert.match(refused.stderr, /^M2-EVIDENCE REFUSED:/);
  }
});

test('CLI accepts stdin with dash and still rejects fabricated summary-only input', () => {
  const accepted = spawnSync(process.execPath, [cli, '-'], {encoding: 'utf8', input: transcript()});
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.equal(accepted.stdout, 'M2-EVIDENCE OK manifests=4 faults=12\n');
  assert.equal(accepted.stderr, '');
  const refused = spawnSync(process.execPath, [cli, '-'], {encoding: 'utf8', input: summary});
  assert.equal(refused.status, 1);
  assert.equal(refused.stdout, '');
  assert.match(refused.stderr, /M2-EVIDENCE REFUSED: missing fault id 1/);
});
