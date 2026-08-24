open Ash_core

type cont = Value.value -> Value.answer
type args_cont = Value.value list -> Value.answer

type t = {
  mutable eval_cell : eval_fn;
  mutable apply_cell : apply_fn;
  mutable eval_list_cell : eval_list_fn;
  mutable global_env : Value.env;
  mutable steps : int;
  mutable eval_calls : int;
  mutable apply_calls : int;
  mutable eval_list_calls : int;
  mutable cell_dereferences : int;
  mutable named_var_lookups : int;
  dispatches : int array;
}

and eval_fn = t -> Core.t -> Value.env -> cont -> Value.answer
and apply_fn = t -> call_site:Span.t -> Value.value -> Value.value list -> cont -> Value.answer
and eval_list_fn = t -> Core.t list -> Value.env -> args_cont -> Value.answer

let create ~eval ~apply ~eval_list =
  {
    eval_cell = eval;
    apply_cell = apply;
    eval_list_cell = eval_list;
    global_env = Value.empty_env;
    steps = 0;
    eval_calls = 0;
    apply_calls = 0;
    eval_list_calls = 0;
    cell_dereferences = 0;
    named_var_lookups = 0;
    dispatches = Array.make Core.kind_count 0;
  }

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
