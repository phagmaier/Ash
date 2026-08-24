open Ash_core
open Ash_runtime

type t = {
  registry : Primitives.t;
  ground : Level.t;
  mutable materialized_count : int;
  mutable upper_levels : Level.t list;
}

type materialized_runtime_size = {
  upper_levels : int;
  global_binding_cells : int;
  evaluator_group_cells : int;
  reachable_words : int;
}

type expanded_semantic_size = {
  depth : int;
  program_nodes : int;
  interpreter_nodes_per_level : int;
  total_nodes : int;
}

type size_metrics = {
  materialized_runtime : materialized_runtime_size;
  expanded_semantic : expanded_semantic_size;
}

let registry (tower : t) = tower.registry
let ground (tower : t) = tower.ground
let run (tower : t) term = Level.run tower.ground term
let materialized (tower : t) = tower.materialized_count

let find_level (tower : t) index =
  if index < 0 then None
  else if index = 0 then Some tower.ground
  else List.find_opt (fun level -> Level.index level = index) tower.upper_levels

(* The evaluator cannot see this library, so each level's machine is told what
   its neighbours are as it is created: the level above is a thunk, because
   materializing it eagerly would defeat laziness, and the level below is a
   machine that necessarily already exists. This is the whole coupling between
   the tower and the runtime — reifier application and [reflect] read it, and
   nothing else does. *)
let rec install_levels (tower : t) level =
  let index = Level.index level in
  Machine.set_levels (Level.machine level)
    {
      Machine.level_index = index;
      level_above = (fun () -> Level.machine (materialize_above tower ~level:index));
      level_below =
        (match find_level tower (index - 1) with
        | Some below -> Some (Level.machine below)
        | None -> None);
      (* Read when asked, never stored: materialization is lazy, so the depth a
         level reports has to be the tower's depth now rather than its depth when
         the level was created. *)
      level_tower_depth = (fun () -> materialized tower);
    }

and materialize_above (tower : t) ~level =
  if level < 0 then
    invalid_arg "Tower.materialize_above: level must be non-negative";
  let highest = materialized tower in
  if level > highest then
    invalid_arg "Tower.materialize_above: source level is not materialized";
  match find_level tower (level + 1) with
  | Some existing -> existing
  | None ->
      let created = Level.create ~index:(level + 1) ~registry:tower.registry () in
      tower.upper_levels <- created :: tower.upper_levels;
      tower.materialized_count <- tower.materialized_count + 1;
      install_levels tower created;
      created

let create ?registry () =
  let registry =
    match registry with Some registry -> registry | None -> Primitives.create ()
  in
  let ground = Level.create ~index:0 ~registry () in
  let tower = { registry; ground; materialized_count = 0; upper_levels = [] } in
  install_levels tower ground;
  tower

let size_metrics (tower : t) ~depth ~program ~interpreter =
  let upper_levels = materialized tower in
  if depth < 0 then invalid_arg "Tower.size_metrics: depth must be non-negative";
  if depth < upper_levels then
    invalid_arg "Tower.size_metrics: depth is below the materialized tower";
  let global_binding_cells =
    List.fold_left
      (fun total level -> total + Level.global_binding_count level)
      0 tower.upper_levels
  in
  let evaluator_group_cells =
    List.fold_left
      (fun total level -> total + Level.evaluator_group_cell_count level)
      0 tower.upper_levels
  in
  let program_nodes = Core.node_count program in
  let interpreter_nodes_per_level = Core.node_count interpreter in
  {
    materialized_runtime =
      {
        upper_levels;
        global_binding_cells;
        evaluator_group_cells;
        reachable_words = Obj.reachable_words (Obj.repr tower);
      };
    expanded_semantic =
      {
        depth;
        program_nodes;
        interpreter_nodes_per_level;
        total_nodes = program_nodes + (depth * interpreter_nodes_per_level);
      };
  }
