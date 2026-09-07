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
