(* Semantic regressions for Stage B.  These probes supplement the frozen
   surface fixtures and check both refusals and valid neighboring cases. *)

module Coi = Kite_iface.Iface

let has_error (name : string) (r : ('a, Error.t) result) : bool =
  Result.fold ~ok:(fun _value -> false)
    ~error:(fun e -> String.equal (Error.name e) name) r

let check (source : string) : (Env.t * Subst.t, Error.t) result =
  Result.bind (Parser.parse source) Infer.check

let accepts (source : string) () : bool = Result.is_ok (check source)

let refuses (name : string) (source : string) () : bool =
  has_error name (check source)

(* has_error reads the error NAME alone, so a milestone case reads the
   printed LINE:  the text names the declared name and the milestone. *)
let error_line (r : ('a, Error.t) result) : string =
  Result.fold ~ok:(fun _value -> "") ~error:Error.to_line r

let refuses_line (tail : string) (source : string) () : bool =
  String.ends_with ~suffix:tail (error_line (check source))

let label : Label.t = Label.of_string "a"
let first : Label.occ = Label.occ_of_int 0

let row_occurs () : bool =
  let v : Types.tvar_row = { rid = 0; rlevel = 0 } in
  let (_r, s) = Subst.fresh_row 0 Subst.empty in
  let body = Types.RExt (label, first, Types.int_type, Types.RVar v) in
  has_error "OccursRow" (Unify.bind_row s v body)

let type_occurs () : bool =
  let v : Types.tvar = { id = 0; level = 0 } in
  let (_t, s) = Subst.fresh_type 0 Subst.empty in
  let body = Types.Arrow (Types.Var v, Types.Many, Types.int_type) in
  has_error "OccursType" (Unify.bind_type s v body)

let imported (provider : string) (consumer : string)
  : (Env.t * Subst.t, Error.t) result =
  Result.bind (Parser.parse provider) (fun p ->
    Result.bind (Infer.check p) (fun (provider_env, provider_store) ->
      let i = Coi.of_prog "Provider" provider p provider_env provider_store in
      Result.bind (Coi.read (Coi.write i)) (fun loaded ->
        Result.bind (Parser.parse consumer) (fun q ->
          let env = Env.add_module (Coi.to_loaded loaded) Env.empty in
          Result.bind (Infer.infer_prog env Subst.empty q) (fun (e, s, _c) ->
            Result.map (fun () -> (e, s)) (Infer.check_uses e s q))))))

let weak_export () : bool =
  has_error "IfaceMismatch"
    (imported "let weak = (fun x -> x) (fun y -> y)"
       "import weak : a -> a cost 3 deadline 5\nlet n = weak 1\nlet b = weak true")

let polymorphic_export () : bool =
  Result.is_ok
    (imported "let identity = fun x -> x"
       "import identity : a -> a cost 3 deadline 5\nlet n = identity 1\nlet b = identity true")

let specialized_export () : bool =
  Result.is_ok
    (imported "let identity = fun x -> x"
       "import identity : Int -> Int cost 3 deadline 5\nlet n = identity 1")

let shadowed_export () : bool =
  Result.is_ok
    (imported "let value = 1\nlet value = true"
       "import value : Bool cost 3 deadline 5\nlet n = if value then 1 else 2")

let obsolete_export () : bool =
  has_error "IfaceMismatch"
    (imported "let value = 1\nlet value = true"
       "import value : Int cost 3 deadline 5\nlet n = value + 1")

(* The .coi reader.  A file with no coi line, a version field that is not
   decimal and an occurrence index that is not decimal are all
   IfaceMismatch and never a silent load. *)
let coi_refuses (text : string) () : bool =
  has_error "IfaceMismatch" (Coi.read text)

let coi_header : string = "coi 1\nsource-sha256 aa\nmodule m\n"

let occurrence_line : string =
  String.concat ""
    [ coi_header; "val v : vars=0 rvars=0 { a ^ -1 : Int } usage=Zero\n";
      "end\n" ]

(* The round trip law holds for a module name that holds a space and for
   a module name that holds a control byte:  the name enters as one
   token, so the reader takes no extra word and no extra line. *)
let module_name_of (name : string) () : bool =
  let source = "let value = 1" in
  Result.fold ~ok:(fun (b : bool) -> b) ~error:(fun (_e : Error.t) -> false)
    (Result.bind (Parser.parse source) (fun (p : Ast.prog) ->
      Result.bind (Infer.check p) (fun ((env, s) : Env.t * Subst.t) ->
        let i = Coi.of_prog name source p env s in
        Result.map (fun (j : Coi.t) -> Coi.equal i j) (Coi.read (Coi.write i)))))

let cases : (string * (unit -> bool)) list =
  [ ("row-occurs", row_occurs);
    ("type-occurs", type_occurs);
    ("weak-alias", refuses "Mismatch"
       "let weak = (fun x -> x) (fun x -> x)\nlet alias = weak\nlet a = alias 1\nlet b = alias true");
    ("weak-rec-alias", refuses "Mismatch"
       "let rec weak = (fun x -> x) (fun x -> x)\nlet alias = weak\nlet a = alias 1\nlet b = alias true");
    ("value-polymorphism", accepts
       "let identity = fun x -> x\nlet alias = identity\nlet a = alias 1\nlet b = alias true");
    ("duplicate-row", accepts
       "let same = if true then { x = 1, x = false } else { x = 1, x = false }");
    ("duplicate-row-reordered", accepts
       "let same = if true then { x = 1, y = (), x = false } else { y = (), x = 1, x = false }");
    ("duplicate-row-mismatch", refuses "Mismatch"
       "let same = if true then { x = 1, x = false } else { x = false, x = 1 }");
    ("shared-row-cyclic", refuses "OccursRow"
       "let loop = fun r -> if true then { a = 1 | r } else { b = 1 | r }");
    ("shared-row-equal", accepts
       "let same = fun r -> if true then { a = 1 | r } else { a = 2 | r }");
    ("indexed-row", accepts
       "let second = fun r -> match r with | { a ^ 1 = x } -> x\nlet b = second { a = 1, a = false }\nlet result = if b then 1 else 2");
    ("indexed-row-missing", refuses "RowMissing"
       "let second = fun r -> match r with | { a ^ 1 = x } -> x\nlet b = second { a = 1 }");
    ("indexed-row-remainder", accepts
       "let split = fun r -> match r with | { a ^ 1 = x | rest } -> if x then rest.a + 1 else rest.a\nlet n = split { a = 1, a = false }");
    ("indexed-row-order", accepts
       "let ends = fun r -> match r with | { a ^ 2 = c, a ^ 0 = a } -> if c then a + 1 else a\nlet n = ends { a = 1, a = (), a = false }");
    ("indexed-variant", accepts
       "let n = match (< tag ^ 1 true >) with | < tag ^ 1 x > -> if x then 1 else 2");
    ("local-affine-alias", refuses "Affine"
       "let out = let f = (fun x -> x : Int -1> Int) in let g = f in { a = g 1, b = g 2 }");
    ("local-affine-alias-once", accepts
       "let out = let f = (fun x -> x : Int -1> Int) in let g = f in g 1");
    ("local-affine-pattern", refuses "Affine"
       "let out = let f = (fun x -> x : Int -1> Int) in let { a = g } = { a = f } in { a = g 1, b = g 2 }");
    ("local-affine-capture", refuses "Capture"
       "let out = let f = (fun x -> x : Int -1> Int) in let g = f in fun x -> g x");
    ("local-shadow", accepts
       "let a = let f = (fun x -> x : Int -1> Int) in f 1\nlet b = let f = (fun x -> x : Int -1> Int) in f 2");
    ("local-shadow-unrestricted", accepts
       "let a = let f = (fun x -> x : Int -1> Int) in f 1\nlet b = let f = fun x -> x in { a = f 1, b = f 2 }");
    ("top-shadow", accepts
       "let f = (fun x -> x : Int -1> Int)\nlet a = f 1\nlet f = (fun x -> x : Int -1> Int)\nlet b = f 2");
    ("weak-export", weak_export);
    ("polymorphic-export", polymorphic_export);
    ("specialized-export", specialized_export);
    ("shadowed-export", shadowed_export);
    ("obsolete-export", obsolete_export);
    ("coi-no-header", coi_refuses "end\n");
    ("coi-hex-version", coi_refuses
       "coi 0x1\nsource-sha256 aa\nmodule m\nend\n");
    ("coi-negative-occurrence", coi_refuses occurrence_line);
    ("coi-no-sha", coi_refuses "coi 1\nmodule m\nend\n");
    ("coi-no-module", coi_refuses
       (String.concat ""
          [ "coi 1\nsource-sha256 ";  String.make 64 'a';  "\nend\n" ]));
    ("module-name-space", module_name_of "my mod");
    ("module-name-control", module_name_of "my\nmod");
    ("annotation-tightens-alias", accepts
       "let g = { f = fun n -> n + 0 }\nlet h = match g with | { f = k } -> (k : Int -1> Int)");
    ("annotation-cannot-loosen", refuses "Mismatch"
       "let f = (fun x -> x : Int -1> Int)\nlet g = (f : Int -> Int)");
    ("pattern-repeats-name", accepts
       "let f = (fun p -> match p with | { a = u , b = u } -> u + u : { a : Int -1> Int , b : Int } -> Int)");
    ("budget-atoms", refuses_line "atoms over the printed budget of 2"
       "@budget { atoms = 2 , constraints = 32 }\nlet over = fun x y -> if x < y then x + y else x - y");
    ("budget-constraints",
       refuses_line "constraints over the printed budget of 0"
       "@budget { atoms = 64 , constraints = 0 }\nlet g = fun x y -> if x < y then x else y");
    ("milestone-m1", refuses_line "arrives at M1" "node n_x");
    ("milestone-m2", refuses_line "arrives at M2" "service s_x");
    ("milestone-m3", refuses_line "arrives at M3" "proof p_x");
    ("milestone-m4", refuses_line "arrives at M4" "fuel f_x");
    ("code-type", refuses "NotYet"
       "let staged = (q : Code [ a : Int , Int ])")
  ]

let args : string list =
  match Array.to_list Sys.argv with
  | [] -> []
  | _prog :: rest -> rest

let run () : unit =
  let chosen =
    if List.length args = 0 then cases
    else List.filter (fun (name, _test) -> List.mem name args) cases in
  let unknown = List.filter (fun name -> not (List.mem_assoc name cases)) args in
  let fails = List.filter_map (fun (name, test) ->
      if test () then None else Some name) chosen in
  let failures = List.append unknown fails in
  let () = List.iter (fun name ->
      print_endline (String.concat " " [ "REGRESS-FAIL"; name ])) failures in
  let n = List.length chosen in
  let bad = List.length failures in
  let () = print_endline (String.concat " "
      [ "REGRESS"; "tests=" ^ string_of_int n;
        "ok=" ^ string_of_int (n - List.length fails);
        "fail=" ^ string_of_int bad ]) in
  if n > 0 && bad = 0 then exit 0 else exit 1

let () = run ()
