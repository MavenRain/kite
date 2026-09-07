/* Adapted from ocaml-tea idb.ml and tab_lock.ml: commit-level success and
   one-shot acquisition delivery. Browser exceptions stop at this boundary. */
(function (root) {
  "use strict";
  const cap = 1000000000;
  const ok = value => ({ ok: true, value });
  const fail = error => ({ ok: false, error });
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
          deliver(ok({ release() {
            release();
            return settled;
          } }));
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
    function transact(mode, action) {
      return new Promise(resolve => {
        let tx;
        let value;
        let failure;
        function abort(reason) {
          failure = failure || reason;
          const aborted = boundary(() => tx.abort());
          if (!aborted.ok) resolve(fail(failure));
        }
        const guarded = callback => () => {
          try {
            callback();
          } catch (error) {
            abort(errorName(error));
          }
        };
        try {
          tx = db.transaction(["meta", "log"], mode);
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
      read,
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
        const request = root.indexedDB.open(name, 1);
        request.onblocked = () => deliver(fail("open_blocked"));
        request.onerror = () => deliver(fail(errorName(request.error)));
        request.onupgradeneeded = () => {
          const upgraded = boundary(() => {
            const db = request.result;
            const meta = db.createObjectStore("meta");
            meta.put({ epoch: 0, seq: 0, owner: null }, "state");
            db.createObjectStore("log", { keyPath: "seq" });
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
  root.KiteGlue = { send, spawn, kill, listen, lock, locks, open };
})(globalThis);
