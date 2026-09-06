(* surface/ast.ml:  the kite surface tree, declared WHOLE at Stage A
   (brief 3.3, D-A-4 to D-A-11).  Every form of the acceptance corpus
   has an arm here, and every M1 to M4 form parses to DMilestone, so a
   later milestone adds a checker leg and not a new arm.

   The printer holds an arm per constructor and no wildcard arm, so a
   new arm is a compile error at every site. *)

(* --- types (D-A-4, D-A-5) --------------------------------------- *)

(* The arrow bit of A2:  Many is the plain arrow -> and AtMostOnce is
   the -1> arrow, which the callee may call at most one time. *)
type mult =
  | Many
  | AtMostOnce

type ty =
  | TName of string
  | TArrow of ty * mult * ty
  | TRec of trow
  | TVar of trow
  | TCode of trow * ty

(* A row is a field list and an optional tail name.  A field named susp
   is an ordinary field, so the susp row entry of A3 needs no arm and
   prints back unchanged (D-A-5). *)
and trow = { fields : (Label.t * ty) list;  tail : string option }

(* --- patterns ---------------------------------------------------- *)

type pat =
  | PLit of Literal.t
  | PVar of Ident.t
  | PWild
  | PInj of Label.t * Label.occ * pat
  | PRec of (Label.t * Label.occ * pat) list * Ident.t option

(* --- operators (D-A-6) ------------------------------------------- *)

(* Fourteen operators.  Cat is the ^ operator over strings, and the
   comparison group is non-associative (D-A-13). *)
type binop =
  | Add
  | Sub
  | Mul
  | Div
  | Mod
  | Cat
  | Eq
  | Ne
  | Lt
  | Le
  | Gt
  | Ge
  | And
  | Or

(* --- expressions -------------------------------------------------- *)

type expr =
  | Lit of Literal.t
  | Var of Ident.t
  | Lam of pat * expr
  | App of expr * expr
  | Let of pat * expr * expr
  | LetRec of bind list * expr
  | If of expr * expr * expr
  | Rec of (Label.t * expr) list
  | RecExt of Label.t * expr * expr
  | RecRes of expr * Label.t
  | Sel of expr * Label.t
  | Inj of Label.t * Label.occ * expr
  | Match of expr * arm list
  | Ann of expr * ty
  | Bin of binop * expr * expr

and arm = pat * expr

and bind = Ident.t * expr

(* --- declarations (D-A-7 to D-A-11) ------------------------------- *)

(* The milestone that a refused form arrives at (D-A-11). *)
type milestone =
  | M1
  | M2
  | M3
  | M4

(* An import of A9:  a cost index and a deadline in whole milliseconds,
   both written and both needed (D-A-9). *)
type import = { iname : Ident.t;  ity : ty;  cost : int;  deadline_ms : int }

(* A protocol state of A4 (D-A-7).  A leg is a label, the type it
   carries and the state it moves to.  compensate is optional at Stage
   A, because the refusal of a state with no compensation is a Stage B
   check. *)
type pstate =
  { sname : Ident.t;
    legs : (Label.t * ty * Ident.t) list;
    compensate : expr option
  }

type proto = { pname : Ident.t;  states : pstate list }

(* A role of A4 (D-A-7).  peer_lost is the Peer_lost leg and abort is
   the abort leg;  both are optional at Stage A. *)
type role =
  { rname : Ident.t;
    proto : Ident.t;
    clauses : (Label.t * Ident.t list * expr) list;
    peer_lost : expr option;
    abort : expr option
  }

(* A manifest entry of A10 (D-A-10):  a kind word, a name and a field
   list.  No manifest field holds a lambda at M0. *)
type mentry = { kind : Ident.t;  ename : Ident.t;  fields : (Label.t * expr) list }

type decl =
  | DLet of Ident.t * expr
  | DLetRec of bind list
  | DImport of import
  | DBudget of (Label.t * int) list * decl
  | DProtocol of proto
  | DRole of role
  | DFreeze of Label.t list * expr
  | DManifest of Ident.t * mentry list
  | DMilestone of milestone * Ident.t * string

type prog = decl list

(* --- small total helpers ------------------------------------------ *)

let milestone_name (m : milestone) : string =
  match m with
  | M1 -> "M1"
  | M2 -> "M2"
  | M3 -> "M3"
  | M4 -> "M4"

let binop_text (b : binop) : string =
  match b with
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Cat -> "^"
  | Eq -> "=="
  | Ne -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="
  | And -> "&&"
  | Or -> "||"

(* The level of D-A-13, lowest first:  1 Or, 2 And, 3 the comparison
   group, 4 Add Sub Cat, 5 Mul Div Mod. *)
let binop_level (b : binop) : int =
  match b with
  | Or -> 1
  | And -> 2
  | Eq -> 3
  | Ne -> 3
  | Lt -> 3
  | Le -> 3
  | Gt -> 3
  | Ge -> 3
  | Add -> 4
  | Sub -> 4
  | Cat -> 4
  | Mul -> 5
  | Div -> 5
  | Mod -> 5

let mult_text (m : mult) : string =
  match m with
  | Many -> "->"
  | AtMostOnce -> "-1>"
