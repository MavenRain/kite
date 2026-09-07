type workload = { name : string; replicas : int; bound : int; tolerate_hidden : bool }
type binding = { name : string; target : string }
type t = Deployment of workload | Stateful_set of workload
  | Named_service of binding | Freeze_drain of binding
type denial = No_eligible_nodes
type error = Invalid_name | Invalid_bound | Invalid_replicas | Not_a_workload
  | Admit_denied of denial | Scheduling_error of Taint.error
let ( let* ) = Result.bind
let valid_name name =
  let valid ch = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
    || (ch >= '0' && ch <= '9') || ch = '_' || ch = '-' in
  String.length name > 0 && String.length name <= 64 && String.for_all valid name
let workload ~name ~replicas ~bound ~tolerate_hidden =
  match () with
  | () when not (valid_name name) -> Error Invalid_name
  | () when bound < 0 || bound > 64 -> Error Invalid_bound
  | () when replicas < 0 || replicas > bound -> Error Invalid_replicas
  | () -> Ok { name; replicas; bound; tolerate_hidden }
let deployment ~name ~replicas ~bound ~tolerate_hidden =
  Result.map (fun value -> Deployment value) (workload ~name ~replicas ~bound ~tolerate_hidden)
let stateful_set ~name ~replicas ~bound ~tolerate_hidden =
  Result.map (fun value -> Stateful_set value) (workload ~name ~replicas ~bound ~tolerate_hidden)
let binding ~name ~target =
  if valid_name name && valid_name target then Ok { name; target } else Error Invalid_name
let service ~name ~target = Result.map (fun value -> Named_service value) (binding ~name ~target)
let drain ~name ~target = Result.map (fun value -> Freeze_drain value) (binding ~name ~target)
let name = function
  | Deployment value | Stateful_set value -> value.name
  | Named_service value | Freeze_drain value -> value.name
let replicas = function
  | Deployment value | Stateful_set value -> Some value.replicas
  | Named_service _ | Freeze_drain _ -> None
let ordinals count = List.init count (fun ordinal -> ordinal)
let pod_names = function
  | Deployment value | Stateful_set value ->
    List.map (fun ordinal -> value.name ^ ":" ^ string_of_int ordinal) (ordinals value.replicas)
  | Named_service _ | Freeze_drain _ -> []
let volume_keys = function
  | Stateful_set value -> List.map (fun ordinal -> value.name, ordinal) (ordinals value.replicas)
  | Deployment _ | Named_service _ | Freeze_drain _ -> []
let admit_workload config ~epoch ~observations snapshot workload =
  let reconcile desired observed = Result.map_error (fun error -> Scheduling_error error)
      (Taint.reconcile config ~epoch ~desired ~observations
        ~tolerate_hidden:workload.tolerate_hidden observed) in
  let* plan = reconcile workload.replicas snapshot in
  let stopped = List.filter_map (function
      | Cluster.Stop placement -> Some placement.Cluster.pod
      | Cluster.Start _ -> None) (Cluster.commands plan) in
  let retained = List.length (List.filter (fun placement ->
      placement.Cluster.pod < workload.replicas && not (List.mem placement.Cluster.pod stopped))
      snapshot.Cluster.placements) in
  if workload.replicas <= retained then Ok plan else
    let empty = { snapshot with Cluster.placements = []; pod_locks = [] } in
    let* possible = reconcile 1 empty in
    if List.exists (function Cluster.Start _ -> true | Cluster.Stop _ -> false)
         (Cluster.commands possible)
    then Ok plan else Error (Admit_denied No_eligible_nodes)
let admit config ~epoch ~observations snapshot = function
  | Deployment workload | Stateful_set workload ->
    admit_workload config ~epoch ~observations snapshot workload
  | Named_service _ | Freeze_drain _ -> Error Not_a_workload
