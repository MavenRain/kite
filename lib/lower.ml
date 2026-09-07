(* lib/lower.ml:  the map from a CHECKED surface program to the IR of
   lib/ir.ml (brief 3.12, D-B-17).  It erases types, rows, protocols,
   roles, manifests and budget annotations, and it refuses every M1 to M4
   form with NotYet naming its milestone.

   The map runs AFTER lib/infer.ml has accepted the program, so no arm
   below repairs a type.  An expression can hold no milestone form,
   because surface/ast.ml carries a milestone at the declaration level
   alone, so the expression map is TOTAL and the declaration map returns
   a result.

   D-B-59:  a recursive group gives ONE item per bound name, and the body
   of that item is the whole group closed over the name it binds.
   Reason:  an IR program is a flat list of named items, a group has to
   stay visible to every member, and the ILetRec arm of D-B-17 is what
   holds a group;  the reading also keeps declaration order, which the
   .kir artifact prints.

   D-B-62:  a freeze declaration lowers to one item under the name
   @freeze.  Reason:  the handler body is code the artifact has to hold,
   the surface binds no name to it, and the at sign starts no identifier
   the frozen lexer of Stage A can read, so the name can collide with no
   user binding. *)

let ( let* ) (x : ('a, Error.t) result) (f : 'a -> ('b, Error.t) result)
  : ('b, Error.t) result =
  Result.bind x f

(* --- patterns --------------------------------------------------------- *)

let rec pat (p : Ast.pat) : Ir.pat =
  match p with
  | Ast.PLit l -> Ir.PLit l
  | Ast.PVar x -> Ir.PVar x
  | Ast.PWild -> Ir.PWild
  | Ast.PInj (l, o, q) -> Ir.PInj (l, o, pat q)
  | Ast.PRec (fs, rest) ->
    Ir.PRec
      ( List.map
          (fun ((l, o, q) : Label.t * Label.occ * Ast.pat) -> (l, o, pat q))
          fs,
        rest )

(* --- expressions ------------------------------------------------------ *)

let rec expr (e : Ast.expr) : Ir.t =
  match e with
  | Ast.Lit l -> Ir.ILit l
  | Ast.Var x -> Ir.IVar x
  | Ast.Lam (p, b) -> Ir.ILam (pat p, expr b)
  | Ast.App (f, x) -> Ir.IApp (expr f, expr x)
  | Ast.Let (p, v, b) -> Ir.ILet (pat p, expr v, expr b)
  | Ast.LetRec (bs, b) -> Ir.ILetRec (binds bs, expr b)
  | Ast.If (c, a, b) -> Ir.IIf (expr c, expr a, expr b)
  | Ast.Rec fs ->
    Ir.IRec
      (List.map (fun ((l, v) : Label.t * Ast.expr) -> (l, expr v)) fs, None)
  | Ast.RecExt (l, v, base) -> Ir.IRec ([ (l, expr v) ], Some (expr base))
  | Ast.RecRes (base, l) ->
    Ir.IBin
      (Ir.restrict_op, expr base, Ir.ILit (Literal.Str (Label.to_string l)))
  | Ast.Sel (b, l) -> Ir.ISel (expr b, l)
  | Ast.Inj (l, o, b) -> Ir.IInj (l, o, expr b)
  | Ast.Match (scrut, arms) ->
    Ir.IMatch
      ( expr scrut,
        List.map (fun ((p, b) : Ast.arm) -> (pat p, expr b)) arms )
  | Ast.Ann (b, _ty) -> expr b
  | Ast.Bin (op, a, b) -> Ir.IBin (Ast.binop_text op, expr a, expr b)

and binds (bs : Ast.bind list) : (Ident.t * Ir.t) list =
  List.map (fun ((x, v) : Ast.bind) -> (x, expr v)) bs

(* --- declarations ------------------------------------------------------ *)

let freeze_name : Ident.t = Ident.of_string "@freeze"

(* One item per name a recursive group binds (D-B-59). *)
let group_items (bs : Ast.bind list) : Ir.item list =
  let lowered = binds bs in
  List.map
    (fun ((x, _v) : Ident.t * Ir.t) ->
      { Ir.iname = x;  Ir.ibody = Ir.ILetRec (lowered, Ir.IVar x) })
    lowered

let rec decl (d : Ast.decl) : (Ir.item list, Error.t) result =
  match d with
  | Ast.DLet (x, e) -> Ok [ { Ir.iname = x;  Ir.ibody = expr e } ]
  | Ast.DLetRec bs -> Ok (group_items bs)
  | Ast.DImport _ -> Ok []
  | Ast.DBudget (_fs, inner) -> decl inner
  | Ast.DProtocol _ -> Ok []
  | Ast.DRole _ -> Ok []
  | Ast.DFreeze (_ls, e) ->
    Ok [ { Ir.iname = freeze_name;  Ir.ibody = expr e } ]
  | Ast.DManifest (_n, _es) -> Ok []
  | Ast.DMilestone (m, n, _text) ->
    Error
      (Error.not_yet
         (String.concat " "
            [ "the declaration";  Ident.to_string n;  "arrives at";
              Ast.milestone_name m ]))

let prog (p : Ast.prog) : (Ir.prog, Error.t) result =
  List.fold_left
    (fun acc d ->
      let* items = acc in
      let* more = decl d in
      Ok (List.append items more))
    (Ok []) p
