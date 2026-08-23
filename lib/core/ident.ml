type t = { name : string; id : int }
type ident = t

(* One counter for the whole process. Centralizing allocation is what makes IDs
   unique, which is what makes hygiene intrinsic rather than a discipline.
   Atomic so that a future multi-domain driver cannot hand out a duplicate ID.
   IDs start at 1; 0 is left unused so that a canonical identifier (numbered from
   0) is never mistaken for the first allocated one while debugging. *)
let counter = Atomic.make 1

let fresh name = { name; id = Atomic.fetch_and_add counter 1 }
let derive ident = fresh ident.name
let derive_as name (_ : t) = fresh name
let name ident = ident.name
let id ident = ident.id

(* Identity is the ID alone; the name is compared only to keep the order total
   and stable for identifiers that were canonicalized separately. *)
let equal a b = Int.equal a.id b.id && String.equal a.name b.name

let compare a b =
  match Int.compare a.id b.id with
  | 0 -> String.compare a.name b.name
  | ordering -> ordering

let hash ident = Hashtbl.hash ident.id
let same_name a b = String.equal a.name b.name
let to_string ident = Printf.sprintf "%s#%d" ident.name ident.id
let pp formatter ident = Format.pp_print_string formatter (to_string ident)

module Key = struct
  type nonrec t = t

  let compare = compare
end

module Set = Set.Make (Key)
module Map = Map.Make (Key)

module Canon = struct
  type policy = Keep_names | Erase_names

  type t = {
    policy : policy;
    table : (int, ident) Hashtbl.t;  (** keyed by original ID *)
    mutable next : int;  (** next canonical slot *)
  }

  (* One name for every erased binder: canonical identifiers are distinguished by
     slot, and a positional name keeps the erasure visible when printed. *)
  let erased_name = "v"

  let create ?(policy = Erase_names) () =
    { policy; table = Hashtbl.create 32; next = 0 }

  let policy state = state.policy

  let fix state ident =
    if Hashtbl.mem state.table ident.id then
      invalid_arg
        (Printf.sprintf "Ident.Canon.fix: %s is already canonicalized"
           (to_string ident));
    Hashtbl.add state.table ident.id ident

  let canonical state ident =
    match Hashtbl.find_opt state.table ident.id with
    | Some canonical -> canonical
    | None ->
        let slot = state.next in
        state.next <- slot + 1;
        let name =
          match state.policy with
          | Keep_names -> ident.name
          | Erase_names -> erased_name
        in
        let canonical = { name; id = slot } in
        Hashtbl.add state.table ident.id canonical;
        canonical

  let count state = state.next

  let list ?policy idents =
    let state = create ?policy () in
    List.map (canonical state) idents
end
