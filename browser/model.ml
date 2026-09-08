(* Pure browser boundary. State handles close over the native model; they
   preserve ticket history without exposing or reconstructing its internals. *)
open Js_of_ocaml

let () = Durable_model.install ()

module K = Kite_runtime.Kubelet
module C = Kite_runtime.Cluster
module M = Kite_runtime.Manifest
module T = Kite_runtime.Taint
module J = Js.Unsafe

let ( let* ) = Result.bind
let text value = J.inject (Js.string value)
let boolean value = J.inject (Js.bool value)
let integer value = J.inject value
let kind value = Js.to_string (Js.typeof value)
let invalid label = Error ("invalid_" ^ label)

let read_string label value =
  if String.equal (kind value) "string" then
    Ok (Js.to_string (J.coerce value))
  else invalid label

let read_int label value =
  if not (String.equal (kind value) "number") then invalid label
  else
    let number = Js.to_float (J.coerce value) in
    if Float.is_finite number && Float.equal number (Float.trunc number)
       && number >= -2147483648. && number <= 2147483647.
    then Ok (int_of_float number)
    else invalid label

let read_bool label value =
  if String.equal (kind value) "boolean" then
    Ok (Js.to_bool (J.coerce value))
  else invalid label

let is_array value =
  Js.to_bool (J.meth_call (J.get J.global "Array") "isArray" [| value |])

let read_object label value =
  if String.equal (kind value) "object"
     && not (J.strict_equals value Js.null) && not (is_array value)
  then Ok value
  else invalid label

let field parser value name = parser name (J.get value name)

let traverse parser values =
  Result.map List.rev
    (List.fold_left (fun acc value ->
       let* reversed = acc in
       let* parsed = parser value in
       Ok (parsed :: reversed)) (Ok []) values)

let read_list parser label value =
  if is_array value then
    traverse parser (Array.to_list (Js.to_array (J.coerce value)))
  else invalid label

let js_list render values =
  J.inject (Js.array (Array.of_list (List.map render values)))

let kubelet_error = function
  | K.Invalid_node -> "invalid_node"
  | K.Invalid_incarnation -> "invalid_incarnation"
  | K.Invalid_pod -> "invalid_pod"
  | K.Invalid_epoch -> "invalid_epoch"
  | K.Stale_epoch -> "stale_epoch"
  | K.Stale_incarnation -> "stale_incarnation"
  | K.Node_unavailable -> "node_unavailable"
  | K.Duplicate_pod -> "duplicate_pod"
  | K.Unknown_worker -> "unknown_worker"
  | K.Counter_exhausted -> "counter_exhausted"

let cluster_error = function
  | C.Invalid_config -> "invalid_config"
  | C.Invalid_desired -> "invalid_desired"
  | C.Invalid_snapshot detail -> "invalid_snapshot: " ^ detail
  | C.Stale_epoch { expected; actual } ->
    "stale_epoch: expected " ^ string_of_int expected
    ^ ", actual " ^ string_of_int actual

let worker_phase = function
  | K.Starting -> "starting"
  | K.Running -> "running"
  | K.Stopping -> "stopping"

let mode = function K.Ready -> "ready" | K.Frozen -> "frozen"

let worker (value : K.worker) : J.any =
  J.obj [| "pod", integer value.pod;
           "ticket", integer value.ticket;
           "incarnation", integer value.incarnation;
           "phase", text (worker_phase value.phase) |]

let view (state : K.t) : J.any =
  let value = K.view state in
  J.obj [| "nodeId", text value.node_id;
           "incarnation", integer value.incarnation;
           "epoch", integer value.epoch;
           "mode", text (mode value.mode);
           "nodeLock", boolean value.node_lock;
           "workers", js_list worker value.workers |]

let node_action name incarnation : J.any =
  J.obj [| "kind", text name; "incarnation", integer incarnation |]

let worker_action name value : J.any =
  J.obj [| "kind", text name; "worker", worker value |]

let action = function
  | K.Acquire_node incarnation -> node_action "acquire_node" incarnation
  | K.Release_node incarnation -> node_action "release_node" incarnation
  | K.Spawn value -> worker_action "spawn" value
  | K.Terminate value -> worker_action "terminate" value
  | K.Publish_place value -> worker_action "publish_place" value
  | K.Release_place value -> worker_action "release_place" value
  | K.Begin_work value -> worker_action "begin_work" value

let read_command constructor value =
  let* epoch = field read_int value "epoch" in
  let* pod = field read_int value "pod" in
  let* incarnation = field read_int value "incarnation" in
  Ok (constructor epoch pod incarnation)

let read_event value =
  let* value = read_object "event" value in
  let* name = field read_string value "kind" in
  match name with
  | "node_acquired" ->
    Result.map (fun incarnation -> K.Node_acquired incarnation)
      (field read_int value "incarnation")
  | "node_lost" ->
    Result.map (fun incarnation -> K.Node_lost incarnation)
      (field read_int value "incarnation")
  | "observe_epoch" ->
    Result.map (fun epoch -> K.Observe_epoch epoch)
      (field read_int value "epoch")
  | "start" ->
    read_command (fun epoch pod incarnation -> K.Start {epoch; pod; incarnation}) value
  | "stop" ->
    read_command (fun epoch pod incarnation -> K.Stop {epoch; pod; incarnation}) value
  | "pod_lock" ->
    let* ticket = field read_int value "ticket" in
    let* granted = field read_bool value "granted" in
    Ok (K.Pod_lock {ticket; granted})
  | "worker_exited" ->
    Result.map (fun ticket -> K.Worker_exited ticket)
      (field read_int value "ticket")
  | "freeze" -> Ok K.Freeze
  | "resume" -> Ok K.Resume
  | unknown -> invalid ("event_kind: " ^ unknown)

let failure error : J.any =
  J.obj [| "ok", boolean false; "error", text error |]

let rec response state actions : J.any =
  let handle = Js.Unsafe.callback (fun operation payload ->
    Result.fold ~error:failure
      ~ok:(fun name ->
        match name with
        | "view" -> view state
        | "step" ->
          let outcome =
            let* event = read_event payload in
            Result.map_error kubelet_error (K.step state event) in
          Result.fold ~error:failure
            ~ok:(fun (next, effects) -> response next effects) outcome
        | unknown -> failure ("invalid_operation: " ^ unknown))
      (read_string "operation" operation)) in
  J.obj [| "ok", boolean true;
           "state", J.inject handle;
           "actions", js_list action actions;
           "view", view state |]

let create node incarnation =
  let outcome =
    let* node_id = read_string "nodeId" node in
    let* incarnation = read_int "incarnation" incarnation in
    Result.map_error kubelet_error (K.create ~node_id ~incarnation) in
  Result.fold ~error:failure ~ok:(fun state -> response state []) outcome

let invoke state operation payload : J.any =
  if String.equal (kind state) "function" then
    J.fun_call state [| text operation; payload |]
  else failure "invalid_state"

let read_node value =
  let* value = read_object "node" value in
  let* node_id = field read_string value "nodeId" in
  let* incarnation = field read_int value "incarnation" in
  let* lock_held = field read_bool value "lockHeld" in
  let* heartbeat = field read_int value "heartbeat" in
  let* name = field read_string value "phase" in
  let* phase =
    match name with
    | "active" -> Ok C.Active
    | "frozen" -> Ok C.Frozen
    | unknown -> invalid ("node_phase: " ^ unknown) in
  Ok { C.node_id; incarnation; lock_held; heartbeat; phase }

let read_placement value =
  let* value = read_object "placement" value in
  let* pod = field read_int value "pod" in
  let* owner = field read_string value "owner" in
  let* incarnation = field read_int value "incarnation" in
  Ok { C.pod; owner; incarnation }

let read_snapshot value =
  let* value = read_object "snapshot" value in
  let* now = field read_int value "now" in
  let* epoch = field read_int value "epoch" in
  let* nodes = field (read_list read_node) value "nodes" in
  let* placements = field (read_list read_placement) value "placements" in
  let* pod_locks = field (read_list (read_int "podLock")) value "podLocks" in
  Ok { C.now; epoch; nodes; placements; pod_locks }

let command name (value : C.placement) : J.any =
  J.obj [| "kind", text name;
           "pod", integer value.pod;
           "owner", text value.owner;
           "incarnation", integer value.incarnation |]

let render_command = function
  | C.Start placement -> command "start" placement
  | C.Stop placement -> command "stop" placement

let plan snapshot epoch desired timeout max_pods =
  let outcome =
    let* snapshot = read_snapshot snapshot in
    let* epoch = read_int "epoch" epoch in
    let* desired = read_int "desired" desired in
    let* timeout = read_int "timeout" timeout in
    let* max_pods = read_int "maxPods" max_pods in
    let* config = Result.map_error cluster_error (C.config ~timeout ~max_pods) in
    let* planned = Result.map_error cluster_error
        (C.reconcile config ~epoch ~desired snapshot) in
    Result.map_error cluster_error (C.authorize ~current_epoch:epoch planned) in
  Result.fold ~error:failure
    ~ok:(fun commands -> J.obj [| "ok", boolean true;
                                "commands", js_list render_command commands |]) outcome

let manifest_error = function
  | M.Invalid_name -> "invalid_manifest_name"
  | M.Invalid_bound -> "invalid_manifest_bound"
  | M.Invalid_replicas -> "invalid_manifest_replicas"
  | M.Not_a_workload -> "not_a_workload"
  | M.Admit_denied M.No_eligible_nodes -> "Admit_denied:no_eligible_nodes"
  | M.Scheduling_error _detail -> "invalid_admission_snapshot"

let read_workload value =
  let* value = read_object "manifest" value in
  let* kind = field read_string value "kind" in
  let* name = field read_string value "name" in
  let* replicas = field read_int value "replicas" in
  let* bound = field read_int value "bound" in
  let* tolerate_hidden = field read_bool value "tolerateHidden" in
  let construct = match kind with
    | "deployment" -> Ok M.deployment
    | "stateful_set" -> Ok M.stateful_set
    | unknown -> invalid ("workload_kind: " ^ unknown) in
  let* construct = construct in
  Result.map_error manifest_error (construct ~name ~replicas ~bound ~tolerate_hidden)

let read_observation value =
  let* value = read_object "observation" value in
  let* node_id = field read_string value "nodeId" in
  let* incarnation = field read_int value "incarnation" in
  let* visibility = field read_string value "visibility" in
  let* visibility = match visibility with
    | "visible" -> Ok T.Visible
    | "hidden" -> Ok T.Hidden
    | unknown -> invalid ("visibility: " ^ unknown) in
  Ok { T.node_id; incarnation; visibility }

let manifest_plan manifest snapshot observations =
  let outcome =
    let* manifest = read_workload manifest in
    let* snapshot = read_snapshot snapshot in
    let* observations = read_list read_observation "observations" observations in
    let* config = Result.map_error cluster_error (C.config ~timeout:5 ~max_pods:64) in
    let* plan = Result.map_error manifest_error
        (M.admit config ~epoch:snapshot.epoch ~observations snapshot manifest) in
    Result.map_error cluster_error (C.authorize ~current_epoch:snapshot.epoch plan) in
  Result.fold ~error:failure
    ~ok:(fun commands -> J.obj [| "ok", boolean true;
                                "commands", js_list render_command commands |]) outcome

let () =
  Js.export "KiteModel"
    (J.obj [| "create", J.inject (Js.Unsafe.callback create);
              "step", J.inject (Js.Unsafe.callback (fun state event ->
                invoke state "step" event));
              "view", J.inject (Js.Unsafe.callback (fun state ->
                invoke state "view" (J.inject Js.undefined)));
              "plan", J.inject (Js.Unsafe.callback plan);
              "manifestPlan", J.inject (Js.Unsafe.callback manifest_plan);
              "validateWorkload", J.inject (Js.Unsafe.callback (fun value ->
                Result.fold ~error:failure
                  ~ok:(fun _manifest -> J.obj [| "ok", boolean true |])
                  (read_workload value))) |])
