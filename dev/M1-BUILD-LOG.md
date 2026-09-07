# kite M1 build log

## Stage A: pure control state, 2026-09-06

Base: `d14082d63778be7b318d4abda52ee1ea288cb61c`, the committed M0
Stage B.  Implementation and validation used a fresh copy of that
checkout.  Publication checks the original file hashes and HEAD before
copying, then verifies the copied bytes and stages the changes.

The runtime library contains two original modules, with public
interfaces and no dependency outside the OCaml standard library:

- Cluster validates snapshots, combines node-lock and heartbeat
  evidence, rejects stale epochs and plans least-loaded placement.
  Existing placements and pod locks reserve names until both disappear.
- Kubelet owns immutable worker slots, monotonic tickets and node
  incarnations.  Payload work needs a granted pod lock.  Leader changes
  cancel pending starts.  Freeze releases locks and requests termination;
  a stopping slot stays occupied until its matching exit arrives.

The implementations contain 185 and 240 lines respectively.  Their
interfaces contain 73 and 81 lines.  These modules are runtime models;
they do not change the eight M0 elaborator files or their 2,400-line
budget.  The RUNTIME gate joins the existing battery, and HOUSE now
includes runtime sources and interfaces.

### Review correction

A delayed successful node-lock acquisition could arrive after freeze
and return an error with no release action.  The model now emits a
release for the callback's incarnation and keeps current ownership
unchanged.  The host must release by incarnation.  Two regression
traces cover acquisition during freeze and an obsolete acquisition
after a newer generation holds the node lock.  Independent static
verification confirmed this repair and found no gate weakening.

### Validation

`zsh dev/pin-dune.sh dune build @all` exited 0 with no diagnostics.
`zsh dev/gates.sh` exited 0 and ended with `GATES-OK`.  Raw output is in
[m1-a-validation/gates.log](m1-a-validation/gates.log).

| Check | Result |
| --- | --- |
| BUILD and HOUSE | PASS |
| PARSE | 46 fixtures pass |
| CHECK | 13 positives, 6 refusal twins, spine and 44 semantic regressions pass |
| RUNTIME | 33 planner cases and 34 lifecycle cases pass |
| TRUSTED-LINES | 2374/2400 |
| DENOMINATORS | PASS, frozen corpus checks retained |
| FLOOR | 125.463 ms/kloc pipeline, 1345.600 ms/kloc raw compiler |

The runtime cases include snapshot permutations, placement invariants
across desired counts, bounded lifecycle trace exploration, and a
planner-to-worker integration trace.  These are native model checks.

`python3 dev/runtime-mutations.py` exited 0.  All six mutants compiled
and each failed its named semantic test.  None survived, and no build
failure counted as a kill.  Raw output is in
[m1-a-validation/mutations.log](m1-a-validation/mutations.log).

| Deliberate regression | Rejecting case |
| --- | --- |
| Ignore expired heartbeat | heartbeat-boundary-expired |
| Ignore the current epoch on authorization | epoch-fence |
| Ignore the surviving pod lock | release-before-replace |
| Begin work after a denied pod lock | lock-denied |
| Keep pending starts after leader change | epoch-cancels-pending |
| Drop cleanup of a delayed node acquisition | late-node-acquisition |

### Next work

M1-B binds the model to browser Workers, Web Locks and IndexedDB with
transactional epoch fencing and the PR-2/PR-4 probes.  M1-C runs the
headless browser acceptance corpus and hidden-tab timing gate, then
measures the shipping pipeline including js_of_ocaml when used.  No
browser runtime, timing result or durable-storage guarantee is claimed
by M1-A.  The user-only M0-EXIT stamp remains blank.  No commit or push
was made by an agent.

## Stage B: browser host and durable fencing, 2026-09-06

Base: `152c556f21dc494833afa1e19ccf9cf71b2e60bc`, the committed M1-A.
Work used a fresh source copy.  Publication checks the original HEAD,
clean index and file hashes before copying.  It verifies every copied
file and stages the complete Kite worktree.  Agents do not commit.

### Implementation

The browser bridge exports the unchanged Cluster and Kubelet models
through js_of_ocaml 6.2.0.  Lifecycle state is an opaque closure, so
worker tickets remain monotonic after the worker list becomes empty.
Wire fields are validated before entering the models.  HOUSE scans
the bridge and allows only its two exact list/array conversion lines.
The toolchain wrapper now pins opam library paths as well as PATH.

The 235-line GLUE owns all Worker, messaging, Web Locks and IndexedDB
calls.  Its sequence log compares epoch and optional expected sequence
inside the same transaction that allocates a sequence and appends a
record.  Success comes from transaction completion.  A stale epoch,
stale sequence or clone failure aborts all pending metadata and payload
changes.  The Idb and Tab_lock callback patterns are adapted with the
source rows recorded in PROVENANCE.md.

The control Worker owns each nested pod handle.  The node adapter
checks ticket, incarnation and epoch across asynchronous publication.
Work needs the pod lock, placement lock and committed publication.
Freeze invalidates model state before waiting for outstanding effects.
Resume waits for freeze cleanup and acquires a fresh node incarnation.
The local watchdog stops a pod after five seconds without progress.

The browser demonstration uses an original Wasm increment function.
Kite-source browser execution, the complete six-behavior acceptance
corpus and the M1-C timing thresholds remain outstanding.  This stage
does not claim the M1 running-cluster milestone gate.

### Review corrections

- A late placement or append continuation could stop a newer ticket
  for the same pod.  Cleanup now checks the exact current ticket.
- A failed initialization message left a Starting worker occupied.
  It now requests termination and observes its unique lifetime lock
  before reclaiming the slot.
- A failed Resume acquisition left the model ready without a lease.
  The current incarnation now returns to Frozen and reports its error,
  so a subsequent Resume can retry.
- A delayed election could install an obsolete leader after freeze
  and resume.  Election attempts carry a lifecycle generation and
  incarnation;  obsolete acquired leases are released.
- Serializing every control request behind publication delayed freeze.
  Lifecycle requests now invalidate state immediately and bypass the
  ordinary reconciliation queue.  Canceled boot attempts close storage
  and release any late node acquisition.
- Same-epoch desired writes could overtake an already computed plan.
  Command publication now compares the observed sequence as well as
  epoch.  Obsolete command replay is filtered by incarnation and the
  latest desired count.

### Browser probes

PR-2 passed in isolated headless Chrome 152.0.7977.77.  The harness
checked that the page stayed hidden throughout the wait and used no
throttling override.  At the final observation the hidden age was
308,092 ms.  Root-worker spawn took 593 ms, nested-worker spawn 50 ms,
and the first payload work after Begin took 47 ms.  Six observed
intervals for the 40 ms worker timer were 42, 39, 41, 40, 40 and 40 ms.
Raw output: [m1-b-validation/hidden.log](m1-b-validation/hidden.log).

This is PR-2 evidence for this Chrome build.  It is not the M1-C
desired-count acceptance run with both cluster tabs hidden.  The
fallback remains conservative: stop placing on a node whose heartbeat
expires, while surviving pod locks reserve its names until reclamation.

PR-4 reports the exact interruption point.  The writer starts append
before the harness terminates it, but internal write-request queuing
is unobserved.  Prefix recovery and successor-epoch refusal are the
claimed properties.  The epoch fence remains required for every write,
independent of browser transaction-versus-lock-release ordering.

The final battery also closes the writer's whole tab through
Target.closeTarget.  An independent observer queues for the writer's
leader lock before the append.  After tab close it takes the lock and
claims epoch 2 before reading the log.  The first attempt interrupted
the transaction, preserved the prior committed prefix and refused an
old-epoch append.  Worker termination and connection-close checks also
pass.  The internal write-request queuing point remains unobserved.

### Final gate evidence

The complete updated battery is recorded in
[m1-b-validation/gates.log](m1-b-validation/gates.log).  Its FLOOR
numerator includes native checking and lowering, fresh js_of_ocaml
emission and browser asset assembly on every sample.  The pinned
corpora, five runs per side, same-minute rule and comparison are retained.
The battery exited zero and ended with GATES-OK.  Every leg passed.

| Check | Result |
| --- | --- |
| BUILD and HOUSE | PASS |
| PARSE | 46 fixtures pass |
| CHECK | 13 positives, 6 refusal twins, spine and 44 semantic regressions pass |
| RUNTIME | 33 planner cases and 34 lifecycle cases pass |
| Browser audit | 235/300 GLUE lines;  4 negative-control groups pass |
| Browser boundary and runtime races | 29 tests pass |
| Real Chrome | 9 named checks pass, including actual tab-close recovery |
| TRUSTED-LINES | 2374/2400 |
| DENOMINATORS | PASS, frozen corpus checks retained |
| FLOOR | 239.092 ms/kloc pipeline, 446.582 ms/kloc raw compiler |

The final FLOOR run measured both sides in UTC minute 2026-09-07T06:21
on the same host.  Load was 13.49 before and after.  No ratio, corpus
pin or timing rule was relaxed.  The separate hidden probe has its own
raw record above.  Documentation completion followed the gate run;
no executable source changed after that run.

## Stage C: source execution and browser acceptance, 2026-09-07

Base: `be3382a7a7735a9713c08cca1e05cff177aa56c4`, the committed M1-B.
Implementation and validation used a fresh copy at
`/Users/oobi/Documents/gpt10/kite-m1c`. Publication verifies the original
HEAD and all baseline file hashes, copies the completed files, verifies
their hashes again, and stages all Kite changes. No agent commit or push
is performed.

### Implementation

`kite build FILE` retains the lowered IR and emits `FILE.kite.js`, a
checked-data artifact. `kite run FILE` executes pure programs natively.
The same persistent OCaml evaluator runs in browsers through js_of_ocaml.
The browser bundle excludes the checker and artifact encoder. Explicit
host-call states carry their declared reply contract and deadline; source
continuation resumes only after a valid reply. Pure evaluation yields in
batches of 1,000 transitions.

Execution covers all twelve IR forms, with lexical scope, mutual function
recursion, scoped records and variants, and signed 32-bit arithmetic.
Non-function recursive initialization, out-of-range integer literals,
unsupported host types, and structures deeper than 256 are explicit
refusals. Freeze expressions remain deferred. These development-runtime
limits are specified in SPEC.md and the M1-C brief. General source-to-WasmGC
emission and M2 drain behavior are not claimed here.

The acceptance program is checked Kite source. It controls creation and
destruction order, desired counts, polling predicates, assertions and
the six behavior reports. Its host imports expose individual operations
and observations. The CDP runner verifies that the six reports occurred
and independently checks the hidden-tab timing evidence.

Pods now execute the required Stage 0 72-byte Wasm module, adapted from
`tab-cluster-spike/web/pod.wat`. `step(200000)` returns `-1734620768`.
The module digest is
`4e5c8ccbe25516f62f531d35246a86ab257c19410237b4d864760318e7b657c2`.
The control Worker still owns every pod handle and its watchdog.

### Review corrections

- An older reconcile snapshot no longer releases a newly claimed leader
  lease. Resume attempts share acquisition within one generation and are
  canceled by a later freeze.
- The five second watchdog covers Starting and unpublished workers.
  Termination retries preserve occupied slots until successful native
  termination and lifetime-lock absence, including while the node is frozen.
- Duplicate refusal evidence records the losing ticket and its observed
  exit. The acceptance test requires durable replay, no losing-worker work,
  and one surviving owner.
- An elapsed-time check closes the host deadline race when a delayed timer
  could lose to an overdue synchronous reply. Unexpected host decoding
  errors return an explicit failure from the public source runner.
- Executable recursive values are refused rather than reevaluating an
  effectful initializer at every use or skipping an unused initializer.
  Structural limits make native preparation and browser decoding agree.
- Standalone SOURCE now builds its compiler, native evaluator test and
  browser bridge prerequisites before testing. Its final scoped run is in
  [m1-c-validation/source.log](m1-c-validation/source.log).

Independent reviews covered source execution, host boundaries, lifecycle
changes, gate preservation, pipeline completeness and publication checks.
The original six lifecycle regressions failed before their fixes. All
required source and browser regression checks pass with the final code.

### Acceptance and gate evidence

The complete battery exited zero and ended with `GATES-OK`. Raw output is
in [m1-c-validation/gates.log](m1-c-validation/gates.log). Chrome was
152.0.7977.77, using an isolated profile and no throttling overrides.

| Check | Result |
| --- | --- |
| BUILD and HOUSE | PASS |
| PARSE | 46 fixtures |
| CHECK | 13 positives, 6 refusal twins, spine and 44 semantic regressions |
| RUNTIME | 33 planner cases and 34 lifecycle cases |
| SOURCE | 29 native evaluator cases and 9 compiled browser cases |
| Browser audit | GLUE 235/300 lines, 6 scripts, 4 negative-control groups |
| Browser boundary/lifecycle tests | 43 tests pass |
| Real Chrome host probes | All named checks pass, including interrupted writer-tab recovery |
| M1 source acceptance | Six behaviors pass |
| TRUSTED-LINES | Elaborator 2374/2400; additional evaluator 295, encoder 146, decoder 211 lines |
| DENOMINATORS | PASS, frozen corpus and hash checks retained |
| FLOOR | Pipeline 576.422 ms/kloc, raw compiler 685.407 ms/kloc |

At the desired-count request, the two cluster tabs had been continuously
hidden for 309,848 and 306,253 ms. The source observed work in 754 ms and
the leader's own converged view in 874 ms. The independent driver recorded
a matching current-worker checksum tick at 530 ms and converged leader
snapshot at 862 ms. Both measurements satisfy the fixed 3,000 and 5,000 ms
limits. The full ACCEPTANCE leg took 375,301 ms, including hidden aging.

Every timed pipeline sample emitted checked IR, the source artifact,
fresh js_of_ocaml control and evaluator bundles, and browser assets.
The five samples per side stayed in UTC minute 2026-09-07T09:35 on the
same host, with load 44.01 before and 42.25 after. The corpus pins,
comparison and timing rules were unchanged. No WasmGC-only number replaced
the complete pipeline measurement.

The retained use-count mutant built successfully and was killed by the
Affine and Capture refusal tests. Raw output is in
[m1-c-validation/use-count-mutant.log](m1-c-validation/use-count-mutant.log).
The updated legacy driver check SB-G12 also passed, including native
`run` returning 42 and missing-file usage returning exit 2.

One early quick browser run timed out in a host-view call following
leader closure. Its record is preserved in
[m1-c-validation/quick-timeout.log](m1-c-validation/quick-timeout.log).
Two subsequent quick runs and the complete gate passed. Additional CDP
operation diagnostics remain in the runner. The original timeout's cause
is unconfirmed; no deadline or acceptance threshold was relaxed.

M1's measured running-cluster gate is satisfied on this Chrome build.
M2 is next. The user-only M0-EXIT stamp remains unchanged.

### Review round 1 fix pass 1 (2026-09-07)

| Id | File | What changed | Acceptance evidence |
| --- | --- | --- | --- |
| H1 | browser/dune, test/program.test.mjs | Before the fix, a 20,000 deep source recursion returned `Maximum call stack size exceeded` in the browser and 200010000 natively. The fix compiles the program executable in browser/dune with js_of_ocaml `--effects=cps`. The evaluator return chain no longer spends a JavaScript stack frame per non-tail call. After the fix, both hosts return 200010000 for the same recursion. `test/program.test.mjs` pins the browser value. | `# pass 11` and `# fail 0` for program.test.mjs, then `PASS SOURCE` |
| H7 | runtime/artifact.ml, test/eval_test.ml, test/program.test.mjs, dev/gates.sh | The encoder escapes every scalar value above 127, so the emitted artifact is ascii only, and it refuses a string that is not valid utf-8 with `executable strings require valid utf-8`. A new evaluator case pins the refusal and a new browser case pins the ascii bytes and the decoded value. | `RUNTIME suite=eval tests=32 ok=32 fail=0`, then `PASS SOURCE` |
| H10 | browser/source.js, test/acceptance-bridge.js, dev/drive.mjs, test/source.test.mjs | The failure name is built inside a guard, so a thrown value that refuses conversion returns the fixed name `host_error` instead of rejecting the public runner. The acceptance bridge and the driver use the same guard. | `# pass 47` and `# fail 0`, then `PASS BROWSER` |
| H2 | test/eval_test.ml, dev/gates.sh | Two multiplication cases pin the wrapped signed 32-bit products 1410065408 and 0. The case count floor of the SOURCE leg moves from 29 to 32, so a deleted case fails the leg. | `RUNTIME suite=eval tests=32 ok=32 fail=0`, then `PASS SOURCE` |
| H16 | browser/control.js, test/control.test.mjs | Reconcile tests its generation before it records the heartbeat tick. A resume that runs during an open heartbeat append keeps its heartbeat reset, so the next cycle publishes the new incarnation. | `# pass 47` and `# fail 0`, then `PASS BROWSER` |
| H15 | browser/control.js, test/control.test.mjs | A desired count refused with `stale_epoch` reads the log once more and appends at the fresh epoch. The retry runs once and the durable fence is unchanged. | `# pass 47` and `# fail 0`, then `PASS BROWSER` |
| H17 | browser/control.js, test/control.test.mjs | The `invalid_request` refusal echoes the correlation id, so the caller settles at once instead of waiting out its ten second timer. | `# pass 47` and `# fail 0`, then `PASS BROWSER` |

Each new case was run against the reverted code and failed there. No id was
skipped. The gate run after this pass reports GLUE at 235 of 300 lines, 32
cases in the `RUNTIME suite=eval` line, 47 node tests in the BROWSER leg, and
`TRUSTED-LINES elaborator=2374/2400 OK`.
