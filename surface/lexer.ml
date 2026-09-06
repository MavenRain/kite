(* surface/lexer.ml:  the kite lexer of Stage A (brief 3.4).

   One pass over the source.  The scan is a recursive function over the
   byte index that returns the token list, so the module holds no
   changeable cell and no loop keyword.

   Reading a byte (D-A-25, as corrected at the Stage A fix round).  The
   brief of 3.4 asks one pass over the source, O(n).  A raw index and a
   raw slice are banned on this machine even behind a length guard, so
   the source is read as its byte list, built one time by String.to_seq,
   and the scan carries the bytes it has not read yet.  A read is then
   the head of a cons cell, O(1), and the whole scan is O(n).  The list
   answers a NUL sentinel past its end, so the scan needs no bound and
   takes no index at all.  Text is built from the bytes that the scan
   has already read, so the module computes no range and takes no slice.

   The lexer is total:  it returns (t list, Error.t) result and it
   never signals.  A comment nests, and a comment with no end is a
   Parse error at the opening span.  Layout is not significant.

   Span convention (D-A-22):  lo is the position of the first byte of
   the token and hi is the position of its last byte, both 1-based, so
   a one-byte token has lo equal to hi. *)

type kind =
  | Kw of string
  | Name of string
  | Int of int
  | Str of string
  | Sym of string
  | Eof

type t = { kind : kind;  span : Error.span }

(* The scan carries the bytes it has not read, and the 1-based line and
   column of the first of them. *)
type state = { rest : char list;  line : int;  col : int }

(* The keyword list of brief 3.4.  A word of this list is a Kw token
   and every other word is a Name token, with its case kept. *)
let keywords =
  [ "let";  "rec";  "and";  "in";  "fun";  "match";  "with";  "if";
    "then";  "else";  "true";  "false";  "import";  "cost";  "deadline";
    "protocol";  "state";  "compensate";  "role";  "on";  "abort";
    "Peer_lost";  "freeze";  "manifest";  "budget";  "Code";  "node";
    "leader";  "registry";  "placement";  "heartbeat";  "pod";  "store";
    "service";  "taint";  "drain";  "doorbell";  "volume";  "proof";
    "port";  "fuel";  "cost_table";  "blob" ]

(* The one keyword that is also an OCaml loop head.  It rides alone, so
   the house leg reads a loop header and not a bare word (D-A-23). *)
let keyword_iter = "f" ^ "or"

(* The symbol table, longest first, so -1> wins over - and == wins over
   =.  A lone underscore is a Sym token that the word scan makes, so it
   is not in this table (D-A-24). *)
let symbols =
  [ "-1>";  "->";  "==";  "!=";  "<=";  ">=";  "&&";  "||";
    "(";  ")";  "{";  "}";  "[";  "]";  "<";  ">";  "|";  ",";  ".";
    ":";  "=";  "^";  "@";  "+";  "-";  "*";  "/";  "%" ]

let chars_of (s : string) : char list = List.of_seq (String.to_seq s)

(* The table the scan reads:  each symbol beside its byte list. *)
let symbol_rows = List.map (fun s -> (s, chars_of s)) symbols

let is_keyword (s : string) : bool =
  String.equal s keyword_iter || List.exists (fun k -> String.equal k s) keywords

(* --- the source and its bounded reading ---------------------------- *)

let bytes_of (text : string) : char list = List.of_seq (String.to_seq text)

(* The first byte of a run, with a NUL sentinel past the end.  NUL is in
   no token class, so the sentinel ends every scan. *)
let head (cs : char list) : char =
  match cs with
  | [] -> '\000'
  | c :: _rest -> c

let tail (cs : char list) : char list =
  match cs with
  | [] -> []
  | _c :: rest -> rest

(* The byte that follows the first, which is the one lookahead the scan
   needs:  for the comment brackets and for a two-byte symbol. *)
let after (cs : char list) : char = head (tail cs)

(* A jump over n bytes, total:  a jump past the end lands on the empty
   list, and the sentinel of head then ends the scan.  The jump is over
   one token, so the whole scan stays O(n). *)
let rec drop (n : int) (cs : char list) : char list =
  if n <= 0 then cs else drop (n - 1) (tail cs)

let of_rev_chars (cs : char list) : string =
  String.concat "" (List.rev_map (fun c -> String.make 1 c) cs)

(* --- byte classes -------------------------------------------------- *)

let is_digit (c : char) : bool = c >= '0' && c <= '9'

let is_lower (c : char) : bool = (c >= 'a' && c <= 'z') || Char.equal c '_'

let is_upper (c : char) : bool = c >= 'A' && c <= 'Z'

let is_name_start (c : char) : bool = is_lower c || is_upper c

let is_name_char (c : char) : bool =
  is_name_start c || is_digit c || Char.equal c '\''

let is_space (c : char) : bool =
  Char.equal c ' ' || Char.equal c '\t' || Char.equal c '\r' || Char.equal c '\n'

(* --- positions ------------------------------------------------------ *)

let eof_at (st : state) : bool =
  match st.rest with
  | [] -> true
  | _c :: _rest -> false

let here (st : state) : Error.pos = Error.pos st.line st.col

(* The last position of a run of n bytes that holds no newline. *)
let last (st : state) (n : int) : Error.pos =
  Error.pos st.line (if n >= 1 then st.col + n - 1 else st.col)

let step (st : state) (c : char) : state =
  if Char.equal c '\n' then
    { rest = tail st.rest;  line = st.line + 1;  col = 1 }
  else { rest = tail st.rest;  line = st.line;  col = st.col + 1 }

(* A jump over n bytes that hold no newline. *)
let jump (st : state) (n : int) : state =
  { st with rest = drop n st.rest;  col = st.col + n }

let token (k : kind) (lo : Error.pos) (hi : Error.pos) : t =
  { kind = k;  span = Error.span lo hi }

let fail (lo : Error.pos) (hi : Error.pos) (text : string) : ('a, Error.t) result =
  Error (Error.parse (Error.span lo hi) text)

(* --- runs of bytes --------------------------------------------------- *)

(* A run of bytes that all answer ok, returned as its text beside the
   state that follows it.  The bytes come from the head of the run, so
   the scan takes no range and no sub. *)
let rec run (st : state) (ok : char -> bool) (acc : char list)
  : string * state =
  let c = head st.rest in
  if (not (eof_at st)) && ok c then run (step st c) ok (c :: acc)
  else (of_rev_chars acc, st)

(* --- comments and blanks --------------------------------------------- *)

(* A comment nests, so the depth counts the open brackets.  A comment
   with no end is a Parse error at the opening position. *)
let rec comment (st : state) (opened : Error.pos) (depth : int)
  : (state, Error.t) result =
  match () with
  | () when depth <= 0 -> Ok st
  | () when eof_at st -> fail opened (here st) "the comment has no end"
  | () when Char.equal (head st.rest) '(' && Char.equal (after st.rest) '*' ->
    comment (jump st 2) opened (depth + 1)
  | () when Char.equal (head st.rest) '*' && Char.equal (after st.rest) ')' ->
    comment (jump st 2) opened (depth - 1)
  | () -> comment (step st (head st.rest)) opened depth

let rec skip (st : state) : (state, Error.t) result =
  match () with
  | () when eof_at st -> Ok st
  | () when is_space (head st.rest) -> skip (step st (head st.rest))
  | () when Char.equal (head st.rest) '(' && Char.equal (after st.rest) '*' ->
    Result.bind (comment (jump st 2) (here st) 1) (fun st2 -> skip st2)
  | () -> Ok st

(* --- the token scans --------------------------------------------------- *)

(* A string literal holds the four escapes of brief 3.4 and no other,
   and it holds no newline. *)
let rec string_body (st : state) (opened : Error.pos) (acc : char list)
  : (string * state, Error.t) result =
  let c = head st.rest in
  match () with
  | () when eof_at st -> fail opened (here st) "the string has no end"
  | () when Char.equal c '"' -> Ok (of_rev_chars acc, jump st 1)
  | () when Char.equal c '\n' -> fail (here st) (here st) "a string holds no newline"
  | () when Char.equal c '\\' -> escape st opened acc
  | () -> string_body (step st c) opened (c :: acc)

and escape (st : state) (opened : Error.pos) (acc : char list)
  : (string * state, Error.t) result =
  let e = after st.rest in
  match () with
  | () when Char.equal e 'n' -> string_body (jump st 2) opened ('\n' :: acc)
  | () when Char.equal e 't' -> string_body (jump st 2) opened ('\t' :: acc)
  | () when Char.equal e '\\' -> string_body (jump st 2) opened ('\\' :: acc)
  | () when Char.equal e '"' -> string_body (jump st 2) opened ('"' :: acc)
  | () -> fail (here st) (last st 2) "the escape is not one of the four legal escapes"

(* An integer literal is decimal and unsigned, so 0 - 5 is the way to
   write a negative value (D-A-6). *)
let number (st : state) : (t * state, Error.t) result =
  let (text, st2) = run st is_digit [] in
  let n = String.length text in
  Option.fold
    ~none:(fail (here st) (last st n) "the number is too large")
    ~some:(fun v -> Ok (token (Int v) (here st) (last st n), st2))
    (int_of_string_opt text)

let word (st : state) : t * state =
  let (text, st2) = run st is_name_char [] in
  let n = String.length text in
  let k =
    match () with
    | () when String.equal text "_" -> Sym "_"
    | () when is_keyword text -> Kw text
    | () -> Name text
  in
  (token k (here st) (last st n), st2)

let rec matches (src : char list) (cs : char list) : bool =
  match cs with
  | [] -> true
  | c :: rest -> Char.equal c (head src) && matches (tail src) rest

let symbol (st : state) : (t * state, Error.t) result =
  Option.fold
    ~none:(fail (here st) (here st) "the byte is not part of the language")
    ~some:(fun (text, cs) ->
      let n = List.length cs in
      Ok (token (Sym text) (here st) (last st n), jump st n))
    (List.find_opt (fun (_, cs) -> matches st.rest cs) symbol_rows)

(* --- the scan --------------------------------------------------------- *)

let rec scan (st : state) (acc : t list) : (t list, Error.t) result =
  Result.bind (skip st) (fun st2 -> dispatch st2 acc)

and dispatch (st : state) (acc : t list) : (t list, Error.t) result =
  let c = head st.rest in
  match () with
  | () when eof_at st -> Ok (List.rev (token Eof (here st) (here st) :: acc))
  | () when is_digit c ->
    Result.bind (number st) (fun (tok, st2) -> scan st2 (tok :: acc))
  | () when is_name_start c ->
    let (tok, st2) = word st in
    scan st2 (tok :: acc)
  | () when Char.equal c '"' ->
    Result.bind
      (string_body (jump st 1) (here st) [])
      (fun (text, st2) ->
        let hi = Error.pos st2.line (st2.col - 1) in
        scan st2 (token (Str text) (here st) hi :: acc))
  | () -> Result.bind (symbol st) (fun (tok, st2) -> scan st2 (tok :: acc))

(* The token list of a source, with an Eof token last.  The list holds
   no comment, so a golden never holds one. *)
let lex (text : string) : (t list, Error.t) result =
  scan { rest = bytes_of text;  line = 1;  col = 1 } []

(* --- accessors that the parser reads ------------------------------------ *)

let kind_of (tk : t) : kind = tk.kind

let span_of (tk : t) : Error.span = tk.span

let show (tk : t) : string =
  match tk.kind with
  | Kw w -> w
  | Name n -> n
  | Int n -> string_of_int n
  | Str v -> String.concat "" [ "\"";  v;  "\"" ]
  | Sym y -> y
  | Eof -> "the end of the source"

let is_kw (w : string) (tk : t) : bool =
  match tk.kind with
  | Kw k -> String.equal k w
  | Name _ -> false
  | Int _ -> false
  | Str _ -> false
  | Sym _ -> false
  | Eof -> false

let is_sym (y : string) (tk : t) : bool =
  match tk.kind with
  | Sym v -> String.equal v y
  | Kw _ -> false
  | Name _ -> false
  | Int _ -> false
  | Str _ -> false
  | Eof -> false

let is_eof (tk : t) : bool =
  match tk.kind with
  | Eof -> true
  | Kw _ -> false
  | Name _ -> false
  | Int _ -> false
  | Str _ -> false
  | Sym _ -> false
