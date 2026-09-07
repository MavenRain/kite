# kite, the M0 surface specification

Stage A of M0.  This document gives the tree, the lexical rules, the
grammar, the operator table, the refusal table, the canonical print form
and the error line form.  Stage A parses and prints;  it does not check
types and it does not count uses.  Stage B adds the checker.

Date:  2026-09-06.  Licence:  MIT OR Apache-2.0.  Author:  Onyeka Obi.

## 1 The tree

```
kite/
  dune-project  README.md  SPEC.md  LICENSE-MIT  LICENSE-APACHE
  lib/      ident.ml label.ml literal.ml error.ml
  surface/  ast.ml lexer.ml parser.ml print.ml
  test/     dune parse.ml roundtrip/ pos/ neg/
  dev/      gates.sh house.sh bench.sh denominators.sh
            denominators.json DENOMINATORS.sha256 trusted-lines.sh
            pin-dune.sh PROVENANCE.md CARRY.md
  examples/ m0-spine.kite
```

lib/ holds one module per file and no dependency on surface/.  surface/
holds the front end.  test/ holds one executable, parse.exe.  dev/ holds
the gate battery and its scripts.  The files that plan section 3 names
for Stage B, such as types.ml and infer.ml, are absent at Stage A;  an
empty file is a vacuous pass, so no file is stubbed.

## 2 The lexical rules

The lexer makes one pass over the source and returns a token list or a
Parse error.  Layout is not significant.

- Keywords:  let, rec, and, in, fun, match, with, if, then, else, true,
  false, import, cost, deadline, protocol, state, compensate, role, for,
  on, abort, Peer_lost, freeze, manifest, budget, Code, node, leader,
  registry, placement, heartbeat, pod, store, service, taint, drain,
  doorbell, volume, proof, port, fuel, cost_table and blob.
- Symbols:  `( ) { } [ ] < > | , . : = -> -1> ^ _ @ + - * / % == != <=
  >= && ||`.  The reader takes the longest symbol first, so `-1>` wins
  over `-` and `==` wins over `=`.
- A name starts with a lowercase letter or an underscore and then holds
  letters, digits, underscores and primes.  A name that starts with an
  uppercase letter is the same token class with its case kept.  A lone
  underscore is the symbol `_` and it is the wildcard pattern.
- An integer literal is decimal and unsigned.  Write a negative value as
  a subtraction, as in `0 - 5`.
- A string literal is double-quoted.  It holds the four escapes `\n`,
  `\t`, `\\` and `\"` and no other, and it holds no newline.
- A comment is `(* *)` and a comment nests, as in `(* a (* b *) c *)`.
  A comment with no end is a Parse error at the opening span.
- Every token carries a span.  A span is two 1-based positions, the
  first byte of the token and its last byte.

## 3 The grammar

The declaration level.

```
prog  ::= decl*
decl  ::= "let" name pat* "=" expr
        | "let" "rec" bind ("and" bind)*
        | "import" name ":" ty "cost" int "deadline" int
        | "@" "budget" "{" bfield ("," bfield)* "}" decl
        | "protocol" name "{" pstate* "}"
        | "role" name ":" name "{" clause ("," clause)* "}"
        | "freeze" "{" "store" "}" "=" expr
        | "manifest" name "{" entry ("," entry)* "}"
        | milestone_word name
bind  ::= name pat* "=" expr
```

The declaration parts.

```
bfield ::= label "=" int
pstate ::= "state" name "{" leg ("," leg)* "}" [ "compensate" expr ]
leg    ::= label ":" ty "->" name
clause ::= label name* "->" expr
         | "Peer_lost" "->" expr
         | "abort" "->" expr
entry  ::= word name "{" efield ("," efield)* "}"
efield ::= label "=" expr
```

An empty program is legal and it prints as the empty string.  A budget
annotation with no declaration after it is a Parse error.  A freeze
handler row other than `{ store }` is a Parse error that names the one
legal row.  An import with no `cost` word or with no `deadline` word is
a Parse error that names the missing word.

The expression level.

```
expr  ::= "fun" pat+ "->" expr
        | "let" pat "=" expr "in" expr
        | "let" "rec" bind ("and" bind)* "in" expr
        | "if" expr "then" expr "else" expr
        | "match" expr "with" ("|" pat "->" expr)+
        | binop_expr
app   ::= app atom | atom
atom  ::= lit | name | "(" expr ")" | "(" expr ":" ty ")" | "(" ")"
        | "{" [ efield ("," efield)* [ "|" expr ] ] "}"
        | "{" app "-" label "}" | atom "." label
        | "<" label [ "^" int ] expr ">"
```

The pattern level and the type level.

```
pat   ::= lit | name | "_"
        | "<" label [ "^" int ] pat ">"
        | "{" [ pfield ("," pfield)* [ "|" name ] ] "}"
pfield ::= label [ "^" int ] "=" pat
ty    ::= ty_atom "->" ty | ty_atom "-1>" ty | ty_atom
ty_atom ::= name | "(" ty ")" | "{" row "}" | "<" row ">"
        | "Code" "[" row "," ty "]"
row   ::= [ rfield ("," rfield)* ] [ "|" name ]
rfield ::= label ":" ty
```

`->` is right associative.  `-1>` sits at the same level and it carries
the at-most-once bit of A2.  A row field named `susp` is an ordinary
field, so the `susp` row entry of A3 parses with no special rule and it
prints back unchanged.

The bracket rules.  `<` opens a variant literal in expression-start
position alone;  after an atom it reads as the less-than operator, so a
variant literal in an argument position needs parentheses, as in
`f (< l x >)`.  Inside a variant payload the reader turns the greater-
than operator off, so `>` closes the literal and a comparison inside a
payload needs parentheses.  Inside braces, a closing brace first is the
empty record;  a label and then an equals sign starts the field list,
whose tail `| e` is a whole expression;  anything else is the
restriction form, whose leading expression is an application of atoms
alone, then `-`, a label and a closing brace.

A parameter pattern starts with a name, a `(`, a `{` or a `_`.  An
injection pattern is thus written in a match arm or in `let pat = e in
body` and not in a parameter list.  The checker prints `expected an
equals sign` for a declaration such as `let f < ok x > = x`, and
`expected a parameter` for a lambda such as `fun < ok x > -> x`.

## 4 The operator table

Level 1 binds least.  Application binds tighter than every operator,
and an atom binds tightest.

| Level | Operators | Association | Meaning |
| --- | --- | --- | --- |
| 1 | `\|\|` | right | disjunction |
| 2 | `&&` | right | conjunction |
| 3 | `== != < <= > >=` | none | comparison |
| 4 | `+ - ^` | left | addition, subtraction, concatenation |
| 5 | `* / %` | left | product, quotient, remainder |

A comparison does not chain.  `a < b < c` is a Parse error with the text
"the comparison does not chain".  `not` is a name and not an operator,
so `not e` is an application.

## 5 The refusal table

Each row is a form that the M0 scope excludes.  Stage A parses the form,
keeps its text and prints it back, so the surface is whole and a later
milestone adds the meaning.  Stage B prints the refusal text, because a
refusal needs the checker.  Every text names the declared NAME and the
milestone the form arrives at, and not the form word (D-B-4).  The
printed line adds the error name and the range, as in
`NotYet 1:1-1:1 the declaration x_a arrives at M2`.

| Form | Concrete syntax | Milestone | Refusal text |
| --- | --- | --- | --- |
| node | `node NAME` | M1 | the declaration NAME arrives at M1 |
| leader | `leader NAME` | M1 | the declaration NAME arrives at M1 |
| registry | `registry NAME` | M1 | the declaration NAME arrives at M1 |
| placement | `placement NAME` | M1 | the declaration NAME arrives at M1 |
| heartbeat | `heartbeat NAME` | M1 | the declaration NAME arrives at M1 |
| pod | `pod NAME` | M1 | the declaration NAME arrives at M1 |
| store | `store NAME` | M1 | the declaration NAME arrives at M1 |
| service | `service NAME` | M2 | the declaration NAME arrives at M2 |
| taint | `taint NAME` | M2 | the declaration NAME arrives at M2 |
| drain | `drain NAME` | M2 | the declaration NAME arrives at M2 |
| doorbell | `doorbell NAME` | M2 | the declaration NAME arrives at M2 |
| volume | `volume NAME` | M2 | the declaration NAME arrives at M2 |
| proof | `proof NAME` | M3 | the declaration NAME arrives at M3 |
| port | `port NAME` | M3 | the declaration NAME arrives at M3 |
| fuel | `fuel NAME` | M4 | the declaration NAME arrives at M4 |
| cost_table | `cost_table NAME` | M4 | the declaration NAME arrives at M4 |
| blob | `blob NAME` | M4 | the declaration NAME arrives at M4 |

The table holds seventeen data rows:  seven M1 forms, five M2 forms, two
M3 forms and three M4 forms.

## 6 The canonical print form

`Print.prog` gives one declaration per line, one newline between two
lines and one newline after the last line.  The empty program gives the
empty string.  One space separates two tokens.  A comment is dropped by
the lexer, so a printed program holds none.

- `let f x y = e` and `let rec f x = e and g y = e2` re-sugar the nested
  lambda into parameters.  `fun x y -> e` does the same.
- `let p = e in b`, `if c then a else b` and
  `match e with | p -> e1 | q -> e2`.
- `{ a = 1, b = 2 }`, `{ a = 1 | r }`, `{ r - l }` and `r.l`.
- `< l e >`, and `< l ^ k e >` only when k is above 0.  A variant
  literal takes parentheses as a function and as an argument, as in
  `f (< l x >)`, because after an atom `<` reads as the less-than
  operator, which is the bracket rule above.  It takes none as an
  operand of a binop,
  because every operand starts an expression.
- `(e : t)` for an annotation.
- A binop takes the fewest parentheses that the levels of section 4
  need.  A non-associative level parenthesizes both sides at its own
  level;  a right-associative level parenthesizes its left side at its
  own level;  a left-associative level parenthesizes its right side at
  its own level.
- `fun`, `let`, `match` and `if` take parentheses in a non-final
  position, that is as an argument, as a left operand or as a
  scrutinee.  A `match` takes them in an arm body too, because a bare
  nested match would take the arms of the outer match with it.
- A string prints with the four escapes of section 2.
- A declaration prints back in the concrete syntax of section 3, word
  for word, so `import f : int -> int cost 3 deadline 5` prints as it
  parses.  A list inside a declaration takes a comma between two
  members.

The printer is total.  It holds one arm for every constructor of
ast.ml and no wildcard arm, so a new arm of a later stage is a compile
error here.

The round-trip law of the PARSE gate:  for every fixture s,
`print(parse(s))` equals `print(parse(print(parse(s))))`.

## 7 The error line

An error prints as one line:

```
NAME L:C-L:C text
```

NAME is the error name, which is `Parse` at Stage A.  `L:C-L:C` is the
span, the line and the column of the first byte and then of the last
byte, both 1-based.  text is the message in ASD-STE100, such as
"expected a closing parenthesis".  A golden of a `parse-` twin under
test/neg/ holds the name and the span, which `test/parse.ml` compares as
the first two words of the line.  A golden of a `check-` twin holds the
error name and no other word, which `test/check.ml` compares against the
first word of the line.

## 8 The types

The internal grammar of the checker, from `lib/types.ml`.  A type
variable and a row variable live in two namespaces, so one never
unifies with the other.

```
type mult = Many | AtMostOnce
type tvar = { id : int;  level : int }
type tvar_row = { rid : int;  rlevel : int }
type t =
  | Var of tvar
  | Con of string
  | Arrow of t * mult * t
  | Record of row
  | Variant of row
  | Code of row * t
```

A row is scoped:  `RExt` carries the occurrence index of a label, so a
label may repeat.  Extension is `RExt`, restriction removes the FIRST
occurrence and selection reads the FIRST occurrence.

```
and row =
  | REmpty
  | RVar of tvar_row
  | RExt of Label.t * Label.occ * t * row
```

`Con` covers the four literal kinds of `lib/literal.ml`, that is `Int`,
`Str`, `Bool` and `Unit`, one name per kind and no fifth name.  `Many`
is the plain arrow `->` and `AtMostOnce` is the `-1>` arrow of A2.  The
kinds are two and nothing else has a kind at M0.

```
type t =
  | Type
  | Row
```

A binding rides in `Subst.t`, an immutable map from an id to a type,
and every function that may bind returns the new store.  The store is
never a `ref`, because the elaborator holds no mutable cell.

## 9 The checks

One row per error name.  The first word of an error line is the name,
so a golden under `test/neg/` names the error and no other.

| name | what it catches | the twin that shows it |
| --- | --- | --- |
| `Parse` | a source the grammar of section 3 refuses | `test/neg/parse-paren.kite` |
| `Unbound` | a name with no binding | none at M0 |
| `Mismatch` | two types that do not unify | none at M0 |
| `OccursType` | a type variable that occurs in the type it would bind | `SB-M2` |
| `OccursRow` | a row variable that occurs in the row it would bind | `SB-M2` |
| `RowMissing` | a label absent from a closed row | none at M0 |
| `RowDuplicate` | a record literal with a repeated label at one occurrence index | none at M0 |
| `KindMismatch` | a type variable met where a row variable is needed | none at M0 |
| `Affine` | an at most once binder used more than once | `test/neg/check-affine.kite` |
| `Capture` | a `Many` arrow that captures an at most once value | `test/neg/check-capture.kite` |
| `Compensation` | a protocol state with no compensation | `test/neg/check-compensate.kite` |
| `PeerLost` | a role with no `Peer_lost` leg | `test/neg/check-peer-lost.kite` |
| `Budget` | an obligation over its printed budget | `test/neg/check-budget.kite` |
| `IfaceMismatch` | an import whose declared type differs from the exported scheme | `SB-G11` |
| `NotYet` | an M1 to M4 form, with the milestone in its text | `test/neg/milestones.kite` |

Fifteen names and no sixteenth.  Every function over `Error.t` holds an
arm for each name and no wildcard arm, so a new name is a compile error
at every site.

## 10 The .coi format

An interface file is TEXT, ASCII, one record per line, so a consumer
never re-reads the source.  Every field is a single token with no
space, so the reader splits a line on one space.  The grammar:

```
coi 1
source-sha256 HEX64
module NAME
val NAME : SCHEME usage=U
budget NAME atoms=A constraints=C
import NAME cost=K deadline_ms=D
end
```

The header is two lines:  `coi 1`, where 1 is the format version, then
`source-sha256` with the sha256 of the source the interface was written
from.  `module` names the source basename without its extension, and
every space of that basename becomes an underscore, because every field
is one token.  Then
one `val` line per exported top level binding, in declaration order,
with the scheme printed by `lib/pp.ml` and the usage `Zero`, `Once` or
`Many` of `lib/usage.ml`.  Then one `budget` line per budget
annotation, so every budget prints beside the obligation it discharged.
Then one `import` line per import declaration, with the cost index and
the per call deadline in whole milliseconds.  The last line is `end`.

The worked example is `test/pos/import-iface.coi`, the interface of
`test/pos/import-iface.kite`:

```
coi 1
source-sha256 c71230d739ebc7c9d40144df3e60c3d39f02058b2b0a6b5be36203a941be07e6
module import-iface
val fetch : vars=0 rvars=0 ( Int -> Str ) usage=Once
val text : vars=0 rvars=0 Str usage=Zero
import fetch cost=3 deadline_ms=5
end
```

`read (write i)` equals `i` for every interface the checker builds.  A
malformed line is the error `IfaceMismatch` and never an exception.

## 11 The driver

`bin/kite.exe` holds seven verbs.  One row per verb, with its printed
line and its exit code.

| verb | printed line | exit |
| --- | --- | --- |
| `check FILE...` | `CHECK-OK files=N`, or one error line per failure | 0, or 1 |
| `build FILE` | `BUILD-OK file=PATH ir=PATH bytes=N` | 0, or 1 |
| `iface FILE` | `IFACE-OK file=PATH exports=N` | 0 |
| `run` | `run arrives at M1` | 2 |
| `fmt FILE` | the canonical form of `surface/print.ml` | 0 |
| `roundtrip FILE` | `ROUNDTRIP-OK file=PATH` or `ROUNDTRIP-FAIL file=PATH` | 0, or 1 |
| `version` | `kite 0.1.0 ocaml 5.3.0 dune 3.24.0` | 0 |

`check` takes the repeatable option `--iface PATH`, which loads a `.coi`
interface:  an import whose name matches an exported binding of a loaded
interface is checked against that exported scheme, and a difference is
`IfaceMismatch`.  That option is the whole separate compilation edge,
and it reads no source of the other module.

`build` is parse, check, lower and emit and nothing else at M0.  It
writes the lowered IR beside the source with the extension `.kir`, so
`examples/m0-spine.kite` emits `examples/m0-spine.kir`.  A `.kir` file
is build output:  `.gitignore` holds the row `*.kir`, so it is never
tracked and never left in the porcelain.

The `run` verb runs NOTHING.  The machine arrives at M1.

No verb and an unknown verb both print the seven verb names and exit 2,
so an empty file list can never read as a pass.

A path that does not read, that is a missing path and a directory, is
the error line `the file PATH does not read` and exit 1.  An I/O failure
that no total test can see, as a file with no read bit or an output
directory with no write bit, prints the failure text and exits 2, which
is the code D-B-16 gives to a verb that cannot run.
