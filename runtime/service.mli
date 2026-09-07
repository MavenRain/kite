(** Pure projections of committed named-channel records. The adapter commits
    each event under its epoch fence before applying it here. Requests and
    BroadcastChannel notifications are not committed records. A successful
    transition is not permission to skip the durable write or epoch fence. *)

(** The largest counter value. Epochs, generations and sequences stop here. *)
val max_counter : int
type sender = { service : string; sender : string; incarnation : int; session : int }
type publication = { source : sender; sequence : int; payload : string }
type event = Register of string | Handshake of sender | Send of publication
type message = { epoch : int; publication : publication }
type session = { source : sender; next_sequence : int option }
type view = { epoch : int; services : string list; sessions : session list;
              messages : message list }
type error = Invalid_name | Invalid_counter of string | Invalid_epoch
  | Stale_epoch of { current : int; actual : int }
  | Unknown_service of string | Missing_handshake | Stale_session
  | Out_of_order of { expected : int; actual : int }
  | Conflicting_replay | Counter_exhausted
type t

(** Make an empty projection. The epoch is zero and no name is registered. *)
val create : unit -> t

(** Give the epoch, the registered names, the active sessions and the
    committed messages of this projection. *)
val view : t -> view
(** Epochs range from zero through [max_counter]. A strictly newer epoch
    clears active sessions and retains registered names and committed
    messages. A service operation itself requires a positive epoch. *)
val observe_epoch : int -> t -> (t, error) result
(** Names use nonempty ASCII letters, digits, underscore or hyphen.
    Registering an existing name is idempotent. A handshake generation is
    ordered lexicographically by (incarnation, session), both positive and
    bounded. Its exact replay preserves sequence progress. A newer generation
    replaces that sender's session and starts at sequence one.

    Sends require the current epoch and exact active generation. Each sender
    sequence is contiguous from one. An identical replay in that session
    produces no delivery; a changed payload for the same identity is refused.
    Old sessions and epochs are refused even for previously accepted sends.
    New messages are returned once per in-memory projection as [Some]. This
    does not claim exactly-once processing across restart. *)
val apply : epoch:int -> event -> t -> (t * message option, error) result
(** Reconstruct durable registration and message history, then observe the
    snapshot's current epoch, invalidating stale handshakes when necessary.
    Input order is durable log order, already validated by [Feed] or an
    equivalent sequence validator. Global sequence gaps are outside this API.
    Restore returns state only and performs no external message delivery. *)
val restore : epoch:int -> (int * event) list -> (t, error) result

(** Give the text of an error for a log row. *)
val error_text : error -> string
