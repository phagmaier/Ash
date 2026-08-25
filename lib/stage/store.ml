open Ash_core

type slot =
  | Held of Value.value
  | Residual of { target : Ident.t; reference : Value.value }

type binding = { cell : Value.cell; binder : Ident.t; slot : slot }

type snapshot = binding list

type state = {
  mutable bindings : binding list;
  mutable assigned : Ident.Set.t;
  mutable holdable : bool Ident.Map.t;
}

let state = { bindings = []; assigned = Ident.Set.empty; holdable = Ident.Map.empty }

let reset ~assigned =
  state.bindings <- [];
  state.assigned <- assigned;
  state.holdable <- Ident.Map.empty

let assigned binder = Ident.Set.mem binder state.assigned

(* {1 Eligibility} *)

(* Everything that could reach a cell without the specializer executing the
   reach. Each clause is one way the specializer stops being the only thing that
   can touch the binding:

   - the binder free in a [Lam] or [LetRec] body: that closure can be reified
     into residual code, inlined into a specialization point's shared body, or
     called from a dynamic position, and each of those runs the read or the
     write in the residual program's order rather than in ours;
   - a mention inside a [Quote]: quoted code is data the program may [run] later;
   - a [NamedVar] spelling the binder's printed name: [NamedVar] searches the
     environment by name and finds the cell without mentioning its identity, so
     identity-based reasoning cannot see the reach;
   - a [Reifier] node anywhere in the scope: applying one hands the whole calling
     environment to the level above, which may evaluate anything in it.

   Deliberately syntactic and deliberately over-approximate. A binder any clause
   catches is not refused — it is residualized, which is what the store does
   whenever proof is unavailable. *)
let rec at_risk ~binder ~name node =
  match Core.shape node with
  | Core.Lit _ | Core.Var _ -> false
  | Core.NamedVar found -> String.equal found name
  | Core.Reifier _ -> true
  | Core.Quote quoted -> Ident.Set.mem binder (Alpha.free_idents quoted)
  | Core.Lam lambda ->
      Ident.Set.mem binder (Alpha.free_idents node)
      || at_risk ~binder ~name lambda.Core.lam_body
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      List.exists
        (fun rec_binding ->
          let lambda =
            Core.of_lambda ~span:rec_binding.Core.rec_span rec_binding.Core.rec_lambda
          in
          Ident.Set.mem binder (Alpha.free_idents lambda)
          || at_risk ~binder ~name rec_binding.Core.rec_lambda.Core.lam_body)
        rec_bindings
      || at_risk ~binder ~name rec_body
  | Core.App _ | Core.Let _ | Core.If _ | Core.Set _ ->
      List.exists (at_risk ~binder ~name) (Core.children node)

(* Memoized on the binder alone: identities are allocated once, so a binder has
   exactly one scope and the answer cannot depend on where it is asked. *)
let holdable ~binder ~scope =
  match Ident.Map.find_opt binder state.holdable with
  | Some decided -> decided
  | None ->
      let decided = not (at_risk ~binder ~name:(Ident.name binder) scope) in
      state.holdable <- Ident.Map.add binder decided state.holdable;
      decided

(* {1 The store itself} *)

(* Keyed by the cell, never by the binder. Two names for one cell are one place
   — that is what aliasing is — and one binder evaluated twice is two places,
   which is what a local [var] inside a recursive function needs. *)
let find cell =
  List.find_opt (fun binding -> Value.same_cell binding.cell cell) state.bindings

let slot cell = Option.map (fun binding -> binding.slot) (find cell)

let without cell =
  List.filter (fun binding -> not (Value.same_cell binding.cell cell)) state.bindings

let put cell binder slot = state.bindings <- { cell; binder; slot } :: without cell

let track_held cell ~binder value = put cell binder (Held value)

let track_residual cell ~binder ~target ~reference =
  put cell binder (Residual { target; reference })

let release cell = state.bindings <- without cell

(* A held cell {e is} the abstract store's storage: the specializer's own cell
   carries the current contents, so an ordinary [Var] read finds them with no
   store lookup at all and the pure fragment pays nothing for mutation existing.
   The store's own entry records that the cell is held and by which binder,
   which is what forking, joining, and promotion need. *)
let write cell value =
  match find cell with
  | Some { binder; slot = Held _; _ } ->
      Value.fill_cell cell value;
      put cell binder (Held value)
  | Some { slot = Residual _; _ } | None -> invalid_arg "Store.write: not a held binding"

(* Giving up on a held binding: from here the residual program owns the
   contents, so the cell stands for [target] and every later read of it yields
   [reference]. The caller has already emitted the binding of [target]. *)
let promote cell ~target ~reference =
  match find cell with
  | Some { binder; slot = Held _; _ } ->
      Value.fill_cell cell reference;
      put cell binder (Residual { target; reference })
  | Some { slot = Residual _; _ } | None ->
      invalid_arg "Store.promote: not a held binding"

let held_value = function Held value -> Some value | Residual _ -> None

let holds_static () =
  List.exists (fun binding -> Option.is_some (held_value binding.slot)) state.bindings

let written_holds written =
  List.filter_map
    (fun binding ->
      if Ident.Set.mem binding.binder written then
        Option.map
          (fun value -> (binding.cell, binding.binder, value))
          (held_value binding.slot)
      else None)
    state.bindings

(* {1 Forking and joining} *)

let snapshot () = state.bindings

let contents_of = function
  | Held value -> value
  | Residual { reference; _ } -> reference

let restore taken =
  state.bindings <- taken;
  List.iter (fun binding -> Value.fill_cell binding.cell (contents_of binding.slot)) taken

let same_slot a b =
  match (a, b) with
  | Held x, Held y -> Value.equal x y
  | Residual x, Residual y -> Ident.equal x.target y.target
  | (Held _ | Residual _), _ -> false

let slot_in taken cell =
  Option.map
    (fun binding -> binding.slot)
    (List.find_opt (fun binding -> Value.same_cell binding.cell cell) taken)

(* The join of two forked stores.

   Only the bindings that were live before the fork survive: a cell a branch
   created is out of scope at the merge point, so carrying it past would be
   describing a place nothing can name any more. What does survive has to be
   described the same way by both branches — the specializer must not hold a
   value that depends on which branch ran. Everything either branch assigns has
   been promoted before the fork, so agreement is the ordinary outcome;
   disagreement is the case where proof is unavailable, and the caller refuses
   there rather than picking a side. *)
let join ~before ~left ~right =
  let rec merge acc = function
    | [] -> Ok (List.rev acc)
    | binding :: rest -> (
        match (slot_in left binding.cell, slot_in right binding.cell) with
        | Some in_left, Some in_right when same_slot in_left in_right ->
            merge ({ binding with slot = in_left } :: acc) rest
        | Some _, Some _ | Some _, None | None, Some _ | None, None -> Error binding)
  in
  merge [] before

let bindings_of taken = taken
let binder_of binding = binding.binder
let slot_of binding = binding.slot
