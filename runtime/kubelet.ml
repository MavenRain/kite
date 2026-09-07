(* Node-local state and an ordered effect protocol. Actual browser calls
   and transaction epoch checks are implemented by later runtime layers. *)

type mode = Ready | Frozen

type worker_phase = Starting | Running | Stopping

type worker =
  { pod : int;
    ticket : int;
    incarnation : int;
    phase : worker_phase
  }

type view =
  { node_id : string;
    incarnation : int;
    epoch : int;
    mode : mode;
    node_lock : bool;
    workers : worker list
  }

type event =
  | Node_acquired of int
  | Node_lost of int
  | Observe_epoch of int
  | Start of { epoch : int; pod : int; incarnation : int }
  | Stop of { epoch : int; pod : int; incarnation : int }
  | Pod_lock of { ticket : int; granted : bool }
  | Worker_exited of int
  | Freeze
  | Resume

type action =
  | Acquire_node of int
  | Release_node of int
  | Spawn of worker
  | Terminate of worker
  | Publish_place of worker
  | Release_place of worker
  | Begin_work of worker

type error =
  | Invalid_node
  | Invalid_incarnation
  | Invalid_pod
  | Invalid_epoch
  | Stale_epoch
  | Stale_incarnation
  | Node_unavailable
  | Duplicate_pod
  | Unknown_worker
  | Counter_exhausted

type t = { current : view; last_ticket : int }

let ( let* ) = Result.bind

let valid_node_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9') || c = '_' || c = '-'

let create ~node_id ~incarnation : (t, error) result =
  match () with
  | () when String.length node_id = 0
            || not (String.for_all valid_node_char node_id) -> Error Invalid_node
  | () when incarnation <= 0 -> Error Invalid_incarnation
  | () ->
    Ok
      { current =
          { node_id; incarnation; epoch = 0; mode = Ready;
            node_lock = false; workers = [] };
        last_ticket = 0
      }

let view (state : t) : view = state.current

let check_incarnation (state : t) incarnation =
  match () with
  | () when incarnation <= 0 -> Error Invalid_incarnation
  | () when incarnation <> state.current.incarnation -> Error Stale_incarnation
  | () -> Ok ()

let check_command (state : t) ~epoch ~pod ~incarnation =
  let* () = check_incarnation state incarnation in
  match () with
  | () when epoch <= 0 -> Error Invalid_epoch
  | () when epoch <> state.current.epoch -> Error Stale_epoch
  | () when pod < 0 -> Error Invalid_pod
  | () -> Ok ()

let available (state : t) =
  match state.current.mode with
  | Ready -> state.current.node_lock
  | Frozen -> false

let with_workers (state : t) workers =
  { state with current = { state.current with workers } }

let replace_worker (state : t) (replacement : worker) =
  with_workers state
    (List.map
       (fun (w : worker) -> if w.ticket = replacement.ticket then replacement else w)
       state.current.workers)

let stop_worker (w : worker) : worker * action list =
  let stopped = { w with phase = Stopping } in
  match w.phase with
  | Starting -> (stopped, [ Terminate stopped ])
  | Running -> (stopped, [ Release_place w; Terminate stopped ])
  | Stopping -> (w, [])

let cancel_start (w : worker) : worker * action list =
  match w.phase with
  | Starting -> stop_worker w
  | Running -> (w, [])
  | Stopping -> (w, [])

let transform_workers transform (state : t) =
  let (workers, effects) = List.split (List.map transform state.current.workers) in
  (with_workers state workers, List.concat effects)

let freeze (state : t) =
  match state.current.mode with
  | Frozen -> Ok (state, [])
  | Ready ->
    let release =
      if state.current.node_lock then [ Release_node state.current.incarnation ]
      else [] in
    let (stopped, effects) = transform_workers stop_worker state in
    let current = { stopped.current with mode = Frozen; node_lock = false } in
    Ok ({ stopped with current }, List.append release effects)

let resume (state : t) =
  match state.current.mode with
  | Ready -> Ok (state, [])
  | Frozen ->
    if state.current.incarnation = Int.max_int then Error Counter_exhausted
    else
      let incarnation = state.current.incarnation + 1 in
      let current =
        { state.current with incarnation; mode = Ready; node_lock = false } in
      Ok ({ state with current }, [ Acquire_node incarnation ])

let acquire_node (state : t) incarnation =
  match () with
  | () when incarnation <= 0 -> Error Invalid_incarnation
  | () when incarnation <> state.current.incarnation ->
    Ok (state, [ Release_node incarnation ])
  | () ->
    match state.current.mode with
    | Frozen -> Ok (state, [ Release_node incarnation ])
    | Ready ->
      let current = { state.current with node_lock = true } in
      Ok ({ state with current }, [])

let observe_epoch (state : t) epoch =
  match () with
  | () when epoch <= 0 -> Error Invalid_epoch
  | () when epoch < state.current.epoch -> Error Stale_epoch
  | () when epoch = state.current.epoch -> Ok (state, [])
  | () ->
    let (cancelled, effects) = transform_workers cancel_start state in
    let current = { cancelled.current with epoch } in
    Ok ({ cancelled with current }, effects)

let start (state : t) ~epoch ~pod ~incarnation =
  let* () = check_command state ~epoch ~pod ~incarnation in
  match () with
  | () when not (available state) -> Error Node_unavailable
  | () when List.exists (fun (w : worker) -> w.pod = pod) state.current.workers ->
    Error Duplicate_pod
  | () when state.last_ticket = Int.max_int -> Error Counter_exhausted
  | () ->
    let ticket = state.last_ticket + 1 in
    let worker = { pod; ticket; incarnation; phase = Starting } in
    let workers =
      List.sort (fun (a : worker) (b : worker) -> Int.compare a.pod b.pod)
        (worker :: state.current.workers) in
    let next = with_workers state workers in
    Ok ({ next with last_ticket = ticket }, [ Spawn worker ])

let stop (state : t) ~epoch ~pod ~incarnation =
  let* () = check_command state ~epoch ~pod ~incarnation in
  Option.fold ~none:(Ok (state, []))
    ~some:(fun w ->
      let (stopped, effects) = stop_worker w in
      Ok (replace_worker state stopped, effects))
    (List.find_opt (fun (w : worker) -> w.pod = pod) state.current.workers)

let lock_worker (state : t) (w : worker) granted =
  match w.phase with
  | Stopping -> Ok (state, [])
  | Running ->
    if granted then Ok (state, [])
    else
      let (stopped, effects) = stop_worker w in
      Ok (replace_worker state stopped, effects)
  | Starting ->
    if granted && available state && w.incarnation = state.current.incarnation
    then
      let running = { w with phase = Running } in
      Ok (replace_worker state running, [ Publish_place running; Begin_work running ])
    else
      let (stopped, effects) = stop_worker w in
      Ok (replace_worker state stopped, effects)

let pod_lock (state : t) ~ticket ~granted =
  Option.fold ~none:(Error Unknown_worker)
    ~some:(fun w -> lock_worker state w granted)
    (List.find_opt (fun (w : worker) -> w.ticket = ticket) state.current.workers)

let worker_exited (state : t) ticket =
  Option.fold ~none:(Error Unknown_worker)
    ~some:(fun (w : worker) ->
      let workers =
        List.filter (fun (candidate : worker) -> candidate.ticket <> ticket)
          state.current.workers in
      let effects =
        match w.phase with
        | Starting -> []
        | Running -> [ Release_place w ]
        | Stopping -> [] in
      Ok (with_workers state workers, effects))
    (List.find_opt (fun (w : worker) -> w.ticket = ticket) state.current.workers)

let step (state : t) (event : event) : (t * action list, error) result =
  match event with
  | Node_acquired incarnation -> acquire_node state incarnation
  | Node_lost incarnation ->
    let* () = check_incarnation state incarnation in
    freeze state
  | Observe_epoch epoch -> observe_epoch state epoch
  | Start { epoch; pod; incarnation } -> start state ~epoch ~pod ~incarnation
  | Stop { epoch; pod; incarnation } -> stop state ~epoch ~pod ~incarnation
  | Pod_lock { ticket; granted } -> pod_lock state ~ticket ~granted
  | Worker_exited ticket -> worker_exited state ticket
  | Freeze -> freeze state
  | Resume -> resume state
