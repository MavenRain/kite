/* Real IndexedDB and Web Lock witnesses for M2-B, separate from the M2-C gate. */
(function (root) {
  "use strict";
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const value = (result, label) => {
    assert(result && result.ok, `${label}: ${result && result.error}`);
    return result.value;
  };
  const equal = (actual, expected, label) => assert(JSON.stringify(actual) === JSON.stringify(expected),
    `${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  const ok = value => ({ok: true, value});
  const sleep = milliseconds => new Promise(done => setTimeout(done, milliseconds));

  async function run() {
    const glue = root.KiteGlue;
    const model = root.KiteDurableModel;
    const durable = root.KiteDurable;
    const prefix = `kite-durable-${crypto.randomUUID()}`;
    const store = value(await glue.open(prefix), "open durable database");
    const lines = [];
    const feeds = [];
    const hosts = [];
    const held = [];
    const name = `${prefix}:volume:state:0`;
    const reads = [{store: "meta", key: "state", as: "state"},
      {store: "volumes", key: "state:0", as: "volume"}];
    const readVolume = async () => value(await store.atomic({mode: "readonly", reads,
      plan: read => ok({receipt: read.volume})}), "read committed volume");
    try {
      value(await store.claim(0, "leaderA"), "initial epoch");
      let lease;
      let savedAction;
      let freezeAfterCommit = false;
      let afterCommit;
      let host;
      const hostGlue = {...glue, async lock(lockName) {
        const result = await glue.lock(lockName);
        if (result.ok && result.value) lease = result.value;
        return result;
      }};
      const hostModel = {...model, atomicVolume(snapshot, operation) {
        if (operation.kind === "commit_checkpoint") savedAction = operation;
        return model.atomicVolume(snapshot, operation);
      }};
      const hostStore = {atomic(request) {
        const pending = store.atomic(request);
        const observed = pending.then(result => {
          if (freezeAfterCommit && request.mode !== "readonly" && result.ok) {
            freezeAfterCommit = false;
            afterCommit = host.freeze();
          }
          return result;
        });
        observed.abort = () => pending.abort && pending.abort();
        return observed;
      }};
      host = value(durable.volume(hostGlue, hostStore, hostModel,
        {prefix, namespace: "state", ordinal: 0}), "volume host");
      hosts.push(host);
      value(await host.attach(1), "claim volume writer");
      equal(host.view().writer.generation, 1, "first writer generation");
      const firstLease = lease;
      value(await host.prepare(["prepared-only"]), "prepare without transaction");
      equal((await readVolume()).committed, {revision: 0, entries: []}, "preparation has no write");
      value(await host.freeze(), "freeze drops preparation");
      equal(host.view().mode, "frozen", "prepared freeze settled");
      equal((await readVolume()).committed.entries, [], "frozen preparation absent");
      value(await host.resume(1), "resume prepared session");
      assert(host.view().writer.generation > 1, "resume gets fresh generation");
      assert(host.view().ticket > 1, "resume gets fresh local ticket");
      const oldLeaseAttempt = await store.atomic({reads, lease: {name, value: firstLease},
        plan: () => ok({receipt: true})});
      equal(oldLeaseAttempt.error, "lock_denied", "old exact lease refused despite same name");
      value(await host.checkpoint(["one"]), "regular checkpoint");
      equal(host.view().committed, {revision: 1, entries: ["one"]}, "checkpoint receipt");
      const oldWrite = savedAction;
      const issue = operation => store.atomic({reads, lease: {name, value: lease}, plan: read => {
        const result = model.atomicVolume({...read.volume, epoch: read.state.epoch}, operation);
        return result.ok ? ok({writes: [{store: "volumes", key: "state:0",
          value: result.value.snapshot}], receipt: true}) : result;
      }});
      value(await host.checkpoint(["two"]), "next checkpoint");
      const beforeStale = await readVolume();
      equal((await issue(oldWrite)).error, "stale_revision", "old revision refused");
      equal(await readVolume(), beforeStale, "revision refusal preserves checkpoint");
      value(await host.freeze(), "release writer");
      value(await host.resume(1), "same epoch writer handoff");
      const afterHandoff = await readVolume();
      equal((await issue(oldWrite)).error, "stale_generation", "old generation refused");
      equal(await readVolume(), afterHandoff, "generation refusal preserves checkpoint");
      value(await store.claim(1, "leaderB"), "new global epoch");
      equal((await issue(oldWrite)).error, "stale_epoch", "old epoch refused");
      equal(await readVolume(), afterHandoff, "epoch refusal preserves checkpoint");
      value(await host.freeze(), "release old epoch writer");
      value(await host.resume(2), "claim under new epoch");
      value(await host.prepare(["abort-or-commit"]), "prepare transaction race");
      const racing = host.begin();
      const frozen = host.freeze();
      const raced = await racing;
      value(await frozen, "freeze waits transaction settlement");
      const recovered = await readVolume();
      equal(host.view().committed, recovered.committed, "terminal result agrees with durable recovery");
      equal(host.view().lockHeld, false, "volume lease released after settlement");
      const successor = value(await glue.lock(name), "volume lease after freeze");
      assert(successor, "successor acquires released volume");
      value(await successor.release(), "release successor");
      value(await host.resume(2), "resume race session");
      const beforeNotification = host.view().committed.revision;
      freezeAfterCommit = true;
      value(await host.checkpoint(["commit-before-notification"]), "commit wins before freeze notification");
      value(await afterCommit, "freeze after commit settles");
      equal((await readVolume()).committed.revision, beforeNotification + 1,
        "commit remains durable when freeze precedes receipt handling");
      equal(host.view().committed.entries.at(-1), "commit-before-notification", "committed suffix recovered");
      lines.push(`PASS M2-B volume atomic fences, prepared freeze, transaction outcome=${raced.ok ? "committed" : raced.error}, commit-before-notification recovery`);

      const observed = [];
      const feedErrors = [];
      const feed = value(durable.feed(glue, store, model, {prefix, interval: 20, doorbells: false,
        onEntries: entries => observed.push(...entries.map(entry => entry.seq)),
        onError: error => feedErrors.push(error)}), "polling feed");
      feeds.push(feed);
      value(await feed.poll(), "initial consistent feed snapshot");
      const final = value(await store.append(2, {kind: "doorbell-dropped"}), "final write without doorbell");
      const deadline = Date.now() + 5000;
      while (feed.view().cursor < final.seq && Date.now() < deadline) await sleep(20);
      equal(feed.view().cursor, final.seq, "periodic read discovers final write");
      value(await feed.poll(), "overlapping full prefix replay");
      equal(new Set(observed).size, observed.length, "projection delivers contiguous entries once");
      equal(observed, Array.from({length: final.seq}, (_, index) => index + 1), "feed validates contiguous prefix");
      equal(feedErrors, [], "feed observations are valid");
      const bellFeed = value(durable.feed(glue, store, model, {prefix: `${prefix}-bells`, interval: 100,
        onError: error => feedErrors.push(error)}), "doorbell feed");
      feeds.push(bellFeed);
      const bell = value(glue.doorbell(`${prefix}-bells:feed`, () => {}), "real doorbell channel");
      for (const seq of [final.seq, 1, final.seq, 0]) value(bell.ring(seq), "reordered duplicate doorbell");
      await sleep(100);
      value(await bellFeed.poll(), "poll after reordered hints");
      equal(bellFeed.view().cursor, final.seq, "doorbells cannot replace authoritative prefix");
      value(bell.close(), "close doorbell sender");
      lines.push("PASS M2-B consistent feed polling with final doorbell dropped and duplicate reordered hints");

      const service = durable.services(store, model);
      const source = {service: "events", sender: "senderA", incarnation: 1, session: 1};
      value(await service.register(2, "events"), "register durable service");
      value(await service.handshake(2, source), "epoch handshake");
      const publication = {source, sequence: 1, payload: "hello"};
      value(await service.send(2, publication), "durable service send");
      const beforeReplay = value(await store.read(), "before duplicate send");
      assert(value(await service.send(2, publication), "identical send replay").duplicate,
        "duplicate logical send is idempotent");
      equal((await service.send(2, {...publication, payload: "changed"})).error,
        "conflicting_replay", "conflicting logical send refused");
      equal(value(await store.read(), "after send replay"), beforeReplay, "duplicate does not append or deliver");
      value(await store.claim(2, "leaderC"), "service leader recovery");
      const secondStore = value(await glue.open(prefix), "reopen service database");
      try {
        const recoveredService = durable.services(secondStore, model);
        const restored = value(await recoveredService.restore(), "restore durable channel projection");
        equal(restored.services, ["events"], "registered service survives epoch");
        equal(restored.messages.length, 1, "restore retains committed history without external delivery");
        equal(restored.sessions, [], "epoch transition invalidates sender handshakes");
        equal((await recoveredService.send(3, publication)).error, "missing_handshake",
          "new epoch requires handshake");
        const fresh = {...source, session: 2};
        value(await recoveredService.handshake(3, fresh), "fresh recovered handshake");
        value(await recoveredService.send(3, {source: fresh, sequence: 1, payload: "after-recovery"}),
          "progress after service recovery");
        equal((await recoveredService.handshake(3, source)).error, "stale_session", "old handshake refused");
        equal((await recoveredService.send(2, publication)).error, "stale_epoch", "old service epoch refused");
        equal(value(await recoveredService.restore(), "final service history").messages.length, 2,
          "one durable message per logical current-session send");
      } finally { value(secondStore.close(), "close reopened service"); }
      lines.push("PASS M2-B durable Service deduplication, changed-payload refusal, epoch handshake and reopen recovery");
      return ok({lines});
    } finally {
      for (const feed of feeds) await feed.stop();
      for (const host of hosts) await host.discard();
      for (const lease of held) await lease.release();
      value(store.close(), "close durable probe database");
    }
  }
  root.KiteDurableTests = {async run() {
    try { return await run(); }
    catch (error) { return {ok: false, error: String(error.stack || error)}; }
  }};
})(globalThis);
