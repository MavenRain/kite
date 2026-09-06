(* lib/literal.ml:  the four literal kinds of M0 (brief 3.2, D-A-3).
   An integer literal is unsigned, so a negative value is written as a
   subtraction, as in 0 - 5 (D-A-6). *)

type t =
  | Int of int
  | Str of string
  | Bool of bool
  | Unit

let equal (a : t) (b : t) : bool =
  match (a, b) with
  | (Int x, Int y) -> x = y
  | (Int _, Str _) -> false
  | (Int _, Bool _) -> false
  | (Int _, Unit) -> false
  | (Str x, Str y) -> String.equal x y
  | (Str _, Int _) -> false
  | (Str _, Bool _) -> false
  | (Str _, Unit) -> false
  | (Bool x, Bool y) -> Bool.equal x y
  | (Bool _, Int _) -> false
  | (Bool _, Str _) -> false
  | (Bool _, Unit) -> false
  | (Unit, Unit) -> true
  | (Unit, Int _) -> false
  | (Unit, Str _) -> false
  | (Unit, Bool _) -> false
