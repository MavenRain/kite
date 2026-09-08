# kite

kite is a small strict language for a tab cluster:  row-polymorphic
records and variants, an at-most-once arrow bit over a resource, one
canonical printed form, and a declaration surface for protocols, roles,
imports with a cost and a deadline, freeze handlers and manifests.  M0
gives the front end and the checker, with no dependency outside the
OCaml standard library.  SPEC.md holds the surface syntax, the refusal
table of the forms that arrive at M1 to M4, and the error line form.

## Layout

```
kite/
  dune-project (lang dune 3.24) (name kite);  README.md SPEC.md
  LICENSE-MIT LICENSE-APACHE
  lib/  kite_core: ident.ml label.ml literal.ml types.ml row.ml kind.ml
        subst.ml unify.ml env.ml infer.ml usage.ml error.ml pp.ml
        iface.ml ir.ml lower.ml
  surface/  kite_surface: lexer.ml parser.ml ast.ml print.ml
  runtime/  cluster.ml kubelet.ml feed.ml service.ml volume.ml taint.ml manifest.ml
            and their interfaces; eval.ml artifact.ml
  bin/kite.ml  driver: check | build | iface | run | fmt | roundtrip | version
  test/  parse.exe  check.exe  iface.exe  regress.exe  cluster.exe  kubelet.exe
  dev/  gates.sh bench.sh denominators.sh denominators.json
        DENOMINATORS.sha256 house.sh pin-dune.sh trusted-lines.sh
        PROVENANCE.md M0-BUILD-LOG.md MUTATION-LOG.md CARRY.md
  examples/m0-spine.kite  the 1 kloc numerator corpus
```

Stage A delivered the front end:  lib/ident.ml, lib/label.ml,
lib/literal.ml, lib/error.ml with its Parse arm, surface/ast.ml declared
whole, surface/lexer.ml, surface/parser.ml, surface/print.ml and
test/parse.ml.  Stage B adds the checker, the use-count pass, the
interfaces and the driver.  A source file carries the extension `.kite`.

M1-A adds the native cluster control model.  `Kite_runtime.Cluster`
plans placements from lock and heartbeat observations and fences plans
by leader epoch.  `Kite_runtime.Kubelet` tracks local workers from spawn
through pod-lock acquisition and shutdown, including freeze and resume.
M1-B executes those actions in real browser Workers.  It adds an
IndexedDB sequence log with transactional epoch fencing, a leader
Worker and a two-tab host demonstration. M1-C adds checked source execution
and the six-behavior browser acceptance corpus, including the hidden-tab
timing gate, described in [the M1-C brief](dev/stage-M1-C-brief.md).

M2-A adds native models for committed feeds, named services, fenced volume
checkpoints, visibility taints and manifest admission. See
[the M2-A brief](dev/stage-M2-A-brief.md) for contracts and validation, and
[the M2 plan](dev/M2-PLAN.md) for the milestone acceptance matrix.
M2-B binds those models to browser transactions and source manifests.
[The M2-B brief](dev/stage-M2-B-brief.md) describes workload namespaces,
regular checkpoints, durable services and retained source freeze handlers.

After building, serve the repository with `python3 -m http.server 8000
--bind 127.0.0.1` and open `http://127.0.0.1:8000/browser/index.html`
in two tabs.  Apply a pod count to start the host-test Wasm payload.
The pods run the Stage 0 Wasm workload. The source acceptance runner below
drives the same production cluster host.

## Use

Build with `zsh dev/pin-dune.sh dune build @all`.  Then run
`_build/default/bin/kite.exe check PATH.kite` to check a program or
`_build/default/bin/kite.exe build PATH.kite` to emit its lowered `.kir`
file and an executable `PATH.kite.js` data artifact. `run PATH.kite`
executes its pure expressions with the native evaluator. Browser host
imports are handled by `KiteSource.run`, using the same evaluator compiled
with js_of_ocaml. On the demonstration page, `kite.load(KiteArtifact, host)`
retains the evaluator session and installs its concrete workload manifests.
The four source forms are `Deployment`, `StatefulSet`, `Service` and
`FreezeDrain`; see [the source contracts](dev/stage-M2-B-source-contract.md)
and `test/source/`. Their numeric bounds are validated at execution;
indexed proofs remain M3. `iface A.kite` writes `A.coi`; `check --iface A.coi B.kite`
checks a consumer with no need to read the provider source.  The other
verbs are `fmt`, `roundtrip` and `version`.

To run source against real browser tabs, build and execute the acceptance
corpus:

```
_build/default/bin/kite.exe build test/acceptance.kite
node dev/drive.mjs
```

This includes at least 306 seconds with both cluster tabs hidden.
`node dev/drive.mjs --quick` runs the other five behaviors for development.
General source-to-WasmGC emission remains later work.

To retain a complete browser package, run
`zsh dev/browser-pipeline.sh --output /tmp/kite-package test/source/deployment.kite`.
The destination must not exist. The builder emits both browser bundles
concurrently, checks both compiler results, and assembles the package.

## Gates

M2-B runs the seven M0 legs plus RUNTIME, DURABLE, SOURCE, BROWSER and ACCEPTANCE,
through one command,
`zsh dev/gates.sh`:

- BUILD:  `zsh dev/pin-dune.sh dune build @all` exits 0 and prints
  nothing.  A warning is an error, because every stanza carries
  `-warn-error +a`.
- HOUSE:  `zsh dev/house.sh` prints one OK line per leg and then
  HOUSE OK.  The legs are the house rules:  no exception, no wildcard
  arm and no partial accessor, no changeable state, no bool match and no
  loop keyword, no match on option or result, no bare division and no
  em-dash.
- PARSE:  for every fixture, `print(parse(s))` equals
  `print(parse(print(parse(s))))`.  This is the one measurable gate of
  M0 Stage A, retained for all 46 Stage B fixtures.
- CHECK:  compares the thirteen positive schemes and six refusal
  goldens, checks the spine, and runs semantic regressions for rows,
  value restriction, affine bindings and separate compilation.
- RUNTIME:  exercises placement, epoch fencing and worker lifecycle
  traces.  Run it alone with `zsh dev/gates.sh --leg runtime`.
- SOURCE: checks native evaluation, browser artifact execution, import
  contracts, concrete manifests, retained freeze sessions and explicit failures.
- BROWSER:  checks the GLUE boundary, asynchronous lifecycle races,
  actual nested Workers, source workloads, Web Locks and IndexedDB transactions in
  isolated Chrome.  Run it alone with `zsh dev/gates.sh --leg browser`.
- ACCEPTANCE: runs all six source-driven behaviors under Chrome, with
  pod work within 3 seconds and the leader's view within 5 seconds after
  a desired-count change in tabs hidden for more than five minutes.
- TRUSTED-LINES:  keeps the eight elaborator files at or below 2,400
  lines.
- DENOMINATORS:  verifies the frozen corpus and records the raw compiler
  time.
- FLOOR:  compares the Kite pipeline, including js_of_ocaml emission
  for both browser bridges (including the durable models and evaluator CPS), source artifact emission and browser asset
  assembly (with independent bundle emission overlapped), per kloc with raw `ocamlopt`
  on the pinned floor corpus, using five runs on each side in one minute.

The frozen kanon denominators are 1,641.599 serial and 712.803 parallel;
they are printed and never gated.  Every build goes through
`dev/pin-dune.sh`, which pins
the `ctxcat-ocaml` opam switch, and through no other switch.

`zsh dev/gates.sh --leg durable` checks the five M2 native suites. The full
battery includes this leg. `python3 dev/durable-mutations.py` checks their
safety oracles against buildable mutations in disposable copies.

`python3 dev/runtime-mutations.py` verifies the native runtime tests
against six deliberately broken safety rules.  Each mutant must build
and fail its named semantic test.  All edits occur in disposable copies.

`node dev/browser-test.mjs --hidden` adds the PR-2 probe after at least
305 seconds hidden.  See [the M1-B brief](dev/stage-M1-B-brief.md) for
the host boundary and PR-2 timing interpretation. The full M1-C gate is
`node dev/drive.mjs`.

`node dev/browser-test.mjs --pressure` adds a PR-1 diagnostic that records
memory-pressure injection and observed freeze/resume events separately from
deliberate page closure. It reports whether a discard actually occurred.
M2-C's complete twelve-fault browser matrix remains outstanding.

## Licence and author

MIT OR Apache-2.0, at your option.  See LICENSE-MIT and LICENSE-APACHE.
Author:  Onyeka Obi.

The user commits;  an agent never commits.
