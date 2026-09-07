let run suite cases =
  let args = match Array.to_list Sys.argv with
    | [] -> []
    | _program :: rest -> rest in
  let chosen = if args = [] then cases
    else List.filter (fun (name, _test) -> List.mem name args) cases in
  let unknown = List.filter (fun name -> not (List.mem_assoc name cases)) args in
  let failed = List.filter_map (fun (name, test) ->
      if test () then None else Some name) chosen in
  let failures = List.append unknown failed in
  let () = List.iter (fun name ->
      print_endline ("RUNTIME-FAIL " ^ suite ^ " " ^ name)) failures in
  let n = List.length chosen in
  let bad = List.length failures in
  let () = print_endline (String.concat " "
      ["RUNTIME"; "suite=" ^ suite; "tests=" ^ string_of_int n;
       "ok=" ^ string_of_int (n - List.length failed);
       "fail=" ^ string_of_int bad]) in
  if n > 0 && bad = 0 then exit 0 else exit 1
