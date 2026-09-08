(* Opaque handles retain native protocols across browser callbacks. *)
open Js_of_ocaml
module F = Kite_runtime.Feed
module S = Kite_runtime.Service
module V = Kite_runtime.Volume
module J = Js.Unsafe
let ( let* ) = Result.bind
let text value = J.inject (Js.string value)
let number value = J.inject value
let boolean value = J.inject (Js.bool value)
let null = J.inject Js.null
let kind value = Js.to_string (Js.typeof value)
let invalid name = Error ("invalid_" ^ name)
let failure error = J.obj [|"ok", boolean false; "error", text error|]
let success value = J.obj [|"ok", boolean true; "value", value|]
let answer render = Result.fold ~error:failure ~ok:(fun value -> success (render value))
let read_string name value =
  if String.equal (kind value) "string" then Ok (Js.to_string (J.coerce value))
  else invalid name
let read_int name value =
  if not (String.equal (kind value) "number") then invalid name else
  let value = Js.to_float (J.coerce value) in
  if Float.is_finite value && Float.equal value (Float.trunc value)
     && value >= -2147483648. && value <= 2147483647.
  then Ok (int_of_float value) else invalid name
let read_bool name value =
  if String.equal (kind value) "boolean" then Ok (Js.to_bool (J.coerce value))
  else invalid name
let is_array value =
  Js.to_bool (J.meth_call (J.get J.global "Array") "isArray" [|value|])
let read_object name value =
  if String.equal (kind value) "object" && not (J.strict_equals value Js.null)
     && not (is_array value) then Ok value else invalid name
let field parser value name = parser name (J.get value name)
let traverse parser values = Result.map List.rev (List.fold_left (fun acc value ->
    let* reversed = acc in let* parsed = parser value in Ok (parsed :: reversed)) (Ok []) values)
let read_list parser name value =
  if is_array value then
    traverse parser (Array.to_list (Js.to_array (J.coerce value)))
  else invalid name
let js_list render values =
  J.inject (Js.array (Array.of_list (List.map render values)))
let optional render = Option.fold ~none:null ~some:render
let state_handles = J.new_obj (J.get J.global "WeakSet") [||]
let operation_handles = J.new_obj (J.get J.global "WeakSet") [||]
let receipt_handles = J.new_obj (J.get J.global "WeakMap") [||]
let registered handles value =
  let () = ignore (J.meth_call handles "add" [|value|]) in value
let registered_with handles value =
  Js.to_bool (J.meth_call handles "has" [|value|])
let invoke handle operation payload =
  if String.equal (kind handle) "function" && registered_with state_handles handle then
    J.fun_call handle [|text operation; payload|]
  else failure "invalid_state"

type json = Null | Bool of bool | Number of float | String of string
  | List of json list | Object of (string * json) list
let rec read_json depth value =
  if depth > 256 then invalid "payload_depth" else
  match kind value with
  | "boolean" -> Result.map (fun value -> Bool value) (read_bool "payload" value)
  | "string" -> Result.map (fun value -> String value) (read_string "payload" value)
  | "number" ->
    let value = Js.to_float (J.coerce value) in
    if Float.is_finite value then Ok (Number value) else invalid "payload_number"
  | "object" ->
    if J.strict_equals value Js.null then Ok Null else
    if is_array value then Result.map (fun values -> List values)
        (read_list (read_json (depth + 1)) "payload" value) else
      let* keys = read_list (read_string "payload_key") "payload_keys"
          (J.meth_call (J.get J.global "Object") "keys" [|value|]) in
      Result.map (fun fields -> Object fields) (traverse (fun key ->
          let* body = read_json (depth + 1) (J.get value key) in Ok (key, body))
          (List.sort String.compare keys))
  | name -> invalid ("payload_" ^ name)
let rec render_json = function
  | Null -> null
  | Bool value -> boolean value
  | Number value -> J.inject (Js.number_of_float value)
  | String value -> text value
  | List values -> js_list render_json values
  | Object values ->
    let result = J.meth_call (J.get J.global "Object") "create" [|null|] in
    let () = List.iter (fun (name, value) -> J.set result name (render_json value)) values in
    result
let read_entry value =
  let* value = read_object "entry" value in
  let* seq = field read_int value "seq" in
  let* epoch = field read_int value "epoch" in
  let* payload = read_json 0 (J.get value "payload") in
  Ok {F.seq; epoch; payload}
let render_entry (value : json F.entry) = J.obj
    [|"seq", number value.seq; "epoch", number value.epoch;
      "payload", render_json value.payload|]
let feed_snapshot value =
  let* value = read_object "feed_snapshot" value in
  let* head_seq = field read_int value "seq" in
  let* head_epoch = field read_int value "epoch" in
  let* entries = field (read_list read_entry) value "entries" in
  Ok (head_seq, head_epoch, entries)
let apply_feed state value =
  let* head_seq, head_epoch, entries = feed_snapshot value in
  Result.map_error F.error_text (F.apply ~equal:( = ) ~head_seq ~head_epoch entries state)
let rec feed_handle state = registered state_handles (J.inject (J.callback (fun operation payload ->
    let result = let* name = read_string "operation" operation in
      match name with
      | "apply" -> Result.map (fun (next, accepted) -> J.obj
          [|"state", feed_handle next; "accepted", js_list render_entry accepted;
            "cursor", number (F.cursor next)|]) (apply_feed state payload)
      | "notify" ->
        let* seq = read_int "sequence" payload in
        Result.map feed_handle (Result.map_error F.error_text (F.notify ~seq state))
      | other -> invalid ("feed_operation:" ^ other) in
    answer (fun value -> value) result)))

let volume_error = function
  | V.Invalid_key -> "invalid_key"
  | V.Invalid_counter -> "invalid_counter"
  | V.Invalid_snapshot -> "invalid_snapshot"
  | V.Wrong_volume -> "wrong_volume"
  | V.Stale_epoch -> "stale_epoch"
  | V.Stale_generation -> "stale_generation"
  | V.Stale_revision -> "stale_revision"
  | V.Stale_callback -> "stale_callback"
  | V.Invalid_phase -> "invalid_phase"
  | V.Counter_exhausted -> "counter_exhausted"
  | V.Lock_denied -> "lock_denied"
  | V.Aborted -> "aborted"
  | V.Storage_failed message -> "storage_failed:" ^ message
let read_volume_error value =
  let* message = read_string "volume_error" value in
  Ok (match message with
    | "invalid_key" -> V.Invalid_key
    | "invalid_counter" -> V.Invalid_counter
    | "invalid_snapshot" -> V.Invalid_snapshot
    | "wrong_volume" -> V.Wrong_volume
    | "stale_epoch" -> V.Stale_epoch
    | "stale_generation" -> V.Stale_generation
    | "stale_revision" -> V.Stale_revision
    | "stale_callback" -> V.Stale_callback
    | "invalid_phase" -> V.Invalid_phase
    | "counter_exhausted" -> V.Counter_exhausted
    | "lock_denied" -> V.Lock_denied
    | "aborted" -> V.Aborted
    | other -> V.Storage_failed other)
let read_key value =
  let* value = read_string "volume_key" value in
  match String.split_on_char ':' value with
  | [namespace; ordinal] ->
    let* ordinal = Option.fold ~none:(invalid "volume_key") ~some:(fun value -> Ok value)
        (int_of_string_opt ordinal) in
    let* key = Result.map_error volume_error (V.key ~namespace ~ordinal) in
    if String.equal (V.key_text key) value then Ok key else invalid "volume_key"
  | [] | [_] | _ :: _ :: _ :: _ -> invalid "volume_key"
let read_checkpoint value =
  let* value = read_object "checkpoint" value in
  let* revision = field read_int value "revision" in
  let* entries = field (read_list (read_string "checkpoint_entry")) value "entries" in
  Ok {V.revision; entries}
let read_volume value =
  let* value = read_object "volume_snapshot" value in
  let* key = read_key (J.get value "key") in
  let* epoch = field read_int value "epoch" in
  let* generation = field read_int value "generation" in
  let* committed = read_checkpoint (J.get value "committed") in
  Result.map_error volume_error (V.restore {V.key; epoch; generation; committed})
let checkpoint (value : V.checkpoint) = J.obj
    [|"revision", number value.revision; "entries", js_list text value.entries|]
let volume_snapshot durable =
  let value = V.snapshot durable in
  J.obj [|"key", text (V.key_text value.key); "epoch", number value.epoch;
          "generation", number value.generation; "committed", checkpoint value.committed|]
let lease (value : V.lease) = J.obj
    [|"key", text (V.key_text value.key); "ticket", number value.ticket|]
let fence (value : V.fence) = J.obj
    [|"key", text (V.key_text value.key); "epoch", number value.epoch;
      "generation", number value.generation|]
let write_fields (value : V.write) =
  ["lease", lease value.lease; "fence", fence value.fence;
   "ticket", number value.ticket; "expectedRevision", number value.expected_revision;
   "entries", js_list text value.entries]
let object_fields fields =
  let value = J.meth_call (J.get J.global "Object") "create" [|null|] in
  let () = List.iter (fun (key, field) -> J.set value key field) fields in value
let phase = function
  | V.Detached -> "detached" | V.Acquiring -> "acquiring" | V.Claiming -> "claiming"
  | V.Attached -> "attached" | V.Prepared -> "prepared" | V.In_flight -> "in_flight"
  | V.Releasing -> "releasing"
let mode = function V.Active -> "active" | V.Freezing -> "freezing" | V.Frozen -> "frozen"
let volume_view state =
  let value = V.view state in
  J.obj [|"key", text (V.key_text value.key); "mode", text (mode value.mode);
          "phase", text (phase value.phase); "ticket", number value.ticket;
          "writer", optional fence value.writer; "committed", checkpoint value.committed;
          "pending", optional (fun value -> object_fields (write_fields value)) value.pending;
          "lockHeld", boolean value.lock_held;
          "lastResult", optional (fun result -> answer checkpoint
            (Result.map_error volume_error result)) value.last_result|]

(* Receipt tokens keep native values inside the boundary. *)
type receipt = Claim_receipt of V.claim_receipt | Write_receipt of V.write_receipt
let receipt_handle value =
  let token = J.obj [||] in
  let capability = J.inject (J.callback (fun visit -> visit value)) in
  let () = ignore (J.meth_call receipt_handles "set" [|token; capability|]) in token
let consume_receipt handle consume =
  if not (registered_with receipt_handles handle) then failure "invalid_receipt" else
    let capability = J.meth_call receipt_handles "get" [|handle|] in
    J.fun_call capability [|J.inject consume|]
let atomic_response = answer (fun (durable, receipt) -> J.obj
    [|"snapshot", volume_snapshot durable; "receipt", receipt_handle receipt|])
let claim_operation claim = registered operation_handles (J.inject (J.callback (fun snapshot ->
    let result = let* durable = read_volume snapshot in
      Result.map (fun (next, receipt) -> next, Claim_receipt receipt)
        (Result.map_error volume_error (V.apply_claim durable claim)) in
    atomic_response result)))
let write_operation write = registered operation_handles (J.inject (J.callback (fun snapshot ->
    let result = let* durable = read_volume snapshot in
      Result.map (fun (next, receipt) -> next, Write_receipt receipt)
        (Result.map_error volume_error (V.apply_write durable write)) in
    atomic_response result)))
let volume_action = function
  | V.Acquire_lock value -> J.obj
      [|"kind", text "acquire_lock"; "lease", lease value|]
  | V.Release_lock value -> J.obj
      [|"kind", text "release_lock"; "lease", lease value|]
  | V.Claim_writer value -> J.obj
      [|"kind", text "claim_writer"; "lease", lease value.lease;
        "epoch", number value.epoch; "expectedGeneration", number value.expected_generation;
        "operation", claim_operation value|]
  | V.Abort_claim value -> J.obj
      [|"kind", text "abort_claim"; "lease", lease value.lease;
        "epoch", number value.epoch; "expectedGeneration", number value.expected_generation|]
  | V.Commit_checkpoint value -> object_fields
      (("kind", text "commit_checkpoint") :: ("operation", write_operation value) :: write_fields value)
  | V.Abort_write value -> object_fields (("kind", text "abort_write") :: write_fields value)
let read_event name value =
  match name with
  | "attach" -> Result.map (fun epoch -> V.Attach epoch) (field read_int value "epoch")
  | "lock_acquired" ->
    let* ticket = field read_int value "ticket" in
    let* durable = read_volume (J.get value "durable") in Ok (V.Lock_acquired {ticket; durable})
  | "lock_refused" -> Result.map (fun ticket -> V.Lock_refused ticket) (field read_int value "ticket")
  | "prepare" -> Result.map (fun entries -> V.Prepare entries)
      (field (read_list (read_string "checkpoint_entry")) value "entries")
  | "begin_write" -> Result.map (fun ticket -> V.Begin_write ticket) (field read_int value "ticket")
  | "freeze" -> Ok V.Freeze
  | "released" -> Result.map (fun ticket -> V.Released ticket) (field read_int value "ticket")
  | "discard" -> Ok V.Discard
  | other -> invalid ("volume_event:" ^ other)
let rec volume_handle state = registered state_handles (J.inject (J.callback (fun operation payload ->
    Result.fold ~error:failure ~ok:(fun name ->
      match name with
      | "view" -> success (volume_view state)
      | "step" -> volume_step state payload
      | other -> failure ("invalid_volume_operation:" ^ other))
      (read_string "operation" operation))))
and volume_response state actions = success (J.obj
    [|"state", volume_handle state; "actions", js_list volume_action actions;
      "view", volume_view state|])
and apply_event state event = Result.fold ~error:(fun error -> failure (volume_error error))
    ~ok:(fun (next, actions) -> volume_response next actions) (V.step state event)
and volume_step state payload =
  let parsed = let* value = read_object "volume_event" payload in
    let* name = field read_string value "kind" in Ok (name, value) in
  Result.fold ~error:failure ~ok:(fun (name, value) ->
    if String.equal name "claimed" || String.equal name "completed"
    then complete_event state name value else
      Result.fold ~error:failure ~ok:(apply_event state) (read_event name value)) parsed
and complete_event state name value =
  let parsed = let* ticket = field read_int value "ticket" in
    let* result = read_object "transaction_result" (J.get value "result") in
    let* ok = field read_bool result "ok" in Ok (ticket, result, ok) in
  Result.fold ~error:failure ~ok:(fun (ticket, result, ok) ->
    if ok then consume_receipt (J.get result "value") (function
      | Claim_receipt receipt ->
        if String.equal name "claimed" then apply_event state (V.Claimed {ticket; result = Ok receipt})
        else failure "invalid_receipt_kind"
      | Write_receipt receipt ->
        if String.equal name "completed" then apply_event state (V.Completed {ticket; result = Ok receipt})
        else failure "invalid_receipt_kind")
    else Result.fold ~error:failure ~ok:(fun error ->
      if String.equal name "claimed" then apply_event state (V.Claimed {ticket; result = Error error})
      else apply_event state (V.Completed {ticket; result = Error error}))
      (read_volume_error (J.get result "error"))) parsed
let volume namespace ordinal first_ticket =
  let result = let* namespace = read_string "namespace" namespace in
    let* ordinal = read_int "ordinal" ordinal in
    let* first_ticket = read_int "firstTicket" first_ticket in
    let* key = Result.map_error volume_error (V.key ~namespace ~ordinal) in
    Result.map_error volume_error (V.session key ~first_ticket) in
  answer volume_handle result
let atomic_volume snapshot operation =
  Result.fold ~error:failure ~ok:(fun value ->
    let capability = J.get value "operation" in
    if String.equal (kind capability) "function" && registered_with operation_handles capability
    then J.fun_call capability [|snapshot|]
    else failure "invalid_volume_operation") (read_object "volume_operation" operation)

let read_sender value =
  let* value = read_object "sender" value in
  let* service = field read_string value "service" in
  let* sender = field read_string value "sender" in
  let* incarnation = field read_int value "incarnation" in
  let* session = field read_int value "session" in
  Ok {S.service; sender; incarnation; session}
let read_publication value =
  let* value = read_object "publication" value in
  let* source = read_sender (J.get value "source") in
  let* sequence = field read_int value "sequence" in
  let* payload = field read_string value "payload" in Ok {S.source; sequence; payload}
let read_service_event value =
  let* value = read_object "service_event" value in
  let* name = field read_string value "kind" in
  match name with
  | "register" -> Result.map (fun name -> S.Register name) (field read_string value "name")
  | "handshake" -> Result.map (fun source -> S.Handshake source) (read_sender (J.get value "source"))
  | "send" -> Result.map (fun value -> S.Send value) (read_publication (J.get value "publication"))
  | other -> invalid ("service_event:" ^ other)
let sender (value : S.sender) = J.obj
    [|"service", text value.service; "sender", text value.sender;
      "incarnation", number value.incarnation; "session", number value.session|]
let publication (value : S.publication) = J.obj
    [|"source", sender value.source; "sequence", number value.sequence; "payload", text value.payload|]
let message (value : S.message) = J.obj
    [|"epoch", number value.epoch; "publication", publication value.publication|]
let service_view state =
  let value = S.view state in
  J.obj [|"epoch", number value.epoch; "services", js_list text value.services;
          "sessions", js_list (fun (session : S.session) -> J.obj
            [|"source", sender session.source; "nextSequence", optional number session.next_sequence|]) value.sessions;
          "messages", js_list message value.messages|]
let service_record (entry : json F.entry) =
  match entry.payload with
  | Object fields ->
    if List.assoc_opt "kind" fields = Some (String "service") then
      Option.fold ~none:(invalid "service_record") ~some:(fun event ->
        Result.map (fun event -> Some (entry.epoch, event)) (read_service_event (render_json event)))
        (List.assoc_opt "event" fields)
    else Ok None
  | Null | Bool _ | Number _ | String _ | List _ -> Ok None
let restore_service snapshot =
  let* state, _accepted = apply_feed (F.create ()) snapshot in
  let* head_seq, _head_epoch, _entries = feed_snapshot snapshot in
  let* () = if F.cursor state = head_seq then Ok () else invalid "incomplete_service_snapshot" in
  let* records = traverse service_record (F.entries state) in
  Result.map_error S.error_text (S.restore ~epoch:(F.epoch state) (List.filter_map Fun.id records))
let service_check snapshot epoch event =
  let result = let* state = restore_service snapshot in
    let* epoch = read_int "epoch" epoch in
    let* event = read_service_event event in
    let* next, delivered = Result.map_error S.error_text (S.apply ~epoch event state) in
    Ok (S.view next = S.view state, delivered) in
  answer (fun (duplicate, delivered) -> J.obj
    [|"duplicate", boolean duplicate; "message", optional message delivered|]) result
let install () = Js.export "KiteDurableModel" (J.obj
    [|"feed", J.inject (J.callback (fun () -> feed_handle (F.create ())));
      "feedApply", J.inject (J.callback (fun state snapshot -> invoke state "apply" snapshot));
      "feedNotify", J.inject (J.callback (fun state seq -> invoke state "notify" seq));
      "volume", J.inject (J.callback volume);
      "volumeStep", J.inject (J.callback (fun state event -> invoke state "step" event));
      "volumeView", J.inject (J.callback (fun state -> invoke state "view" null));
      "atomicVolume", J.inject (J.callback atomic_volume);
      "serviceCheck", J.inject (J.callback service_check);
      "serviceRestore", J.inject (J.callback (fun snapshot -> answer service_view (restore_service snapshot)))|])
