open Ash_core
open Ash_runtime
open Ash_tower
open Ash_collapse

let failures = ref 0
let check name ok =
  if not ok then (incr failures; Printf.printf "FAIL %s\n" name)

let measure name source =
  Metrics.measure ~depth:1 ~file:"dynamic_reflection.ash" ~name
    (Metrics.Surface source)

let check_case name expected source =
  let measured = measure name source in
  let classified = Classification.classify measured in
  check (name ^ ": class") (classified.kind = expected);
  match measured.residual with
  | Error error ->
      check (name ^ ": residual produced") false;
      Printf.printf "%s\n" (Error.to_string error)
  | Ok residual ->
      check (name ^ ": same value or failure")
        (Metrics.agreement measured.tower.run.outcome residual.run.outcome
         = Metrics.Agrees);
      check (name ^ ": exact output")
        (List.equal Io.event_equal measured.tower.run.output residual.run.output);
      check (name ^ ": compilation output empty")
        (measured.specialization.output = []);
      let survey = Residue.survey ~env:measured.globals residual.term in
      check (name ^ ": direct AST walk nodes")
        (survey.nodes = residual.residue.nodes
         && survey.nodes = Core.node_count residual.term);
      check (name ^ ": constructor case totals")
        (List.fold_left
           (fun total (_, _, count) -> total + count)
           0 survey.cases_by_origin
         = survey.nodes);
      check (name ^ ": direct AST walk counters")
        (survey.eval_cell_dereferences = residual.residue.eval_cell_dereferences
         && survey.dispatch_sites = residual.residue.dispatch_sites
         && survey.named_var_lookups = residual.residue.named_var_lookups
         && survey.reflection_boundaries = residual.residue.reflection_boundaries);
      check (name ^ ": site totals")
        (List.length survey.sites
         = survey.eval_cell_dereferences + survey.evaluator_calls
           + survey.dispatch_sites + survey.named_var_lookups
           + List.fold_left (fun total (_, n) -> total + n) 0
               survey.reflection_boundaries)

let runtime_flag value =
  Printf.sprintf
    "let flag = deref(cell_new(%s))\n\
     meta_with(eval = if flag then fn(e, r, k) -> { println('trace); eval(e, r, k) } else eval) { 1 + 2 }"
    (if value then "true" else "false")

let partial value =
  Printf.sprintf
    "let x = 40 + 2\n\
     let flag = deref(cell_new(%s))\n\
     [x, meta_with(eval = if flag then fn(e, r, k) -> { println('trace); eval(e, r, k) } else eval) { 1 + 2 }]"
    (if value then "true" else "false")

let persistent_choice =
  "let flag = deref(cell_new(true))\n\
   if flag then up { let base = eval; eval := fn(e, r, k) -> { println('trace); base(e, r, k) } } else ()\n\
   1 + 2"

let stacked_persistent_choice =
  "up { let base = eval; eval := fn(e, r, k) -> { print(\"p\"); base(e, r, k) } }\n\
   let flag = deref(cell_new(true))\n\
   if flag then up { let base = eval; eval := fn(e, r, k) -> { print(\"q\"); base(e, r, k) } } else ()\n\
   1 + 2"

let persistent_observes_trivial_let =
  "let flag = deref(cell_new(true))\n\
   if flag then up { let base = eval; eval := fn(e, r, k) -> { println(head(code_view(e))); base(e, r, k) } } else ()\n\
   let x = 1\n\
   x"

let scoped_observes_trivial_let =
  "let flag = deref(cell_new(true))\n\
   meta_with(eval = if flag then fn(e, r, k) -> { println(head(code_view(e))); eval(e, r, k) } else eval) {\n\
     let x = 1\n\
     x\n\
   }"

let () =
  check_case "invariant full" Classification.Depth_invariant_full "40 + 2";
  check_case "depth sensitive full" Classification.Depth_sensitive_full
    "tower_depth() + 1";
  check_case "partial true" Classification.Partial (partial true);
  check_case "partial false" Classification.Partial (partial false);
  check_case "static capture at a dynamic scoped boundary"
    Classification.Partial
    "let x = 40 + 2\n\
     let flag = deref(cell_new(true))\n\
     meta_with(eval = if flag then fn(e, r, k) -> { println('trace); eval(e, r, k) } else eval) { x + 1 }";
  check_case "opaque true" Classification.Opaque (runtime_flag true);
  check_case "opaque false" Classification.Opaque (runtime_flag false);
  check_case "scoped evaluator observes a trivial let" Classification.Opaque
    scoped_observes_trivial_let;
  check_case "persistent conditional" Classification.Opaque persistent_choice;
  check_case "known and dynamic persistent stack" Classification.Opaque
    stacked_persistent_choice;
  check_case "dynamic evaluator observes a trivial let" Classification.Opaque
    persistent_observes_trivial_let;
  let named =
    Metrics.measure ~depth:1 ~file:"dynamic_reflection.ash"
      ~name:"dynamic name lookup"
      (Metrics.Core_notation
         "(let x (lit 3) (if (app (var deref) (app (var cell_new) (lit #t))) (named-var \"x\") (lit 0)))")
  in
  let named_class = Classification.classify named in
  check "dynamic NamedVar precheck is conservative"
    (named_class.precheck.dynamic_named_var
     && named_class.kind = Classification.Partial);
  let depth_zero =
    Metrics.measure ~depth:0 ~file:"dynamic_reflection.ash"
      ~name:"dynamic materialization at depth zero"
      (Metrics.Surface (runtime_flag true))
  in
  check "depth zero reports runtime materialization separately"
    (depth_zero.sizes.Tower.expanded_semantic.depth = 0
     && depth_zero.sizes.Tower.materialized_runtime.upper_levels >= 1);
  if !failures <> 0 then exit 1
