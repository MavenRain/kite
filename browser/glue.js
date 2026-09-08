/* Adapted from ocaml-tea idb.ml and tab_lock.ml: commit-level success and
   one-shot acquisition delivery. Browser exceptions stop at this boundary. */
(function (root) {
  "use strict";
  const cap = 1000000000;
  const ok = value => ({ ok: true, value });
  const fail = error => ({ ok: false, error });
  const leases = new WeakMap();
  const errorName = error => error && (error.name || error.message) || "browser_error";
  const integer = value => Number.isSafeInteger(value) && value >= 0 && value <= cap;
  const stateValid = state => state && integer(state.epoch) && integer(state.seq)
    && (state.owner === null || typeof state.owner === "string");
  function boundary(action) {
    try {
      return ok(action());
    } catch (error) {
      return fail(errorName(error));
    }
  }
  function send(target, value) {
    return boundary(() => target.postMessage(value));
  }
  function spawn(url, onMessage, onError) {
    return boundary(() => {
      const worker = new Worker(url, { type: "classic" });
      worker.onmessage = event => onMessage(event.data);
      worker.onerror = event => onError(event.message || "worker_error");
      return worker;
    });
  }
  function kill(worker) {
    return boundary(() => worker.terminate());
  }
  function listen(callback) {
    return boundary(() => {
      const listener = event => callback(event.data);
      root.addEventListener("message", listener);
      return () => boundary(() => root.removeEventListener("message", listener));
    });
  }
  function lock(name, { wait = false, signal } = {}) {
    return new Promise(resolve => {
      let delivered = false;
      function deliver(value) {
        if (!delivered) {
          delivered = true;
          resolve(value);
        }
      }
      try {
        const manager = root.navigator && root.navigator.locks;
        if (!manager) {
          deliver(fail("locks_unavailable"));
          return;
        }
        if (signal && signal.aborted) {
          deliver(fail("AbortError"));
          return;
        }
        const options = wait ? { mode: "exclusive", signal } : {
          mode: "exclusive", ifAvailable: true
        };
        let settled;
        const request = manager.request(name, options, granted => {
          if (!granted) {
            deliver(ok(null));
            return;
          }
          let release;
          const held = new Promise(done => { release = done; });
          const lease = { release() {
            leases.delete(lease);
            release();
            return settled;
          } };
          leases.set(lease, name);
          deliver(ok(lease));
          return held;
        });
        settled = Promise.resolve(request).then(() => ok(undefined), error => {
          const refusal = fail(errorName(error));
          deliver(refusal);
          return refusal;
        });
      } catch (error) {
        deliver(fail(errorName(error)));
      }
    });
  }
  async function locks() {
    try {
      const manager = root.navigator && root.navigator.locks;
      if (!manager) return fail("locks_unavailable");
      const snapshot = await manager.query();
      return ok(snapshot.held.map(held => held.name));
    } catch (error) {
      return fail(errorName(error));
    }
  }
  function store(db) {
    function transact(mode, action, names = ["meta", "log"]) {
      let cancel = () => fail("transaction_unavailable");
      const pending = new Promise(resolve => {
        let tx;
        let value;
        let failure;
        function abort(reason) {
          failure = failure || reason;
          return boundary(() => tx.abort());
        }
        const guarded = callback => () => {
          try {
            callback();
          } catch (error) {
            abort(errorName(error));
          }
        };
        try {
          tx = db.transaction(names, mode);
          cancel = () => boundary(() => tx.abort());
          tx.oncomplete = () => resolve(failure ? fail(failure) : ok(value));
          tx.onabort = () => resolve(fail(failure || errorName(tx.error)));
          tx.onerror = event => {
            failure = failure || errorName(event.target.error);
          };
          action(tx, result => { value = result; }, abort, guarded);
        } catch (error) {
          if (tx) abort(errorName(error));
          else resolve(fail(errorName(error)));
        }
      });
      pending.abort = () => cancel();
      return pending;
    }
    function atomic({ mode = "readwrite", reads, lease, plan }) {
      const held = () => !lease || leases.get(lease.value) === lease.name;
      if (!held()) return Promise.resolve(fail("lock_denied"));
      return transact(mode, (tx, finish, abort, guarded) => {
        const snapshot = {};
        let remaining = reads.length;
        for (const read of reads) {
          const object = tx.objectStore(read.store);
          const request = read.all ? object.getAll() : object.get(read.key);
          request.onsuccess = guarded(() => {
            snapshot[read.as] = request.result;
            remaining -= 1;
            if (remaining !== 0) return;
            if (!held()) { abort("lock_denied"); return; }
            const outcome = plan(snapshot);
            if (!outcome.ok) { abort(outcome.error); return; }
            for (const write of outcome.value.writes || []) {
              const target = tx.objectStore(write.store);
              if (write.add) target.add(write.value);
              else target.put(write.value, write.key);
            }
            finish(outcome.value.receipt);
          });
        }
        if (remaining === 0) abort("empty_transaction");
      }, [...new Set(reads.map(read => read.store))]);
    }
    function read() {
      return transact("readonly", (tx, finish, abort, guarded) => {
        let state;
        const metadata = tx.objectStore("meta").get("state");
        metadata.onsuccess = guarded(() => {
          state = metadata.result;
          if (!stateValid(state)) abort("invalid_state");
        });
        const log = tx.objectStore("log").getAll();
        log.onsuccess = guarded(() => finish({ ...state, entries: log.result }));
      });
    }
    function write(expectedEpoch, payload, owner, expectedSeq) {
      if (!integer(expectedEpoch)) return Promise.resolve(fail("invalid_epoch"));
      if (expectedSeq !== undefined && !integer(expectedSeq)) {
        return Promise.resolve(fail("invalid_sequence"));
      }
      const claiming = owner !== undefined;
      if (claiming && (typeof owner !== "string" || owner.length === 0)) {
        return Promise.resolve(fail("invalid_owner"));
      }
      return transact("readwrite", (tx, finish, abort, guarded) => {
        const meta = tx.objectStore("meta");
        const request = meta.get("state");
        request.onsuccess = guarded(() => {
          const previous = request.result;
          if (!stateValid(previous)) {
            abort("invalid_state");
            return;
          }
          if (previous.epoch !== expectedEpoch) {
            abort("stale_epoch");
            return;
          }
          if (expectedSeq !== undefined && previous.seq !== expectedSeq) {
            abort("stale_sequence");
            return;
          }
          if (previous.seq === cap || (claiming && previous.epoch === cap)) {
            abort("counter_exhausted");
            return;
          }
          const epoch = previous.epoch + (claiming ? 1 : 0);
          const seq = previous.seq + 1;
          meta.put({ epoch, seq, owner: claiming ? owner : previous.owner }, "state");
          tx.objectStore("log").add({ seq, epoch, payload });
          finish({ epoch, seq });
        });
      });
    }
    return {
      read, atomic,
      claim(expectedEpoch, owner) {
        if (typeof owner !== "string" || owner.length === 0) {
          return Promise.resolve(fail("invalid_owner"));
        }
        return write(expectedEpoch, { kind: "leader", owner }, owner);
      },
      append(epoch, payload, expectedSeq) {
        return write(epoch, payload, undefined, expectedSeq);
      },
      close() { return boundary(() => db.close()); }
    };
  }
  function open(name) {
    return new Promise(resolve => {
      let delivered = false;
      function deliver(value) {
        if (!delivered) {
          delivered = true;
          resolve(value);
        }
      }
      try {
        const request = root.indexedDB.open(name, 2);
        request.onblocked = () => deliver(fail("open_blocked"));
        request.onerror = () => deliver(fail(errorName(request.error)));
        request.onupgradeneeded = () => {
          const upgraded = boundary(() => {
            const db = request.result;
            if (!db.objectStoreNames.contains("meta")) {
              const meta = db.createObjectStore("meta");
              meta.put({ epoch: 0, seq: 0, owner: null }, "state");
              db.createObjectStore("log", { keyPath: "seq" });
            }
            if (!db.objectStoreNames.contains("volumes")) db.createObjectStore("volumes");
          });
          if (!upgraded.ok) {
            boundary(() => request.transaction.abort());
            deliver(upgraded);
          }
        };
        request.onsuccess = () => {
          const opened = boundary(() => {
            const db = request.result;
            db.onversionchange = () => boundary(() => db.close());
            if (delivered) {
              db.close();
              return;
            }
            return store(db);
          });
          deliver(opened);
        };
      } catch (error) {
        deliver(fail(errorName(error)));
      }
    });
  }
  function doorbell(name, callback) {
    return boundary(() => {
      const channel = new root.BroadcastChannel(name);
      channel.onmessage = event => callback(event.data);
      return { ring: value => send(channel, value), close: () => boundary(() => channel.close()) };
    });
  }
  function every(milliseconds, callback) {
    return boundary(() => {
      const timer = root.setInterval(callback, milliseconds);
      return () => boundary(() => root.clearInterval(timer));
    });
  }
  root.KiteGlue = { send, spawn, kill, listen, lock, locks, open, doorbell, every };
})(globalThis);
