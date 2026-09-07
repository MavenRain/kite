(* lib/error.ml:  the M0 error value (brief 3.2 of Stage A, D-A-3;  grown
   at Stage B by brief 3.8, D-B-12).
   Stage A held the Parse arm alone, because a parse was the only pass
   that existed.  Stage B adds fourteen arms and the set is CLOSED at
   fifteen names:  a sixteenth name is a halt (HALT-KITE-B-7).

   A position is 1-based on the line and on the column.  to_line prints
   the error name first, the span second and the text last:
     Parse 3:5-3:9 expected a closing parenthesis
   The FIRST WORD of the line is therefore the arm name, and that word is
   what a negative twin golden holds (brief 3.14).

   The surface tree of surface/ast.ml carries no span, so every arm the
   checker builds takes the span nowhere, which is 1:1-1:1.  The name and
   the text carry the report (D-B-32). *)

type pos = { line : int;  col : int }

type span = { lo : pos;  hi : pos }

type t =
  | Parse of span * string
  | Unbound of span * string
  | Mismatch of span * string
  | OccursType of span * string
  | OccursRow of span * string
  | RowMissing of span * string
  | RowDuplicate of span * string
  | KindMismatch of span * string
  | Affine of span * string
  | Capture of span * string
  | Compensation of span * string
  | PeerLost of span * string
  | Budget of span * string
  | IfaceMismatch of span * string
  | NotYet of span * string

let pos (line : int) (col : int) : pos = { line;  col }

let span (lo : pos) (hi : pos) : span = { lo;  hi }

let point (p : pos) : span = { lo = p;  hi = p }

(* The span of a checker error.  The elaborated tree holds no position,
   so the report leads with the name and the text (D-B-32). *)
let nowhere : span = point (pos 1 1)

let name (e : t) : string =
  match e with
  | Parse (_, _) -> "Parse"
  | Unbound (_, _) -> "Unbound"
  | Mismatch (_, _) -> "Mismatch"
  | OccursType (_, _) -> "OccursType"
  | OccursRow (_, _) -> "OccursRow"
  | RowMissing (_, _) -> "RowMissing"
  | RowDuplicate (_, _) -> "RowDuplicate"
  | KindMismatch (_, _) -> "KindMismatch"
  | Affine (_, _) -> "Affine"
  | Capture (_, _) -> "Capture"
  | Compensation (_, _) -> "Compensation"
  | PeerLost (_, _) -> "PeerLost"
  | Budget (_, _) -> "Budget"
  | IfaceMismatch (_, _) -> "IfaceMismatch"
  | NotYet (_, _) -> "NotYet"

let span_of (e : t) : span =
  match e with
  | Parse (s, _) -> s
  | Unbound (s, _) -> s
  | Mismatch (s, _) -> s
  | OccursType (s, _) -> s
  | OccursRow (s, _) -> s
  | RowMissing (s, _) -> s
  | RowDuplicate (s, _) -> s
  | KindMismatch (s, _) -> s
  | Affine (s, _) -> s
  | Capture (s, _) -> s
  | Compensation (s, _) -> s
  | PeerLost (s, _) -> s
  | Budget (s, _) -> s
  | IfaceMismatch (s, _) -> s
  | NotYet (s, _) -> s

let text_of (e : t) : string =
  match e with
  | Parse (_, t) -> t
  | Unbound (_, t) -> t
  | Mismatch (_, t) -> t
  | OccursType (_, t) -> t
  | OccursRow (_, t) -> t
  | RowMissing (_, t) -> t
  | RowDuplicate (_, t) -> t
  | KindMismatch (_, t) -> t
  | Affine (_, t) -> t
  | Capture (_, t) -> t
  | Compensation (_, t) -> t
  | PeerLost (_, t) -> t
  | Budget (_, t) -> t
  | IfaceMismatch (_, t) -> t
  | NotYet (_, t) -> t

let pos_to_string (p : pos) : string =
  String.concat ":" [ string_of_int p.line;  string_of_int p.col ]

let span_to_string (s : span) : string =
  String.concat "-" [ pos_to_string s.lo;  pos_to_string s.hi ]

let to_line (e : t) : string =
  String.concat " " [ name e;  span_to_string (span_of e);  text_of e ]

(* --- the constructors, one per name -------------------------------- *)

let parse (s : span) (text : string) : t = Parse (s, text)

let unbound (text : string) : t = Unbound (nowhere, text)

let mismatch (text : string) : t = Mismatch (nowhere, text)

let occurs_type (text : string) : t = OccursType (nowhere, text)

let occurs_row (text : string) : t = OccursRow (nowhere, text)

let row_missing (text : string) : t = RowMissing (nowhere, text)

let row_duplicate (text : string) : t = RowDuplicate (nowhere, text)

let kind_mismatch (text : string) : t = KindMismatch (nowhere, text)

let affine (text : string) : t = Affine (nowhere, text)

let capture (text : string) : t = Capture (nowhere, text)

let compensation (text : string) : t = Compensation (nowhere, text)

let peer_lost (text : string) : t = PeerLost (nowhere, text)

let budget (text : string) : t = Budget (nowhere, text)

let iface_mismatch (text : string) : t = IfaceMismatch (nowhere, text)

let not_yet (text : string) : t = NotYet (nowhere, text)
