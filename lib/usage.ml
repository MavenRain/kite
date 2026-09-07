(* lib/usage.ml:  lexical scoping and the bottom up use count pass.
   Sequential uses add, branches join, and arrow multiplicity scales
   captures.  The checker supplies inferred types for scoped binders. *)

type u =
  | Zero
  | Once
  | Many

let to_string (x : u) : string =
  match x with
  | Zero -> "Zero"
  | Once -> "Once"
  | Many -> "Many"

let plus (a : u) (b : u) : u =
  match (a, b) with
  | (Zero, x) -> x
  | (Once, Zero) -> Once
  | (Once, Once) -> Many
  | (Once, Many) -> Many
  | (Many, Zero) -> Many
  | (Many, Once) -> Many
  | (Many, Many) -> Many

let join (a : u) (b : u) : u =
  match (a, b) with
  | (Zero, Zero) -> Zero
  | (Zero, Once) -> Once
  | (Zero, Many) -> Many
  | (Once, Zero) -> Once
  | (Once, Once) -> Once
  | (Once, Many) -> Many
  | (Many, Zero) -> Many
  | (Many, Once) -> Many
  | (Many, Many) -> Many

let scale (m : Ast.mult) (x : u) : u =
  match (m, x) with
  | (Ast.AtMostOnce, y) -> y
  | (Ast.Many, Zero) -> Zero
  | (Ast.Many, Once) -> Many
  | (Ast.Many, Many) -> Many

(* --- the usage map -------------------------------------------------- *)

type map = (Ident.t * u) list

let get (x : Ident.t) (m : map) : u =
  Option.fold ~none:Zero
    ~some:(fun (v : u) -> v)
    (List.find_map (fun (y, v) -> if Ident.equal x y then Some v else None) m)

let has (x : Ident.t) (m : map) : bool =
  List.exists (fun (y, _v) -> Ident.equal x y) m

let merge (f : u -> u -> u) (a : map) (b : map) : map =
  List.append
    (List.map (fun (x, v) -> (x, f v (get x b))) a)
    (List.map (fun (y, v) -> (y, f Zero v))
       (List.filter (fun (y, _v) -> not (has y a)) b))

let seq (a : map) (b : map) : map = merge plus a b

let alt (a : map) (b : map) : map = merge join a b

let remove (xs : Ident.t list) (m : map) : map =
  List.filter (fun (y, _v) -> not (List.exists (Ident.equal y) xs)) m

let scale_map (m : Ast.mult) (u : map) : map =
  List.map (fun (x, v) -> (x, scale m v)) u

let observed (xs : Ident.t list) (inner : map) : map =
  List.map (fun x -> (x, get x inner)) xs

(* --- the small readers of the surface tree --------------------------- *)

let rec pat_vars (p : Ast.pat) : Ident.t list =
  match p with
  | Ast.PLit _ -> []
  | Ast.PVar x -> [ x ]
  | Ast.PWild -> []
  | Ast.PInj (_, _, q) -> pat_vars q
  | Ast.PRec (fs, tl) ->
    List.append
      (List.concat_map (fun (_l, _o, q) -> pat_vars q) fs)
      (Option.fold ~none:[] ~some:(fun x -> [ x ]) tl)

(* The parts of a lambda, taken with no partial accessor. *)
let lam_parts (e : Ast.expr) : (Ast.pat * Ast.expr) option =
  match e with
  | Ast.Lam (p, b) -> Some (p, b)
  | Ast.Lit _ -> None
  | Ast.Var _ -> None
  | Ast.App (_, _) -> None
  | Ast.Let (_, _, _) -> None
  | Ast.LetRec (_, _) -> None
  | Ast.If (_, _, _) -> None
  | Ast.Rec _ -> None
  | Ast.RecExt (_, _, _) -> None
  | Ast.RecRes (_, _) -> None
  | Ast.Sel (_, _) -> None
  | Ast.Inj (_, _, _) -> None
  | Ast.Match (_, _) -> None
  | Ast.Ann (_, _) -> None
  | Ast.Bin (_, _, _) -> None

let ann_parts (e : Ast.expr) : (Ast.expr * Ast.ty) option =
  match e with
  | Ast.Ann (x, t) -> Some (x, t)
  | Ast.Lit _ -> None
  | Ast.Var _ -> None
  | Ast.Lam (_, _) -> None
  | Ast.App (_, _) -> None
  | Ast.Let (_, _, _) -> None
  | Ast.LetRec (_, _) -> None
  | Ast.If (_, _, _) -> None
  | Ast.Rec _ -> None
  | Ast.RecExt (_, _, _) -> None
  | Ast.RecRes (_, _) -> None
  | Ast.Sel (_, _) -> None
  | Ast.Inj (_, _, _) -> None
  | Ast.Match (_, _) -> None
  | Ast.Bin (_, _, _) -> None

let ann_mult (t : Ast.ty) : Ast.mult =
  match t with
  | Ast.TArrow (_, m, _) -> m
  | Ast.TName _ -> Ast.Many
  | Ast.TRec _ -> Ast.Many
  | Ast.TVar _ -> Ast.Many
  | Ast.TCode (_, _) -> Ast.Many

let is_affine_ty (t : Ast.ty) : bool =
  match ann_mult t with
  | Ast.AtMostOnce -> true
  | Ast.Many -> false

let is_affine_value (e : Ast.expr) : bool =
  Option.fold ~none:false
    ~some:(fun ((_x, t) : Ast.expr * Ast.ty) -> is_affine_ty t)
    (ann_parts e)

let affine_of (p : Ast.pat) (v : Ast.expr) : Ident.t list =
  if is_affine_value v then pat_vars p else []

(* --- the one bottom up walk (D-B-8) ---------------------------------- *)

type scan =
  { free : map;
    bound : map;
    captured : Ident.t list;
    affine : Ident.t list
  }

let empty_scan : scan =
  { free = [];  bound = [];  captured = [];  affine = [] }

let both (f : u -> u -> u) (a : scan) (b : scan) : scan =
  { free = merge f a.free b.free;
    bound = seq a.bound b.bound;
    captured = List.append a.captured b.captured;
    affine = List.append a.affine b.affine
  }

let captured_of (m : Ast.mult) (inner : map) : Ident.t list =
  match m with
  | Ast.Many -> List.map (fun (x, _v) -> x) inner
  | Ast.AtMostOnce -> []

let rec scan_expr (e : Ast.expr) : scan =
  match e with
  | Ast.Lit _ -> empty_scan
  | Ast.Var x -> { empty_scan with free = [ (x, Once) ] }
  | Ast.Lam (p, b) -> scan_lam Ast.Many p b
  | Ast.App (f, x) -> both plus (scan_expr f) (scan_expr x)
  | Ast.Let (p, v, b) -> scan_let p v b
  | Ast.LetRec (bs, b) -> scan_letrec bs b
  | Ast.If (c, a, b) ->
    both plus (scan_expr c) (both join (scan_expr a) (scan_expr b))
  | Ast.Rec fs ->
    List.fold_left
      (fun acc (_l, x) -> both plus acc (scan_expr x))
      empty_scan fs
  | Ast.RecExt (_l, v, t) -> both plus (scan_expr v) (scan_expr t)
  | Ast.RecRes (t, _l) -> scan_expr t
  | Ast.Sel (t, _l) -> scan_expr t
  | Ast.Inj (_l, _o, x) -> scan_expr x
  | Ast.Match (s, arms) ->
    both plus (scan_expr s)
      (List.fold_left
         (fun acc (p, body) -> both join acc (scan_arm p body))
         empty_scan arms)
  | Ast.Ann (x, t) -> scan_ann t x
  | Ast.Bin (_op, a, b) -> both plus (scan_expr a) (scan_expr b)

and scan_lam (m : Ast.mult) (p : Ast.pat) (b : Ast.expr) : scan =
  let s = scan_expr b in
  let xs = pat_vars p in
  let inner = remove xs s.free in
  { free = scale_map m inner;
    bound = seq s.bound (observed xs s.free);
    captured = List.append s.captured (captured_of m inner);
    affine = s.affine
  }

and scan_arm (p : Ast.pat) (body : Ast.expr) : scan =
  let s = scan_expr body in
  let xs = pat_vars p in
  { s with free = remove xs s.free;  bound = seq s.bound (observed xs s.free) }

and scan_let (p : Ast.pat) (v : Ast.expr) (b : Ast.expr) : scan =
  let sv = scan_expr v in
  let sb = scan_expr b in
  let xs = pat_vars p in
  { free = seq sv.free (remove xs sb.free);
    bound = seq (seq sv.bound sb.bound) (observed xs sb.free);
    captured = List.append sv.captured sb.captured;
    affine = List.concat [ affine_of p v;  sv.affine;  sb.affine ]
  }

and scan_letrec (bs : Ast.bind list) (b : Ast.expr) : scan =
  let names = List.map (fun ((x, _v) : Ast.bind) -> x) bs in
  let sv =
    List.fold_left
      (fun acc ((_x, rhs) : Ast.bind) -> both plus acc (scan_expr rhs))
      empty_scan bs in
  let all = both plus sv (scan_expr b) in
  { free = remove names all.free;
    bound = seq all.bound (observed names all.free);
    captured = all.captured;
    affine =
      List.concat
        [ List.concat_map
            (fun ((x, rhs) : Ast.bind) -> affine_of (Ast.PVar x) rhs) bs;
          all.affine
        ]
  }

(* An annotation over a lambda writes the arrow bit, so the body scales
   by THAT bit and not by Many (D-B-40).  The two legs ride behind a
   thunk, because Option.fold takes its none leg eagerly. *)
and scan_ann (t : Ast.ty) (x : Ast.expr) : scan =
  (Option.fold
     ~none:(fun () -> scan_expr x)
     ~some:(fun ((p, b) : Ast.pat * Ast.expr) () -> scan_lam (ann_mult t) p b)
     (lam_parts x))
    ()

(* The signature of D-B-8:  ONE bottom up walk that returns a usage map. *)
let walk (e : Ast.expr) : (Ident.t * u) list = (scan_expr e).free

(* --- declarations and programs --------------------------------------- *)

(* Every expression a declaration holds, in declaration order. *)
let rec decl_exprs (d : Ast.decl) : Ast.expr list =
  match d with
  | Ast.DLet (_x, e) -> [ e ]
  | Ast.DLetRec bs -> List.map (fun ((_x, e) : Ast.bind) -> e) bs
  | Ast.DImport _ -> []
  | Ast.DBudget (_fs, inner) -> decl_exprs inner
  | Ast.DProtocol p ->
    List.filter_map (fun (st : Ast.pstate) -> st.Ast.compensate) p.Ast.states
  | Ast.DRole r ->
    List.concat
      [ List.map (fun (_l, _ps, e) -> e) r.Ast.clauses;
        Option.to_list r.Ast.peer_lost;
        Option.to_list r.Ast.abort
      ]
  | Ast.DFreeze (_ls, e) -> [ e ]
  | Ast.DManifest (_n, es) ->
    List.concat_map
      (fun (m : Ast.mentry) -> List.map (fun (_l, e) -> e) m.Ast.fields)
      es
  | Ast.DMilestone (_m, _n, _t) -> []

(* The names a declaration binds at the top level, in declaration order.
   A milestone form binds nothing, because the checker refuses it. *)
let rec decl_binders (d : Ast.decl) : Ident.t list =
  match d with
  | Ast.DLet (x, _e) -> [ x ]
  | Ast.DLetRec bs -> List.map (fun ((x, _e) : Ast.bind) -> x) bs
  | Ast.DImport i -> [ i.Ast.iname ]
  | Ast.DBudget (_fs, inner) -> decl_binders inner
  | Ast.DProtocol _ -> []
  | Ast.DRole _ -> []
  | Ast.DFreeze (_ls, _e) -> []
  | Ast.DManifest (_n, _es) -> []
  | Ast.DMilestone (_m, _n, _t) -> []

let scan_decl (d : Ast.decl) : scan =
  List.fold_left
    (fun acc e -> both plus acc (scan_expr e))
    empty_scan (decl_exprs d)

let scan_prog (p : Ast.prog) : scan =
  List.fold_left (fun acc d -> both plus acc (scan_decl d)) empty_scan p

let prog_binders (p : Ast.prog) : Ident.t list = List.concat_map decl_binders p

(* Private names identify lexical binders.  The surface cannot spell @. *)
let source_name (x : Ident.t) : Ident.t =
  match String.split_on_char '@' (Ident.to_string x) with
  | [] -> x
  | name :: _rest -> Ident.of_string name

let renamed names x = Option.value ~default:x (List.assoc_opt x names)

let bind_names names next xs =
  List.fold_left (fun (ns, n) x ->
    ((x, Ident.of_string (Ident.to_string x ^ "@" ^ string_of_int n)) :: ns,
     n + 1)) (names, next) xs

let map_scope f next xs =
  let (ys, n) = List.fold_left (fun (ys, n) x ->
    let (y, n2) = f n x in (y :: ys, n2)) ([], next) xs in
  (List.rev ys, n)

let numbered next x =
  Ident.of_string (Ident.to_string x ^ "@" ^ string_of_int next)

(* Every binder occurrence of a pattern takes its OWN lexical id, in the
   order pat_vars walks, so a pattern that binds one name two times gives
   two binders and one affine bit does not refuse the uses of the other.
   Each pair goes on the FRONT of the rename list, so the first assoc
   still names the LAST binder, which is the binder the body reads. *)
let rec scope_pat names next p =
  match p with
  | Ast.PLit _ | Ast.PWild -> (p, names, next)
  | Ast.PVar x ->
    let y = numbered next x in (Ast.PVar y, (x, y) :: names, next + 1)
  | Ast.PInj (l, o, q) ->
    let (q2, ns, n) = scope_pat names next q in (Ast.PInj (l, o, q2), ns, n)
  | Ast.PRec (fs, tail) ->
    let (rev, ns, n) =
      List.fold_left (fun (acc, ms, k) (l, o, q) ->
        let (q2, ms2, k2) = scope_pat ms k q in ((l, o, q2) :: acc, ms2, k2))
        ([], names, next) fs in
    let kept = List.rev rev in
    Option.fold ~none:(Ast.PRec (kept, None), ns, n)
      ~some:(fun x ->
        let y = numbered n x in
        (Ast.PRec (kept, Some y), (x, y) :: ns, n + 1)) tail

let rec scope_expr names next e =
  let sub n x = scope_expr names n x in
  let pair make a b =
    let (a2, n) = sub next a in
    let (b2, n2) = sub n b in (make a2 b2, n2) in
  match e with
  | Ast.Lit _ -> (e, next)
  | Ast.Var x -> (Ast.Var (renamed names x), next)
  | Ast.Lam (p, b) ->
    let (p2, ns, n) = scope_pat names next p in
    let (b2, n2) = scope_expr ns n b in (Ast.Lam (p2, b2), n2)
  | Ast.App (a, b) -> pair (fun x y -> Ast.App (x, y)) a b
  | Ast.Let (p, v, b) ->
    let (v2, n) = sub next v in
    let (p2, ns, n2) = scope_pat names n p in
    let (b2, n3) = scope_expr ns n2 b in (Ast.Let (p2, v2, b2), n3)
  | Ast.LetRec (bs, b) ->
    let (bs2, ns, n) = scope_group names next bs in
    let (b2, n2) = scope_expr ns n b in (Ast.LetRec (bs2, b2), n2)
  | Ast.If (c, a, b) ->
    let (c2, n) = sub next c in
    let (a2, n2) = sub n a in
    let (b2, n3) = sub n2 b in (Ast.If (c2, a2, b2), n3)
  | Ast.Rec fs ->
    let (fs2, n) = scope_fields names next fs in (Ast.Rec fs2, n)
  | Ast.RecExt (l, a, b) -> pair (fun x y -> Ast.RecExt (l, x, y)) a b
  | Ast.RecRes (a, l) -> let (a2, n) = sub next a in (Ast.RecRes (a2, l), n)
  | Ast.Sel (a, l) -> let (a2, n) = sub next a in (Ast.Sel (a2, l), n)
  | Ast.Inj (l, o, a) -> let (a2, n) = sub next a in (Ast.Inj (l, o, a2), n)
  | Ast.Match (s, arms) ->
    let (s2, n) = sub next s in
    let (as2, n2) = map_scope (fun n (p, b) ->
      let (p2, ns, n3) = scope_pat names n p in
      let (b2, n4) = scope_expr ns n3 b in ((p2, b2), n4)) n arms in
    (Ast.Match (s2, as2), n2)
  | Ast.Ann (a, t) -> let (a2, n) = sub next a in (Ast.Ann (a2, t), n)
  | Ast.Bin (op, a, b) -> pair (fun x y -> Ast.Bin (op, x, y)) a b

and scope_fields names next fs =
  map_scope (fun n (l, e) ->
    let (e2, n2) = scope_expr names n e in ((l, e2), n2)) next fs

and scope_group names next bs =
  let (ns, n) = bind_names names next (List.map fst bs) in
  let (bs2, n2) = map_scope (fun n (x, e) ->
    let (e2, n3) = scope_expr ns n e in ((renamed ns x, e2), n3)) n bs in
  (bs2, ns, n2)

let scope_optional names next e =
  Option.fold ~none:(None, next) ~some:(fun x ->
    let (x2, n) = scope_expr names next x in (Some x2, n)) e

let rec scope_decl names next d =
  match d with
  | Ast.DLet (x, e) ->
    let (e2, n) = scope_expr names next e in
    let (ns, n2) = bind_names names n [x] in
    (Ast.DLet (renamed ns x, e2), ns, n2)
  | Ast.DLetRec bs ->
    let (bs2, ns, n) = scope_group names next bs in (Ast.DLetRec bs2, ns, n)
  | Ast.DImport i ->
    let (ns, n) = bind_names names next [i.Ast.iname] in
    (Ast.DImport { i with Ast.iname = renamed ns i.Ast.iname }, ns, n)
  | Ast.DBudget (fs, inner) ->
    let (d2, ns, n) = scope_decl names next inner in (Ast.DBudget (fs, d2), ns, n)
  | Ast.DProtocol p ->
    let (states, n) = map_scope (fun n (st : Ast.pstate) ->
      let (compensate, n2) = scope_optional names n st.Ast.compensate in
      ({ st with Ast.compensate }, n2)) next p.Ast.states in
    (Ast.DProtocol { p with Ast.states }, names, n)
  | Ast.DRole r ->
    let (clauses, n) = map_scope (fun n (l, ps, e) ->
      let (ns, n2) = bind_names names n ps in
      let (e2, n3) = scope_expr ns n2 e in
      ((l, List.map (renamed ns) ps, e2), n3)) next r.Ast.clauses in
    let (peer_lost, n2) = scope_optional names n r.Ast.peer_lost in
    let (abort, n3) = scope_optional names n2 r.Ast.abort in
    (Ast.DRole { r with Ast.clauses; peer_lost; abort }, names, n3)
  | Ast.DFreeze (ls, e) ->
    let (e2, n) = scope_expr names next e in (Ast.DFreeze (ls, e2), names, n)
  | Ast.DManifest (x, es) ->
    let (es2, n) = map_scope (fun n (m : Ast.mentry) ->
      let (fields, n2) = scope_fields names n m.Ast.fields in
      ({ m with Ast.fields }, n2)) next es in
    (Ast.DManifest (x, es2), names, n)
  | Ast.DMilestone _ -> (d, names, next)

let scope_prog (p : Ast.prog) : Ast.prog =
  let (ds, _names, _next) = List.fold_left (fun (ds, names, next) d ->
    let (d2, ns, n) = scope_decl names next d in (d2 :: ds, ns, n))
      ([], [], 0) p in
  List.rev ds

(* The usage line of a top level name, which the .usage golden of brief
   3.13 reads and which the val line of a .coi file carries (D-B-13). *)
let prog_uses (p : Ast.prog) : map =
  let p = scope_prog p in
  let s = scan_prog p in
  List.map (fun x -> (source_name x, get x s.free)) (prog_binders p)

(* The reading the AFFINE twin of D-B-9 makes:  a count of Many over a
   binder that carries the at most once bit is the error. *)
let is_many (x : u) : bool =
  match x with
  | Zero -> false
  | Once -> false
  | Many -> true
