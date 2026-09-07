(* The checked IR machine returns persistent states and explicit host calls. *)
type error = Unbound of string | Expected of string | Pattern_failed
  | Missing_field of string | Division_by_zero | Integer_range
  | Unknown_operator of string | Uncomparable | Unsupported_host_type
  | Host_failed of string
type contract = Atom of string | Fields of (string * contract) list
  | Choice of (string * contract) list
type imported = { name : string; argument : contract; result : contract;
                  deadline_ms : int }
type value = Lit of Literal.t | Record of (Label.t * value) list
  | Variant of Label.t * Label.occ * value
  | Closure of Ir.pat * Ir.t * environment
  | Recursive of Ident.t * (Ident.t * Ir.t) list * environment
  | Host of imported
and environment = (Ident.t * value) list
type item = Binding of Ir.item | Import of imported | Deferred of Ir.item
type outcome = Done of value | Failed of error | Continue of (unit -> outcome)
  | Call of imported * value * ((value, error) result -> outcome)
let ( let* ) = Result.bind
let error_text = function
  | Unbound name -> "unbound: " ^ name
  | Expected name -> "expected_" ^ name
  | Pattern_failed -> "pattern_failed"
  | Missing_field name -> "missing_field: " ^ name
  | Division_by_zero -> "division_by_zero"
  | Integer_range -> "integer_range"
  | Unknown_operator name -> "unknown_operator: " ^ name
  | Uncomparable -> "uncomparable_function"
  | Unsupported_host_type -> "unsupported_host_type"
  | Host_failed name -> "host_failed: " ^ name
let rec value_text = function
  | Lit (Literal.Int n) -> string_of_int n
  | Lit (Literal.Str s) -> "\"" ^ String.escaped s ^ "\""
  | Lit (Literal.Bool b) -> string_of_bool b
  | Lit Literal.Unit -> "()"
  | Record fields -> "{" ^ String.concat ", " (List.map (fun (label, value) ->
      Label.to_string label ^ " = " ^ value_text value) fields) ^ "}"
  | Variant (label, occurrence, value) -> "<" ^ Label.to_string label ^ "^"
      ^ string_of_int (Label.occ_to_int occurrence) ^ " " ^ value_text value ^ ">"
  | Closure _ | Recursive _ | Host _ -> "<function>"
let lookup name env = List.find_map (fun (key, value) ->
    if Ident.equal key name then Some value else None) env
let rec field label occurrence = function
  | [] -> None
  | (key, value) :: rest ->
    match () with
    | () when Label.equal label key && occurrence = 0 -> Some value
    | () when Label.equal label key -> field label (occurrence - 1) rest
    | () -> field label occurrence rest
let rec remove label = function
  | [] -> None
  | (key, value) :: rest -> if Label.equal label key then Some rest
    else Option.map (fun tail -> (key, value) :: tail) (remove label rest)
let record_rest patterns fields =
  let (_, kept) = List.fold_left (fun (seen, kept) (label, value) ->
      let key = Label.to_string label in
      let occurrence = Option.value ~default:0 (List.assoc_opt key seen) in
      let consumed = List.exists (fun (wanted, index, _pattern) ->
          Label.equal label wanted && occurrence = Label.occ_to_int index) patterns in
      ((key, occurrence + 1) :: seen,
       if consumed then kept else (label, value) :: kept)) ([], []) fields in
  List.rev kept
let rec pattern pat value =
  match pat with
  | Ir.PWild -> Some []
  | Ir.PVar name -> Some [(name, value)]
  | Ir.PLit wanted ->
    (match value with
     | Lit actual -> if Literal.equal wanted actual then Some [] else None
     | Record _ | Variant _ | Closure _ | Recursive _ | Host _ -> None)
  | Ir.PInj (label, occurrence, body) ->
    (match value with
     | Variant (actual, index, payload) ->
       if Label.equal label actual && Label.occ_equal occurrence index
       then pattern body payload else None
     | Lit _ | Record _ | Closure _ | Recursive _ | Host _ -> None)
  | Ir.PRec (patterns, rest_name) ->
    (match value with
     | Record fields ->
       let matched = List.fold_left (fun acc (label, index, pat) ->
           Option.bind acc (fun bindings ->
             Option.bind (field label (Label.occ_to_int index) fields) (fun value ->
               Option.map (fun more -> List.append more bindings) (pattern pat value))))
           (Some []) patterns in
       Option.map (fun bindings -> Option.fold ~none:bindings
           ~some:(fun name -> (name, Record (record_rest patterns fields)) :: bindings)
           rest_name) matched
     | Lit _ | Variant _ | Closure _ | Recursive _ | Host _ -> None)
let integer = function
  | Lit (Literal.Int n) -> Ok n
  | Lit (Literal.Str _ | Literal.Bool _ | Literal.Unit)
  | Record _ | Variant _ | Closure _ | Recursive _ | Host _ -> Error (Expected "integer")
let boolean = function
  | Lit (Literal.Bool b) -> Ok b
  | Lit (Literal.Str _ | Literal.Int _ | Literal.Unit)
  | Record _ | Variant _ | Closure _ | Recursive _ | Host _ -> Error (Expected "boolean")
let string = function
  | Lit (Literal.Str text) -> Ok text
  | Lit (Literal.Bool _ | Literal.Int _ | Literal.Unit)
  | Record _ | Variant _ | Closure _ | Recursive _ | Host _ -> Error (Expected "string")
let fields = function
  | Record values -> Ok values
  | Lit _ | Variant _ | Closure _ | Recursive _ | Host _ -> Error (Expected "record")
let int_value n = Lit (Literal.Int n)
let bool_value b = Lit (Literal.Bool b)
let i32 operation a b = Int32.to_int (operation (Int32.of_int a) (Int32.of_int b))
let in_range n = Int64.of_int n >= -2147483648L && Int64.of_int n <= 2147483647L
let rec equal a b =
  match a with
  | Lit x ->
    (match b with
     | Lit y -> Ok (Literal.equal x y)
     | Record _ | Variant _ -> Ok false
     | Closure _ | Recursive _ | Host _ -> Error Uncomparable)
  | Record xs ->
    (match b with
     | Record ys -> equal_fields xs ys
     | Lit _ | Variant _ -> Ok false
     | Closure _ | Recursive _ | Host _ -> Error Uncomparable)
  | Variant (label, occurrence, value) ->
    (match b with
     | Variant (key, index, payload) ->
       if Label.equal label key && Label.occ_equal occurrence index
       then equal value payload else Ok false
     | Lit _ | Record _ -> Ok false
     | Closure _ | Recursive _ | Host _ -> Error Uncomparable)
  | Closure _ | Recursive _ | Host _ -> Error Uncomparable
and equal_fields xs ys =
  match xs with
  | [] -> Ok (ys = [])
  | (label, value) :: rest ->
    Option.fold ~none:(Ok false) ~some:(fun actual ->
        let* same = equal value actual in
        if not same then Ok false else
          Option.fold ~none:(Ok false) ~some:(equal_fields rest) (remove label ys))
      (field label 0 ys)
let rec accepts contract value =
  match contract with
  | Atom name ->
    (match value with
     | Lit (Literal.Int n) -> String.equal name "int" && in_range n
     | Lit (Literal.Str _) -> String.equal name "str"
     | Lit (Literal.Bool _) -> String.equal name "bool"
     | Lit Literal.Unit -> String.equal name "unit"
     | Record _ | Variant _ | Closure _ | Recursive _ | Host _ -> false)
  | Fields wanted ->
    (match value with
     | Record actual -> accepts_fields wanted actual
     | Lit _ | Variant _ | Closure _ | Recursive _ | Host _ -> false)
  | Choice alternatives ->
    (match value with
     | Variant (label, index, payload) ->
       let rec select occurrence = function
         | [] -> false
         | (key, contract) :: rest ->
           match () with
           | () when String.equal key (Label.to_string label) && occurrence = 0 -> accepts contract payload
           | () when String.equal key (Label.to_string label) -> select (occurrence - 1) rest
           | () -> select occurrence rest in
       select (Label.occ_to_int index) alternatives
     | Lit _ | Record _ | Closure _ | Recursive _ | Host _ -> false)
and accepts_fields wanted actual =
  match wanted with
  | [] -> actual = []
  | (key, contract) :: rest ->
    let label = Label.of_string key in
    Option.fold ~none:false ~some:(fun value -> accepts contract value &&
      Option.fold ~none:false ~some:(accepts_fields rest) (remove label actual))
      (field label 0 actual)
let binary op a b =
  match () with
  | () when String.equal op "==" || String.equal op "!=" ->
    Result.map (fun same -> bool_value (if String.equal op "==" then same else not same)) (equal a b)
  | () when String.equal op "^" ->
    let* x = string a in let* y = string b in Ok (Lit (Literal.Str (x ^ y)))
  | () when String.equal op Ir.restrict_op ->
    let* values = fields a in let* label = string b in
    Option.fold ~none:(Error (Missing_field label)) ~some:(fun rest -> Ok (Record rest))
      (remove (Label.of_string label) values)
  | () ->
    let* x = integer a in let* y = integer b in
    match () with
    | () when String.equal op "+" -> Ok (int_value (i32 Int32.add x y))
    | () when String.equal op "-" -> Ok (int_value (i32 Int32.sub x y))
    | () when String.equal op "*" -> Ok (int_value (i32 Int32.mul x y))
    | () when String.equal op "/" ->
      if y = 0 then Error Division_by_zero else Ok (int_value (i32 Int32.div x y)) (* @total-accessor *)
    | () when String.equal op "%" ->
      if y = 0 then Error Division_by_zero else Ok (int_value (i32 Int32.rem x y)) (* @total-accessor *)
    | () when String.equal op "<" -> Ok (bool_value (x < y))
    | () when String.equal op "<=" -> Ok (bool_value (x <= y))
    | () when String.equal op ">" -> Ok (bool_value (x > y))
    | () when String.equal op ">=" -> Ok (bool_value (x >= y))
    | () -> Error (Unknown_operator op)
let deliver result next = Result.fold ~ok:next ~error:(fun error -> Failed error) result
let recursive bindings env = List.append
    (List.map (fun (name, _body) -> (name, Recursive (name, bindings, env))) bindings) env
let recursive_functions bindings = List.for_all (fun (_name, body) ->
    match body with
    | Ir.ILam _ -> true
    | Ir.IVar _ | Ir.ILit _ | Ir.IApp _ | Ir.ILet _ | Ir.ILetRec _
    | Ir.IIf _ | Ir.IRec _ | Ir.ISel _ | Ir.IInj _ | Ir.IMatch _ | Ir.IBin _ -> false) bindings
let rec expression env term next = Continue (fun () ->
  match term with
  | Ir.IVar name ->
    Option.fold ~none:(Failed (Unbound (Ident.to_string name)))
      ~some:(fun value -> force value next) (lookup name env)
  | Ir.ILit (Literal.Int n) -> if in_range n then next (int_value n) else Failed Integer_range
  | Ir.ILit literal -> next (Lit literal)
  | Ir.ILam (pat, body) -> next (Closure (pat, body, env))
  | Ir.IApp (fn, argument) -> expression env fn (fun f ->
      expression env argument (fun value -> apply f value next))
  | Ir.ILet (pat, bound, body) -> expression env bound (fun value ->
      bind_pattern env pat value (fun scope -> expression scope body next))
  | Ir.ILetRec (bindings, body) ->
    if recursive_functions bindings then expression (recursive bindings env) body next
    else Failed (Expected "recursive_function")
  | Ir.IIf (condition, yes, no) -> expression env condition (fun value ->
      deliver (boolean value) (fun flag -> expression env (if flag then yes else no) next))
  | Ir.IRec (entries, base) -> entries_eval env entries [] (fun values ->
      Option.fold ~none:(Continue (fun () -> next (Record values)))
        ~some:(fun term -> expression env term (fun value ->
          deliver (fields value) (fun rest -> next (Record (List.append values rest))))) base)
  | Ir.ISel (record, label) -> expression env record (fun value ->
      deliver (fields value) (fun values ->
        Option.fold ~none:(Failed (Missing_field (Label.to_string label))) ~some:next
          (field label 0 values)))
  | Ir.IInj (label, occurrence, body) -> expression env body (fun value ->
      next (Variant (label, occurrence, value)))
  | Ir.IMatch (scrutinee, arms) -> expression env scrutinee (fun value ->
      match_arms env value arms next)
  | Ir.IBin (op, left, right) -> expression env left (fun value ->
      if String.equal op "&&" || String.equal op "||" then
        deliver (boolean value) (fun flag ->
          if (String.equal op "&&" && not flag) || (String.equal op "||" && flag)
          then next (bool_value flag)
          else expression env right (fun right ->
            deliver (boolean right) (fun answer -> next (bool_value answer))))
      else expression env right (fun other -> deliver (binary op value other) next)))
and force value next =
  match value with
  | Recursive (name, bindings, env) ->
    Option.fold ~none:(Failed (Unbound (Ident.to_string name)))
      ~some:(fun body -> expression (recursive bindings env) body next)
      (List.find_map (fun (key, body) -> if Ident.equal key name then Some body else None) bindings)
  | Lit _ | Record _ | Variant _ | Closure _ | Host _ -> next value
and bind_pattern env pat value next =
  Option.fold ~none:(Failed Pattern_failed)
      ~some:(fun names -> next (List.append names env)) (pattern pat value)
and apply fn argument next = Continue (fun () ->
  match fn with
  | Closure (pat, body, env) ->
    bind_pattern env pat argument (fun scope -> expression scope body next)
  | Recursive _ -> force fn (fun value -> apply value argument next)
  | Host imported ->
    if not (accepts imported.argument argument) then Failed (Expected "host_argument")
    else Call (imported, argument, fun reply -> deliver reply (fun value ->
      if accepts imported.result value then next value else Failed (Expected "host_result")))
  | Lit _ | Record _ | Variant _ -> Failed (Expected "function"))
and entries_eval env entries reversed next =
  match entries with
  | [] -> next (List.rev reversed)
  | (label, body) :: rest -> expression env body (fun value ->
      entries_eval env rest ((label, value) :: reversed) next)
and match_arms env value arms next =
  match arms with
  | [] -> Failed Pattern_failed
  | (pat, body) :: rest ->
    Option.fold ~none:(Continue (fun () -> match_arms env value rest next))
      ~some:(fun names -> expression (List.append names env) body next) (pattern pat value)
let rec items env last program finish =
  match program with
  | [] -> finish env last
  | Binding binding :: rest -> expression env binding.Ir.ibody (fun value ->
      items ((binding.Ir.iname, value) :: env) value rest finish)
  | Import imported :: rest -> Continue (fun () ->
      items ((Ident.of_string imported.name, Host imported) :: env) last rest finish)
  | Deferred binding :: rest -> Continue (fun () ->
      items ((binding.Ir.iname, Closure (Ir.PWild, binding.Ir.ibody, env)) :: env) last rest finish)
let start program = items [] (Lit Literal.Unit) program (fun _env value -> Done value)
let invoke program name argument = items [] (Lit Literal.Unit) program (fun env _last ->
    Option.fold ~none:(Failed (Unbound name))
      ~some:(fun fn -> apply fn argument (fun value -> Done value))
      (lookup (Ident.of_string name) env))
let rec advance count outcome =
  if count <= 0 then outcome else
    match outcome with
    | Continue resume -> advance (count - 1) (resume ())
    | Done _ | Failed _ | Call _ -> outcome
let rec native outcome =
  match outcome with
  | Continue resume -> native (resume ())
  | Done value -> Ok value
  | Failed error -> Error error
  | Call (imported, _argument, _resume) -> Error (Host_failed ("unavailable: " ^ imported.name))
