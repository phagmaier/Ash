open Ash_core
open Ash_runtime
open Ash_tower

open Ash_stage

let label = 34

(* Enough to see what the specializer gave up on without a runaway program
   burying the rest of the report. *)
let shown_generalizations = 6

let line name value = Printf.sprintf "  %-*s%s\n" (label - 2) name value
let count name n = line name (string_of_int n)

let plural n singular = if n = 1 then singular else singular ^ "s"

let nodes n = Printf.sprintf "%d %s" n (plural n "node")

let outcome_line name outcome ~against =
  match against with
  | None -> line name (Metrics.outcome_to_string outcome)
  | Some reference ->
      let note =
        match Metrics.agreement reference outcome with
        | Metrics.Agrees -> "  (agrees)"
        | Metrics.Differs -> "  (DIFFERS)"
        | Metrics.Incomparable -> "  (carries identity: not comparable across runs)"
      in
      line name (Metrics.outcome_to_string outcome ^ note)

let output_line name = function
  | [] -> line name "none"
  | events -> line name (String.concat "; " (List.map Io.event_to_string events))

let association name = function
  | [] -> line name "none"
  | pairs ->
      line name
        (String.concat ", " (List.map (fun (key, n) -> Printf.sprintf "%s %d" key n) pairs))

let section title = Printf.sprintf "\n%s\n" title

let levels_summary levels =
  String.concat ", "
    (List.map
       (fun { Metrics.index; steps; cell_dereferences = _ } ->
         Printf.sprintf "level %d: %d" index steps)
       levels)

let dereferences_summary levels =
  String.concat ", "
    (List.map
       (fun { Metrics.index; steps = _; cell_dereferences } ->
         Printf.sprintf "level %d: %d" index cell_dereferences)
       levels)

let to_string (metrics : Metrics.t) =
  let buffer = Buffer.create 2048 in
  let add = Buffer.add_string buffer in
  let sizes = metrics.Metrics.sizes in
  let expanded = sizes.Tower.expanded_semantic in
  let materialized = sizes.Tower.materialized_runtime in
  let tower = metrics.Metrics.tower in

  add (Printf.sprintf "== collapse: %s ==\n\n" metrics.Metrics.name);
  add (line "Program:" (Printf.sprintf "%s, %s" metrics.Metrics.file
                          (nodes expanded.Tower.program_nodes)));
  add (count "Tower depth:" tower.Metrics.depth);
  add
    (line "Interposed interpreter:"
       (Printf.sprintf "%s per level" (nodes expanded.Tower.interpreter_nodes_per_level)));

  add (section "Sizes");
  add
    (line "Expanded semantic tower:"
       (Printf.sprintf "%s  (%d + %d x %d)" (nodes expanded.Tower.total_nodes)
          expanded.Tower.program_nodes expanded.Tower.depth
          expanded.Tower.interpreter_nodes_per_level));
  add
    (line "Materialized representation:"
       (Printf.sprintf "%d upper %s, %d global cells, %d group cells"
          materialized.Tower.upper_levels
          (plural materialized.Tower.upper_levels "level")
          materialized.Tower.global_binding_cells
          materialized.Tower.evaluator_group_cells));
  (match metrics.Metrics.residual with
  | Ok residual -> add (line "Residual:" (nodes residual.Metrics.residue.Residue.nodes))
  | Error _ -> add (line "Residual:" "none: specialization failed"));

  add (section "Interpretation left in the residual");
  (match metrics.Metrics.residual with
  | Error error -> add (line "Not measured:" (Error.to_string error))
  | Ok residual ->
      let residue = residual.Metrics.residue in
      add
        (line "Interpreter residue:"
           (nodes (Residue.interpreter_residue residue ~own:metrics.Metrics.file)));
      add (count "Surviving eval-cell derefs:" residue.Residue.eval_cell_dereferences);
      add (count "Constructor dispatch sites:" residue.Residue.dispatch_sites);
      add (count "NamedVar lookups residualized:" residue.Residue.named_var_lookups);
      add (count "Evaluator calls:" residue.Residue.evaluator_calls);
      association "Reflection boundaries:" residue.Residue.reflection_boundaries |> add;
      association "Residual nodes by origin:" residue.Residue.nodes_by_origin |> add);

  add (section "Work");
  add (count "Source run:" metrics.Metrics.source.Metrics.steps);
  add
    (line
       (Printf.sprintf "Tower run (depth %d):" tower.Metrics.depth)
       (Printf.sprintf "%d  (%s)" tower.Metrics.run.Metrics.steps
          (levels_summary tower.Metrics.levels)));
  add (line "Tower eval-cell derefs:" (dereferences_summary tower.Metrics.levels));
  add (count "Tower open-group derefs:" tower.Metrics.open_dereferences);
  add (count "Tower constructor dispatches:" tower.Metrics.dispatches);
  add (count "Specialization:" metrics.Metrics.specialization.Metrics.steps);
  add
    (line "Specialization points:"
       (Printf.sprintf "%d  (%d call%s)"
          metrics.Metrics.specialization.Metrics.specialization_points
          metrics.Metrics.specialization.Metrics.memoized_calls
          (if metrics.Metrics.specialization.Metrics.memoized_calls = 1 then ""
           else "s")));
  add (count "Generalizations:" metrics.Metrics.specialization.Metrics.generalizations);
  (* Why, not just how many: §7.5 asks for every generalization to be
     instrumented because each one is a place the specializer admitted it could
     not decide something. *)
  List.iteri
    (fun index reason ->
      if index < shown_generalizations then
        add
          (line
             (Printf.sprintf "  %s(%s):" reason.Specialize.gen_function
                reason.Specialize.gen_parameter)
             (Printf.sprintf "%s, %s"
                (Specialize.pressure_name reason.Specialize.gen_pressure)
                (Specialize.pressure_message reason.Specialize.gen_pressure))))
    metrics.Metrics.specialization.Metrics.generalization_reasons;
  (match
     List.length metrics.Metrics.specialization.Metrics.generalization_reasons
     - shown_generalizations
   with
  | remaining when remaining > 0 ->
      add (line "  " (Printf.sprintf "and %d more" remaining))
  | _ -> ());
  (match metrics.Metrics.residual with
  | Ok residual -> add (count "Residual run:" residual.Metrics.run.Metrics.steps)
  | Error _ -> add (line "Residual run:" "none"));

  add (section "Outcome");
  let source = metrics.Metrics.source.Metrics.outcome in
  add (outcome_line "Source:" source ~against:None);
  add (outcome_line "Tower:" tower.Metrics.run.Metrics.outcome ~against:(Some source));
  (match metrics.Metrics.residual with
  | Ok residual ->
      add (outcome_line "Residual:" residual.Metrics.run.Metrics.outcome ~against:(Some source))
  | Error error -> add (line "Residual:" ("not produced: " ^ Error.to_string error)));
  add (output_line "Source output:" metrics.Metrics.source.Metrics.output);
  add (output_line "Specialization output:" metrics.Metrics.specialization.Metrics.output);
  (match metrics.Metrics.residual with
  | Ok residual -> add (output_line "Residual output:" residual.Metrics.run.Metrics.output)
  | Error _ -> ());

  (* Said in the report rather than in a decision record nobody reads beside the
     numbers: the residual above is not a collapsed tower. *)
  add (section "Basis");
  add "  The residual is the program specialized on its own, which is the pure
";
  add "  fragment of spec 7.4 step 1. Specializing away a level's interposed
";
  add "  evaluator is static reflective collapse, task 9.1; the tower figures
";
  add "  above are the measured cost that collapse is set against, not a cost
";
  add "  this residual removed.
";
  Buffer.contents buffer
