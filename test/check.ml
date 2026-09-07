(* test/check.ml:  the CHECK gate as one executable (brief 3.13, D-B-18),
   written in the test/parse.ml shape.

   Usage:  check.exe PATH...

   With no path the program prints CHECK-EMPTY and exits 2, so an empty
   file list can never read as a pass.

   A path under test/pos parses, checks, and prints the scheme of EVERY
   top level binding, one line per binding in declaration order, against
   the sibling NAME.scheme.  A missing golden is a failure and never a
   skip.  When a sibling NAME.usage exists the printed usage map is
   compared the same way, one NAME count line per top level binder.

   A path under test/neg whose name starts with check-, and the
   milestones twin of D-B-19 item 14, run the other way:  the check has
   to fail and the FIRST WORD of the error line has to equal the whole
   content of the sibling NAME.err with its last newline removed.

   A path outside test/ checks clean and reads no golden, so the example
   spine of examples/ rides the same executable.

   Reading argv.  Sys.argv is an array and the house guard bans the Array
   module, with the one disclosed spelling Array.to_list Sys.argv that
   dev/house.sh allows in test/ alone (D-A-33).

   THE CANONICAL SCHEME PRINT (D-B-51).  A golden may not read a raw
   variable id, because an id counts every fresh variable the run made
   before it.  The print renames the variables of the scheme in order of
   first appearance:  a quantified type variable becomes a0, a1 and so
   on, a free type variable becomes t0, t1 and so on, a quantified row
   variable becomes b0 and a free row variable becomes r0.  The shape of
   the body is the shape of Types.to_string.  lib/pp.ml of round B3
   reproduces this print, because these goldens are the contract. *)

(* --- total string helpers ------------------------------------------ *)

let chars_of (s : string) : string list =
  List.map (fun c -> String.make 1 c) (List.of_seq (String.to_seq s))

let rec drop_lead_nl (cs : string list) : string list =
  match cs with
  | [] -> []
  | c :: rest -> if String.equal c "\n" then drop_lead_nl rest else c :: rest

(* The text with its trailing newline removed, taken with no index. *)
let chomp (s : string) : string =
  String.concat "" (List.rev (drop_lead_nl (List.rev (chars_of s))))

(* A many line report rides on ONE printed line, so a newline reads as a
   separator. *)
let flatten (s : string) : string =
  String.concat ""
    (List.map (fun c -> if String.equal c "\n" then " ; " else c) (chars_of s))

(* The first word of an error line, which is the golden form of a
   negative twin (brief 3.13). *)
let first_word (line : string) : string =
  match String.split_on_char ' ' line with
  | [] -> ""
  | w :: _rest -> w

let say (xs : string list) : unit = print_endline (String.concat " " xs)

let field (name : string) (n : int) : string =
  String.concat "" [ name;  string_of_int n ]

(* --- the file and its neighbours ----------------------------------- *)

let read_file (path : string) : string option =
  if Sys.file_exists path then
    Some (In_channel.with_open_bin path In_channel.input_all)
  else None

let sibling (path : string) (ext : string) : string =
  String.concat "" [ Filename.remove_extension path;  ext ]

let parent (path : string) : string =
  Filename.basename (Filename.dirname path)

let is_pos (path : string) : bool = String.equal (parent path) "pos"

let is_neg (path : string) : bool =
  String.equal (parent path) "neg"
  && (String.starts_with ~prefix:"check-" (Filename.basename path)
     || String.equal (Filename.basename path) "milestones.kite")

(* --- the canonical scheme print (D-B-51) ---------------------------- *)

type naming = { tmap : (int * string) list;  rmap : (int * string) list }

let no_naming : naming = { tmap = [];  rmap = [] }

let quantified (ids : int list) (id : int) : bool =
  List.exists (fun i -> i = id) ids

let next_name (pairs : (int * string) list) (prefix : string) : string =
  let taken =
    List.length
      (List.filter (fun (_i, s) -> String.starts_with ~prefix s) pairs) in
  String.concat "" [ prefix;  string_of_int taken ]

let add_t (qs : int list) (n : naming) (id : int) : naming =
  if List.mem_assoc id n.tmap then n
  else
    let prefix = if quantified qs id then "a" else "t" in
    { n with tmap = List.append n.tmap [ (id, next_name n.tmap prefix) ] }

let add_r (rs : int list) (n : naming) (id : int) : naming =
  if List.mem_assoc id n.rmap then n
  else
    let prefix = if quantified rs id then "b" else "r" in
    { n with rmap = List.append n.rmap [ (id, next_name n.rmap prefix) ] }

let named (pairs : (int * string) list) (id : int) : string =
  Option.fold ~none:"?" ~some:(fun (s : string) -> s) (List.assoc_opt id pairs)

(* The variables of a body, in order of first appearance. *)
let rec collect (qs : int list) (rs : int list) (n : naming) (ty : Types.t)
  : naming =
  match ty with
  | Types.Var v -> add_t qs n v.Types.id
  | Types.Con _ -> n
  | Types.Arrow (a, _m, b) -> collect qs rs (collect qs rs n a) b
  | Types.Record r -> collect_row qs rs n r
  | Types.Variant r -> collect_row qs rs n r
  | Types.Code (r, b) -> collect qs rs (collect_row qs rs n r) b

and collect_row (qs : int list) (rs : int list) (n : naming) (r : Types.row)
  : naming =
  match r with
  | Types.REmpty -> n
  | Types.RVar v -> add_r rs n v.Types.rid
  | Types.RExt (_l, _o, ty, rest) ->
    collect_row qs rs (collect qs rs n ty) rest

let rec show (n : naming) (ty : Types.t) : string =
  match ty with
  | Types.Var v -> named n.tmap v.Types.id
  | Types.Con c -> c
  | Types.Arrow (a, m, b) ->
    String.concat " "
      [ "(";  show n a;  Types.mult_text m;  show n b;  ")" ]
  | Types.Record r -> String.concat " " [ "{";  show_row n r;  "}" ]
  | Types.Variant r -> String.concat " " [ "<";  show_row n r;  ">" ]
  | Types.Code (r, b) ->
    String.concat " " [ "Code";  "[";  show_row n r;  ",";  show n b;  "]" ]

and show_row (n : naming) (r : Types.row) : string =
  match r with
  | Types.REmpty -> ""
  | Types.RVar v -> String.concat "" [ "| ";  named n.rmap v.Types.rid ]
  | Types.RExt (l, o, ty, rest) ->
    let head =
      String.concat " "
        [ Label.to_string l;  "^";  string_of_int (Label.occ_to_int o);  ":";
          show n ty ] in
    let tl = show_row n rest in
    if String.equal tl "" then head
    else if String.starts_with ~prefix:"|" tl then String.concat " " [ head;  tl ]
    else String.concat " " [ head;  ",";  tl ]

let scheme_line (x : Ident.t) (sc : Types.scheme) : string =
  let n = collect sc.Types.vars sc.Types.rvars no_naming sc.Types.body in
  String.concat " "
    [ Ident.to_string x;  ":";
      field "vars=" (List.length sc.Types.vars);
      field "rvars=" (List.length sc.Types.rvars);
      show n sc.Types.body
    ]

(* --- the printed reports ------------------------------------------- *)

let applied (s : Subst.t) (sc : Types.scheme) : Types.scheme =
  { sc with Types.body = Subst.apply s sc.Types.body }

let scheme_text (env : Env.t) (s : Subst.t) : string =
  String.concat "\n"
    (List.map
       (fun ((x, sc) : Ident.t * Types.scheme) -> scheme_line x (applied s sc))
       (Env.bindings env))

let usage_text (p : Ast.prog) : string =
  String.concat "\n"
    (List.map
       (fun ((x, u) : Ident.t * Usage.u) ->
         String.concat " " [ Ident.to_string x;  Usage.to_string u ])
       (Usage.prog_uses p))

(* --- the goldens ---------------------------------------------------- *)

let differs (what : string) (got : string) (want : string) : string list =
  [ String.concat " "
      [ what;  String.concat "" [ "got=[";  flatten got;  "]" ];
        String.concat "" [ "want=[";  flatten want;  "]" ]
      ]
  ]

let scheme_golden (path : string) (got : string) : string list =
  Option.fold
    ~none:[ "the golden .scheme does not exist" ]
    ~some:(fun (g : string) ->
      if String.equal (chomp g) (chomp got) then []
      else differs "the printed scheme differs from the golden" got (chomp g))
    (read_file (sibling path ".scheme"))

(* The usage golden is optional:  a positive with no .usage sidecar reads
   its schemes alone (brief 3.13). *)
let usage_golden (path : string) (got : string) : string list =
  Option.fold ~none:[]
    ~some:(fun (g : string) ->
      if String.equal (chomp g) (chomp got) then []
      else differs "the printed usage map differs from the golden" got (chomp g))
    (read_file (sibling path ".usage"))

let neg_golden (path : string) (line : string) : string list =
  Option.fold
    ~none:[ "the golden .err does not exist" ]
    ~some:(fun (g : string) ->
      if String.equal (chomp g) (first_word line) then []
      else
        [ String.concat " "
            [ "the golden .err says";  chomp g;  "and the error says";
              first_word line
            ]
        ])
    (read_file (sibling path ".err"))

let neg_clean (path : string) : string list =
  [ String.concat " "
      [ "the file checks clean and the golden names";
        Option.fold ~none:"nothing" ~some:chomp (read_file (sibling path ".err"))
      ]
  ]

(* --- the checks ----------------------------------------------------- *)

let goldens (path : string) (p : Ast.prog) (env : Env.t) (s : Subst.t)
  : string list =
  if is_pos path then
    List.append
      (scheme_golden path (scheme_text env s))
      (usage_golden path (usage_text p))
  else []

let pos_checks (path : string) (p : Ast.prog) : string list =
  Result.fold
    ~error:(fun e ->
      [ String.concat " " [ "the check failed:";  Error.to_line e ] ])
    ~ok:(fun ((env, s) : Env.t * Subst.t) -> goldens path p env s)
    (Infer.check p)

let neg_checks (path : string) (p : Ast.prog) : string list =
  Result.fold
    ~error:(fun e -> neg_golden path (Error.to_line e))
    ~ok:(fun (_r : Env.t * Subst.t) -> neg_clean path)
    (Infer.check p)

let parsed (path : string) (p : Ast.prog) : string list =
  if is_neg path then neg_checks path p else pos_checks path p

(* A negative twin that fails at the PARSE reads its golden too, so a
   twin never passes by a parse error the golden does not name. *)
let on_parse_error (path : string) (e : Error.t) : string list =
  if is_neg path then neg_golden path (Error.to_line e)
  else [ String.concat " " [ "the parse failed:";  Error.to_line e ] ]

let check (path : string) : string list =
  Option.fold
    ~none:[ "the file does not exist" ]
    ~some:(fun (text : string) ->
      Result.fold
        ~error:(fun e -> on_parse_error path e)
        ~ok:(fun (p : Ast.prog) -> parsed path p)
        (Parser.parse text))
    (read_file path)

(* --- the run -------------------------------------------------------- *)

let report ((path, fails) : string * string list) : unit =
  List.iter (fun r -> say [ "CHECK-FAIL";  path;  r ]) fails

let count (f : string -> bool) (paths : string list) : int =
  List.length (List.filter f paths)

let run (paths : string list) : unit =
  let rows = List.map (fun p -> (p, check p)) paths in
  let () = List.iter report rows in
  let n = List.length rows in
  let m =
    List.length (List.filter (fun (_p, fs) -> List.length fs > 0) rows) in
  let () =
    say
      [ "CHECK";
        field "files=" n;
        field "pos=" (count is_pos paths);
        field "neg=" (count is_neg paths);
        field "ok=" (n - m);
        field "fail=" m
      ] in
  if m = 0 && n > 0 then exit 0 else exit 1

(* The disclosed spelling of D-A-33.  argv rides through one total
   conversion and the program name is dropped by a list match. *)
let args () : string list =
  match Array.to_list Sys.argv with
  | [] -> []
  | _prog :: rest -> rest

let () =
  let paths = args () in
  if List.length paths = 0 then
    let () = print_endline "CHECK-EMPTY" in
    exit 2
  else run paths
