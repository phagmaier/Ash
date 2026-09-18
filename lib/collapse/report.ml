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

let to_string ?(show_residual = false) (metrics : Metrics.t) =
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

  if show_residual then (
    add (section "Residual Core");
    match metrics.Metrics.residual with
    | Ok residual ->
        add (Ash_syntax.Core_printer.to_string residual.Metrics.term);
        add "\n"
    | Error error -> add (line "Not produced:" (Error.to_string error)));

  add (section "Interpretation left in the residual");
  (match metrics.Metrics.residual with
  | Error error -> add (line "Not measured:" (Error.to_string error))
  | Ok residual ->
      let residue = residual.Metrics.residue in
      add
        (line "Interpreter residue:"
           (nodes (Residue.interpreter_residue residue ~own:metrics.Metrics.file)));
      add
        (line "Interpreter residue cases:"
           (match Residue.foreign_cases residue ~own:metrics.Metrics.file with
           | [] -> "none"
           | cases ->
               String.concat ", "
                 (List.map
                    (fun (file, kind, n) ->
                      Printf.sprintf "%s/%s %d" file kind n)
                    cases)));
      add (count "Surviving eval-cell derefs:" residue.Residue.eval_cell_dereferences);
      add (count "Constructor dispatch sites:" residue.Residue.dispatch_sites);
      add (count "NamedVar lookups residualized:" residue.Residue.named_var_lookups);
      add (count "Evaluator calls:" residue.Residue.evaluator_calls);
      add (count "Control operation sites:" residue.Residue.control_sites);
      association "Reflection boundaries:" residue.Residue.reflection_boundaries |> add;
      association "Residual nodes by origin:" residue.Residue.nodes_by_origin |> add;
      List.iter
        (fun (site : Residue.site) ->
          add
            (line ("  " ^ site.kind ^ ":")
               (Printf.sprintf "%s — %s" (Span.to_string site.span) site.reason)))
        residue.Residue.sites);

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
  if show_residual then
    (match metrics.Metrics.residual with
    | Ok residual ->
        let verdict =
          match
            Metrics.agreement tower.Metrics.run.Metrics.outcome
              residual.Metrics.run.Metrics.outcome
          with
          | Metrics.Agrees -> "agrees"
          | Metrics.Differs -> "DIFFERS"
          | Metrics.Incomparable -> "carries identity: not comparable across runs"
        in
        add (line "Tower vs residual:" verdict)
    | Error _ -> ());
  add (output_line "Source output:" metrics.Metrics.source.Metrics.output);
  add (output_line "Specialization output:" metrics.Metrics.specialization.Metrics.output);
  (* Beside the output line, never inside it: the compile-time channel is what
     §D7 offers instead of folding [print], so a report that hid it would leave
     the honest alternative invisible. *)
  add (output_line "Specialization log:" metrics.Metrics.specialization.Metrics.log);
  (match metrics.Metrics.residual with
  | Ok residual -> add (output_line "Residual output:" residual.Metrics.run.Metrics.output)
  | Error _ -> ());

  if show_residual then (
    let bytes events =
      String.concat ""
        (List.filter_map (function Io.Wrote text -> Some text | Io.Read _ -> None) events)
      |> fun text -> Constant.to_string (Constant.Str text)
    in
    add (line "Tower output bytes:" (bytes tower.Metrics.run.Metrics.output));
    match metrics.Metrics.residual with
    | Ok residual ->
        add (line "Residual output bytes:" (bytes residual.Metrics.run.Metrics.output))
    | Error _ -> ());

  let classification = Classification.classify metrics in
  add (section "Classification (conservative)");
  add (line "Collapse class:" (Classification.name classification.kind));
  add (line "Tower/residual agreement:"
         (if classification.tower_residual_agree then "yes, value and output"
          else "not established"));
  List.iter (fun reason -> add (line "Reason:" reason)) classification.reasons;
  let pre = classification.precheck in
  add (line "Depth observation:"
         (if pre.observes_depth then "possible" else "none found"));
  add (line "Dynamic NamedVar:"
         (if pre.dynamic_named_var then "possible" else "none found"));
  add (line "Conditional reflection:"
         (if pre.reflection_under_dynamic_condition then "possible" else "none found"));

  add (section "Basis");
  add "  Classification is conservative: full classes describe this measured\n";
  add "  residual and syntactic pre-check, not all possible inputs.\n";
  add "  Runtime evaluator choices retain their source-located reflective region.\n";
  Buffer.contents buffer

(* A dependency-free JSON renderer. The schema keeps raw measurements as
   numbers, and carries the same sites and explanations as the human report. *)
type json = Jobject of (string * json) list | Jarray of json list
          | Jstring of string | Jint of int | Jbool of bool

let json_escape value =
  let out = Buffer.create (String.length value + 8) in
  Buffer.add_char out '"';
  String.iter
    (function
      | '"' -> Buffer.add_string out "\\\""
      | '\\' -> Buffer.add_string out "\\\\"
      | '\n' -> Buffer.add_string out "\\n"
      | '\r' -> Buffer.add_string out "\\r"
      | '\t' -> Buffer.add_string out "\\t"
      | c when Char.code c < 32 -> Buffer.add_string out (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char out c)
    value;
  Buffer.add_char out '"';
  Buffer.contents out

let rec render_json = function
  | Jobject fields ->
      "{" ^ String.concat ","
        (List.map (fun (key, value) -> json_escape key ^ ":" ^ render_json value) fields)
      ^ "}"
  | Jarray values -> "[" ^ String.concat "," (List.map render_json values) ^ "]"
  | Jstring value -> json_escape value
  | Jint value -> string_of_int value
  | Jbool value -> string_of_bool value

let pairs_json pairs =
  Jobject (List.map (fun (name, count) -> (name, Jint count)) pairs)

let cases_json cases =
  Jarray
    (List.map
       (fun (file, kind, count) ->
         Jobject
           [ ("origin", Jstring file);
             ("case", Jstring kind);
             ("count", Jint count) ])
       cases)

let events_json events =
  Jarray (List.map (fun event -> Jstring (Io.event_to_string event)) events)

let run_json (run : Metrics.run) =
  Jobject
    [ ("outcome", Jstring (Metrics.outcome_to_string run.outcome));
      ("steps", Jint run.steps);
      ("output", events_json run.output) ]

let to_json (metrics : Metrics.t) =
  let classed = Classification.classify metrics in
  let pre = classed.precheck in
  let sizes = metrics.sizes in
  let expanded = sizes.Tower.expanded_semantic in
  let materialized = sizes.Tower.materialized_runtime in
  let residual_json =
    match metrics.residual with
    | Error error ->
        Jobject [ ("produced", Jbool false); ("error", Jstring (Error.to_string error)) ]
    | Ok residual ->
        let residue = residual.residue in
        Jobject
          [ ("produced", Jbool true);
            ("core", Jstring (Ash_syntax.Core_printer.to_string residual.term));
            ("run", run_json residual.run);
            ("nodes", Jint residue.nodes);
            ("generated_nodes", Jint residue.generated_nodes);
            ("interpreter_nodes", Jint (Residue.interpreter_residue residue ~own:metrics.file));
            ("nodes_by_origin", pairs_json residue.nodes_by_origin);
            ("cases_by_origin", cases_json residue.cases_by_origin);
            ("interpreter_cases",
              cases_json (Residue.foreign_cases residue ~own:metrics.file));
            ("eval_cell_dereferences", Jint residue.eval_cell_dereferences);
            ("evaluator_calls", Jint residue.evaluator_calls);
            ("dispatch_sites", Jint residue.dispatch_sites);
            ("named_var_lookups", Jint residue.named_var_lookups);
            ("control_sites", Jint residue.control_sites);
            ("reflection_boundaries", pairs_json residue.reflection_boundaries);
            ("sites", Jarray
               (List.map
                  (fun (site : Residue.site) ->
                    Jobject
                      [ ("kind", Jstring site.kind);
                        ("source", Jstring (Span.to_string site.span));
                        ("reason", Jstring site.reason) ])
                  residue.sites)) ]
  in
  render_json
    (Jobject
       [ ("schema", Jint 1);
         ("name", Jstring metrics.name);
         ("file", Jstring metrics.file);
         ("depth", Jint metrics.tower.depth);
         ("classification",
           Jobject
             [ ("class", Jstring (Classification.name classed.kind));
               ("conservative", Jbool classed.conservative);
               ("tower_residual_agree", Jbool classed.tower_residual_agree);
               ("reasons", Jarray (List.map (fun reason -> Jstring reason) classed.reasons));
               ("precheck",
                 Jobject
                   [ ("depth_observation", Jbool pre.observes_depth);
                     ("dynamic_named_var", Jbool pre.dynamic_named_var);
                     ("reflection_under_dynamic_condition",
                       Jbool pre.reflection_under_dynamic_condition) ]) ]);
         ("sizes",
           Jobject
             [ ("program_nodes", Jint expanded.program_nodes);
               ("interpreter_nodes_per_level", Jint expanded.interpreter_nodes_per_level);
               ("expanded_semantic_nodes", Jint expanded.total_nodes);
               ("materialized_upper_levels", Jint materialized.upper_levels);
               ("materialized_global_cells", Jint materialized.global_binding_cells);
               ("materialized_group_cells", Jint materialized.evaluator_group_cells);
               ("materialized_reachable_words", Jint materialized.reachable_words) ]);
         ("source", run_json metrics.source);
         ("tower",
           Jobject
             [ ("run", run_json metrics.tower.run);
               ("dispatches", Jint metrics.tower.dispatches);
               ("open_dereferences", Jint metrics.tower.open_dereferences);
               ("named_var_lookups", Jint metrics.tower.named_var_lookups);
               ("levels",
                 Jarray
                   (List.map
                      (fun (level : Metrics.level_cost) ->
                        Jobject
                          [ ("index", Jint level.index);
                            ("steps", Jint level.steps);
                            ("cell_dereferences", Jint level.cell_dereferences) ])
                      metrics.tower.levels)) ]);
         ("specialization",
           Jobject
             [ ("steps", Jint metrics.specialization.steps);
               ("dispatches", pairs_json metrics.specialization.dispatches);
               ("total_dispatches", Jint metrics.specialization.total_dispatches);
               ("named_var_lookups", Jint metrics.specialization.named_var_lookups);
               ("open_dereferences", Jint metrics.specialization.open_dereferences);
               ("specialization_points", Jint metrics.specialization.specialization_points);
               ("memoized_calls", Jint metrics.specialization.memoized_calls);
               ("generalizations", Jint metrics.specialization.generalizations);
               ("generalization_reasons",
                 Jarray
                   (List.map
                      (fun (reason : Specialize.generalization) ->
                        Jobject
                          [ ("function", Jstring reason.gen_function);
                            ("parameter", Jstring reason.gen_parameter);
                            ("position", Jint reason.gen_position);
                            ("pressure", Jstring (Specialize.pressure_name reason.gen_pressure));
                            ("reason", Jstring (Specialize.pressure_message reason.gen_pressure));
                            ("source", Jstring (Span.to_string (Span.source_span reason.gen_site))) ])
                      metrics.specialization.generalization_reasons));
               ("output", events_json metrics.specialization.output);
               ("log", events_json metrics.specialization.log) ]);
         ("residual", residual_json) ])
