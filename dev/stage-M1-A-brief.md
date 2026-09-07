# kite M1-A brief: pure control state

Status: implementation slice for M1.  This stage provides native model
behavior for the browser host to consume.  It does not complete the
running-cluster milestone or fill the user-only M0-EXIT stamp.

## Scope and sources

M1 owns the node, leader, registry, placement, heartbeat, pod and store
mechanisms (/Users/oobi/Documents/tab-cluster-lang-m0/M0-PLAN.md:39).
The design requires both locks and heartbeat deadlines for liveness,
least-loaded placement, and a per-tab control Worker that owns each
pod handle
(/Users/oobi/Documents/tab-cluster-lang-design-verdict.md:301).
Freeze releases node and placement locks under the ruled OQ3
(/Users/oobi/Documents/tab-cluster-lang-m0/M0-PLAN.md:25).

M1-A implements pure decision and transition functions.  It adds no
browser call, storage transaction, source-language runtime form or
proof claim.  The current continuation instruction authorizes this
slice.  The M0-EXIT stamp remains reserved for the user
(/Users/oobi/Documents/tab-cluster-lang-m0/M0-PLAN.md:177).

## Deliverables

1. runtime/cluster.ml and runtime/cluster.mli define a validated
   snapshot planner.  A node is eligible only while its required lock
   evidence and heartbeat deadline hold.  An old leader epoch cannot
   issue a placement plan.  Missing names start in deterministic order
   on the least-loaded eligible node, with deterministic node ties.
   Either a remaining placement lock or a remaining pod lock prevents
   replacement of the same name.
2. runtime/kubelet.ml and runtime/kubelet.mli define node-local worker
   lifecycle state and effects.  Node acquisition carries a generation,
   and each worker start carries a unique ticket.  The host constructs
   the worker before attempting its pod lock.  Begin_work is emitted
   only after successful pod-lock acquisition.  Epoch changes cancel
   pending starts, and obsolete tickets cannot begin work.  Freeze
   releases node and placement locks and terminates local workers.
   Resume begins a fresh incarnation.  A stopping slot remains occupied
   until the worker's exit is observed.
3. runtime/dune builds the native runtime library.  State and effects
   stay explicit values with total error handling.  This stage does
   not add these runtime modules to the M0 elaborator's trusted-line
   numerator.
4. test/cluster.ml and test/kubelet.ml exercise visible plans, effects
   and failure cases.  Tests cover deterministic scheduling, each
   liveness source, epoch fencing, both replacement locks, lifecycle
   event ordering, obsolete completion events, freeze, resume and
   retained stopping slots.
5. dev/gates.sh gains a RUNTIME leg that runs both native suites and
   participates in the full battery.  Existing M0 gate legs remain.
   dev/house.sh includes runtime .ml and .mli files in its checks.
6. dev/M1-PLAN.md records the next host and browser acceptance stages.
   The build log records actual validation results after the commands
   below run.  A planned result is not recorded as a pass.

## Gate commands and acceptance

Run from the repository root with the pinned toolchain wrapper:

```sh
zsh dev/pin-dune.sh dune build @all
zsh dev/gates.sh --leg runtime
python3 dev/runtime-mutations.py
zsh dev/gates.sh
```

The build exits zero.  The RUNTIME leg passes both suites and exits
zero.  The full battery retains its existing M0 acceptance checks,
includes RUNTIME, and ends with GATES-OK.  A failed suite or a missing
runtime executable must fail the runtime leg.

The mutation runner checks six deliberate safety regressions in
disposable copies.  Every mutant must build and fail its selected
semantic test.  A failed build cannot count as a killed mutant.

The native tests must reject these adverse cases:

- A node with a held lock but an expired heartbeat receives a start.
- A node with a fresh heartbeat but missing lock evidence receives a
  start.
- An old leader epoch produces placement work.
- Either remaining lock permits replacement of the same pod name.
- A worker begins work before acquiring its pod lock.
- An obsolete start ticket begins work after cancellation or resume.
- Freeze leaves a local worker eligible to begin work.
- A stopping worker's slot is reused before its exit is observed.

Test deterministic ties using snapshots whose input ordering differs.
Check lifecycle outputs through event sequences, including delayed
outcomes from a prior ticket or incarnation.  These native checks
verify model behavior.  The browser adapter must later preserve the
same ordering when it performs effects.

## Completion boundary and later gates

M1-A is ready when its code, tests, documentation and gate integration
are staged with passing native evidence.  It leaves the M0 parser and
checker milestone refusals intact.  It makes no claim that a browser
worker starts or dies within a measured interval.

M1-B implements the browser GLUE, the IndexedDB transaction fence, and
PR-2 and PR-4.  M1-C runs the six Stage 0 behaviors through headless
Chrome and drive.mjs.  With both tabs hidden past five minutes, pod
work must start within 3 seconds of a desired-count change and the
leader's own view must converge within 5 seconds
(/Users/oobi/Documents/tab-cluster-lang-design-verdict.md:317).

The browser GLUE stays at or below 300 audited lines.  When the control
plane ships through js_of_ocaml, its time joins the shipping pipeline
numerator and GATE M0 is re-run
(/Users/oobi/Documents/tab-cluster-lang-m0/M0-PLAN.md:45).
The host and hidden-tab gates are outstanding after M1-A.  Agents stage
changes for the user and do not commit or push.
