(* Pure placement planning. Snapshot validation precedes all decisions. *)

type phase = Active | Frozen

type node = {
  node_id : string;
  incarnation : int;
  lock_held : bool;
  heartbeat : int;
  phase : phase;
}

type placement = { pod : int; owner : string; incarnation : int }

type snapshot = {
  now : int;
  epoch : int;
  nodes : node list;
  placements : placement list;
  pod_locks : int list;
}

type command = Start of placement | Stop of placement
type config = { timeout : int; max_pods : int }
type plan = { plan_epoch : int; planned : command list }

type error =
  | Invalid_config
  | Invalid_desired
  | Invalid_snapshot of string
  | Stale_epoch of { expected : int; actual : int }

module Names = Map.Make (String)
module Pods = Map.Make (Int)
module Locks = Set.Make (Int)

type candidate = { host : node; load : int }

module Candidates = Set.Make (struct
  type t = candidate

  let compare (a : t) (b : t) : int =
    let by_load = Int.compare a.load b.load in
    if by_load = 0 then String.compare a.host.node_id b.host.node_id
    else by_load
end)

let config ~timeout ~max_pods : (config, error) result =
  if timeout <= 0 || max_pods <= 0 then Error Invalid_config
  else Ok { timeout; max_pods }

let valid_name (name : string) : bool =
  let valid_char c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9') || c = '_' || c = '-' in
  String.length name > 0 && String.for_all valid_char name

let invalid message = Error (Invalid_snapshot message)

let validate_nodes now (nodes : node list) : (node Names.t, error) result =
  List.fold_left
    (fun acc (host : node) ->
      Result.bind acc (fun known ->
        match () with
        | () when not (valid_name host.node_id) -> invalid "invalid node identifier"
        | () when host.incarnation <= 0 -> invalid "nonpositive node incarnation"
        | () when host.heartbeat < 0 || host.heartbeat > now ->
          invalid "heartbeat outside snapshot time"
        | () when Names.mem host.node_id known -> invalid "duplicate node identifier"
        | () -> Ok (Names.add host.node_id host known)))
    (Ok Names.empty) nodes

let validate_placements (placements : placement list)
    : (placement Pods.t, error) result =
  List.fold_left
    (fun acc (placement : placement) ->
      Result.bind acc (fun known ->
        match () with
        | () when placement.pod < 0 -> invalid "negative placement pod"
        | () when not (valid_name placement.owner) -> invalid "invalid placement owner"
        | () when placement.incarnation <= 0 ->
          invalid "nonpositive placement incarnation"
        | () when Pods.mem placement.pod known -> invalid "duplicate placement pod"
        | () -> Ok (Pods.add placement.pod placement known)))
    (Ok Pods.empty) placements

let validate_locks (locks : int list) : (Locks.t, error) result =
  List.fold_left
    (fun acc pod ->
      Result.bind acc (fun known ->
        match () with
        | () when pod < 0 -> invalid "negative pod lock"
        | () when Locks.mem pod known -> invalid "duplicate pod lock"
        | () -> Ok (Locks.add pod known)))
    (Ok Locks.empty) locks

let healthy (cfg : config) now (host : node) : bool =
  let active =
    match host.phase with
    | Active -> true
    | Frozen -> false in
  active && host.lock_held && now - host.heartbeat < cfg.timeout

let retained desired (eligible : node Names.t) (placement : placement) : bool =
  placement.pod < desired
  && Option.fold ~none:false
       ~some:(fun (host : node) -> host.incarnation = placement.incarnation)
       (Names.find_opt placement.owner eligible)

let load_for name loads : int =
  Option.fold ~none:0 ~some:(fun count -> count) (Names.find_opt name loads)

let candidates (eligible : node Names.t) (kept : placement Pods.t)
    : Candidates.t =
  let loads =
    Pods.fold
      (fun _pod (placement : placement) counts ->
        Names.add placement.owner (load_for placement.owner counts + 1) counts)
      kept Names.empty in
  Names.fold
    (fun name host queue ->
      Candidates.add { host; load = load_for name loads } queue)
    eligible Candidates.empty

let starts desired reserved initial : command list =
  let rec loop pod queue reversed =
    match () with
    | () when pod >= desired || Candidates.is_empty queue -> List.rev reversed
    | () when Locks.mem pod reserved -> loop (pod + 1) queue reversed
    | () ->
      (Option.fold
         ~none:(fun () -> List.rev reversed)
         ~some:(fun candidate () ->
           let placement = {
             pod;
             owner = candidate.host.node_id;
             incarnation = candidate.host.incarnation;
           } in
           let remaining = Candidates.remove candidate queue in
           let next =
             Candidates.add { candidate with load = candidate.load + 1 }
               remaining in
           loop (pod + 1) next (Start placement :: reversed))
         (Candidates.min_elt_opt queue)) () in
  loop 0 initial []

let plan_commands (cfg : config) desired (observed : snapshot)
    (nodes : node Names.t) (placements : placement Pods.t) locks
    : command list =
  let eligible = Names.filter (fun _name host -> healthy cfg observed.now host) nodes in
  let kept = Pods.filter (fun _pod placement -> retained desired eligible placement) placements in
  let stops_reversed =
    Pods.fold
      (fun pod placement acc ->
        if Pods.mem pod kept then acc else Stop placement :: acc)
      placements [] in
  let reserved =
    Pods.fold (fun pod _placement names -> Locks.add pod names) placements locks in
  List.rev_append stops_reversed (starts desired reserved (candidates eligible kept))

let reconcile (cfg : config) ~epoch ~desired (observed : snapshot)
    : (plan, error) result =
  match () with
  | () when desired < 0 || desired > cfg.max_pods -> Error Invalid_desired
  | () when observed.now < 0 -> invalid "negative snapshot time"
  | () when observed.epoch <= 0 -> invalid "nonpositive snapshot epoch"
  | () when epoch <= 0 || epoch <> observed.epoch ->
    Error (Stale_epoch { expected = epoch; actual = observed.epoch })
  | () ->
    Result.bind (validate_nodes observed.now observed.nodes) (fun nodes ->
      Result.bind (validate_placements observed.placements) (fun placements ->
        Result.bind (validate_locks observed.pod_locks) (fun locks ->
          Ok {
            plan_epoch = epoch;
            planned = plan_commands cfg desired observed nodes placements locks;
          })))

let commands (plan : plan) : command list = plan.planned

let epoch (plan : plan) : int = plan.plan_epoch

let authorize ~current_epoch (plan : plan) : (command list, error) result =
  if current_epoch <= 0 || current_epoch <> plan.plan_epoch then
    Error (Stale_epoch { expected = plan.plan_epoch; actual = current_epoch })
  else Ok plan.planned
