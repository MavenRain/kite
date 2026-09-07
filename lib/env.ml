(* lib/env.ml:  the term environment of brief 3.3.  It holds an
   association list of Ident.t to scheme, the current level, and the
   interfaces loaded from a .coi file (brief 3.9).  The whole record is a
   VALUE:  every extension returns a new environment, because lib/ holds
   no cell to write into (dev/house.sh:131).

   D-B-44:  the loaded interface rides here as the export list it is,
   that is a name and the scheme that name exports, so lib/env.ml does
   not depend on lib/iface.ml.  lib/iface.ml of round B3 reads a .coi
   file into an Iface.t and hands this module the export list, so the
   dependency runs one way only.

   The level is the let depth of Algorithm W (D-B-7).  A binding raises
   it, and generalization keeps every variable whose level is above the
   level the binding returns to. *)

type export = { xname : Ident.t;  xscheme : Types.scheme }

type loaded = { mname : string;  exports : export list }

type t =
  { terms : (Ident.t * Types.scheme) list;
    level : int;
    modules : loaded list
  }

let empty : t = { terms = [];  level = 0;  modules = [] }

let level (e : t) : int = e.level

(* A let raises the level, infers the right-hand side, and generalizes
   back at the level it came from (D-B-7). *)
let deeper (e : t) : t = { e with level = e.level + 1 }

let extend (x : Ident.t) (sc : Types.scheme) (e : t) : t =
  { e with terms = (x, sc) :: e.terms }

let extend_all (bs : (Ident.t * Types.scheme) list) (e : t) : t =
  List.fold_left (fun acc (x, sc) -> extend x sc acc) e bs

let lookup (x : Ident.t) (e : t) : Types.scheme option =
  List.find_map
    (fun (y, sc) -> if Ident.equal x y then Some sc else None)
    e.terms

(* The bindings in DECLARATION order, which is the order the .scheme
   golden of brief 3.13 and the val lines of a .coi file read. *)
let bindings (e : t) : (Ident.t * Types.scheme) list = List.rev e.terms

let add_module (m : loaded) (e : t) : t = { e with modules = m :: e.modules }

let modules (e : t) : loaded list = List.rev e.modules

(* The exported scheme of a name, taken over every loaded interface.  An
   import whose name matches one is checked against it, and a difference
   is IfaceMismatch (D-B-15).  The last declaration of a name is visible,
   as it is in the provider's own term environment. *)
let export (x : Ident.t) (e : t) : Types.scheme option =
  List.find_map
    (fun (m : loaded) ->
      List.find_map
        (fun (v : export) ->
          if Ident.equal x v.xname then Some v.xscheme else None)
        (List.rev m.exports))
    e.modules

let export_of (name : Ident.t) (sc : Types.scheme) : export =
  { xname = name;  xscheme = sc }

let loaded_of (name : string) (xs : export list) : loaded =
  { mname = name;  exports = xs }
