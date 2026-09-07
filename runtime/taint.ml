(* A conservative visibility filter for new starts. Cluster owns health. *)
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

module Nodes = Map.Make (String)
module Seen = Set.Make (String)
let ( let* ) = Result.bind

let valid_node_id name =
  let valid_char c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9') || c = '_' || c = '-' in
  String.length name > 0 && String.for_all valid_char name

let allowlist ~tolerate_hidden nodes observations =
  let known = List.fold_left (fun known (node : Cluster.node) ->
      Nodes.add node.node_id node known) Nodes.empty nodes in
  let add accumulated (observation : observation) =
    let* (seen, allowed) = accumulated in
    match () with
    | () when not (valid_node_id observation.node_id) ->
      Error (Invalid_node_id observation.node_id)
    | () when observation.incarnation <= 0 ->
      Error (Invalid_incarnation {node_id = observation.node_id;
                                 incarnation = observation.incarnation})
    | () when Seen.mem observation.node_id seen ->
      Error (Duplicate_observation observation.node_id)
    | () ->
      Option.fold ~none:(Error (Unknown_node observation.node_id))
        ~some:(fun (node : Cluster.node) ->
          if node.incarnation <> observation.incarnation then
            Error (Stale_incarnation {node_id = observation.node_id;
              expected = node.incarnation; actual = observation.incarnation})
          else
            let permitted = match observation.visibility with
              | Visible -> true
              | Hidden -> tolerate_hidden in
            Ok (Seen.add observation.node_id seen,
              if permitted then observation.node_id :: allowed else allowed))
        (Nodes.find_opt observation.node_id known) in
  Result.map (fun (_seen, allowed) -> List.rev allowed)
    (List.fold_left add (Ok (Seen.empty, [])) observations)

let reconcile config ~epoch ~desired ~observations ~tolerate_hidden
    (snapshot : Cluster.snapshot) =
  let* allowed = allowlist ~tolerate_hidden snapshot.nodes observations in
  let* filtered = Result.map_error (fun error -> Cluster_error error)
      (Cluster.with_start_nodes config allowed) in
  Result.map_error (fun error -> Cluster_error error)
    (Cluster.reconcile filtered ~epoch ~desired snapshot)
