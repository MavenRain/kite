(* Scoped row operations (D-B-5).  Occurrences are positions among fields
   with the same label.  Explicit indices elaborate to dense rows before
   unification, and every operation threads the immutable store. *)

(* Every entry of the label l moves up by one occurrence, which is what
   an extension in front of that label does. *)
let bump (l : Label.t) (r : Types.row) : Types.row =
  let rec go (r2 : Types.row) : Types.row =
    match r2 with
    | Types.REmpty -> Types.REmpty
    | Types.RVar v -> Types.RVar v
    | Types.RExt (l2, o, ty, rest) ->
      let o2 =
        if Label.equal l l2 then Label.occ_of_int (Label.occ_to_int o + 1) else o in
      Types.RExt (l2, o2, ty, go rest) in
  go r

(* Extension is RExt applied:  the new field is occurrence zero and the
   old entries of that label shift up, so the new field shadows them. *)
let extend (l : Label.t) (ty : Types.t) (r : Types.row) : Types.row =
  Types.RExt (l, Label.occ_of_int 0, ty, bump l r)

(* The canonical numbering:  each entry takes its position among the
   entries of its own label.  A row variable tail carries no entry, so
   the walk stops there. *)
let reindex (r : Types.row) : Types.row =
  let rec go (seen : (string * int) list) (r2 : Types.row) : Types.row =
    match r2 with
    | Types.REmpty -> Types.REmpty
    | Types.RVar v -> Types.RVar v
    | Types.RExt (l, _, ty, rest) ->
      let key = Label.to_string l in
      let n = Option.value ~default:0 (List.assoc_opt key seen) in
      Types.RExt (l, Label.occ_of_int n, ty, go ((key, n + 1) :: seen) rest) in
  go [] r

(* A record literal writes its fields in order and takes its occurrence
   indices from that order. *)
let of_fields (fs : (Label.t * Types.t) list) (tail : Types.row) : Types.row =
  reindex
    (List.fold_right
       (fun (l, ty) acc -> Types.RExt (l, Label.occ_of_int 0, ty, acc))
       fs tail)

(* Missing positions in an indexed pattern are fresh fields.  They stay
   in the pattern's remainder, since the pattern did not consume them. *)
let indexed_fields (lvl : int) (s : Subst.t)
    (fs : (Label.t * Label.occ * Types.t) list) (tail : Types.row)
  : Types.row * Types.row * Subst.t =
  let ordered = List.sort
      (fun (l, o, _) (l2, o2, _) ->
        let c = String.compare (Label.to_string l) (Label.to_string l2) in
        if c = 0 then Int.compare (Label.occ_to_int o) (Label.occ_to_int o2)
        else c) fs in
  let rec go seen st fields =
    match fields with
    | [] -> (tail, tail, st)
    | (l, o, ty) :: more ->
      let key = Label.to_string l in
      let n = Option.value ~default:0 (List.assoc_opt key seen) in
      let seen2 = (key, n + 1) :: seen in
      let index = Label.occ_of_int n in
      if n < Label.occ_to_int o then
        let (missing, st2) = Subst.fresh_type lvl st in
        let (row, rest, st3) = go seen2 st2 fields in
        (Types.RExt (l, index, missing, row),
         Types.RExt (l, index, missing, rest), st3)
      else
        let (row, rest, st2) = go seen2 st more in
        (Types.RExt (l, index, ty, row), rest, st2) in
  let (row, rest, s2) = go [] s ordered in
  (row, reindex rest, s2)

(* A record PATTERN writes its own occurrence indices, so the same label
   at the same index twice is RowDuplicate (brief 3.8). *)
let no_duplicate (fs : (Label.t * Label.occ) list) : (unit, Error.t) result =
  let rec go (seen : string list) (rest : (Label.t * Label.occ) list)
    : (unit, Error.t) result =
    match rest with
    | [] -> Ok ()
    | (l, o) :: more ->
      let key =
        String.concat "^" [ Label.to_string l;  string_of_int (Label.occ_to_int o) ] in
      if List.exists (String.equal key) seen then
        Error
          (Error.row_duplicate
             (String.concat " "
                [ "the label";  Label.to_string l;  "repeats at occurrence";
                  string_of_int (Label.occ_to_int o) ]))
      else go (key :: seen) more in
  go [] fs

(* The solver.  seen counts the entries of the label already passed, so
   the requested occurrence is the position among them, and the scan
   stops at the FIRST entry that reaches it (D-B-5). *)
let rewrite (s : Subst.t) (l : Label.t) (o : Label.occ) (r : Types.row)
  : (Types.t * Types.row * Subst.t, Error.t) result =
  let want = Label.occ_to_int o in
  let rec go (st : Subst.t) (seen : int) (r2 : Types.row)
    : (Types.t * Types.row * Subst.t, Error.t) result =
    match Subst.resolve_row st r2 with
    | Types.REmpty ->
      Error
        (Error.row_missing
           (String.concat " "
              [ "the closed row holds no label";  Label.to_string l;
                "at occurrence";  string_of_int want ]))
    | Types.RVar v ->
      let (ty, st2) = Subst.fresh_type v.rlevel st in
      let (tail, st3) = Subst.fresh_row v.rlevel st2 in
      let grown = Types.RExt (l, Label.occ_of_int seen, ty, tail) in
      let st4 = Subst.bind_row v.rid grown st3 in
      go st4 seen grown
    | Types.RExt (l2, o2, ty, rest) ->
      let same = Label.equal l l2 in
      let hit = same && seen = want in
      let seen2 = if same then seen + 1 else seen in
      if hit then Ok (ty, rest, st)
      else
        Result.map
          (fun (t2, rest2, st2) -> (t2, Types.RExt (l2, o2, ty, rest2), st2))
          (go st seen2 rest) in
  if want < 0 then Error (Error.row_missing "row occurrence indices must be nonnegative")
  else Result.map (fun (ty, rest, st) -> (ty, reindex rest, st)) (go s 0 r)

(* Selection reads the FIRST occurrence and keeps the head. *)
let select (s : Subst.t) (l : Label.t) (r : Types.row)
  : (Types.t * Subst.t, Error.t) result =
  Result.map (fun (ty, _, st) -> (ty, st)) (rewrite s l (Label.occ_of_int 0) r)

(* Restriction removes the FIRST occurrence and drops the head, and the
   entries of that label that stay move down by one (D-B-45). *)
let restrict (s : Subst.t) (l : Label.t) (r : Types.row)
  : (Types.row * Subst.t, Error.t) result =
  Result.map
    (fun (_, rest, st) -> (reindex rest, st))
    (rewrite s l (Label.occ_of_int 0) r)
