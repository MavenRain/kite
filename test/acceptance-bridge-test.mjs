#!/usr/bin/env node
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import vm from "node:vm";

const source = await readFile(new URL("./acceptance-bridge.js", import.meta.url), "utf8");
const context = vm.createContext({});
vm.runInContext(source, context);
const bridge = context.KiteAcceptance;
const first = bridge.call("open", "a");
const second = bridge.call("desired", {count: 2});
const queue = bridge.take();
assert.equal(queue.length, 2);
assert.equal(queue[0].name, "open");
assert.equal(queue[1].name, "desired");
assert.equal(bridge.take().length, 0);
bridge.settle(queue[1].id, {ok: true, value: 2});
bridge.settle(queue[0].id, {ok: true, value: "a"});
assert.equal(await first, "a");
assert.equal(await second, 2);
assert.throws(() => bridge.settle(queue[0].id, {ok: true}), /unknown source import reply/);

const rejected = bridge.call("desired", {count: -1});
const rejection = assert.rejects(rejected, /invalid_desired/);
bridge.settle(bridge.take()[0].id, {ok: false, error: "invalid_desired"});
await rejection;
bridge.run(async () => {
  const value = await bridge.call("view", "a");
  return value.count;
});
await Promise.resolve();
await Promise.resolve();
const call = bridge.take()[0];
assert.equal(call.name, "view");
bridge.settle(call.id, {ok: true, value: {count: 2}});
await new Promise(done => setImmediate(done));
assert.equal(bridge.result.ok, true);
assert.equal(bridge.result.value, 2);
assert.throws(() => bridge.run(() => null), /already started/);
console.log("PASS acceptance-bridge-correlated-replies-and-source-result");

let closed = 0;
context.KiteGlue = {open: async () => ({ok: true, value: {
  read: async () => ({ok: true, value: {epoch: 7}}),
  append: async (epoch, payload) => {
    assert.equal(epoch, 7);
    assert.equal(payload.kind, "command");
    assert.equal(payload.command.pod, 0);
    return {ok: false, error: "stale_epoch"};
  },
  close: () => { closed += 1; }
}})};
const failed = await bridge.append("cluster", {kind: "start", pod: 0});
assert.equal(failed.error, "stale_epoch");
assert.equal(closed, 1);
console.log("PASS acceptance-duplicate-injection-preserves-fence-and-closes-store");
