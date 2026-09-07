(* Offline emission of checked IR data. The browser does not load the checker. *)
module Eval = Kite_execution.Eval
let ( let* ) = Result.bind
let traverse f values = Result.map List.rev (List.fold_left (fun acc value ->
    let* reversed = acc in let* item = f value in Ok (item :: reversed)) (Ok []) values)
let unsupported = Error "executable imports require closed first-order data types"
let rec contract depth ty =
  if depth > 256 then Error "artifact_depth" else match ty with
  | Ast.TName name ->
    let name = String.lowercase_ascii name in
    if List.mem name ["int"; "str"; "bool"; "unit"] then Ok (Eval.Atom name)
    else unsupported
  | Ast.TRec row ->
    let names = List.map (fun (label, _ty) -> Label.to_string label) row.Ast.fields in
    if List.length (List.sort_uniq String.compare names) <> List.length names
    then Error "executable host record contracts require distinct field names" else
      Result.map (fun fields -> Eval.Fields fields) (contract_row (depth + 1) row)
  | Ast.TVar row -> Result.map (fun fields -> Eval.Choice fields) (contract_row (depth + 1) row)
  | Ast.TArrow _ | Ast.TCode _ -> unsupported
and contract_row depth row =
  if Option.is_some row.Ast.tail then unsupported else
    traverse (fun (label, ty) -> let* value = contract depth ty in
      Ok (Label.to_string label, value)) row.Ast.fields
let imported (value : Ast.import) =
  match value.ity with
  | Ast.TArrow (argument, _multiplicity, result) ->
    let* argument = contract 0 argument in let* result = contract 0 result in
    if value.deadline_ms <= 0 || not (Eval.in_range value.deadline_ms)
    then Error "executable imports require a positive signed 32-bit deadline" else
    Ok {Eval.name = Ident.to_string value.iname; argument; result;
        deadline_ms = value.deadline_ms}
  | Ast.TName _ | Ast.TRec _ | Ast.TVar _ | Ast.TCode _ -> unsupported
let rec declaration = function
  | Ast.DImport value -> Result.map (fun value -> [Eval.Import value]) (imported value)
  | Ast.DBudget (_caps, body) -> declaration body
  | Ast.DFreeze (_labels, body) ->
    Ok [Eval.Deferred {Ir.iname = Lower.freeze_name; ibody = Lower.expr body}]
  | (Ast.DLet _ | Ast.DLetRec _ | Ast.DProtocol _ | Ast.DRole _
    | Ast.DManifest _ | Ast.DMilestone _) as value ->
    Result.map (List.map (fun binding -> Eval.Binding binding))
      (Result.map_error Error.to_line (Lower.decl value))
(* The emitted artifact is read back as text. A byte run that is not valid
   utf-8 decodes to a different string, so the encoder refuses it here.
   The fold carries the scalar value so far, the number of continuation
   bytes it still wants, the lowest scalar value its length may carry, and
   the verdict. A surrogate value and a value above U+10FFFF are refused
   with an overlong run and a truncated run. *)
let legal point floor =
  point >= floor && point <= 0x10ffff && not (point >= 0xd800 && point <= 0xdfff)
let utf8_check (point, remaining, floor, ok) ch =
  let code = Char.code ch in
  match () with
  | () when remaining > 1 && code land 0xc0 = 0x80 ->
    ((point lsl 6) lor (code land 0x3f), remaining - 1, floor, ok)
  | () when remaining = 1 && code land 0xc0 = 0x80 ->
    (0, 0, 0, ok && legal ((point lsl 6) lor (code land 0x3f)) floor)
  | () when remaining > 0 -> (0, 0, 0, false)
  | () when code < 0x80 -> (0, 0, 0, ok)
  | () when code land 0xe0 = 0xc0 -> (code land 0x1f, 1, 0x80, ok)
  | () when code land 0xf0 = 0xe0 -> (code land 0x0f, 2, 0x800, ok)
  | () when code land 0xf8 = 0xf0 -> (code land 0x07, 3, 0x10000, ok)
  | () -> (0, 0, 0, false)
let valid_utf8 text =
  let (_point, remaining, _floor, ok) =
    String.fold_left utf8_check (0, 0, 0, true) text in
  if ok && remaining = 0 then Ok ()
  else Error "executable strings require valid utf-8"
let valid_literal = function
  | Literal.Int n -> if Eval.in_range n then Ok () else Error "executable integers require signed 32-bit values"
  | Literal.Str text -> valid_utf8 text
  | Literal.Bool _ | Literal.Unit -> Ok ()
let all f values = Result.map (fun _checked -> ()) (traverse f values)
let max_depth = 256
let rec valid_pattern depth pat =
  if depth > max_depth then Error "artifact_depth" else match pat with
  | Ir.PLit literal -> valid_literal literal
  | Ir.PVar _ | Ir.PWild -> Ok ()
  | Ir.PInj (_label, _occ, body) -> valid_pattern (depth + 1) body
  | Ir.PRec (fields, _rest) -> all (fun (_label, _occ, body) -> valid_pattern (depth + 1) body) fields
let rec valid_expression depth expression =
  if depth > max_depth then Error "artifact_depth" else match expression with
  | Ir.IVar _ -> Ok ()
  | Ir.ILit literal -> valid_literal literal
  | Ir.ILam (pat, body) -> let* () = valid_pattern (depth + 1) pat in valid_expression (depth + 1) body
  | Ir.IApp (left, right) | Ir.IBin (_, left, right) ->
    let* () = valid_expression (depth + 1) left in valid_expression (depth + 1) right
  | Ir.ILet (pat, value, body) ->
    let* () = valid_pattern (depth + 1) pat in let* () = valid_expression (depth + 1) value in valid_expression (depth + 1) body
  | Ir.ILetRec (bindings, body) ->
    if not (Eval.recursive_functions bindings) then Error "executable recursive bindings require functions"
    else let* () = all (fun (_name, value) -> valid_expression (depth + 1) value) bindings in valid_expression (depth + 1) body
  | Ir.IIf (condition, yes, no) ->
    let* () = valid_expression (depth + 1) condition in let* () = valid_expression (depth + 1) yes in valid_expression (depth + 1) no
  | Ir.IRec (fields, base) ->
    let* () = all (fun (_label, body) -> valid_expression (depth + 1) body) fields in
    Option.fold ~none:(Ok ()) ~some:(valid_expression (depth + 1)) base
  | Ir.ISel (body, _) | Ir.IInj (_, _, body) -> valid_expression (depth + 1) body
  | Ir.IMatch (body, arms) ->
    let* () = valid_expression (depth + 1) body in all (fun (pat, arm) ->
      let* () = valid_pattern (depth + 1) pat in valid_expression (depth + 1) arm) arms
let of_program program =
  let* items = Result.map List.concat (traverse declaration program) in
  let* () = all (function
    | Eval.Binding item | Eval.Deferred item -> valid_expression 0 item.Ir.ibody
    | Eval.Import _ -> Ok ()) items in Ok items
(* The emitted text is ascii only. A raw byte above 127 reads back as the
   encoding the reader picks, so every scalar value above 127 becomes its
   escape, and a value above U+FFFF becomes its surrogate pair. The fold
   decodes the same way utf8_check counts, and a run the encoder cannot
   represent becomes the replacement value, which valid_utf8 has already
   refused for every executable string. *)
let hex4 point = Printf.sprintf "\\u%04x" point
let ascii ch =
  match ch with
  | '"' -> "\\\""
  | '\\' -> "\\\\"
  | '\n' -> "\\n"
  | '\r' -> "\\r"
  | '\t' -> "\\t"
  | ch -> if Char.code ch < 32 then hex4 (Char.code ch) else String.make 1 ch
let escaped point =
  match () with
  | () when point > 0x10ffff -> hex4 0xfffd
  | () when point <= 0xffff -> hex4 point
  | () ->
    let rest = point - 0x10000 in
    hex4 (0xd800 lor (rest lsr 10)) ^ hex4 (0xdc00 lor (rest land 0x3ff))
let flushed (remaining, acc) = if remaining > 0 then hex4 0xfffd :: acc else acc
let utf8_quote (point, remaining, acc) ch =
  let code = Char.code ch in
  match () with
  | () when remaining > 1 && code land 0xc0 = 0x80 ->
    ((point lsl 6) lor (code land 0x3f), remaining - 1, acc)
  | () when remaining = 1 && code land 0xc0 = 0x80 ->
    (0, 0, escaped ((point lsl 6) lor (code land 0x3f)) :: acc)
  | () when code < 0x80 -> (0, 0, ascii ch :: flushed (remaining, acc))
  | () when code land 0xe0 = 0xc0 -> (code land 0x1f, 1, flushed (remaining, acc))
  | () when code land 0xf0 = 0xe0 -> (code land 0x0f, 2, flushed (remaining, acc))
  | () when code land 0xf8 = 0xf0 -> (code land 0x07, 3, flushed (remaining, acc))
  | () -> (0, 0, hex4 0xfffd :: flushed (remaining, acc))
let quote value =
  let (_point, remaining, acc) = String.fold_left utf8_quote (0, 0, []) value in
  "\"" ^ String.concat "" (List.rev (flushed (remaining, acc))) ^ "\""
let obj fields = "{" ^ String.concat "," (List.map (fun (key, value) -> quote key ^ ":" ^ value) fields) ^ "}"
let list render values = "[" ^ String.concat "," (List.map render values) ^ "]"
let node tag fields = obj (("tag", quote tag) :: fields)
let name value = quote (Ident.to_string value)
let label value = quote (Label.to_string value)
let occurrence value = string_of_int (Label.occ_to_int value)
let literal = function
  | Literal.Int value -> node "int" ["value", string_of_int value]
  | Literal.Str value -> node "str" ["value", quote value]
  | Literal.Bool value -> node "bool" ["value", string_of_bool value]
  | Literal.Unit -> node "unit" []
let rec pattern = function
  | Ir.PLit value -> node "lit" ["value", literal value]
  | Ir.PVar value -> node "var" ["name", name value]
  | Ir.PWild -> node "wild" []
  | Ir.PInj (key, index, body) -> node "variant"
      ["name", label key; "occ", occurrence index; "body", pattern body]
  | Ir.PRec (fields, rest) -> node "record"
      ["fields", list (fun (key, index, pat) -> obj
         ["name", label key; "occ", occurrence index; "body", pattern pat]) fields;
       "rest", Option.fold ~none:"null" ~some:name rest]
let rec expression = function
  | Ir.IVar value -> node "var" ["name", name value]
  | Ir.ILit value -> node "lit" ["value", literal value]
  | Ir.ILam (pat, body) -> node "lambda" ["pattern", pattern pat; "body", expression body]
  | Ir.IApp (fn, arg) -> node "apply" ["fn", expression fn; "argument", expression arg]
  | Ir.ILet (pat, value, body) -> node "let"
      ["pattern", pattern pat; "value", expression value; "body", expression body]
  | Ir.ILetRec (bindings, body) -> node "recursive"
      ["bindings", list binding bindings; "body", expression body]
  | Ir.IIf (condition, yes, no) -> node "if"
      ["condition", expression condition; "yes", expression yes; "no", expression no]
  | Ir.IRec (fields, base) -> node "record"
      ["fields", list (fun (key, value) -> obj ["name", label key; "body", expression value]) fields;
       "base", Option.fold ~none:"null" ~some:expression base]
  | Ir.ISel (value, key) -> node "select" ["body", expression value; "name", label key]
  | Ir.IInj (key, index, value) -> node "variant"
      ["name", label key; "occ", occurrence index; "body", expression value]
  | Ir.IMatch (value, arms) -> node "match" ["body", expression value;
      "arms", list (fun (pat, body) -> obj ["pattern", pattern pat; "body", expression body]) arms]
  | Ir.IBin (op, left, right) -> node "binary"
      ["operator", quote op; "left", expression left; "right", expression right]
and binding (key, body) = obj ["name", name key; "body", expression body]
let rec contract_json = function
  | Eval.Atom name -> node name []
  | Eval.Fields fields -> node "record" ["fields", contract_fields fields]
  | Eval.Choice fields -> node "variant" ["fields", contract_fields fields]
and contract_fields fields = list (fun (name, ty) ->
    obj ["name", quote name; "type", contract_json ty]) fields
let item = function
  | Eval.Binding value -> node "binding" ["name", name value.Ir.iname;
      "body", expression value.Ir.ibody]
  | Eval.Import value -> node "import" ["name", quote value.Eval.name;
      "argument", contract_json value.argument; "result", contract_json value.result;
      "deadlineMs", string_of_int value.deadline_ms]
  | Eval.Deferred value -> node "deferred" ["name", name value.Ir.iname;
      "body", expression value.Ir.ibody]
let json values = obj ["version", "1"; "items", list item values]
let javascript values = "globalThis.KiteArtifact = " ^ json values ^ ";\n"
