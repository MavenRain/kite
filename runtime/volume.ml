type key = { namespace : string; ordinal : int }
type error = Invalid_key | Invalid_counter | Invalid_snapshot | Wrong_volume
  | Stale_epoch | Stale_generation | Stale_revision | Stale_callback | Invalid_phase
  | Counter_exhausted | Lock_denied | Aborted | Storage_failed of string
let limit = 1_000_000_000
let key ~namespace ~ordinal =
  let valid c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9') || c = '_' || c = '-' in
  if namespace = "" || String.length namespace > 64
     || not (String.for_all valid namespace) || ordinal < 0 || ordinal > limit
  then Error Invalid_key else Ok {namespace; ordinal}
let key_text key = key.namespace ^ ":" ^ string_of_int key.ordinal
type checkpoint = { revision : int; entries : string list }
type snapshot = { key : key; epoch : int; generation : int; committed : checkpoint }
type durable = Durable of snapshot
let ( let* ) = Result.bind
let bounded n = n >= 0 && n <= limit
let positive n = n > 0 && n <= limit
let empty = {revision = 0; entries = []}
let snapshot (Durable state) = state
let restore (state : snapshot) =
  match () with
  | () when not (positive state.epoch && bounded state.generation
                 && bounded state.committed.revision) -> Error Invalid_counter
  | () when (state.committed.revision = 0 && state.committed.entries <> [])
         || (state.generation = 0 && state.committed.revision <> 0) -> Error Invalid_snapshot
  | () -> Ok (Durable state)
let create key ~epoch = restore {key; epoch; generation = 0; committed = empty}
let observe_epoch (Durable state) epoch =
  match () with
  | () when not (positive epoch) -> Error Invalid_counter
  | () when epoch < state.epoch -> Error Stale_epoch
  | () -> Ok (Durable {state with epoch})
type lease = { key : key; ticket : int }
type fence = { key : key; epoch : int; generation : int }
type claim = { lease : lease; epoch : int; expected_generation : int }
type write = {
  lease : lease; fence : fence; ticket : int; expected_revision : int;
  entries : string list
}
type claim_receipt = { claim : claim; writer : fence; recovered : checkpoint }
type write_receipt = { write : write; saved : checkpoint }
let apply_claim (Durable state) (claim : claim) =
  match () with
  | () when state.key <> claim.lease.key -> Error Wrong_volume
  | () when state.epoch <> claim.epoch -> Error Stale_epoch
  | () when state.generation <> claim.expected_generation -> Error Stale_generation
  | () when state.generation = limit -> Error Counter_exhausted
  | () ->
    let generation = state.generation + 1 in
    let writer = {key = state.key; epoch = state.epoch; generation} in
    Ok (Durable {state with generation}, {claim; writer; recovered = state.committed})
let apply_write (Durable state) (write : write) =
  match () with
  | () when state.key <> write.fence.key -> Error Wrong_volume
  | () when state.epoch <> write.fence.epoch -> Error Stale_epoch
  | () when state.generation <> write.fence.generation -> Error Stale_generation
  | () when state.committed.revision <> write.expected_revision -> Error Stale_revision
  | () when state.committed.revision = limit -> Error Counter_exhausted
  | () ->
    let saved = {revision = state.committed.revision + 1;
      entries = List.append state.committed.entries write.entries} in
    Ok (Durable {state with committed = saved}, {write; saved})
type mode = Active | Freezing | Frozen
type phase = Detached | Acquiring | Claiming | Attached | Prepared | In_flight | Releasing
type pending = Nothing | Await_lock of lease * int | Await_claim of claim
  | Staged of write | Writing of write | Await_release of lease
type session = {
  key : key; mode : mode; ticket : int; writer : fence option;
  committed : checkpoint; lease : lease option; pending : pending;
  last_result : (checkpoint, error) result option
}
type view = {
  key : key; mode : mode; phase : phase; ticket : int;
  writer : fence option; committed : checkpoint; pending : write option;
  lock_held : bool; last_result : (checkpoint, error) result option
}
type event = Attach of int
  | Lock_acquired of { ticket : int; durable : durable }
  | Lock_refused of int
  | Claimed of { ticket : int; result : (claim_receipt, error) result }
  | Prepare of string list | Begin_write of int
  | Completed of { ticket : int; result : (write_receipt, error) result }
  | Freeze | Released of int | Discard
type action = Acquire_lock of lease | Claim_writer of claim
  | Commit_checkpoint of write | Abort_claim of claim | Abort_write of write
  | Release_lock of lease
let session key ~first_ticket =
  if not (bounded first_ticket) then Error Invalid_counter else
    Ok {key; mode = Active; ticket = first_ticket; writer = None;
        committed = empty; lease = None; pending = Nothing; last_result = None}
let view (state : session) =
  let phase, pending = match state.pending with
    | Nothing -> (if Option.is_some state.writer then Attached else Detached), None
    | Await_lock _ -> Acquiring, None
    | Await_claim _ -> Claiming, None
    | Staged write -> Prepared, Some write
    | Writing write -> In_flight, Some write
    | Await_release _ -> Releasing, None in
  {key = state.key; mode = state.mode; phase; ticket = state.ticket;
   writer = state.writer; committed = state.committed; pending;
   lock_held = Option.is_some state.lease; last_result = state.last_result}
let release (state : session) =
  Option.fold
    ~none:({state with mode = Frozen; writer = None; pending = Nothing}, [])
    ~some:(fun lease -> ({state with writer = None; pending = Await_release lease},
                         [Release_lock lease])) state.lease
let clear (state : session) =
  {state with mode = Frozen; writer = None; lease = None; pending = Nothing}
let attach (state : session) epoch =
  match () with
  | () when not (positive epoch) -> Error Invalid_counter
  | () when state.pending <> Nothing || Option.is_some state.lease -> Error Invalid_phase
  | () when state.ticket = limit -> Error Counter_exhausted
  | () ->
    let ticket = state.ticket + 1 in
    let lease = {key = state.key; ticket} in
    Ok ({state with mode = Active; ticket; writer = None; last_result = None;
          pending = Await_lock (lease, epoch)}, [Acquire_lock lease])
let lock_acquired (state : session) ticket durable =
  if not (positive ticket) then Error Invalid_counter else
  match state.pending with
  | Await_lock (lease, epoch) when lease.ticket = ticket ->
    let observed = snapshot durable in
    let invalid = if observed.key <> state.key then Some Wrong_volume
      else if observed.epoch <> epoch then Some Stale_epoch else None in
    Option.fold ~some:(fun error -> Ok (release {state with mode = Freezing;
        lease = Some lease; last_result = Some (Error error)}))
      ~none:(let claim = {lease; epoch; expected_generation = observed.generation} in
        Ok ({state with lease = Some lease; pending = Await_claim claim}, [Claim_writer claim])) invalid
  | Nothing | Await_lock _ | Await_claim _ | Staged _ | Writing _ | Await_release _ ->
    if Option.fold ~none:false ~some:(fun (lease : lease) -> lease.ticket = ticket) state.lease
    then Error Stale_callback else Ok (state, [Release_lock {key = state.key; ticket}])
let lock_refused (state : session) ticket =
  match state.pending with
  | Await_lock (lease, _epoch) when lease.ticket = ticket ->
    Ok ({state with pending = Nothing; last_result = Some (Error Lock_denied)}, [])
  | Nothing | Await_lock _ | Await_claim _ | Staged _ | Writing _ | Await_release _ ->
    Error Stale_callback
let claimed (state : session) ticket result =
  match state.pending with
  | Await_claim claim when claim.lease.ticket = ticket ->
    Result.fold
      ~error:(fun error -> Ok (release {state with mode = Freezing;
                                       last_result = Some (Error error)}))
      ~ok:(fun receipt ->
        if receipt.claim <> claim then Error Stale_callback else
        let next = {state with writer = Some receipt.writer;
          committed = receipt.recovered; pending = Nothing} in
        if state.mode = Active then Ok (next, []) else Ok (release next)) result
  | Nothing | Await_lock _ | Await_claim _ | Staged _ | Writing _ | Await_release _ ->
    Error Stale_callback
let prepare (state : session) entries =
  match () with
  | () when state.mode <> Active || state.pending <> Nothing -> Error Invalid_phase
  | () when state.ticket = limit || state.committed.revision = limit -> Error Counter_exhausted
  | () -> Option.fold ~none:(Error Invalid_phase) ~some:(fun fence ->
      Option.fold ~none:(Error Invalid_phase) ~some:(fun lease ->
        let ticket = state.ticket + 1 in
        let write = {lease; fence; ticket; expected_revision = state.committed.revision; entries} in
        Ok ({state with ticket; pending = Staged write; last_result = None}, [])) state.lease) state.writer
let begin_write (state : session) ticket =
  match state.pending with
  | Staged write when write.ticket = ticket && state.mode = Active ->
    Ok ({state with pending = Writing write}, [Commit_checkpoint write])
  | Nothing | Await_lock _ | Await_claim _ | Staged _ | Writing _ | Await_release _ ->
    Error Stale_callback
let completed (state : session) ticket result =
  match state.pending with
  | Writing write when write.ticket = ticket ->
    let* outcome = Result.fold ~error:(fun error -> Ok (Error error))
      ~ok:(fun receipt -> if receipt.write = write then Ok (Ok receipt.saved)
            else Error Stale_callback) result in
    let committed = Result.value ~default:state.committed outcome in
    let next = {state with committed; pending = Nothing; last_result = Some outcome} in
    if state.mode = Active then Ok (next, []) else Ok (release next)
  | Nothing | Await_lock _ | Await_claim _ | Staged _ | Writing _ | Await_release _ ->
    Error Stale_callback
let freeze (state : session) =
  if state.mode = Freezing then Ok (state, []) else
  let next = {state with mode = Freezing} in
  match state.pending with
  | Await_claim claim -> Ok (next, [Abort_claim claim])
  | Writing write -> Ok (next, [Abort_write write])
  | Staged _ -> Ok (release {next with last_result = Some (Error Aborted)})
  | Nothing | Await_lock _ | Await_release _ -> Ok (release next)
let released (state : session) ticket =
  match state.pending with
  | Await_release lease when lease.ticket = ticket -> Ok (clear state, [])
  | Nothing | Await_lock _ | Await_claim _ | Staged _ | Writing _ | Await_release _ ->
    Error Stale_callback
let step state = function
  | Attach epoch -> attach state epoch
  | Lock_acquired {ticket; durable} -> lock_acquired state ticket durable
  | Lock_refused ticket -> lock_refused state ticket
  | Claimed {ticket; result} -> claimed state ticket result
  | Prepare entries -> prepare state entries
  | Begin_write ticket -> begin_write state ticket
  | Completed {ticket; result} -> completed state ticket result
  | Freeze -> freeze state
  | Released ticket -> released state ticket
  | Discard -> Ok (clear state, [])
