(** Pure volume protocol. No lock, IndexedDB transaction or durability is measured.
    Stable keys contain a namespace and ordinal, never a node identity. *)
type key
type error = Invalid_key | Invalid_counter | Invalid_snapshot | Wrong_volume
  | Stale_epoch | Stale_generation | Stale_revision | Stale_callback | Invalid_phase
  | Counter_exhausted | Lock_denied | Aborted | Storage_failed of string
(** Make a stable volume key. The namespace uses ASCII letters, digits,
    underscore or hyphen, and holds 1 through 64 characters. The ordinal is
    from zero through [limit]. *)
val key : namespace:string -> ordinal:int -> (key, error) result

(** Give the text of a key as [namespace:ordinal] for a log row. *)
val key_text : key -> string

(** The largest counter value. Epochs, generations, revisions, tickets and
    ordinals stop here. *)
val limit : int
type checkpoint = { revision : int; entries : string list }
type snapshot = { key : key; epoch : int; generation : int; committed : checkpoint }
type durable
(** Make an empty durable volume at this positive epoch. The generation and
    the revision start at zero. *)
val create : key -> epoch:int -> (durable, error) result

(** Adopt a durable snapshot that a host read. Refuse a counter outside its
    bound and a generation or revision that contradicts the checkpoint. *)
val restore : snapshot -> (durable, error) result

(** Give the durable key, epoch, generation and committed checkpoint. *)
val snapshot : durable -> snapshot

(** Record a newer leader epoch on the durable volume. Refuse an older epoch
    and a counter outside its bound. *)
val observe_epoch : durable -> int -> (durable, error) result
type lease = private { key : key; ticket : int }
type fence = private { key : key; epoch : int; generation : int }
type claim = private { lease : lease; epoch : int; expected_generation : int }
type write = private {
  lease : lease; fence : fence; ticket : int; expected_revision : int;
  entries : string list
}
type claim_receipt
type write_receipt
(** Each helper describes ONE atomic transaction over the global leader epoch,
    volume generation and checkpoint. Claims compare epoch and generation before
    incrementing the generation. Writes compare both fences and the revision.
    The adapter publishes the returned receipt only from transaction.oncomplete,
    never from an individual request's success callback. On abort it retains the
    prior durable value. Both operations require the exact lease in their request
    to remain held. The local protocol creates claims only after Lock_acquired.
    There is no standing transaction between claim, preparation and begin. *)
val apply_claim : durable -> claim -> (durable * claim_receipt, error) result

(** Commit one checkpoint under the exact writer fence and revision. The
    receipt names the write it answers and the saved checkpoint. *)
val apply_write : durable -> write -> (durable * write_receipt, error) result
type mode = Active | Freezing | Frozen
type phase = Detached | Acquiring | Claiming | Attached | Prepared | In_flight | Releasing
type view = {
  key : key; mode : mode; phase : phase; ticket : int;
  writer : fence option; committed : checkpoint; pending : write option;
  lock_held : bool; last_result : (checkpoint, error) result option
}
type session
type event = Attach of int
  | Lock_acquired of { ticket : int; durable : durable }
  | Lock_refused of int
  | Claimed of { ticket : int; result : (claim_receipt, error) result }
  | Prepare of string list | Begin_write of int
  | Completed of { ticket : int; result : (write_receipt, error) result }
  | Freeze | Released of int | Discard
type action = Acquire_lock of lease | Claim_writer of claim
  | Commit_checkpoint of write | Abort_claim of claim | Abort_write of write
  | Release_lock of lease
(** first_ticket supports an adapter's process-wide ticket allocator. It must not
    be reused if callbacks from an older session can arrive. Discard preserves
    the allocator but drops local work; a real crash also destroys its callbacks.
    Reattachment recovers only the committed checkpoint from a fresh claim.
    Epochs, generations, revisions and tickets stop at 1e9. *)
val session : key -> first_ticket:int -> (session, error) result

(** Give the key, mode, phase, ticket, writer fence, committed checkpoint,
    pending write, lock state and last result of this session. *)
val view : session -> view

(** Prepared has no transaction. Begin_write is explicit. Freeze drops a prepared
    batch or requests best-effort abort of an in-flight claim/write. The lease
    remains occupied until transaction completion or abort, then release names
    its exact acquisition ticket. A transaction winning the abort race may commit.
    Discard models local state loss, not rollback. The adapter aborts outstanding
    transactions and releases process-owned leases on discard/crash; a completed
    durable write remains recoverable even if its local callback was discarded.
    Stale lock grants clean up only their own lease; other stale callbacks fail.
    last_result is reset at Prepare and reports success only after Completed. *)
val step : session -> event -> (session * action list, error) result
