# kite M1-B: browser host and transaction fence

This stage binds the M1-A models to browser Workers, Web Locks and
IndexedDB.  The user's continuation instruction authorizes the work.
The user-only M0-EXIT stamp remains reserved for the user.

## Deliverables

- `browser/model.ml` exports the existing OCaml models through
  js_of_ocaml.  It validates wire fields and keeps each lifecycle state
  in an opaque closure, preserving ticket history after worker exit.
- `browser/glue.js` is the sole browser effect boundary.  It adapts
  the commit callback from `ocaml-tea/lib/tea_client_run/idb.ml:127`
  and the one-shot grant callback from `tab_lock.ml:32`.  It returns
  outcomes for browser refusals.  It owns Worker creation and messaging,
  Web Locks and IndexedDB access.  Its physical line limit is 300.
- The sequence log reads and compares the epoch in the write
  transaction.  Epoch claim, sequence allocation and log append commit
  together.  A stale epoch aborts the transaction.  A plan can also
  require the sequence observed when it was computed.
- `browser/node-host.js` executes lifecycle actions in order.  It
  rechecks the worker ticket, incarnation and epoch after asynchronous
  acquisition and publication.  Payload work requires the pod lock,
  placement lock and committed publication.  Termination keeps the slot
  until the host has requested the real kill and observed the absence
  of that worker's unique lifetime lock.
- `browser/control.js` runs the planner in a dedicated Worker, owns
  nested pod handles, acquires the FIFO leader lease and claims its
  epoch.  Registry heartbeats and desired counts are log records.
  Placement and pod locks remain conservative reservations.  Freeze
  releases node and placement leases;  resume increments incarnation.
- `browser/pod.js` executes a small original Wasm test function after
  Begin_work.  `browser/index.html` is a two-tab host demonstration.
  It does not execute arbitrary Kite source programs.

## Boundary and implementation decisions

The native models remain OCaml with no new library dependency.
`js_of_ocaml` 6.2.0 is a dependency of the browser bridge only.
Two whole-line Array conversions at the FFI boundary are permitted by
HOUSE: converting a JS array to a list, and converting a rendered list
to a JS array.  No array access or mutation is added to OCaml code.

The JS host keeps the effect handles and asynchronous scheduling state.
The OCaml models retain placement and lifecycle decisions.  Browser
exceptions are absorbed only in GLUE and returned as named errors.
The browser audit checks the effect boundary and counts every physical
line of GLUE, including comments and blank lines.

Heartbeat time is seconds since Unix second 1,700,000,000.  Nodes share
the same clock origin;  values fit the JS OCaml integer range.  A node
expires after five missed seconds.  The local watchdog is five seconds,
above the 1,359 ms baseline in the design verdict's A7 row.  Browser
timing results, including hidden-tab measurements, are recorded separately.

The log is read in full in this stage.  Incremental feed, compaction,
storage limits and volume attachment remain M2 work.  A page freeze
notification is best effort.  A node with an expired heartbeat gets
no new placement even if its locks survive.  Pod locks still reserve
names until the browser reclaims a wedged context.

## Validation

```sh
zsh dev/pin-dune.sh dune build @all
zsh dev/gates.sh --leg browser
node dev/browser-test.mjs --hidden
zsh dev/gates.sh
```

The BROWSER leg includes boundary tests, adverse lifecycle callback
orderings with the real compiled model, and real Chrome tests.  Chrome
uses a temporary profile and a localhost server, both removed on exit.
The hidden probe leaves the target hidden for more than 305 seconds
before measuring nested-worker spawn and timer cadence.  It does not
disable background throttling.

PR-4 closes or terminates a writer after append has opened its
transaction.  The probe checks prefix recovery and the successor epoch
fence.  Its record distinguishes transaction start from observation of
the internal write requests.  These are different evidence points.

FLOOR retains the pinned numerator, floor corpus, five runs on each
side, same-minute check and ratio.  Each numerator sample now also emits
the browser model through js_of_ocaml and assembles the browser assets.
`dev/browser-pipeline.sh` uses a temporary output directory per sample.
The browser host uses the original test Wasm fixture;  this is not a
WasmGC backend measurement or a source-to-browser execution claim.

## Completion and next work

Stage B completion requires passing browser tests, recorded PR-2 and
PR-4 results and the full updated gate battery.  Stage C retains the
complete six-behavior acceptance corpus, the Stage 0 payload behavior,
and the desired-count timing thresholds after five hidden minutes.
It also connects the source-language shipping path to browser execution.
No M1 milestone pass is implied by this host stage.  Agents stage the
changes;  the user commits.
