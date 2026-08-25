(* Depth results for the pure corpus (to-do task 6.4).

   The claim, from spec §8's Phase 6: [collapse(n, p) ≅α collapse(1, p)] for n
   in 0..5, all p in the pure corpus, after normalization — and, for the
   programs that observe their own depth, §9.3's second class instead: the
   residuals {b differ} across depths, each remaining semantically equivalent
   to what the depth-n tower did.

   {1 The two halves, and why they need different harnesses}

   The syntactic half compares residuals themselves, so every residual must
   name the same globals: cloned globals (ADR 0022) give each environment its
   own identities, and two environments never agree on those. One environment —
   one tower's ground level, created once — is therefore shared by every
   specialization here, through {!Metrics.specialize}, which stages under a
   stated depth without materializing anything. That is faithful by §7.4 step
   1: the pure fragment cannot shift levels, so a configuration contributes
   exactly one thing a program can read — its depth.

   The semantic half asks what each depth's residual {e does}. There the full
   measurement runs — {!Metrics.measure}: source, real interposed tower at the
   stated depth, and residual, each against the measurement's own environment,
   with agreement asserted per class. An invariant sample's residual matches
   both its program and what the tower did — transparency means those two
   agree. A depth-sensitive sample's residual matches what the tower did,
   which at depth n says n while the ground source run says 0; that difference
   is the class, not a failure of it.

   {1 What keeps this honest}

   Two raw specializations of one term are {e not} structurally equal, because
   each allocates fresh binder identities; normalization is therefore
   load-bearing in every cross-depth comparison here, and that is asserted
   rather than assumed. A depth-sensitive sample is required to fail the
   invariance check: a [tower_depth()] residual identical at every depth would
   mean the specializer ignored the configuration it specializes under. And
   depth cost is bounded by counted steps projected through the measured
   per-level multiplier, never wall time; a depth a sample does not fit is
   reported rather than silently skipped. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_collapse

let failures = ref 0
let proved = ref 0
let sensitive_proved = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let label sample suffix = sample ^ ": " ^ suffix

(* {1 Configuration} *)

let file = "depth_invariance.ash"
let max_depth = 5
let reference_depth = 1
let depth_budget = 20_000_000
let per_level_multiplier = 5

let projected_steps ~base ~depth =
  let rec go value remaining =
    if remaining = 0 then value
    else if value > depth_budget then value
    else go (value * per_level_multiplier) (remaining - 1)
  in
  go base depth

(* The one environment every syntactic comparison shares. *)
let registry = Primitives.create ()
let tower = Ash_tower.Tower.create ~registry ()
let env = Ash_tower.Level.global (Ash_tower.Tower.ground tower)
let named =
  Ident.Set.fold
    (fun ident collected -> (Ident.name ident, ident) :: collected)
    (Env.idents env)
    []
let scope = Core_reader.scope_of_list named

let skipped = ref []

(* {1 Samples} *)

type sample = {
  name : string;
  program : Metrics.program;
      (* What {!Metrics.measure} reads against its own tower. *)
  term : Core.t;
      (* The same program read once against the shared environment, so every
         specialization names the same globals. *)
  arguments : string list;
      (* Argument terms for a program whose value is a function of something
         the specializer does not have. *)
}

let core name text arguments =
  {
    name;
    program = Metrics.Core_notation text;
    term = Core_reader.read ~scope ~file text;
    arguments;
  }

let surface name text =
  {
    name;
    program = Metrics.Surface text;
    term = Desugar.program ~scope:(Desugar.scope_of_globals named) (Parser.program ~file text);
    arguments = [];
  }

let closed name text = core name text []

(* {1 The syntactic half: residuals across depths} *)

(* What the program does on the ground evaluator — for budgeting, and as the
   answer a folded specialization must match. Outcomes only; the semantic half
   owns traces. *)
let source_outcome term =
  let machine = Evaluator.machine () in
  match Evaluator.run machine ~env term with
  | value -> Metrics.Answered value
  | exception Error.Ash_error error -> Metrics.Failed error

let base_steps term =
  let machine = Evaluator.machine () in
  match Evaluator.run machine ~env term with
  | _ -> max 1 (Machine.steps machine)
  | exception Error.Ash_error _ -> max 1 (Machine.steps machine)
  (* A failing run still costs steps; that is what the budget projects. *)

(* What one run observed: its answer and what it printed. *)
type observed = { outcome : Metrics.outcome; trace : Io.event list }

let outcomes_agree a b =
  Metrics.agreement a.outcome b.outcome = Metrics.Agrees
  && List.equal Io.event_equal a.trace b.trace

let residue_clean name term =
  let residue = Residue.survey ~env term in
  check (label name "zero surviving eval-cell dereferences")
    (residue.Residue.eval_cell_dereferences = 0);
  check (label name "zero surviving evaluator calls") (residue.Residue.evaluator_calls = 0);
  check (label name "zero Core-constructor dispatch") (residue.Residue.dispatch_sites = 0);
  check (label name "zero residualized NamedVar lookups")
    (residue.Residue.named_var_lookups = 0);
  check (label name "no interpreter residue from any other source")
    (Residue.interpreter_residue residue ~own:file = 0)

let across_depths_syntactic sample ~invariance_expected =
  let reference = ref None in
  let reference_at = ref reference_depth in
  let steps = base_steps sample.term in
  let source = source_outcome sample.term in
  for depth = 0 to max_depth do
    if projected_steps ~base:steps ~depth <= depth_budget then (
      let specialized = Metrics.specialize ~depth ~env sample.term in
      match specialized with
      | Ok normalized ->
          residue_clean sample.name normalized;
          (* Idempotence over real residuals, not just hand-built terms: the
             normal form of the normal form is the normal form. *)
          check
            (label sample.name
               "normalization is idempotent on the actual residual")
            (Core.equal_structure (Normalize.normalize normalized) normalized);
          (match !reference with
          | None ->
              reference := Some normalized;
              reference_at := depth
          | Some reference_term ->
              (* The claim is pairwise across all depths, so comparing every
                 residual against the first affordable one is the same claim. *)
              if invariance_expected then
                check
                  (label sample.name
                     (Printf.sprintf "normalized residual equals depth %d"
                        !reference_at))
                  (Core.equal_structure reference_term normalized)
              else
                check
                  (label sample.name
                     (Printf.sprintf "differs from depth %d, as a depth observer must"
                        !reference_at))
                  (not (Core.equal_structure reference_term normalized)))
      | Error error ->
          (* Specialization folded the program to a failure. That fold is
             correct exactly when it is the failure the program itself has,
             cause and site included — at every depth alike, since the fold
             comes from the program, not from the configuration. *)
          check (label sample.name "the folded failure is the program's own")
            (Metrics.agreement source (Metrics.Failed error) = Metrics.Agrees);
          if !reference <> None then (
            incr failures;
            Printf.printf "FAIL %s: residual presence changed at depth %d\n" sample.name
              depth))
    else skipped := (sample.name, depth) :: !skipped
  done

(* {1 Samples} *)

let corpus =
  List.map (fun (name, text) -> closed ("value: " ^ name) text) Corpus.values
  @ List.map (fun (name, text) -> closed ("error: " ^ name) text) Corpus.errors
  @ [
      (* Observable output has to reach the stream through n interpreters in
         the same order, and the residual prints once too. *)
      surface "output: hello" "println(\"hello\")\n42";
    ]

let computing =
  [
    core "a function of an unknown argument"
      "(lam (x) (app (var +) (app (var *) (var x) (lit 2)) (lit 1)))"
      [ "(lit 5)" ];
    core "recursion on an unknown count"
      "(letrec ((loop (lam (n) (if (app (var ==) (var n) (lit 0)) (lit 0)\n\
      \  (app (var +) (var n) (app (var loop) (app (var -) (var n) (lit 1))))))))\n\
      \  (lam (x) (app (var loop) (var x))))"
      [ "(lit 6)" ];
    core "a traversal of an unknown list"
      "(letrec ((total (lam (xs) (if (app (var empty?) (var xs)) (lit 0)\n\
      \  (app (var +) (app (var head) (var xs)) (app (var total) (app (var tail) (var xs))))))))\n\
      \  (lam (l) (app (var total) (var l))))"
      [ "(app (var list) (lit 1) (lit 2) (lit 3))" ];
    core "a higher-order function applied at specialization time"
      "(let twice (lam (f v) (app (var f) (app (var f) (var v))))\n\
      \  (lam (x) (app (var twice) (lam (y) (app (var +) (var y) (lit 1))) (var x))))"
      [ "(lit 7)" ];
  ]

(* Programs that read the depth they run at. §9.3's DEPTH-SENSITIVE class:
   residuals differ across depths, each correct at its own — which here means
   matching what the depth-n tower did. All are closed on purpose: a
   function-valued answer carries identity, so neither side could be compared
   without applying both, and the tower's recorded outcome cannot be applied.
   The closed samples carry the same claim with comparable answers. *)
let depth_sensitive =
  [
    surface "tower_depth alone" "tower_depth()";
    surface "tower_depth under addition" "tower_depth() + 1";
    surface "printed depth" "println(tower_depth())\n0";
  ]

(* {1 The semantic half: behavior at each depth} *)

(* Function-valued answers are compared by application, through the
   measurement's own globals — closure equality is identity, so that is the
   only honest comparison. Applied bodies in this corpus are pure, so those
   comparisons are on outcomes alone. *)
let apply_with_globals ~globals term arguments =
  let inner_scope =
    Core_reader.scope_of_list
      (Ident.Set.fold
         (fun ident collected -> (Ident.name ident, ident) :: collected)
         (Env.idents globals) [])
  in
  let args = List.map (Core_reader.read ~scope:inner_scope ~file) arguments in
  let call = Core.app ~span:(Core.span term) ~func:term ~args in
  match Evaluator.eval ~env:globals call with
  | value -> Metrics.Answered value
  | exception Error.Ash_error error -> Metrics.Failed error

let across_depths_semantic sample ~invariance_expected =
  let measure ~depth =
    Metrics.measure ~depth ~file ~name:sample.name sample.program
  in
  let base = max 1 (measure ~depth:0).Metrics.source.Metrics.steps in
  for depth = 0 to max_depth do
    if projected_steps ~base:base ~depth <= depth_budget then (
      let m = measure ~depth in
      let source = m.Metrics.source in
      let tower_run = m.Metrics.tower.Metrics.run in
      if invariance_expected then (
        check (label sample.name "the tower is transparent")
          (Metrics.agreement source.Metrics.outcome tower_run.Metrics.outcome
          <> Metrics.Differs);
        check (label sample.name "the tower left the same trace")
          (List.equal Io.event_equal source.Metrics.output tower_run.Metrics.output));
      match m.Metrics.residual with
      | Error error ->
          check (label sample.name "the folded failure is the program's own")
            (Metrics.agreement source.Metrics.outcome (Metrics.Failed error) = Metrics.Agrees);
          incr proved
      | Ok residual ->
          let from_residual =
            match sample.arguments with
            | [] ->
                {
                  outcome = residual.Metrics.run.Metrics.outcome;
                  trace = residual.Metrics.run.Metrics.output;
                }
            | _ ->
                {
                  outcome =
                    apply_with_globals ~globals:m.Metrics.globals residual.Metrics.term
                      sample.arguments;
                  trace = [];
                }
          in
          if invariance_expected then (
            let from_program =
              match sample.arguments with
              | [] ->
                  { outcome = source.Metrics.outcome; trace = source.Metrics.output }
              | _ ->
                  {
                    outcome =
                      apply_with_globals ~globals:m.Metrics.globals m.Metrics.program
                        sample.arguments;
                    trace = [];
                  }
            in
            check (label sample.name "the residual matches the program")
              (outcomes_agree from_program from_residual));
          let from_tower =
            { outcome = tower_run.Metrics.outcome; trace = tower_run.Metrics.output }
          in
          if invariance_expected then (
            (* The tower-vs-residual match is assertable only on closed
               answers: a function-valued tower answer carries identity, and
               what was recorded cannot be applied after the fact. There the
               claim is carried by transparency plus program-vs-residual. *)
            if sample.arguments = [] then
              check (label sample.name "and matches what the tower did")
                (outcomes_agree from_tower from_residual);
            incr proved)
          else (
            check (label sample.name "the residual matches what the tower did")
              (outcomes_agree from_tower from_residual);
            incr sensitive_proved);
          check (label sample.name "the residual costs no more than the source")
            (residual.Metrics.run.Metrics.steps <= source.Metrics.steps))
    else skipped := (sample.name, depth) :: !skipped
  done

(* {1 The normalizer is load-bearing} *)

(* Specialize the same term twice, raw: the two results must differ — every run
   allocates fresh identities — and their normal forms must coincide. Without
   that, "equal after normalization" could mean anything. *)
let test_normalizer_load_bearing () =
  let text =
    "(lam (x) (let t (app (var +) (var x) (lit 1)) (app (var *) (var t) (var t))))"
  in
  let term = Core_reader.read ~scope ~file text in
  let raw () =
    let machine = Ash_stage.Staged_eval.machine ~mode:Ash_stage.Mode.Lift () in
    Machine.set_levels machine
      {
        Machine.level_index = 0;
        level_above = (fun () -> invalid_arg "no level above during specialization");
        level_below = None;
        level_tower_depth = (fun () -> reference_depth);
      };
    match Ash_stage.Staged_eval.run machine ~env term with
    | Value.Code node -> node
    | _ -> invalid_arg "expected a residual"
  in
  let first = raw () and second = raw () in
  check "two raw specializations are not structurally equal"
    (not (Core.equal_structure first second));
  check "normalization makes them one term"
    (Core.equal_structure (Normalize.normalize first) (Normalize.normalize second))

(* {1 Entry} *)

let () =
  List.iter
    (fun s -> across_depths_syntactic s ~invariance_expected:true)
    corpus;
  List.iter
    (fun s -> across_depths_syntactic s ~invariance_expected:true)
    computing;
  List.iter
    (fun s -> across_depths_syntactic s ~invariance_expected:false)
    depth_sensitive;
  List.iter
    (fun s -> across_depths_semantic s ~invariance_expected:true)
    corpus;
  List.iter
    (fun s -> across_depths_semantic s ~invariance_expected:true)
    computing;
  List.iter
    (fun s -> across_depths_semantic s ~invariance_expected:false)
    depth_sensitive;
  test_normalizer_load_bearing ();
  Printf.printf "depth results: %d invariant checks and %d depth-sensitive checks over depths 0-%d\n"
    !proved !sensitive_proved max_depth;
  if !skipped <> [] then (
    let names =
      let rec unique acc = function
        | [] -> List.rev acc
        | name :: rest ->
            if List.mem name acc then unique acc rest else unique (name :: acc) rest
      in
      unique [] (List.rev_map fst !skipped)
    in
    Printf.printf "  over the %d-step budget, so depth %d at most: %s\n" depth_budget
      (List.fold_left (fun acc (_, d) -> max acc d) 0 !skipped)
      (String.concat ", " names));
  if !failures > 0 then (
    Printf.printf "%d depth-result failure(s)\n" !failures;
    exit 1)
