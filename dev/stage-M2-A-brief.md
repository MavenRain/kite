# M2-A: native recovery and admission

This stage adds five pure runtime modules. They return validated state and
explicit outcomes for browser adapters to consume in M2-B. They do not open
IndexedDB, acquire locks, deliver messages or observe page lifecycle events.

| Module | Contract |
| --- | --- |
| `Feed` | Validate a contiguous committed prefix, fill notification gaps by polling, and distinguish identical from conflicting replay. Partial pages retain their accepted entry epoch. |
| `Service` | Reconstruct names, handshakes and messages from committed records. Fence epochs and sender generations, enforce contiguous sender sequences, and suppress identical replay within the current projection. |
| `Volume` | Keep stable namespace/ordinal keys, private writer requests and receipts, per-volume generations, revision comparisons, explicit transaction start/completion, freeze abort races, and committed-prefix recovery. |
| `Taint` | Validate visibility observations at the current node incarnation and restrict new starts without evicting healthy work. Compose restrictions by intersection. |
| `Manifest` | Construct four native descriptions, check numeric replica bounds, preserve StatefulSet identities, and refuse admission without an eligible live node when more replicas are needed. |

`Cluster.with_start_nodes` adds a restriction for new starts, retaining the
existing planner's health, epoch, lock reservation and least-load rules.
An empty restriction denies new starts. The default configuration keeps M1
behavior. Each manifest admission snapshot belongs to one workload; bare
integer ordinals cannot be shared across workload namespaces.

Counters stop at one billion in feed, service and volume protocols so
incrementing them remains representable across native and js_of_ocaml hosts.
Feed history and volume checkpoint entries are retained for replay and prefix
checks. Compaction, storage quotas and M4 resource bounds are not implemented.
Service delivery suppression applies to a live projection; replay after a
crash does not promise exactly-once consumer effects.

Volume helpers describe proposed atomic transactions. The adapter must read
the leader epoch, generation and revision consistently, keep the exact lease
held, and adopt the result only at transaction completion. Request success
alone is insufficient. A failed transaction retains the old durable value.
Freeze cannot guarantee a final write and may lose an abort race. Tickets
must remain unique across sessions whose callbacks can still arrive.

Build and validate with:

```
zsh dev/pin-dune.sh dune build @all
zsh dev/gates.sh --leg durable
python3 dev/durable-mutations.py
zsh dev/gates.sh
```

The DURABLE gate rebuilds its five native test executables and requires
exact suite counts. Every mutation must first pass its named baseline case,
then compile and fail that same semantic case. Missing case names, compile
errors and surviving mutations fail the mutation check. The full battery
still requires M1 source execution, real browser probes, the 306-second
hidden acceptance run, and the unchanged shipping-pipeline FLOOR protocol.

The next stages are in [the M2 plan](M2-PLAN.md). Source manifests, browser
volume transactions, retained freeze-handler execution and the twelve real
browser fault injections remain outstanding. Native tests are evidence for
these models only. Validation results live in [the M2 build log](M2-BUILD-LOG.md).
