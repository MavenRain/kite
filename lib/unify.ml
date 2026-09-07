(* Unification (D-B-6): separate type and row occurs checks inspect the
   applied form across nested types and rows.  Arrows also require equal
   multiplicities.  Levels lower before a variable binds (D-B-35). *)

(* --- the type occurs check ------------------------------------------ *)

let rec occurs_type (id : int) (ty : Types.t) : bool =
  match ty with
  | Types.Var v -> v.id = id
  | Types.Con _ -> false
  | Types.Arrow (a, _, b) -> occurs_type id a || occurs_type id b
  | Types.Record r -> occurs_type_in_row id r
  | Types.Variant r -> occurs_type_in_row id r
  | Types.Code (r, b) -> occurs_type_in_row id r || occurs_type id b

and occurs_type_in_row (id : int) (r : Types.row) : bool =
  match r with
  | Types.REmpty -> false
  | Types.RVar _ -> false
  | Types.RExt (_, _, ty, rest) -> occurs_type id ty || occurs_type_in_row id rest

(* --- the row occurs check ------------------------------------------- *)

let rec occurs_row (id : int) (r : Types.row) : bool =
  match r with
  | Types.REmpty -> false
  | Types.RVar v -> v.rid = id
  | Types.RExt (_, _, ty, rest) -> occurs_row_in_type id ty || occurs_row id rest

and occurs_row_in_type (id : int) (ty : Types.t) : bool =
  match ty with
  | Types.Var _ -> false
  | Types.Con _ -> false
  | Types.Arrow (a, _, b) -> occurs_row_in_type id a || occurs_row_in_type id b
  | Types.Record r -> occurs_row id r
  | Types.Variant r -> occurs_row id r
  | Types.Code (r, b) -> occurs_row id r || occurs_row_in_type id b

(* --- the two messages ----------------------------------------------- *)

let mismatch (a : Types.t) (b : Types.t) : (Subst.t, Error.t) result =
  Error
    (Error.mismatch
       (String.concat " "
          [ "the type";  Types.to_string a;  "does not unify with the type";
            Types.to_string b ]))

(* --- the two binds -------------------------------------------------- *)

let bind_type (s : Subst.t) (v : Types.tvar) (ty : Types.t)
  : (Subst.t, Error.t) result =
  let body = Subst.apply s ty in
  if occurs_type v.id body then
    Error
      (Error.occurs_type
         (String.concat " "
            [ "the type variable t";  string_of_int v.id;  "occurs in the type";
              Types.to_string body ]))
  else Ok (Subst.bind_type v.id body (Subst.lower_type v.level body s))

let bind_row (s : Subst.t) (v : Types.tvar_row) (r : Types.row)
  : (Subst.t, Error.t) result =
  let body = Subst.apply_row s r in
  if occurs_row v.rid body then
    Error
      (Error.occurs_row
         (String.concat " "
            [ "the row variable r";  string_of_int v.rid;  "occurs in the row";
              Types.row_to_string body ]))
  else Ok (Subst.bind_row v.rid body (Subst.lower_row v.rlevel body s))

(* --- unification ----------------------------------------------------- *)

let rec row_tail (s : Subst.t) (r : Types.row) : int option =
  match Subst.resolve_row s r with
  | Types.REmpty -> None
  | Types.RVar v -> Some v.rid
  | Types.RExt (_, _, _, rest) -> row_tail s rest

let rec unify (s : Subst.t) (a : Types.t) (b : Types.t)
  : (Subst.t, Error.t) result =
  let ra = Subst.resolve_type s a in
  let rb = Subst.resolve_type s b in
  match (ra, rb) with
  | (Types.Var v, Types.Var w) ->
    if v.id = w.id then Ok s else bind_type s v rb
  | ( Types.Var v,
      ( Types.Con _ | Types.Arrow _ | Types.Record _ | Types.Variant _
      | Types.Code _ ) ) ->
    bind_type s v rb
  | ( ( Types.Con _ | Types.Arrow _ | Types.Record _ | Types.Variant _
      | Types.Code _ ),
      Types.Var w ) ->
    bind_type s w ra
  | (Types.Con c, Types.Con d) ->
    if String.equal c d then Ok s else mismatch ra rb
  | (Types.Arrow (a1, m1, b1), Types.Arrow (a2, m2, b2)) ->
    if Types.mult_equal m1 m2 then
      Result.bind (unify s a1 a2) (fun s2 -> unify s2 b1 b2)
    else mismatch ra rb
  | (Types.Record r1, Types.Record r2) -> unify_row s r1 r2
  | (Types.Variant r1, Types.Variant r2) -> unify_row s r1 r2
  | (Types.Code (r1, t1), Types.Code (r2, t2)) ->
    Result.bind (unify_row s r1 r2) (fun s2 -> unify s2 t1 t2)
  | ( ( Types.Con _ | Types.Arrow _ | Types.Record _ | Types.Variant _
      | Types.Code _ ),
      ( Types.Con _ | Types.Arrow _ | Types.Record _ | Types.Variant _
      | Types.Code _ ) ) ->
    mismatch ra rb

(* Row indices are positional, so each remaining head matches the first
   occurrence in the remaining right row. *)
and unify_row (s : Subst.t) (a : Types.row) (b : Types.row)
  : (Subst.t, Error.t) result =
  let ra = Subst.resolve_row s a in
  let rb = Subst.resolve_row s b in
  match (ra, rb) with
  | (Types.REmpty, Types.REmpty) -> Ok s
  | (Types.RVar v, Types.RVar w) ->
    if v.rid = w.rid then Ok s else bind_row s v rb
  | (Types.RVar v, (Types.REmpty | Types.RExt _)) -> bind_row s v rb
  | ((Types.REmpty | Types.RExt _), Types.RVar w) -> bind_row s w ra
  | (Types.REmpty, Types.RExt (l, _, _, _))
  | (Types.RExt (l, _, _, _), Types.REmpty) ->
    Result.map (fun (_, _, st) -> st)
      (Row.rewrite s l (Label.occ_of_int 0) Types.REmpty)
  | (Types.RExt (l, _, ty, rest), Types.RExt _) ->
    let tail = row_tail s ra in
    Result.bind (Row.rewrite s l (Label.occ_of_int 0) rb)
      (fun (ty2, rest2, s2) ->
        (* Growing a shared tail makes the residual equation recur with
           a fresh shared tail.  Reject it before recursing. *)
        if Option.fold ~none:false
            ~some:(fun id -> Option.is_some (Subst.lookup_row id s2)) tail then
          Error (Error.occurs_row "row rewriting would extend its own tail")
        else Result.bind (unify s2 ty ty2)
            (fun s3 -> unify_row s3 rest rest2))
