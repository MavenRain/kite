(* Native visibility and placement integration. No browser observation claim. *)
module C = Kite_runtime.Cluster
module T = Kite_runtime.Taint

let node ?(incarnation = 1) ?(lock_held = true) ?(heartbeat = 10)
    ?(phase = C.Active) node_id : C.node =
  {node_id; incarnation; lock_held; heartbeat; phase}

let observation ?(incarnation = 1) ?(visibility = T.Visible) node_id
    : T.observation = {node_id; incarnation; visibility}

let placement ?(incarnation = 1) pod owner : C.placement =
  {pod; owner; incarnation}

let snapshot ?(epoch = 1) ?(nodes = []) ?(placements = [])
    ?(pod_locks = []) () : C.snapshot =
  {now = 10; epoch; nodes; placements; pod_locks}

let plan ?(epoch = 1) ?(desired = 1) ?(tolerate_hidden = false)
    ?(observations = []) observed =
  Result.bind
    (Result.map_error (fun error -> T.Cluster_error error)
      (C.config ~timeout:3 ~max_pods:8))
    (fun config -> T.reconcile config ~epoch ~desired ~observations
        ~tolerate_hidden observed)

let commands expected result = Result.fold
    ~error:(fun _error -> false)
    ~ok:(fun plan -> C.commands plan = expected) result

let fails expected result = Result.fold
    ~error:(fun actual -> actual = expected) ~ok:(fun _plan -> false) result

let start pod owner = C.Start (placement pod owner)
let stop pod owner = C.Stop (placement pod owner)

let hidden_new_starts () =
  let observed = snapshot ~nodes:[node "a"] () in
  let observations = [observation ~visibility:T.Hidden "a"] in
  commands [] (plan ~observations observed)
  && commands [start 0 "a"] (plan ~observations ~tolerate_hidden:true observed)

let hidden_retained () =
  let observed = snapshot ~nodes:[node "a"; node "b"]
      ~placements:[placement 0 "a"] ~pod_locks:[0] () in
  let observations = [observation ~visibility:T.Hidden "a"; observation "b"] in
  commands [start 1 "b"] (plan ~desired:2 ~observations observed)
  && commands [] (plan ~desired:1 ~observations observed)

let hidden_only_retained () =
  commands [] (plan ~desired:2
    ~observations:[observation ~visibility:T.Hidden "a"]
    (snapshot ~nodes:[node "a"] ~placements:[placement 0 "a"] ~pod_locks:[0] ()))

let missing_observations () =
  let observed = snapshot ~nodes:[node "a"; node "b"]
      ~placements:[placement 0 "a"] ~pod_locks:[0] () in
  commands [] (plan ~desired:2 observed)
  && commands [] (plan ~desired:2 ~tolerate_hidden:true observed)
  && commands [start 1 "b"]
    (plan ~desired:2 ~observations:[observation "b"] observed)

let health_is_independent () =
  let unhealthy = [node ~phase:C.Frozen "a";
                   node ~lock_held:false "a"; node ~heartbeat:7 "a"] in
  List.for_all (fun unhealthy_node ->
    List.for_all (fun visibility ->
      let observations = [observation ~visibility "a"; observation "b"] in
      let observed = snapshot ~nodes:[unhealthy_node; node "b"]
          ~placements:[placement 0 "a"] ~pod_locks:[0] () in
      commands [stop 0 "a"; start 1 "b"]
        (plan ~desired:2 ~observations ~tolerate_hidden:true observed))
      [T.Visible; T.Hidden]) unhealthy

let default_cluster_unchanged () =
  let observed = snapshot ~nodes:[node "a"] () in
  commands [] (plan observed)
  && Result.fold ~error:(fun _error -> false)
    ~ok:(fun config -> commands [start 0 "a"]
      (Result.map_error (fun error -> T.Cluster_error error)
        (C.reconcile config ~epoch:1 ~desired:1 observed)))
    (C.config ~timeout:3 ~max_pods:8)

let resumed_incarnation () =
  let fresh = snapshot ~nodes:[node ~incarnation:2 "a"] () in
  let stale = [observation "a"] in
  let expected = T.Stale_incarnation {node_id = "a"; expected = 2; actual = 1} in
  fails expected (plan ~observations:stale fresh)
  && fails expected (plan ~observations:stale ~tolerate_hidden:true fresh)
  && commands [] (plan ~observations:[observation ~incarnation:2 ~visibility:T.Hidden "a"] fresh)
  && commands [C.Start (placement ~incarnation:2 0 "a")]
    (plan ~observations:[observation ~incarnation:2 "a"] fresh)

let duplicate_observations () =
  let observed = snapshot ~nodes:[node "a"] () in
  List.for_all (fun observations ->
    fails (T.Duplicate_observation "a")
      (plan ~observations ~tolerate_hidden:true observed))
    [[observation "a"; observation "a"];
     [observation "a"; observation ~visibility:T.Hidden "a"];
     [observation ~visibility:T.Hidden "a"; observation "a"]]

let observation_order () =
  let observations = [observation "a"; observation ~visibility:T.Hidden "b";
                      observation "c"] in
  let observed = snapshot ~nodes:[node "c"; node "b"; node "a"] () in
  let expected = [start 0 "a"; start 1 "c"; start 2 "a"] in
  commands expected (plan ~desired:3 ~observations observed)
  && commands expected (plan ~desired:3 ~observations:(List.rev observations) observed)

let restricted_plan allowed observations =
  Result.bind
    (Result.map_error (fun error -> T.Cluster_error error)
      (C.config ~timeout:3 ~max_pods:8))
    (fun config -> Result.bind
      (Result.map_error (fun error -> T.Cluster_error error) (C.with_start_nodes config allowed))
      (fun restricted -> T.reconcile restricted ~epoch:1 ~desired:2 ~observations
        ~tolerate_hidden:false (snapshot ~nodes:[node "a"; node "b"; node "c"] ())))

let cases = [
  "visible-node-starts", (fun () -> commands [start 0 "a"]
    (plan ~observations:[observation "a"] (snapshot ~nodes:[node "a"] ())));
  "hidden-starts-require-tolerance", hidden_new_starts;
  "hidden-healthy-work-retained", hidden_retained;
  "hidden-only-existing-work-retained", hidden_only_retained;
  "missing-report-never-admits-even-with-tolerance", missing_observations;
  "tolerance-never-bypasses-node-health", health_is_independent;
  "default-cluster-policy-unchanged", default_cluster_unchanged;
  "resume-requires-current-incarnation-report", resumed_incarnation;
  "duplicate-reports-refuse-whole-plan", duplicate_observations;
  "observation-order-independent", observation_order;
  "restricted-config-positive-intersection", (fun () ->
    commands [start 0 "b"; start 1 "b"]
      (restricted_plan ["a"; "b"] [observation "b"; observation "c"]));
  "restricted-config-disjoint-intersection", (fun () ->
    commands [] (restricted_plan ["a"] [observation "b"; observation "c"]));
  "restricted-config-empty-remains-empty", (fun () ->
    commands [] (restricted_plan [] [observation "a"; observation "b"; observation "c"]));
  "restricted-config-invalid-name-refused", (fun () ->
    fails (T.Cluster_error C.Invalid_config) (restricted_plan ["bad:name"] [observation "a"]));
  "restricted-config-duplicate-name-refused", (fun () ->
    fails (T.Cluster_error C.Invalid_config) (restricted_plan ["a"; "a"] [observation "a"]));
  "unknown-report-refused", (fun () -> fails (T.Unknown_node "gone")
    (plan ~observations:[observation "gone"] (snapshot ~nodes:[node "a"] ())));
  "unknown-hidden-report-refused-even-with-tolerance", (fun () -> fails (T.Unknown_node "gone")
    (plan ~tolerate_hidden:true ~observations:[observation ~visibility:T.Hidden "gone"] (snapshot ())));
  "future-incarnation-refused", (fun () -> fails
    (T.Stale_incarnation {node_id = "a"; expected = 1; actual = 2})
    (plan ~observations:[observation ~incarnation:2 "a"] (snapshot ~nodes:[node "a"] ())));
  "nonpositive-incarnation-refused", (fun () -> fails
    (T.Invalid_incarnation {node_id = "a"; incarnation = 0})
    (plan ~observations:[observation ~incarnation:0 "a"] (snapshot ~nodes:[node "a"] ())));
  "invalid-report-name-refused", (fun () -> fails (T.Invalid_node_id "bad:name")
    (plan ~observations:[observation "bad:name"] (snapshot ())));
  "empty-report-name-refused", (fun () -> fails (T.Invalid_node_id "")
    (plan ~observations:[observation ""] (snapshot ())));
  "epoch-fence-preserved", (fun () -> fails
    (T.Cluster_error (C.Stale_epoch {expected = 1; actual = 2}))
    (plan (snapshot ~epoch:2 ())));
  "desired-budget-preserved", (fun () -> fails (T.Cluster_error C.Invalid_desired)
    (plan ~desired:9 (snapshot ())));
  "snapshot-validation-preserved", (fun () -> fails
    (T.Cluster_error (C.Invalid_snapshot "duplicate node identifier"))
    (plan (snapshot ~nodes:[node "a"; node "a"] ())));
  "pod-lock-reservation-preserved", (fun () -> commands []
    (plan ~observations:[observation "a"]
      (snapshot ~nodes:[node "a"] ~pod_locks:[0] ())))
]

let () = Runtime_suite.run "taint" cases
