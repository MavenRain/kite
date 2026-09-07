module F = Kite_runtime.Feed
let ( let* ) = Result.bind
let entry seq epoch payload : string F.entry = {seq; epoch; payload}
let apply head_seq head_epoch values state = F.apply ~equal:String.equal ~head_seq ~head_epoch values state
let good check = Result.fold ~ok:check ~error:(fun _error -> false)
let refused wanted = Result.fold ~ok:(fun _value -> false) ~error:(fun actual -> actual = wanted)
let a = entry 1 1 "a"
let b = entry 2 1 "b"
let seed () = Result.map fst (apply 2 1 [a; b] (F.create ()))
let cases = [
  "empty-polls", (fun () ->
    let state = F.create () in F.cursor state = 0 && F.epoch state = 0 &&
    F.hint state = 0 && F.entries state = [] && F.read_from state = Some 1);
  "contiguous-prefix", (fun () -> good (fun (state, accepted) ->
    F.cursor state = 2 && F.epoch state = 1 && accepted = [a; b] &&
    F.entries state = [a; b] && F.read_from state = Some 3)
    (apply 2 1 [a; b] (F.create ())));
  "identical-replay", (fun () -> good (fun state ->
    good (fun (next, accepted) -> accepted = [] && F.entries next = [a; b] &&
      F.cursor next = 2) (apply 2 1 [a; b] state)) (seed ()));
  "overlapping-page", (fun () -> good (fun state ->
    let c = entry 3 2 "c" in good (fun (next, accepted) ->
      accepted = [c] && F.entries next = [a; b; c] && F.epoch next = 2)
      (apply 3 2 [b; c] state)) (seed ()));
  "duplicate-in-page", (fun () -> good (fun (state, accepted) ->
    F.entries state = [a; b] && accepted = [a; b]) (apply 2 1 [a; a; b; b] (F.create ())));
  "payload-conflict", (fun () -> good (fun state ->
    refused (F.Conflicting_replay 1) (apply 2 1 [entry 1 1 "changed"] state)) (seed ()));
  "replay-epoch-conflict", (fun () -> good (fun state ->
    refused (F.Conflicting_replay 1) (apply 3 2 [entry 1 2 "a"] state)) (seed ()));
  "gap-does-not-advance", (fun () -> good (fun state ->
    refused (F.Gap {expected = 3; actual = 4}) (apply 4 1 [entry 4 1 "d"] state) &&
    F.cursor state = 2 && F.read_from state = Some 3) (seed ()));
  "bad-batch-is-atomic", (fun () -> good (fun state ->
    refused (F.Gap {expected = 4; actual = 5})
      (apply 5 2 [entry 3 2 "c"; entry 5 2 "e"] state) &&
    F.entries state = [a; b] && F.epoch state = 1 && F.hint state = 2) (seed ()));
  "unordered-replay", (fun () -> good (fun state ->
    refused F.Unordered_batch (apply 2 1 [b; a] state)) (seed ()));
  "epoch-regression", (fun () -> good (fun state ->
    refused (F.Epoch_regression {previous = 1; actual = 0})
      (apply 3 1 [entry 3 0 "old"] state)) (seed ()));
  "entry-outside-snapshot", (fun () -> good (fun state ->
    refused (F.Entry_after_head 3) (apply 2 1 [entry 3 1 "future"] state) &&
    refused (F.Entry_after_head 3) (apply 3 1 [entry 3 2 "future-epoch"] state)) (seed ()));
  "partial-page-keeps-prefix-epoch", (fun () ->
    let first = entry 1 0 "before-election" in
    good (fun (partial, _) -> F.epoch partial = 0 && F.cursor partial = 1 &&
      F.hint partial = 3 && F.read_from partial = Some 2 &&
      good (fun (complete, accepted) -> F.epoch complete = 2 && List.length accepted = 2)
        (apply 3 2 [entry 2 1 "leader-one"; entry 3 2 "leader-two"] partial))
      (apply 3 2 [first] (F.create ())));
  "empty-newer-page-still-polls", (fun () -> good (fun (state, accepted) ->
    accepted = [] && F.cursor state = 0 && F.epoch state = 0 && F.hint state = 7 &&
    F.read_from state = Some 1) (apply 7 2 [] (F.create ())));
  "stale-snapshot-after-partial", (fun () -> good (fun (state, _) ->
    refused F.Stale_head (apply 6 2 [] state) && F.read_from state = Some 1)
    (apply 7 2 [] (F.create ())));
  "stale-head-epoch-refused", (fun () -> good (fun (state, _) ->
    refused F.Stale_head (apply 9 2 [] state) &&
    F.cursor state = 0 && F.hint state = 5 && F.read_from state = Some 1)
    (apply 5 3 [] (F.create ())));
  "snapshot-epoch-contradiction", (fun () ->
    refused F.Invalid_head (apply 0 1 [] (F.create ())) &&
    refused F.Inconsistent_head (apply 2 2 [a; b] (F.create ())) &&
    good (fun state -> refused F.Inconsistent_head (apply 2 2 [] state)) (seed ()));
  "pending-head-boundaries-survive-newer-snapshots", (fun () ->
    let partial = let* (state, _) = apply 2 2 [a] (F.create ()) in
      Result.map fst (apply 3 3 [] state) in
    good (fun state ->
      refused F.Inconsistent_head
        (apply 4 4 [entry 2 1 "contradicts-first-head"; entry 3 3 "c"; entry 4 4 "d"] state) &&
      F.cursor state = 1 && F.epoch state = 1 && F.read_from state = Some 2 &&
      good (fun (complete, accepted) -> F.cursor complete = 4 && F.epoch complete = 4 &&
        List.length accepted = 3)
        (apply 4 4 [entry 2 2 "b"; entry 3 3 "c"; entry 4 4 "d"] state)) partial);
  "pending-head-bounds-earlier-entry-epoch", (fun () ->
    good (fun (state, _) ->
      refused F.Inconsistent_head (apply 4 4 [entry 1 3 "already-impossible"] state) &&
      F.cursor state = 0 && F.epoch state = 0 && F.read_from state = Some 1 &&
      good (fun (partial, accepted) -> F.cursor partial = 1 && F.epoch partial = 2 &&
        accepted = [entry 1 2 "valid-neighbor"] &&
        good (fun (next, _) -> F.cursor next = 2 && F.epoch next = 2)
          (apply 4 4 [entry 2 2 "boundary"] partial))
        (apply 4 4 [entry 1 2 "valid-neighbor"] state))
      (apply 2 2 [] (F.create ())));
  "notifications-are-only-hints", (fun () -> good (fun state ->
    F.cursor state = 0 && F.epoch state = 0 && F.entries state = [] &&
    F.hint state = F.max_counter && F.read_from state = Some 1 &&
    good (fun next -> F.hint next = F.max_counter) (F.notify ~seq:1 state))
    (F.notify ~seq:F.max_counter (F.create ())));
  "dropped-notification", (fun () -> good (fun state ->
    F.read_from state = Some 3 && good (fun (next, accepted) ->
      F.cursor next = 3 && List.length accepted = 1)
      (apply 3 1 [entry 3 1 "without-doorbell"] state)) (seed ()));
  "bounded-counters", (fun () ->
    F.max_counter = 1_000_000_000 &&
    refused (F.Invalid_counter "notification") (F.notify ~seq:(F.max_counter + 1) (F.create ())) &&
    refused (F.Invalid_counter "entry_sequence")
      (apply F.max_counter 1 [entry (F.max_counter + 1) 1 "past-bound"] (F.create ())) &&
    refused (F.Invalid_counter "head_sequence") (apply (-1) 0 [] (F.create ())) &&
    refused (F.Invalid_counter "head_epoch") (apply 1 (F.max_counter + 1) [] (F.create ())) &&
    refused (F.Invalid_counter "entry_sequence") (apply 1 1 [entry 0 1 "zero"] (F.create ())) &&
    refused (F.Invalid_counter "entry_epoch") (apply 1 1 [entry 1 (-1) "negative"] (F.create ())))
]
let () = Runtime_suite.run "feed" cases
