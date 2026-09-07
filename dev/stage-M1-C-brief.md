# M1-C: source execution and browser acceptance

M1-C implements the remaining running-cluster acceptance path from
`M1-PLAN.md`. The source corpus is `test/acceptance.kite`. It selects
desired counts, orders node creation and destruction, polls observations,
and makes the assertions for all six Stage 0 behaviors.

## Execution path

`kite build FILE.kite` checks the complete source, retains the `.kir`
output, and writes a sibling `.kite.js` data artifact. The artifact
contains lowered expressions and first-order import contracts. The
browser decodes it with `KiteProgram.start`, built by js_of_ocaml from
the same pure OCaml evaluator used by `kite run FILE.kite`.

The evaluator covers all twelve IR forms, with lexical closures, mutual
recursion, scoped record occurrences, variants, strict application and
short-circuit Boolean operators. Runtime failures are explicit values.
Integer execution uses signed 32-bit arithmetic on both hosts. Pure
evaluation yields after bounded batches of transitions. This permits
browser scheduling; it is not the M4 fuel bound.

Executable recursive groups require lambda bodies. Non-function recursive
initialization is refused explicitly, so a binding cannot duplicate or
silently skip effects when referenced. Host records require unique labels;
scoped duplicate labels remain available within source expressions.
Executable expression, pattern and host-contract nesting is limited to
256 levels, counting the root at zero. Deeper artifacts fail with
`artifact_depth` on both hosts. Dynamic function recursion is independent
of this structural limit and runs through the cooperative evaluator.

`browser/source.js` drives yielded states and asynchronous host calls.
Each call carries the source import's deadline and validates its reply
against the declared data type. Timeout and host failure stop source
continuation. A timeout does not roll back an already issued host effect.
The native CLI has no browser imports and reports an unavailable host
when a program calls one.

This is the permitted js_of_ocaml development path from design Q3.
General source-to-WasmGC emission remains outstanding. The pod workload
is the original 72-byte Stage 0 module, running `step(200000)` and
returning checksum `-1734620768`. Every pod is owned by its node's
control Worker and starts work only after publication and pod locking.

## Acceptance

Build through the pinned switch, then run:

```
zsh dev/pin-dune.sh dune build @all
_build/default/bin/kite.exe build test/acceptance.kite
node dev/drive.mjs
```

The driver owns an ephemeral loopback server, a fresh Chrome profile,
and all targets it creates. It closes those resources on completion or
failure. It uses no throttling override. A separate foreground page
executes the Kite program and forwards granular host operations through
the test bridge; the actual cluster loops remain in Workers.

| Behavior | Required observation |
| --- | --- |
| Registry | Each live tab observes the registered nodes, backed by node locks. |
| FIFO election | Node b queues before c, then succeeds a; c succeeds b. |
| Least-loaded placement | Six pods execute with two owners per node across three nodes. |
| Leader-death failover | Closing the leader's target causes epoch takeover and replacement of its pods. |
| Duplicate rejection | An injected durable command is replayed, denied the occupied pod lock, and its losing worker is observed exited without work. |
| Hidden operation | Both cluster tabs remain continuously hidden for at least 306 seconds; actual work starts within 3 seconds of a desired-count request, and the leader's own view converges within 5 seconds. |

The driver independently verifies hidden timing evidence before accepting
the source program's final behavior report. Work observations match the
current worker ticket and incarnation and the Stage 0 checksum. Leader
convergence requires the current epoch, desired count, unique pod locks
and placement reservations, and no pending planner commands.

`node dev/drive.mjs --quick` checks five behaviors and explicitly reports
that the hidden test and full milestone gate were not run. It cannot
satisfy the ACCEPTANCE leg of `dev/gates.sh`. The full battery includes
the complete acceptance run. Its 600 second watchdog accommodates the
mandatory aging period; the 3 and 5 second acceptance limits are fixed.

## Pipeline and scope

Every FLOOR sample includes checking, lowering, artifact serialization,
fresh js_of_ocaml emission for both the control model and evaluator,
and browser asset assembly. Frozen corpora, hashes, line counts,
five-run medians and same-minute comparison remain unchanged. No
WasmGC-only measurement substitutes for the shipping pipeline.

The existing eight-file elaborator bound remains 2,400 lines. The new
evaluator, artifact encoder and browser decoder are additional execution
and emission code, documented separately rather than moved into those
eight files. HOUSE includes their OCaml sources, allowing only the two
exact list/array conversion lines in each browser bridge. GLUE retains
its 300 physical-line bound and sole browser effect boundary.

M2 manifests, named services, taints and drain, M3 proofs, and M4 fuel
remain later work. The user-only M0-EXIT ratification is unchanged.
Changes are staged for the user to review and commit.
