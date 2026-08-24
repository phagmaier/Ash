open Ash_core
open Ash_runtime

type t = {
  index : int;
  global : Value.env;
  machine : Machine.t;
  global_binding_count : int;
}

let create ~index ~registry () =
  if index < 0 then invalid_arg "Level.create: index must be non-negative";
  let bindings = Primitives.globals registry in
  let global = Env.extend bindings Value.empty_env in
  let machine = Evaluator.machine () in
  Machine.set_global_env machine global;
  { index; global; machine; global_binding_count = List.length bindings }

let index level = level.index
let global level = level.global
let machine level = level.machine
let run level term = Evaluator.run level.machine ~env:level.global term
let global_binding_count level = level.global_binding_count
let evaluator_group_cell_count level = Machine.group_cell_count level.machine
