# kite carries

What kite takes from a sibling tree, and when.  A carry is ADAPTED by
hand with a row in dev/PROVENANCE.md, and it is never vendored.  Every
sibling tree named here is read only (M0-PLAN.md:151).

## Carried at M0

- The gate harness shape from BRISK, /Users/oobi/Documents/brisk:
  `dev/gates.sh`, `dev/house.sh`, `dev/bench.sh`, `dev/denominators.sh`,
  `dev/pin-dune.sh` and `dev/trusted-lines.sh`.  See dev/PROVENANCE.md
  for the row of each file.
- The two licence files and the `.gitignore` from KANON,
  /Users/oobi/Documents/kanon.
- The frozen kanon denominators 1,641.599 serial and 712.803 parallel,
  quoted as line 2 of a gate run and never gated (M0-PLAN.md:76 and
  :108).
- The denominator pin, /Users/oobi/Documents/affine-lang-tot-pin at
  6d0d48d, read and never built in place.

## NOT carried at M0:  the M1 carries

These two shells are an M1 carry and not an M0 carry
(/Users/oobi/Documents/tab-cluster-lang-dossier-host.md:122-126).  No M0
file names them, and no browser code exists at M0 (M0-PLAN.md:7).

- `Idb`, the IndexedDB shell of
  /Users/oobi/Documents/ocaml-tea/lib/tea_client_run/idb.ml (149 lines)
  with its interface idb.mli (14 lines).  It arrives at M1 with the
  store form, and it lands inside the audited GLUE module, which is the
  only module that may name `indexedDB` (M0-PLAN.md:137).
- `Tab_lock`, the writer-lock election shell of
  /Users/oobi/Documents/ocaml-tea/lib/tea_client_run/tab_lock.ml (81
  lines) with its interface tab_lock.mli (12 lines).  It arrives at M1
  with the leader form, and it lands inside the same audited GLUE
  module, which is the only module that may name `navigator.locks`.

## Never carried

- No M0 code comes from /Users/oobi/Documents/tab-cluster-spike.  Its
  RESULTS.md is read-only evidence and nothing else (M0-PLAN.md:78).
- No line of the kite front end comes from a sibling tree.  The grammar,
  the tree, the lexer and the printer are a rewrite.
