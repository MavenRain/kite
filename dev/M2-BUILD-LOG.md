# Kite M2 build log

## M2-A, 2026-09-07

Started from committed M1-C at `2099ac90db1e186332ae270f6d877e84739b3d07`.
The original checkout was clean. Implementation and validation used a tracked
source copy at `/Users/oobi/Documents/gpt10/kite-m2a`; publication checks the
original HEAD and file hashes before copying and staging. No commit is made.

Added pure Feed, Service, Volume, Taint and Manifest modules with interfaces,
their native suites, the DURABLE gate, a mutation runner and the M2 plan.
Cluster's new-start restriction composes by intersection and preserves
healthy existing placements. No browser effects or source declaration
semantics changed in this stage.

Independent review found and corrected two classes of defects before the
final validation:

- Visibility filtering initially widened an existing caller restriction.
  Repeated restrictions now intersect; disjoint, empty and overlapping
  policies have regression cases.
- Partial feed pages could forget an earlier advertised sequence/epoch
  boundary. The feed retains every outstanding boundary and validates both
  its exact epoch and the epoch ceiling it imposes on preceding entries.
  Contradictory data is rejected before downstream application.

The review also corrected the plan's probe assignment: PR-1 concerns
discard/freeze under memory pressure; future ports depend on PR-5 or PR-6.
Review found no weakening of inherited gates or changes to their bounds.

### Native validation

The pinned `@all` build succeeded. The initial cold js_of_ocaml runtime build
printed integer-overflow warnings from existing runtime constants; subsequent
BUILD gate execution was silent and successful. All OCaml compilation uses
the pinned switch and warning policy.

| Suite | Passed |
| --- | ---: |
| Feed | 22 |
| Service | 23 |
| Volume | 33 |
| Taint | 25 |
| Manifest | 20 |
| Total M2 native cases | 123 |

All eighteen deliberate safety mutations compiled and failed their intended
semantic test. Each selected case first passed alone, with an exact one-case
result, so an unknown selector cannot masquerade as a killed mutant.
[The mutation log](m2-a-validation/mutations.log) records the fresh baseline,
selected cases, successful builds and failures. Temporary copies were removed.

The retained Cluster, Kubelet and evaluator suites have 33, 34 and 32 cases.
HOUSE passed all seven checks. The eight-file elaborator and GLUE remain
subject to their existing 2,400-line and 300-line bounds.

### Full gate evidence

The complete twelve-leg battery exited zero with `GATES-OK`. Every measured
leg exited zero. [The gate log](m2-a-validation/gates.log) records the source
copy, Chrome version, all native and browser results, timing and corpus pins.

- Compiled source: 11 tests passed. Browser unit tests: 47 passed. The actual
  Chrome probe suite passed its lock, IndexedDB, worker and lifecycle checks.
- All six M1 source-driven behaviors passed. The hidden age was 306,280 ms;
  reported pod work began in 641 ms and leader convergence took 854 ms,
  within the unchanged 3,000 ms and 5,000 ms limits. The driver also checked
  the independently collected hidden timing evidence.
- Elaborator: 2,374/2,400 lines. GLUE: 235/300 lines. Corpus hashes and line
  counts remained unchanged.
- FLOOR: shipping pipeline 417.253 ms/kloc versus raw compiler floor
  474.393 ms/kloc. Both five-run medians were taken in minute
  `2026-09-07T19:29`, with host load 11.62 before and 12.21 after. The
  numerator includes check, lower, source artifact, both js_of_ocaml bridges
  and browser assets. No threshold or timing protocol changed.

Executable sources were frozen before the complete battery and hash-checked
again before publication. Documentation was finalized after the results.

### Scope remaining

M2-A validates native protocols only. Source manifest elaboration/emission,
real browser volume transactions and service transport, periodic durable
feed polling, retained source freeze execution, and M2's four manifests and
twelve browser fault injections remain M2-B and M2-C. Native crash models do
not establish browser discard behavior or guarantee a final freeze write.
The [M2 plan](M2-PLAN.md) records these obligations. Indexed invariant proofs
remain M3, and general source-to-WasmGC emission remains outstanding.

### Review round 1 fix pass 1 (2026-09-07)

| Id | File | What changed | Acceptance evidence |
| --- | --- | --- | --- |
| H5 | `test/service_test.ml`, `dev/gates.sh`, `dev/durable-mutations.py` | Two cases pin the sender generation fence in the restart direction and in the ahead direction, and one mutation drops the incarnation half of `same_generation`. | `RUNTIME suite=service tests=23 ok=23 fail=0`, `M2-MUTATION-KILLED service-generation-incarnation-bypass suite=service case=restart-incarnation-fences-old-session build=0 test=1` |
| H1 | `test/feed_test.ml`, `dev/gates.sh`, `dev/durable-mutations.py` | One case refuses a snapshot from an older head epoch with a higher sequence, and one mutation removes that fence. | `RUNTIME suite=feed tests=22 ok=22 fail=0`, `M2-MUTATION-KILLED head-epoch-stale-fence-removed suite=feed case=stale-head-epoch-refused build=0 test=1` |
| H17 | `test/manifest_test.ml`, `dev/durable-mutations.py` | The replica case now separates the requested count from the bound and covers the StatefulSet arm, and one mutation reports the bound. | `RUNTIME suite=manifest tests=20 ok=20 fail=0`, `M2-MUTATION-KILLED manifest-replicas-reports-bound suite=manifest case=valid-replica-bound build=0 test=1` |
| H10 | `test/volume_test.ml`, `dev/gates.sh`, `dev/durable-mutations.py` | Two cases pin the lock grant epoch test and the claim receipt pairing test, and two mutations remove them. | `RUNTIME suite=volume tests=33 ok=33 fail=0`, `M2-MUTATION-KILLED lock-grant-epoch-fence-removed suite=volume case=lock_grant_epoch_mismatch build=0 test=1`, `M2-MUTATION-KILLED claim-receipt-pairing-bypass suite=volume case=crossed_claim_receipt_refused build=0 test=1` |
| H3 | `test/feed_test.ml`, `runtime/feed.mli`, `dev/durable-mutations.py` | The bounded counter case pins the one billion literal and an entry sequence above the bound, and the poll comment states why the empty poll result is unreachable. | `M2-MUTATION-KILLED feed-counter-bound-doubled suite=feed case=bounded-counters build=0 test=1`, `M2-MUTATION-KILLED feed-entry-sequence-upper-bound-removed suite=feed case=bounded-counters build=0 test=1` |
| H14 | `test/taint_test.ml`, `dev/gates.sh`, `dev/durable-mutations.py` | Two cases refuse an invalid and a duplicate restriction name, and two mutations bypass each check. | `RUNTIME suite=taint tests=25 ok=25 fail=0`, `M2-MUTATION-KILLED restricted-name-check-bypass suite=taint case=restricted-config-invalid-name-refused build=0 test=1`, `M2-MUTATION-KILLED restricted-duplicate-check-bypass suite=taint case=restricted-config-duplicate-name-refused build=0 test=1` |
| H20 | `runtime/feed.mli`, `runtime/service.mli`, `runtime/volume.mli`, `runtime/manifest.mli`, `runtime/cluster.mli` | Every exported value now carries a doc comment, and the four volume comment blocks attach as documentation. | `PASS HOUSE`, and the doc scan over the six interfaces prints no value line |

Before this pass the five suites held 116 cases and nine mutations, and 27 exported values carried no doc comment. After this pass the five suites hold 123 cases and eighteen mutations, and every exported value of the six interfaces carries a doc comment.

The gate run after this pass prints feed 22, service 23, volume 33, taint 25 and manifest 20 cases, `M2-MUTATIONS tests=18 killed=18 survived=0 unbuildable=0`, GLUE 235 of 300 lines and the elaborator at 2,374 of 2,400 lines.

### Review round 1 fix pass 2 (2026-09-07)

| Id | File | What changed | Acceptance evidence |
| --- | --- | --- | --- |
| H5 | `test/service_test.ml`, `dev/gates.sh`, `dev/durable-mutations.py` | Kept from pass 1: two cases pin the sender generation fence in the restart direction and in the ahead direction, and one mutation drops the incarnation half of `same_generation`. | `RUNTIME suite=service tests=23 ok=23 fail=0`, `M2-MUTATION-KILLED service-generation-incarnation-bypass suite=service case=restart-incarnation-fences-old-session build=0 test=1` |
| H1 | `test/feed_test.ml`, `dev/gates.sh`, `dev/durable-mutations.py` | Kept from pass 1: one case refuses a snapshot from an older head epoch with a higher sequence, and one mutation removes that fence. | `RUNTIME suite=feed tests=22 ok=22 fail=0`, `M2-MUTATION-KILLED head-epoch-stale-fence-removed suite=feed case=stale-head-epoch-refused build=0 test=1` |
| H17 | `test/manifest_test.ml`, `dev/durable-mutations.py` | Kept from pass 1: the replica case separates the requested count from the bound and covers the StatefulSet arm, and one mutation reports the bound. | `RUNTIME suite=manifest tests=20 ok=20 fail=0`, `M2-MUTATION-KILLED manifest-replicas-reports-bound suite=manifest case=valid-replica-bound build=0 test=1` |
| H10 | `test/volume_test.ml`, `dev/gates.sh`, `dev/durable-mutations.py` | Two cases pin the lock grant epoch test and the claim receipt pairing test, and this pass corrects the interface reference of the pairing case to the ticket rule at `runtime/volume.mli` lines 75 to 79. | `RUNTIME suite=volume tests=33 ok=33 fail=0`, `M2-MUTATION-KILLED lock-grant-epoch-fence-removed suite=volume case=lock_grant_epoch_mismatch build=0 test=1`, `M2-MUTATION-KILLED claim-receipt-pairing-bypass suite=volume case=crossed_claim_receipt_refused build=0 test=1` |
| H3 | `test/feed_test.ml`, `runtime/feed.mli`, `dev/durable-mutations.py` | Kept from pass 1: the bounded counter case pins the one billion literal and an entry sequence above the bound, and the poll comment states why the empty poll result is unreachable. | `M2-MUTATION-KILLED feed-counter-bound-doubled suite=feed case=bounded-counters build=0 test=1`, `M2-MUTATION-KILLED feed-entry-sequence-upper-bound-removed suite=feed case=bounded-counters build=0 test=1` |
| H14 | `test/taint_test.ml`, `dev/gates.sh`, `dev/durable-mutations.py` | Kept from pass 1: two cases refuse an invalid and a duplicate restriction name, and two mutations bypass each check. | `RUNTIME suite=taint tests=25 ok=25 fail=0`, `M2-MUTATION-KILLED restricted-name-check-bypass suite=taint case=restricted-config-invalid-name-refused build=0 test=1`, `M2-MUTATION-KILLED restricted-duplicate-check-bypass suite=taint case=restricted-config-duplicate-name-refused build=0 test=1` |
| H20 | `runtime/feed.mli`, `runtime/service.mli`, `runtime/volume.mli`, `runtime/manifest.mli`, `runtime/cluster.mli` | Every exported value carries a doc comment, and this pass rewrites the plan epoch sentence of `runtime/cluster.mli` in active voice. | `PASS HOUSE`, and the doc scan over the six interfaces prints no value line |

Before this pass the volume suite comment pointed at the wrong interface lines and the plan epoch sentence used passive voice. After this pass the comment names the ticket rule at its present lines, the sentence is active, and the seven fixes hold with no change to any case count or mutation count.

The gate run after this pass prints feed 22, service 23, volume 33, taint 25 and manifest 20 cases, `M2-MUTATIONS tests=18 killed=18 survived=0 unbuildable=0`, GLUE 235 of 300 lines and the elaborator at 2,374 of 2,400 lines.

## M2-B, 2026-09-07

Started from committed M2-A at `d0cadb02095849da3d0331966867e9fd8ef300f1`.
The original checkout was clean. Implementation and validation used
`/Users/oobi/Documents/gpt10/kite-m2b`. Publication verifies the original
HEAD, index and file hashes, then copies and stages the validated changes.
The executable and gate inputs are pinned in
[sources.json](m2-b-validation/sources.json). No commit is created.

### Source and browser integration

The existing source evaluator now retains concrete `Deployment`,
`StatefulSet`, `Service` and `FreezeDrain` descriptions and validates them
with native Manifest constructors. It evaluates computed fields once.
Retained source sessions invoke captured freeze closures without replaying
startup; JavaScript owns continuation and lifecycle state. The OCaml
evaluator and models remain pure. The original generic manifest corpus
continues to pass. No trusted elaborator file changed.

The existing control bundle now includes native Feed, Service and Volume
bridges. Opaque branded handles preserve native request and receipt identity.
The browser effect boundary adds version-two volume storage, transactional
reads and writes, exact lease validation, polling and doorbells. GLUE remains
285/300 physical lines. Volume acknowledgements occur only at transaction
completion, including an abort that loses to commit.

Each source workload has an independent placement namespace and an immutable
initial descriptor stored atomically. Conflicting joins refuse before node
acquisition. Manifest admission uses current node incarnations and visibility
observations, returning an explicit denial when no node can admit new work.
StatefulSet volumes keep their workload/ordinal identity and regularly save
the fixture's observed Wasm tick values. Services use the target workload's
durable log with per-epoch handshakes and logical-send deduplication.

Integration review added regressions for retained placement leases after
cleanup refusal, volume reattachment across epoch changes, stale visibility
observations, conflicting manifest joins, canceled startup continuations and
freeze/resume races. Missing observations are omitted from durable heartbeat
payloads so the Feed's JSON contract remains valid after resume. A detached
volume can retry reattachment after an unsuccessful epoch handoff.

### Validation and observed limits

The native evaluator suite now has 42 cases, and the compiled source suite
has 17. The five inherited durable suites retain 123 cases. All eighteen
native safety mutations compiled and failed their intended semantic case,
with zero surviving or unbuildable mutations; see
[mutations.log](m2-b-validation/mutations.log).

Real Chrome ran all four source fixtures. Deployment started two pods and
refused a count above its emitted bound. StatefulSet reopened a marked
checkpoint under the same workload/ordinal and a fresh generation after
deliberate target closure. Service recovered one recorded message, refused
a conflicting retry and fenced the old epoch. The freeze fixture invoked
its captured closure after exactly one startup call, released leases and
resumed with a fresh incarnation. Its final checkpoint returned
`host_failed: node_unavailable`, demonstrating the explicit best-effort
outcome without discarding the previously committed prefix.

The [pressure log](m2-b-validation/pressure.log) records Chrome
`152.0.7977.77`, a critical memory-pressure notification and an explicit
`Page.setWebLifecycleState` freeze/resume cycle. Observed events were
`context,freeze,resume`; no `pagehide`, `wasDiscarded` or loss of the local
sentinel occurred. Recovery retained the committed prefix. This run did
not observe a browser discard. Target closure is identified separately as
deliberate recovery injection or cleanup.

The gate audit found no weakening of inherited tests, corpora, time limits,
line limits or benchmark comparisons. SOURCE's minimum rises from 32 to 41;
BROWSER adds the durable boundary, native bridge and workload suites, plus
the real source probes. HOUSE adds only the same two exact FFI array
conversion spellings for the durable bridge. FLOOR emits the combined
control/durable bundle and now explicitly uses the shipping evaluator's CPS
setting. The two frozen corpora and the eight-file elaborator are unchanged.

M2-C's complete twelve-fault matrix, an observed discard under memory
pressure, indexed M3 proofs and general source-to-WasmGC emission remain
outstanding. Recovery covers committed checkpoints and durable message
history; it does not promise arbitrary heap restoration or exactly-once
external message processing.

### Shipping pipeline correction

The first complete battery passed eleven legs, including 73 browser unit
tests and the full M1 hidden timing gate (307,010 ms hidden, pod work in
498 ms and leader view in 715 ms). FLOOR failed at 651.209 ms/kloc against
531.423 ms/kloc, with load 10.39 to 11.08. The earlier high-load preflight
had passed at 704.293 against 706.547; it did not establish the final
performance result. The full failed run and its input hashes are retained
as [gates-before-pipeline.log](m2-b-validation/gates-before-pipeline.log)
and [sources-before-pipeline.json](m2-b-validation/sources-before-pipeline.json).

The shipping builder now emits the independent control/durable and CPS
evaluator bundles concurrently. It waits for both compiler statuses before
assembly, and cleanup terminates and reaps unfinished children. Every source,
artifact, bundle and assembly phase remains inside the measured invocation.
R3 specifies end-to-end wall time and does not require serial independent
emission. `--output DIR SOURCE` retains the runnable package in a fresh
destination; existing destinations are refused. Tests cover the actual
compiled package, overlapping emissions, either compiler failing, source
failure, destination protection and signal cleanup. No corpus, comparison,
timer or source/runtime semantics changed for this correction.

All seven [pipeline regression cases](m2-b-validation/pipeline.log) passed.
The corrected [FLOOR preflight](m2-b-validation/floor-after-pipeline.log)
measured 385.086 ms/kloc against 442.000 ms/kloc in minute
`2026-09-07T22:22`, at load 8.66 to 8.29. The numerator still contains both
fresh emissions and complete assembly. Final source hashes were refreshed
after this code change and before the final complete battery.

### Final complete battery

The final [gate log](m2-b-validation/gates.log) ends with `GATES-OK`, and the
captured process and every one of the twelve measured legs exited zero.
BUILD was silent and successful. SOURCE passed 41 native evaluator cases
and 17 compiled program tests; BROWSER passed 90 unit and pipeline tests,
the durable transaction probes and all four real source integration fixtures.
The independent mutation run killed all eighteen native safety mutations.

All six M1 source-driven behaviors passed. The hidden age was 306,449 ms,
pod work began in 519 ms and the leader view converged in 756 ms, within
the unchanged 3,000 ms and 5,000 ms bounds. TRUSTED-LINES remained
2,374/2,400 and GLUE remained 285/300. Both corpus pins were unchanged.

Final FLOOR measured 387.198 ms/kloc against 444.115 ms/kloc, with both
five-run medians in minute `2026-09-07T22:28` and load 11.12 before and
after. All 212 frozen executable and gate input hashes matched again after
the battery. Documentation was finalized afterwards; publication checks
those hashes and the original checkout before copying and staging.

### Review round 1 fix pass 1 (2026-09-07)

| Id | File | What changed | Acceptance evidence |
| --- | --- | --- | --- |
| H10 | `browser/durable.js`, `browser/control.js`, `test/durable-browser.test.mjs`, `test/control.test.mjs` | The service doorbell now runs behind a guard and reports a failure through a new `onError` option, so a doorbell failure cannot rewrite a settled receipt. The control worker binds the doorbell through the current feed and sends the refusal as a diagnostic. Two cases cover a throwing doorbell and a close that clears the feed during a committed send. | `PASS BROWSER` with `# pass 90`; the guarded doorbell mutant fails `test/durable-browser.test.mjs` and the unguarded bind fails `test/control.test.mjs` |
| H17 | `test/durable-browser.test.mjs` | The lock fake now holds one name at a time and honors `ifAvailable`, and a stored fixture keeps written rows. Four cases cover the denied lock, the released lease fence, the freeze abort request and the retained checkpoint after that abort. | `PASS BROWSER`; the three volume mutants (lease dropped from the write, lock refusal not dispatched, abort request disabled) each fail the suite |
| H11 | `test/durable-browser.test.mjs` | Four cases pin the service counter bound at one billion, the feed read that lands after stop, the duplicate reply that rings no doorbell and the refused feed interval. | `PASS BROWSER`; the four matching mutants each fail the suite |
| H1 | `dev/gates.sh` | `leg_source` now reads the TAP summary of the compiled source suite. It refuses fewer than 17 passing cases and any failure, as a floor beside the 41 case evaluator floor. | A copy whose compiled suite holds one placeholder prints `FAIL SOURCE compiled=1 failed=0 floor=17` and exits 1 |
| H3 | `test/eval_test.ml` | One case refuses the malformed manifest schema at emission, through `A.of_program`, and not at evaluation. | `RUNTIME suite=eval tests=42 ok=42 fail=0`; a copy without the emission guard prints `ok=41 fail=1` and `FAIL SOURCE` |
| H2 | `test/program.test.mjs` | The manifest field test gains a block with three effectful fields in an order that differs from the schema order. It records the host arguments and pins declaration order. | `PASS SOURCE` with `# pass 17`; a copy that reverses the field list prints `# fail 1` and `FAIL SOURCE` |
| H6 | `test/control.test.mjs`, `test/workloads.test.mjs` | Each clause of the stored contract now refuses a join on its own, the count at the stored bound is accepted and recorded, and the visibility sequences of two observation rounds are compared. | `PASS BROWSER`; the three mutants (contract compared on two keys, exclusive desired bound, frozen observation sequence) each fail their suite |

Before this pass a committed service send was reported as a `TypeError` when
close cleared the feed, the compiled source suite had no gate count, the
emission time manifest guard and the manifest field order had no failing
test, and nine browser rules held on one clause each. After this pass the
doorbell failure is reported without touching the receipt, the SOURCE leg
refuses a shrunken compiled suite, and every listed rule has a case that
fails on the reverted code. The earlier validation sections keep the counts
of the recorded battery; this sentence carries the new counts.

The gate run after this pass prints feed 22, service 23, volume 33, taint 25
and manifest 20 durable cases, 42 native evaluator cases,
`M2-MUTATIONS tests=18 killed=18 survived=0 unbuildable=0`, GLUE 285 of 300
lines and the elaborator at 2,374 of 2,400 lines.

### Review round 1 fix pass 2 (2026-09-07)

| Id | File | What changed | Acceptance evidence |
| --- | --- | --- | --- |
| H10 | `browser/durable.js`, `browser/control.js`, `test/durable-browser.test.mjs`, `test/control.test.mjs` | No source change. Pass 1 keeps the guarded doorbell and the null safe bind. | A copy that rings the doorbell outside the guard fails `test/durable-browser.test.mjs` with exit 1. A copy that binds `feed.ring` without the null check fails `test/control.test.mjs` with exit 1. A copy that reverts both clauses still commits the receipt, because the effect boundary returns a result and never throws, so that report stays defensive. |
| H17 | `test/durable-browser.test.mjs` | No source change. | The three volume mutants each fail the suite with exit 1: the lease dropped from the write transaction, the lock refusal not dispatched, and the abort request disabled. |
| H11 | `test/durable-browser.test.mjs` | No source change. | The four service and feed mutants each fail the suite with exit 1: the counter bound removed, the read after stop admitted, the duplicate doorbell rung, and the interval guard removed. |
| H1 | `dev/gates.sh` | No source change. | A copy whose compiled source suite holds one placeholder case prints `FAIL SOURCE compiled=1 failed=0 floor=17` and exits 1. |
| H3 | `test/eval_test.ml` | No source change. | A copy without the emission guard of the encoder prints `RUNTIME suite=eval tests=42 ok=41 fail=1` and `FAIL SOURCE`. |
| H2 | `test/program.test.mjs` | No source change. | A copy that reverses the manifest field list prints `not ok 12`, `# fail 1` and `FAIL SOURCE compiled=16 failed=1 floor=17`. |
| H6 | `test/control.test.mjs`, `test/workloads.test.mjs` | No source change. | The three admission mutants each fail their suite with exit 1: the stored contract compared on two keys, the frozen observation sequence, and the exclusive desired bound. |

One plan item stays open. The H3 plan asks for a new count in the section
headed Validation and observed limits. That section records the battery of
the stage, so this pass keeps it as evidence. The sentence below carries
the new counts.

Before this pass the seven fixes of pass 1 carried no recorded mutation
result in this log. After this pass each fix names the mutation that its
test kills, and every named mutation fails the suite that owns the rule.

The gate run after this pass prints feed 22, service 23, volume 33, taint 25
and manifest 20 durable cases, 42 native evaluator cases,
`M2-MUTATIONS tests=18 killed=18 survived=0 unbuildable=0`, GLUE 285 of 300
lines and the elaborator at 2,374 of 2,400 lines.

## M2-C, 2026-09-07

Started from clean M2-B at `9b95017a8d4c780c142eb45fe68ca35bc74b1906`.
Implementation and validation use the tracked source copy at
`/Users/oobi/Documents/gpt9/kite-m2c`. Publication verifies the original
HEAD, clean destination, frozen executable hashes and staged file bytes.
The user commits; this stage only copies and stages the reviewed changes.

The regular BROWSER leg now requires all four source manifests and twelve
real-browser fault witnesses. Each row records its injection, typed outcome
and measured invariant evidence as JSON. Both the runner and a separate
transcript validator reject an incomplete matrix. Seventeen validator tests
cover missing rows, duplicate identities, renumbered clones, records below
the summary, malformed witnesses and a success summary without evidence.
No runtime or shipped browser source changes.

The durable probes use the production adapters and compiled native models
with real IndexedDB, Web Locks and BroadcastChannel. Dropped hints must be
recovered by timer-driven reads; reordered hints must actually arrive at the
channel callback. Old epochs, generations and Service sessions are refused
without changing committed data. Checkpoint freeze probes record real
transaction settlement before exact-lease release, and reopen an independent
connection to check the recovered prefix. The committed-notification case
deliberately drops the supplied observer callback after real IDB completion.

Starting and Stopping deaths run the production node host and nested pod
Worker behind test barriers. They verify refusal before native lease
release, child-lease disappearance, fresh-epoch replacement work and
detached-message rejection. A deliberate mutation removing only the
registered-handle guard in `KiteNode.message` failed the real Starting test
at `stale callback leaves replacement unchanged`, after all four source
fixtures passed. The [mutation output](m2-c-validation/handle-mutation.stdout.log)
and [expected failure](m2-c-validation/handle-mutation.stderr.log) retain
that evidence; the disposable source copy was removed.

`Target.closeTarget` invokes pagehide in the tested Chrome, so target closure
alone cannot establish death without graceful drain. The source StatefulSet
and Running fault now capture and terminate the actual workload control
Worker through the unchanged GLUE operation. Before closing the victim tab
for cleanup, the runner verifies that every workload lease disappeared and
neither pagehide nor freeze ran. The successor must recover the complete
committed prefix under the same volume key and a fresh epoch and generation.
Independent review found no remaining defects or weakened inherited gates.

The [PR-1 run](m2-c-validation/pressure.log) passed the full browser matrix,
then observed `context,freeze,resume` under critical memory pressure and
explicit lifecycle injection. The checkpoint prefix survived.
`wasDiscarded=false` and `local-state-lost=false`: a browser discard was
not observed. Deliberate Worker termination is recorded separately from
that diagnostic. These witnesses do not establish exactly-once external
message processing, arbitrary heap serialization or general WasmGC emission.
Indexed invariant proofs remain M3.

### Full gate evidence

The [complete battery](m2-c-validation/gates.log) exited zero with
`GATES-OK`, and all twelve measured legs exited zero. The original sandboxed
browser attempt passed the unit suites but could not bind its loopback
server (`listen EPERM`); real Chrome validation used the required local
server access. The initial pinned build succeeded with existing cold
js_of_ocaml integer-overflow warnings; the final BUILD leg was silent.

- Native evaluator: 42/42; compiled source: 17/17; browser unit tests:
  110/110, including the 17 transcript-validator cases and the 3 lifecycle
  runner cases. The BROWSER leg reads that TAP summary and requires at least
  105 cases with fail 0 and skipped 0, so a skipped or emptied suite fails.
- Real Chrome: all four manifests and twelve fault rows passed, followed
  by `M2-EVIDENCE OK manifests=4 faults=12`. The in-flight freeze observed
  `AbortError`, unchanged recovered data and lease release after settlement.
- All six M1 behaviors passed. Hidden age was 307,034 ms, pod work was
  reported in 477 ms and leader convergence in 680 ms, within the unchanged
  3,000 ms and 5,000 ms limits. Independent timing evidence also passed.
- The elaborator remains 2,374/2,400 lines and GLUE 285/300. Both pinned
  corpora and every shipping pipeline phase remain unchanged.
- FLOOR: pipeline 440.271 ms/kloc versus raw compiler 505.201 ms/kloc.
  Both five-run medians were taken in UTC minute `2026-09-08T04:04`,
  with host load 9.76 before and 9.14 after. No bound or timing protocol
  changed, and no retry was required.

The [source manifest](m2-c-validation/sources.json) pins 171 executable,
fixture and configuration files before the battery. Their hashes were
checked again afterward and before publication. Documentation and evidence
were finalized after validation; no executable changes followed the run.

### Review round 1 fix pass 1 (2026-09-08)

| Id | File | Change | Acceptance evidence |
| --- | --- | --- | --- |
| H1 | `dev/gates.sh` | The BROWSER leg reads the node TAP summary and requires at least 105 cases with fail 0 and skipped 0. | A copy with a skipped validator suite printed `FAIL BROWSER cases=31 failed=5 skipped=17 floor=105`; the tree prints `# pass 110` and `PASS BROWSER`. |
| H2 | `dev/m2-evidence.mjs`, `test/m2-evidence.test.mjs` | The validator pins the plan row name of every fault id and exports that table. | Twelve renumbered clones of row 1 give `M2-EVIDENCE REFUSED: faults[1].fault must be the plan row of id 2` and exit 1. |
| H3 | `dev/m2-evidence.mjs`, `test/m2-evidence.test.mjs` | The validator refuses a record below the success summary and keeps free order above it. | A summary-first transcript gives `line 3: record follows the M2-OK summary`; runner order still prints `M2-EVIDENCE OK manifests=4 faults=12`. |
| H4 | `test/m2-evidence.test.mjs` | The two argument-count arms run against the complete transcript and pin the usage message. | A copy without the usage check reports `# fail 1`; the tree reports `# pass 17`. |
| H7 | `test/m2-durable-probe.js`, `test/m2-lifecycle-probe.js` | Every witness field of rows 1, 3, 4, 6, 7, 9, 11 and 12 now reports a measurement, and the notification check counts events of either name. | The BROWSER leg prints row 12 with `"notificationsDelivered":0,"notificationsDropped":1` read from the event list, and row 9 with a numeric `nativeLeaseWaitMs`. |
| H11 | `test/m2-lifecycle-probe.js`, `dev/m2-lifecycle-faults.mjs`, `test/m2-lifecycle-faults.test.mjs` | Rows 7, 8 and 9 report a typed outcome built from the observed phase, epoch and generation. | No `"outcome":"ok"` remains in the twelve fault rows; the new case fails against the reverted line. |
| H13 | `dev/m2-lifecycle-faults.mjs`, `test/m2-lifecycle-faults.test.mjs`, `dev/gates.sh` | The cleanup closes the observer target after a failed victim tab close, keeps the matrix error and still fails a clean run. | `node --test test/m2-lifecycle-faults.test.mjs` reports `# pass 3`; the staged cleanup reports `# fail 3`. |

Before this pass the BROWSER leg accepted a skipped node suite, the validator
accepted renumbered clones and records below the summary, seven witness
fields carried chosen constants, three death rows recorded the word `ok`, and
a failed victim tab close hid the matrix error and left the observer target
open. After this pass the leg reads its own counts, the validator binds each
id to its plan row and to its position, every witness field is a measurement,
each death row names its observed epoch, and the cleanup always closes the
observer target.

The gate run after this pass prints feed 22, service 23, volume 33, taint 25
and manifest 20 durable cases, 42 native evaluator cases, 110 browser node
cases of which 17 are validator cases, `M2-EVIDENCE OK manifests=4 faults=12`,
`M2-MUTATIONS tests=18 killed=18 survived=0 unbuildable=0`, GLUE 285 of 300
lines and the elaborator at 2,374 of 2,400 lines.

### Review round 1 fix pass 2 (2026-09-08)

| Id | File | Change | Acceptance evidence |
| --- | --- | --- | --- |
| H1 | `dev/gates.sh` | Kept from pass 1. The BROWSER leg parses the node TAP summary and fails below 105 cases, or on any failed or skipped case. | The battery prints `# tests 110`, `# fail 0`, `# skipped 0` and `PASS BROWSER`. |
| H2 | `dev/m2-evidence.mjs`, `test/m2-evidence.test.mjs` | Kept from pass 1. The validator binds each fault id to its plan row name. | `node --test test/m2-evidence.test.mjs` reports `# pass 17` with `# fail 0`. |
| H3 | `dev/m2-evidence.mjs`, `test/m2-evidence.test.mjs` | Kept from pass 1. The validator refuses a record below the success summary. | The leg prints `M2-EVIDENCE OK manifests=4 faults=12` for runner order. |
| H4 | `test/m2-evidence.test.mjs` | Kept from pass 1. The two argument count arms run against the complete transcript and pin the usage message. | The suite reports `# pass 17` with `# fail 0`. |
| H7 | `test/m2-durable-probe.js` | Row 1 now counts every read of the durable connection. The direct read count of the probe is the difference between that total and the feed read count, so the witness can fail. | A copy with one direct probe read after the append fails with `no probe read of its own discovered the final write` and prints `FAIL BROWSER`; the tree prints twelve `M2-FAULT` rows and `PASS BROWSER`. |
| H11 | `test/m2-lifecycle-probe.js`, `dev/m2-lifecycle-faults.mjs` | Kept from pass 1. Rows 7, 8 and 9 report a typed outcome built from the observed phase, epoch and generation. | No `"outcome":"ok"` appears in the twelve fault rows of the battery. |
| H13 | `dev/m2-lifecycle-faults.mjs`, `test/m2-lifecycle-faults.test.mjs`, `dev/gates.sh` | Kept from pass 1. The cleanup always closes the observer target and keeps the matrix error. | The eleven file node run reports `# pass 110` with `# fail 0`. |

Before this pass the row 1 witness counted reads of a probe connection that
the row never read, so `manualReadsAfterAppend` was zero by construction and
its check could not fail. After this pass the row counts every read of the
durable connection and reports the reads that the feed did not make, so a
direct probe read raises the count and fails the row.

The gate run after this pass prints feed 22, service 23, volume 33, taint 25
and manifest 20 durable cases, 42 native evaluator cases, 110 browser node
cases of which 17 are validator cases, `M2-EVIDENCE OK manifests=4 faults=12`,
`M2-MUTATIONS tests=18 killed=18 survived=0 unbuildable=0`, GLUE 285 of 300
lines and the elaborator at 2,374 of 2,400 lines.
