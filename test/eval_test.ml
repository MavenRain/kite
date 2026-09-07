module E = Kite_execution.Eval
module A = Kite_artifact.Artifact
let ( let* ) = Result.bind
let prepare source =
  let* parsed = Result.map_error Error.to_line (Parser.parse source) in
  let* (_env, _subst) = Result.map_error Error.to_line (Infer.check parsed) in A.of_program parsed
let run source = let* program = prepare source in
  Result.map_error E.error_text (E.native (E.start program))
let output expected source () = Result.fold ~error:(fun message -> print_endline message; false)
    ~ok:(fun value -> String.equal expected (E.value_text value)) (run source)
let failure expected source () = Result.fold ~ok:(fun _value -> false)
    ~error:(String.equal expected) (run source)
let direct expected term () =
  Result.fold ~ok:(fun _value -> false) ~error:(fun error -> String.equal expected (E.error_text error))
    (E.native (E.expression [] term (fun value -> E.Done value)))
let import_roundtrip () =
  Result.fold ~error:(fun _error -> false) ~ok:(fun program ->
    match E.advance 1000 (E.start program) with
    | E.Call (imported, argument, resume) ->
      String.equal imported.name "read" && imported.deadline_ms = 50 &&
      E.value_text argument = "7" &&
      Result.fold ~error:(fun _error -> false) ~ok:(fun result -> E.value_text result = "10")
        (E.native (resume (Ok (E.int_value 9))))
    | E.Done _ | E.Failed _ | E.Continue _ -> false)
    (prepare "import read : Int -> Int cost 1 deadline 50 let result = read 7 + 1")
let import_rejection () =
  Result.fold ~error:(fun _error -> false) ~ok:(fun program ->
    match E.advance 1000 (E.start program) with
    | E.Call (_imported, _argument, resume) ->
      Result.fold ~ok:(fun _result -> false)
        ~error:(fun error -> E.error_text error = "expected_host_result")
        (E.native (resume (Ok (E.Lit (Literal.Str "wrong")))))
    | E.Done _ | E.Failed _ | E.Continue _ -> false)
    (prepare "import read : Int -> Int cost 1 deadline 50 let result = read 7")
let divergence_yields () =
  Result.fold ~error:(fun _error -> false) ~ok:(fun program ->
    match E.advance 1000 (E.start program) with
    | E.Continue _ -> true
    | E.Done _ | E.Failed _ | E.Call _ -> false)
    (prepare "let rec spin x = spin x let result = spin 0")
let literal n = Ir.ILit (Literal.Int n)
let cases = [
  "lexical-shadowing", output "3" "let x = 3 let f = fun _ -> x let x = 9 let result = f ()";
  "local-shadowing", output "5" "let f = fun x -> let g = fun _ -> x in let x = 8 in g () let result = f 5";
  "mutual-recursion", output "true" "let rec even n = if n == 0 then true else odd (n - 1) and odd n = if n == 0 then false else even (n - 1) let result = even 10000";
  "recursive-shadowing", output "2" "let rec f n = if n == 0 then 2 else f (n - 1) let saved = f let f n = 9 let result = saved 3";
  "record-pattern", output "5" "let r = { a = 2, b = 3 } let result = let { a = x | rest } = r in x + rest.b";
  "record-occurrence", output "5" "let r = { a = 2 | { a = 3 } } let result = let { a ^ 1 = x | rest } = r in x + rest.a";
  "record-restrict", output "3" "let r = { a = 2 | { a = 3 } } let result = ({ r - a }).a";
  "record-equality", output "true" "let result = {a=1,b=2} == {b=2,a=1}";
  "variant-occurrence", output "7" "let result = match (< a ^ 1 7 >) with | < a  _ > -> 0 | < a ^ 1 n > -> n";
  "literal-pattern", output "2" "let result = match 1 with | 0 -> 4 | 1 -> 2 | fallback -> 3";
  "short-circuit", output "false" "let result = false && (1/0 == 0)";
  "disjunction", output "true" "let result = true || (1/0 == 0)";
  "string-join", output "\"kite\"" "let result = \"ki\" ^ \"te\"";
  "int32-wrap", output "-2147483648" "let result = 2147483647 + 1";
  "int32-product", output "1410065408" "let result = 100000 * 100000";
  "int32-product-zero", output "0" "let result = 65536 * 65536";
  "int32-quotient", output "-2147483648" "let result = (0 - 2147483647 - 1)/(0 - 1)";
  "signed-remainder", output "-1" "let result = (0 - 7) % 3";
  "division-zero", failure "division_by_zero" "let result = 1/0";
  "unmatched-pattern", failure "pattern_failed" "let result = match 1 with | 0 -> 9";
  "function-equality", failure "uncomparable_function" "let f x = x let result = f == f";
  "host-unavailable", failure "host_failed: unavailable: read" "import read : Int -> Int cost 1 deadline 50 let result = read 7";
  "deferred-freeze", output "7" "let result = 7 freeze { store } = 1/0";
  "recursive-value-refused", failure "executable recursive bindings require functions"
    "let result = let rec x = 1/0 in 42";
  "non-utf8-string-refused", failure "executable strings require valid utf-8"
    "let result = \"\255\"";
  "host-scoped-record-refused", failure "executable host record contracts require distinct field names"
    "import read : {a:Int,a:Int} -> Int cost 1 deadline 20 let result = 7";
  "unbound-ir", direct "unbound: absent" (Ir.IVar (Ident.of_string "absent"));
  "bad-application", direct "expected_function" (Ir.IApp (literal 1, literal 2));
  "missing-field", direct "missing_field: x" (Ir.ISel (Ir.IRec ([], None), Label.of_string "x"));
  "host-roundtrip", import_roundtrip;
  "host-type-rejection", import_rejection;
  "divergence-yields", divergence_yields;
]
let () = Runtime_suite.run "eval" cases
