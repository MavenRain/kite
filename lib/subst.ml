(* lib/subst.ml:  the value-threaded store (brief 3.3, D-B-3).  The store
   holds the binding of a type variable id, the binding of a row variable
   id and the next free id, all as ONE immutable value, because lib/
   holds no cell to write into (dev/house.sh:131).  Every function that may
   bind returns the new store, and the caller passes it on.

   The fresh-id counter rides in the store for the same reason (D-B-34).

   A level is lowered by binding the old id to a FRESH variable at the
   lower level, so a resolution walk always ends:  the fresh id is
   unbound at the moment it is made (D-B-35). *)

type t =
  { types : (int * Types.t) list;
    rows : (int * Types.row) list;
    binder_types : (Ident.t * Types.t) list;
    next : int
  }

let empty : t = { types = [];  rows = [];  binder_types = [];  next = 0 }

let observe (x : Ident.t) (ty : Types.t) (s : t) : t =
  { s with binder_types = (x, ty) :: s.binder_types }

let fresh_id (s : t) : int * t = (s.next, { s with next = s.next + 1 })

let fresh_type (level : int) (s : t) : Types.t * t =
  let (n, s2) = fresh_id s in
  let v : Types.tvar = { id = n;  level } in
  (Types.Var v, s2)

let fresh_row (level : int) (s : t) : Types.row * t =
  let (n, s2) = fresh_id s in
  let v : Types.tvar_row = { rid = n;  rlevel = level } in
  (Types.RVar v, s2)

let lookup_type (id : int) (s : t) : Types.t option = List.assoc_opt id s.types

let lookup_row (id : int) (s : t) : Types.row option = List.assoc_opt id s.rows

let bind_type (id : int) (ty : Types.t) (s : t) : t =
  { s with types = (id, ty) :: s.types }

let bind_row (id : int) (r : Types.row) (s : t) : t =
  { s with rows = (id, r) :: s.rows }

(* The HEAD resolution:  a variable walks to its binding and stops at the
   first form that is not a bound variable. *)
let rec resolve_type (s : t) (ty : Types.t) : Types.t =
  match ty with
  | Types.Var v ->
    Option.fold ~none:ty ~some:(fun b -> resolve_type s b) (lookup_type v.id s)
  | Types.Con _ -> ty
  | Types.Arrow (_, _, _) -> ty
  | Types.Record _ -> ty
  | Types.Variant _ -> ty
  | Types.Code (_, _) -> ty

let rec resolve_row (s : t) (r : Types.row) : Types.row =
  match r with
  | Types.RVar v ->
    Option.fold ~none:r ~some:(fun b -> resolve_row s b) (lookup_row v.rid s)
  | Types.REmpty -> r
  | Types.RExt (_, _, _, _) -> r

(* The DEEP application:  every variable of the form walks to its
   binding. *)
let rec apply (s : t) (ty : Types.t) : Types.t =
  match resolve_type s ty with
  | Types.Var v -> Types.Var v
  | Types.Con c -> Types.Con c
  | Types.Arrow (a, m, b) -> Types.Arrow (apply s a, m, apply s b)
  | Types.Record r -> Types.Record (apply_row s r)
  | Types.Variant r -> Types.Variant (apply_row s r)
  | Types.Code (r, b) -> Types.Code (apply_row s r, apply s b)

and apply_row (s : t) (r : Types.row) : Types.row =
  let rec go seen row =
    match resolve_row s row with
    | Types.REmpty -> Types.REmpty
    | Types.RVar v -> Types.RVar v
    | Types.RExt (l, _, ty, rest) ->
      let key = Label.to_string l in
      let n = Option.value ~default:0 (List.assoc_opt key seen) in
      Types.RExt (l, Label.occ_of_int n, apply s ty,
        go ((key, n + 1) :: seen) rest) in
  go [] r

(* --- the free variables, for generalization by levels --------------- *)

let add_tvar (v : Types.tvar) (xs : Types.tvar list) : Types.tvar list =
  if List.exists (fun (w : Types.tvar) -> w.id = v.id) xs then xs else v :: xs

let add_rvar (v : Types.tvar_row) (xs : Types.tvar_row list) : Types.tvar_row list =
  if List.exists (fun (w : Types.tvar_row) -> w.rid = v.rid) xs then xs else v :: xs

let rec free_of_type (s : t) (acc : Types.tvar list * Types.tvar_row list)
    (ty : Types.t) : Types.tvar list * Types.tvar_row list =
  let (ts, rs) = acc in
  match resolve_type s ty with
  | Types.Var v -> (add_tvar v ts, rs)
  | Types.Con _ -> acc
  | Types.Arrow (a, _, b) -> free_of_type s (free_of_type s acc a) b
  | Types.Record r -> free_of_row s acc r
  | Types.Variant r -> free_of_row s acc r
  | Types.Code (r, b) -> free_of_type s (free_of_row s acc r) b

and free_of_row (s : t) (acc : Types.tvar list * Types.tvar_row list)
    (r : Types.row) : Types.tvar list * Types.tvar_row list =
  let (ts, rs) = acc in
  match resolve_row s r with
  | Types.REmpty -> acc
  | Types.RVar v -> (ts, add_rvar v rs)
  | Types.RExt (_, _, ty, rest) -> free_of_row s (free_of_type s acc ty) rest

(* --- level lowering -------------------------------------------------- *)

(* A variable that a binding carries out of its own level keeps the LOWER
   level, so generalization at the outer level does not close it.  The
   old id binds to a fresh variable at the lower level (D-B-35). *)
let rec lower_type (lvl : int) (ty : Types.t) (s : t) : t =
  match resolve_type s ty with
  | Types.Var v ->
    if v.level > lvl then
      (let (n, s2) = fresh_id s in
       let w : Types.tvar = { id = n;  level = lvl } in
       bind_type v.id (Types.Var w) s2)
    else s
  | Types.Con _ -> s
  | Types.Arrow (a, _, b) -> lower_type lvl b (lower_type lvl a s)
  | Types.Record r -> lower_row lvl r s
  | Types.Variant r -> lower_row lvl r s
  | Types.Code (r, b) -> lower_type lvl b (lower_row lvl r s)

and lower_row (lvl : int) (r : Types.row) (s : t) : t =
  match resolve_row s r with
  | Types.REmpty -> s
  | Types.RVar v ->
    if v.rlevel > lvl then
      (let (n, s2) = fresh_id s in
       let w : Types.tvar_row = { rid = n;  rlevel = lvl } in
       bind_row v.rid (Types.RVar w) s2)
    else s
  | Types.RExt (_, _, ty, rest) -> lower_row lvl rest (lower_type lvl ty s)

(* --- instantiation --------------------------------------------------- *)

(* substitute replaces a quantified id by the form the map gives it and
   leaves every other variable alone.  It is the ONE walk instantiation
   needs and it reads no binding, because a scheme body is already
   applied when generalization closes it (D-B-34). *)
let rec substitute (tm : (int * Types.t) list) (rm : (int * Types.row) list)
    (ty : Types.t) : Types.t =
  match ty with
  | Types.Var v -> Option.value ~default:ty (List.assoc_opt v.id tm)
  | Types.Con c -> Types.Con c
  | Types.Arrow (a, m, b) ->
    Types.Arrow (substitute tm rm a, m, substitute tm rm b)
  | Types.Record r -> Types.Record (substitute_row tm rm r)
  | Types.Variant r -> Types.Variant (substitute_row tm rm r)
  | Types.Code (r, b) -> Types.Code (substitute_row tm rm r, substitute tm rm b)

and substitute_row (tm : (int * Types.t) list) (rm : (int * Types.row) list)
    (r : Types.row) : Types.row =
  match r with
  | Types.REmpty -> Types.REmpty
  | Types.RVar v -> Option.value ~default:r (List.assoc_opt v.rid rm)
  | Types.RExt (l, o, ty, rest) ->
    Types.RExt (l, o, substitute tm rm ty, substitute_row tm rm rest)

(* A scheme instantiates at the level of the use site:  each quantified
   id takes a fresh variable of that level, so an outer generalization
   closes the fresh variable again only when it stays free. *)
let instantiate (level : int) (sc : Types.scheme) (s : t) : Types.t * t =
  let (tm, s1) =
    List.fold_left
      (fun (acc, st) id ->
        let (v, st2) = fresh_type level st in
        ((id, v) :: acc, st2))
      ([], s) sc.vars in
  let (rm, s2) =
    List.fold_left
      (fun (acc, st) id ->
        let (v, st2) = fresh_row level st in
        ((id, v) :: acc, st2))
      ([], s1) sc.rvars in
  (substitute tm rm sc.body, s2)
