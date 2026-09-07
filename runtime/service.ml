(* Durable channel records are folded only after their transaction commits. *)
module Names = Set.Make (String)
module Session_key = struct
  type t = string * string
  let compare = Stdlib.compare
end
module Sessions = Map.Make (Session_key)
module Message_key = struct
  type t = int * string * string * int * int * int
  let compare = Stdlib.compare
end
module Messages = Map.Make (Message_key)
let max_counter = 1_000_000_000
type sender = { service : string; sender : string; incarnation : int; session : int }
type publication = { source : sender; sequence : int; payload : string }
type event = Register of string | Handshake of sender | Send of publication
type message = { epoch : int; publication : publication }
type session = { source : sender; next_sequence : int option }
type view = { epoch : int; services : string list; sessions : session list;
              messages : message list }
type error = Invalid_name | Invalid_counter of string | Invalid_epoch
  | Stale_epoch of { current : int; actual : int }
  | Unknown_service of string | Missing_handshake | Stale_session
  | Out_of_order of { expected : int; actual : int }
  | Conflicting_replay | Counter_exhausted
type active = { identity : sender; last_sequence : int }
type t = { current_epoch : int; registered : Names.t; active : active Sessions.t;
           history : message list; accepted : string Messages.t }
let ( let* ) = Result.bind
let create () = {current_epoch = 0; registered = Names.empty; active = Sessions.empty;
                 history = []; accepted = Messages.empty}
let positive value = value > 0 && value <= max_counter
let valid_name name = String.length name > 0 && String.for_all (fun c ->
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    || c = '_' || c = '-') name
let successor value = if value = max_counter then None else Some (value + 1)
let view state = {epoch = state.current_epoch; services = Names.elements state.registered;
  sessions = List.map (fun (_key, active) ->
    {source = active.identity; next_sequence = successor active.last_sequence})
    (Sessions.bindings state.active); messages = List.rev state.history}
let error_text = function
  | Invalid_name -> "invalid_name"
  | Invalid_counter name -> "invalid_counter: " ^ name
  | Invalid_epoch -> "invalid_epoch"
  | Stale_epoch {current; actual} -> "stale_epoch: current " ^ string_of_int current
      ^ ", actual " ^ string_of_int actual
  | Unknown_service name -> "unknown_service: " ^ name
  | Missing_handshake -> "missing_handshake"
  | Stale_session -> "stale_session"
  | Out_of_order {expected; actual} -> "out_of_order: expected " ^ string_of_int expected
      ^ ", actual " ^ string_of_int actual
  | Conflicting_replay -> "conflicting_replay"
  | Counter_exhausted -> "counter_exhausted"
let observe_epoch epoch state =
  match () with
  | () when epoch < 0 || epoch > max_counter -> Error Invalid_epoch
  | () when epoch < state.current_epoch -> Error (Stale_epoch {current = state.current_epoch; actual = epoch})
  | () when epoch = state.current_epoch -> Ok state
  | () -> Ok {state with current_epoch = epoch; active = Sessions.empty}
let validate_sender (source : sender) =
  match () with
  | () when not (valid_name source.service) || not (valid_name source.sender) -> Error Invalid_name
  | () when not (positive source.incarnation) -> Error (Invalid_counter "incarnation")
  | () when not (positive source.session) -> Error (Invalid_counter "session")
  | () -> Ok ()
let key (source : sender) = (source.service, source.sender)
let same_generation (a : sender) (b : sender) = a.incarnation = b.incarnation && a.session = b.session
let newer_generation (a : sender) (b : sender) =
  a.incarnation > b.incarnation || (a.incarnation = b.incarnation && a.session > b.session)
let require_service name state =
  if Names.mem name state.registered then Ok () else Error (Unknown_service name)
let handshake source state =
  let* () = validate_sender source in let* () = require_service source.service state in
  let install () = Ok ({state with active = Sessions.add (key source)
      {identity = source; last_sequence = 0} state.active}, None) in
  Option.fold ~none:(fun () -> install ()) ~some:(fun prior () ->
    match () with
    | () when same_generation source prior.identity -> Ok (state, None)
    | () when newer_generation source prior.identity -> install ()
    | () -> Error Stale_session) (Sessions.find_opt (key source) state.active) ()
let message_key epoch (publication : publication) =
  let source = publication.source in
  (epoch, source.service, source.sender, source.incarnation, source.session, publication.sequence)
let send (publication : publication) state =
  let source = publication.source in
  let* () = validate_sender source in let* () = require_service source.service state in
  if not (positive publication.sequence) then Error (Invalid_counter "sender_sequence") else
  Option.fold ~none:(Error Missing_handshake) ~some:(fun prior ->
    if not (same_generation source prior.identity) then Error Stale_session else
    let identity = message_key state.current_epoch publication in
    Option.fold
      ~none:(fun () ->
        Option.fold ~none:(Error Counter_exhausted) ~some:(fun expected ->
          if publication.sequence <> expected then Error (Out_of_order {expected; actual = publication.sequence})
          else
            let message = {epoch = state.current_epoch; publication} in
            let active = {prior with last_sequence = publication.sequence} in
            let next = {state with active = Sessions.add (key source) active state.active;
              accepted = Messages.add identity publication.payload state.accepted;
              history = message :: state.history} in
            Ok (next, Some message)) (successor prior.last_sequence))
      ~some:(fun payload () -> if String.equal payload publication.payload
        then Ok (state, None) else Error Conflicting_replay)
      (Messages.find_opt identity state.accepted) ())
    (Sessions.find_opt (key source) state.active)
let apply ~epoch event state =
  if not (positive epoch) then Error Invalid_epoch else
  let* state = observe_epoch epoch state in
  match event with
  | Register name ->
    if not (valid_name name) then Error Invalid_name
    else Ok ({state with registered = Names.add name state.registered}, None)
  | Handshake source -> handshake source state
  | Send publication -> send publication state
let restore ~epoch records =
  let* restored = List.fold_left (fun acc (event_epoch, event) ->
    let* state = acc in Result.map fst (apply ~epoch:event_epoch event state)) (Ok (create ())) records in
  observe_epoch epoch restored
