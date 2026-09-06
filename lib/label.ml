(* lib/label.ml:  a record field name and a variant tag (brief 3.2,
   D-A-3).  The occurrence index of a label rides beside it as occ, so a
   duplicate label in a row keeps its order. *)

type t = Label of string

type occ = Occ of int

let of_string (s : string) : t = Label s

let to_string (l : t) : string =
  match l with
  | Label s -> s

let equal (a : t) (b : t) : bool = String.equal (to_string a) (to_string b)

let occ_of_int (n : int) : occ = Occ n

let occ_to_int (o : occ) : int =
  match o with
  | Occ n -> n

let occ_equal (a : occ) (b : occ) : bool = occ_to_int a = occ_to_int b
