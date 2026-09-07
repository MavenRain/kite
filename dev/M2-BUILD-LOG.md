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
