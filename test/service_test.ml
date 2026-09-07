module S = Kite_runtime.Service
let ( let* ) = Result.bind
let good check = Result.fold ~ok:check ~error:(fun _error -> false)
let refused wanted = Result.fold ~ok:(fun _value -> false) ~error:(fun actual -> actual = wanted)
let sender ?(incarnation = 1) ?(session = 1) service name : S.sender =
  {service; sender = name; incarnation; session}
let source = sender "chat" "alice"
let publication ?(from = source) sequence payload : S.publication = {source = from; sequence; payload}
let step ?(epoch = 1) event state = S.apply ~epoch event state
let change ?(epoch = 1) event state = Result.map fst (step ~epoch event state)
let ready () =
  let* state = change (S.Register "chat") (S.create ()) in change (S.Handshake source) state
let sent () = let* state = ready () in change (S.Send (publication 1 "hello")) state
let cases = [
  "empty-state", (fun () -> let view = S.view (S.create ()) in
    view.epoch = 0 && view.services = [] && view.sessions = [] && view.messages = []);
  "durable-register-idempotent", (fun () ->
    let built = let* state = change (S.Register "z") (S.create ()) in
      let* state = change (S.Register "a") state in change (S.Register "z") state in
    good (fun state -> (S.view state).services = ["a"; "z"]) built);
  "handshake-starts-sequence-one", (fun () -> good (fun state ->
    (S.view state).sessions = [{S.source; next_sequence = Some 1}]) (ready ()));
  "committed-send-delivers-once", (fun () -> good (fun state ->
    good (fun (next, delivery) -> delivery = Some {S.epoch = 1; publication = publication 1 "hello"} &&
      List.length (S.view next).messages = 1 &&
      (S.view next).sessions = [{S.source; next_sequence = Some 2}])
      (step (S.Send (publication 1 "hello")) state)) (ready ()));
  "identical-send-replay", (fun () -> good (fun state ->
    good (fun (next, delivery) -> delivery = None && S.view next = S.view state)
      (step (S.Send (publication 1 "hello")) state)) (sent ()));
  "conflicting-send-replay", (fun () -> good (fun state ->
    refused S.Conflicting_replay (step (S.Send (publication 1 "changed")) state)) (sent ()));
  "nonlatest-identical-replay", (fun () ->
    let prepared = let* state = sent () in change (S.Send (publication 2 "second")) state in
    good (fun state -> good (fun (next, delivery) ->
      delivery = None && S.view next = S.view state)
      (step (S.Send (publication 1 "hello")) state)) prepared);
  "out-of-order-refused", (fun () -> good (fun state ->
    refused (S.Out_of_order {expected = 1; actual = 2})
      (step (S.Send (publication 2 "gap")) state) &&
    (S.view state).messages = []) (ready ()));
  "handshake-replay-keeps-progress", (fun () -> good (fun state ->
    good (fun (next, delivery) -> delivery = None && S.view next = S.view state)
      (step (S.Handshake source) state)) (sent ()));
  "new-session-resets-sequence", (fun () -> good (fun state ->
    let fresh = sender ~session:2 "chat" "alice" in
    good (fun next ->
      refused S.Stale_session (step (S.Send (publication 1 "hello")) next) &&
      good (fun (last, delivery) -> Option.is_some delivery && List.length (S.view last).messages = 2)
        (step (S.Send (publication ~from:fresh 1 "fresh")) next))
      (change (S.Handshake fresh) state)) (sent ()));
  "incarnation-dominates-session", (fun () ->
    let high = sender ~session:9 "chat" "alice" in
    let fresh = sender ~incarnation:2 "chat" "alice" in
    let prepared = let* state = ready () in let* state = change (S.Handshake high) state in
      change (S.Handshake fresh) state in
    good (fun state -> refused S.Stale_session (step (S.Handshake high) state) &&
      (S.view state).sessions = [{S.source = fresh; next_sequence = Some 1}]) prepared);
  "restart-incarnation-fences-old-session", (fun () ->
    let restarted = sender ~incarnation:2 ~session:1 "chat" "alice" in
    let prepared = let* state = ready () in change (S.Handshake restarted) state in
    good (fun state ->
      refused S.Stale_session (step (S.Send (publication 1 "stale-write")) state) &&
      (S.view state).messages = [] &&
      (S.view state).sessions = [{S.source = restarted; next_sequence = Some 1}]) prepared);
  "ahead-generation-send-refused", (fun () ->
    let ahead = sender ~incarnation:9 ~session:9 "chat" "alice" in
    good (fun state ->
      refused S.Stale_session (step (S.Send (publication ~from:ahead 1 "hijack")) state) &&
      (S.view state).messages = []) (ready ()));
  "independent-senders", (fun () ->
    let bob = sender "chat" "bob" in
    let prepared = let* state = sent () in let* state = change (S.Handshake bob) state in
      change (S.Send (publication ~from:bob 1 "bob")) state in
    good (fun state -> List.length (S.view state).messages = 2 &&
      List.length (S.view state).sessions = 2) prepared);
  "independent-services", (fun () ->
    let other = sender "other" "alice" in
    let prepared = let* state = sent () in let* state = change (S.Register "other") state in
      let* state = change (S.Handshake other) state in
      change (S.Send (publication ~from:other 1 "other")) state in
    good (fun state -> (S.view state).services = ["chat"; "other"] &&
      List.length (S.view state).messages = 2) prepared);
  "epoch-clears-handshakes-keeps-history", (fun () -> good (fun state ->
    good (fun next -> let view = S.view next in view.epoch = 2 && view.sessions = [] &&
      view.services = ["chat"] && List.length view.messages = 1 &&
      refused S.Missing_handshake (step ~epoch:2 (S.Send (publication 1 "hello")) next))
      (S.observe_epoch 2 state)) (sent ()));
  "stale-epoch-refused", (fun () -> good (fun state -> good (fun advanced ->
    refused (S.Stale_epoch {current = 2; actual = 1})
      (step (S.Send (publication 1 "hello")) advanced)) (S.observe_epoch 2 state)) (sent ()));
  "new-epoch-rehandshake", (fun () ->
    let prepared = let* state = sent () in let* state = S.observe_epoch 2 state in
      let* state = change ~epoch:2 (S.Handshake source) state in
      change ~epoch:2 (S.Send (publication 1 "again")) state in
    good (fun state -> List.map (fun (message : S.message) -> message.epoch) (S.view state).messages = [1; 2]) prepared);
  "bad-new-epoch-event-is-atomic", (fun () -> good (fun state ->
    refused (S.Unknown_service "absent")
      (step ~epoch:2 (S.Handshake (sender "absent" "alice")) state) &&
    (S.view state).epoch = 1 && List.length (S.view state).sessions = 1) (sent ()));
  "restore-durable-history", (fun () ->
    let records = [1, S.Register "chat"; 1, S.Handshake source;
      1, S.Send (publication 1 "hello"); 1, S.Send (publication 1 "hello");
      2, S.Handshake source; 2, S.Send (publication 1 "again")] in
    good (fun state -> let view = S.view state in view.epoch = 3 &&
      view.services = ["chat"] && view.sessions = [] &&
      List.map (fun (message : S.message) -> message.publication.payload) view.messages = ["hello"; "again"])
      (S.restore ~epoch:3 records));
  "restore-refuses-conflicting-history", (fun () ->
    refused S.Conflicting_replay (S.restore ~epoch:1 [1, S.Register "chat";
      1, S.Handshake source; 1, S.Send (publication 1 "hello"); 1, S.Send (publication 1 "changed")]) &&
    refused (S.Stale_epoch {current = 2; actual = 1}) (S.restore ~epoch:1 [2, S.Register "chat"]));
  "missing-registration-and-handshake", (fun () ->
    refused (S.Unknown_service "chat") (step (S.Handshake source) (S.create ())) &&
    good (fun state -> refused S.Missing_handshake (step (S.Send (publication 1 "hello")) state))
      (change (S.Register "chat") (S.create ())));
  "name-and-counter-bounds", (fun () ->
    refused S.Invalid_name (step (S.Register "bad:name") (S.create ())) &&
    refused S.Invalid_epoch (step ~epoch:0 (S.Register "chat") (S.create ())) &&
    refused S.Invalid_epoch (S.observe_epoch (S.max_counter + 1) (S.create ())) &&
    good (fun state ->
      refused (S.Invalid_counter "incarnation") (step (S.Handshake (sender ~incarnation:0 "chat" "alice")) state) &&
      refused (S.Invalid_counter "session") (step (S.Handshake (sender ~session:(S.max_counter + 1) "chat" "alice")) state) &&
      refused (S.Invalid_counter "sender_sequence") (step (S.Send (publication 0 "zero")) state) &&
      good (fun _next -> true) (step (S.Handshake (sender ~incarnation:S.max_counter ~session:S.max_counter "chat" "alice")) state))
      (ready ()))
]
let () = Runtime_suite.run "service" cases
