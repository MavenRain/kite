(* test/parse.ml:  the PARSE gate as one executable (brief 3.7, D-A-16).

   Usage:  parse.exe PATH...

   With no path the program prints PARSE-EMPTY and exits 2, so an empty
   file list can never read as a pass.  For each path it reads the text,
   parses it to p1, prints s1, parses s1 to p2 and prints s2, and it
   checks that p1 and p2 agree, that s1 and s2 agree, which is the
   round-trip law of the plan, and that the golden beside the fixture
   agrees with s1.  A missing golden is a failure and never a skip.

   A path under test/neg/ whose name starts with parse- runs the other
   way:  the parse has to fail, and the first two words of the error
   line have to equal the golden NAME.err with its last newline
   removed.

   A path outside test/ runs the two round-trip checks alone, so the
   example spine of examples/ can ride the same executable.

   Reading argv.  Sys.argv is an array, and the house guard bans the
   Array module in lib/ and surface/.  test/ holds to the same rule with
   one disclosed spelling, Array.to_list Sys.argv, which house.sh names
   and allows in test/ alone (D-A-33).  Every other read here is total. *)

(* --- total string helpers ------------------------------------------ *)

let chars_of (s : string) : string list =
  List.map (fun c -> String.make 1 c) (List.of_seq (String.to_seq s))

(* The leading newlines of a reversed character list, dropped. *)
let rec drop_lead_nl (cs : string list) : string list =
  match cs with
  | [] -> []
  | c :: rest -> if String.equal c "\n" then drop_lead_nl rest else c :: rest

(* The text with its trailing newline removed, taken with no index and
   no sub. *)
let chomp (s : string) : string =
  String.concat "" (List.rev (drop_lead_nl (List.rev (chars_of s))))

(* The first two words of a line, which is the golden form of an error
   (brief 3.7). *)
let first_two (line : string) : string =
  let ws = String.split_on_char ' ' line in
  let two =
    match ws with
    | [] -> []
    | [ a ] -> [ a ]
    | a :: b :: _rest -> [ a;  b ]
  in
  String.concat " " two

let say (xs : string list) : unit = print_endline (String.concat " " xs)

(* --- the file and its neighbours ----------------------------------- *)

let read_file (path : string) : string option =
  if Sys.file_exists path then
    Some (In_channel.with_open_bin path In_channel.input_all)
  else None

let sibling (path : string) (ext : string) : string =
  String.concat "" [ Filename.remove_extension path;  ext ]

let parent (path : string) : string =
  Filename.basename (Filename.dirname path)

let is_roundtrip (path : string) : bool =
  String.equal (parent path) "roundtrip"

let is_neg (path : string) : bool =
  String.equal (parent path) "neg"
  && String.starts_with ~prefix:"parse-" (Filename.basename path)

(* --- the checks ---------------------------------------------------- *)

(* The golden of a round-trip fixture.  A fixture outside test/roundtrip
   has no golden, so the list is empty. *)
let golden_check (path : string) (s1 : string) : string list =
  if is_roundtrip path then
    Option.fold
      ~none:[ "the golden .fmt does not exist" ]
      ~some:(fun g ->
        if String.equal g s1 then []
        else [ "the golden .fmt does not equal the print" ])
      (read_file (sibling path ".fmt"))
  else []

(* p1 and p2 agree structurally, s1 and s2 agree, and the golden agrees
   with s1.  The comparison of p1 and p2 is the structural equality of
   the language, which is total on this type:  the tree holds integers,
   strings, booleans and constructors and no function. *)
let second_pass (path : string) (p1 : Ast.prog) (s1 : string) : string list =
  Result.fold
    ~error:(fun e ->
      [ String.concat " " [ "the reprint does not parse:";  Error.to_line e ] ])
    ~ok:(fun p2 ->
      let s2 = Print.prog p2 in
      List.concat
        [ (if p1 = p2 then [] else [ "the two parses differ" ]);
          (if String.equal s1 s2 then [] else [ "the two prints differ" ]);
          golden_check path s1
        ])
    (Parser.parse s1)

let pos_checks (path : string) (text : string) : string list =
  Result.fold
    ~error:(fun e ->
      [ String.concat " " [ "the parse failed:";  Error.to_line e ] ])
    ~ok:(fun p1 -> second_pass path p1 (Print.prog p1))
    (Parser.parse text)

(* A Parse twin has to fail, and its first two error words have to equal
   its golden. *)
let neg_golden (path : string) (line : string) : string list =
  Option.fold
    ~none:[ "the golden .err does not exist" ]
    ~some:(fun g ->
      if String.equal (chomp g) (first_two line) then []
      else
        [ String.concat " "
            [ "the golden .err says";
              chomp g;
              "and the error says";
              first_two line
            ]
        ])
    (read_file (sibling path ".err"))

let neg_checks (path : string) (text : string) : string list =
  Result.fold
    ~error:(fun e -> neg_golden path (Error.to_line e))
    ~ok:(fun _p -> [ "the parse was expected to fail and it did not" ])
    (Parser.parse text)

let check (path : string) : string list =
  Option.fold
    ~none:[ "the file does not exist" ]
    ~some:(fun text ->
      if is_neg path then neg_checks path text else pos_checks path text)
    (read_file path)

(* --- the run ------------------------------------------------------- *)

let report ((path, fails) : string * string list) : unit =
  List.iter (fun r -> say [ "PARSE-FAIL";  path;  r ]) fails

let run (paths : string list) : unit =
  let rows = List.map (fun p -> (p, check p)) paths in
  let () = List.iter report rows in
  let n = List.length rows in
  let m =
    List.length (List.filter (fun (_p, fs) -> List.length fs > 0) rows)
  in
  let () =
    say
      [ "PARSE";
        String.concat "" [ "files=";  string_of_int n ];
        String.concat "" [ "ok=";  string_of_int (n - m) ];
        String.concat "" [ "fail=";  string_of_int m ]
      ]
  in
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
    let () = print_endline "PARSE-EMPTY" in
    exit 2
  else run paths
