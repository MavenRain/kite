(* lib/pp.ml:  the two printers of brief 3.12 (D-B-17).  It prints a
   SCHEME, which the .scheme goldens of brief 3.13 and the val lines of a
   .coi file read, and it prints an IR term, which the .kir artifact of
   the build verb holds.

   THE CANONICAL SCHEME PRINT (D-B-51 of round B2).  A golden may not
   read a raw variable id, because an id counts every fresh variable the
   run made before it.  The print renames the variables of the scheme in
   order of first appearance:  a quantified type variable becomes a0, a1
   and so on, a free type variable becomes t0, t1 and so on, a quantified
   row variable becomes b0 and a free row variable becomes r0.  The shape
   of the body is the shape of Types.to_string.  This file reproduces the
   print of test/check.ml byte for byte, because those goldens are the
   contract that round B2 froze.

   D-B-60:  the printed scheme is TOKEN SEPARATED by one space at every
   join, so the reader of lib/iface.ml splits a val line on one space and
   never on a quote (D-B-13).  That is already true of the round B2
   print, and this file keeps it. *)

(* --- the naming of the variables ------------------------------------ *)

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

(* --- the body ------------------------------------------------------- *)

let rec show (n : naming) (ty : Types.t) : string =
  match ty with
  | Types.Var v -> named n.tmap v.Types.id
  | Types.Con c -> c
  | Types.Arrow (a, m, b) ->
    String.concat " " [ "(";  show n a;  Types.mult_text m;  show n b;  ")" ]
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

let field (name : string) (n : int) : string =
  String.concat "" [ name;  string_of_int n ]

(* vars=K rvars=L BODY, which is the tail of a .scheme line and the
   scheme field of a val line of a .coi file. *)
let scheme (sc : Types.scheme) : string =
  let n = collect sc.Types.vars sc.Types.rvars no_naming sc.Types.body in
  String.concat " "
    [ field "vars=" (List.length sc.Types.vars);
      field "rvars=" (List.length sc.Types.rvars);
      show n sc.Types.body
    ]

(* NAME : vars=K rvars=L BODY, the whole line of a .scheme golden. *)
let scheme_line (x : Ident.t) (sc : Types.scheme) : string =
  String.concat " " [ Ident.to_string x;  ":";  scheme sc ]

(* --- the IR printer (the .kir artifact of D-B-17) -------------------- *)

let escape_char (c : char) : string =
  match () with
  | () when Char.equal c '"' -> "\\\""
  | () when Char.equal c '\\' -> "\\\\"
  | () when Char.equal c '\n' -> "\\n"
  | () -> String.make 1 c

let escape (s : string) : string =
  String.concat "" (List.map escape_char (List.of_seq (String.to_seq s)))

let literal (l : Literal.t) : string =
  match l with
  | Literal.Int n -> string_of_int n
  | Literal.Str s -> String.concat "" [ "\"";  escape s;  "\"" ]
  | Literal.Bool b -> if b then "#t" else "#f"
  | Literal.Unit -> "#u"

let rec pat (p : Ir.pat) : string =
  match p with
  | Ir.PLit l ->
    String.concat " " [ "(plit";  String.concat "" [ literal l;  ")" ] ]
  | Ir.PVar x ->
    String.concat " " [ "(pvar";  String.concat "" [ Ident.to_string x;  ")" ] ]
  | Ir.PWild -> "(pwild)"
  | Ir.PInj (l, o, q) ->
    String.concat " "
      [ "(pinj";  Label.to_string l;  string_of_int (Label.occ_to_int o);
        String.concat "" [ pat q;  ")" ]
      ]
  | Ir.PRec (fs, rest) ->
    String.concat " "
      [ "(prec";
        String.concat " "
          (List.map
             (fun ((l, o, q) : Label.t * Label.occ * Ir.pat) ->
               String.concat " "
                 [ "(";  Label.to_string l;  string_of_int (Label.occ_to_int o);
                   pat q;  ")" ])
             fs);
        String.concat ""
          [ Option.fold ~none:"." ~some:Ident.to_string rest;  ")" ]
      ]

let rec term (e : Ir.t) : string =
  match e with
  | Ir.IVar x -> Ident.to_string x
  | Ir.ILit l -> literal l
  | Ir.ILam (p, b) -> String.concat " " [ "(lam";  pat p;  close b ]
  | Ir.IApp (f, x) -> String.concat " " [ "(app";  term f;  close x ]
  | Ir.ILet (p, v, b) -> String.concat " " [ "(let";  pat p;  term v;  close b ]
  | Ir.ILetRec (bs, b) ->
    String.concat " "
      [ "(letrec";
        String.concat " "
          (List.map
             (fun ((x, v) : Ident.t * Ir.t) ->
               String.concat " " [ "(";  Ident.to_string x;  term v;  ")" ])
             bs);
        close b
      ]
  | Ir.IIf (c, a, b) -> String.concat " " [ "(if";  term c;  term a;  close b ]
  | Ir.IRec (fs, base) ->
    String.concat " "
      [ "(rec";  Option.fold ~none:"." ~some:term base;
        String.concat ""
          [ String.concat " "
              (List.map
                 (fun ((l, v) : Label.t * Ir.t) ->
                   String.concat " " [ "(";  Label.to_string l;  term v;  ")" ])
                 fs);
            ")"
          ]
      ]
  | Ir.ISel (e2, l) ->
    String.concat " "
      [ "(sel";  term e2;  String.concat "" [ Label.to_string l;  ")" ] ]
  | Ir.IInj (l, o, e2) ->
    String.concat " "
      [ "(inj";  Label.to_string l;  string_of_int (Label.occ_to_int o);
        close e2 ]
  | Ir.IMatch (scrut, arms) ->
    String.concat " "
      [ "(match";  term scrut;
        String.concat ""
          [ String.concat " "
              (List.map
                 (fun ((p, b) : Ir.pat * Ir.t) ->
                   String.concat " " [ "(";  pat p;  term b;  ")" ])
                 arms);
            ")"
          ]
      ]
  | Ir.IBin (op, a, b) -> String.concat " " [ "(bin";  op;  term a;  close b ]

and close (e : Ir.t) : string = String.concat "" [ term e;  ")" ]

let item (it : Ir.item) : string =
  String.concat " " [ "(val";  Ident.to_string it.Ir.iname;  close it.Ir.ibody ]

(* The .kir file:  one header line, then one item per line in declaration
   order, then one trailing newline. *)
let prog (p : Ir.prog) : string =
  String.concat ""
    [ "kir 1\n";
      String.concat ""
        (List.map (fun it -> String.concat "" [ item it;  "\n" ]) p)
    ]
