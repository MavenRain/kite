# Kite M2 plan: declarative controllers and recovery

M2-A establishes native recovery and admission protocols. M2-B binds them
to the browser and source language. M2-C runs the complete milestone gate.
Passing a native stage does not establish IndexedDB durability or browser
freeze behavior. M1's six behaviors and shipping-pipeline FLOOR remain
required throughout.

M2-B implements the source and browser bindings described below. M2-C adds
the complete four-manifest, twelve-fault acceptance matrix to the regular
BROWSER leg, with a checked JSON witness for every row. The PR-1 diagnostic
distinguishes observed lifecycle events from discard and deliberate closure.
An observed discard under memory pressure remains outstanding; see the
[M2-C brief](stage-M2-C-brief.md) and [M2 build log](M2-BUILD-LOG.md) for
measured evidence and limits.

The basis is the design verdict's A3, A8 and A10 amendments and M2 row
(`/Users/oobi/Documents/tab-cluster-lang-design-verdict.md:287`, `:292`,
`:294`, `:304-318`) and the four Q4 examples in the design brief
(`/Users/oobi/Documents/tab-cluster-lang-design-brief.md:364-370`). Those
documents set twelve faults without enumerating twelve unique cases. The
matrix below pins concrete cases for Kite; it is an implementation plan,
not a claim that the design supplied this exact list.

## M2-A: native protocols

Implement a committed-prefix feed with sequence gap detection and replay
checks. BroadcastChannel supplies a doorbell, never authoritative data;
periodic reads must discover a final write even if every doorbell is lost.
Keep durable service names and messages across leader changes, invalidate
old sender handshakes, and refuse duplicate logical sends with conflicting
payloads. A replay reconstructs state without delivering historical messages.

Model StatefulSet volume identity as namespace plus ordinal, independent of
placement. Claim a writer under a volume lease and compare leader epoch and
volume generation in each atomic write. Preparation opens no transaction.
Only transaction completion acknowledges a checkpoint. Freeze may abort or
lose the race to a commit, then release the exact lease. Recovery returns a
committed prefix. No standing transaction or guaranteed freeze-time write
is permitted.

Add visibility observations and NoSchedule filtering for new starts. Hidden
nodes require explicit tolerance; missing observations cannot admit starts.
Healthy existing work remains placed. Frozen, expired and lockless nodes
remain ineligible. Restriction composition must never widen caller policy.

Provide native Deployment, StatefulSet, named Service and freeze-drain
descriptions, with numeric replica bounds, stable identities and total live
admission. These descriptions are not source manifests or indexed proofs.
Native state-machine tests, buildable safety mutations and all inherited
gates are the stage's acceptance checks.

## M2-B: source and browser integration

Extend the existing source manifest path, which currently checks generic
fields and erases the description during lowering. Define the four concrete
forms and emit their data contracts without adding a second interpreter.
Keep invariant and naming proofs in M3; runtime admission must still return
an explicit `Admit_denied` when no eligible node can satisfy a workload.
Use one placement namespace per workload in the browser adapter.

Bind feed reads to consistent IndexedDB snapshots, periodic polling and
doorbells. Bind volume claims and checkpoint writes to real transactions
covering the global epoch, writer generation and revision. Publish receipts
only on transaction completion, retaining previous state on abort. Verify
the exact volume lease is held when issuing either operation. Checkpoint on
regular ticks, with freeze as best effort. Release node and placement leases
through the existing lifecycle, and hold volume leases until outstanding
transactions settle. A resumed session gets fresh tickets and observations.
Run PR-1 for discard and freeze under memory pressure; record the observed
lifecycle events, loss of local state and recovery result separately from
deliberate target closure.

Expose named services as durable log channels with per-epoch handshakes.
The amended Service contract does not require transferable ports. Any later
port extension depends on PR-5 or PR-6 at M3, with the durable-log fallback
recorded explicitly. Restore must not be presented as exactly-once external
message processing.

Retain the source evaluator session and its registered freeze closure after
startup completes, or define a checkpoint host contract that keeps ownership
explicit. The current `KiteProgram.start` export does not retain that session;
re-running `Eval.invoke` would replay startup effects and cannot implement
freeze handling safely. Connect actual visibility and freeze observations
with freshness checks. Preserve M1's default hidden-tab behavior.

## M2-C: four manifests and twelve browser faults

Run source fixtures for Deployment with a checked replica bound, StatefulSet
reopen after node death, named Service recovery, and drain on freeze. M3
later supplies indexed proofs. Every fault below needs a recorded injection,
an observed typed outcome and an invariant witness from the real browser.
Native tests and mocked callbacks cannot satisfy these twelve rows.

| Fault | Required witness |
| --- | --- |
| 1. Drop the final doorbell | A periodic durable read discovers the final committed sequence. |
| 2. Reorder and duplicate doorbells | Contiguous application with no duplicate delivery in a live projection. |
| 3. Write from an old leader epoch | Transaction refusal and unchanged committed data. |
| 4. Write from an old volume generation in the same epoch | Transaction refusal after handoff and unchanged checkpoint. |
| 5. Duplicate a logical Service send | One recorded delivery; a changed payload with the same identity is refused. |
| 6. Replay an old Service handshake | New session progress remains authoritative. |
| 7. Kill a node in Starting | Its pending worker cannot publish work after replacement. |
| 8. Kill a node in Running | Reattachment recovers the committed volume prefix under a fresh fence. |
| 9. Kill a node in Stopping | Replacement waits for release evidence and stale callbacks cannot affect it. |
| 10. Freeze before checkpoint submission | Prepared changes are dropped; prior checkpoint remains recoverable. |
| 11. Freeze during the transaction | Commit or abort is observed before lease release; recovery agrees. |
| 12. Freeze after commit before notification | Recovery includes the committed write despite missing notification. |

Keep the full M1 hidden timing gate and all shipping phases in FLOOR. Do not
move corpora, thresholds or the elaborator and GLUE line bounds. M2 is
complete only after these four manifests and twelve browser faults pass.
General source-to-WasmGC emission remains a separate backend obligation.
The user commits staged changes; agents do not commit or push.
