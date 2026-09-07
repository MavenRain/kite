module M = Kite_runtime.Manifest
module C = Kite_runtime.Cluster
module T = Kite_runtime.Taint
module V = Kite_runtime.Volume
let ( let* ) = Result.bind
let succeeds predicate = Result.fold ~error:(fun _error -> false) ~ok:predicate
let fails expected = Result.fold ~error:(( = ) expected) ~ok:(fun _value -> false)
let deployment ?(replicas = 1) ?(bound = 4) ?(tolerate_hidden = false) name =
  M.deployment ~name ~replicas ~bound ~tolerate_hidden
let stateful ?(replicas = 2) name =
  M.stateful_set ~name ~replicas ~bound:4 ~tolerate_hidden:false
let node ?(phase = C.Active) ?(heartbeat = 10) node_id : C.node =
  {node_id; incarnation = 1; lock_held = true; heartbeat; phase}
let observation ?(visibility = T.Visible) node_id : T.observation =
  {node_id; incarnation = 1; visibility}
let placement pod owner : C.placement = {pod; owner; incarnation = 1}
let snapshot ?(epoch = 1) ?(nodes = []) ?(placements = []) ?(pod_locks = []) ()
    : C.snapshot = {now = 10; epoch; nodes; placements; pod_locks}
let admit ?(observations = []) observed description =
  let* manifest = description in
  let* config = Result.map_error (fun error -> M.Scheduling_error (T.Cluster_error error))
      (C.config ~timeout:3 ~max_pods:8) in
  M.admit config ~epoch:1 ~observations observed manifest
let commands expected = succeeds (fun plan -> C.commands plan = expected)
let denied result = fails (M.Admit_denied M.No_eligible_nodes) result
let naming () = succeeds (fun (large, small, other) ->
    M.pod_names large = ["cache:0"; "cache:1"]
    && M.pod_names small = ["cache:0"]
    && M.volume_keys large = ["cache", 0; "cache", 1]
    && M.volume_keys small = ["cache", 0]
    && M.volume_keys other = ["other", 0; "other", 1]
    && List.for_all (fun (namespace, ordinal) ->
      succeeds (fun key -> String.length (V.key_text key) > 0)
        (V.key ~namespace ~ordinal)) (M.volume_keys large))
    (let* large = stateful "cache" in
     let* small = stateful ~replicas:1 "cache" in
     let* other = stateful "other" in Ok (large, small, other))
let healthy_admission () =
  commands [C.Start (placement 0 "a"); C.Start (placement 1 "a")]
    (admit ~observations:[observation "a"] (snapshot ~nodes:[node "a"] ())
      (deployment ~replicas:2 "web"))
let hidden_admission () =
  let observed = snapshot ~nodes:[node "a"] () in
  let observations = [observation ~visibility:T.Hidden "a"] in
  denied (admit ~observations observed (deployment "web"))
  && commands [C.Start (placement 0 "a")]
    (admit ~observations observed (deployment ~tolerate_hidden:true "web"))
let retained_hidden () =
  let observed = snapshot ~nodes:[node "a"] ~placements:[placement 0 "a"] ~pod_locks:[0] () in
  let observations = [observation ~visibility:T.Hidden "a"] in
  commands [] (admit ~observations observed (deployment "web"))
  && denied (admit ~observations observed (deployment ~replicas:2 "web"))
let unhealthy_admission () =
  List.for_all (fun host -> denied
    (admit ~observations:[observation "a"] (snapshot ~nodes:[host]
      ~placements:[placement 0 "a"] ~pod_locks:[0] ()) (deployment "web")))
    [node ~phase:C.Frozen "a"; node ~heartbeat:7 "a"]
let reservation_wait () =
  commands [C.Stop (placement 0 "gone")]
    (admit ~observations:[observation "a"]
      (snapshot ~nodes:[node "a"] ~placements:[placement 0 "gone"] ~pod_locks:[0] ())
      (stateful ~replicas:1 "cache"))
let scale_to_zero () =
  commands [C.Stop (placement 0 "gone")]
    (admit (snapshot ~placements:[placement 0 "gone"] ~pod_locks:[0] ())
      (deployment ~replicas:0 "web"))
let descriptions () =
  succeeds (fun (service, drain) ->
    M.name service = "api" && M.name drain = "shutdown"
    && M.replicas service = None && M.replicas drain = None
    && M.pod_names service = [] && M.volume_keys drain = [])
    (let* service = M.service ~name:"api" ~target:"web" in
     let* drain = M.drain ~name:"shutdown" ~target:"web" in Ok (service, drain))
let cases = [
  "valid-replica-bound", (fun () ->
    succeeds (fun value -> M.replicas value = Some 2) (deployment ~replicas:2 "web")
    && succeeds (fun value -> M.replicas value = Some 1) (stateful ~replicas:1 "cache"));
  "invalid-names", (fun () -> List.for_all (fun name -> fails M.Invalid_name (deployment name))
    [""; "bad:name"; String.make 65 'a']);
  "invalid-bounds", (fun () -> List.for_all (fun bound -> fails M.Invalid_bound
    (deployment ~bound "web")) [-1; 65]);
  "invalid-replica-counts", (fun () -> List.for_all (fun replicas -> fails M.Invalid_replicas
    (deployment ~replicas "web")) [-1; 5]);
  "zero-bound-zero-replicas", (fun () -> succeeds (fun value -> M.pod_names value = [])
    (deployment ~bound:0 ~replicas:0 "web"));
  "stable-stateful-identities", naming;
  "deployment-has-no-volume", (fun () -> succeeds (fun value ->
    M.pod_names value = ["web:0"] && M.volume_keys value = []) (deployment "web"));
  "live-node-admission", healthy_admission;
  "no-live-node-denied", (fun () -> denied (admit (snapshot ()) (deployment "web")));
  "missing-visibility-denied", (fun () -> denied (admit (snapshot ~nodes:[node "a"] ())
    (deployment ~tolerate_hidden:true "web")));
  "hidden-tolerance-admission", hidden_admission;
  "retained-hidden-replicas", retained_hidden;
  "unhealthy-retained-placement-denied", unhealthy_admission;
  "reservation-delays-replacement", reservation_wait;
  "scale-to-zero-without-nodes", scale_to_zero;
  "snapshot-epoch-refused", (fun () -> fails
    (M.Scheduling_error (T.Cluster_error (C.Stale_epoch {expected = 1; actual = 2})))
    (admit (snapshot ~epoch:2 ()) (deployment ~replicas:0 "web")));
  "observation-incarnation-refused", (fun () -> fails
    (M.Scheduling_error (T.Stale_incarnation {node_id = "a"; expected = 1; actual = 2}))
    (admit ~observations:[{T.node_id = "a"; incarnation = 2; visibility = T.Visible}]
      (snapshot ~nodes:[node "a"] ()) (deployment "web")));
  "service-and-drain-descriptions", descriptions;
  "service-and-drain-placement-refused", (fun () -> List.for_all
    (fun value -> fails M.Not_a_workload (admit (snapshot ()) value))
    [M.service ~name:"api" ~target:"web"; M.drain ~name:"shutdown" ~target:"web"]);
  "binding-target-validated", (fun () -> fails M.Invalid_name
    (M.service ~name:"api" ~target:"") && fails M.Invalid_name
    (M.drain ~name:"shutdown" ~target:"invalid:target"))
]
let () = Runtime_suite.run "manifest" cases
