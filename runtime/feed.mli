(** A validated committed prefix. Broadcast notifications only suggest work.
    The host must obtain metadata and entries from one consistent read and
    apply only [accepted] entries to downstream projections. No browser
    operation, delivery guarantee, or compaction is implemented here. *)

(** The largest counter value. Sequences, epochs and hints stop here. *)
val max_counter : int
type 'a entry = { seq : int; epoch : int; payload : 'a }
type error =
  | Invalid_counter of string
  | Invalid_head
  | Stale_head
  | Entry_after_head of int
  | Unordered_batch
  | Gap of { expected : int; actual : int }
  | Epoch_regression of { previous : int; actual : int }
  | Conflicting_replay of int
  | Inconsistent_head
type 'a t

(** Make an empty prefix. The cursor, the epoch and the hint are zero. *)
val create : unit -> 'a t

(** Give the sequence of the last accepted entry. *)
val cursor : 'a t -> int

(** Give the epoch of the last accepted entry. *)
val epoch : 'a t -> int

(** Give the largest sequence that a notification or a head announced.
    [apply] also raises the hint to the observed head sequence. The hint is
    a high-water mark of doorbells and heads. The hint is never a cursor. *)
val hint : 'a t -> int

(** List every retained entry in sequence order. *)
val entries : 'a t -> 'a entry list
(** Valid notification counters range from zero through [max_counter].
    Notification contents never become committed entries or advance epoch. *)
val notify : seq:int -> 'a t -> ('a t, error) result
(** Poll this sequence even when no notification has arrived. [None] means
    the committed prefix reached the fixed counter bound. That result needs a
    position at the counter bound. [apply] advances the position by one
    accepted entry, so a host cannot build that prefix. *)
val read_from : 'a t -> int option
(** Accept a possibly overlapping page, ordered by nondecreasing sequence.
    Every new record must extend the contiguous prefix; historical records
    must exactly match their saved epoch and payload under [equal]. Repeated
    identical records are harmless. Errors leave the input state unchanged.

    [head_seq] and [head_epoch] describe the same durable snapshot as the
    page. [head_epoch] is exactly the epoch of the entry at [head_seq], or
    zero for an empty log. This matches M1 storage: claiming a leader epoch
    also appends its leader record in that transaction. A source that changes
    metadata epoch without appending cannot use that metadata as this head.
    A partial page need not reach the head. Every observed head boundary is
    retained until its matching entry is checked, even if newer metadata is
    read first. An earlier entry cannot exceed the epoch of the next pending
    boundary, so contradictory partial pages are refused before projection.
    Metadata epoch never replaces the epoch of the accepted
    prefix. [accepted] contains only new
    entries, in sequence order. History is retained for exact replay checks.
    [equal] must be a total equivalence over immutable payloads. *)
val apply : equal:('a -> 'a -> bool) -> head_seq:int -> head_epoch:int ->
  'a entry list -> 'a t -> ('a t * 'a entry list, error) result

(** Give the text of an error for a log row. *)
val error_text : error -> string
