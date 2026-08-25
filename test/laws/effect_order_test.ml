(* The effect-order differential (to-do task 7.3).

   Phase 6 asked whether a residual computes the same {e answer} as the program
   it came from. This asks the question mutation and output make sharper: does
   it do the same things, in the same order, ending in the same store — at every
   tower depth from 0 to 5.

   {1 The four observations}

   Each sample in {!Corpus.effect_order} is composed into one program whose
   final expression is a list: its answer first, then the expressions that read
   the store back. One run therefore yields three of the four observations
   together — value, store, and the trace the run left on the output stream —
   and the fourth, failure, is what the two other lists are for.
   {!Corpus.effect_order_failures} are programs whose failure the specializer
   could not decide and had to leave in the residual, which is the only way the
   output and the writes {e before} a failure become comparable at all: a folded
   failure never reaches a residual.

   A store cannot be compared across runs directly — cells carry identity and
   each run allocates its own (§D1) — so what is compared is what the program
   reads out of it. That is not a weaker claim than it sounds: the reads are in
   the program, so the specializer has to get them right along with everything
   else, and a fold that moved a read across a write shows up as a wrong number
   rather than as a missing check.

   {1 What is compared against what}

   Per depth, three claims. The tower is transparent: the source run and the
   depth-n tower run agree on outcome and trace. The criterion: the tower run
   and the residual run agree — value, store, output, and failure. And
   compilation is silent: the specialization phase writes nothing to the
   program's stream, whatever it writes to §D7's compile-time log.

   Across depths, the syntactic claim of task 6.4, now over programs that
   mutate: the normalized residuals are one term. These programs do not read
   their own depth, so a residual that changed with depth would mean the
   specializer had folded something about the configuration into a program that
   never asked.

   {1 Normalized, not raw}

   Every residual here is the normalized one, which is what {!Metrics.measure}
   produces and what the report calls the deliverable. That is deliberate:
   ADR 0033's store guard — a binding whose value is a read of something the
   term assigns may not be substituted away — is only load-bearing on a residual
   that contains a [Set], and this is the first corpus that produces one. A
   comparison against raw residuals would pass without ever exercising it, which
   is why one sample additionally asserts that the guarded shape is present in
   the residual it produced.

   {1 The boundary}

   {!Corpus.effect_order_boundaries} is a program that runs and does not
   specialize: a failure the specializer can decide, inside a branch it cannot,
   aborts the whole specialization instead of becoming a residual failure in
   that branch. Residualizing a decided failure is error-and-control work no step
   of §7.4's fragment ordering owns. The sample is asserted to be refused rather
   than dropped, so whichever phase takes it on says so here. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_collapse

let failures = ref 0
let proved = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let report name explanation =
  incr failures;
  Printf.printf "FAIL %s\n  %s\n" name explanation

let label sample suffix = sample ^ ": " ^ suffix

(* {1 Configuration}

   Depth cost is bounded by counted Ash steps projected through the measured
   per-level multiplier, never by wall time; a depth a sample does not fit is
   reported rather than silently skipped. Both numbers are task 6.4's. *)

let file = "effect_order.ash"
let max_depth = 5
let depth_budget = 20_000_000
let per_level_multiplier = 5
let skipped = ref []

let projected_steps ~base ~depth =
  let rec go value remaining =
    if remaining = 0 then value
    else if value > depth_budget then value
    else go (value * per_level_multiplier) (remaining - 1)
  in
  go base depth

(* The one environment every syntactic comparison shares: cloned globals (ADR
   0022) give each environment its own identities, so residuals from two
   environments never compare. *)
let registry = Primitives.create ()
let shared_tower = Ash_tower.Tower.create ~registry ()
let env = Ash_tower.Level.global (Ash_tower.Tower.ground shared_tower)

let named =
  Ident.Set.fold
    (fun ident collected -> (Ident.name ident, ident) :: collected)
    (Env.idents env) []

let read text = Desugar.program ~scope:(Desugar.scope_of_globals named) (Parser.program ~file text)

(* {1 Reading a residual} *)

let rec fold_nodes f accumulator node =
  let accumulator = f accumulator node in
  match Core.shape node with
  | Core.Quote _ -> accumulator
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
  | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Reifier _ ->
      List.fold_left (fold_nodes f) accumulator (Core.children node)

let exists p node = fold_nodes (fun found node -> found || p node) false node

let is_set node =
  match Core.shape node with
  | Core.Set _ -> true
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
  | Core.LetRec _ | Core.If _ | Core.Quote _ | Core.Reifier _ ->
      false

(* ADR 0033's store guard, as a shape: a binding whose value is a bare read of a
   binder the same term assigns. Substituting it away would answer with the
   value the cell held before the [Set]. *)
let binds_a_read_of_an_assigned_binding node =
  let assigned = Core.assigned_idents node in
  exists
    (fun candidate ->
      match Core.shape candidate with
      | Core.Let { Core.let_value; _ } -> (
          match Core.shape let_value with
          | Core.Var read -> Ident.Set.mem read assigned
          | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
          | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
              false)
      | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          false)
    node

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

(* {1 Comparing two runs}

   The composed program answers a list: the value first, the store readings
   after it. Splitting them here is what lets a difference be named as the one
   it is rather than as a list that came out wrong. *)

let values_to_string values = String.concat ", " (List.map Value.to_string values)
let trace_to_string events = String.concat "; " (List.map Io.event_to_string events)

let observation_difference (expected : Metrics.run) (actual : Metrics.run) =
  let by_part =
    match (expected.Metrics.outcome, actual.Metrics.outcome) with
    | ( Metrics.Answered (Value.List (expected_value :: expected_store)),
        Metrics.Answered (Value.List (actual_value :: actual_store)) ) ->
        if not (Value.equal expected_value actual_value) then
          Some
            (Printf.sprintf "value: %s became %s" (Value.to_string expected_value)
               (Value.to_string actual_value))
        else if not (List.equal Value.equal expected_store actual_store) then
          Some
            (Printf.sprintf "store: [%s] became [%s]" (values_to_string expected_store)
               (values_to_string actual_store))
        else None
    | ( ( Metrics.Answered
            ( Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
            | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
            | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ )
        | Metrics.Failed _ ),
        _ ) ->
        None
  in
  match by_part with
  | Some difference -> Some difference
  | None -> (
      match Metrics.agreement expected.Metrics.outcome actual.Metrics.outcome with
      | Metrics.Agrees ->
          if List.equal Io.event_equal expected.Metrics.output actual.Metrics.output then None
          else
            Some
              (Printf.sprintf "output: [%s] became [%s]"
                 (trace_to_string expected.Metrics.output)
                 (trace_to_string actual.Metrics.output))
      | Metrics.Differs | Metrics.Incomparable ->
          Some
            (Printf.sprintf "outcome: %s became %s"
               (Metrics.outcome_to_string expected.Metrics.outcome)
               (Metrics.outcome_to_string actual.Metrics.outcome)))

(* {1 The semantic half: every depth, three claims} *)

type expectation =
  | Collapses  (** A residual is produced and agrees with the tower run. *)
  | Refused  (** No residual: the specialization is expected to fail. *)

let across_depths ?(inspect = fun _ -> ()) ~expectation name text =
  let program = Metrics.Surface text in
  let base = max 1 (Metrics.measure ~depth:0 ~file ~name program).Metrics.source.Metrics.steps in
  for depth = 0 to max_depth do
    if projected_steps ~base ~depth > depth_budget then skipped := (name, depth) :: !skipped
    else
      let at = Printf.sprintf "%s at depth %d" name depth in
      let m = Metrics.measure ~depth ~file ~name program in
      let source = m.Metrics.source and tower = m.Metrics.tower.Metrics.run in

      (* Compilation runs nothing the program could have run. *)
      check (label at "specialization left no program output")
        (m.Metrics.specialization.Metrics.output = []);

      (* Transparency: n interposed interpreters change neither the answer nor
         the trace. *)
      (match observation_difference source tower with
      | None -> incr proved
      | Some difference -> report (label at "the tower is transparent") difference);

      match (m.Metrics.residual, expectation) with
      | Ok residual, Collapses ->
          residue_clean at residual.Metrics.term;
          check (label at "normalization is idempotent on the actual residual")
            (Core.equal_structure
               (Normalize.normalize residual.Metrics.term)
               residual.Metrics.term);
          (match observation_difference tower residual.Metrics.run with
          | None -> incr proved
          | Some difference ->
              report
                (label at "the residual does what the tower did")
                (difference ^ "\n  residual: "
                ^ Core_printer.to_string residual.Metrics.term));
          inspect residual.Metrics.term
      | Ok residual, Refused ->
          report (label at "expected no residual")
            ("staged to " ^ Core_printer.to_string residual.Metrics.term)
      | Error error, Collapses ->
          report (label at "expected a residual") ("specialization failed: " ^ Error.to_string error)
      | Error error, Refused ->
          (* The refusal is the specializer's, not a lowering or reading
             failure: the program itself runs, and it is a failure the program's
             own text contains that stopped the specialization. *)
          check (label at "the program itself runs")
            (match source.Metrics.outcome with
            | Metrics.Answered _ -> true
            | Metrics.Failed _ -> false);
          check (label at "the refusal names the failure the branch would have had")
            (Error.cause_equal error.Error.cause Error.Division_by_zero);
          check (label at "the refusal points into the program's own source")
            (String.equal (Span.file (Span.source_span error.Error.span)) file);
          incr proved
  done

(* {1 The syntactic half: one residual across all depths}

   None of these programs reads its own depth, so every depth's normalized
   residual is the same term. Two raw specializations of one term are never
   structurally equal — each allocates fresh binder identities — so
   normalization is load-bearing here exactly as it is in task 6.4, which that
   test asserts directly. *)

let one_residual_across_depths ~expectation name text =
  let term = read text in
  let reference = ref None in
  for depth = 0 to max_depth do
    match (Metrics.specialize ~depth ~env term, expectation) with
    | Ok normalized, Collapses -> (
        match !reference with
        | None -> reference := Some normalized
        | Some first ->
            if Core.equal_structure first normalized then incr proved
            else
              report
                (label name (Printf.sprintf "the depth-%d residual equals depth 0" depth))
                (Printf.sprintf "depth 0: %s\n  depth %d: %s" (Core_printer.to_string first)
                   depth
                   (Core_printer.to_string normalized)))
    | Ok normalized, Refused ->
        report
          (label name (Printf.sprintf "expected no residual at depth %d" depth))
          ("staged to " ^ Core_printer.to_string normalized)
    | Error error, Collapses ->
        report
          (label name (Printf.sprintf "expected a residual at depth %d" depth))
          ("specialization failed: " ^ Error.to_string error)
    | Error _, Refused -> incr proved
  done

(* {1 Entry} *)

(* The one sample whose residual is asserted by shape as well as by behaviour:
   without ADR 0033's guard the normalizer would substitute the read away and
   the residual would answer with the value the cell held before the write. *)
let guarded_sample = "a read of a binding a later write changes"

let inspect_guarded residual =
  check (label guarded_sample "the residual keeps a write to a residual binding")
    (exists is_set residual);
  check (label guarded_sample "and the binding the normalizer's store guard protects")
    (binds_a_read_of_an_assigned_binding residual)

let () =
  List.iter
    (fun sample ->
      let name = "effect order: " ^ sample.Corpus.name in
      let text = Corpus.effect_sample_program sample in
      let inspect =
        if String.equal sample.Corpus.name guarded_sample then inspect_guarded
        else fun _ -> ()
      in
      across_depths ~inspect ~expectation:Collapses name text;
      one_residual_across_depths ~expectation:Collapses name text)
    Corpus.effect_order;
  List.iter
    (fun (name, text) ->
      let name = "failure: " ^ name in
      across_depths ~expectation:Collapses name text;
      one_residual_across_depths ~expectation:Collapses name text)
    Corpus.effect_order_failures;
  List.iter
    (fun (name, text) ->
      let name = "boundary: " ^ name in
      across_depths ~expectation:Refused name text;
      one_residual_across_depths ~expectation:Refused name text)
    Corpus.effect_order_boundaries;
  Printf.printf
    "effect order: %d checks over %d programs at depths 0-%d\n" !proved
    (List.length Corpus.effect_order
    + List.length Corpus.effect_order_failures
    + List.length Corpus.effect_order_boundaries)
    max_depth;
  if !skipped <> [] then (
    let names =
      let rec unique acc = function
        | [] -> List.rev acc
        | name :: rest -> if List.mem name acc then unique acc rest else unique (name :: acc) rest
      in
      unique [] (List.rev_map fst !skipped)
    in
    Printf.printf "  over the %d-step budget, so depth %d at most: %s\n" depth_budget
      (List.fold_left (fun acc (_, d) -> max acc d) 0 !skipped)
      (String.concat ", " names));
  if !failures > 0 then (
    Printf.printf "%d effect-order failure(s)\n" !failures;
    exit 1)
