(** Pure deterministic placement planning over a host-provided snapshot.
    This module does not acquire browser locks, read IndexedDB, or execute
    commands. The host must supply one consistent snapshot and execute an
    authorized plan under the same leader transaction or equivalent guard. *)

type phase = Active | Frozen

type node = {
  node_id : string;
  incarnation : int;
  lock_held : bool;
  heartbeat : int;
  phase : phase;
}

type placement = { pod : int; owner : string; incarnation : int }

type snapshot = {
  now : int;
  epoch : int;
  nodes : node list;
  placements : placement list;
  pod_locks : int list;
}

type command = Start of placement | Stop of placement

type config
type plan

type error =
  | Invalid_config
  | Invalid_desired
  | Invalid_snapshot of string
  | Stale_epoch of { expected : int; actual : int }

(** Both limits must be positive. Time uses nonnegative logical integer
    ticks. A node expires when [now - heartbeat >= timeout]. *)
val config : timeout:int -> max_pods:int -> (config, error) result

(** Restrict new starts to these unique, valid node identifiers. Existing
    healthy placements remain retained, including placements on excluded
    nodes. An empty list permits no new starts. The default [config] has no
    such restriction. Repeated restrictions intersect, so later visibility
    filters cannot widen a caller's existing policy. Snapshot health, epoch and reservation checks still
    apply. This permits a NoSchedule taint without evicting running pods. *)
val with_start_nodes : config -> string list -> (config, error) result

(** [epoch] must be positive and equal to the observed snapshot epoch.
    [desired] must be in [0, max_pods]; desired pod names are the integers
    from zero through [desired - 1]. Invalid snapshots are refused before
    planning: epochs and incarnations must be positive, times and pod names
    nonnegative, and heartbeats cannot be in the future. Node identifiers
    and placement owners must be nonempty ASCII letters, digits, [_], or
    [-]. Node identifiers, placement pod names, and lock names are unique
    within their respective lists. A placement may name a departed node.

    An active node holding its node lock with an unexpired heartbeat is
    eligible. Existing placements are retained only on an eligible owner
    with the same incarnation and a desired pod name. Other placements
    yield stops in ascending pod order. Any observed placement or pod lock
    reserves its name for this entire plan, including a placement being
    stopped. A later snapshot must confirm release before replacement.

    Missing unreserved names are started in ascending pod order on the
    eligible node with the least retained plus newly planned load, breaking
    ties by lexicographic node identifier. No eligible nodes means no
    starts. All stops precede all starts. *)
val reconcile :
  config -> epoch:int -> desired:int -> snapshot -> (plan, error) result

(** Inspect planned commands; this does not authorize their execution. *)
val commands : plan -> command list

(** Give the leader epoch of this plan. *)
val epoch : plan -> int

(** Refuse a nonpositive current epoch or one different from the plan's
    epoch, with the plan epoch as [expected]. This is a pure comparison:
    the host must prevent leadership changes between authorization and
    command execution and must enforce the pod lock protocol. *)
val authorize : current_epoch:int -> plan -> (command list, error) result
