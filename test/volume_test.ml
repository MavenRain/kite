(* Adversarial durable-store and local-callback traces, with no browser effects. *)
module V = Kite_runtime.Volume
let ( let* ) = Result.bind
let is_ok result = Result.fold ~ok:Fun.id ~error:(fun _error -> false) result
let fails wanted = Result.fold ~ok:(fun _value -> false) ~error:(( = ) wanted)
let step state event = Result.map fst (V.step state event)
let make_key () = V.key ~namespace:"orders" ~ordinal:0
let initial () =
  let* key = make_key () in
  let* durable = V.create key ~epoch:1 in
  let* state = V.session key ~first_ticket:0 in
  Ok (durable, state)
let request_claim durable state =
  let* state = step state (V.Attach (V.snapshot durable).epoch) in
  let ticket = (V.view state).ticket in
  let* state, actions = V.step state (V.Lock_acquired {ticket; durable}) in
  let claim = List.find_map (function
    | V.Claim_writer claim -> Some claim
    | V.Acquire_lock _ | V.Commit_checkpoint _ | V.Abort_claim _
    | V.Abort_write _ | V.Release_lock _ -> None) actions in
  let* claim = Option.to_result ~none:V.Invalid_phase claim in
  Ok (state, claim)
let attach durable state =
  let* state, claim = request_claim durable state in
  let* durable, receipt = V.apply_claim durable claim in
  let* state = step state (V.Claimed {ticket = claim.lease.ticket; result = Ok receipt}) in
  Ok (durable, state)
let ready () = let* durable, state = initial () in attach durable state
let prepare state entries =
  let* state = step state (V.Prepare entries) in
  let* write = Option.to_result ~none:V.Invalid_phase (V.view state).pending in
  Ok (state, write)
let begin_write state entries =
  let* state, write = prepare state entries in
  let* state = step state (V.Begin_write write.ticket) in
  Ok (state, write)
let commit durable state entries =
  let* state, write = begin_write state entries in
  let* durable, receipt = V.apply_write durable write in
  let* state = step state (V.Completed {ticket = write.ticket; result = Ok receipt}) in
  Ok (durable, state)
let reopened durable state = let* state = step state V.Discard in attach durable state
let release_tickets actions = List.filter_map (function
  | V.Release_lock lease -> Some lease.V.ticket
  | V.Acquire_lock _ | V.Claim_writer _ | V.Commit_checkpoint _
  | V.Abort_claim _ | V.Abort_write _ -> None) actions
let no_commit actions = List.for_all (function
  | V.Commit_checkpoint _ -> false
  | V.Acquire_lock _ | V.Claim_writer _ | V.Abort_claim _
  | V.Abort_write _ | V.Release_lock _ -> true) actions
let entries durable = (V.snapshot durable).committed.entries
let pending_result state wanted = Option.fold ~none:false
  ~some:(fails wanted) (V.view state).last_result

let stable_key () = is_ok (let* a = make_key () in
  let* b = V.key ~namespace:"orders" ~ordinal:0 in
  let* c = V.key ~namespace:"orders" ~ordinal:1 in
  Ok (a = b && a <> c && V.key_text a = "orders:0"))
let malformed_keys () = List.for_all (fun (namespace, ordinal) ->
  fails V.Invalid_key (V.key ~namespace ~ordinal))
  ["", 0; "a:b", 0; "a/b", 0; "a", -1; "a", V.limit + 1]
let lock_required () = is_ok (let* durable, state = initial () in
  let* waiting, actions = V.step state (V.Attach 1) in
  let* refused = step waiting (V.Lock_refused (V.view waiting).ticket) in
  Ok (List.length actions = 1 && no_commit actions
      && (V.view waiting).phase = V.Acquiring && not (V.view waiting).lock_held
      && fails V.Invalid_phase (V.step waiting (V.Prepare ["x"]))
      && (V.snapshot durable).generation = 0 && pending_result refused V.Lock_denied))
let claim_completion_required () = is_ok (let* durable, state = initial () in
  let* state, claim = request_claim durable state in
  let* changed, receipt = V.apply_claim durable claim in
  let* attached = step state (V.Claimed {ticket = claim.lease.ticket; result = Ok receipt}) in
  Ok ((V.snapshot durable).generation = 0 && (V.snapshot changed).generation = 1
      && (V.view state).phase = V.Claiming && (V.view state).writer = None
      && (V.view attached).phase = V.Attached))
let preparation_is_not_commit () = is_ok (let* durable, state = ready () in
  let* prepared, write = prepare state ["one"] in
  let* writing, actions = V.step prepared (V.Begin_write write.ticket) in
  Ok ((V.view prepared).phase = V.Prepared && (V.view writing).phase = V.In_flight
      && entries durable = [] && (V.view writing).last_result = None
      && List.length actions = 1 && not (no_commit actions)))
let commit_completion_required () = is_ok (let* durable, state = ready () in
  let* writing, write = begin_write state ["one"; "two"] in
  let* changed, receipt = V.apply_write durable write in
  let* complete = step writing (V.Completed {ticket = write.ticket; result = Ok receipt}) in
  Ok (entries durable = [] && entries changed = ["one"; "two"]
      && (V.view writing).committed.revision = 0 && (V.view writing).last_result = None
      && (V.view complete).committed = (V.snapshot changed).committed
      && Option.fold ~none:false ~some:(Result.is_ok) (V.view complete).last_result))
let same_epoch_handoff () = is_ok (let* durable, old = ready () in
  let* old, write = begin_write old ["stale"] in
  let* discarded = step old V.Discard in
  let* durable, newer = attach durable discarded in
  Ok ((V.snapshot durable).epoch = 1 && (V.snapshot durable).generation = 2
      && fails V.Stale_generation (V.apply_write durable write)
      && (V.view newer).committed.entries = []))
let claim_compare_and_set () = is_ok (let* durable, state = initial () in
  let* _state, claim = request_claim durable state in
  let* changed, _receipt = V.apply_claim durable claim in
  Ok (fails V.Stale_generation (V.apply_claim changed claim)))
let old_epoch_write () = is_ok (let* durable, state = ready () in
  let* _state, write = begin_write state ["stale"] in
  let* changed = V.observe_epoch durable 2 in
  Ok (fails V.Stale_epoch (V.apply_write changed write) && entries changed = []))
let old_epoch_claim () = is_ok (let* durable, state = initial () in
  let* _state, claim = request_claim durable state in
  let* changed = V.observe_epoch durable 2 in
  Ok (fails V.Stale_epoch (V.apply_claim changed claim)))
let duplicate_commit () = is_ok (let* durable, state = ready () in
  let* state, write = begin_write state ["once"] in
  let* durable, receipt = V.apply_write durable write in
  let* state = step state (V.Completed {ticket = write.ticket; result = Ok receipt}) in
  Ok (fails V.Stale_revision (V.apply_write durable write)
      && fails V.Stale_callback (V.step state (V.Completed {ticket = write.ticket; result = Ok receipt}))
      && entries durable = ["once"]))
let stale_completion () = is_ok (let* durable, state = ready () in
  let* state, old = begin_write state ["old"] in
  let* durable, receipt = V.apply_write durable old in
  let* durable, state = reopened durable state in
  let* newer, pending = begin_write state ["new"] in
  Ok (old.ticket <> pending.ticket
      && fails V.Stale_callback (V.step newer (V.Completed {ticket = old.ticket; result = Ok receipt}))
      && fails V.Stale_callback (V.step newer (V.Completed {ticket = pending.ticket; result = Ok receipt}))
      && (V.view newer).committed.entries = ["old"] && entries durable = ["old"]))
let failed_write_retry () = is_ok (let* durable, state = ready () in
  let* durable, state = commit durable state ["kept"] in
  let* state, write = begin_write state ["lost"] in
  let* state = step state (V.Completed {ticket = write.ticket; result = Error (V.Storage_failed "quota")}) in
  let failed = pending_result state (V.Storage_failed "quota") in
  let* durable, state = commit durable state ["retry"] in
  Ok (failed && entries durable = ["kept"; "retry"]
      && (V.view state).committed.revision = 2))
let freeze_prepared () = is_ok (let* durable, state = ready () in
  let* state, write = prepare state ["lost"] in
  let* state, actions = V.step state V.Freeze in
  Ok (release_tickets actions = [write.lease.ticket] && no_commit actions
      && (V.view state).phase = V.Releasing && pending_result state V.Aborted
      && fails V.Stale_callback (V.step state (V.Begin_write write.ticket))
      && entries durable = []))
let freeze_inflight commit_wins () = is_ok (let* durable, state = ready () in
  let* durable, state = commit durable state ["kept"] in
  let* state, write = begin_write state ["racing"] in
  let* frozen, actions = V.step state V.Freeze in
  let waits = (V.view frozen).mode = V.Freezing && (V.view frozen).lock_held
    && release_tickets actions = []
    && List.exists (function V.Abort_write pending -> pending = write
       | V.Acquire_lock _ | V.Claim_writer _ | V.Commit_checkpoint _
       | V.Abort_claim _ | V.Release_lock _ -> false) actions in
  let* durable, result = if commit_wins then
      Result.map (fun (durable, receipt) -> durable, Ok receipt) (V.apply_write durable write)
    else Ok (durable, Error V.Aborted) in
  let* released, actions = V.step frozen (V.Completed {ticket = write.ticket; result}) in
  let* closed = step released (V.Released write.lease.ticket) in
  let* durable, reopened = attach durable closed in
  Ok (waits && release_tickets actions = [write.lease.ticket]
      && (V.view closed).mode = V.Frozen && not (V.view closed).lock_held
      && (V.view reopened).committed.entries =
         (if commit_wins then ["kept"; "racing"] else ["kept"])
      && entries durable = (V.view reopened).committed.entries))
let freeze_claim () = is_ok (let* durable, state = initial () in
  let* state, claim = request_claim durable state in
  let* frozen, actions = V.step state V.Freeze in
  let* durable, receipt = V.apply_claim durable claim in
  let* state, cleanup = V.step frozen (V.Claimed {ticket = claim.lease.ticket; result = Ok receipt}) in
  Ok (release_tickets actions = [] && List.length actions = 1
      && release_tickets cleanup = [claim.lease.ticket]
      && (V.view state).phase = V.Releasing && (V.view state).writer = None
      && (V.snapshot durable).generation = 1))
let stale_grant_cleanup () = is_ok (let* durable, state = initial () in
  let* waiting = step state (V.Attach 1) in
  let old = (V.view waiting).ticket in
  let* frozen = step waiting V.Freeze in
  let* current = step frozen (V.Attach 1) in
  let* unchanged, cleanup = V.step current (V.Lock_acquired {ticket = old; durable}) in
  Ok (V.view unchanged = V.view current && release_tickets cleanup = [old]
      && (V.view current).ticket <> old))
let duplicate_grant_preserves_lease () = is_ok (let* durable, state = ready () in
  Ok (fails V.Stale_callback (V.step state (V.Lock_acquired {ticket = 1; durable}))
      && (V.view state).lock_held))
let wrong_volume_cleanup () = is_ok (let* _durable, state = initial () in
  let* other = V.key ~namespace:"other" ~ordinal:0 in
  let* durable = V.create other ~epoch:1 in
  let* state = step state (V.Attach 1) in
  let* state, actions = V.step state (V.Lock_acquired {ticket = 1; durable}) in
  Ok (release_tickets actions = [1] && pending_result state V.Wrong_volume))
let crash_phase phase () = is_ok (let* durable, state = ready () in
  let* durable, state = commit durable state ["prefix"] in
  let* state, pending = prepare state ["suffix"] in
  let* state = if phase = 0 then Ok state else step state (V.Begin_write pending.ticket) in
  let* durable = if phase = 2 then Result.map fst (V.apply_write durable pending) else Ok durable in
  let* durable, state = reopened durable state in
  let expected = if phase = 2 then ["prefix"; "suffix"] else ["prefix"] in
  Ok (entries durable = expected && (V.view state).committed.entries = expected))
let abort_reopen () = is_ok (let* durable, state = ready () in
  let* durable, state = commit durable state ["prefix"] in
  let* state, write = begin_write state ["lost"] in
  let* state = step state (V.Completed {ticket = write.ticket; result = Error V.Aborted}) in
  let* durable, state = reopened durable state in
  let* durable, _state = commit durable state ["tail"] in
  Ok (entries durable = ["prefix"; "tail"]))
let crash_acquiring () = is_ok (let* durable, state = initial () in
  let* state = step state (V.Attach 1) in
  let old = (V.view state).ticket in
  let* durable, current = reopened durable state in
  let* unchanged, actions = V.step current (V.Lock_acquired {ticket = old; durable}) in
  Ok (V.view unchanged = V.view current && release_tickets actions = [old]
      && (V.view current).lock_held && (V.snapshot durable).generation = 1))
let crash_claim durable_won () = is_ok (let* durable, state = initial () in
  let* state, claim = request_claim durable state in
  let* proposed, receipt = V.apply_claim durable claim in
  let durable = if durable_won then proposed else durable in
  let* durable, current = reopened durable state in
  Ok ((V.snapshot durable).generation = (if durable_won then 2 else 1)
      && fails V.Stale_callback (V.step current
           (V.Claimed {ticket = claim.lease.ticket; result = Ok receipt}))
      && (V.view current).phase = V.Attached && entries durable = []))
let ticket_exhaustion () = is_ok (let* key = make_key () in
  let* state = V.session key ~first_ticket:V.limit in
  Ok (fails V.Counter_exhausted (V.step state (V.Attach 1))))
let generation_exhaustion () = is_ok (let* durable, state = initial () in
  let* durable = V.restore {(V.snapshot durable) with generation = V.limit} in
  let* _state, claim = request_claim durable state in
  Ok (fails V.Counter_exhausted (V.apply_claim durable claim)))
let revision_exhaustion () = is_ok (let* durable, state = initial () in
  let* durable = V.restore {(V.snapshot durable) with generation = 1;
    committed = {revision = V.limit; entries = ["saved"]}} in
  let* _durable, state = attach durable state in
  Ok (fails V.Counter_exhausted (V.step state (V.Prepare ["too late"]))))
let lock_grant_epoch_mismatch () = is_ok (let* durable, state = initial () in
  let* state = step state (V.Attach 1) in
  let ticket = (V.view state).ticket in
  let* newer = V.observe_epoch durable 2 in
  let* next, actions = V.step state (V.Lock_acquired {ticket; durable = newer}) in
  Ok (release_tickets actions = [ticket] && (V.view next).mode = V.Freezing
      && pending_result next V.Stale_epoch && (V.snapshot newer).generation = 0))
(* Both sessions below hold ticket 1. The interface forbids that reuse
   (volume.mli lines 75 to 79, and the stage brief lines 32 to 33).
   The case pins a defensive branch. *)
let crossed_claim_receipt_refused () = is_ok (let* key = make_key () in
  let* durable = V.create key ~epoch:1 in
  let* first = V.session key ~first_ticket:0 in
  let* second = V.session key ~first_ticket:0 in
  let* first, mine = request_claim durable first in
  let* newer = V.observe_epoch durable 2 in
  let* _second, theirs = request_claim newer second in
  let* _durable, receipt = V.apply_claim newer theirs in
  Ok (mine.V.lease.V.ticket = theirs.V.lease.V.ticket
      && fails V.Stale_callback
        (V.step first (V.Claimed {ticket = mine.V.lease.V.ticket; result = Ok receipt}))))
let invalid_snapshots () = is_ok (let* durable, _state = initial () in
  let old = V.snapshot durable in
  Ok (fails V.Invalid_counter (V.restore {old with epoch = 0})
      && fails V.Invalid_counter (V.restore {old with generation = V.limit + 1})
      && fails V.Invalid_snapshot (V.restore {old with committed = {revision = 0; entries = ["bad"]}})
      && fails V.Invalid_snapshot (V.restore {old with committed = {revision = 1; entries = []}})))
let () = Runtime_suite.run "volume" [
  "stable_key", stable_key; "malformed_keys", malformed_keys;
  "lock_required", lock_required; "claim_completion_required", claim_completion_required;
  "preparation_is_not_commit", preparation_is_not_commit;
  "commit_completion_required", commit_completion_required;
  "same_epoch_handoff", same_epoch_handoff; "claim_compare_and_set", claim_compare_and_set;
  "old_epoch_write", old_epoch_write; "old_epoch_claim", old_epoch_claim;
  "duplicate_commit", duplicate_commit; "stale_completion", stale_completion;
  "failed_write_retry", failed_write_retry; "freeze_prepared", freeze_prepared;
  "freeze_abort", freeze_inflight false; "freeze_commit_race", freeze_inflight true;
  "freeze_claim", freeze_claim; "stale_grant_cleanup", stale_grant_cleanup;
  "duplicate_grant_preserves_lease", duplicate_grant_preserves_lease;
  "wrong_volume_cleanup", wrong_volume_cleanup;
  "crash_prepared", crash_phase 0; "crash_inflight", crash_phase 1;
  "crash_after_durable_before_callback", crash_phase 2; "abort_reopen", abort_reopen;
  "crash_acquiring", crash_acquiring; "crash_claim_before_commit", crash_claim false;
  "crash_claim_after_commit", crash_claim true;
  "ticket_exhaustion", ticket_exhaustion; "generation_exhaustion", generation_exhaustion;
  "revision_exhaustion", revision_exhaustion; "invalid_snapshots", invalid_snapshots;
  "lock_grant_epoch_mismatch", lock_grant_epoch_mismatch;
  "crossed_claim_receipt_refused", crossed_claim_receipt_refused
]
