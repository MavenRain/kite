(* A doorbell cannot install data. Only a validated committed prefix advances. *)
module Sequence = Map.Make (Int)
let max_counter = 1_000_000_000
type 'a entry = { seq : int; epoch : int; payload : 'a }
type error = Invalid_counter of string | Invalid_head | Stale_head
  | Entry_after_head of int | Unordered_batch
  | Gap of { expected : int; actual : int }
  | Epoch_regression of { previous : int; actual : int }
  | Conflicting_replay of int | Inconsistent_head
type 'a t = { position : int; prefix_epoch : int; announced : int;
              head_seq : int; head_epoch : int; saved : 'a entry Sequence.t;
              pending_heads : int Sequence.t }
let ( let* ) = Result.bind
let create () = { position = 0; prefix_epoch = 0; announced = 0;
                  head_seq = 0; head_epoch = 0; saved = Sequence.empty;
                  pending_heads = Sequence.empty }
let cursor state = state.position
let epoch state = state.prefix_epoch
let hint state = state.announced
let entries state = List.map snd (Sequence.bindings state.saved)
let valid_counter value = value >= 0 && value <= max_counter
let read_from state = if state.position = max_counter then None else Some (state.position + 1)
let notify ~seq state =
  if not (valid_counter seq) then Error (Invalid_counter "notification")
  else Ok { state with announced = max state.announced seq }
let error_text = function
  | Invalid_counter name -> "invalid_counter: " ^ name
  | Invalid_head -> "invalid_head"
  | Stale_head -> "stale_head"
  | Entry_after_head seq -> "entry_after_head: " ^ string_of_int seq
  | Unordered_batch -> "unordered_batch"
  | Gap {expected; actual} -> "gap: expected " ^ string_of_int expected ^ ", actual " ^ string_of_int actual
  | Epoch_regression {previous; actual} -> "epoch_regression: previous " ^ string_of_int previous
      ^ ", actual " ^ string_of_int actual
  | Conflicting_replay seq -> "conflicting_replay: " ^ string_of_int seq
  | Inconsistent_head -> "inconsistent_head"
let validate_head ~head_seq ~head_epoch state =
  match () with
  | () when not (valid_counter head_seq) -> Error (Invalid_counter "head_sequence")
  | () when not (valid_counter head_epoch) -> Error (Invalid_counter "head_epoch")
  | () when head_seq = 0 && head_epoch <> 0 -> Error Invalid_head
  | () when head_seq < state.head_seq || head_epoch < state.head_epoch -> Error Stale_head
  | () when head_seq = state.head_seq && head_epoch <> state.head_epoch -> Error Inconsistent_head
  | () -> Ok ()
let accept ~equal ~head_seq ~head_epoch entry (state, previous, accepted) =
  match () with
  | () when entry.seq <= 0 || not (valid_counter entry.seq) -> Error (Invalid_counter "entry_sequence")
  | () when not (valid_counter entry.epoch) -> Error (Invalid_counter "entry_epoch")
  | () when entry.seq < previous -> Error Unordered_batch
  | () when entry.seq > head_seq || entry.epoch > head_epoch -> Error (Entry_after_head entry.seq)
  | () when entry.seq <= state.position ->
    Option.fold ~none:(Error (Conflicting_replay entry.seq))
      ~some:(fun saved ->
        if saved.epoch = entry.epoch && equal saved.payload entry.payload
        then Ok (state, entry.seq, accepted) else Error (Conflicting_replay entry.seq))
      (Sequence.find_opt entry.seq state.saved)
  | () ->
    Option.fold ~none:(Error (Invalid_counter "exhausted_sequence"))
      ~some:(fun expected ->
        match () with
        | () when entry.seq <> expected -> Error (Gap {expected; actual = entry.seq})
        | () when entry.epoch < state.prefix_epoch ->
          Error (Epoch_regression {previous = state.prefix_epoch; actual = entry.epoch})
        | () when Option.fold ~none:false ~some:(fun (boundary, expected) ->
            (boundary = entry.seq && expected <> entry.epoch) || entry.epoch > expected)
            (Sequence.find_first_opt (fun boundary -> boundary >= entry.seq) state.pending_heads) ->
          Error Inconsistent_head
        | () ->
          let next = { state with position = entry.seq; prefix_epoch = entry.epoch;
            saved = Sequence.add entry.seq entry state.saved } in
          Ok (next, entry.seq, entry :: accepted)) (read_from state)
let apply ~equal ~head_seq ~head_epoch page state =
  let* () = validate_head ~head_seq ~head_epoch state in
  let observed = {state with pending_heads = Sequence.add head_seq head_epoch state.pending_heads} in
  let* (next, _previous, accepted) = List.fold_left (fun acc entry ->
      let* current = acc in accept ~equal ~head_seq ~head_epoch entry current)
      (Ok (observed, 0, [])) page in
  if next.position = head_seq && next.prefix_epoch <> head_epoch then Error Inconsistent_head
  else
    let pending_heads = Sequence.filter (fun seq _epoch -> seq > next.position) next.pending_heads in
    Ok ({next with head_seq; head_epoch; pending_heads;
      announced = max next.announced head_seq}, List.rev accepted)
