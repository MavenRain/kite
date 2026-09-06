(* surface/print.ml:  the canonical form (brief 3.6, D-A-15).

   prog gives one declaration per line, one newline between the lines and
   one newline after the last line.  The empty program gives the empty
   string (D-A-12).  Tokens carry one space between them, and a bracket
   holds to its content:  a record reads { a = 1, b = 2 }, an annotation
   reads (e : t) and a variant reads < l e >.

   The printer holds one arm per constructor of ast.ml and no wildcard
   arm, so a new arm of Stage B is a compile error here.

   Parentheses come from the levels of D-A-13 and from the context:  a
   loose form, that is fun, let, match or if, takes parentheses as an
   argument, as an operand and as a scrutinee;  a match takes them in an
   arm body too, because a bare nested match would take the arms of the
   outer match with it. *)

(* --- the context of one printed expression ------------------------ *)

type ctx =
  | CTop (* a final position:  every form prints bare *)
  | CArm (* an arm body or a field value:  a match takes parentheses *)
  | CApp (* an argument or a scrutinee:  only an atom prints bare *)
  | CFun (* the head of an application *)
  | COpL of int (* the left operand of a binop of that level *)
  | COpR of int (* the right operand of a binop of that level *)

(* 100 is an atom, 50 is an application, 1 to 5 are the binop levels of
   D-A-13, and 0 is a loose form. *)
let prec (e : Ast.expr) : int =
  match e with
  | Ast.Lit _ -> 100
  | Ast.Var _ -> 100
  | Ast.Rec _ -> 100
  | Ast.RecExt (_, _, _) -> 100
  | Ast.RecRes (_, _) -> 100
  | Ast.Sel (_, _) -> 100
  | Ast.Inj (_, _, _) -> 100
  | Ast.Ann (_, _) -> 100
  | Ast.App (_, _) -> 50
  | Ast.Bin (op, _, _) -> Ast.binop_level op
  | Ast.Lam (_, _) -> 0
  | Ast.Let (_, _, _) -> 0
  | Ast.LetRec (_, _) -> 0
  | Ast.If (_, _, _) -> 0
  | Ast.Match (_, _) -> 0

(* An exposed trailing match can consume the next arm or record tail.
   Delimited forms and operator operands already protect their children. *)
let rec has_open_match (e : Ast.expr) : bool =
  match e with
  | Ast.Match (_, _) -> true
  | Ast.Lit _ -> false
  | Ast.Var _ -> false
  | Ast.Rec _ -> false
  | Ast.RecExt (_, _, _) -> false
  | Ast.RecRes (_, _) -> false
  | Ast.Sel (_, _) -> false
  | Ast.Inj (_, _, _) -> false
  | Ast.Ann (_, _) -> false
  | Ast.App (_, _) -> false
  | Ast.Bin (_, _, _) -> false
  | Ast.Lam (_, b) -> has_open_match b
  | Ast.Let (_, _, b) -> has_open_match b
  | Ast.LetRec (_, b) -> has_open_match b
  | Ast.If (_, _, b) -> has_open_match b

(* A variant literal is an atom for the operator levels, because `<`
   opens a literal in expression-start position, and every operand of a
   binop starts an expression (D-A-13).  In application position the
   bracket reads the other way:  after an atom `<` is Lt, so a variant
   literal that sits as a function or as an argument takes parentheses,
   which is the form `f (< l x >)` of D-A-14.  The pattern side takes
   the same shape at pat_atom. *)
let is_inj (e : Ast.expr) : bool =
  match e with
  | Ast.Inj (_, _, _) -> true
  | Ast.Lit _ -> false
  | Ast.Var _ -> false
  | Ast.Rec _ -> false
  | Ast.RecExt (_, _, _) -> false
  | Ast.RecRes (_, _) -> false
  | Ast.Sel (_, _) -> false
  | Ast.Ann (_, _) -> false
  | Ast.App (_, _) -> false
  | Ast.Bin (_, _, _) -> false
  | Ast.Lam (_, _) -> false
  | Ast.Let (_, _, _) -> false
  | Ast.LetRec (_, _) -> false
  | Ast.If (_, _, _) -> false
  | Ast.Match (_, _) -> false

let as_lam (e : Ast.expr) : (Ast.pat * Ast.expr) option =
  match e with
  | Ast.Lam (p, b) -> Some (p, b)
  | Ast.Lit _ -> None
  | Ast.Var _ -> None
  | Ast.Rec _ -> None
  | Ast.RecExt (_, _, _) -> None
  | Ast.RecRes (_, _) -> None
  | Ast.Sel (_, _) -> None
  | Ast.Inj (_, _, _) -> None
  | Ast.Ann (_, _) -> None
  | Ast.App (_, _) -> None
  | Ast.Bin (_, _, _) -> None
  | Ast.Let (_, _, _) -> None
  | Ast.LetRec (_, _) -> None
  | Ast.If (_, _, _) -> None
  | Ast.Match (_, _) -> None

let as_ext (e : Ast.expr) : (Label.t * Ast.expr * Ast.expr) option =
  match e with
  | Ast.RecExt (l, v, t) -> Some (l, v, t)
  | Ast.Lit _ -> None
  | Ast.Var _ -> None
  | Ast.Rec _ -> None
  | Ast.RecRes (_, _) -> None
  | Ast.Sel (_, _) -> None
  | Ast.Inj (_, _, _) -> None
  | Ast.Ann (_, _) -> None
  | Ast.App (_, _) -> None
  | Ast.Bin (_, _, _) -> None
  | Ast.Lam (_, _) -> None
  | Ast.Let (_, _, _) -> None
  | Ast.LetRec (_, _) -> None
  | Ast.If (_, _, _) -> None
  | Ast.Match (_, _) -> None

(* The left operand of a right-associative or non-associative level
   takes parentheses at its own level;  the left operand of a left
   associative level takes them below its level alone. *)
let paren_left (n : int) (p : int) : bool =
  match () with
  | () when p >= 50 -> false
  | () when p = 0 -> true
  | () when n <= 3 -> p <= n
  | () -> p < n

let paren_right (n : int) (p : int) : bool =
  match () with
  | () when p >= 50 -> false
  | () when p = 0 -> true
  | () when n <= 2 -> p < n
  | () -> p <= n

let needs_parens (c : ctx) (e : Ast.expr) : bool =
  match c with
  | CTop -> false
  | CArm -> has_open_match e
  | CApp -> prec e < 100 || is_inj e
  | CFun -> prec e < 50 || is_inj e
  | COpL n -> paren_left n (prec e)
  | COpR n -> paren_right n (prec e)

(* --- the small string helpers ------------------------------------- *)

let words (xs : string list) : string =
  String.concat " " (List.filter (fun s -> String.length s > 0) xs)

let glue (xs : string list) : string = String.concat "" xs

let parens (s : string) : string = glue [ "(";  s;  ")" ]

let esc (c : char) : string =
  match () with
  | () when Char.equal c '\n' -> "\\n"
  | () when Char.equal c '\t' -> "\\t"
  | () when Char.equal c '\\' -> "\\\\"
  | () when Char.equal c '"' -> "\\\""
  | () -> String.make 1 c

let quote (s : string) : string =
  glue
    [ "\"";
      glue (List.map esc (List.of_seq (String.to_seq s)));
      "\""
    ]

let lit (v : Literal.t) : string =
  match v with
  | Literal.Int n -> string_of_int n
  | Literal.Str s -> quote s
  | Literal.Bool b -> if b then "true" else "false"
  | Literal.Unit -> "()"

(* --- types (brief 3.5) -------------------------------------------- *)

let rec ty (t : Ast.ty) : string =
  match t with
  | Ast.TName n -> n
  | Ast.TArrow (a, m, b) -> words [ ty_atom a;  Ast.mult_text m;  ty b ]
  | Ast.TRec r -> words [ "{";  row r;  "}" ]
  | Ast.TVar r -> words [ "<";  row r;  ">" ]
  | Ast.TCode (r, t2) -> words [ "Code";  "[";  row r;  ",";  ty t2;  "]" ]

(* The arrow is right associative, so a left arm that is itself an arrow
   takes parentheses. *)
and ty_atom (t : Ast.ty) : string =
  match t with
  | Ast.TArrow (_, _, _) -> parens (ty t)
  | Ast.TName _ -> ty t
  | Ast.TRec _ -> ty t
  | Ast.TVar _ -> ty t
  | Ast.TCode (_, _) -> ty t

and row (r : Ast.trow) : string =
  let fs =
    String.concat ", "
      (List.map
         (fun (l, t) -> words [ Label.to_string l;  ":";  ty t ])
         r.Ast.fields)
  in
  Option.fold ~none:fs ~some:(fun n -> words [ fs;  "|";  n ]) r.Ast.tail

(* --- patterns ----------------------------------------------------- *)

let rec pat (p : Ast.pat) : string =
  match p with
  | Ast.PLit v -> lit v
  | Ast.PVar i -> Ident.to_string i
  | Ast.PWild -> "_"
  | Ast.PInj (l, k, p2) ->
    words [ "<";  Label.to_string l;  occ k;  pat p2;  ">" ]
  | Ast.PRec (fs, tail) -> rec_pat fs tail

and occ (k : Label.occ) : string =
  if Label.occ_to_int k > 0 then
    words [ "^";  string_of_int (Label.occ_to_int k) ]
  else ""

and pat_atom (p : Ast.pat) : string =
  match p with
  | Ast.PInj (_, _, _) -> parens (pat p)
  | Ast.PLit _ -> pat p
  | Ast.PVar _ -> pat p
  | Ast.PWild -> pat p
  | Ast.PRec (_, _) -> pat p

and rec_pat (fs : (Label.t * Label.occ * Ast.pat) list)
    (tail : Ident.t option) : string =
  let body =
    String.concat ", "
      (List.map
         (fun (l, k, p) -> words [ Label.to_string l;  occ k;  "=";  pat p ])
         fs)
  in
  let inner =
    Option.fold ~none:body
      ~some:(fun n -> words [ body;  "|";  Ident.to_string n ])
      tail
  in
  words [ "{";  inner;  "}" ]

(* --- expressions -------------------------------------------------- *)

let rec expr (c : ctx) (e : Ast.expr) : string =
  if needs_parens c e then parens (bare e) else bare e

and bare (e : Ast.expr) : string =
  match e with
  | Ast.Lit v -> lit v
  | Ast.Var i -> Ident.to_string i
  | Ast.Lam (p, b) -> lam p b
  | Ast.App (f, x) -> words [ expr CFun f;  expr CApp x ]
  | Ast.Let (p, v, b) ->
    words [ "let";  pat p;  "=";  expr CArm v;  "in";  expr CTop b ]
  | Ast.LetRec (bs, b) ->
    words [ "let";  "rec";  binds bs;  "in";  expr CTop b ]
  | Ast.If (a, b, c2) ->
    words [ "if";  expr CArm a;  "then";  expr CArm b;  "else";  expr CTop c2 ]
  | Ast.Rec fs -> words [ "{";  fields fs;  "}" ]
  | Ast.RecExt (l, v, t) -> ext l v t
  | Ast.RecRes (e2, l) ->
    words [ "{";  expr CFun e2;  "-";  Label.to_string l;  "}" ]
  | Ast.Sel (e2, l) -> glue [ expr CApp e2;  ".";  Label.to_string l ]
  | Ast.Inj (l, k, e2) ->
    words [ "<";  Label.to_string l;  occ k;  expr CApp e2;  ">" ]
  | Ast.Match (s, rows) -> words [ "match";  expr CApp s;  "with";  arms rows ]
  | Ast.Ann (e2, t) -> glue [ "(";  expr CTop e2;  " : ";  ty t;  ")" ]
  | Ast.Bin (op, a, b) ->
    let n = Ast.binop_level op in
    words [ expr (COpL n) a;  Ast.binop_text op;  expr (COpR n) b ]

and fields (fs : (Label.t * Ast.expr) list) : string =
  String.concat ", "
    (List.map
       (fun (l, v) -> words [ Label.to_string l;  "=";  expr CArm v ])
       fs)

and ext (l : Label.t) (v : Ast.expr) (t : Ast.expr) : string =
  let (fs, tail) = strip_ext [ (l, v) ] t in
  words [ "{";  fields fs;  "|";  expr CArm tail;  "}" ]

and strip_ext (acc : (Label.t * Ast.expr) list) (e : Ast.expr)
  : (Label.t * Ast.expr) list * Ast.expr =
  Option.fold ~none:(List.rev acc, e)
    ~some:(fun (l, v, t) -> strip_ext ((l, v) :: acc) t)
    (as_ext e)

and lam (p : Ast.pat) (b : Ast.expr) : string =
  let (ps, body) = strip_lam [ p ] b in
  words
    (List.concat
       [ [ "fun" ];  List.map pat_atom ps;  [ "->";  expr CTop body ] ])

and strip_lam (acc : Ast.pat list) (e : Ast.expr) : Ast.pat list * Ast.expr =
  Option.fold ~none:(List.rev acc, e)
    ~some:(fun (p, b) -> strip_lam (p :: acc) b)
    (as_lam e)

and arms (rows : Ast.arm list) : string =
  words
    (List.map
       (fun (p, b) -> words [ "|";  pat p;  "->";  expr CArm b ])
       rows)

and binds (bs : Ast.bind list) : string =
  String.concat " and " (List.map bind bs)

and bind ((n, e) : Ast.bind) : string =
  let (ps, body) = strip_lam [] e in
  words
    (List.concat
       [ [ Ident.to_string n ];
         List.map pat_atom ps;
         [ "=";  expr CArm body ]
       ])

(* --- declarations (brief 3.6) -------------------------------------- *)

(* A declaration prints on one line.  A list inside a declaration takes
   a comma between its members, because the reader of a leg, a clause
   and an entry accepts a comma and the comma keeps two members apart
   when the first one ends in an expression. *)

let head_of (n : Ident.t) (e : Ast.expr) : string =
  let (ps, body) = strip_lam [] e in
  words
    (List.concat
       [ [ Ident.to_string n ];
         List.map pat_atom ps;
         [ "=";  expr CTop body ]
       ])

let budget_fs (fs : (Label.t * int) list) : string =
  String.concat ", "
    (List.map
       (fun (l, v) -> words [ Label.to_string l;  "=";  string_of_int v ])
       fs)

let import_str (i : Ast.import) : string =
  words
    [ "import";
      Ident.to_string i.Ast.iname;
      ":";
      ty i.Ast.ity;
      "cost";
      string_of_int i.Ast.cost;
      "deadline";
      string_of_int i.Ast.deadline_ms
    ]

let leg_str ((l, t, s) : Label.t * Ast.ty * Ident.t) : string =
  words [ Label.to_string l;  ":";  ty t;  "->";  Ident.to_string s ]

let state_str (s : Ast.pstate) : string =
  let comp =
    Option.fold ~none:""
      ~some:(fun e -> words [ "compensate";  expr CTop e ])
      s.Ast.compensate
  in
  words
    [ "state";
      Ident.to_string s.Ast.sname;
      "{";
      String.concat ", " (List.map leg_str s.Ast.legs);
      "}";
      comp
    ]

let proto_str (p : Ast.proto) : string =
  words
    [ "protocol";
      Ident.to_string p.Ast.pname;
      "{";
      words (List.map state_str p.Ast.states);
      "}"
    ]

let clause_str ((l, ps, e) : Label.t * Ident.t list * Ast.expr) : string =
  words
    (List.concat
       [ [ Label.to_string l ];
         List.map Ident.to_string ps;
         [ "->";  expr CArm e ]
       ])

let role_str (r : Ast.role) : string =
  let cs = List.map clause_str r.Ast.clauses in
  let pl =
    Option.fold ~none:[]
      ~some:(fun e -> [ words [ "Peer_lost";  "->";  expr CArm e ] ])
      r.Ast.peer_lost
  in
  let ab =
    Option.fold ~none:[]
      ~some:(fun e -> [ words [ "abort";  "->";  expr CArm e ] ])
      r.Ast.abort
  in
  words
    [ "role";
      Ident.to_string r.Ast.rname;
      ":";
      Ident.to_string r.Ast.proto;
      "{";
      String.concat ", " (List.concat [ cs;  pl;  ab ]);
      "}"
    ]

let entry_str (e : Ast.mentry) : string =
  words
    [ Ident.to_string e.Ast.kind;
      Ident.to_string e.Ast.ename;
      "{";
      fields e.Ast.fields;
      "}"
    ]

let freeze_str (ls : Label.t list) (e : Ast.expr) : string =
  words
    [ "freeze";
      "{";
      String.concat ", " (List.map Label.to_string ls);
      "}";
      "=";
      expr CTop e
    ]

let rec decl (d : Ast.decl) : string =
  match d with
  | Ast.DLet (n, e) -> words [ "let";  head_of n e ]
  | Ast.DLetRec bs -> words [ "let";  "rec";  binds bs ]
  | Ast.DImport i -> import_str i
  | Ast.DBudget (fs, d2) ->
    words [ glue [ "@";  "budget" ];  "{";  budget_fs fs;  "}";  decl d2 ]
  | Ast.DProtocol p -> proto_str p
  | Ast.DRole r -> role_str r
  | Ast.DFreeze (ls, e) -> freeze_str ls e
  | Ast.DManifest (n, es) ->
    words
      [ "manifest";
        Ident.to_string n;
        "{";
        String.concat ", " (List.map entry_str es);
        "}"
      ]
  | Ast.DMilestone (_m, _n, text) -> text

(* The empty program is the empty string (D-A-12);  every other program
   is its declarations, one to a line, with a newline after the last. *)
let prog (p : Ast.prog) : string =
  if List.is_empty p then ""
  else glue [ String.concat "\n" (List.map decl p);  "\n" ]
