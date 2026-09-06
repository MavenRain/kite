(* lib/ident.ml:  a name that a declaration binds (brief 3.2, D-A-3).
   One file is one module.  The type is a newtype over a string, so a
   name and a label never mix by accident. *)

type t = Ident of string

let of_string (s : string) : t = Ident s

let to_string (i : t) : string =
  match i with
  | Ident s -> s

let equal (a : t) (b : t) : bool = String.equal (to_string a) (to_string b)
