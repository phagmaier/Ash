open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_tower

type outcome = Answered of Value.value | Failed of Error.t

let outcome_to_string = function
  | Answered value -> Value.to_string value
  | Failed error -> "failure: " ^ Error.to_string error

type agreement = Agrees | Differs | Incomparable

(* Identity-bearing values cannot be compared between two runs: each run
   allocated its own. Lists are transparent, so a list is comparable exactly
   when everything in it is. *)
let rec comparable_across_runs = function
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.Code _ | Value.Primitive _ ->
      true
  | Value.List items -> List.for_all comparable_across_runs items
  | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Environment _
  | Value.Cell _ ->
      false

let agreement a b =
  match (a, b) with
  | Answered x, Answered y ->
      if not (comparable_across_runs x && comparable_across_runs y) then Incomparable
      else if Value.equal x y then Agrees
      else Differs
  | Failed x, Failed y ->
      if
        Error.cause_equal x.Error.cause y.Error.cause
        && Span.equal x.Error.span y.Error.span
      then Agrees
      else Differs
  | (Answered _ | Failed _), _ -> Differs

type run = { outcome : outcome; steps : int; output : Io.event list }

type level_cost = { index : int; steps : int; cell_dereferences : int }

type tower = {
  depth : int;
  run : run;
  levels : level_cost list;
  open_dereferences : int;
  dispatches : int;
  named_var_lookups : int;
}

type specialization = {
  steps : int;
  dispatches : (string * int) list;
  total_dispatches : int;
  named_var_lookups : int;
  open_dereferences : int;
  specialization_points : int;
  memoized_calls : int;
  generalizations : int;
  generalization_reasons : Ash_stage.Specialize.generalization list;
  output : Io.event list;
}

type residual = { term : Core.t; residue : Residue.t; run : run }

type t = {
  name : string;
  file : string;
  program : Core.t;
  globals : Value.env;
  sizes : Tower.size_metrics;
  source : run;
  tower : tower;
  specialization : specialization;
  residual : (residual, Error.t) result;
}

type program = Surface of string | Core_notation of string

let attempt f = match f () with value -> Answered value | exception Error.Ash_error e -> Failed e

(* Each phase starts from a cleared stream and zeroed counters, so a number is
   that phase's alone rather than the total since the tower was created. *)
let start ~registry ~machines =
  Io.clear (Primitives.io registry);
  Primitives.reset_open_dereferences registry;
  List.iter Machine.reset_counters machines

let measure ?(depth = 1) ?budget ~file ~name program =
  if depth < 0 then invalid_arg "Metrics.measure: depth must be non-negative";
  let registry = Primitives.create () in
  let io = Primitives.io registry in
  let tower = Tower.create ~registry () in
  let ground = Tower.ground tower in
  let env = Level.global ground in
  let named =
    Ident.Set.fold
      (fun ident collected -> (Ident.name ident, ident) :: collected)
      (Env.idents env) []
  in
  let term =
    match program with
    | Core_notation text -> Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text
    | Surface source ->
        Desugar.program ~scope:(Desugar.scope_of_globals named) (Parser.program ~file source)
  in

  (* 1. What the program means: the ground evaluator, no tower, no staging. *)
  let source_machine = Evaluator.machine () in
  start ~registry ~machines:[ source_machine ];
  let source_outcome = attempt (fun () -> Evaluator.run source_machine ~env term) in
  let source =
    { outcome = source_outcome; steps = Machine.steps source_machine; output = Io.events io }
  in

  (* 2. What it costs to run under a tower of interposed interpreters. The
     levels are materialized first so that every level's counters can be zeroed
     before the run rather than during it. *)
  Depth.materialize tower ~depth;
  let levels =
    List.filter_map (Tower.find_level tower) (List.init (Tower.materialized tower + 1) Fun.id)
  in
  let machines = List.map Level.machine levels in
  start ~registry ~machines;
  let tower_outcome = attempt (fun () -> Tower.run tower term) in
  let level_costs =
    List.map
      (fun level ->
        let machine = Level.machine level in
        {
          index = Level.index level;
          steps = Machine.steps machine;
          cell_dereferences = Machine.cell_dereferences machine;
        })
      levels
  in
  let tower_run =
    {
      depth;
      run =
        {
          outcome = tower_outcome;
          (* Every level's calls, not level 0's: the machinery above the program
             is the part the collapser exists to remove, so it is not left out of
             the total that measures it. The breakdown is in [levels]. *)
          steps = List.fold_left (fun total (level : level_cost) -> total + level.steps) 0 level_costs;
          output = Io.events io;
        };
      levels = level_costs;
      open_dereferences = Primitives.open_dereferences registry;
      dispatches = List.fold_left (fun total m -> total + Machine.total_dispatches m) 0 machines;
      named_var_lookups =
        List.fold_left (fun total m -> total + Machine.named_var_lookups m) 0 machines;
    }
  in

  (* 3. Specialization itself, and what it left behind. *)
  let staging_machine = Ash_stage.Staged_eval.machine ~mode:Ash_stage.Mode.Lift () in
  start ~registry ~machines:[ staging_machine ];
  let configured = Ash_stage.Specialize.budget () in
  Option.iter Ash_stage.Specialize.set_budget budget;
  let staged =
    match Ash_stage.Staged_eval.run staging_machine ~env term with
    | Value.Code residual -> Ok residual
    | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
    | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Environment _
    | Value.Cell _ | Value.Primitive _ ->
        (* [run] in lift mode reifies its answer, so this is unreachable; it is
           written out rather than assumed so the match stays exhaustive. *)
        Error
          (Error.make ~phase:Error.Stage ~span:(Core.span term) ~level:0
             (Error.Unsupported
                { what = "a specialization that did not produce code"; by = "the collapse report" }))
    | exception Error.Ash_error error -> Error error
  in
  Ash_stage.Specialize.set_budget configured;
  let specialization =
    {
      steps = Machine.steps staging_machine;
      dispatches = Machine.dispatches staging_machine;
      total_dispatches = Machine.total_dispatches staging_machine;
      named_var_lookups = Machine.named_var_lookups staging_machine;
      open_dereferences = Primitives.open_dereferences registry;
      specialization_points = Ash_stage.Specialize.points_created ();
      memoized_calls = Ash_stage.Specialize.memoized_calls ();
      generalizations = Ash_stage.Specialize.generalization_count ();
      generalization_reasons = Ash_stage.Specialize.generalizations ();
      output = Io.events io;
    }
  in

  (* 4. What the collapsed program costs, and what interpretation is left in it. *)
  let residual =
    Result.map
      (fun term ->
        let machine = Evaluator.machine () in
        start ~registry ~machines:[ machine ];
        let outcome = attempt (fun () -> Evaluator.run machine ~env term) in
        {
          term;
          residue = Residue.survey ~env term;
          run = { outcome; steps = Machine.steps machine; output = Io.events io };
        })
      staged
  in
  {
    name;
    file;
    program = term;
    globals = env;
    sizes =
      Tower.size_metrics tower ~depth ~program:term ~interpreter:(Depth.interposed_term ());
    source;
    tower = tower_run;
    specialization;
    residual;
  }
