(* Algorithm W with levels (D-B-7).  Values generalize above the enclosing
   level; non-values lower to that level and remain monomorphic.  Recursive
   names start monomorphic and the group generalizes together (D-B-42).
   Errors, environments, stores and counters thread as immutable values.
   Future declarations and code types report their milestone as NotYet. *)

let ( let* ) (x : ('a, Error.t) result) (f : 'a -> ('b, Error.t) result)
  : ('b, Error.t) result = Result.bind x f

(* --- the budget counters of D-B-10 ----------------------------------- *)

type counters = { atoms : int;  constraints : int }

(* The caps in force when no annotation wraps a declaration:  64 atoms,
   from the 64 atom cap of A5, and 32 constraints, which D-B-10 fixes. *)
let default_caps : counters = { atoms = 64;  constraints = 32 }

(* D-B-41:  the annotation of D-A-10 reads into the caps in force, and
   the record threads through every declaration, so infer_decl carries
   the signature D-B-10 names.  A label the annotation does not name
   keeps the cap it came in with. *)
let caps_of_annotation (c : counters) (fs : (Label.t * int) list) : counters =
  List.fold_left
    (fun acc (l, n) ->
      let key = Label.to_string l in
      if String.equal key "atoms" then { acc with atoms = n }
      else if String.equal key "constraints" then { acc with constraints = n }
      else acc)
    c fs

(* --- the A5 obligation of brief 3.6 (D-B-10, D-B-49) ------------------ *)

(* An ATOM is one occurrence of a linear arithmetic variable inside an
   obligation and a CONSTRAINT is one difference constraint of that
   obligation (verdict:289).  D-B-49 fixes what the checker counts at M0:
   an operator of the arithmetic group and of the comparison group opens
   an obligation, every name occurrence under such an operator is one
   atom, and every comparison node is one difference constraint.  The
   pair below reads, per operator, whether it opens an obligation and
   whether it is itself a constraint. *)
let op_kind (op : Ast.binop) : bool * bool =
  match op with
  | Ast.Add -> (true, false)
  | Ast.Sub -> (true, false)
  | Ast.Mul -> (true, false)
  | Ast.Div -> (true, false)
  | Ast.Mod -> (true, false)
  | Ast.Cat -> (false, false)
  | Ast.Eq -> (true, true)
  | Ast.Ne -> (true, true)
  | Ast.Lt -> (true, true)
  | Ast.Le -> (true, true)
  | Ast.Gt -> (true, true)
  | Ast.Ge -> (true, true)
  | Ast.And -> (false, false)
  | Ast.Or -> (false, false)

let zero_counts : counters = { atoms = 0;  constraints = 0 }

let add_counts (a : counters) (b : counters) : counters =
  { atoms = a.atoms + b.atoms;  constraints = a.constraints + b.constraints }

let one_atom : counters = { atoms = 1;  constraints = 0 }

let one_constraint : counters = { atoms = 0;  constraints = 1 }

(* The counts an expression raises.  inside says that the reader already
   sits under an arithmetic operator, so a name it meets is an atom. *)
let rec count_expr (inside : bool) (e : Ast.expr) : counters =
  match e with
  | Ast.Lit _ -> zero_counts
  | Ast.Var _ -> if inside then one_atom else zero_counts
  | Ast.Lam (_p, b) -> count_expr inside b
  | Ast.App (f, x) -> add_counts (count_expr inside f) (count_expr inside x)
  | Ast.Let (_p, v, b) -> add_counts (count_expr inside v) (count_expr inside b)
  | Ast.LetRec (bs, b) ->
    add_counts
      (List.fold_left
         (fun acc ((_x, r) : Ast.bind) -> add_counts acc (count_expr inside r))
         zero_counts bs)
      (count_expr inside b)
  | Ast.If (c, a, b) ->
    add_counts (count_expr inside c)
      (add_counts (count_expr inside a) (count_expr inside b))
  | Ast.Rec fs ->
    List.fold_left
      (fun acc (_l, x) -> add_counts acc (count_expr inside x))
      zero_counts fs
  | Ast.RecExt (_l, v, t) ->
    add_counts (count_expr inside v) (count_expr inside t)
  | Ast.RecRes (t, _l) -> count_expr inside t
  | Ast.Sel (t, _l) -> count_expr inside t
  | Ast.Inj (_l, _o, x) -> count_expr inside x
  | Ast.Match (s, arms) ->
    add_counts (count_expr inside s)
      (List.fold_left
         (fun acc ((_p, b) : Ast.arm) -> add_counts acc (count_expr inside b))
         zero_counts arms)
  | Ast.Ann (x, _t) -> count_expr inside x
  | Ast.Bin (op, a, b) ->
    let (opens, constrains) = op_kind op in
    let here = if constrains then one_constraint else zero_counts in
    let deeper = inside || opens in
    add_counts here (add_counts (count_expr deeper a) (count_expr deeper b))

let decl_counts (d : Ast.decl) : counters =
  List.fold_left
    (fun acc e -> add_counts acc (count_expr false e))
    zero_counts (Usage.decl_exprs d)

let over (what : string) (got : int) (cap : int) : Error.t =
  Error.budget
    (String.concat " "
       [ "the obligation raises";  string_of_int got;  what;
         "over the printed budget of";  string_of_int cap ])

let limit (c : counters) (got : counters) : (unit, Error.t) result =
  match () with
  | () when got.atoms > c.atoms -> Error (over "atoms" got.atoms c.atoms)
  | () when got.constraints > c.constraints ->
    Error (over "constraints" got.constraints c.constraints)
  | () -> Ok ()

(* The A5 check of brief 3.6.  A budget annotation reads into the caps in
   force and the wrapped declaration is held at or under them;  a
   declaration with no annotation is held at the default caps of D-B-10,
   that is 64 atoms and 32 constraints. *)
let rec budget_check (c : counters) (d : Ast.decl) : (unit, Error.t) result =
  match d with
  | Ast.DBudget (fs, inner) -> budget_check (caps_of_annotation c fs) inner
  | Ast.DLet (_, _)
  | Ast.DLetRec _
  | Ast.DImport _
  | Ast.DProtocol _
  | Ast.DRole _
  | Ast.DFreeze (_, _)
  | Ast.DManifest (_, _)
  | Ast.DMilestone (_, _, _) -> limit c (decl_counts d)

(* --- the syntactic value test of D-B-7 -------------------------------- *)

(* D-B-46:  an annotated value is a value, because an annotation writes
   the arrow bit of A2 and writes no computation. *)
let rec is_value (e : Ast.expr) : bool =
  match e with
  | Ast.Lit _ -> true
  | Ast.Var _ -> true
  | Ast.Lam (_, _) -> true
  | Ast.Rec fs -> List.for_all (fun (_, v) -> is_value v) fs
  | Ast.Ann (x, _) -> is_value x
  | Ast.App (_, _) -> false
  | Ast.Let (_, _, _) -> false
  | Ast.LetRec (_, _) -> false
  | Ast.If (_, _, _) -> false
  | Ast.RecExt (_, _, _) -> false
  | Ast.RecRes (_, _) -> false
  | Ast.Sel (_, _) -> false
  | Ast.Inj (_, _, _) -> false
  | Ast.Match (_, _) -> false
  | Ast.Bin (_, _, _) -> false

(* --- generalization by levels (D-B-7) --------------------------------- *)

let generalize (s : Subst.t) (lvl : int) (ty : Types.t) : Types.scheme =
  let (ts, rs) = Subst.free_of_type s ([], []) ty in
  let vars =
    List.filter_map
      (fun (v : Types.tvar) -> if v.level > lvl then Some v.id else None)
      ts in
  let rvars =
    List.filter_map
      (fun (v : Types.tvar_row) -> if v.rlevel > lvl then Some v.rid else None)
      rs in
  { Types.vars = vars;  Types.rvars = rvars;  Types.body = Subst.apply s ty }

let monomorphic (s : Subst.t) (ty : Types.t) : Types.scheme =
  Types.mono (Subst.apply s ty)

(* --- the arrow bit at a use site --------------------------------------- *)

let affine_head (ty : Types.t) : bool =
  match ty with
  | Types.Arrow (_, Types.AtMostOnce, _) -> true
  | Types.Arrow (_, Types.Many, _) -> false
  | Types.Var _ -> false
  | Types.Con _ -> false
  | Types.Record _ -> false
  | Types.Variant _ -> false
  | Types.Code _ -> false

let arrow_mult (ty : Types.t) : Types.mult =
  if affine_head ty then Types.AtMostOnce else Types.Many

(* D-B-40:  an annotation may tighten a Many arrow to a -1> arrow,
   because a function that runs many times also runs at most once and the
   annotation is the one place the surface writes the bit (D-A-4).  The
   other direction stays a Mismatch:  a -1> arrow met where a Many arrow
   is wanted does not unify (D-B-6). *)
let retag (m : Types.mult) (ty : Types.t) : Types.t =
  match ty with
  | Types.Arrow (a, _, b) -> Types.Arrow (a, m, b)
  | Types.Var _ -> ty
  | Types.Con _ -> ty
  | Types.Record _ -> ty
  | Types.Variant _ -> ty
  | Types.Code _ -> ty

(* --- the surface type to the internal type ----------------------------- *)

(* A name written in a declared type binds once over that declaration, so
   the two name maps ride together:  a name already taken as a row
   variable and met as a type variable is KindMismatch, and the other way
   round is the same error (brief 3.8). *)
type names = { tvs : (string * Types.t) list;  rvs : (string * Types.row) list }

let no_names : names = { tvs = [];  rvs = [] }

let kind_clash (n : string) (want : Kind.t) (got : Kind.t) : Error.t =
  Error.kind_mismatch
    (String.concat " "
       [ "the name";  n;  "has the kind";  Kind.to_string got;
         "where the kind";  Kind.to_string want;  "is needed" ])

let elab_mult (m : Ast.mult) : Types.mult =
  match m with
  | Ast.Many -> Types.Many
  | Ast.AtMostOnce -> Types.AtMostOnce

let rec elab_ty (lvl : int) (nm : names) (s : Subst.t) (t : Ast.ty)
  : (Types.t * names * Subst.t, Error.t) result =
  match t with
  | Ast.TName n ->
    if Types.is_con_name n then Ok (Types.Con n, nm, s)
    else if List.mem_assoc n nm.rvs then Error (kind_clash n Kind.Type Kind.Row)
    else
      Option.fold
        ~none:
          (let (v, s2) = Subst.fresh_type lvl s in
           Ok (v, { nm with tvs = (n, v) :: nm.tvs }, s2))
        ~some:(fun v -> Ok (v, nm, s))
        (List.assoc_opt n nm.tvs)
  | Ast.TArrow (a, m, b) ->
    let* (ta, nm1, s1) = elab_ty lvl nm s a in
    let* (tb, nm2, s2) = elab_ty lvl nm1 s1 b in
    Ok (Types.Arrow (ta, elab_mult m, tb), nm2, s2)
  | Ast.TRec r ->
    let* (row, nm1, s1) = elab_row lvl nm s r in
    Ok (Types.Record row, nm1, s1)
  | Ast.TVar r ->
    let* (row, nm1, s1) = elab_row lvl nm s r in
    Ok (Types.Variant row, nm1, s1)
  | Ast.TCode (_, _) -> Error (Error.not_yet "the code type arrives at M2")

and elab_row (lvl : int) (nm : names) (s : Subst.t) (r : Ast.trow)
  : (Types.row * names * Subst.t, Error.t) result =
  let* (tail, nm0, s0) = elab_tail lvl nm s r.Ast.tail in
  let* (fs, nm1, s1) =
    List.fold_left
      (fun acc (l, t) ->
        let* (got, n2, st) = acc in
        let* (ty, n3, st2) = elab_ty lvl n2 st t in
        Ok (got @ [ (l, ty) ], n3, st2))
      (Ok ([], nm0, s0)) r.Ast.fields in
  Ok (Row.of_fields fs tail, nm1, s1)

and elab_tail (lvl : int) (nm : names) (s : Subst.t) (tl : string option)
  : (Types.row * names * Subst.t, Error.t) result =
  Option.fold
    ~none:(Ok (Types.REmpty, nm, s))
    ~some:(fun (n : string) ->
      if List.mem_assoc n nm.tvs then Error (kind_clash n Kind.Row Kind.Type)
      else
        Option.fold
          ~none:
            (let (v, s2) = Subst.fresh_row lvl s in
             Ok (v, { nm with rvs = (n, v) :: nm.rvs }, s2))
          ~some:(fun v -> Ok (v, nm, s))
          (List.assoc_opt n nm.rvs))
    tl

(* A declared type closes over the names it writes, so an import or a
   protocol leg reads at every use site (D-B-15). *)
let elab_scheme (lvl : int) (s : Subst.t) (t : Ast.ty)
  : (Types.scheme * Subst.t, Error.t) result =
  let* (ty, _names, s1) = elab_ty (lvl + 1) no_names s t in
  Ok (generalize s1 lvl ty, s1)

(* --- expressions and patterns ----------------------------------------- *)

let rec infer_expr (env : Env.t) (s : Subst.t) (e : Ast.expr)
  : (Types.t * Subst.t, Error.t) result =
  match e with
  | Ast.Lit v -> Ok (Types.type_of_literal v, s)
  | Ast.Var x ->
    Option.fold
      ~none:
        (Error
           (Error.unbound
              (String.concat " "
                 [ "the name";  Ident.to_string (Usage.source_name x);
                   "has no binding" ])))
      ~some:(fun sc -> Ok (Subst.instantiate (Env.level env) sc s))
      (Env.lookup x env)
  | Ast.Lam (p, b) ->
    let* (tp, binds, s1) = infer_pat env s p in
    let* (tb, s2) = infer_expr (Env.extend_all binds env) s1 b in
    Ok (Types.Arrow (tp, Types.Many, tb), s2)
  | Ast.App (f, x) ->
    let* (tf, s1) = infer_expr env s f in
    let* (tx, s2) = infer_expr env s1 x in
    let (tr, s3) = Subst.fresh_type (Env.level env) s2 in
    let m = arrow_mult (Subst.resolve_type s3 tf) in
    let* s4 = Unify.unify s3 tf (Types.Arrow (tx, m, tr)) in
    Ok (Subst.apply s4 tr, s4)
  | Ast.Let (p, v, b) ->
    let* (binds, s1) = infer_binding env s p v in
    infer_expr (Env.extend_all binds env) s1 b
  | Ast.LetRec (bs, b) ->
    let* (binds, s1) = infer_group env s bs in
    infer_expr (Env.extend_all binds env) s1 b
  | Ast.If (c, a, b) ->
    let* (tc, s1) = infer_expr env s c in
    let* s2 = Unify.unify s1 tc Types.bool_type in
    let* (ta, s3) = infer_expr env s2 a in
    let* (tb, s4) = infer_expr env s3 b in
    let* s5 = Unify.unify s4 ta tb in
    Ok (Subst.apply s5 ta, s5)
  | Ast.Rec fs ->
    let* (row, s1) = infer_fields env s fs in
    Ok (Types.Record row, s1)
  | Ast.RecExt (l, v, t) ->
    let* (tv, s1) = infer_expr env s v in
    let* (tt, s2) = infer_expr env s1 t in
    let (rest, s3) = Subst.fresh_row (Env.level env) s2 in
    let* s4 = Unify.unify s3 tt (Types.Record rest) in
    Ok
      ( Types.Record (Row.extend l (Subst.apply s4 tv) (Subst.apply_row s4 rest)),
        s4 )
  | Ast.RecRes (t, l) ->
    let* (tt, s1) = infer_expr env s t in
    let (rest, s2) = Subst.fresh_row (Env.level env) s1 in
    let (fld, s3) = Subst.fresh_type (Env.level env) s2 in
    let* s4 = Unify.unify s3 tt (Types.Record (Row.extend l fld rest)) in
    Ok (Types.Record (Row.reindex (Subst.apply_row s4 rest)), s4)
  | Ast.Sel (t, l) ->
    let* (tt, s1) = infer_expr env s t in
    let (rest, s2) = Subst.fresh_row (Env.level env) s1 in
    let (fld, s3) = Subst.fresh_type (Env.level env) s2 in
    let* s4 = Unify.unify s3 tt (Types.Record (Row.extend l fld rest)) in
    Ok (Subst.apply s4 fld, s4)
  | Ast.Inj (l, o, x) ->
    let* (tx, s1) = infer_expr env s x in
    let (rest, s2) = Subst.fresh_row (Env.level env) s1 in
    let (row, _rest, s3) =
      Row.indexed_fields (Env.level env) s2 [ (l, o, tx) ] rest in
    Ok (Types.Variant row, s3)
  | Ast.Match (scrut, arms) -> infer_match env s scrut arms
  | Ast.Ann (x, t) ->
    let* (ta, _names, s1) = elab_ty (Env.level env) no_names s t in
    let* (tx, s2) = infer_expr env s1 x in
    let seen = Subst.resolve_type s2 tx in
    let got = if affine_head ta then retag Types.AtMostOnce seen else tx in
    let* s3 = Unify.unify s2 got ta in
    Ok (Subst.apply s3 ta, s3)
  | Ast.Bin (op, a, b) -> infer_bin env s op a b

and infer_fields (env : Env.t) (s : Subst.t) (fs : (Label.t * Ast.expr) list)
  : (Types.row * Subst.t, Error.t) result =
  let* (tys, s1) =
    List.fold_left
      (fun acc (l, x) ->
        let* (got, st) = acc in
        let* (ty, st2) = infer_expr env st x in
        Ok (got @ [ (l, ty) ], st2))
      (Ok ([], s)) fs in
  Ok (Row.of_fields tys Types.REmpty, s1)

and infer_match (env : Env.t) (s : Subst.t) (scrut : Ast.expr)
    (arms : Ast.arm list) : (Types.t * Subst.t, Error.t) result =
  let* (ts, s1) = infer_expr env s scrut in
  let (tr, s2) = Subst.fresh_type (Env.level env) s1 in
  let* sfin =
    List.fold_left
      (fun acc (p, body) ->
        let* st = acc in
        let* (tp, binds, st2) = infer_pat env st p in
        let* st3 = Unify.unify st2 tp ts in
        let* (tb, st4) = infer_expr (Env.extend_all binds env) st3 body in
        Unify.unify st4 tb tr)
      (Ok s2) arms in
  Ok (Subst.apply sfin tr, sfin)

and infer_pat (env : Env.t) (s : Subst.t) (p : Ast.pat)
  : (Types.t * (Ident.t * Types.scheme) list * Subst.t, Error.t) result =
  match p with
  | Ast.PLit v -> Ok (Types.type_of_literal v, [], s)
  | Ast.PVar x ->
    let (t, s1) = Subst.fresh_type (Env.level env) s in
    Ok (t, [ (x, Types.mono t) ], Subst.observe x t s1)
  | Ast.PWild ->
    let (t, s1) = Subst.fresh_type (Env.level env) s in
    Ok (t, [], s1)
  | Ast.PInj (l, o, q) ->
    let* (tq, bs, s1) = infer_pat env s q in
    let (rest, s2) = Subst.fresh_row (Env.level env) s1 in
    let (row, _rest, s3) =
      Row.indexed_fields (Env.level env) s2 [ (l, o, tq) ] rest in
    Ok (Types.Variant row, bs, s3)
  | Ast.PRec (fs, tl) -> infer_prec env s fs tl

and infer_prec (env : Env.t) (s : Subst.t)
    (fs : (Label.t * Label.occ * Ast.pat) list) (tl : Ident.t option)
  : (Types.t * (Ident.t * Types.scheme) list * Subst.t, Error.t) result =
  let* () = Row.no_duplicate (List.map (fun (l, o, _) -> (l, o)) fs) in
  let* (tys, bs, s1) =
    List.fold_left
      (fun acc (l, o, q) ->
        let* (got, seen, st) = acc in
        let* (tq, bs2, st2) = infer_pat env st q in
        Ok (got @ [ (l, o, tq) ], seen @ bs2, st2))
      (Ok ([], [], s)) fs in
  let (rest, s2) = Subst.fresh_row (Env.level env) s1 in
  let (row, unmatched, s3) =
    Row.indexed_fields (Env.level env) s2 tys rest in
  let tail_bind =
    Option.fold ~none:[]
      ~some:(fun x -> [ (x, Types.mono (Types.Record unmatched)) ])
      tl in
  Ok (Types.Record row, bs @ tail_bind, s3)

(* The fourteen operators of D-A-6.  Eq and Ne read both operands at one
   type and give Bool, so their operand type is not fixed;  every other
   operator fixes it. *)
and binop_rule (op : Ast.binop) : bool * Types.t * Types.t =
  match op with
  | Ast.Add -> (true, Types.int_type, Types.int_type)
  | Ast.Sub -> (true, Types.int_type, Types.int_type)
  | Ast.Mul -> (true, Types.int_type, Types.int_type)
  | Ast.Div -> (true, Types.int_type, Types.int_type)
  | Ast.Mod -> (true, Types.int_type, Types.int_type)
  | Ast.Cat -> (true, Types.str_type, Types.str_type)
  | Ast.Eq -> (false, Types.unit_type, Types.bool_type)
  | Ast.Ne -> (false, Types.unit_type, Types.bool_type)
  | Ast.Lt -> (true, Types.int_type, Types.bool_type)
  | Ast.Le -> (true, Types.int_type, Types.bool_type)
  | Ast.Gt -> (true, Types.int_type, Types.bool_type)
  | Ast.Ge -> (true, Types.int_type, Types.bool_type)
  | Ast.And -> (true, Types.bool_type, Types.bool_type)
  | Ast.Or -> (true, Types.bool_type, Types.bool_type)

and infer_bin (env : Env.t) (s : Subst.t) (op : Ast.binop) (a : Ast.expr)
    (b : Ast.expr) : (Types.t * Subst.t, Error.t) result =
  let* (ta, s1) = infer_expr env s a in
  let* (tb, s2) = infer_expr env s1 b in
  let (fixed, operand, result) = binop_rule op in
  let* s3 = Unify.unify s2 ta tb in
  let* s4 =
    if fixed then Result.bind (Unify.unify s3 ta operand)
        (fun s5 -> Unify.unify s5 tb operand)
    else Ok s3 in
  Ok (result, s4)

and infer_binding (env : Env.t) (s : Subst.t) (p : Ast.pat) (v : Ast.expr)
  : ((Ident.t * Types.scheme) list * Subst.t, Error.t) result =
  let lvl = Env.level env in
  let inner = Env.deeper env in
  let* (tv, s1) = infer_expr inner s v in
  let* (tp, binds, s2) = infer_pat inner s1 p in
  let* s3 = Unify.unify s2 tp tv in
  let close = is_value v in
  let s4 = if close then s3 else Subst.lower_type lvl tv s3 in
  Ok
    ( List.map
        (fun (x, (sc : Types.scheme)) ->
          if close then (x, generalize s4 lvl sc.Types.body)
          else (x, monomorphic s4 sc.Types.body))
        binds,
      s4 )

and infer_group (env : Env.t) (s : Subst.t) (bs : Ast.bind list)
  : ((Ident.t * Types.scheme) list * Subst.t, Error.t) result =
  let lvl = Env.level env in
  let inner = Env.deeper env in
  let (holes, s1) =
    List.fold_left
      (fun (acc, st) (x, _) ->
        let (t, st2) = Subst.fresh_type (Env.level inner) st in
        (acc @ [ (x, t) ], Subst.observe x t st2))
      ([], s) bs in
  let inner_env =
    Env.extend_all (List.map (fun (x, t) -> (x, Types.mono t)) holes) inner in
  let* s2 =
    List.fold_left
      (fun acc (x, rhs) ->
        let* st = acc in
        let* (tr, st2) = infer_expr inner_env st rhs in
        Option.fold
          ~none:
            (Error
               (Error.unbound
                  (String.concat " "
                     [ "the recursive name";  Ident.to_string (Usage.source_name x);
                       "has no hole" ])))
          ~some:(fun h -> Unify.unify st2 h tr)
          (List.find_map
             (fun (y, t) -> if Ident.equal x y then Some t else None)
             holes))
      (Ok s1) bs in
  let close = List.for_all (fun (_, rhs) -> is_value rhs) bs in
  let s3 =
    if close then s2
    else List.fold_left (fun st (_, t) -> Subst.lower_type lvl t st) s2 holes in
  Ok
    ( List.map
        (fun (x, t) ->
          if close then (x, generalize s3 lvl t) else (x, monomorphic s3 t))
        holes,
      s3 )

(* --- declarations ------------------------------------------------------ *)

(* D-B-43:  an import agrees with a loaded interface when the EXPORTED
   scheme is at least as general as the DECLARED one.  The declared
   scheme takes rigid constants for its own quantifiers and the exported
   scheme takes fresh variables, and one unification on a scratch store
   settles it.  A difference is IfaceMismatch (D-B-15). *)
let rigid (sc : Types.scheme) : Types.t =
  let tm =
    List.map
      (fun id -> (id, Types.Con (String.concat "" [ "#t";  string_of_int id ])))
      sc.Types.vars in
  let rm =
    List.map
      (fun id ->
        ( id,
          Types.RExt
            ( Label.of_string (String.concat "" [ "#r";  string_of_int id ]),
              Label.occ_of_int 0, Types.unit_type, Types.REmpty ) ))
      sc.Types.rvars in
  Subst.substitute tm rm sc.Types.body

let scheme_agrees (declared : Types.scheme) (exported : Types.scheme) : bool =
  let (ts, rs) = Subst.free_of_type Subst.empty ([], []) exported.Types.body in
  let weak =
    { Types.vars = List.filter_map (fun (v : Types.tvar) ->
        if List.mem v.id exported.Types.vars then None else Some v.id) ts;
      Types.rvars = List.filter_map (fun (v : Types.tvar_row) ->
        if List.mem v.rid exported.Types.rvars then None else Some v.rid) rs;
      Types.body = exported.Types.body } in
  let weak_types = List.map (fun id ->
    (id, Types.Con ("#weak_t" ^ string_of_int id))) weak.Types.vars in
  let weak_rows = List.map (fun id ->
    (id, Types.RExt (Label.of_string ("#weak_r" ^ string_of_int id),
       Label.occ_of_int 0, Types.unit_type, Types.REmpty))) weak.Types.rvars in
  let exported = { exported with Types.body =
    Subst.substitute weak_types weak_rows exported.Types.body } in
  let wanted = rigid declared in
  let (given, s1) = Subst.instantiate 1 exported Subst.empty in
  Result.is_ok (Unify.unify s1 given wanted)

(* --- the A4 checks of brief 3.7 (D-B-11) ------------------------------ *)

(* Every state declares a compensation the reaper runs on lock loss, and
   a state without one is a compile error (verdict:288). *)
let compensation_check (pn : Ident.t) (st : Ast.pstate) : (unit, Error.t) result
  =
  Option.fold
    ~none:
      (Error
         (Error.compensation
            (String.concat " "
               [ "the protocol";  Ident.to_string pn;  "has the state";
                 Ident.to_string st.Ast.sname;
                 "and that state declares no compensation" ])))
    ~some:(fun (_e : Ast.expr) -> Ok ())
    st.Ast.compensate

(* Every role declares a Peer_lost leg (verdict:288).  The abort leg is
   NOT checked, because the protocol side makes abort total (D-B-11). *)
let peer_lost_check (r : Ast.role) : (unit, Error.t) result =
  Option.fold
    ~none:
      (Error
         (Error.peer_lost
            (String.concat " "
               [ "the role";  Ident.to_string r.Ast.rname;
                 "declares no Peer_lost leg" ])))
    ~some:(fun (_e : Ast.expr) -> Ok ())
    r.Ast.peer_lost

let rec infer_decl (c : counters) (env : Env.t) (s : Subst.t) (d : Ast.decl)
  : (Env.t * Subst.t * counters, Error.t) result =
  match d with
  | Ast.DLet (x, e) ->
    let* (binds, s1) = infer_binding env s (Ast.PVar x) e in
    Ok (Env.extend_all binds env, s1, c)
  | Ast.DLetRec bs ->
    let* (binds, s1) = infer_group env s bs in
    Ok (Env.extend_all binds env, s1, c)
  | Ast.DImport i ->
    let* (declared, s1) = elab_scheme (Env.level env) s i.Ast.ity in
    let* () =
      Option.fold ~none:(Ok ())
        ~some:(fun ex ->
          if scheme_agrees declared ex then Ok ()
          else
            Error
              (Error.iface_mismatch
                 (String.concat " "
                    [ "the import";  Ident.to_string (Usage.source_name i.Ast.iname);
                      "declares a type the loaded interface does not export" ])))
        (Env.export (Usage.source_name i.Ast.iname) env) in
    Ok (Env.extend i.Ast.iname declared env,
        Subst.observe i.Ast.iname declared.Types.body s1, c)
  | Ast.DBudget (fs, inner) ->
    Result.map
      (fun (e2, s2, _inner) -> (e2, s2, c))
      (infer_decl (caps_of_annotation c fs) env s inner)
  | Ast.DProtocol p -> infer_proto c env s p
  | Ast.DRole r -> infer_role c env s r
  | Ast.DFreeze (_, e) ->
    let* (_t, s1) = infer_expr env s e in
    Ok (env, s1, c)
  | Ast.DManifest (_, es) -> infer_manifest c env s es
  | Ast.DMilestone (m, n, _) ->
    Error
      (Error.not_yet
         (String.concat " "
            [ "the declaration";  Ident.to_string n;  "arrives at";
              Ast.milestone_name m ]))

(* A protocol state elaborates every leg type and types its compensation
   when it declares one.  The refusal of a state with no compensation is
   the A4 check of brief 3.7, which joins this file in round B2. *)
and infer_proto (c : counters) (env : Env.t) (s : Subst.t) (p : Ast.proto)
  : (Env.t * Subst.t * counters, Error.t) result =
  let* s1 =
    List.fold_left
      (fun acc (st : Ast.pstate) ->
        let* store = acc in
        let* () = compensation_check p.Ast.pname st in
        let* store2 = infer_legs env store st.Ast.legs in
        infer_optional env store2 st.Ast.compensate)
      (Ok s) p.Ast.states in
  Ok (env, s1, c)

and infer_legs (env : Env.t) (s : Subst.t)
    (legs : (Label.t * Ast.ty * Ident.t) list) : (Subst.t, Error.t) result =
  List.fold_left
    (fun acc (_, t, _) ->
      let* store = acc in
      Result.map (fun (_sc, s2) -> s2) (elab_scheme (Env.level env) store t))
    (Ok s) legs

(* A role clause binds its parameters at fresh types and types its body.
   The refusal of a role with no Peer_lost leg is the A4 check of brief
   3.7, which joins this file in round B2. *)
and infer_role (c : counters) (env : Env.t) (s : Subst.t) (r : Ast.role)
  : (Env.t * Subst.t * counters, Error.t) result =
  let* s1 =
    List.fold_left
      (fun acc (_, params, body) ->
        let* store = acc in
        let (binds, store2) =
          List.fold_left
            (fun (bs, st) x ->
              let (t, st2) = Subst.fresh_type (Env.level env) st in
              (bs @ [ (x, Types.mono t) ], Subst.observe x t st2))
            ([], store) params in
        Result.map
          (fun (_t, s3) -> s3)
          (infer_expr (Env.extend_all binds env) store2 body))
      (Ok s) r.Ast.clauses in
  let* () = peer_lost_check r in
  let* s2 = infer_optional env s1 r.Ast.peer_lost in
  let* s3 = infer_optional env s2 r.Ast.abort in
  Ok (env, s3, c)

and infer_optional (env : Env.t) (s : Subst.t) (e : Ast.expr option)
  : (Subst.t, Error.t) result =
  Option.fold ~none:(Ok s)
    ~some:(fun x -> Result.map (fun (_t, s2) -> s2) (infer_expr env s x))
    e

(* A manifest is declarations only:  every field types as a value and the
   reconciler proof arrives at M3 (plan:42). *)
and infer_manifest (c : counters) (env : Env.t) (s : Subst.t)
    (es : Ast.mentry list) : (Env.t * Subst.t * counters, Error.t) result =
  let* s1 =
    List.fold_left
      (fun acc (m : Ast.mentry) ->
        let* store = acc in
        List.fold_left
          (fun acc2 (_, x) ->
            let* st = acc2 in
            Result.map (fun (_t, s2) -> s2) (infer_expr env st x))
          (Ok store) m.Ast.fields)
      (Ok s) es in
  Ok (env, s1, c)

(* --- the whole program -------------------------------------------------- *)

let infer_prog (env : Env.t) (s : Subst.t) (p : Ast.prog)
  : (Env.t * Subst.t * counters, Error.t) result =
  let* (e, store, c) = List.fold_left
    (fun acc d ->
      let* (e2, s2, c2) = acc in
      let* () = budget_check c2 d in
      infer_decl c2 e2 s2 d)
    (Ok (env, s, default_caps)) (Usage.scope_prog p) in
  let terms = List.map (fun (x, sc) -> (Usage.source_name x, sc)) e.Env.terms in
  Ok ({ e with Env.terms }, store, c)

(* --- the two twins of the use count pass (brief 3.5, D-B-9) ----------- *)

(* Observations retain inferred types for every lexical binder. *)
let affine_binders (env : Env.t) (s : Subst.t) (extra : Ident.t list)
  : Ident.t list =
  List.append
    (List.filter_map
       (fun ((x, sc) : Ident.t * Types.scheme) ->
         if affine_head (Subst.apply s sc.Types.body) then Some x else None)
       (Env.bindings env))
    (List.append (List.filter_map (fun (x, ty) ->
       if affine_head (Subst.apply s ty) then Some x else None)
       s.Subst.binder_types) extra)

let holds_name (xs : Ident.t list) (y : Ident.t) : bool =
  List.exists (Ident.equal y) xs

(* The CAPTURE twin runs FIRST, because a Many arrow that closes over an
   at most once value also raises the count of that value to Many, so the
   AFFINE twin would name the same program under the other error
   (D-B-50). *)
let capture_check (xs : Ident.t list) (captured : Ident.t list)
  : (unit, Error.t) result =
  Option.fold ~none:(Ok ())
    ~some:(fun (y : Ident.t) ->
      Error
        (Error.capture
           (String.concat " "
              [ "the arrow captures the at most once name";
                Ident.to_string (Usage.source_name y);
                "and it may run more than one time" ])))
    (List.find_opt (holds_name xs) captured)

let affine_check (xs : Ident.t list) (sc : Usage.scan) : (unit, Error.t) result
  =
  Option.fold ~none:(Ok ())
    ~some:(fun (y : Ident.t) ->
      Error
        (Error.affine
           (String.concat " "
              [ "the at most once name";  Ident.to_string (Usage.source_name y);
                "is used more than one time" ])))
    (List.find_opt
       (fun (y : Ident.t) ->
         Usage.is_many
           (Usage.join (Usage.get y sc.Usage.free) (Usage.get y sc.Usage.bound)))
       xs)

(* ONE walk of the program feeds both twins, so the pass keeps the linear
   cost of D-B-8. *)
let check_uses (env : Env.t) (s : Subst.t) (p : Ast.prog)
  : (unit, Error.t) result =
  let sc = Usage.scan_prog (Usage.scope_prog p) in
  let xs = affine_binders env s sc.Usage.affine in
  let* () = capture_check xs sc.Usage.captured in
  affine_check xs sc

(* The entry point the driver of brief 3.11 and the CHECK driver of brief
   3.13 read:  a checked program gives back the environment, whose
   bindings print in declaration order, and the store the schemes read. *)
let check (p : Ast.prog) : (Env.t * Subst.t, Error.t) result =
  let* (e, s, _c) = infer_prog Env.empty Subst.empty p in
  let* () = check_uses e s p in
  Ok (e, s)
