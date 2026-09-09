#!/usr/bin/env node
import {readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const manifestNames = ['deployment', 'stateful-set', 'service', 'freeze-drain'];
const summary = 'M2-OK manifests=4 faults=12 browser=real';

/** The fault name that each plan row must carry, keyed by its matrix id. */
export const faultNames = Object.freeze({
  1: 'Drop the final doorbell',
  2: 'Reorder and duplicate doorbells',
  3: 'Write from an old leader epoch',
  4: 'Write from an old volume generation in the same epoch',
  5: 'Duplicate a logical Service send',
  6: 'Replay an old Service handshake',
  7: 'kill_node_starting',
  8: 'kill_node_running',
  9: 'kill_node_stopping',
  10: 'Freeze before checkpoint submission',
  11: 'Freeze during the transaction',
  12: 'Freeze after commit before notification'
});

function plainObject(value) {
  return value !== null && typeof value === 'object' &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
}

function record(value, label, fields) {
  if (!plainObject(value)) throw new Error(`${label} must be a plain object`);
  for (const field of fields) {
    if (typeof value[field] !== 'string' || value[field].trim() === '')
      throw new Error(`${label}.${field} must be nonblank text`);
  }
  if (!plainObject(value.witness) || Object.keys(value.witness).length === 0)
    throw new Error(`${label}.witness must be a nonempty plain object`);
}

// This checks coverage and record shape. Browser probes assert the semantics
// of each witness before emitting it; this validator cannot establish them.
export function validateEvidence(evidence) {
  if (!plainObject(evidence)) throw new Error('evidence must be a plain object');
  const {faults, manifests} = evidence;
  if (!Array.isArray(faults)) throw new Error('faults must be an array');
  if (!Array.isArray(manifests)) throw new Error('manifests must be an array');

  const ids = new Set();
  for (const [index, fault] of faults.entries()) {
    const label = `faults[${index}]`;
    record(fault, label, ['fault', 'injection', 'outcome']);
    if (!Number.isInteger(fault.id) || fault.id < 1 || fault.id > 12)
      throw new Error(`${label}.id must be a numeric integer from 1 through 12`);
    if (fault.fault !== faultNames[fault.id])
      throw new Error(`${label}.fault must be the plan row of id ${fault.id}: ${faultNames[fault.id]}`);
    if (ids.has(fault.id)) throw new Error(`duplicate fault id ${fault.id}`);
    ids.add(fault.id);
  }
  for (let id = 1; id <= 12; id += 1) {
    if (!ids.has(id)) throw new Error(`missing fault id ${id}`);
  }

  const names = new Set();
  for (const [index, manifest] of manifests.entries()) {
    const label = `manifests[${index}]`;
    record(manifest, label, ['name', 'outcome']);
    if (!manifestNames.includes(manifest.name))
      throw new Error(`${label}.name is unknown: ${manifest.name}`);
    if (names.has(manifest.name)) throw new Error(`duplicate manifest ${manifest.name}`);
    names.add(manifest.name);
  }
  for (const name of manifestNames) {
    if (!names.has(name)) throw new Error(`missing manifest ${name}`);
  }
  return {faults, manifests};
}

export function validateTranscript(text) {
  if (typeof text !== 'string') throw new Error('transcript must be text');
  const evidence = {faults: [], manifests: []};
  let summaries = 0;
  let summaryLine = -1;
  for (const [index, line] of text.split(/\r?\n/).entries()) {
    if (line === summary) {
      summaries += 1;
      if (summaryLine < 0) summaryLine = index;
      continue;
    }
    const match = /^(M2-FAULT|M2-MANIFEST) (.+)$/.exec(line);
    if (match) {
      let value;
      try {
        value = JSON.parse(match[2]);
      } catch {
        throw new Error(`line ${index + 1}: malformed ${match[1]} JSON`);
      }
      if (summaryLine >= 0)
        throw new Error(`line ${index + 1}: record follows the M2-OK summary`);
      evidence[match[1] === 'M2-FAULT' ? 'faults' : 'manifests'].push(value);
    } else if (/^M2(?:[-_]|\s|$)/.test(line.trimStart())) {
      throw new Error(`line ${index + 1}: malformed M2 evidence prefix or summary`);
    }
  }
  if (summaries !== 1) throw new Error(`expected exactly one M2-OK summary, found ${summaries}`);
  return validateEvidence(evidence);
}

async function readTranscript(path) {
  if (path !== '-') return readFile(path, 'utf8');
  process.stdin.setEncoding('utf8');
  let text = '';
  for await (const chunk of process.stdin) text += chunk;
  return text;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 3) throw new Error('usage: node dev/m2-evidence.mjs LOGFILE');
    validateTranscript(await readTranscript(process.argv[2]));
    console.log('M2-EVIDENCE OK manifests=4 faults=12');
  } catch (error) {
    console.error(`M2-EVIDENCE REFUSED: ${error.message}`);
    process.exitCode = 1;
  }
}
