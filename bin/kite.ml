(* bin/kite.ml:  the driver of brief 3.11 (D-B-16), with the seven verbs
   of M0-PLAN.md:64.

     check FILE...      prints CHECK-OK files=N, exit 0, and takes the
                        repeatable option --iface PATH
     build FILE         parse, check, lower and emit, and prints
                        BUILD-OK file=PATH ir=PATH bytes=N
     iface FILE         writes FILE.coi and prints
                        IFACE-OK file=PATH exports=N
     run                prints run arrives at M1 and exits 2
     fmt FILE           prints the canonical form of surface/print.ml
     roundtrip FILE     prints ROUNDTRIP-OK file=PATH or ROUNDTRIP-FAIL
     version            prints kite 0.1.0 ocaml 5.3.0 dune 3.24.0

   No verb and an unknown verb both print the seven verb names and exit
   2.  The run verb runs NOTHING:  the machine arrives at M1
   (M0-PLAN.md:39).

   D-B-66:  a verb that names no file prints the verb names and exits 2,
   and never prints an OK line over an empty file list.  Reason:  brief
   3.13 makes the empty file list the vacuous pass trap of the CHECK
   driver, and the driver holds the same guard.

   The build verb writes the lowered IR BESIDE the source with the
   extension .kir (D-B-17).  That file is build output:  round B4 adds
   the one *.kir row to .gitignore (brief 3.19).

   Reading argv.  Sys.argv is an array and the house guard bans the
   Array module, with the one disclosed spelling Array.to_list Sys.argv
   (D-A-33).  dev/house.sh reads bin/ beside lib, surface and test, and
   the disclosed spelling rides the exemption that test/ rides, so any
   other use of the Array module here fails the gate. *)

module Coi = Kite_iface.Iface

let ( let* ) (x : ('a, Error.t) result) (f : 'a -> ('b, Error.t) result)
  : ('b, Error.t) result =
  Result.bind x f

let say (xs : string list) : unit = print_endline (String.concat " " xs)

let field (name : string) (n : int) : string =
  String.concat "" [ name;  string_of_int n ]

(* --- the file boundary ------------------------------------------------ *)

(* A path that reads:  it exists AND it is not a directory.  The && short
   circuits, so the directory test never sees a missing path.  Without
   the second test the open of a directory raises Sys_error and the
   process exits 2, a code the driver table of SPEC.md does not give to
   a verb that refuses its input. *)
let readable (path : string) : bool =
  Sys.file_exists path && not (Sys.is_directory path)

let read_file (path : string) : string option =
  if readable path then
    Some (In_channel.with_open_bin path In_channel.input_all)
  else None

let write_file (path : string) (text : string) : unit =
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc text)

let missing (path : string) : Error.t =
  Error.parse Error.nowhere
    (String.concat " " [ "the file";  path;  "does not read" ])

let parse_file (path : string) : (Ast.prog, Error.t) result =
  Option.fold ~none:(Error (missing path)) ~some:Parser.parse (read_file path)

let source_of (path : string) : string =
  Option.fold ~none:"" ~some:(fun (s : string) -> s) (read_file path)

let sibling (path : string) (ext : string) : string =
  String.concat "" [ Filename.remove_extension path;  ext ]

let module_of (path : string) : string =
  Filename.remove_extension (Filename.basename path)

(* --- the checker ------------------------------------------------------- *)

(* The entry point of lib/infer.ml over a LOADED environment, which is
   what the --iface option builds (D-B-15).  Infer.check is the same fold
   over the empty environment. *)
let check_prog (env0 : Env.t) (p : Ast.prog)
  : (Env.t * Subst.t, Error.t) result =
  let* (e, s, _c) = Infer.infer_prog env0 Subst.empty p in
  let* () = Infer.check_uses e s p in
  Ok (e, s)

let load_iface (acc : (Env.t, Error.t) result) (path : string)
  : (Env.t, Error.t) result =
  let* env = acc in
  Option.fold
    ~none:
      (Error
         (Error.iface_mismatch
            (String.concat " " [ "the interface";  path;  "does not read" ])))
    ~some:(fun (text : string) ->
      let* i = Coi.read text in
      Ok (Env.add_module (Coi.to_loaded i) env))
    (read_file path)

let checked (env0 : Env.t) (path : string) : (Env.t * Subst.t, Error.t) result =
  let* p = parse_file path in
  check_prog env0 p

(* --- the option list of the check verb --------------------------------- *)

let rec split_args (ifaces : string list) (files : string list)
  (args : string list) : string list * string list =
  match args with
  | [] -> (ifaces, files)
  | a :: rest ->
    if String.equal a "--iface" then
      match rest with
      | [] -> (ifaces, files)
      | p :: more -> split_args (List.append ifaces [ p ]) files more
    else split_args ifaces (List.append files [ a ]) rest

(* --- the verbs --------------------------------------------------------- *)

let report (e : Error.t) : unit = print_endline (Error.to_line e)

let verb_names : string list =
  [ "check";  "build";  "iface";  "run";  "fmt";  "roundtrip";  "version" ]

let usage () : int =
  let () = say (List.append [ "usage: kite" ] verb_names) in
  2

let verb_check (args : string list) : int =
  let (ifaces, files) = split_args [] [] args in
  if List.length files = 0 then usage ()
  else
    let start = List.fold_left load_iface (Ok Env.empty) ifaces in
    let errs =
      List.filter_map
        (fun (path : string) ->
          Result.fold ~ok:(fun (_r : Env.t * Subst.t) -> None)
            ~error:(fun (e : Error.t) -> Some e)
            (Result.bind start (fun (env : Env.t) -> checked env path)))
        files in
    if List.length errs = 0 then
      let () = say [ "CHECK-OK";  field "files=" (List.length files) ] in
      0
    else
      let () = List.iter report errs in
      1

let build_one (path : string) : int =
  Result.fold
    ~error:(fun (e : Error.t) ->
      let () = report e in
      1)
    ~ok:(fun (n : int) -> n)
    (let* p = parse_file path in
     let* (_env, _s) = check_prog Env.empty p in
     let* ir = Lower.prog p in
     let text = Pp.prog ir in
     let out = sibling path ".kir" in
     let () = write_file out text in
     let () =
       say
         [ "BUILD-OK";  String.concat "" [ "file=";  path ];
           String.concat "" [ "ir=";  out ];
           field "bytes=" (String.length text)
         ] in
     Ok 0)

let iface_one (path : string) : int =
  Result.fold
    ~error:(fun (e : Error.t) ->
      let () = report e in
      1)
    ~ok:(fun (n : int) -> n)
    (let source = source_of path in
     let* p = parse_file path in
     let* (env, s) = check_prog Env.empty p in
     let i = Coi.of_prog (module_of path) source p env s in
     let out = sibling path ".coi" in
     let () = write_file out (Coi.write i) in
     let () =
       say
         [ "IFACE-OK";  String.concat "" [ "file=";  path ];
           field "exports=" (Coi.exports i)
         ] in
     Ok 0)

let verb_run () : int =
  (* The run verb runs NOTHING at M0:  the machine arrives at M1
     (M0-PLAN.md:39, D-B-16). *)
  let () = say [ "run";  "arrives";  "at";  "M1" ] in
  2

let fmt_one (path : string) : int =
  Result.fold
    ~error:(fun (e : Error.t) ->
      let () = report e in
      1)
    ~ok:(fun (n : int) -> n)
    (let* p = parse_file path in
     let () = print_string (Print.prog p) in
     Ok 0)

(* The round trip of brief 3.13:  print, parse the print and print again,
   and the two prints agree byte for byte. *)
let roundtrip_one (path : string) : int =
  Result.fold
    ~error:(fun (e : Error.t) ->
      let () = report e in
      1)
    ~ok:(fun (n : int) -> n)
    (let* p = parse_file path in
     let once = Print.prog p in
     let* q = Parser.parse once in
     let twice = Print.prog q in
     if String.equal once twice then
       let () = say [ "ROUNDTRIP-OK";  String.concat "" [ "file=";  path ] ] in
       Ok 0
     else
       let () = say [ "ROUNDTRIP-FAIL";  String.concat "" [ "file=";  path ] ] in
       Ok 1)

let verb_version () : int =
  let () = say [ "kite";  "0.1.0";  "ocaml";  "5.3.0";  "dune";  "3.24.0" ] in
  0

(* A verb over one file:  the first argument is the file and a missing
   first argument prints the verb names (D-B-66).

   D-B-67:  a verb list rides a list match, never Option.fold over the
   total head accessor.  Reason:  the none branch of Option.fold is
   EAGER, so an Option.fold whose none branch PRINTS prints on every
   call. *)
let over_one (f : string -> int) (args : string list) : int =
  match args with
  | [] -> usage ()
  | a :: _rest -> f a

let dispatch (v : string) (args : string list) : int =
  match () with
  | () when String.equal v "check" -> verb_check args
  | () when String.equal v "build" -> over_one build_one args
  | () when String.equal v "iface" -> over_one iface_one args
  | () when String.equal v "run" -> verb_run ()
  | () when String.equal v "fmt" -> over_one fmt_one args
  | () when String.equal v "roundtrip" -> over_one roundtrip_one args
  | () when String.equal v "version" -> verb_version ()
  | () -> usage ()

let main () : int =
  match Array.to_list Sys.argv with
  | [] -> usage ()
  | _exe :: [] -> usage ()
  | _exe :: v :: rest -> dispatch v rest

let () = exit (main ())
