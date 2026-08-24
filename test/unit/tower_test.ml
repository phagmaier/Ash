(* Lazy level materialization (to-do task 4.1). *)

open Ash_core
open Ash_runtime
open Ash_tower

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_int name expected actual =
  if not (Int.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %d\n  actual:   %d\n" name expected actual)

let global_named level name =
  match Env.lookup_by_name (Level.global level) name with
  | Env.Name_found (identity, cell) -> (identity, cell)
  | Env.Name_unbound | Env.Name_ambiguous _ ->
      failwith (Printf.sprintf "test fixture has no unique `%s` global" name)

let lit number = Core.lit ~span:Span.unknown (Constant.Num number)

let test_lazy_materialization () =
  let tower = Tower.create () in
  check_int "a new tower has no upper level" 0 (Tower.materialized tower);
  check "level 1 does not exist before reflection"
    (Option.is_none (Tower.find_level tower 1));
  check "ordinary code runs on ground"
    (Value.equal (Value.Num 7) (Tower.run tower (lit 7)));
  check_int "ordinary code creates no upper level" 0 (Tower.materialized tower);

  let level_1 = Tower.materialize_above tower ~level:0 in
  check_int "first reflection creates one upper level" 1 (Tower.materialized tower);
  check_int "the first upper level is relative level 1" 1 (Level.index level_1);
  check "the materialized level is discoverable"
    (match Tower.find_level tower 1 with
    | Some found -> found == level_1
    | None -> false);
  check "repeating reflection reuses the level"
    (Tower.materialize_above tower ~level:0 == level_1);
  check_int "repeated reflection creates nothing" 1 (Tower.materialized tower);

  let level_2 = Tower.materialize_above tower ~level:1 in
  check_int "nested reflection creates only the next level" 2
    (Tower.materialized tower);
  check_int "the nested upper level is relative level 2" 2 (Level.index level_2)

let test_level_independence () =
  let registry = Primitives.create () in
  let tower = Tower.create ~registry () in
  let level_0 = Tower.ground tower in
  let level_1 = Tower.materialize_above tower ~level:0 in
  let level_2 = Tower.materialize_above tower ~level:1 in
  check "each level installs its own globals on its own machine"
    (Machine.global_env (Level.machine level_0) == Level.global level_0
    && Machine.global_env (Level.machine level_1) == Level.global level_1
    && Machine.global_env (Level.machine level_2) == Level.global level_2);

  let plus_0, plus_cell_0 = global_named level_0 "+" in
  let plus_1, plus_cell_1 = global_named level_1 "+" in
  let plus_2, plus_cell_2 = global_named level_2 "+" in
  check "cloned global binders keep their printed name"
    (Ident.same_name plus_0 plus_1 && Ident.same_name plus_1 plus_2);
  check "every level gets a fresh hygienic global identity"
    (not (Ident.equal plus_0 plus_1)
    && not (Ident.equal plus_1 plus_2)
    && not (Ident.equal plus_0 plus_2));
  check "every level gets a fresh global cell"
    (not (Value.same_cell plus_cell_0 plus_cell_1)
    && not (Value.same_cell plus_cell_1 plus_cell_2)
    && not (Value.same_cell plus_cell_0 plus_cell_2));
  check "cloned globals share primitive values and their IO stream"
    (match (Value.cell_contents plus_cell_0, Value.cell_contents plus_cell_1) with
    | Some left, Some right -> Value.equal left right
    | None, _ | _, None -> false);

  let base = Machine.current_eval (Level.machine level_1) in
  Machine.set_eval (Level.machine level_1) (fun machine node env k ->
      match Core.shape node with
      | Core.Lit _ -> k (Value.Num 99)
      | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          base machine node env k);
  check "replacing level 1's eval cell changes level 1"
    (Value.equal (Value.Num 99) (Level.run level_1 (lit 1)));
  check "level 0 owns an independent eval cell"
    (Value.equal (Value.Num 1) (Level.run level_0 (lit 1)));
  check "level 2 owns an independent eval cell"
    (Value.equal (Value.Num 1) (Level.run level_2 (lit 1)))

let test_sizes () =
  let tower = Tower.create () in
  let program = Core.app ~span:Span.unknown ~func:(lit 0) ~args:[ lit 1; lit 2 ] in
  let interpreter =
    Core.let_ ~span:Span.unknown ~binder:(Ident.fresh "x") ~value:(lit 3)
      ~body:(lit 4)
  in
  let before = Tower.size_metrics tower ~depth:5 ~program ~interpreter in
  check_int "materialized size starts with no upper records" 0
    before.materialized_runtime.upper_levels;
  check_int "no upper global cells exist before reflection" 0
    before.materialized_runtime.global_binding_cells;
  check_int "no upper evaluator cells exist before reflection" 0
    before.materialized_runtime.evaluator_group_cells;
  check_int "expanded size records program nodes" 4
    before.expanded_semantic.program_nodes;
  check_int "expanded size records interpreter nodes" 3
    before.expanded_semantic.interpreter_nodes_per_level;
  check_int "expanded semantic size is depth times interpreter plus program" 19
    before.expanded_semantic.total_nodes;

  let (_ : Level.t) = Tower.materialize_above tower ~level:0 in
  let after = Tower.size_metrics tower ~depth:5 ~program ~interpreter in
  check_int "actual size records exactly one upper level" 1
    after.materialized_runtime.upper_levels;
  check_int "the level owns one cloned primitive-global frame" Primitives.count
    after.materialized_runtime.global_binding_cells;
  check_int "the level owns the three evaluator-group cells" 3
    after.materialized_runtime.evaluator_group_cells;
  check "actual reachable representation grows when a level is materialized"
    (after.materialized_runtime.reachable_words
    > before.materialized_runtime.reachable_words);
  check_int "materialization does not change conceptual expanded size" 19
    after.expanded_semantic.total_nodes

let test_invalid_materialization () =
  let tower = Tower.create () in
  check "reflection cannot skip an unmaterialized source level"
    (match Tower.materialize_above tower ~level:1 with
    | _ -> false
    | exception Invalid_argument _ -> true);
  check "size depth cannot contradict existing materialization"
    (let (_ : Level.t) = Tower.materialize_above tower ~level:0 in
     match Tower.size_metrics tower ~depth:0 ~program:(lit 0) ~interpreter:(lit 0) with
     | _ -> false
     | exception Invalid_argument _ -> true)

let () =
  test_lazy_materialization ();
  test_level_independence ();
  test_sizes ();
  test_invalid_materialization ();
  if !failures > 0 then (
    Printf.printf "%d tower assertion(s) failed\n" !failures;
    exit 1)
