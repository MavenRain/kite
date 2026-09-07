(* Event traces target delayed messages, duplicate work and local ownership. *)
module K = Kite_runtime.Kubelet
module C = Kite_runtime.Cluster

let ( let* ) = Result.bind
let is_ok f r = Result.fold ~ok:f ~error:(fun _error -> false) r
let fails error r = Result.fold ~ok:(fun _value -> false)
    ~error:(fun actual -> actual = error) r

let create () = K.create ~node_id:"a" ~incarnation:1

let trace events =
  let* initial = create () in
  List.fold_left (fun acc event ->
    let* state, effects = acc in
    let* next, more = K.step state event in
    Ok (next, List.append effects more)) (Ok (initial, [])) events

let ready = [K.Observe_epoch 1; K.Node_acquired 1]
let start ?(epoch = 1) ?(incarnation = 1) pod = K.Start {epoch; pod; incarnation}
let stop ?(epoch = 1) ?(incarnation = 1) pod = K.Stop {epoch; pod; incarnation}
let locked ticket = K.Pod_lock {ticket; granted = true}
let started = List.append ready [start 0]
let running = List.append started [locked 1]

let count_work effects = List.length (List.filter (fun action -> match action with
  | K.Begin_work _ -> true
  | K.Acquire_node _ | K.Release_node _
  | K.Spawn _ | K.Terminate _ | K.Publish_place _
  | K.Release_place _ -> false) effects)

let terminated effects = List.filter_map (fun action -> match action with
  | K.Terminate worker -> Some worker.K.ticket
  | K.Acquire_node _ | K.Release_node _
  | K.Spawn _ | K.Publish_place _ | K.Release_place _
  | K.Begin_work _ -> None) effects

let no_payload_before_lock () = is_ok (fun (state, effects) ->
  let view = K.view state in
  count_work effects = 0
  && List.length view.workers = 1
  && List.for_all (fun (w : K.worker) -> w.phase = K.Starting) view.workers
  && List.exists (fun action -> match action with
       | K.Spawn worker -> worker.pod = 0 && worker.ticket = 1
       | K.Acquire_node _ | K.Release_node _
       | K.Terminate _ | K.Publish_place _ | K.Release_place _
       | K.Begin_work _ -> false) effects) (trace started)

let lock_grant_once () = is_ok (fun (state, effects) ->
  count_work effects = 1
  && List.for_all (fun (w : K.worker) -> w.phase = K.Running) (K.view state).workers)
    (trace (List.append running [locked 1]))

let lock_denied () = is_ok (fun (state, effects) ->
  count_work effects = 0 && terminated effects = [1]
  && List.for_all (fun (w : K.worker) -> w.phase = K.Stopping) (K.view state).workers)
    (trace (List.append started [K.Pod_lock {ticket = 1; granted = false}; locked 1]))

let freeze_running () = is_ok Fun.id (let* state, effects = trace running in
  let* frozen, actions = K.step state K.Freeze in
  let view = K.view frozen in
  Ok (count_work effects = 1 && count_work actions = 0
      && view.mode = K.Frozen && not view.node_lock
      && List.mem (K.Release_node 1) actions
      && terminated actions = [1]
      && List.exists (fun action -> match action with
           | K.Release_place worker -> worker.pod = 0 && worker.ticket = 1
           | K.Acquire_node _ | K.Release_node _
           | K.Spawn _ | K.Terminate _ | K.Publish_place _
           | K.Begin_work _ -> false) actions
      && List.for_all (fun (w : K.worker) -> w.phase = K.Stopping) view.workers))

let late_grant () = is_ok (fun (state, effects) ->
  count_work effects = 0 && (K.view state).incarnation = 2
  && List.mem (K.Acquire_node 2) effects
  && List.for_all (fun (w : K.worker) -> w.phase = K.Stopping) (K.view state).workers)
    (trace (List.append started [K.Freeze; K.Resume; K.Node_acquired 2; locked 1]))

let wait_for_exit () = is_ok (fun (state, _effects) ->
  fails K.Duplicate_pod (K.step state (start 0))
  && is_ok (fun (exited, _actions) ->
    is_ok (fun (fresh, effects) ->
      count_work effects = 0
      && List.exists (fun (w : K.worker) -> w.ticket = 2 && w.pod = 0)
           (K.view fresh).workers
      && fails K.Unknown_worker (K.step fresh (locked 1)))
      (K.step exited (start 0))) (K.step state (K.Worker_exited 1)))
    (trace (List.append running [stop 0]))

let epoch_cancels_pending () = is_ok (fun (state, effects) ->
  count_work effects = 0 && terminated effects = [1]
  && (K.view state).epoch = 2
  && fails K.Stale_epoch (K.step state (start 1))
  && fails K.Stale_epoch (K.step state (K.Observe_epoch 1)))
    (trace (List.append started [K.Observe_epoch 2; locked 1]))

let epoch_keeps_running () = is_ok (fun (state, effects) ->
  count_work effects = 1 && terminated effects = []
  && List.for_all (fun (w : K.worker) -> w.phase = K.Running) (K.view state).workers
  && fails K.Stale_epoch (K.step state (stop 0))
  && is_ok (fun (_next, actions) -> terminated actions = [1])
       (K.step state (stop ~epoch:2 0)))
    (trace (List.append running [K.Observe_epoch 2]))

let node_loss () = is_ok (fun (state, effects) ->
  (K.view state).mode = K.Frozen && not (K.view state).node_lock
  && terminated effects = [1]
  && fails K.Node_unavailable (K.step state (start 1)))
    (trace (List.append running [K.Node_lost 1]))

let duplicate_isolation () = is_ok (fun (state, _effects) ->
  fails K.Duplicate_pod (K.step state (start 0))
  && is_ok (fun (more, actions) ->
       count_work actions = 0 && List.length (K.view more).workers = 2)
       (K.step state (start 1))) (trace running)

let idempotent event initial = is_ok (fun (state, _effects) ->
  is_ok (fun (next, actions) -> actions = [] && K.view next = K.view state)
    (K.step state event)) (trace initial)

let refusal error event initial = is_ok (fun (state, _effects) ->
    fails error (K.step state event)) (trace initial)

let transition_invariants () =
  let rec explore depth begun state =
    if depth = 0 then true else
    let before = K.view state in
    let events = [start ~epoch:before.epoch ~incarnation:before.incarnation 0;
      start ~epoch:before.epoch ~incarnation:before.incarnation 1;
      stop ~epoch:before.epoch ~incarnation:before.incarnation 0;
      K.Observe_epoch (before.epoch + 1); K.Freeze; K.Resume;
      K.Node_acquired before.incarnation; K.Node_lost before.incarnation;
      locked 1; K.Pod_lock {ticket = 1; granted = false}; K.Worker_exited 1;
      locked 2; K.Worker_exited 2] in
    List.for_all (fun event -> Result.fold ~error:(fun _error -> true)
      ~ok:(fun (next, effects) ->
        let after = K.view next in
        let pods = List.map (fun (w : K.worker) -> w.pod) after.workers in
        let work = List.filter_map (fun action -> match action with
          | K.Begin_work worker -> Some worker
          | K.Acquire_node _ | K.Release_node _
          | K.Spawn _ | K.Terminate _ | K.Publish_place _
          | K.Release_place _ -> None) effects in
        let safe = List.for_all (fun (worker : K.worker) ->
          before.mode = K.Ready && before.node_lock
          && worker.incarnation = before.incarnation
          && not (List.mem worker.ticket begun)
          && List.exists (fun (w : K.worker) ->
               w.ticket = worker.ticket && w.phase = K.Starting) before.workers
          && event = locked worker.ticket) work in
        safe && List.length pods = List.length (List.sort_uniq Int.compare pods)
        && after.incarnation >= before.incarnation && after.epoch >= before.epoch
        && List.for_all (fun (w : K.worker) ->
             if w.phase = K.Running then after.mode = K.Ready && after.node_lock
               && w.incarnation = after.incarnation else true) after.workers
        && explore (depth - 1)
             (List.append (List.map (fun (w : K.worker) -> w.ticket) work) begun) next)
      (K.step state event)) events in
  is_ok (fun (state, _effects) -> explore 5 [] state) (trace ready)

let planner_to_workers () = is_ok Fun.id (
  let* config = C.config ~timeout:3 ~max_pods:8 in
  let nodes : C.node list = List.map (fun node_id ->
    {C.node_id; incarnation = 1; lock_held = true; heartbeat = 10; phase = C.Active})
    ["a"; "b"] in
  let snapshot : C.snapshot = {now = 10; epoch = 1; nodes;
                              placements = []; pod_locks = []} in
  let* plan = C.reconcile config ~epoch:1 ~desired:2 snapshot in
  let* commands = C.authorize ~current_epoch:1 plan in
  let run_node (node : C.node) =
    let* state = K.create ~node_id:node.node_id ~incarnation:1 in
    let* state, _effects = K.step state (K.Node_acquired 1) in
    let* state, _effects = K.step state (K.Observe_epoch 1) in
    let* state, effects = List.fold_left (fun acc command ->
      let* state, effects = acc in
      match command with
      | C.Start target ->
        if String.equal target.owner node.node_id then
          let* next, more = K.step state (start ~incarnation:target.incarnation target.pod) in
          Ok (next, List.append effects more)
        else Ok (state, effects)
      | C.Stop _target -> Ok (state, effects)) (Ok (state, [])) commands in
    let* state, work = K.step state (locked 1) in
    Ok (count_work effects = 0 && count_work work = 1
        && List.length (K.view state).workers = 1) in
  Ok (List.for_all (fun node -> is_ok Fun.id (run_node node)) nodes
      && List.length commands = 2))

let incarnation_overflow () = is_ok Fun.id (
  let* state = K.create ~node_id:"a" ~incarnation:max_int in
  let* frozen, _effects = K.step state K.Freeze in
  Ok (fails K.Counter_exhausted (K.step frozen K.Resume)))

let late_node_acquisition () = is_ok (fun (state, _effects) ->
  is_ok (fun (same, actions) -> K.view same = K.view state
      && actions = [K.Release_node 2]) (K.step state (K.Node_acquired 2)))
    (trace [K.Freeze; K.Resume; K.Freeze])

let old_node_acquisition () = is_ok (fun (state, _effects) ->
  is_ok (fun (same, actions) -> K.view same = K.view state
      && (K.view same).node_lock && (K.view same).incarnation = 3
      && actions = [K.Release_node 2]) (K.step state (K.Node_acquired 2)))
    (trace [K.Freeze; K.Resume; K.Freeze; K.Resume; K.Node_acquired 3])

let cases =
  [ "no-payload-before-lock", no_payload_before_lock;
    "lock-grant-once", lock_grant_once;
    "lock-denied", lock_denied;
    "freeze-running", freeze_running;
    "late-grant-after-resume", late_grant;
    "wait-for-exit", wait_for_exit;
    "epoch-cancels-pending", epoch_cancels_pending;
    "epoch-keeps-running", epoch_keeps_running;
    "node-loss", node_loss;
    "duplicate-isolation", duplicate_isolation;
    "transition-invariants", transition_invariants;
    "planner-to-workers", planner_to_workers;
    "incarnation-overflow", incarnation_overflow;
    "late-node-acquisition", late_node_acquisition;
    "old-node-acquisition", old_node_acquisition;
    "freeze-idempotent", (fun () -> idempotent K.Freeze (List.append running [K.Freeze]));
    "resume-idempotent", (fun () -> idempotent K.Resume ready);
    "stop-idempotent", (fun () -> idempotent (stop 0) (List.append running [stop 0]));
    "absent-stop", (fun () -> idempotent (stop 7) ready);
    "node-lock-idempotent", (fun () -> idempotent (K.Node_acquired 1) ready);
    "epoch-idempotent", (fun () -> idempotent (K.Observe_epoch 1) ready);
    "no-node-lock", (fun () -> refusal K.Node_unavailable (start 0) [K.Observe_epoch 1]);
    "no-leader-epoch", (fun () -> refusal K.Stale_epoch (start 0) [K.Node_acquired 1]);
    "frozen-start", (fun () -> refusal K.Node_unavailable (start 0) (List.append ready [K.Freeze]));
    "old-node-loss", (fun () -> refusal K.Stale_incarnation (K.Node_lost 1)
      (List.append ready [K.Freeze; K.Resume; K.Node_acquired 2]));
    "old-start", (fun () -> refusal K.Stale_incarnation (start 0)
      (List.append ready [K.Freeze; K.Resume; K.Node_acquired 2]));
    "old-stop", (fun () -> refusal K.Stale_incarnation (stop 0)
      (List.append running [K.Freeze; K.Resume; K.Node_acquired 2]));
    "invalid-node", (fun () -> fails K.Invalid_node (K.create ~node_id:"a:b" ~incarnation:1));
    "empty-node", (fun () -> fails K.Invalid_node (K.create ~node_id:"" ~incarnation:1));
    "invalid-incarnation", (fun () -> fails K.Invalid_incarnation (K.create ~node_id:"a" ~incarnation:0));
    "invalid-epoch", (fun () -> refusal K.Invalid_epoch (K.Observe_epoch 0) ready);
    "invalid-pod", (fun () -> refusal K.Invalid_pod (start (-1)) ready);
    "unknown-worker", (fun () -> refusal K.Unknown_worker (locked 42) ready);
    "exit-releases-placement", (fun () -> is_ok (fun (state, _effects) ->
      is_ok (fun (next, effects) -> (K.view next).workers = []
        && List.exists (fun action -> match action with
             | K.Release_place worker -> worker.ticket = 1
             | K.Acquire_node _ | K.Release_node _
             | K.Spawn _ | K.Terminate _ | K.Publish_place _
             | K.Begin_work _ -> false) effects)
        (K.step state (K.Worker_exited 1))) (trace running)) ]

let () = Runtime_suite.run "kubelet" cases
