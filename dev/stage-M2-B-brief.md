# M2-B: source manifests and durable browser hosts

The existing parser accepts the four concrete manifest forms. Artifact
emission preserves their expressions, and the existing evaluator evaluates
each field once before calling the native Manifest constructors. Generic
lowercase declarations remain compatible with the pinned M0 corpus.
Numeric replica bounds are runtime checks; indexed proofs remain M3.

The source session retains its final lexical environment and freeze closure.
Fresh lifecycle observations invoke that closure without replaying startup.
JavaScript owns asynchronous session state; the OCaml evaluator remains pure.
Freeze cancels incomplete startup before a late host reply can resume source
effects. An accepted freeze requires completed startup and an exact session
token with an increasing observation sequence; invocations cannot overlap.
The [source contract](stage-M2-B-source-contract.md) specifies the host API.

Each workload gets its own control Worker, IndexedDB database and placement
lock prefix, scoped by cluster and workload name. Its initial manifest
contract is stored atomically; a conflicting kind, count, bound or visibility
policy refuses a later join. Desired-count updates remain bounded by that
contract. Native Manifest and Taint perform live admission, including explicit
`Admit_denied:no_eligible_nodes`. Missing or stale visibility observations
cannot admit new starts. Existing M1 hidden-tab behavior remains the default
for the original desired-count demonstration.

The durable models share the existing compiled control bridge. Feed validates
consistent IndexedDB snapshots, with a periodic read even when every doorbell
is lost. BroadcastChannel contents never become authoritative log records.
Service operations reconstruct the validated prefix inside the write
transaction, check the epoch and sender generation, and commit one logical
send. Identical retries produce no new log record; changed payloads refuse.
Replay returns history without delivering historical messages. Service
bindings use the target workload's durable log, with no transferable ports.

StatefulSet volumes use workload name plus ordinal, independent of node
placement. Each volume has its own exact opaque Web Lock lease. Atomic
claims and writes compare the global epoch, writer generation and revision.
The browser exposes a receipt only on transaction completion. Abort keeps
the previous checkpoint, and a losing abort waits for the winning commit.
Native request and receipt handles cannot be forged by copying their fields.

The existing Wasm fixture checkpoints its observed tick values on regular
ticks. A new writer recovers the committed prefix. This is a concrete host
checkpoint contract, not serialization of an arbitrary program heap. An epoch
change reclaims running volumes under a fresh writer fence. Preparation has
no standing transaction. Freeze drops preparation or requests abort, retains
the volume lease until settlement, and releases placements through the
existing node lifecycle. A resumed node gets a fresh incarnation and must
publish a fresh visibility observation.

The retained source handler can request `host_checkpoint` for a StatefulSet.
That request races with lifecycle drain and may return an explicit refusal.
No final freeze-time write is guaranteed. External message handling is not
exactly once across recovery.

Validation retains all twelve inherited gate legs, the full M1 hidden timing
gate, both corpus pins, and the 2,400-line elaborator and 300-line GLUE bounds.
FLOOR emits the complete control/durable bridge and the evaluator with its
shipping CPS setting. The shipping builder overlaps these independent
emissions, waits for both compilers, and includes assembly in its measured
wall time. Native, boundary, source and real Chrome tests exercise
the integration. PR-1 records pressure and observed lifecycle events; a
deliberate target closure is reported separately from a browser discard.
M2-C still requires the complete four-manifest, twelve-fault matrix and its
per-fault witnesses. General source-to-WasmGC emission remains outstanding.
