(* surface/parser.ml:  recursive descent with a Pratt level per binop
   (brief 3.5, D-A-12 to D-A-14).

   The parser reads the token list of Lexer.lex and returns
   (Ast.prog, Error.t) result.  It never signals a failure:  a failure is
   a value.  Every function takes the token list and returns the value it
   built beside the tokens that are left.

   The token list ends with one Eof token, so the reader always has a
   token to name in an error.  The empty stream case stays for totality
   alone (D-A-12).

   The flag gt is the Gt flag of D-A-14:  inside a variant payload it is
   false, so the byte > closes the payload and a comparison inside a
   payload needs parentheses.  A parenthesis, a brace and a bracket all
   set the flag back to true. *)

type stream = Lexer.t list

(* --- the small total readers ------------------------------------- *)

let empty_stream : Error.t =
  Error.parse (Error.point (Error.pos 1 1)) "the token list is empty"

let fail (tk : Lexer.t) (text : string) : ('a, Error.t) result =
  Error (Error.parse (Lexer.span_of tk) text)

let take (ts : stream) : (Lexer.t * stream, Error.t) result =
  match ts with
  | [] -> Error empty_stream
  | tk :: rest -> Ok (tk, rest)

let head (ts : stream) : Lexer.t option =
  match ts with
  | [] -> None
  | tk :: _rest -> Some tk

let head2 (ts : stream) : Lexer.t option =
  match ts with
  | [] -> None
  | _tk :: rest -> head rest

let name_of (tk : Lexer.t) : string option =
  match Lexer.kind_of tk with
  | Lexer.Name n -> Some n
  | Lexer.Kw _ -> None
  | Lexer.Int _ -> None
  | Lexer.Str _ -> None
  | Lexer.Sym _ -> None
  | Lexer.Eof -> None

(* A label and a manifest kind word take a keyword too, because store,
   pod, port and service are keywords of the language and field names of
   the surface at the same time. *)
let word_of (tk : Lexer.t) : string option =
  match Lexer.kind_of tk with
  | Lexer.Name n -> Some n
  | Lexer.Kw w -> Some w
  | Lexer.Int _ -> None
  | Lexer.Str _ -> None
  | Lexer.Sym _ -> None
  | Lexer.Eof -> None

let int_of (tk : Lexer.t) : int option =
  match Lexer.kind_of tk with
  | Lexer.Int n -> Some n
  | Lexer.Name _ -> None
  | Lexer.Kw _ -> None
  | Lexer.Str _ -> None
  | Lexer.Sym _ -> None
  | Lexer.Eof -> None

let sym_of (tk : Lexer.t) : string option =
  match Lexer.kind_of tk with
  | Lexer.Sym y -> Some y
  | Lexer.Name _ -> None
  | Lexer.Kw _ -> None
  | Lexer.Int _ -> None
  | Lexer.Str _ -> None
  | Lexer.Eof -> None

let at_sym (y : string) (ts : stream) : bool =
  Option.fold ~none:false ~some:(Lexer.is_sym y) (head ts)

let at_kw (w : string) (ts : stream) : bool =
  Option.fold ~none:false ~some:(Lexer.is_kw w) (head ts)

let at_eof (ts : stream) : bool =
  Option.fold ~none:true ~some:Lexer.is_eof (head ts)

let expect_sym (y : string) (text : string) (ts : stream)
  : (stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      if Lexer.is_sym y tk then Ok rest else fail tk text)

let expect_kw (w : string) (text : string) (ts : stream)
  : (stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      if Lexer.is_kw w tk then Ok rest else fail tk text)

let expect_name (text : string) (ts : stream)
  : (Ident.t * stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      Option.fold ~none:(fail tk text)
        ~some:(fun n -> Ok (Ident.of_string n, rest))
        (name_of tk))

let expect_word (text : string) (ts : stream)
  : (Ident.t * stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      Option.fold ~none:(fail tk text)
        ~some:(fun w -> Ok (Ident.of_string w, rest))
        (word_of tk))

let expect_label (text : string) (ts : stream)
  : (Label.t * stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      Option.fold ~none:(fail tk text)
        ~some:(fun w -> Ok (Label.of_string w, rest))
        (word_of tk))

let expect_int (text : string) (ts : stream)
  : (int * stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      Option.fold ~none:(fail tk text) ~some:(fun n -> Ok (n, rest))
        (int_of tk))

(* --- the operator table (D-A-13) ---------------------------------- *)

let binop_of (gt : bool) (y : string) : Ast.binop option =
  match () with
  | () when String.equal y "||" -> Some Ast.Or
  | () when String.equal y "&&" -> Some Ast.And
  | () when String.equal y "==" -> Some Ast.Eq
  | () when String.equal y "!=" -> Some Ast.Ne
  | () when String.equal y "<" -> Some Ast.Lt
  | () when String.equal y "<=" -> Some Ast.Le
  | () when String.equal y ">" && gt -> Some Ast.Gt
  | () when String.equal y ">=" && gt -> Some Ast.Ge
  | () when String.equal y "+" -> Some Ast.Add
  | () when String.equal y "-" -> Some Ast.Sub
  | () when String.equal y "^" -> Some Ast.Cat
  | () when String.equal y "*" -> Some Ast.Mul
  | () when String.equal y "%" -> Some Ast.Mod
  | () when String.equal y "/" -> Some Ast.Div
  | () -> None

let op_at (gt : bool) (ts : stream) : Ast.binop option =
  Option.bind (head ts) (fun tk ->
      Option.bind (sym_of tk) (fun y -> binop_of gt y))

let assoc_right (lvl : int) : bool = lvl <= 2

let assoc_none (lvl : int) : bool = lvl = 3

(* An argument of an application.  The byte < is left out, because after
   an atom it is Lt and a variant literal in an argument position needs
   parentheses (D-A-14). *)
let starts_arg (tk : Lexer.t) : bool =
  match Lexer.kind_of tk with
  | Lexer.Int _ -> true
  | Lexer.Str _ -> true
  | Lexer.Name _ -> true
  | Lexer.Kw w -> String.equal w "true" || String.equal w "false"
  | Lexer.Sym y -> String.equal y "(" || String.equal y "{"
  | Lexer.Eof -> false

let starts_pat_tok (tk : Lexer.t) : bool =
  match Lexer.kind_of tk with
  | Lexer.Int _ -> true
  | Lexer.Str _ -> true
  | Lexer.Name _ -> true
  | Lexer.Kw w -> String.equal w "true" || String.equal w "false"
  | Lexer.Sym y ->
    String.equal y "(" || String.equal y "{" || String.equal y "_"
  | Lexer.Eof -> false

let starts_pat (ts : stream) : bool =
  Option.fold ~none:false ~some:starts_pat_tok (head ts)

(* A field of a record literal:  a word and then an equals sign.  A row
   field of a type:  a word and then a colon. *)
let field_start (ts : stream) : bool =
  Option.fold ~none:false ~some:(fun tk -> Option.is_some (word_of tk))
    (head ts)
  && Option.fold ~none:false ~some:(Lexer.is_sym "=") (head2 ts)

let row_field_start (ts : stream) : bool =
  Option.fold ~none:false ~some:(fun tk -> Option.is_some (word_of tk))
    (head ts)
  && Option.fold ~none:false ~some:(Lexer.is_sym ":") (head2 ts)

(* --- the milestone table (D-A-11) --------------------------------- *)

let m1_words =
  [ "node";  "leader";  "registry";  "placement";  "heartbeat";  "pod";
    "store" ]

let m2_words = [ "service";  "taint";  "drain";  "doorbell";  "volume" ]

let m3_words = [ "proof";  "port" ]

let m4_words = [ "fuel";  "cost_table";  "blob" ]

let holds (ws : string list) (w : string) : bool =
  List.exists (String.equal w) ws

let milestone_of (w : string) : Ast.milestone option =
  match () with
  | () when holds m1_words w -> Some Ast.M1
  | () when holds m2_words w -> Some Ast.M2
  | () when holds m3_words w -> Some Ast.M3
  | () when holds m4_words w -> Some Ast.M4
  | () -> None

(* --- the leg split of a protocol state (D-A-7) -------------------- *)

(* A leg reads l : ty -> S2, and the type parser is greedy over the
   arrow, so the last arm of the arrow chain is the state name and the
   rest is the type the leg carries. *)
let rec split_leg (t : Ast.ty) : (Ast.ty * string) option =
  match t with
  | Ast.TArrow (a, m, r) -> split_arrow a m r
  | Ast.TName _ -> None
  | Ast.TRec _ -> None
  | Ast.TVar _ -> None
  | Ast.TCode (_, _) -> None

and split_arrow (a : Ast.ty) (m : Ast.mult) (r : Ast.ty)
  : (Ast.ty * string) option =
  match r with
  | Ast.TName s -> split_last a m s
  | Ast.TArrow (_, _, _) ->
    Option.map (fun (r2, s) -> (Ast.TArrow (a, m, r2), s)) (split_leg r)
  | Ast.TRec _ -> None
  | Ast.TVar _ -> None
  | Ast.TCode (_, _) -> None

and split_last (a : Ast.ty) (m : Ast.mult) (s : string)
  : (Ast.ty * string) option =
  match m with
  | Ast.Many -> Some (a, s)
  | Ast.AtMostOnce -> None

(* --- expressions, patterns and types ------------------------------ *)

let rec expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  bin_at gt 1 ts

and bin_at (gt : bool) (lvl : int) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  if lvl > 5 then app_expr gt ts
  else
    Result.bind (bin_at gt (lvl + 1) ts) (fun (lhs, rest) ->
        bin_more gt lvl lhs rest)

and bin_more (gt : bool) (lvl : int) (lhs : Ast.expr) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Option.fold ~none:(Ok (lhs, ts))
    ~some:(fun op ->
      if Ast.binop_level op = lvl then bin_rhs gt lvl op lhs ts
      else Ok (lhs, ts))
    (op_at gt ts)

and bin_rhs (gt : bool) (lvl : int) (op : Ast.binop) (lhs : Ast.expr)
    (ts : stream) : (Ast.expr * stream, Error.t) result =
  Result.bind (take ts) (fun (_op_tok, rest) ->
      match () with
      | () when assoc_none lvl ->
        Result.bind (bin_at gt (lvl + 1) rest) (fun (rhs, r2) ->
            no_chain gt lvl (Ast.Bin (op, lhs, rhs)) r2)
      | () when assoc_right lvl ->
        Result.bind (bin_at gt lvl rest) (fun (rhs, r2) ->
            Ok (Ast.Bin (op, lhs, rhs), r2))
      | () ->
        Result.bind (bin_at gt (lvl + 1) rest) (fun (rhs, r2) ->
            bin_more gt lvl (Ast.Bin (op, lhs, rhs)) r2))

(* The comparison group is non-associative, so a < b < c is a failure
   and not a nest (D-A-13). *)
and no_chain (gt : bool) (lvl : int) (node : Ast.expr) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Option.fold ~none:(Ok (node, ts))
    ~some:(fun op ->
      if Ast.binop_level op = lvl then
        Result.bind (take ts) (fun (tk, _rest) ->
            fail tk "the comparison does not chain")
      else Ok (node, ts))
    (op_at gt ts)

and app_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Result.bind (atom_expr gt ts) (fun (f, rest) -> app_more gt f rest)

and app_more (gt : bool) (f : Ast.expr) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Option.fold ~none:(Ok (f, ts))
    ~some:(fun tk ->
      if starts_arg tk then
        Result.bind (atom_expr gt ts) (fun (x, rest) ->
            app_more gt (Ast.App (f, x)) rest)
      else Ok (f, ts))
    (head ts)

and atom_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      match Lexer.kind_of tk with
      | Lexer.Int n -> post_expr gt (Ast.Lit (Literal.Int n)) rest
      | Lexer.Str s -> post_expr gt (Ast.Lit (Literal.Str s)) rest
      | Lexer.Name n -> post_expr gt (Ast.Var (Ident.of_string n)) rest
      | Lexer.Kw w -> kw_expr gt tk w rest
      | Lexer.Sym y -> sym_expr gt tk y rest
      | Lexer.Eof -> fail tk "expected an expression")

and post_expr (gt : bool) (e : Ast.expr) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  if at_sym "." ts then
    Result.bind (take ts) (fun (_dot, r1) ->
        Result.bind (expect_label "expected a field name after the point" r1)
          (fun (l, r2) -> post_expr gt (Ast.Sel (e, l)) r2))
  else Ok (e, ts)

and kw_expr (gt : bool) (tk : Lexer.t) (w : string) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  match () with
  | () when String.equal w "true" ->
    post_expr gt (Ast.Lit (Literal.Bool true)) ts
  | () when String.equal w "false" ->
    post_expr gt (Ast.Lit (Literal.Bool false)) ts
  | () when String.equal w "fun" -> lam_expr gt ts
  | () when String.equal w "if" -> if_expr gt ts
  | () when String.equal w "match" -> match_expr gt ts
  | () when String.equal w "let" -> let_expr gt ts
  | () -> fail tk "expected an expression"

and sym_expr (gt : bool) (tk : Lexer.t) (y : string) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  match () with
  | () when String.equal y "(" -> paren_expr gt ts
  | () when String.equal y "{" -> brace_expr gt ts
  | () when String.equal y "<" -> inj_expr gt ts
  | () -> fail tk "expected an expression"

and paren_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  if at_sym ")" ts then
    Result.bind (take ts) (fun (_close, r1) ->
        post_expr gt (Ast.Lit Literal.Unit) r1)
  else
    Result.bind (expr true ts) (fun (e, r1) ->
        if at_sym ":" r1 then
          Result.bind (take r1) (fun (_colon, r2) ->
              Result.bind (ty r2) (fun (t, r3) ->
                  Result.bind
                    (expect_sym ")" "expected a closing parenthesis" r3)
                    (fun r4 -> post_expr gt (Ast.Ann (e, t)) r4)))
        else
          Result.bind (expect_sym ")" "expected a closing parenthesis" r1)
            (fun r2 -> post_expr gt e r2))

(* Inside braces (D-A-14):  a closing brace first is the empty record;  a
   label and an equals sign start the field list;  anything else is the
   restriction form. *)
and brace_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  match () with
  | () when at_sym "}" ts ->
    Result.bind (take ts) (fun (_close, r1) -> post_expr gt (Ast.Rec []) r1)
  | () when field_start ts -> rec_fields gt [] ts
  | () -> res_expr gt ts

and rec_fields (gt : bool) (acc : (Label.t * Ast.expr) list) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Result.bind (expect_label "expected a field name" ts) (fun (l, r1) ->
      Result.bind (expect_sym "=" "expected an equals sign" r1) (fun r2 ->
          Result.bind (expr true r2) (fun (v, r3) ->
              rec_next gt ((l, v) :: acc) r3)))

and rec_next (gt : bool) (acc : (Label.t * Ast.expr) list) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  match () with
  | () when at_sym "," ts ->
    Result.bind (take ts) (fun (_comma, r1) -> rec_fields gt acc r1)
  | () when at_sym "|" ts ->
    Result.bind (take ts) (fun (_bar, r1) ->
        Result.bind (expr true r1) (fun (tail, r2) ->
            Result.bind (expect_sym "}" "expected a closing brace" r2)
              (fun r3 -> post_expr gt (build_ext (List.rev acc) tail) r3)))
  | () ->
    Result.bind (expect_sym "}" "expected a closing brace" ts) (fun r1 ->
        post_expr gt (Ast.Rec (List.rev acc)) r1)

and build_ext (fs : (Label.t * Ast.expr) list) (tail : Ast.expr) : Ast.expr =
  List.fold_right (fun (l, v) t -> Ast.RecExt (l, v, t)) fs tail

(* The restriction form { e - l }.  Its leading expression is an
   application of atoms alone (D-A-14). *)
and res_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Result.bind (atom_expr true ts) (fun (f, r1) ->
      Result.bind (app_more true f r1) (fun (e, r2) ->
          Result.bind
            (expect_sym "-" "expected a minus sign in the restriction" r2)
            (fun r3 ->
              Result.bind
                (expect_label "expected the field name that goes away" r3)
                (fun (l, r4) ->
                  Result.bind (expect_sym "}" "expected a closing brace" r4)
                    (fun r5 -> post_expr gt (Ast.RecRes (e, l)) r5)))))

and inj_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Result.bind (expect_label "expected a variant label" ts) (fun (l, r1) ->
      Result.bind (occ_opt r1) (fun (k, r2) ->
          Result.bind (expr false r2) (fun (payload, r3) ->
              Result.bind
                (expect_sym ">" "expected a closing angle bracket" r3)
                (fun r4 -> post_expr gt (Ast.Inj (l, k, payload)) r4))))

and occ_opt (ts : stream) : (Label.occ * stream, Error.t) result =
  if at_sym "^" ts then
    Result.bind (take ts) (fun (_hat, r1) ->
        Result.bind (expect_int "expected an occurrence index" r1)
          (fun (n, r2) -> Ok (Label.occ_of_int n, r2)))
  else Ok (Label.occ_of_int 0, ts)

and lam_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Result.bind (params [] ts) (fun (ps, r1) ->
      Result.bind (expect_sym "->" "expected an arrow after the parameters" r1)
        (fun r2 ->
          Result.bind (expr gt r2) (fun (body, r3) ->
              Ok (List.fold_right (fun p b -> Ast.Lam (p, b)) ps body, r3))))

and params (acc : Ast.pat list) (ts : stream)
  : (Ast.pat list * stream, Error.t) result =
  match () with
  | () when starts_pat ts ->
    Result.bind (atom_pat ts) (fun (p, rest) -> params (p :: acc) rest)
  | () when List.length acc = 0 ->
    Result.bind (take ts) (fun (tk, _rest) -> fail tk "expected a parameter")
  | () -> Ok (List.rev acc, ts)

and params_opt (acc : Ast.pat list) (ts : stream)
  : (Ast.pat list * stream, Error.t) result =
  if starts_pat ts then
    Result.bind (atom_pat ts) (fun (p, rest) -> params_opt (p :: acc) rest)
  else Ok (List.rev acc, ts)

and if_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Result.bind (expr gt ts) (fun (c, r1) ->
      Result.bind (expect_kw "then" "expected the word then" r1) (fun r2 ->
          Result.bind (expr gt r2) (fun (a, r3) ->
              Result.bind (expect_kw "else" "expected the word else" r3)
                (fun r4 ->
                  Result.bind (expr gt r4) (fun (b, r5) ->
                      Ok (Ast.If (c, a, b), r5))))))

and match_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  Result.bind (expr gt ts) (fun (scrut, r1) ->
      Result.bind (expect_kw "with" "expected the word with" r1) (fun r2 ->
          Result.bind (arms gt [] r2) (fun (rows, r3) ->
              Ok (Ast.Match (scrut, rows), r3))))

and arms (gt : bool) (acc : Ast.arm list) (ts : stream)
  : (Ast.arm list * stream, Error.t) result =
  match () with
  | () when at_sym "|" ts ->
    Result.bind (take ts) (fun (_bar, r1) ->
        Result.bind (pat r1) (fun (p, r2) ->
            Result.bind
              (expect_sym "->" "expected an arrow after the pattern" r2)
              (fun r3 ->
                Result.bind (expr gt r3) (fun (b, r4) ->
                    arms gt ((p, b) :: acc) r4))))
  | () when List.length acc = 0 ->
    Result.bind (take ts) (fun (tk, _rest) ->
        fail tk "the match needs at least one arm")
  | () -> Ok (List.rev acc, ts)

and let_expr (gt : bool) (ts : stream)
  : (Ast.expr * stream, Error.t) result =
  if at_kw "rec" ts then
    Result.bind (take ts) (fun (_rec, r1) ->
        Result.bind (binds [] r1) (fun (bs, r2) ->
            Result.bind (expect_kw "in" "expected the word in" r2) (fun r3 ->
                Result.bind (expr gt r3) (fun (b, r4) ->
                    Ok (Ast.LetRec (bs, b), r4)))))
  else
    Result.bind (pat ts) (fun (p, r1) ->
        Result.bind (expect_sym "=" "expected an equals sign" r1) (fun r2 ->
            Result.bind (expr true r2) (fun (v, r3) ->
                Result.bind (expect_kw "in" "expected the word in" r3)
                  (fun r4 ->
                    Result.bind (expr gt r4) (fun (b, r5) ->
                        Ok (Ast.Let (p, v, b), r5))))))

and binds (acc : Ast.bind list) (ts : stream)
  : (Ast.bind list * stream, Error.t) result =
  Result.bind (expect_name "expected a name" ts) (fun (n, r1) ->
      Result.bind (params_opt [] r1) (fun (ps, r2) ->
          Result.bind (expect_sym "=" "expected an equals sign" r2)
            (fun r3 ->
              Result.bind (expr true r3) (fun (v, r4) ->
                  binds_more
                    ((n, List.fold_right (fun p b -> Ast.Lam (p, b)) ps v)
                     :: acc)
                    r4))))

and binds_more (acc : Ast.bind list) (ts : stream)
  : (Ast.bind list * stream, Error.t) result =
  if at_kw "and" ts then
    Result.bind (take ts) (fun (_and, r1) -> binds acc r1)
  else Ok (List.rev acc, ts)

(* --- patterns ----------------------------------------------------- *)

and pat (ts : stream) : (Ast.pat * stream, Error.t) result =
  if at_sym "<" ts then
    Result.bind (take ts) (fun (_open, r1) ->
        Result.bind (expect_label "expected a variant label" r1)
          (fun (l, r2) ->
            Result.bind (occ_opt r2) (fun (k, r3) ->
                Result.bind (pat r3) (fun (p, r4) ->
                    Result.bind
                      (expect_sym ">" "expected a closing angle bracket" r4)
                      (fun r5 -> Ok (Ast.PInj (l, k, p), r5))))))
  else atom_pat ts

and atom_pat (ts : stream) : (Ast.pat * stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      match Lexer.kind_of tk with
      | Lexer.Int n -> Ok (Ast.PLit (Literal.Int n), rest)
      | Lexer.Str s -> Ok (Ast.PLit (Literal.Str s), rest)
      | Lexer.Name n -> Ok (Ast.PVar (Ident.of_string n), rest)
      | Lexer.Kw w -> kw_pat tk w rest
      | Lexer.Sym y -> sym_pat tk y rest
      | Lexer.Eof -> fail tk "expected a pattern")

and kw_pat (tk : Lexer.t) (w : string) (ts : stream)
  : (Ast.pat * stream, Error.t) result =
  match () with
  | () when String.equal w "true" -> Ok (Ast.PLit (Literal.Bool true), ts)
  | () when String.equal w "false" -> Ok (Ast.PLit (Literal.Bool false), ts)
  | () -> fail tk "expected a pattern"

and sym_pat (tk : Lexer.t) (y : string) (ts : stream)
  : (Ast.pat * stream, Error.t) result =
  match () with
  | () when String.equal y "_" -> Ok (Ast.PWild, ts)
  | () when String.equal y "(" -> paren_pat ts
  | () when String.equal y "{" -> rec_pat [] ts
  | () -> fail tk "expected a pattern"

and paren_pat (ts : stream) : (Ast.pat * stream, Error.t) result =
  if at_sym ")" ts then
    Result.bind (take ts) (fun (_close, r1) -> Ok (Ast.PLit Literal.Unit, r1))
  else
    Result.bind (pat ts) (fun (p, r1) ->
        Result.bind (expect_sym ")" "expected a closing parenthesis" r1)
          (fun r2 -> Ok (p, r2)))

and rec_pat (acc : (Label.t * Label.occ * Ast.pat) list) (ts : stream)
  : (Ast.pat * stream, Error.t) result =
  match () with
  | () when at_sym "}" ts ->
    Result.bind (take ts) (fun (_close, r1) ->
        Ok (Ast.PRec (List.rev acc, None), r1))
  | () when at_sym "|" ts ->
    Result.bind (take ts) (fun (_bar, r1) ->
        Result.bind (expect_name "expected a row tail name" r1)
          (fun (n, r2) ->
            Result.bind (expect_sym "}" "expected a closing brace" r2)
              (fun r3 -> Ok (Ast.PRec (List.rev acc, Some n), r3))))
  | () ->
    Result.bind (expect_label "expected a field name" ts) (fun (l, r1) ->
        Result.bind (occ_opt r1) (fun (k, r2) ->
            Result.bind (expect_sym "=" "expected an equals sign" r2)
              (fun r3 ->
                Result.bind (pat r3) (fun (p, r4) ->
                    rec_pat_more ((l, k, p) :: acc) r4))))

and rec_pat_more (acc : (Label.t * Label.occ * Ast.pat) list) (ts : stream)
  : (Ast.pat * stream, Error.t) result =
  if at_sym "," ts then
    Result.bind (take ts) (fun (_comma, r1) -> rec_pat acc r1)
  else rec_pat acc ts

(* --- types -------------------------------------------------------- *)

and ty (ts : stream) : (Ast.ty * stream, Error.t) result =
  Result.bind (ty_atom ts) (fun (a, r1) ->
      match () with
      | () when at_sym "->" r1 ->
        Result.bind (take r1) (fun (_arrow, r2) ->
            Result.bind (ty r2) (fun (b, r3) ->
                Ok (Ast.TArrow (a, Ast.Many, b), r3)))
      | () when at_sym "-1>" r1 ->
        Result.bind (take r1) (fun (_arrow, r2) ->
            Result.bind (ty r2) (fun (b, r3) ->
                Ok (Ast.TArrow (a, Ast.AtMostOnce, b), r3)))
      | () -> Ok (a, r1))

and ty_atom (ts : stream) : (Ast.ty * stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      match Lexer.kind_of tk with
      | Lexer.Name n -> Ok (Ast.TName n, rest)
      | Lexer.Kw w -> ty_kw tk w rest
      | Lexer.Sym y -> ty_sym tk y rest
      | Lexer.Int _ -> fail tk "expected a type"
      | Lexer.Str _ -> fail tk "expected a type"
      | Lexer.Eof -> fail tk "expected a type")

and ty_kw (tk : Lexer.t) (w : string) (ts : stream)
  : (Ast.ty * stream, Error.t) result =
  if String.equal w "Code" then
    Result.bind
      (expect_sym "[" "expected an opening bracket after the word Code" ts)
      (fun r1 -> code_ty r1)
  else fail tk "expected a type"

and code_ty (ts : stream) : (Ast.ty * stream, Error.t) result =
  Result.bind (row_fields [] ts) (fun (r, r1) ->
      Result.bind (expect_sym "," "expected a comma before the code type" r1)
        (fun r2 ->
          Result.bind (ty r2) (fun (t, r3) ->
              Result.bind (expect_sym "]" "expected a closing bracket" r3)
                (fun r4 -> Ok (Ast.TCode (r, t), r4)))))

and ty_sym (tk : Lexer.t) (y : string) (ts : stream)
  : (Ast.ty * stream, Error.t) result =
  match () with
  | () when String.equal y "{" ->
    Result.bind (row_fields [] ts) (fun (r, r1) ->
        Result.bind (expect_sym "}" "expected a closing brace" r1)
          (fun r2 -> Ok (Ast.TRec r, r2)))
  | () when String.equal y "<" ->
    Result.bind (row_fields [] ts) (fun (r, r1) ->
        Result.bind (expect_sym ">" "expected a closing angle bracket" r1)
          (fun r2 -> Ok (Ast.TVar r, r2)))
  | () when String.equal y "(" ->
    Result.bind (ty ts) (fun (t, r1) ->
        Result.bind (expect_sym ")" "expected a closing parenthesis" r1)
          (fun r2 -> Ok (t, r2)))
  | () -> fail tk "expected a type"

(* A row stops at the first item that is not a field, so the trailing
   type of Code [ l : t | r , u ] stays for the caller. *)
and row_fields (acc : (Label.t * Ast.ty) list) (ts : stream)
  : (Ast.trow * stream, Error.t) result =
  match () with
  | () when at_sym "|" ts ->
    Result.bind (take ts) (fun (_bar, r1) ->
        Result.bind (expect_name "expected a row tail name" r1)
          (fun (n, r2) ->
            Ok
              ( { Ast.fields = List.rev acc;
                  tail = Some (Ident.to_string n) },
                r2 )))
  | () when row_field_start ts ->
    Result.bind (expect_label "expected a field name" ts) (fun (l, r1) ->
        Result.bind (expect_sym ":" "expected a colon" r1) (fun r2 ->
            Result.bind (ty r2) (fun (t, r3) ->
                row_more ((l, t) :: acc) r3)))
  | () -> Ok ({ Ast.fields = List.rev acc;  tail = None }, ts)

and row_more (acc : (Label.t * Ast.ty) list) (ts : stream)
  : (Ast.trow * stream, Error.t) result =
  if at_sym "," ts then
    Result.bind (take ts) (fun (_comma, r1) ->
        if row_field_start r1 || at_sym "|" r1 then row_fields acc r1
        else Ok ({ Ast.fields = List.rev acc;  tail = None }, ts))
  else row_fields acc ts

(* --- declarations (brief 3.5) ------------------------------------- *)

let rec decl (ts : stream) : (Ast.decl * stream, Error.t) result =
  Result.bind (take ts) (fun (tk, rest) ->
      match Lexer.kind_of tk with
      | Lexer.Kw w -> decl_kw tk w rest
      | Lexer.Sym y ->
        if String.equal y "@" then budget_decl rest
        else fail tk "expected a declaration"
      | Lexer.Name _ -> fail tk "expected a declaration"
      | Lexer.Int _ -> fail tk "expected a declaration"
      | Lexer.Str _ -> fail tk "expected a declaration"
      | Lexer.Eof -> fail tk "expected a declaration")

and decl_kw (tk : Lexer.t) (w : string) (ts : stream)
  : (Ast.decl * stream, Error.t) result =
  match () with
  | () when String.equal w "let" -> let_decl ts
  | () when String.equal w "import" -> import_decl ts
  | () when String.equal w "protocol" -> protocol_decl ts
  | () when String.equal w "role" -> role_decl ts
  | () when String.equal w "freeze" -> freeze_decl ts
  | () when String.equal w "manifest" -> manifest_decl ts
  | () -> milestone_decl tk w ts

and let_decl (ts : stream) : (Ast.decl * stream, Error.t) result =
  if at_kw "rec" ts then
    Result.bind (take ts) (fun (_rec, r1) ->
        Result.bind (binds [] r1) (fun (bs, r2) -> Ok (Ast.DLetRec bs, r2)))
  else
    Result.bind (expect_name "expected a name after the word let" ts)
      (fun (n, r1) ->
        Result.bind (params_opt [] r1) (fun (ps, r2) ->
            Result.bind (expect_sym "=" "expected an equals sign" r2)
              (fun r3 ->
                Result.bind (expr true r3) (fun (v, r4) ->
                    Ok
                      ( Ast.DLet
                          ( n,
                            List.fold_right
                              (fun p b -> Ast.Lam (p, b))
                              ps v ),
                        r4 )))))

and import_decl (ts : stream) : (Ast.decl * stream, Error.t) result =
  Result.bind (expect_name "expected a name after the word import" ts)
    (fun (n, r1) ->
      Result.bind (expect_sym ":" "expected a colon" r1) (fun r2 ->
          Result.bind (ty r2) (fun (t, r3) ->
              Result.bind (expect_kw "cost" "the import needs the word cost" r3)
                (fun r4 ->
                  Result.bind (expect_int "expected the cost index" r4)
                    (fun (c, r5) ->
                      Result.bind
                        (expect_kw "deadline"
                           "the import needs the word deadline" r5)
                        (fun r6 ->
                          Result.bind
                            (expect_int
                               "expected the deadline in whole milliseconds" r6)
                            (fun (d, r7) ->
                              Ok
                                ( Ast.DImport
                                    { Ast.iname = n;
                                      ity = t;
                                      cost = c;
                                      deadline_ms = d
                                    },
                                  r7 ))))))))

and budget_decl (ts : stream) : (Ast.decl * stream, Error.t) result =
  Result.bind
    (expect_kw "budget" "expected the word budget after the at sign" ts)
    (fun r1 ->
      Result.bind (expect_sym "{" "expected an opening brace" r1) (fun r2 ->
          Result.bind (budget_fields [] r2) (fun (fs, r3) ->
              if at_eof r3 then
                Result.bind (take r3) (fun (tk, _rest) ->
                    fail tk
                      "the budget annotation needs a declaration after it")
              else
                Result.bind (decl r3) (fun (d, r4) ->
                    Ok (Ast.DBudget (fs, d), r4)))))

and budget_fields (acc : (Label.t * int) list) (ts : stream)
  : ((Label.t * int) list * stream, Error.t) result =
  if at_sym "}" ts then
    Result.bind (take ts) (fun (_close, r1) -> Ok (List.rev acc, r1))
  else
    Result.bind (expect_label "expected a budget name" ts) (fun (l, r1) ->
        Result.bind (expect_sym "=" "expected an equals sign" r1) (fun r2 ->
            Result.bind (expect_int "expected a whole number" r2)
              (fun (v, r3) -> budget_more ((l, v) :: acc) r3)))

and budget_more (acc : (Label.t * int) list) (ts : stream)
  : ((Label.t * int) list * stream, Error.t) result =
  if at_sym "," ts then
    Result.bind (take ts) (fun (_comma, r1) -> budget_fields acc r1)
  else budget_fields acc ts

and protocol_decl (ts : stream) : (Ast.decl * stream, Error.t) result =
  Result.bind (expect_name "expected a protocol name" ts) (fun (n, r1) ->
      Result.bind (expect_sym "{" "expected an opening brace" r1) (fun r2 ->
          Result.bind (states [] r2) (fun (ss, r3) ->
              Ok (Ast.DProtocol { Ast.pname = n;  states = ss }, r3))))

and states (acc : Ast.pstate list) (ts : stream)
  : (Ast.pstate list * stream, Error.t) result =
  if at_sym "}" ts then
    Result.bind (take ts) (fun (_close, r1) -> Ok (List.rev acc, r1))
  else
    Result.bind (expect_kw "state" "expected the word state" ts) (fun r1 ->
        Result.bind (expect_name "expected a state name" r1) (fun (n, r2) ->
            Result.bind (expect_sym "{" "expected an opening brace" r2)
              (fun r3 ->
                Result.bind (legs [] r3) (fun (ls, r4) ->
                    Result.bind (compensate_opt r4) (fun (c, r5) ->
                        states
                          ({ Ast.sname = n;  legs = ls;  compensate = c }
                           :: acc)
                          r5)))))

and legs (acc : (Label.t * Ast.ty * Ident.t) list) (ts : stream)
  : ((Label.t * Ast.ty * Ident.t) list * stream, Error.t) result =
  if at_sym "}" ts then
    Result.bind (take ts) (fun (_close, r1) -> Ok (List.rev acc, r1))
  else
    Result.bind (expect_label "expected a leg label" ts) (fun (l, r1) ->
        Result.bind (expect_sym ":" "expected a colon" r1) (fun r2 ->
            Result.bind (ty r2) (fun (t, r3) ->
                Option.fold ~none:(leg_error r3)
                  ~some:(fun (carry, target) ->
                    legs_more ((l, carry, Ident.of_string target) :: acc) r3)
                  (split_leg t))))

and leg_error (ts : stream)
  : ((Label.t * Ast.ty * Ident.t) list * stream, Error.t) result =
  Result.bind (take ts) (fun (tk, _rest) ->
      fail tk "the leg needs an arrow and a state name")

and legs_more (acc : (Label.t * Ast.ty * Ident.t) list) (ts : stream)
  : ((Label.t * Ast.ty * Ident.t) list * stream, Error.t) result =
  if at_sym "," ts then
    Result.bind (take ts) (fun (_comma, r1) -> legs acc r1)
  else legs acc ts

and compensate_opt (ts : stream)
  : (Ast.expr option * stream, Error.t) result =
  if at_kw "compensate" ts then
    Result.bind (take ts) (fun (_word, r1) ->
        Result.bind (expr true r1) (fun (e, r2) -> Ok (Some e, r2)))
  else Ok (None, ts)

and role_decl (ts : stream) : (Ast.decl * stream, Error.t) result =
  Result.bind (expect_name "expected a role name" ts) (fun (n, r1) ->
      Result.bind (expect_sym ":" "expected a colon" r1) (fun r2 ->
          Result.bind (expect_name "expected a protocol name" r2)
            (fun (p, r3) ->
              Result.bind (expect_sym "{" "expected an opening brace" r3)
                (fun r4 ->
                  Result.bind (clauses [] None None r4)
                    (fun (cs, pl, ab, r5) ->
                      Ok
                        ( Ast.DRole
                            { Ast.rname = n;
                              proto = p;
                              clauses = cs;
                              peer_lost = pl;
                              abort = ab
                            },
                          r5 ))))))

and clauses (acc : (Label.t * Ident.t list * Ast.expr) list)
    (pl : Ast.expr option) (ab : Ast.expr option) (ts : stream)
  : ((Label.t * Ident.t list * Ast.expr) list * Ast.expr option
     * Ast.expr option * stream, Error.t) result =
  match () with
  | () when at_sym "}" ts ->
    Result.bind (take ts) (fun (_close, r1) -> Ok (List.rev acc, pl, ab, r1))
  | () when at_kw "Peer_lost" ts && Option.is_some pl ->
    Result.bind (take ts) (fun (tk, _rest) ->
        fail tk "the role has more than one Peer_lost handler")
  | () when at_kw "abort" ts && Option.is_some ab ->
    Result.bind (take ts) (fun (tk, _rest) ->
        fail tk "the role has more than one abort handler")
  | () when at_kw "Peer_lost" ts ->
    Result.bind (take ts) (fun (_word, r1) ->
        Result.bind (expect_sym "->" "expected an arrow" r1) (fun r2 ->
            Result.bind (expr true r2) (fun (e, r3) ->
                clauses_more acc (Some e) ab r3)))
  | () when at_kw "abort" ts ->
    Result.bind (take ts) (fun (_word, r1) ->
        Result.bind (expect_sym "->" "expected an arrow" r1) (fun r2 ->
            Result.bind (expr true r2) (fun (e, r3) ->
                clauses_more acc pl (Some e) r3)))
  | () ->
    Result.bind (expect_label "expected a clause label" ts) (fun (l, r1) ->
        Result.bind (clause_params [] r1) (fun (ps, r2) ->
            Result.bind (expect_sym "->" "expected an arrow" r2) (fun r3 ->
                Result.bind (expr true r3) (fun (e, r4) ->
                    clauses_more ((l, ps, e) :: acc) pl ab r4))))

and clauses_more (acc : (Label.t * Ident.t list * Ast.expr) list)
    (pl : Ast.expr option) (ab : Ast.expr option) (ts : stream)
  : ((Label.t * Ident.t list * Ast.expr) list * Ast.expr option
     * Ast.expr option * stream, Error.t) result =
  if at_sym "," ts then
    Result.bind (take ts) (fun (_comma, r1) -> clauses acc pl ab r1)
  else clauses acc pl ab ts

and clause_params (acc : Ident.t list) (ts : stream)
  : (Ident.t list * stream, Error.t) result =
  Option.fold ~none:(Ok (List.rev acc, ts))
    ~some:(fun tk ->
      Option.fold ~none:(Ok (List.rev acc, ts))
        ~some:(fun n ->
          Result.bind (take ts) (fun (_word, r1) ->
              clause_params (Ident.of_string n :: acc) r1))
        (name_of tk))
    (head ts)

(* The one legal handler row is { store } (D-A-8). *)
and freeze_decl (ts : stream) : (Ast.decl * stream, Error.t) result =
  Result.bind
    (expect_sym "{" "the freeze handler row is { store } and no other" ts)
    (fun r1 ->
      Result.bind
        (expect_label "the freeze handler row is { store } and no other" r1)
        (fun (l, r2) ->
          if Label.equal l (Label.of_string "store") then
            Result.bind
              (expect_sym "}"
                 "the freeze handler row is { store } and no other" r2)
              (fun r3 ->
                Result.bind (expect_sym "=" "expected an equals sign" r3)
                  (fun r4 ->
                    Result.bind (expr true r4) (fun (e, r5) ->
                        Ok (Ast.DFreeze ([ l ], e), r5))))
          else
            Result.bind (take r1) (fun (tk, _rest) ->
                fail tk "the freeze handler row is { store } and no other")))

and manifest_decl (ts : stream) : (Ast.decl * stream, Error.t) result =
  Result.bind (expect_name "expected a manifest name" ts) (fun (n, r1) ->
      Result.bind (expect_sym "{" "expected an opening brace" r1) (fun r2 ->
          Result.bind (entries [] r2) (fun (es, r3) ->
              Ok (Ast.DManifest (n, es), r3))))

and entries (acc : Ast.mentry list) (ts : stream)
  : (Ast.mentry list * stream, Error.t) result =
  if at_sym "}" ts then
    Result.bind (take ts) (fun (_close, r1) -> Ok (List.rev acc, r1))
  else
    Result.bind (expect_word "expected an entry kind" ts) (fun (k, r1) ->
        Result.bind (expect_name "expected an entry name" r1) (fun (nm, r2) ->
            Result.bind (expect_sym "{" "expected an opening brace" r2)
              (fun r3 ->
                Result.bind (entry_fields [] r3) (fun (fs, r4) ->
                    entries_more
                      ({ Ast.kind = k;  ename = nm;  fields = fs } :: acc)
                      r4))))

and entries_more (acc : Ast.mentry list) (ts : stream)
  : (Ast.mentry list * stream, Error.t) result =
  if at_sym "," ts then
    Result.bind (take ts) (fun (_comma, r1) -> entries acc r1)
  else entries acc ts

and entry_fields (acc : (Label.t * Ast.expr) list) (ts : stream)
  : ((Label.t * Ast.expr) list * stream, Error.t) result =
  if at_sym "}" ts then
    Result.bind (take ts) (fun (_close, r1) -> Ok (List.rev acc, r1))
  else
    Result.bind (expect_label "expected a field name" ts) (fun (l, r1) ->
        Result.bind (expect_sym "=" "expected an equals sign" r1) (fun r2 ->
            Result.bind (expr true r2) (fun (v, r3) ->
                entry_more ((l, v) :: acc) r3)))

and entry_more (acc : (Label.t * Ast.expr) list) (ts : stream)
  : ((Label.t * Ast.expr) list * stream, Error.t) result =
  if at_sym "," ts then
    Result.bind (take ts) (fun (_comma, r1) -> entry_fields acc r1)
  else entry_fields acc ts

(* An M1 to M4 form parses and holds its own text, which the printer
   gives back word for word (D-A-11).  The text is built from the words
   the reader took, because the parser reads tokens and holds no range
   of the source to slice (D-A-25). *)
and milestone_decl (tk : Lexer.t) (w : string) (ts : stream)
  : (Ast.decl * stream, Error.t) result =
  Option.fold ~none:(fail tk "expected a declaration")
    ~some:(fun m ->
      Result.bind (expect_name "expected a name after the form word" ts)
        (fun (n, r1) ->
          Ok
            ( Ast.DMilestone
                (m, n, String.concat " " [ w;  Ident.to_string n ]),
              r1 )))
    (milestone_of w)

and decls (acc : Ast.decl list) (ts : stream)
  : (Ast.prog * stream, Error.t) result =
  if at_eof ts then Ok (List.rev acc, ts)
  else Result.bind (decl ts) (fun (d, rest) -> decls (d :: acc) rest)

(* --- the entry point ---------------------------------------------- *)

let parse (text : string) : (Ast.prog, Error.t) result =
  Result.bind (Lexer.lex text) (fun ts ->
      Result.map (fun (ds, _rest) -> ds) (decls [] ts))
