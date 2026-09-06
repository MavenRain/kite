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
