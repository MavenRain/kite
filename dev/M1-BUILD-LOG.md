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
