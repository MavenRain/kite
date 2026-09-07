(* lib/ir.ml:  the lowered term language of brief 3.12 (D-B-17).  It has
   no types and no rows, because lib/lower.ml erases both, and it holds
   the twelve names the brief closes over:  IVar, ILit, ILam, IApp,
   ILet, ILetRec, IIf, IRec, ISel, IInj, IMatch and IBin.  A thirteenth
   name is a change of the brief and not a build decision.

   D-B-57:  an operator rides as the printed text of Ast.binop_text and
   not as a copy of the fourteen surface arms.  Reason:  the IR reads no
   surface tree, so a copy of the operator type would put lib/ir.ml in
   the library that depends on surface/ast.ml for nothing the machine
   below reads;  the text is total, it prints as itself and M1 recovers
   the arm by the same table.

   D-B-58:  record extension rides in IRec as an optional BASE term, and
   record restriction rides in IBin under the operator text backslash
   with the dropped label as a string literal.  Reason:  the twelve
   names of D-B-17 hold no extension arm and no restriction arm, IRec is
   the record former and IBin is the binary primitive former, and both
   readings erase the row exactly as the brief asks. *)

(* A pattern carries no type, and its occurrence index stays, because a
   scoped label of D-A-5 is what the match arm selects on. *)
type pat =
  | PLit of Literal.t
  | PVar of Ident.t
  | PWild
  | PInj of Label.t * Label.occ * pat
  | PRec of (Label.t * Label.occ * pat) list * Ident.t option

type t =
  | IVar of Ident.t
  | ILit of Literal.t
  | ILam of pat * t
  | IApp of t * t
  | ILet of pat * t * t
  | ILetRec of (Ident.t * t) list * t
  | IIf of t * t * t
  | IRec of (Label.t * t) list * t option
  | ISel of t * Label.t
  | IInj of Label.t * Label.occ * t
  | IMatch of t * (pat * t) list
  | IBin of string * t * t

(* One lowered top level binding.  A declaration that binds no name
   erases to no item, and a recursive group gives one item per name
   whose body closes the whole group (D-B-59). *)
type item = { iname : Ident.t;  ibody : t }

type prog = item list

(* The operator text of record restriction (D-B-58). *)
let restrict_op : string = "\\"

(* The size of a term, in nodes.  The driver of brief 3.11 prints the
   byte count of the written file and this count is what the build log
   reports beside it. *)
let rec size (e : t) : int =
  match e with
  | IVar _ -> 1
  | ILit _ -> 1
  | ILam (_p, b) -> 1 + size b
  | IApp (f, x) -> 1 + size f + size x
  | ILet (_p, v, b) -> 1 + size v + size b
  | ILetRec (bs, b) ->
    1 + size b + List.fold_left (fun acc (_x, v) -> acc + size v) 0 bs
  | IIf (c, a, b) -> 1 + size c + size a + size b
  | IRec (fs, base) ->
    1
    + Option.fold ~none:0 ~some:size base
    + List.fold_left (fun acc (_l, v) -> acc + size v) 0 fs
  | ISel (e2, _l) -> 1 + size e2
  | IInj (_l, _o, e2) -> 1 + size e2
  | IMatch (scrut, arms) ->
    1 + size scrut + List.fold_left (fun acc (_p, b) -> acc + size b) 0 arms
  | IBin (_op, a, b) -> 1 + size a + size b

let prog_size (p : prog) : int =
  List.fold_left (fun acc (it : item) -> acc + size it.ibody) 0 p
