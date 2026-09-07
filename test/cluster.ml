(* Native planner oracles.  No browser timing claim follows from these. *)
module C = Kite_runtime.Cluster

let node ?(incarnation = 1) ?(lock_held = true) ?(heartbeat = 10)
    ?(phase = C.Active) node_id : C.node =
  { node_id; incarnation; lock_held; heartbeat; phase }

let placement ?(incarnation = 1) pod owner : C.placement =
  { pod; owner; incarnation }

let snapshot ?(now = 10) ?(epoch = 1) ?(nodes = [])
    ?(placements = []) ?(pod_locks = []) () : C.snapshot =
  { now; epoch; nodes; placements; pod_locks }

let plan ?(epoch = 1) ?(desired = 1) s =
  Result.bind (C.config ~timeout:3 ~max_pods:8)
    (fun config -> C.reconcile config ~epoch ~desired s)

let is_ok f r = Result.fold ~ok:f ~error:(fun _error -> false) r
let fails e r = Result.fold ~ok:(fun _value -> false)
    ~error:(fun actual -> actual = e) r

let invalid s () = Result.fold ~ok:(fun _plan -> false)
    ~error:(fun e -> match e with
      | C.Invalid_snapshot _reason -> true
      | C.Invalid_config | C.Invalid_desired | C.Stale_epoch _ -> false)
    (plan s)

let commands expected r = is_ok (fun p -> C.commands p = expected) r
let start n owner = C.Start (placement n owner)
let stop n owner = C.Stop (placement n owner)

let balanced () = commands
    [start 0 "a"; start 1 "b"; start 2 "c"; start 3 "a"]
    (plan ~desired:4 (snapshot ~nodes:[node "c"; node "b"; node "a"] ()))

let retained_load () = commands [start 2 "b"; start 3 "b"]
    (plan ~desired:4 (snapshot ~nodes:[node "b"; node "a"]
       ~placements:[placement 1 "a"; placement 0 "a"]
       ~pod_locks:[0; 1] ()))

let release_before_replace () =
  let pending = snapshot ~nodes:[node "b"]
      ~placements:[placement 0 "a"] ~pod_locks:[0] () in
  commands [stop 0 "a"] (plan pending)
  && commands [] (plan {pending with placements = []})
  && commands [stop 0 "a"] (plan {pending with pod_locks = []})
  && commands [start 0 "b"] (plan {pending with placements = []; pod_locks = []})

let freeze_resume () =
  let frozen = snapshot ~nodes:[node ~phase:C.Frozen "a"; node "b"]
      ~placements:[placement 0 "a"] ~pod_locks:[0] () in
  commands [stop 0 "a"] (plan frozen)
  && commands [stop 0 "a"]
    (plan {frozen with nodes = [node ~incarnation:2 "a"; node "b"]})
  && commands [C.Start (placement ~incarnation:2 0 "a")]
    (plan {frozen with nodes = [node ~incarnation:2 "a"; node "b"];
                      placements = []; pod_locks = []})

let epoch_fence () =
  is_ok (fun p -> C.epoch p = 1
    && is_ok (fun cs -> cs = [start 0 "a"]) (C.authorize ~current_epoch:1 p)
    && fails (C.Stale_epoch {expected = 1; actual = 2})
         (C.authorize ~current_epoch:2 p)
    && fails (C.Stale_epoch {expected = 1; actual = 0})
         (C.authorize ~current_epoch:0 p))
    (plan (snapshot ~nodes:[node "a"] ()))

let rec insert x xs =
  (x :: xs) :: (match xs with
    | [] -> []
    | y :: ys -> List.map (fun zs -> y :: zs) (insert x ys))

let rec permutations xs = match xs with
  | [] -> [[]]
  | x :: rest -> List.concat_map (insert x) (permutations rest)

let permutation_invariance () =
  let nodes = [node "c"; node "a"; node "b"] in
  let placements = [placement 0 "a"; placement 2 "c"; placement 7 "b"] in
  let expected = plan ~desired:6 (snapshot ~nodes ~placements ()) in
  is_ok (fun p -> List.for_all (fun ns ->
    List.for_all (fun ps -> commands (C.commands p)
      (plan ~desired:6 (snapshot ~nodes:ns ~placements:ps ())))
      (permutations placements)) (permutations nodes)) expected

let plan_invariants () =
  let nodes = [node "a"; node "b"; node "c"] in
  List.for_all (fun desired -> List.for_all (fun reserved ->
    let s = snapshot ~nodes ~pod_locks:reserved () in
    is_ok (fun p ->
      let starts = List.filter_map (fun command -> match command with
        | C.Start target -> Some target
        | C.Stop _target -> None) (C.commands p) in
      let pods = List.map (fun (p : C.placement) -> p.pod) starts in
      let loads = List.map (fun (n : C.node) ->
        List.length (List.filter (fun (p : C.placement) ->
          String.equal p.owner n.node_id) starts)) nodes in
      List.length pods = List.length (List.sort_uniq Int.compare pods)
      && List.length pods = desired - List.length
           (List.filter (fun pod -> pod < desired) reserved)
      && List.for_all (fun pod -> pod >= 0 && pod < desired
           && not (List.mem pod reserved)) pods
      && List.for_all (fun a -> List.for_all (fun b -> abs (a - b) <= 1) loads) loads)
      (plan ~desired s)) [ []; [0]; [1; 3]; [0; 1; 2; 3; 4; 5; 6; 7] ])
    (List.init 9 Fun.id)

let cases =
  [ "least-loaded", balanced;
    "retained-load", retained_load;
    "release-before-replace", release_before_replace;
    "freeze-resume", freeze_resume;
    "epoch-fence", epoch_fence;
    "snapshot-permutations", permutation_invariance;
    "placement-invariants", plan_invariants;
    "no-nodes", (fun () -> commands [] (plan (snapshot ())));
    "healthy-placement-kept", (fun () -> commands []
      (plan (snapshot ~nodes:[node "a"] ~placements:[placement 0 "a"] ())));
    "scale-down-order", (fun () -> commands [stop 2 "b"; stop 7 "a"]
      (plan ~desired:1 (snapshot ~nodes:[node "a"; node "b"]
        ~placements:[placement 7 "a"; placement 0 "a"; placement 2 "b"] ())));
    "stale-lock-holder", (fun () -> commands [stop 0 "a"; start 1 "b"]
      (plan ~desired:2 (snapshot ~nodes:[node ~heartbeat:7 "a"; node "b"]
        ~placements:[placement 0 "a"] ~pod_locks:[0] ())));
    "heartbeat-boundary-live", (fun () -> commands [start 0 "a"]
      (plan (snapshot ~nodes:[node ~heartbeat:8 "a"] ())));
    "heartbeat-boundary-expired", (fun () -> commands []
      (plan (snapshot ~nodes:[node ~heartbeat:7 "a"] ())));
    "lock-required", (fun () -> commands []
      (plan (snapshot ~nodes:[node ~lock_held:false "a"] ())));
    "tick-overflow-safe", (fun () -> commands [start 0 "a"]
      (plan (snapshot ~now:max_int ~nodes:[node ~heartbeat:(max_int - 2) "a"] ())));
    "stale-leader", (fun () -> fails (C.Stale_epoch {expected = 1; actual = 2})
      (plan (snapshot ~epoch:2 ())));
    "future-leader", (fun () -> fails (C.Stale_epoch {expected = 2; actual = 1})
      (plan ~epoch:2 (snapshot ())));
    "negative-desired", (fun () -> fails C.Invalid_desired (plan ~desired:(-1) (snapshot ())));
    "desired-budget", (fun () -> fails C.Invalid_desired (plan ~desired:9 (snapshot ())));
    "invalid-timeout", (fun () -> fails C.Invalid_config (C.config ~timeout:0 ~max_pods:8));
    "invalid-pod-limit", (fun () -> fails C.Invalid_config (C.config ~timeout:3 ~max_pods:0));
    "duplicate-nodes", invalid (snapshot ~nodes:[node "a"; node "a"] ());
    "duplicate-placement", invalid (snapshot ~placements:[placement 0 "a"; placement 0 "b"] ());
    "duplicate-pod-lock", invalid (snapshot ~pod_locks:[0; 0] ());
    "negative-pod-lock", invalid (snapshot ~pod_locks:[-1] ());
    "negative-placement", invalid (snapshot ~placements:[placement (-1) "a"] ());
    "invalid-owner", invalid (snapshot ~placements:[placement 0 "a:b"] ());
    "invalid-node", invalid (snapshot ~nodes:[node "a b"] ());
    "invalid-incarnation", invalid (snapshot ~nodes:[node ~incarnation:0 "a"] ());
    "future-heartbeat", invalid (snapshot ~nodes:[node ~heartbeat:11 "a"] ());
    "negative-heartbeat", invalid (snapshot ~nodes:[node ~heartbeat:(-1) "a"] ());
    "negative-tick", invalid (snapshot ~now:(-1) ());
    "invalid-snapshot-epoch", invalid (snapshot ~epoch:0 ()) ]

let () = Runtime_suite.run "cluster" cases
