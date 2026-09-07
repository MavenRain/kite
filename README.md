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
  runtime/  kite_runtime: cluster.ml kubelet.ml and their interfaces
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
The browser host will execute its returned actions.  Browser execution,
IndexedDB transactions and the hidden-tab acceptance run remain in
M1-B and M1-C, described in [the M1 plan](dev/M1-PLAN.md).

## Use

Build with `zsh dev/pin-dune.sh dune build @all`.  Then run
`_build/default/bin/kite.exe check PATH.kite` to check a program or
`_build/default/bin/kite.exe build PATH.kite` to emit its lowered `.kir`
file.  `iface A.kite` writes `A.coi`;  `check --iface A.coi B.kite`
checks a consumer with no need to read the provider source.  The other
verbs are `fmt`, `roundtrip`, `version` and `run`.  Execution through
`run` arrives at M1.

## Gates

M1-A runs the seven M0 legs and the new RUNTIME leg, in this order,
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
- TRUSTED-LINES:  keeps the eight elaborator files at or below 2,400
  lines.
- DENOMINATORS:  verifies the frozen corpus and records the raw compiler
  time.
- FLOOR:  compares the full Kite pipeline per kloc with raw `ocamlopt`
  on the pinned floor corpus, using five runs on each side in one minute.

The frozen kanon denominators are 1,641.599 serial and 712.803 parallel;
they are printed and never gated.  Every build goes through
`dev/pin-dune.sh`, which pins
the `ctxcat-ocaml` opam switch, and through no other switch.

`python3 dev/runtime-mutations.py` verifies the native runtime tests
against six deliberately broken safety rules.  Each mutant must build
and fail its named semantic test.  All edits occur in disposable copies.

## Licence and author

MIT OR Apache-2.0, at your option.  See LICENSE-MIT and LICENSE-APACHE.
Author:  Onyeka Obi.

The user commits;  an agent never commits.
