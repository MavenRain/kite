(* lib/types.ml:  the internal type grammar of M0, declared WHOLE
   (brief 3.1, D-B-2 to D-B-4).  The surface tree of surface/ast.ml is
   what the user writes;  this grammar is what the checker solves, and
   the two never share a constructor.

   A row is SCOPED (D-A-5, D-B-2):  RExt carries the occurrence index of
   the label it adds, a label may repeat, extension is RExt, restriction
   removes the FIRST occurrence and selection reads the FIRST occurrence.

   Con covers the four literal kinds of lib/literal.ml, that is Int, Str,
   Bool and Unit, one Con name per kind and no fifth name.  Code carries
   a row and a type, and the checker refuses it by milestone name,
   because the code type ARRIVES AT M2 (M0-PLAN.md:41). *)

(* The arrow bit of A2:  Many is the plain arrow -> and AtMostOnce is the
   -1> arrow of surface/ast.ml.  The two never unify (D-B-6). *)
type mult =
  | Many
  | AtMostOnce

(* A type variable and a row variable are two namespaces, so a type
   variable never unifies with a row variable (D-B-3).  Each record holds
   its id and the level at which it was made.  The binding of an id lives
   in the value-threaded store of lib/subst.ml, because lib/ holds no
   cell to write into (dev/house.sh:131). *)
type tvar = { id : int;  level : int }

type tvar_row = { rid : int;  rlevel : int }

type t =
  | Var of tvar
  | Con of string
  | Arrow of t * mult * t
  | Record of row
  | Variant of row
  | Code of row * t

and row =
  | REmpty
  | RVar of tvar_row
  | RExt of Label.t * Label.occ * t * row

(* A scheme quantifies a type variable list and a row variable list over
   one body (brief 3.3).  It is declared beside the grammar it closes,
   because lib/pp.ml prints a scheme and lib/iface.ml writes one, and
   neither reads the term environment;  lib/env.ml re-exports the record
   under the name the brief gives it (D-B-31). *)
type scheme = { vars : int list;  rvars : int list;  body : t }

(* --- total helpers ------------------------------------------------- *)

let mult_equal (a : mult) (b : mult) : bool =
  match (a, b) with
  | (Many, Many) -> true
  | (Many, AtMostOnce) -> false
  | (AtMostOnce, Many) -> false
  | (AtMostOnce, AtMostOnce) -> true

let mult_text (m : mult) : string =
  match m with
  | Many -> "->"
  | AtMostOnce -> "-1>"

(* The four Con names, one per literal kind of lib/literal.ml. *)
let int_type : t = Con "Int"

let str_type : t = Con "Str"

let bool_type : t = Con "Bool"

let unit_type : t = Con "Unit"

let con_names : string list = [ "Int";  "Str";  "Bool";  "Unit" ]

let is_con_name (s : string) : bool = List.exists (String.equal s) con_names

let type_of_literal (l : Literal.t) : t =
  match l with
  | Literal.Int _ -> int_type
  | Literal.Str _ -> str_type
  | Literal.Bool _ -> bool_type
  | Literal.Unit -> unit_type

(* The kind of a form, which the KindMismatch message names. *)
let kind_of_type (_ : t) : Kind.t = Kind.Type

let kind_of_row (_ : row) : Kind.t = Kind.Row

let mono (body : t) : scheme = { vars = [];  rvars = [];  body }

(* The head of a row, taken by position among the entries that carry the
   same label:  the FIRST such entry is occurrence zero (D-B-5).  The
   count is what a record literal uses to number its own fields. *)
let rec occ_count (l : Label.t) (r : row) : int =
  match r with
  | REmpty -> 0
  | RVar _ -> 0
  | RExt (l2, _, _, rest) ->
    let here = if Label.equal l l2 then 1 else 0 in
    here + occ_count l rest

(* --- the printer of the internal grammar ---------------------------- *)

(* The printer lives beside the grammar it reads, because lib/unify.ml
   names two types in a Mismatch message and lib/pp.ml prints a SCHEME
   over this same form (D-B-33).  A variable prints by its id, and
   lib/pp.ml renames a quantified id for a golden. *)
let rec to_string (ty : t) : string =
  match ty with
  | Var v -> String.concat "" [ "t";  string_of_int v.id ]
  | Con c -> c
  | Arrow (a, m, b) ->
    String.concat " " [ "(";  to_string a;  mult_text m;  to_string b;  ")" ]
  | Record r -> String.concat " " [ "{";  row_to_string r;  "}" ]
  | Variant r -> String.concat " " [ "<";  row_to_string r;  ">" ]
  | Code (r, b) ->
    String.concat " " [ "Code";  "[";  row_to_string r;  ",";  to_string b;  "]" ]

and row_to_string (r : row) : string =
  match r with
  | REmpty -> ""
  | RVar v -> String.concat "" [ "| r";  string_of_int v.rid ]
  | RExt (l, o, ty, rest) ->
    let head =
      String.concat " "
        [ Label.to_string l;  "^";  string_of_int (Label.occ_to_int o);  ":";
          to_string ty ] in
    let tl = row_to_string rest in
    if String.equal tl "" then head
    else if String.starts_with ~prefix:"|" tl then String.concat " " [ head;  tl ]
    else String.concat " " [ head;  ",";  tl ]
