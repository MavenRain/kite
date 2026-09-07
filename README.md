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
  bin/kite.ml  driver: check | build | iface | run | fmt | roundtrip | version
  test/  parse.exe  check.exe  iface.exe  regress.exe
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

## Use

Build with `zsh dev/pin-dune.sh dune build @all`.  Then run
`_build/default/bin/kite.exe check PATH.kite` to check a program or
`_build/default/bin/kite.exe build PATH.kite` to emit its lowered `.kir`
file.  `iface A.kite` writes `A.coi`;  `check --iface A.coi B.kite`
checks a consumer with no need to read the provider source.  The other
verbs are `fmt`, `roundtrip`, `version` and `run`.  Execution through
`run` arrives at M1.

## Gates

Stage B runs seven legs, in this order, through one command,
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

## Licence and author

MIT OR Apache-2.0, at your option.  See LICENSE-MIT and LICENSE-APACHE.
Author:  Onyeka Obi.

The user commits;  an agent never commits.
