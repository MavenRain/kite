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
refusal needs the checker.  Every text names the milestone the form
arrives at.

| Form | Concrete syntax | Milestone | Refusal text |
| --- | --- | --- | --- |
| node | `node NAME` | M1 | the node declaration is not part of M0;  it arrives at M1 |
| leader | `leader NAME` | M1 | the leader declaration is not part of M0;  it arrives at M1 |
| registry | `registry NAME` | M1 | the registry declaration is not part of M0;  it arrives at M1 |
| placement | `placement NAME` | M1 | the placement declaration is not part of M0;  it arrives at M1 |
| heartbeat | `heartbeat NAME` | M1 | the heartbeat declaration is not part of M0;  it arrives at M1 |
| pod | `pod NAME` | M1 | the pod declaration is not part of M0;  it arrives at M1 |
| store | `store NAME` | M1 | the store declaration is not part of M0;  it arrives at M1 |
| service | `service NAME` | M2 | the service declaration is not part of M0;  it arrives at M2 |
| taint | `taint NAME` | M2 | the taint declaration is not part of M0;  it arrives at M2 |
| drain | `drain NAME` | M2 | the drain declaration is not part of M0;  it arrives at M2 |
| doorbell | `doorbell NAME` | M2 | the doorbell declaration is not part of M0;  it arrives at M2 |
| volume | `volume NAME` | M2 | the volume declaration is not part of M0;  it arrives at M2 |
| proof | `proof NAME` | M3 | the proof declaration is not part of M0;  it arrives at M3 |
| port | `port NAME` | M3 | the port declaration is not part of M0;  it arrives at M3 |
| fuel | `fuel NAME` | M4 | the fuel declaration is not part of M0;  it arrives at M4 |
| cost_table | `cost_table NAME` | M4 | the cost_table declaration is not part of M0;  it arrives at M4 |
| blob | `blob NAME` | M4 | the blob declaration is not part of M0;  it arrives at M4 |

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
"expected a closing parenthesis".  A golden under test/neg/ holds the
first two words of this line, so its first word is `Parse`.
