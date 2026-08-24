open Ash_core

type cont = Value.value -> Value.answer
type args_cont = Value.value list -> Value.answer

type evaluator_mode = Ground | Staged_identity | Staged_lift

type t = {
  mutable eval_cell : eval_fn;
  mutable apply_cell : apply_fn;
  mutable eval_list_cell : eval_list_fn;
  mutable global_env : Value.env;
  mutable levels : levels option;
  mutable meta_eval : Value.cell option;
  mutable meta_apply : Value.cell option;
  mutable steps : int;
  mutable eval_calls : int;
  mutable apply_calls : int;
  mutable eval_list_calls : int;
  mutable cell_dereferences : int;
  mutable named_var_lookups : int;
  dispatches : int array;
  evaluator_mode : evaluator_mode;
}

and levels = {
  level_index : int;
  level_above : unit -> t;
  level_below : t option;
  level_tower_depth : unit -> int;
}

and eval_fn = t -> Core.t -> Value.env -> cont -> Value.answer
and apply_fn = t -> call_site:Span.t -> Value.value -> Value.value list -> cont -> Value.answer
and eval_list_fn = t -> Core.t list -> Value.env -> args_cont -> Value.answer

let create ?(evaluator_mode = Ground) ~eval ~apply ~eval_list () =
  {
    eval_cell = eval;
    apply_cell = apply;
    eval_list_cell = eval_list;
    global_env = Value.empty_env;
    levels = None;
    meta_eval = None;
    meta_apply = None;
    steps = 0;
    eval_calls = 0;
    apply_calls = 0;
    eval_list_calls = 0;
    cell_dereferences = 0;
    named_var_lookups = 0;
    dispatches = Array.make Core.kind_count 0;
    evaluator_mode;
  }

let evaluator_mode machine = machine.evaluator_mode

(* The dereference points. Reading the cell here, on every call, is what makes a
   replacement take effect from the next step rather than the next top-level
   evaluation. *)

let eval machine node env k =
  machine.steps <- machine.steps + 1;
  machine.eval_calls <- machine.eval_calls + 1;
  machine.cell_dereferences <- machine.cell_dereferences + 1;
  let current = machine.eval_cell in
  current machine node env k

let apply machine ~call_site callee arguments k =
  machine.steps <- machine.steps + 1;
  machine.apply_calls <- machine.apply_calls + 1;
  machine.cell_dereferences <- machine.cell_dereferences + 1;
  let current = machine.apply_cell in
  current machine ~call_site callee arguments k

let eval_list machine nodes env k =
  machine.steps <- machine.steps + 1;
  machine.eval_list_calls <- machine.eval_list_calls + 1;
  machine.cell_dereferences <- machine.cell_dereferences + 1;
  let current = machine.eval_list_cell in
  current machine nodes env k

let set_eval machine f = machine.eval_cell <- f
let set_apply machine f = machine.apply_cell <- f
let set_eval_list machine f = machine.eval_list_cell <- f
let current_eval machine = machine.eval_cell
let current_apply machine = machine.apply_cell
let current_eval_list machine = machine.eval_list_cell
let group_cell_count _machine = 3

(* The tower installs this when it materializes a level. A machine without it is
   the whole tower it belongs to: it is the base program's level, and there is
   no level for a reifier to run at. *)
let set_levels machine value = machine.levels <- Some value
let levels machine = machine.levels

let level machine =
  match machine.levels with None -> 0 | Some levels -> levels.level_index

let above machine =
  match machine.levels with
  | None -> None
  | Some levels -> Some (levels.level_above ())

let below machine =
  match machine.levels with None -> None | Some levels -> levels.level_below

let tower_depth machine =
  match machine.levels with None -> 0 | Some levels -> levels.level_tower_depth ()

(* {1 The Ash-visible face of the group cells}

   [up] binds [eval] and [apply] to cells (spec §5.2), and a cell is an ordinary
   Ash value: the meta level reads the current evaluator out of one, and writes a
   replacement into it. Nothing here is a second mechanism — the cell {e is} the
   group cell, seen from Ash rather than from OCaml.

   Two properties have to hold, and they decide the shape of the code below.

   Materializing a cell must be observationally inert: [up] asks for both cells
   whether or not its body touches them, so a level whose cell exists but still
   holds the evaluator it started with runs exactly the host function it ran
   before, with the same counters and the same host stack behaviour. That is the
   [==] fast path.

   And the replacement is written at level [n + 1], so level [n + 1]'s machine is
   what evaluates it. Running it on the machine whose cell holds it would make it
   its own interpreter and diverge on the first step. *)

let meta_fail ~call_site ~level cause =
  Error.raise_cause ~phase:Error.Evaluate ~span:call_site ~level cause

let meta_type_error ~call_site ~level ~expected value =
  meta_fail ~call_site ~level
    (Error.Unexpected { found = Value.type_phrase value; expected })

let meta_arity_error ~call_site ~level ~name arguments =
  meta_fail ~call_site ~level
    (Error.Arity_error
       { callee = Some name; expected = "3"; actual = List.length arguments })

(* The evaluator that was installed when the cell was created, wrapped as a
   value. It closes over that function rather than over the cell, because
   [let base = eval; eval := wrap(base)] must reach the evaluator that was there:
   a wrapper that re-read the cell would call itself. *)
let default_eval_value machine base =
  Value.Primitive
    {
      Value.prim_name = "eval";
      prim_arity = Value.Exactly 3;
      prim_class = Effect_class.Reflection;
      prim_impl =
        (fun ~call_site ~level ~apply ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
          match args with
          | [ code; environment; cont ] -> (
              match (code, environment) with
              | Value.Code node, Value.Environment env ->
                  base machine node env (fun value ->
                      apply ~call_site cont [ value ] k)
              | Value.Code _, other ->
                  meta_type_error ~call_site ~level ~expected:"an environment" other
              | other, _ -> meta_type_error ~call_site ~level ~expected:"code" other)
          | _ -> meta_arity_error ~call_site ~level ~name:"eval" args);
    }

let default_apply_value machine base =
  Value.Primitive
    {
      Value.prim_name = "apply";
      prim_arity = Value.Exactly 3;
      prim_class = Effect_class.Reflection;
      prim_impl =
        (fun ~call_site ~level ~apply ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
          match args with
          | [ callee; arguments; cont ] -> (
              match arguments with
              (* The call site of the original application is not among the three
                 arguments spec §5.2 gives [apply], so a replacement that falls
                 back to the default attributes it to where the fallback was
                 written. Declared boundary, not an oversight: widening the cell's
                 protocol to carry a span would change what a meta level has to
                 accept. *)
              | Value.List spread ->
                  base machine ~call_site callee spread (fun value ->
                      apply ~call_site cont [ value ] k)
              | other ->
                  meta_type_error ~call_site ~level ~expected:"a list of arguments"
                    other)
          | _ -> meta_arity_error ~call_site ~level ~name:"apply" args);
    }

let meta_eval_cell machine =
  match machine.meta_eval with
  | Some cell -> cell
  | None ->
      let base = machine.eval_cell in
      let default = default_eval_value machine base in
      let cell = Value.cell default in
      machine.meta_eval <- Some cell;
      machine.eval_cell <-
        (fun machine node env k ->
          match Value.cell_contents cell with
          (* Untouched: run exactly what this level ran before the cell existed. *)
          | Some replacement when replacement == default -> base machine node env k
          | Some replacement ->
              let upper =
                match above machine with Some upper -> upper | None -> machine
              in
              let span = Core.span node in
              apply upper ~call_site:span replacement
                [
                  Value.Code node;
                  Value.Environment env;
                  (* This level's continuation, one-shot like every other (§D4).
                     A replacement that never invokes it abandons this level, the
                     same way an unresumed reifier does. *)
                  Value.Continuation
                    (Value.continuation ~capture:span ~level:(level machine) k);
                ]
                (fun answer -> answer)
          (* [Value.cell] creates the cell filled and [open_set] only ever fills
             it, so this is unreachable; falling back keeps it total. *)
          | None -> base machine node env k);
      cell

let meta_apply_cell machine =
  match machine.meta_apply with
  | Some cell -> cell
  | None ->
      let base = machine.apply_cell in
      let default = default_apply_value machine base in
      let cell = Value.cell default in
      machine.meta_apply <- Some cell;
      machine.apply_cell <-
        (fun machine ~call_site callee arguments k ->
          match Value.cell_contents cell with
          | Some replacement when replacement == default ->
              base machine ~call_site callee arguments k
          | Some replacement ->
              let upper =
                match above machine with Some upper -> upper | None -> machine
              in
              apply upper ~call_site replacement
                [
                  callee;
                  Value.List arguments;
                  Value.Continuation
                    (Value.continuation ~capture:call_site ~level:(level machine) k);
                ]
                (fun answer -> answer)
          | None -> base machine ~call_site callee arguments k);
      cell
let set_global_env machine env = machine.global_env <- env
let global_env machine = machine.global_env

let count_dispatch machine shape =
  let index = Core.kind_index shape in
  machine.dispatches.(index) <- machine.dispatches.(index) + 1

let count_named_var_lookup machine =
  machine.named_var_lookups <- machine.named_var_lookups + 1

let steps machine = machine.steps
let eval_calls machine = machine.eval_calls
let apply_calls machine = machine.apply_calls
let eval_list_calls machine = machine.eval_list_calls
let cell_dereferences machine = machine.cell_dereferences
let named_var_lookups machine = machine.named_var_lookups

let dispatches machine =
  List.mapi (fun index name -> (name, machine.dispatches.(index))) Core.kind_names

let total_dispatches machine = Array.fold_left ( + ) 0 machine.dispatches

let reset_counters machine =
  machine.steps <- 0;
  machine.eval_calls <- 0;
  machine.apply_calls <- 0;
  machine.eval_list_calls <- 0;
  machine.cell_dereferences <- 0;
  machine.named_var_lookups <- 0;
  Array.fill machine.dispatches 0 (Array.length machine.dispatches) 0
