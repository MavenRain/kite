(* A pure protocol for a node's Worker lifecycle. Effects describe browser
   operations; this module performs none. The browser adapter and transaction
   epoch checks belong to later runtime work. *)

type mode = Ready | Frozen

type worker_phase = Starting | Running | Stopping

type worker =
  { pod : int;
    ticket : int;
    incarnation : int;
    phase : worker_phase
  }

type view =
  { node_id : string;
    incarnation : int;
    epoch : int;
    mode : mode;
    node_lock : bool;
    workers : worker list
  }

type event =
  | Node_acquired of int
  | Node_lost of int
  | Observe_epoch of int
  | Start of { epoch : int; pod : int; incarnation : int }
  | Stop of { epoch : int; pod : int; incarnation : int }
  | Pod_lock of { ticket : int; granted : bool }
  | Worker_exited of int
  | Freeze
  | Resume

type action =
  | Acquire_node of int
  | Release_node of int
  | Spawn of worker
  | Terminate of worker
  | Publish_place of worker
  | Release_place of worker
  | Begin_work of worker

type error =
  | Invalid_node
  | Invalid_incarnation
  | Invalid_pod
  | Invalid_epoch
  | Stale_epoch
  | Stale_incarnation
  | Node_unavailable
  | Duplicate_pod
  | Unknown_worker
  | Counter_exhausted

type t

(* Node identifiers are nonempty ASCII letters, digits, underscores or
   hyphens. Incarnations are positive. Creation starts Ready, with no node
   lock, epoch zero, and no Workers. *)
val create : node_id:string -> incarnation:int -> (t, error) result

(* Workers are ordered by pod. Tickets increase across the entire lifetime
   of this state, including freeze and resume. A Stopping slot reserves its
   pod until Worker_exited acknowledges that exact ticket. *)
val view : t -> view

(* A successful step returns actions in execution order. Spawn carries a
   Starting snapshot; Publish_place and Begin_work carry Running snapshots;
   Terminate carries Stopping; Release_place carries the prior Running
   snapshot. The adapter must preserve ticket and incarnation identities.
   A positive Node_acquired callback for a Frozen node or another incarnation
   leaves state unchanged and releases that callback's generation. The host
   must key Release_node by generation so delayed cleanup cannot release a
   newer held lock. Nonpositive generations remain invalid; Node_lost rejects
   stale generations.
   Only a granted Pod_lock for an eligible Starting Worker begins work.
   Advancing the epoch cancels pending starts and preserves Running Workers.
   Freeze stops Workers; Resume requires a newly acquired node lock. *)
val step : t -> event -> (t * action list, error) result
