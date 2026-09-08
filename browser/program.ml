(* Checked artifact decoder and explicit suspension boundary for the IR machine. *)
open Js_of_ocaml
module E = Kite_execution.Eval
module J = Js.Unsafe
let ( let* ) = Result.bind
let text value = J.inject (Js.string value)
let number value = J.inject value
let null = J.inject Js.null
let kind value = Js.to_string (Js.typeof value)
let invalid name = Error ("invalid_" ^ name)
let read_string name value =
  if String.equal (kind value) "string" then Ok (Js.to_string (J.coerce value)) else invalid name
let read_int name value =
  if not (String.equal (kind value) "number") then invalid name else
    let n = Js.to_float (J.coerce value) in
    if Float.is_finite n && Float.equal n (Float.trunc n) && n >= -2147483648. && n <= 2147483647.
    then Ok (int_of_float n) else invalid name
let read_bool name value =
  if String.equal (kind value) "boolean" then Ok (Js.to_bool (J.coerce value)) else invalid name
let is_array value = Js.to_bool (J.meth_call (J.get J.global "Array") "isArray" [|value|])
let read_object name value =
  if String.equal (kind value) "object" && not (J.strict_equals value Js.null) && not (is_array value)
  then Ok value else invalid name
let traverse parser values = Result.map List.rev (List.fold_left (fun acc value ->
    let* reversed = acc in let* parsed = parser value in Ok (parsed :: reversed)) (Ok []) values)
let read_list parser name value =
  if is_array value then
    traverse parser (Array.to_list (Js.to_array (J.coerce value)))
  else invalid name
let js_list render values =
  J.inject (Js.array (Array.of_list (List.map render values)))
let field parser value name = parser name (J.get value name)
let str value name = field read_string value name
let integer value name = field read_int value name
let ident value name = Result.map Ident.of_string (str value name)
let label value = Result.map Label.of_string (str value "name")
let optional parser name value =
  if J.strict_equals value Js.null then Ok None else Result.map Option.some (parser name value)
let occurrence value =
  let* index = integer value "occ" in
  if index >= 0 then Ok (Label.occ_of_int index) else invalid "occurrence"
let tagged name value =
  let* value = read_object name value in let* tag = str value "tag" in Ok (value, tag)
let literal name input =
  let* (value, tag) = tagged name input in
  match () with
  | () when String.equal tag "int" -> Result.map (fun n -> Literal.Int n) (integer value "value")
  | () when String.equal tag "str" -> Result.map (fun s -> Literal.Str s) (str value "value")
  | () when String.equal tag "bool" -> Result.map (fun b -> Literal.Bool b) (field read_bool value "value")
  | () when String.equal tag "unit" -> Ok Literal.Unit
  | () -> invalid "literal"
let rec pattern depth name input =
  if depth > 256 then Error "artifact_depth" else
  let* (value, tag) = tagged name input in
  match () with
  | () when String.equal tag "lit" -> Result.map (fun x -> Ir.PLit x) (field literal value "value")
  | () when String.equal tag "var" -> Result.map (fun x -> Ir.PVar x) (ident value "name")
  | () when String.equal tag "wild" -> Ok Ir.PWild
  | () when String.equal tag "variant" ->
    let* key = label value in let* index = occurrence value in
    let* body = field (pattern (depth + 1)) value "body" in Ok (Ir.PInj (key, index, body))
  | () when String.equal tag "record" ->
    let* fields = field (read_list (pattern_field (depth + 1))) value "fields" in
    let* rest = field (optional read_string) value "rest" in
    Ok (Ir.PRec (fields, Option.map Ident.of_string rest))
  | () -> invalid "pattern"
and pattern_field depth input =
  let* value = read_object "pattern_field" input in
  let* key = label value in let* index = occurrence value in
  let* body = field (pattern depth) value "body" in Ok (key, index, body)
let rec expression depth name input =
  if depth > 256 then Error "artifact_depth" else
  let* (value, tag) = tagged name input in
  match () with
  | () when String.equal tag "var" -> Result.map (fun x -> Ir.IVar x) (ident value "name")
  | () when String.equal tag "lit" -> Result.map (fun x -> Ir.ILit x) (field literal value "value")
  | () when String.equal tag "lambda" ->
    let* pat = field (pattern (depth + 1)) value "pattern" in let* body = field (expression (depth + 1)) value "body" in
    Ok (Ir.ILam (pat, body))
  | () when String.equal tag "apply" ->
    let* fn = field (expression (depth + 1)) value "fn" in let* arg = field (expression (depth + 1)) value "argument" in
    Ok (Ir.IApp (fn, arg))
  | () when String.equal tag "let" ->
    let* pat = field (pattern (depth + 1)) value "pattern" in let* bound = field (expression (depth + 1)) value "value" in
    let* body = field (expression (depth + 1)) value "body" in Ok (Ir.ILet (pat, bound, body))
  | () when String.equal tag "recursive" ->
    let* bindings = field (read_list (binding (depth + 1))) value "bindings" in
    let* body = field (expression (depth + 1)) value "body" in Ok (Ir.ILetRec (bindings, body))
  | () when String.equal tag "if" ->
    let* c = field (expression (depth + 1)) value "condition" in let* yes = field (expression (depth + 1)) value "yes" in
    let* no = field (expression (depth + 1)) value "no" in Ok (Ir.IIf (c, yes, no))
  | () when String.equal tag "record" ->
    let* fields = field (read_list (record_field (depth + 1))) value "fields" in
    let* base = field (optional (expression (depth + 1))) value "base" in Ok (Ir.IRec (fields, base))
  | () when String.equal tag "select" ->
    let* body = field (expression (depth + 1)) value "body" in let* key = label value in Ok (Ir.ISel (body, key))
  | () when String.equal tag "variant" ->
    let* key = label value in let* index = occurrence value in
    let* body = field (expression (depth + 1)) value "body" in Ok (Ir.IInj (key, index, body))
  | () when String.equal tag "match" ->
    let* body = field (expression (depth + 1)) value "body" in let* arms = field (read_list (arm (depth + 1))) value "arms" in
    Ok (Ir.IMatch (body, arms))
  | () when String.equal tag "binary" ->
    let* op = str value "operator" in let* left = field (expression (depth + 1)) value "left" in
    let* right = field (expression (depth + 1)) value "right" in Ok (Ir.IBin (op, left, right))
  | () -> invalid "expression"
and binding depth input =
  let* value = read_object "binding" input in let* name = ident value "name" in
  let* body = field (expression depth) value "body" in Ok (name, body)
and record_field depth input =
  let* value = read_object "record_field" input in let* key = label value in
  let* body = field (expression depth) value "body" in Ok (key, body)
and arm depth input =
  let* value = read_object "arm" input in let* pat = field (pattern depth) value "pattern" in
  let* body = field (expression depth) value "body" in Ok (pat, body)
let rec contract depth name input =
  if depth > 256 then Error "artifact_depth" else
  let* (value, tag) = tagged name input in
  match () with
  | () when List.mem tag ["int"; "str"; "bool"; "unit"] -> Ok (E.Atom tag)
  | () when String.equal tag "record" ->
    Result.map (fun x -> E.Fields x) (field (read_list (contract_field (depth + 1))) value "fields")
  | () when String.equal tag "variant" ->
    Result.map (fun x -> E.Choice x) (field (read_list (contract_field (depth + 1))) value "fields")
  | () -> invalid "contract"
and contract_field depth input =
  let* value = read_object "contract_field" input in let* name = str value "name" in
  let* ty = field (contract depth) value "type" in Ok (name, ty)
let item input =
  let* (value, tag) = tagged "item" input in
  match () with
  | () when String.equal tag "binding" ->
    let* name = ident value "name" in let* body = field (expression 0) value "body" in
    Ok (E.Binding {Ir.iname = name; ibody = body})
  | () when String.equal tag "deferred" ->
    let* name = ident value "name" in let* body = field (expression 0) value "body" in
    Ok (E.Deferred {Ir.iname = name; ibody = body})
  | () when String.equal tag "manifest" ->
    let* manifest_kind = str value "kind" in let* manifest_name = str value "name" in
    let* manifest_fields = field (read_list (record_field 0)) value "fields" in
    let* () = Result.map_error E.error_text (E.manifest_schema manifest_kind
      (List.map (fun (label, _body) -> Label.to_string label) manifest_fields)) in
    Ok (E.Manifest {E.manifest_kind; manifest_name; manifest_fields})
  | () when String.equal tag "import" ->
    let* name = str value "name" in let* argument = field (contract 0) value "argument" in
    let* result = field (contract 0) value "result" in let* deadline_ms = integer value "deadlineMs" in
    if deadline_ms <= 0 then invalid "deadline" else
      Ok (E.Import {E.name; argument; result; deadline_ms})
  | () -> invalid "item"
let program input =
  let* value = read_object "artifact" input in let* version = integer value "version" in
  if version <> 1 then invalid "artifact_version" else field (read_list item) value "items"
let object_fields fields =
  let value = J.meth_call (J.get J.global "Object") "create" [|null|] in
  let () = List.iter (fun (key, field) -> J.set value key field) fields in value
let rec render = function
  | E.Lit (Literal.Int n) -> number n
  | E.Lit (Literal.Str s) -> text s
  | E.Lit (Literal.Bool b) -> J.inject (Js.bool b)
  | E.Lit Literal.Unit -> null
  | E.Record fields ->
    let names = List.map (fun (key, _value) -> Label.to_string key) fields in
    if List.length (List.sort_uniq String.compare names) = List.length names then
      object_fields (List.map (fun (key, value) -> Label.to_string key, render value) fields)
    else J.obj [|"kind", text "record"; "fields", js_list (fun (key, value) ->
      J.obj [|"name", text (Label.to_string key); "value", render value|]) fields|]
  | E.Variant (key, occurrence, value) -> J.obj [|"tag", text (Label.to_string key);
      "occ", number (Label.occ_to_int occurrence); "value", render value|]
  | E.Closure _ | E.Recursive _ | E.Host _ -> J.obj [|"kind", text "function"|]
let rec data contract input =
  match contract with
  | E.Atom name ->
    (match () with
     | () when String.equal name "int" -> Result.map (fun n -> E.Lit (Literal.Int n)) (read_int "host_integer" input)
     | () when String.equal name "str" -> Result.map (fun s -> E.Lit (Literal.Str s)) (read_string "host_string" input)
     | () when String.equal name "bool" -> Result.map (fun b -> E.Lit (Literal.Bool b)) (read_bool "host_boolean" input)
     | () when String.equal name "unit" && J.strict_equals input Js.null -> Ok (E.Lit Literal.Unit)
     | () -> invalid "host_value")
  | E.Fields contracts ->
    let* value = read_object "host_record" input in
    let keys = J.meth_call (J.get J.global "Object") "keys" [|value|] in
    let* keys = read_list (read_string "host_field") "host_keys" keys in
    if List.sort String.compare keys <> List.sort String.compare (List.map fst contracts)
    then invalid "host_record_fields" else
      Result.map (fun fields -> E.Record fields) (traverse (fun (name, contract) ->
        let* value = data contract (J.get value name) in Ok (Label.of_string name, value)) contracts)
  | E.Choice alternatives ->
    let* value = read_object "host_variant" input in let* name = str value "tag" in
    let* index = occurrence value in
    let rec pick remaining = function
      | [] -> invalid "host_variant_tag"
      | (key, contract) :: rest ->
        match () with
        | () when String.equal key name && remaining = 0 -> data contract (J.get value "value")
        | () when String.equal key name -> pick (remaining - 1) rest
        | () -> pick remaining rest in
    let* payload = pick (Label.occ_to_int index) alternatives in
    Ok (E.Variant (Label.of_string name, index, payload))
let error message = J.obj [|"kind", text "error"; "error", text message|]
let manifest value =
  let workload kind (value : E.Manifest.workload) = J.obj [|"kind", text kind; "name", text value.name;
      "replicas", number value.replicas; "bound", number value.bound;
      "tolerateHidden", J.inject (Js.bool value.tolerate_hidden)|] in
  let binding kind (value : E.Manifest.binding) = J.obj [|"kind", text kind; "name", text value.name;
      "target", text value.target|] in
  match value with
  | E.Manifest.Deployment value -> workload "deployment" value
  | E.Manifest.Stateful_set value -> workload "stateful_set" value
  | E.Manifest.Named_service value -> binding "service" value
  | E.Manifest.Freeze_drain value -> binding "drain" value
let rec outcome state =
  match E.advance 1000 state with
  | E.Done value -> J.obj [|"kind", text "done"; "value", render value|]
  | E.Ready (session, value) ->
    let freeze () =
      let state = Option.fold ~none:(E.Done (E.Lit Literal.Unit))
          ~some:(fun fn -> E.apply fn (E.Lit Literal.Unit) (fun value -> E.Done value))
          (E.lookup (Ident.of_string "@freeze") session.E.environment) in
      outcome state in
    J.obj [|"kind", text "done"; "value", render value;
      "manifests", js_list manifest session.E.manifests;
      "session", J.obj [|"freeze", J.inject (Js.wrap_callback freeze)|]|]
  | E.Failed failure -> error (E.error_text failure)
  | E.Continue resume -> J.obj [|"kind", text "yield";
      "resume", J.inject (Js.wrap_callback (fun () -> outcome (resume ())))|]
  | E.Call (imported, argument, resume) ->
    let answer input =
      let parsed = let* value = read_object "host_reply" input in
        let* ok = field read_bool value "ok" in
        if ok then data imported.E.result (J.get value "value")
        else let* message = str value "error" in Error message in
      outcome (resume (Result.map_error (fun message -> E.Host_failed message) parsed)) in
    J.obj [|"kind", text "call"; "name", text imported.E.name;
      "argument", render argument; "deadlineMs", number imported.E.deadline_ms;
      "resume", J.inject (Js.wrap_callback answer)|]
let start artifact = Result.fold ~error ~ok:(fun program -> outcome (E.start program)) (program artifact)
let open_session artifact = Result.fold ~error
    ~ok:(fun program -> outcome (E.open_session program)) (program artifact)
let () = Js.export "KiteProgram" (J.obj [|"start", J.inject (Js.wrap_callback start);
    "openSession", J.inject (Js.wrap_callback open_session)|])
