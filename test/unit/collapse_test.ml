(* Collapse metrics and the report (to-do task 5.4).

   The golden test pins what the report prints. This one pins what the numbers
   mean: that a survey counts what it says it counts, that it identifies callees
   by hygienic identity rather than by printed name, and that the measurement's
   own invariants hold — level 0's cost does not depend on the tower's depth,
   specialization leaves no output, and a fully static program's residual is its
   answer. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_collapse

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_int name ~expected actual =
  if expected <> actual then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %d\n  actual:   %d\n" name expected actual)

let ground () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Core_reader.scope_of_list named in
  (scope, Env.extend globals Value.empty_env)

let read ?(file = "collapse_test.ash") scope text = Core_reader.read ~scope ~file text

(* {1 The residual survey} *)

let test_survey () =
  let scope, env = ground () in
  (* The reader resolves free names, so the fragments under survey are wrapped in
     a binder for the names they mention. The wrapper adds nodes and no
     dereference, dispatch, or boundary of its own. *)
  let survey text =
    Residue.survey ~env (read scope (Printf.sprintf "(lam (x c e r k) %s)" text))
  in

  let plain = survey "(app (var +) (lit 1) (var x))" in
  check_int "a plain call has no eval-cell dereference" ~expected:0
    plain.Residue.eval_cell_dereferences;
  check_int "a plain call is not a dispatch" ~expected:0 plain.Residue.dispatch_sites;
  check_int "a plain call crosses no reflection boundary" ~expected:0
    (List.length plain.Residue.reflection_boundaries);

  let deref = survey "(app (var open_deref) (var c))" in
  check_int "open_deref is an evaluator-group dereference" ~expected:1
    deref.Residue.eval_cell_dereferences;
  check_int "reading a cell is not yet calling what was in it" ~expected:0
    deref.Residue.evaluator_calls;

  (* What an interpreter's own recursive step looks like once written down:
     read the group cell, then apply what came out. *)
  let step = survey "(app (app (var open_deref) (var c)) (var e) (var r) (var k))" in
  check_int "an interpreted step dereferences the group" ~expected:1
    step.Residue.eval_cell_dereferences;
  check_int "an interpreted step is a surviving evaluator call" ~expected:1
    step.Residue.evaluator_calls;

  let dispatch = survey "(app (var code_view) (var e))" in
  check_int "code_view is a constructor dispatch" ~expected:1 dispatch.Residue.dispatch_sites;

  let reflect = survey "(app (var lift) (lit 1))" in
  check "lift is a reflection boundary"
    (List.mem ("lift", 1) reflect.Residue.reflection_boundaries);

  let named_var = survey "(app (var +) (named-var \"x\") (lit 1))" in
  check_int "NamedVar is a residualized lookup by name" ~expected:1
    named_var.Residue.named_var_lookups;

  (* Hygiene: a local binder that prints like a primitive is a different
     identity and denotes nothing. A survey that matched printed names would
     count this one. *)
  let shadowed = survey "(app (lam (open_deref) (app (var open_deref) (lit 1))) (lam (c) (var c)))" in
  check_int "a local binder printing open_deref is not a dereference" ~expected:0
    shadowed.Residue.eval_cell_dereferences;

  (* Provenance: a node keeps the origin of the code it came from, so residue is
     attributable per source even after the specializer has invented nodes. *)
  let scope, _ = ground () in
  let helper = read ~file:"helper.ash" scope "(lam (n) (app (var +) (var n) (lit 1)))" in
  let main = read ~file:"main.ash" scope "(lit 2)" in
  let mixed = Core.app ~span:(Core.span main) ~func:helper ~args:[ main ] in
  let survey_mixed = Residue.survey ~env mixed in
  check "nodes are grouped by origin file"
    (List.mem_assoc "helper.ash" survey_mixed.Residue.nodes_by_origin
    && List.mem_assoc "main.ash" survey_mixed.Residue.nodes_by_origin);
  check_int "residue is what came from some other source" ~expected:5
    (Residue.interpreter_residue survey_mixed ~own:"main.ash");
  check_int "and it is the other way round from the other side" ~expected:2
    (Residue.interpreter_residue survey_mixed ~own:"helper.ash");
  check_int "every node is accounted for exactly once" ~expected:survey_mixed.Residue.nodes
    (List.fold_left (fun total (_, n) -> total + n) 0 survey_mixed.Residue.nodes_by_origin)

(* {1 The measurement} *)

let static_program = "fn fact(n) =\n  if n == 0 then 1 else n * fact(n - 1)\nfact(5)"

let test_measurement () =
  let at depth =
    Metrics.measure ~depth ~file:"m.ash" ~name:"fact" (Metrics.Surface static_program)
  in
  let depth0 = at 0 and depth1 = at 1 and depth2 = at 2 in

  let level0 metrics =
    match metrics.Metrics.tower.Metrics.levels with
    | first :: _ -> first.Metrics.steps
    | [] -> -1
  in
  (* The transparency law, seen through the report's own numbers: interposing an
     interpreter changes who does the base program's steps, not how many. *)
  check "level 0's cost does not depend on depth"
    (level0 depth0 = level0 depth1 && level0 depth1 = level0 depth2);
  check "the tower's total cost does"
    (depth1.Metrics.tower.Metrics.run.Metrics.steps
    > depth0.Metrics.tower.Metrics.run.Metrics.steps
    && depth2.Metrics.tower.Metrics.run.Metrics.steps
       > depth1.Metrics.tower.Metrics.run.Metrics.steps);

  List.iter
    (fun metrics ->
      let name = Printf.sprintf "at depth %d" metrics.Metrics.tower.Metrics.depth in
      check (name ^ ": the tower agrees with the source")
        (Metrics.agreement metrics.Metrics.source.Metrics.outcome
           metrics.Metrics.tower.Metrics.run.Metrics.outcome
        = Metrics.Agrees);
      (* §D7's trap, as a measurement rather than a comment. *)
      check (name ^ ": specialization prints nothing")
        (metrics.Metrics.specialization.Metrics.output = []);
      check (name ^ ": a program the specializer decides generalizes nothing")
        (metrics.Metrics.specialization.Metrics.generalizations = 0
        && metrics.Metrics.specialization.Metrics.generalization_reasons = []);
      match metrics.Metrics.residual with
      | Error error ->
          incr failures;
          Printf.printf "FAIL %s: no residual: %s\n" name (Error.to_string error)
      | Ok residual ->
          check (name ^ ": the residual agrees with the source")
            (Metrics.agreement metrics.Metrics.source.Metrics.outcome
               residual.Metrics.run.Metrics.outcome
            = Metrics.Agrees);
          check (name ^ ": a static program collapses to its answer")
            (residual.Metrics.residue.Residue.nodes = 1);
          check (name ^ ": no interpretation survives")
            (residual.Metrics.residue.Residue.eval_cell_dereferences = 0
            && residual.Metrics.residue.Residue.dispatch_sites = 0
            && residual.Metrics.residue.Residue.named_var_lookups = 0
            && residual.Metrics.residue.Residue.evaluator_calls = 0);
          check (name ^ ": the residual costs less than the source run")
            (residual.Metrics.run.Metrics.steps < metrics.Metrics.source.Metrics.steps))
    [ depth0; depth1; depth2 ];

  (* Sizes are two different measurements with two different units, and §9.1 is
     explicit that reporting one as the other is what invites the objection. *)
  let expanded = depth2.Metrics.sizes.Ash_tower.Tower.expanded_semantic in
  check_int "the expanded semantic size is what an eager tower would hold"
    ~expected:
      (expanded.Ash_tower.Tower.program_nodes
      + (2 * expanded.Ash_tower.Tower.interpreter_nodes_per_level))
    expanded.Ash_tower.Tower.total_nodes;
  let materialized = depth2.Metrics.sizes.Ash_tower.Tower.materialized_runtime in
  check_int "and the materialized one counts levels that exist" ~expected:2
    materialized.Ash_tower.Tower.upper_levels

(* A program outside the fragment is reported, not hidden. Store splitting
   (task 7.2) moved this boundary rather than removing it: an assignment the
   abstract store can place is staged, and one it cannot is still said out
   loud. *)
let test_outside_the_fragment () =
  let metrics =
    Metrics.measure ~file:"m.ash" ~name:"set"
      (Metrics.Core_notation
         "(letrec ((f (lam () (lit 1)))) (let _ (set f (lam () (lit 2))) (app (var f))))")
  in
  check "the source still runs"
    (Metrics.agreement metrics.Metrics.source.Metrics.outcome (Metrics.Answered (Value.Num 2))
    = Metrics.Agrees);
  check "specialization failed rather than guessing"
    (match metrics.Metrics.residual with Error _ -> true | Ok _ -> false);
  check "and the report can still be rendered"
    (String.length (Report.to_string metrics) > 0)

(* Inside the fragment the store proves: the binding is the specializer's alone,
   so the assignment happens at specialization time and nothing of it survives. *)
let test_a_held_store_binding () =
  let metrics =
    Metrics.measure ~file:"m.ash" ~name:"held"
      (Metrics.Core_notation "(let x (lit 1) (let _ (set x (lit 2)) (var x)))")
  in
  match metrics.Metrics.residual with
  | Error error ->
      incr failures;
      Printf.printf "FAIL a held store binding staged: %s\n" (Error.to_string error)
  | Ok residual ->
      check "the residual agrees with the source"
        (Metrics.agreement metrics.Metrics.source.Metrics.outcome
           residual.Metrics.run.Metrics.outcome
        = Metrics.Agrees);
      check "and the assignment left nothing behind"
        (Core.node_count residual.Metrics.term = 1)

(* A measurement under a budget the program exceeds reports the generalization
   and why, and the residual it produces is still correct (task 6.2). *)
let test_generalization_is_reported () =
  let metrics =
    Metrics.measure ~file:"m.ash" ~name:"growing"
      ~budget:
        { Ash_stage.Specialize.max_inline_depth = 5; max_residual_bindings = 10_000 }
      (Metrics.Core_notation
         "(letrec ((rev (lam (xs acc)\n\
         \                (if (app (var empty?) (var xs)) (var acc)\n\
         \                    (app (var rev) (app (var tail) (var xs))\n\
         \                         (app (var cons) (app (var head) (var xs)) (var acc)))))))\n\
         \  (app (var rev) (app (var list) (lit 1) (lit 2) (lit 3) (lit 4) (lit 5) (lit 6))\n\
         \       (lit nil)))")
  in
  (* Both arguments drive this unrolling — the list shrinks while the
     accumulator grows — so one generalization is not enough and the specializer
     gives them up one at a time, leftmost first. That is what "progressively
     mark arguments dynamic" means, and the report has to show both. *)
  check_int "two arguments were given up, one at a time" ~expected:2
    metrics.Metrics.specialization.Metrics.generalizations;
  (match metrics.Metrics.specialization.Metrics.generalization_reasons with
  | [ first; second ] ->
      check "the reasons name the function"
        (String.equal first.Ash_stage.Specialize.gen_function "rev"
        && String.equal second.Ash_stage.Specialize.gen_function "rev");
      check "the list is given up before the accumulator"
        (String.equal first.Ash_stage.Specialize.gen_parameter "xs"
        && String.equal second.Ash_stage.Specialize.gen_parameter "acc");
      check "and both name the budget that forced them"
        (List.for_all
           (fun reason ->
             match reason.Ash_stage.Specialize.gen_pressure with
             | Ash_stage.Specialize.Inline_depth limit -> limit = 5
             | Ash_stage.Specialize.Residual_size _ -> false)
           [ first; second ])
  | [] | [ _ ] | _ :: _ :: _ :: _ ->
      check "exactly two reasons were recorded" false);
  check "a specialization point stood in for the unrolling"
    (metrics.Metrics.specialization.Metrics.specialization_points >= 1);
  check "and the residual still computes the source's answer"
    (match metrics.Metrics.residual with
    | Ok residual ->
        Metrics.agreement metrics.Metrics.source.Metrics.outcome
          residual.Metrics.run.Metrics.outcome
        = Metrics.Agrees
    | Error _ -> false);
  check "the report shows the reason"
    (let text = Report.to_string metrics in
     let contains needle =
       let n = String.length needle and h = String.length text in
       let rec at i = i + n <= h && (String.sub text i n = needle || at (i + 1)) in
       at 0
     in
     contains "rev(xs)" && contains "rev(acc)" && contains "inlining-depth")

(* The default budget is configuration, not run state: a measurement that set
   one must not leave it behind. *)
let test_budget_is_restored () =
  let before = Ash_stage.Specialize.budget () in
  ignore
    (Metrics.measure ~file:"m.ash" ~name:"tiny"
       ~budget:
         { Ash_stage.Specialize.max_inline_depth = 2; max_residual_bindings = 3 }
       (Metrics.Core_notation "(lit 1)"));
  let after = Ash_stage.Specialize.budget () in
  check "the configured budget is restored"
    (after.Ash_stage.Specialize.max_inline_depth
     = before.Ash_stage.Specialize.max_inline_depth
    && after.Ash_stage.Specialize.max_residual_bindings
       = before.Ash_stage.Specialize.max_residual_bindings)

let () =
  test_survey ();
  test_measurement ();
  test_outside_the_fragment ();
  test_a_held_store_binding ();
  test_generalization_is_reported ();
  test_budget_is_restored ();
  if !failures > 0 then (
    Printf.printf "%d collapse assertion(s) failed\n" !failures;
    exit 1)
