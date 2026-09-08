# M2-B source contracts and evaluator sessions

The existing manifest grammar accepts four concrete forms. Their capitalized
kind words distinguish them from the generic M0 descriptions, including the
existing lowercase `pod` and `service` examples. Generic descriptions retain
their checker and lowering behavior. Concrete descriptions survive executable
artifact emission and run through the existing checked IR evaluator.

```kite
let wanted = 1 + 1
manifest Workloads {
  Deployment web { replicas = wanted, bound = 3, tolerate_hidden = false },
  StatefulSet data { replicas = 1, bound = 2, tolerate_hidden = true },
  Service api { target = "web" },
  FreezeDrain shutdown { target = "data" }
}
```

Workloads require exactly `replicas`, `bound` and `tolerate_hidden`. Services
and drain bindings require exactly `target`. Missing, duplicate and extra
fields are refused before evaluation. Fields can contain checked expressions;
they evaluate once in declaration order using the current lexical environment.
Native `Manifest` constructors then validate field values, names, replica
counts and bounds. A workload bound is from zero through 64, and replicas are
from zero through that bound. Wrong field types and invalid numeric values
return explicit evaluator failures. Duplicate concrete names also fail.
Numeric validation happens at execution, including computed field values;
the source checker does not establish indexed replica or naming proofs.

`KiteSource.createSession(artifact, host)` returns an immutable session handle
with `token`, `start()`, `freeze(observation)` and `close()`. `start()` runs the
program once and returns `{ok: true, value, manifests}`. Manifest records use
the following browser contracts:

| Source form | Browser data |
| --- | --- |
| `Deployment` | `{kind: "deployment", name, replicas, bound, tolerateHidden}` |
| `StatefulSet` | `{kind: "stateful_set", name, replicas, bound, tolerateHidden}` |
| `Service` | `{kind: "service", name, target}` |
| `FreezeDrain` | `{kind: "drain", name, target}` |

The browser adapter gives each workload its own placement namespace. These
records describe desired state; producing them does not grant admission,
acquire a lease or acknowledge a durable transaction. The browser adapter
must perform live admission and verify its current leases and transaction
fences. Service and drain targets are resolved by that adapter.

A freeze declaration captures its lexical scope when startup reaches it:

```kite
import host_checkpoint : Str -> Unit cost 1 deadline 1000
let target = "data"
freeze { store } = host_checkpoint target
```

After startup, call `session.freeze({session: session.token, sequence: 1})`.
This executes the saved body directly, without replaying startup, manifests
or earlier host effects. A program with no freeze handler returns Unit.
Each accepted observation must carry the exact session token and a positive
safe integer sequence strictly larger than the last accepted sequence.
Startup and freeze cannot overlap, nor can two freeze invocations. A later
freeze after resume can execute the retained body under a newer observation.
The page lifecycle adapter owns the actual observation and refreshes runtime
tickets and admission observations on resume. The token and sequence checks
prevent stale calls; they do not constitute evidence of a browser freeze.
The workload adapter cancels incomplete startup on freeze or close. It cannot
resume that abandoned startup later and does not replay it automatically.

`close()` invalidates pending continuations and releases the captured session.
A late host reply cannot resume source work after close. The source driver
owns continuation consumption and session lifetime. The native bridge returns
immutable evaluator states and captures the freeze closure at completion;
it introduces no mutable OCaml session state. Host failure or timeout closes the source
session. Effects already submitted to the host still follow the host's
transaction completion and cancellation rules. Freeze remains best effort
and cannot promise a final checkpoint.

The workload adapter supplies the `host_checkpoint : Str -> Unit` import.
Its string argument names an installed StatefulSet. It asks that workload's
control host to checkpoint the current local tick state, returning Unit only
when the host reports success. Explicit host refusal becomes a source error.
The retained handler starts before workload drain is dispatched, but later
handler effects and outstanding writes may race with that drain. Repeating
the same frozen lifecycle returns the prior result without replaying the
handler. A failed worker termination retains its handle for close retries.

The existing `KiteSource.run(artifact, host)` and `KiteProgram.start(artifact)`
entry points retain their return shapes. They do not expose a retained session.
The four fixtures are in `test/source`; evaluator and compiled browser tests
cover data emission, malformed contracts, lexical freeze capture, startup
effect counts, concurrent or stale observations and late host continuations.
These tests establish source and bridge behavior. The M2 browser lifecycle
fault matrix remains a separate acceptance requirement.
