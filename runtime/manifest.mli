(** Native M2 manifest descriptions. Source elaboration and indexed proofs
    are separate stages. Replica bounds here are checked numeric limits. *)
type workload = private {
  name : string;
  replicas : int;
  bound : int;
  tolerate_hidden : bool;
}
type binding = private { name : string; target : string }
type t = private
  | Deployment of workload
  | Stateful_set of workload
  | Named_service of binding
  | Freeze_drain of binding
type denial = No_eligible_nodes
type error =
  | Invalid_name
  | Invalid_bound
  | Invalid_replicas
  | Not_a_workload
  | Admit_denied of denial
  | Scheduling_error of Taint.error

(** Describe a stateless workload. The name uses ASCII letters, digits,
    underscore or hyphen, and holds at most 64 characters. The bound is from
    zero through 64. The replica count is from zero through the bound. *)
val deployment : name:string -> replicas:int -> bound:int ->
  tolerate_hidden:bool -> (t, error) result

(** Describe a workload with stable identities and volumes. The name, the
    bound and the replica count obey the [deployment] limits. *)
val stateful_set : name:string -> replicas:int -> bound:int ->
  tolerate_hidden:bool -> (t, error) result

(** Describe a named service that binds a name to a target workload. Both
    names obey the [deployment] name rules. *)
val service : name:string -> target:string -> (t, error) result

(** Describe a freeze drain policy that binds a name to a target workload.
    Both names obey the [deployment] name rules. *)
val drain : name:string -> target:string -> (t, error) result

(** Give the declared name of a description. *)
val name : t -> string

(** Give the requested replica count of a workload. The value is the
    requested count and never the bound. A named service and a freeze drain
    have no replica count, so both give [None]. *)
val replicas : t -> int option

(** Names are [manifest:ordinal], independent of placement, node and epoch.
    A snapshot passed to [admit] must be scoped to this one workload.
    Multiple workload namespaces cannot share a bare ordinal snapshot. *)
val pod_names : t -> string list

(** StatefulSet volume keys are stable namespace/ordinal pairs suitable
    for [Volume.key]. Scale-down does not delete committed volume history. *)
val volume_keys : t -> (string * int) list

(** Validate the snapshot and produce the existing safe placement plan.
    If the requested replicas exceed retained healthy placements, at least
    one healthy node eligible for new starts must exist. Otherwise return
    [Admit_denied]. Zero replicas require no live node. Reservations still
    delay replacement until both placement and pod locks have disappeared.
    Services and drain policies are descriptions consumed by their own
    adapters, so this placement entry point returns [Not_a_workload]. *)
val admit : Cluster.config -> epoch:int -> observations:Taint.observation list ->
  Cluster.snapshot -> t -> (Cluster.plan, error) result
