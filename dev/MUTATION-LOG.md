# kite mutation log

Every row runs on a copy of the repository under `$TMPDIR/kite-stageA`,
built through the copy's own `dev/pin-dune.sh`.  No repository file is
mutated.  `dev/gates.sh` takes its root from its own path, so the copy
gates itself.

## Stage A

| Id | Mutation | Command | Catching leg | Result |
| --- | --- | --- | --- | --- |
| SA-M1 | `surface/print.ml` swaps the first two fields of a printed record literal | `zsh COPY/dev/gates.sh --leg parse` | PARSE | KILLED |
| SA-M2 | `surface/lexer.ml` drops the nested-comment arm, so a comment ends at the first `*)` | `zsh COPY/dev/gates.sh --leg parse` | PARSE | KILLED |
| SA-M3 | one `.fmt` golden removed, `test/roundtrip/ops.fmt` | `zsh COPY/dev/gates.sh --leg parse` | PARSE | KILLED |
| SA-M4 | `surface/parser.ml` accepts `freeze { store , log }` | `zsh COPY/dev/gates.sh --leg parse` | PARSE | KILLED |

### Evidence, one printed line per row

- SA-M1:  `PARSE-FAIL .../test/roundtrip/record.kite the golden .fmt does
  not equal the print`, then `PARSE files=23 ok=21 fail=2` and
  `FAIL PARSE`.  The manifest fixture fails beside the record fixture,
  because a manifest entry prints its fields through the same reader.
- SA-M2:  `PARSE-FAIL .../test/roundtrip/comments.kite the parse failed:
  Parse 1:14-1:14 expected a declaration`, then
  `PARSE files=23 ok=22 fail=1` and `FAIL PARSE`.
- SA-M3:  `PARSE-FAIL .../test/roundtrip/ops.kite the golden .fmt does
  not exist`, then `PARSE files=23 ok=22 fail=1` and `FAIL PARSE`.  The
  missing golden is a failure and never a skip.
- SA-M4:  `PARSE-FAIL .../test/neg/parse-freeze.kite the parse was
  expected to fail and it did not`, then `PARSE files=23 ok=22 fail=1`
  and `FAIL PARSE`.

Four mutants, four killed, none survived.

## Stage A, judge rerun (2026-09-06)

The judge ran the four checks again on four fresh copies of the
repository under `$TMPDIR/kite-stageA/judge/mut-SA-Mn`, each copied
without `_build` and without `.git`, each built through the copy's own
`dev/pin-dune.sh`.  `dev/gates.sh` takes its root from its own path, so
each copy gates itself.  No repository file was mutated.  The commands
are the rows of `dev/run-stage-A.sh`, reached as
`zsh /Users/oobi/Documents/kite/dev/run-stage-A.sh --mut SA-Mn`.

| Id | Mutation | Command | Catching leg | Result |
| --- | --- | --- | --- | --- |
| SA-M1 | `surface/print.ml` swaps the first two fields of a printed record literal | `zsh COPY/dev/gates.sh --leg parse` | PARSE | KILLED |
| SA-M2 | `surface/lexer.ml` drops the nested-comment arm, so a comment ends at the first close bracket | `zsh COPY/dev/gates.sh --leg parse` | PARSE | KILLED |
| SA-M3 | one `.fmt` golden removed, `test/roundtrip/ops.fmt` | `zsh COPY/dev/gates.sh --leg parse` | PARSE | KILLED |
| SA-M4 | `surface/parser.ml` accepts a handler row that is not `{ store }`, so `freeze { store , log }` parses | `zsh COPY/dev/gates.sh --leg parse` | PARSE | KILLED |

### Evidence, the printed lines of this run

- SA-M1:  `MUT edit=APPLIED`, then `PARSE-FAIL .../record.kite the two
  parses differ`, `PARSE-FAIL .../record.kite the golden .fmt does not
  equal the print`, the same three lines for `manifest.kite`, then
  `PARSE files=23 ok=21 fail=2` and `FAIL PARSE`, exit 1.  The manifest
  fixture falls beside the record fixture, because a manifest entry
  prints its fields through the same reader.
- SA-M2:  `MUT edit=APPLIED`, then `PARSE-FAIL .../comments.kite the
  parse failed: Parse 1:14-1:14 expected a declaration`, then
  `PARSE files=23 ok=22 fail=1` and `FAIL PARSE`, exit 1.
- SA-M3:  `MUT goldens_before=20 goldens_after=19`, then `PARSE-FAIL
  .../ops.kite the golden .fmt does not exist`, then
  `PARSE files=23 ok=22 fail=1` and `FAIL PARSE`, exit 1.  A missing
  golden is a failure and never a skip.
- SA-M4:  `MUT edit=APPLIED`, then `PARSE-FAIL .../parse-freeze.kite the
  parse was expected to fail and it did not`, then
  `PARSE files=23 ok=22 fail=1` and `FAIL PARSE`, exit 1.

Four mutants, four killed, none survived.

## Stage B

Final command, run from the original checkout on 2026-09-06:
`zsh /Users/oobi/Documents/kite/dev/run-stage-B.sh --mutants`.
Every mutant uses its own copy below the runner's unique scratch
directory.  Each edit was verified and each mutant compiled at exit 0
with no compiler output.  Every intended test then failed at exit 1.
The runner exited 0 with `STAGE-B-MUTANTS failures=0` and removed its
scratch directory.  Six mutants were killed;  none survived.

| Id | Exact edit | Command in the copy | Killing input | Evidence | Result |
| --- | --- | --- | --- | --- | --- |
| SB-M1 | In infer.ml, replace `let* () = check_uses e s p in` with `let* () = Ok () in`. | `zsh dev/gates.sh --leg check` | `test/neg/check-affine.kite` | `CHECK-FAIL .../check-affine.kite the file checks clean and the golden names Affine`, then `FAIL CHECK`. | KILLED |
| SB-M2 | In unify.ml, replace `Types.RVar v -> v.rid = id` with `Types.RVar _v -> false`. | `zsh dev/gates.sh --leg check` | `test/regress.ml`, `row-occurs` | `REGRESS-FAIL row-occurs`, then `REGRESS tests=27 ok=26 fail=1` and `FAIL CHECK`. | KILLED |
| SB-M3 | In row.ml, replace the first-occurrence predicate with the last-occurrence scan below. | `zsh dev/gates.sh --leg check` | `test/pos/scoped.kite`, `through_fun` | `CHECK-FAIL .../scoped.kite the printed scheme differs from the golden`, with `through_fun` inferred as Str instead of Int, then `FAIL CHECK`. | KILLED |
| SB-M4 | In infer.ml, replace `let close = is_value v in` with `let close = true in`. | `zsh dev/gates.sh --leg check` | `test/pos/value-restriction.kite` | `CHECK-FAIL .../value-restriction.kite the printed scheme differs from the golden`, with nonval quantified instead of weak, then `FAIL CHECK`. | KILLED |
| SB-M5 | In iface.ml, replace the budget-row arm and its parse/append body with `\| () when String.equal (peek ts) "budget" -> Ok acc`. | `_build/default/test/iface.exe test/pos/budget-ok.kite` | `test/pos/budget-ok.kite` | `IFACE-FAIL .../budget-ok.kite the read interface differs`, then `IFACE files=1 ok=0 fail=1`. | KILLED |
| SB-M6 | Remove `examples/m0-spine.sha256`. | `zsh dev/gates.sh --leg floor` | Spine sidecar | `GATE-FAIL floor sidecar missing`, then `FAIL FLOOR`, with no `GATE-OK`. | KILLED |

SB-M3 replaces `let hit = same && seen = want in` with:

```ocaml
let rec later (tail : Types.row) : bool =
  match Subst.resolve_row st tail with
  | Types.REmpty -> false
  | Types.RVar _tail -> false
  | Types.RExt (next, _occ, _ty, more) ->
    Label.equal l next || later more in
let hit = same && seen >= want && not (later rest) in
```

The first attempt at SB-M3 only skipped the next occurrence.  Replacing
it with the actual last-occurrence behavior showed that the original
scoped fixture missed this defect.  The fixture now passes its duplicate
record through a selector function, and the final mutant changes that
result from Int to Str.  The parser corpus still contains 46 files.

The original positive row fixture also missed the direct row occurs
check.  SB-M2 therefore uses the explicit cyclic-row regression in
CHECK.  Its failure names the missed occurs check;  a compile error or
an unrelated test failure cannot count as a kill.
