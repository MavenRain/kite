(* test/iface.ml:  the write-then-read round trip of the .coi text format
   (brief 3.9, D-B-13, D-B-14).  It builds as test/iface.exe.

   For every source path named on the command line the driver
     - parses and checks the file,
     - builds the interface with Iface.of_prog,
     - writes it with Iface.write,
     - reads that text back with Iface.read,
     - compares the two interfaces with Iface.equal, and
     - compares write (read (write i)) with write i byte for byte.

   It prints one IFACE-FAIL line per failure, then the tally line
     IFACE files=N ok=K fail=M
   and exits 0 when M is zero and N is above zero.  With no argument it
   prints IFACE-EMPTY and exits 2, so an empty file list never reads as a
   pass (brief 3.13).

   The library module rides behind its wrapper as Kite_iface.Iface,
   because this executable's own module is also called Iface (D-B-65). *)

module Coi = Kite_iface.Iface

let say (xs : string list) : unit = print_endline (String.concat " " xs)

let field (name : string) (n : int) : string =
  String.concat "" [ name;  string_of_int n ]

let read_file (path : string) : string option =
  if Sys.file_exists path then
    Some (In_channel.with_open_bin path In_channel.input_all)
  else None

let module_of (path : string) : string =
  Filename.remove_extension (Filename.basename path)

let ( let* ) (x : ('a, Error.t) result) (f : 'a -> ('b, Error.t) result)
  : ('b, Error.t) result =
  Result.bind x f

(* The one check over one source path.  It answers None on a pass and
   Some reason on a failure, so the fold below counts and prints. *)
let trip (path : string) : string option =
  Result.fold
    ~error:(fun (e : Error.t) -> Some (Error.to_line e))
    ~ok:(fun (r : string option) -> r)
    (Option.fold
       ~none:(Error (Error.iface_mismatch "the source file does not exist"))
       ~some:(fun (source : string) ->
         let* p = Parser.parse source in
         let* (env, s, _c) = Infer.infer_prog Env.empty Subst.empty p in
         let* () = Infer.check_uses env s p in
         let built = Coi.of_prog (module_of path) source p env s in
         let once = Coi.write built in
         let* got = Coi.read once in
         let twice = Coi.write got in
         let same_text = String.equal once twice in
         let same_value = Coi.equal built got in
         match () with
         | () when not same_value -> Ok (Some "the read interface differs")
         | () when not same_text -> Ok (Some "the second write differs")
         | () -> Ok None)
       (read_file path))

let step ((ok, bad) : int * int) (path : string) : int * int =
  Option.fold
    ~none:(ok + 1, bad)
    ~some:(fun (reason : string) ->
      let () = say [ "IFACE-FAIL";  path;  reason ] in
      (ok, bad + 1))
    (trip path)

(* Array.to_list Sys.argv is the one disclosed array spelling of the house
   rules (D-A-33). *)
let args () : string list =
  List.filteri (fun (i : int) (_a : string) -> i > 0) (Array.to_list Sys.argv)

let () =
  let paths = args () in
  if List.length paths = 0 then
    let () = print_endline "IFACE-EMPTY" in
    exit 2
  else
    let (ok, bad) = List.fold_left step (0, 0) paths in
    let () =
      say
        [ "IFACE";  field "files=" (List.length paths);  field "ok=" ok;
          field "fail=" bad
        ] in
    exit (if bad = 0 then 0 else 1)
