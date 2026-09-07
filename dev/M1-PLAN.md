# kite M1 plan: a running cluster

Status: M1-A implementation.  The current user instruction to continue
building kite authorizes this implementation work.  It is not an
M0-EXIT ratification.  The user-only stamp in
/Users/oobi/Documents/tab-cluster-lang-m0/M0-PLAN.md:177 remains blank.

## Basis and boundary

The M0 plan defines only Stage A and Stage B
(/Users/oobi/Documents/tab-cluster-lang-m0/M0-PLAN.md:29).  M1 follows
those stages.  Its scope is the control Worker, nodes, pods, leader,
registry, placement, heartbeats and store
(/Users/oobi/Documents/tab-cluster-lang-m0/M0-PLAN.md:39).

The full milestone gate remains the design verdict's running-cluster
gate (/Users/oobi/Documents/tab-cluster-lang-design-verdict.md:317).
The stages below split its implementation;  none replaces that gate.
M1-A is native preparation for browser M1.  It establishes no browser
timing, browser lock behavior or durable-store guarantee.

## M1-A: pure control state

Add a deterministic snapshot planner and a pure node-local worker
lifecycle.  The planner uses both lock ownership and heartbeat age for
node eligibility, fences an old leader epoch, and assigns missing pod
names to the least-loaded eligible node with deterministic ties.
Replacement waits until both the placement lock and the pod lock are
absent.

The local lifecycle owns worker tickets and the node incarnation.
Worker construction precedes pod-lock acquisition;  work begins only
after the pod lock is acquired.  An epoch change cancels pending
starts.  Freeze releases the node and placement locks and terminates
local workers.  Resume uses a fresh incarnation.  Stopping workers keep
their slots until their exit is observed.

The modules return state and effects as values.  A browser host must
execute those effects and report their outcomes.  Native tests cover
the transitions and adverse event orderings.  M0 compiler behavior and
milestone refusals remain in force.  See dev/stage-M1-A-brief.md for the
deliverables and gate commands.

## M1-B: browser host and durable fencing

Implement the host GLUE and IndexedDB sequence log.  The per-tab control
Worker constructs each nested pod Worker and owns its handle.  The
page holds no cluster lock.  Bind the model's outcomes to real lock
acquisition, worker exit, freeze and resume events.

Fence writes by an epoch compare-and-set inside the same transaction.
Carry the Idb and Tab_lock shells by adaptation with provenance, as
listed in dev/CARRY.md.  The GLUE is the only module allowed to call
postMessage, new Worker, navigator.locks or indexedDB, with at most
300 audited lines
(/Users/oobi/Documents/tab-cluster-lang-design-verdict.md:329).

Run PR-2 for nested Worker spawn and timers under throttling, and PR-4
for IndexedDB write ordering against lock release.  Record the outcome
and the fallback taken for each probe.  A wedged node receives no new
placements;  stale writes fail the transaction's epoch fence
(/Users/oobi/Documents/tab-cluster-lang-m0/M0-PLAN.md:126 and :128).

## M1-C: browser acceptance and shipping pipeline

Run the six Stage 0 behaviors under headless Chrome through drive.mjs.
With both tabs hidden past five minutes, require pod work to start
within 3 seconds of a desired-count change and the leader's own view
to converge within 5 seconds.  These are acceptance thresholds, not
measurements from M1-A
(/Users/oobi/Documents/tab-cluster-lang-design-verdict.md:317).

Re-run GATE M0 with every shipping phase in the numerator.  Include
js_of_ocaml when the control plane ships through it, retain the pinned
corpus and floor protocol, and report any WasmGC-only number separately
(/Users/oobi/Documents/tab-cluster-lang-m0/M0-PLAN.md:45).

M1 completion requires the browser gate and the applicable pipeline
gate evidence.  Stage changes are staged for user review.  Agents do
not commit or push.
