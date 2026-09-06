(* lib/error.ml:  the M0 error value (brief 3.2, D-A-3).
   Stage A holds the Parse arm alone, because a parse is the only pass
   that exists.  Stage B adds the other arms, and the exhaustive-match
   rule then grows every function over t.

   A position is 1-based on the line and on the column.  to_line prints
   the error name first, the span second and the text last:
     Parse 3:5-3:9 expected a closing parenthesis *)

type pos = { line : int;  col : int }

type span = { lo : pos;  hi : pos }

type t = Parse of span * string

let pos (line : int) (col : int) : pos = { line;  col }

let span (lo : pos) (hi : pos) : span = { lo;  hi }

let point (p : pos) : span = { lo = p;  hi = p }

let name (e : t) : string =
  match e with
  | Parse (_, _) -> "Parse"

let span_of (e : t) : span =
  match e with
  | Parse (s, _) -> s

let text_of (e : t) : string =
  match e with
  | Parse (_, t) -> t

let pos_to_string (p : pos) : string =
  String.concat ":" [ string_of_int p.line;  string_of_int p.col ]

let span_to_string (s : span) : string =
  String.concat "-" [ pos_to_string s.lo;  pos_to_string s.hi ]

let to_line (e : t) : string =
  String.concat " " [ name e;  span_to_string (span_of e);  text_of e ]

let parse (s : span) (text : string) : t = Parse (s, text)
