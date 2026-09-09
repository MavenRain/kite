# M2-C: browser fault acceptance

M2-C makes the [M2 plan](M2-PLAN.md)'s twelve fault rows part of the regular
BROWSER gate. The runner executes the four checked source fixtures and
records a separate injection, typed outcome and invariant witness for every
fault. Source StatefulSet recovery terminates its actual workload control
Worker without a graceful checkpoint or drain. The runner verifies that
all workload leases disappear and no pagehide or freeze handler ran before
closing the victim tab for cleanup.

The durable probes use the production GLUE, browser adapters and compiled
native models with real IndexedDB transactions, BroadcastChannel messages
and Web Locks. Test decorators delay or observe specific callbacks to place
faults at reproducible boundaries. They do not substitute transaction
results or supply fake lock ownership. A freeze during a submitted
transaction may abort or lose to commit; its recorded terminal outcome must
agree with recovery, and settlement must precede lease release.

The node probes run the production node host and nested pod Worker. Test
barriers hold Starting and Stopping at observable boundaries before the
node Worker is terminated. A successor must wait for actual lock release.
Captured messages from the dead Worker are replayed against the successor
to test detached-handle rejection before they can publish state or work.
Running recovery terminates the control Worker of a source StatefulSet.
These deliberate terminations do not establish a browser discard under
memory pressure. The separate PR-1 diagnostic reports observed lifecycle
events and `document.wasDiscarded` without reclassifying target closure.

Each successful run prints four `M2-MANIFEST` JSON records and twelve
`M2-FAULT` JSON records, followed by
`M2-OK manifests=4 faults=12 browser=real`. The browser runner validates
record completeness before printing that summary. The gate independently
validates its captured transcript with `dev/m2-evidence.mjs`. The validator
rejects missing, repeated or malformed records and summary-only output;
the browser probes own the semantic assertions behind their witnesses.

Run `zsh dev/gates.sh --leg browser` after the pinned build for development,
or `zsh dev/gates.sh` for the complete acceptance battery. All twelve
inherited legs, six M1 behaviors, hidden timing limits, shipping pipeline
phases, corpus pins and elaborator/GLUE line bounds remain in force.
The [build log](M2-BUILD-LOG.md) records measured results and remaining
limits. Indexed proofs remain M3 and general source-to-WasmGC emission
remains a separate backend obligation. The user commits staged changes.
