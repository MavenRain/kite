(** Visibility observations restrict new placement without evicting healthy
    existing work. This pure module does not observe browser lifecycle events. *)

type visibility = Visible | Hidden

type observation = {
  node_id : string;
  incarnation : int;
  visibility : visibility;
}

type error =
  | Invalid_node_id of string
  | Invalid_incarnation of { node_id : string; incarnation : int }
  | Duplicate_observation of string
  | Unknown_node of string
  | Stale_incarnation of { node_id : string; expected : int; actual : int }
  | Cluster_error of Cluster.error

(** Install a new-start allowlist from these observations and delegate to
    [Cluster.reconcile]. Each observation must name a node in the snapshot
    at exactly its current incarnation. Invalid identifiers, nonpositive
    incarnations, duplicate node observations, unknown nodes, and incarnation
    mismatches refuse the whole plan. A missing observation permits no new
    starts on that node, including when [tolerate_hidden] is true.

    Visible nodes pass the visibility filter; hidden nodes pass it only with
    explicit tolerance. Cluster snapshot validation, epoch fencing, health,
    placement reservation, and load balancing still apply. Frozen, expired,
    and lockless nodes cannot receive starts. A healthy existing placement
    remains retained regardless of its owner's visibility or missing report.
    The host must guard observation freshness and execution of the plan. *)
val reconcile :
  Cluster.config -> epoch:int -> desired:int ->
  observations:observation list -> tolerate_hidden:bool -> Cluster.snapshot ->
  (Cluster.plan, error) result
