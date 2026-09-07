(* lib/iface.ml:  the .coi interface file of brief 3.9 (D-B-13, D-B-14)
   and the separate compilation edge of brief 3.10 (D-B-15).

   A .coi file is TEXT, ASCII, one record per line, so a consumer never
   re-reads the source:

     coi 1
     source-sha256 HEX64
     module NAME
     val NAME : SCHEME usage=U
     budget NAME atoms=A constraints=C
     import NAME cost=K deadline_ms=D
     end

   Every field is a single token with no space, so the reader splits a
   line on one space and never on a quote.  The SCHEME field of a val
   line is the canonical print of lib/pp.ml, which is token separated by
   the same one space, so the reader takes the tokens between the colon
   and the usage field and parses them back (D-B-60).

   D-B-14 the round trip:  read (write i) equals i for every interface
   the checker builds.  The equality is Iface.equal, which reads a
   scheme through its canonical print, because a read scheme carries the
   ids the reader made and never the ids the inference run made
   (D-B-61).  A malformed line is IfaceMismatch and never a crash.

   D-B-63:  the val lines carry EVERY top level binding of the
   environment, the imported names included.  Reason:  Env.bindings is
   the declaration order list the .scheme golden of brief 3.13 already
   prints, an import is a name the module offers to its readers, and the
   two prints then agree name for name. *)

let ( let* ) (x : ('a, Error.t) result) (f : 'a -> ('b, Error.t) result)
  : ('b, Error.t) result =
  Result.bind x f

let bad (text : string) : Error.t = Error.iface_mismatch text

(* --- the record ------------------------------------------------------- *)

type export =
  { xname : Ident.t;  xscheme : Types.scheme;  xusage : Usage.u }

type budget = { bname : Ident.t;  batoms : int;  bconstraints : int }

type imported = { pname : Ident.t;  pcost : int;  pdeadline_ms : int }

type t =
  { version : int;
    source_sha256 : string;
    module_name : string;
    vals : export list;
    budgets : budget list;
    imports : imported list
  }

let format_version : int = 1

let empty (name : string) (sha : string) : t =
  { version = format_version;
    source_sha256 = sha;
    module_name = name;
    vals = [];
    budgets = [];
    imports = []
  }

(* --- total string helpers --------------------------------------------- *)

let chars (s : string) : string list =
  List.map (String.make 1) (List.of_seq (String.to_seq s))

let first_of (s : string) : string =
  match chars s with
  | [] -> ""
  | c :: _more -> c

let rest_of (s : string) : string =
  String.concat "" (List.filteri (fun i _c -> i > 0) (chars s))

let is_digit (c : string) : bool =
  List.exists (String.equal c)
    [ "0";  "1";  "2";  "3";  "4";  "5";  "6";  "7";  "8";  "9" ]

let all_digits (s : string) : bool =
  (not (String.equal s "")) && List.for_all is_digit (chars s)

(* A digest field holds 64 hexadecimal characters.  The reader tests the
   shape, so an interface with no digest line does not read as a match. *)
let is_hex (c : string) : bool =
  is_digit c
  || List.exists (String.equal c) [ "a";  "b";  "c";  "d";  "e";  "f" ]

let hex64 (s : string) : bool =
  String.length s = 64 && List.for_all is_hex (chars s)

let upper_first (s : string) : bool =
  List.exists (String.equal (first_of s))
    [ "A";  "B";  "C";  "D";  "E";  "F";  "G";  "H";  "I";  "J";  "K";  "L";
      "M";  "N";  "O";  "P";  "Q";  "R";  "S";  "T";  "U";  "V";  "W";  "X";
      "Y";  "Z" ]

let after (prefix : string) (s : string) : string option =
  if String.starts_with ~prefix s then
    Some
      (String.concat ""
         (List.filteri (fun i _c -> i >= String.length prefix) (chars s)))
  else None

(* A field holds DECIMAL digits alone.  The reader of the standard
   library also takes a hex, an octal, a binary, an underscored and a
   signed number, so `coi 0x1` would read as version 1 and `a ^ -1` would
   put an occurrence index the surface grammar refuses into a row. *)
let decimal (s : string) : int option =
  if all_digits s then int_of_string_opt s else None

let int_field (prefix : string) (s : string) : (int, Error.t) result =
  Option.fold
    ~none:
      (Error
         (bad (String.concat " " [ "the field";  s;  "is not";  prefix ])))
    ~some:(fun (v : int) -> Ok v)
    (Option.bind (after prefix s) decimal)

let words (line : string) : string list =
  List.filter
    (fun (w : string) -> not (String.equal w ""))
    (String.split_on_char ' ' line)

let lines_of (text : string) : string list =
  List.filter
    (fun (l : string) -> not (String.equal l ""))
    (String.split_on_char '\n' text)

let peek (ts : string list) : string =
  match ts with
  | [] -> ""
  | w :: _more -> w

let advance (ts : string list) : string list =
  match ts with
  | [] -> []
  | _w :: more -> more

let last_of (ts : string list) : string = peek (List.rev ts)

let without_last (ts : string list) : string list =
  List.rev (advance (List.rev ts))

let expect (w : string) (ts : string list) : (string list, Error.t) result =
  if String.equal (peek ts) w then Ok (advance ts)
  else
    Error
      (bad
         (String.concat " "
            [ "the interface wants";  w;  "and reads";  peek ts ]))

(* --- the reader of a canonical scheme print --------------------------- *)

(* A printed variable is a lower case letter and a digit run:  a and b
   name a quantified variable and t and r name a free one (D-B-51). *)
type pstate =
  { next : int;
    tnames : (string * int) list;
    rnames : (string * int) list;
    qvars : int list;
    qrvars : int list
  }

let no_state : pstate =
  { next = 0;  tnames = [];  rnames = [];  qvars = [];  qrvars = [] }

let var_shaped (heads : string list) (s : string) : bool =
  List.exists (String.equal (first_of s)) heads && all_digits (rest_of s)

let is_tvar (s : string) : bool = var_shaped [ "a";  "t" ] s

let is_rvar (s : string) : bool = var_shaped [ "b";  "r" ] s

let bound_head (s : string) (heads : string list) : bool =
  List.exists (String.equal (first_of s)) heads

let tvar_id (name : string) (st : pstate) : int * pstate =
  Option.fold
    ~none:
      ( st.next,
        { st with
          next = st.next + 1;
          tnames = List.append st.tnames [ (name, st.next) ];
          qvars =
            (if bound_head name [ "a" ] then List.append st.qvars [ st.next ]
             else st.qvars)
        } )
    ~some:(fun (id : int) -> (id, st))
    (List.assoc_opt name st.tnames)

let rvar_id (name : string) (st : pstate) : int * pstate =
  Option.fold
    ~none:
      ( st.next,
        { st with
          next = st.next + 1;
          rnames = List.append st.rnames [ (name, st.next) ];
          qrvars =
            (if bound_head name [ "b" ] then List.append st.qrvars [ st.next ]
             else st.qrvars)
        } )
    ~some:(fun (id : int) -> (id, st))
    (List.assoc_opt name st.rnames)

let mult_of (w : string) : (Types.mult, Error.t) result =
  match () with
  | () when String.equal w "->" -> Ok Types.Many
  | () when String.equal w "-1>" -> Ok Types.AtMostOnce
  | () -> Error (bad (String.concat " " [ "the arrow";  w;  "is unknown" ]))

let row_end (w : string) : bool =
  List.exists (String.equal w) [ "}";  ">";  "" ]

let rec p_ty (st : pstate) (ts : string list)
  : (Types.t * string list * pstate, Error.t) result =
  match () with
  | () when String.equal (peek ts) "(" ->
    let* (a, ts1, st1) = p_ty st (advance ts) in
    let* m = mult_of (peek ts1) in
    let* (b, ts2, st2) = p_ty st1 (advance ts1) in
    let* ts3 = expect ")" ts2 in
    Ok (Types.Arrow (a, m, b), ts3, st2)
  | () when String.equal (peek ts) "{" ->
    let* (r, ts1, st1) = p_row st (advance ts) in
    let* ts2 = expect "}" ts1 in
    Ok (Types.Record r, ts2, st1)
  | () when String.equal (peek ts) "<" ->
    let* (r, ts1, st1) = p_row st (advance ts) in
    let* ts2 = expect ">" ts1 in
    Ok (Types.Variant r, ts2, st1)
  | () when String.equal (peek ts) "Code" ->
    let* ts1 = expect "[" (advance ts) in
    let* (r, ts2, st1) = p_row st ts1 in
    let* ts3 = expect "," ts2 in
    let* (b, ts4, st2) = p_ty st1 ts3 in
    let* ts5 = expect "]" ts4 in
    Ok (Types.Code (r, b), ts5, st2)
  | () when is_tvar (peek ts) ->
    let (id, st1) = tvar_id (peek ts) st in
    Ok (Types.Var { Types.id = id;  Types.level = 0 }, advance ts, st1)
  | () when upper_first (peek ts) ->
    Ok (Types.Con (peek ts), advance ts, st)
  | () ->
    Error (bad (String.concat " " [ "the type token";  peek ts;  "is unknown" ]))

and p_tail (st : pstate) (ts : string list)
  : (Types.row * string list * pstate, Error.t) result =
  let name = peek (advance ts) in
  if is_rvar name then
    let (id, st1) = rvar_id name st in
    Ok
      ( Types.RVar { Types.rid = id;  Types.rlevel = 0 },
        advance (advance ts),
        st1 )
  else
    Error (bad (String.concat " " [ "the row tail";  name;  "is unknown" ]))

and p_row (st : pstate) (ts : string list)
  : (Types.row * string list * pstate, Error.t) result =
  match () with
  | () when String.equal (peek ts) "|" -> p_tail st ts
  | () when row_end (peek ts) -> Ok (Types.REmpty, ts, st)
  | () ->
    let l = Label.of_string (peek ts) in
    let* ts1 = expect "^" (advance ts) in
    let* n = int_field "" (peek ts1) in
    let* ts2 = expect ":" (advance ts1) in
    let* (ty, ts3, st1) = p_ty st ts2 in
    let* (rest, ts4, st2) = p_more st1 ts3 in
    Ok (Types.RExt (l, Label.occ_of_int n, ty, rest), ts4, st2)

and p_more (st : pstate) (ts : string list)
  : (Types.row * string list * pstate, Error.t) result =
  match () with
  | () when String.equal (peek ts) "," -> p_row st (advance ts)
  | () when String.equal (peek ts) "|" -> p_tail st ts
  | () -> Ok (Types.REmpty, ts, st)

(* D-B-68:  a list index rides a total recursion written here, never the
   indexed reader of the standard library, whose option-returning name
   carries the text the partial-index leg of dev/house.sh reads. *)
let rec tok (i : int) (ts : string list) : string =
  match ts with
  | [] -> ""
  | w :: rest -> if i <= 0 then w else tok (i - 1) rest

(* vars=K rvars=L BODY, the scheme field of a val line. *)
let p_scheme (ts : string list) : (Types.scheme, Error.t) result =
  let* k = int_field "vars=" (tok 0 ts) in
  let* l = int_field "rvars=" (tok 1 ts) in
  let* (body, rest, st) = p_ty no_state (advance (advance ts)) in
  match () with
  | () when List.length rest > 0 ->
    Error (bad (String.concat " " [ "the scheme leaves";  peek rest ]))
  | () when List.length st.qvars <> k ->
    Error (bad "the scheme counts a different number of type variables")
  | () when List.length st.qrvars <> l ->
    Error (bad "the scheme counts a different number of row variables")
  | () ->
    Ok
      { Types.vars = st.qvars;  Types.rvars = st.qrvars;  Types.body = body }

let usage_of (w : string) : (Usage.u, Error.t) result =
  match () with
  | () when String.equal w "Zero" -> Ok Usage.Zero
  | () when String.equal w "Once" -> Ok Usage.Once
  | () when String.equal w "Many" -> Ok Usage.Many
  | () -> Error (bad (String.concat " " [ "the usage";  w;  "is unknown" ]))

(* --- the writer ------------------------------------------------------- *)

let val_line (x : export) : string =
  String.concat " "
    [ "val";  Ident.to_string x.xname;  ":";  Pp.scheme x.xscheme;
      String.concat "" [ "usage=";  Usage.to_string x.xusage ]
    ]

let budget_line (b : budget) : string =
  String.concat " "
    [ "budget";  Ident.to_string b.bname;
      String.concat "" [ "atoms=";  string_of_int b.batoms ];
      String.concat "" [ "constraints=";  string_of_int b.bconstraints ]
    ]

let import_line (m : imported) : string =
  String.concat " "
    [ "import";  Ident.to_string m.pname;
      String.concat "" [ "cost=";  string_of_int m.pcost ];
      String.concat "" [ "deadline_ms=";  string_of_int m.pdeadline_ms ]
    ]

let write (i : t) : string =
  String.concat ""
    (List.map
       (fun (l : string) -> String.concat "" [ l;  "\n" ])
       (List.concat
          [ [ String.concat " " [ "coi";  string_of_int i.version ];
              String.concat " " [ "source-sha256";  i.source_sha256 ];
              String.concat " " [ "module";  i.module_name ]
            ];
            List.map val_line i.vals;
            List.map budget_line i.budgets;
            List.map import_line i.imports;
            [ "end" ]
          ]))

(* --- the reader ------------------------------------------------------- *)

let p_val (ts : string list) : (export, Error.t) result =
  let* ts2 = expect ":" (advance (advance ts)) in
  let* u =
    Option.fold
      ~none:(Error (bad (String.concat " " [ "the usage field";  last_of ts2 ])))
      ~some:usage_of
      (after "usage=" (last_of ts2)) in
  let* sc = p_scheme (without_last ts2) in
  Ok { xname = Ident.of_string (tok 1 ts);  xscheme = sc;  xusage = u }

let p_budget (ts : string list) : (budget, Error.t) result =
  let* a = int_field "atoms=" (tok 2 ts) in
  let* c = int_field "constraints=" (tok 3 ts) in
  Ok
    { bname = Ident.of_string (tok 1 ts);  batoms = a;  bconstraints = c }

let p_import (ts : string list) : (imported, Error.t) result =
  let* k = int_field "cost=" (tok 2 ts) in
  let* d = int_field "deadline_ms=" (tok 3 ts) in
  Ok { pname = Ident.of_string (tok 1 ts);  pcost = k;  pdeadline_ms = d }

let add_line (acc : t) (line : string) : (t, Error.t) result =
  let ts = words line in
  match () with
  | () when String.equal (peek ts) "coi" ->
    let* v = int_field "" (tok 1 ts) in
    Ok { acc with version = v }
  | () when String.equal (peek ts) "source-sha256" ->
    Ok { acc with source_sha256 = tok 1 ts }
  | () when String.equal (peek ts) "module" ->
    Ok { acc with module_name = tok 1 ts }
  | () when String.equal (peek ts) "val" ->
    let* x = p_val ts in
    Ok { acc with vals = List.append acc.vals [ x ] }
  | () when String.equal (peek ts) "budget" ->
    let* b = p_budget ts in
    Ok { acc with budgets = List.append acc.budgets [ b ] }
  | () when String.equal (peek ts) "import" ->
    let* m = p_import ts in
    Ok { acc with imports = List.append acc.imports [ m ] }
  | () when String.equal (peek ts) "end" -> Ok acc
  | () ->
    Error (bad (String.concat " " [ "the record";  peek ts;  "is unknown" ]))

let read (text : string) : (t, Error.t) result =
  let ls = lines_of text in
  let* built =
    List.fold_left
      (fun acc line ->
        let* a = acc in
        add_line a line)
      (Ok { (empty "" "") with version = 0 })
      ls in
  match () with
  | () when not (String.equal (last_of ls) "end") ->
    Error (bad "the interface holds no end line")
  | () when built.version = 0 ->
    Error (bad "the interface holds no coi line")
  | () when built.version <> format_version ->
    Error (bad "the interface holds another format version")
  | () when not (hex64 built.source_sha256) ->
    Error (bad "the interface holds no source-sha256 line")
  | () when String.equal built.module_name "" ->
    Error (bad "the interface holds no module line")
  | () -> Ok built

(* --- the round trip equality (D-B-61) --------------------------------- *)

let rec list_equal (f : 'a -> 'a -> bool) (xs : 'a list) (ys : 'a list) : bool =
  match (xs, ys) with
  | ([], []) -> true
  | ([], _y :: _r) -> false
  | (_x :: _r, []) -> false
  | (x :: r1, y :: r2) -> f x y && list_equal f r1 r2

let export_equal (a : export) (b : export) : bool =
  Ident.equal a.xname b.xname
  && String.equal (Pp.scheme a.xscheme) (Pp.scheme b.xscheme)
  && String.equal (Usage.to_string a.xusage) (Usage.to_string b.xusage)

let budget_equal (a : budget) (b : budget) : bool =
  Ident.equal a.bname b.bname && a.batoms = b.batoms
  && a.bconstraints = b.bconstraints

let import_equal (a : imported) (b : imported) : bool =
  Ident.equal a.pname b.pname && a.pcost = b.pcost
  && a.pdeadline_ms = b.pdeadline_ms

let equal (a : t) (b : t) : bool =
  a.version = b.version
  && String.equal a.source_sha256 b.source_sha256
  && String.equal a.module_name b.module_name
  && list_equal export_equal a.vals b.vals
  && list_equal budget_equal a.budgets b.budgets
  && list_equal import_equal a.imports b.imports

(* --- the interface the checker builds ---------------------------------- *)

(* The atoms and the constraints of an A5 annotation, with the default
   caps of D-B-10 when the annotation names one field alone. *)
let field_or (fs : (Label.t * int) list) (name : string) (dflt : int) : int =
  Option.fold ~none:dflt
    ~some:(fun (v : int) -> v)
    (List.find_map
       (fun ((l, v) : Label.t * int) ->
         if String.equal (Label.to_string l) name then Some v else None)
       fs)

(* The name a budget line carries:  the name the wrapped declaration
   binds, and the name of the form itself when it binds none (D-B-64). *)
let rec budget_name (d : Ast.decl) : Ident.t =
  match d with
  | Ast.DLet (x, _e) -> x
  | Ast.DLetRec bs ->
    (match bs with
     | [] -> Ident.of_string "@group"
     | (x, _e) :: _rest -> x)
  | Ast.DImport i -> i.Ast.iname
  | Ast.DBudget (_fs, inner) -> budget_name inner
  | Ast.DProtocol p -> p.Ast.pname
  | Ast.DRole r -> r.Ast.rname
  | Ast.DFreeze (_ls, _e) -> Ident.of_string "@freeze"
  | Ast.DManifest (n, _es) -> n
  | Ast.DMilestone (_m, n, _t) -> n

let rec budgets_of (d : Ast.decl) : budget list =
  match d with
  | Ast.DLet (_x, _e) -> []
  | Ast.DLetRec _bs -> []
  | Ast.DImport _i -> []
  | Ast.DBudget (fs, inner) ->
    { bname = budget_name inner;
      batoms = field_or fs "atoms" 64;
      bconstraints = field_or fs "constraints" 32
    }
    :: budgets_of inner
  | Ast.DProtocol _p -> []
  | Ast.DRole _r -> []
  | Ast.DFreeze (_ls, _e) -> []
  | Ast.DManifest (_n, _es) -> []
  | Ast.DMilestone (_m, _n, _t) -> []

let rec imports_of (d : Ast.decl) : imported list =
  match d with
  | Ast.DLet (_x, _e) -> []
  | Ast.DLetRec _bs -> []
  | Ast.DImport i ->
    [ { pname = i.Ast.iname;
        pcost = i.Ast.cost;
        pdeadline_ms = i.Ast.deadline_ms
      }
    ]
  | Ast.DBudget (_fs, inner) -> imports_of inner
  | Ast.DProtocol _p -> []
  | Ast.DRole _r -> []
  | Ast.DFreeze (_ls, _e) -> []
  | Ast.DManifest (_n, _es) -> []
  | Ast.DMilestone (_m, _n, _t) -> []

(* Every field of a record line is ONE token, so the module name keeps a
   printable byte that is not a space and writes an underscore for every
   other byte, at the one place the name enters.  The round trip law then
   holds for a space, a tab and a newline alike. *)
let one_token (s : string) : string =
  String.concat ""
    (List.map
       (fun (c : char) ->
         if Char.code c >= 33 && Char.code c <= 126 then String.make 1 c
         else "_")
       (List.of_seq (String.to_seq s)))

(* The interface of a CHECKED program:  the source digest, the module
   name, one val line per top level binding in declaration order with
   its usage, one budget line per annotation and one import line per
   import (D-B-13). *)
let of_prog (module_name : string) (source : string) (p : Ast.prog)
  (env : Env.t) (s : Subst.t) : t =
  let uses = Usage.prog_uses p in
  let (vals, _rest) = List.fold_left (fun (vals, remaining) (x, sc) ->
    let (u, rest) = match remaining with
      | [] -> (Usage.Zero, [])
      | (_name, u) :: rest -> (u, rest) in
    ({ xname = x;  xscheme = { sc with Types.body = Subst.apply s sc.Types.body };
       xusage = u } :: vals, rest)) ([], uses) (Env.bindings env) in
  { version = format_version;
    source_sha256 = Sha256.of_string source;
    module_name = one_token module_name;
    vals = List.rev vals;
    budgets = List.concat_map budgets_of p;
    imports = List.concat_map imports_of p
  }

let exports (i : t) : int = List.length i.vals

(* The interface as the environment reads it, so an import of brief 3.10
   is checked against the exported scheme (D-B-15). *)
let to_loaded (i : t) : Env.loaded =
  Env.loaded_of i.module_name
    (List.map (fun (x : export) -> Env.export_of x.xname x.xscheme) i.vals)
