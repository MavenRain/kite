(* lib/kind.ml:  the two kinds of M0 (brief 3.1, D-B-4).  A type has the
   kind Type and a row has the kind Row, and nothing else has a kind at
   M0.  A type variable met where a row variable is needed is the error
   KindMismatch of brief 3.8, and that message names the kind, so the
   file holds the type and two total helpers over it and no third form. *)

type t =
  | Type
  | Row

let to_string (k : t) : string =
  match k with
  | Type -> "Type"
  | Row -> "Row"

let equal (a : t) (b : t) : bool =
  match (a, b) with
  | (Type, Type) -> true
  | (Type, Row) -> false
  | (Row, Type) -> false
  | (Row, Row) -> true
