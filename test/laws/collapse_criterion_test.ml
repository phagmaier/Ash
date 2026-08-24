(* The pure Phase 5 criterion (to-do task 5.5).

   The claim, from spec §8's Phase 5 and the checklist's 5.5: for a pure
   program, the residual behaves as the program does and contains {b zero}
   Core-constructor dispatch and {b zero} surviving eval-cell dereferences.

   {1 What is being compared}

   Three runs of one program: the source on the ground evaluator, the same
   program under one interposed interpreter (depth 1 — the configuration
   `Ash_tower.Depth` installs, where every step of level 0 is a term level 1 has
   to evaluate), and the residual the specializer produced. All three must agree
   on the value, the failure, and the observable trace.

   {1 Why this is not a tautology}

   A closed pure program folds to a literal, and a literal trivially contains no
   dispatch. Three things keep the suite honest.

   First, the {e premise} is asserted, not assumed: the tower run at depth 1 has
   to have performed the interpretation the residual is claimed not to contain —
   Core dispatches and evaluator-group cell reads, both greater than zero. A
   program that was never interpreted proves nothing about erasing
   interpretation.

   Second, half the samples do not fold to a literal: their value is a function
   of an argument the specializer does not have, so the residual still computes,
   and equivalence is established by {e applying} it — closure equality is
   identity, so a residual function cannot be compared to a source function any
   other way.

   Third, the criterion is shown to be falsifiable. The boundary section runs
   programs that are pure and still leave interpretation behind — an
   open-recursion group, and a runtime dispatch on a Core node — and requires the
   measurement to say so. A criterion no program can fail is not a criterion.

   {1 What this does not claim}

   The residual is the program specialized on its own, which is §7.4 step 1.
   Specializing away the interposed evaluator itself is static reflective
   collapse, task 9.1. The depth-1 figures here are the interpretation that a
   tower performs and the residual does not contain — not interpretation this
   residual removed from a tower. `Ash_collapse.Report` prints the same
   qualification beneath every report. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_collapse

let failures = ref 0
let proved = ref 0

(* The interpretation the tower performed and the residuals do not contain,
   totalled so the suite's own output states the result rather than only
   asserting it. *)
let tower_dispatches = ref 0
let tower_dereferences = ref 0
let residual_nodes = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "criterion.ash"

(* {1 Running a residual the specializer left as a function} *)

let scope_of globals =
  Core_reader.scope_of_list
    (Ident.Set.fold
       (fun ident collected -> (Ident.name ident, ident) :: collected)
       (Env.idents globals) [])

type applied = { outcome : Metrics.outcome; trace : Io.event list }

(* Apply a term to argument terms on a fresh ground evaluator, with its own
   output stream so the trace is that application's alone. *)
let apply ~globals term arguments =
  let registry = Primitives.create () in
  let io = Primitives.io registry in
  let scope = scope_of globals in
  let args = List.map (Core_reader.read ~scope ~file) arguments in
  let call = Core.app ~span:(Core.span term) ~func:term ~args in
  let outcome =
    match Evaluator.eval ~env:globals call with
    | value -> Metrics.Answered value
    | exception Error.Ash_error error -> Metrics.Failed error
  in
  { outcome; trace = Io.events io }

(* {1 One sample} *)

type sample = {
  name : string;
  program : Metrics.program;
  arguments : string list;
      (** Argument terms for a program whose value is a function. Empty when the
          program's own value is the thing to compare. *)
}

let closed name program = { name; program; arguments = [] }
let open_ name program arguments = { name; program; arguments }

let criterion sample =
  let metrics =
    Metrics.measure ~depth:1 ~file ~name:sample.name sample.program
  in
  let label suffix = sample.name ^ ": " ^ suffix in
  let tower = metrics.Metrics.tower in
  let source = metrics.Metrics.source in

  (* The premise. Without it the criterion is a statement about nothing. *)
  check (label "the tower run interpreted something") (tower.Metrics.dispatches > 0);
  tower_dispatches := !tower_dispatches + tower.Metrics.dispatches;
  tower_dereferences :=
    !tower_dereferences
    + List.fold_left (fun total (l : Metrics.level_cost) -> total + l.Metrics.cell_dereferences) 0
        tower.Metrics.levels;
  check (label "the tower run dereferenced an evaluator cell")
    (match tower.Metrics.levels with
    | level0 :: _ -> level0.Metrics.cell_dereferences > 0
    | [] -> false);

  match metrics.Metrics.residual with
  | Error error -> (
      (* A pure computation the program certainly reaches may be folded to its
         failure at specialization time. That is only correct when it is the
         failure the program actually has, reported where the program has it. *)
      match Metrics.agreement source.Metrics.outcome (Metrics.Failed error) with
      | Metrics.Agrees -> incr proved
      | Metrics.Differs | Metrics.Incomparable ->
          incr failures;
          Printf.printf "FAIL %s\n  source %s, specialization %s\n" (label "specialization")
            (Metrics.outcome_to_string source.Metrics.outcome)
            (Metrics.outcome_to_string (Metrics.Failed error)))
  | Ok residual ->
      let residue = residual.Metrics.residue in
      residual_nodes := !residual_nodes + residue.Residue.nodes;
      (* A sample declared to still compute must actually still compute: a
         residual that folded to a literal would satisfy the criterion for the
         uninteresting reason. *)
      if sample.arguments <> [] then
        check (label "the residual still computes")
          (residue.Residue.nodes > 2
          && match Core.shape residual.Metrics.term with Core.Lam _ -> true | _ -> false);
      (* The criterion itself. *)
      check (label "zero surviving eval-cell dereferences")
        (residue.Residue.eval_cell_dereferences = 0);
      check (label "zero surviving evaluator calls") (residue.Residue.evaluator_calls = 0);
      check (label "zero Core-constructor dispatch") (residue.Residue.dispatch_sites = 0);
      check (label "zero residualized NamedVar lookups") (residue.Residue.named_var_lookups = 0);
      check (label "zero reflection boundaries") (residue.Residue.reflection_boundaries = []);
      check (label "no residue from any other source")
        (Residue.interpreter_residue residue ~own:file = 0);

      (* Specialization is not a run of the program (§D7). *)
      check (label "specialization left no output")
        (metrics.Metrics.specialization.Metrics.output = []);

      (* §7.5: a program that collapses without generalizing says more than one
         that does. Every sample here is decided by the specializer outright,
         under the default budget, and the criterion asserts that rather than
         leaving it to be noticed. *)
      check (label "nothing was generalized")
        (metrics.Metrics.specialization.Metrics.generalizations = 0);

      (* Equivalence: source, tower, residual. *)
      (match Metrics.agreement source.Metrics.outcome tower.Metrics.run.Metrics.outcome with
      | Metrics.Agrees | Metrics.Incomparable -> ()
      | Metrics.Differs ->
          incr failures;
          Printf.printf "FAIL %s\n  source %s, tower %s\n" (label "tower equivalence")
            (Metrics.outcome_to_string source.Metrics.outcome)
            (Metrics.outcome_to_string tower.Metrics.run.Metrics.outcome));
      check (label "the tower left the same trace")
        (List.equal Io.event_equal source.Metrics.output tower.Metrics.run.Metrics.output);

      (match sample.arguments with
      | [] ->
          (* A value the two runs can be compared on directly. *)
          (match Metrics.agreement source.Metrics.outcome residual.Metrics.run.Metrics.outcome with
          | Metrics.Agrees -> incr proved
          | Metrics.Incomparable ->
              incr failures;
              Printf.printf
                "FAIL %s\n  the answer carries identity and no arguments were given to \
                 compare it by application\n"
                (label "residual equivalence")
          | Metrics.Differs ->
              incr failures;
              Printf.printf "FAIL %s\n  source %s, residual %s\n" (label "residual equivalence")
                (Metrics.outcome_to_string source.Metrics.outcome)
                (Metrics.outcome_to_string residual.Metrics.run.Metrics.outcome));
          check (label "the residual left the same trace")
            (List.equal Io.event_equal source.Metrics.output residual.Metrics.run.Metrics.output)
      | _ :: _ ->
          (* A function: the only honest comparison is to apply both. *)
          let globals = metrics.Metrics.globals in
          let from_source = apply ~globals metrics.Metrics.program sample.arguments in
          let from_residual = apply ~globals residual.Metrics.term sample.arguments in
          (match Metrics.agreement from_source.outcome from_residual.outcome with
          | Metrics.Agrees -> incr proved
          | Metrics.Differs | Metrics.Incomparable ->
              incr failures;
              Printf.printf "FAIL %s\n  applied source %s, applied residual %s\n"
                (label "residual equivalence")
                (Metrics.outcome_to_string from_source.outcome)
                (Metrics.outcome_to_string from_residual.outcome));
          check (label "applying the residual left the same trace")
            (List.equal Io.event_equal from_source.trace from_residual.trace));

      (* Collapsing must not cost more than not collapsing. *)
      check (label "the residual costs no more than the source")
        (residual.Metrics.run.Metrics.steps <= source.Metrics.steps)

(* {1 The samples} *)

(* Every pure program the rest of the repository is tested on: the values, and
   the failures. A pure program that fails is still a pure program, and "behaves
   as p" is easiest to get wrong where p does not produce a value — the
   specializer is allowed to fold a certain failure at specialization time, but
   only into the failure the program actually has, at the place it has it. *)
let corpus =
  List.map (fun (name, text) -> closed ("value: " ^ name) (Metrics.Core_notation text)) Corpus.values
  @ List.map
      (fun (name, text) -> closed ("error: " ^ name) (Metrics.Core_notation text))
      Corpus.errors

(* Programs whose value still depends on something the specializer does not
   have, so the residual is a function and still computes. *)
let open_samples =
  [
    open_ "a function of an unknown argument"
      (Metrics.Core_notation "(lam (x) (app (var +) (app (var *) (var x) (lit 2)) (lit 1)))")
      [ "(lit 5)" ];
    open_ "recursion on a static count over an unknown base"
      (Metrics.Core_notation
         "(letrec ((power (lam (n x) (if (app (var ==) (var n) (lit 0)) (lit 1)\n\
         \  (app (var *) (var x) (app (var power) (app (var -) (var n) (lit 1)) (var x)))))))\n\
         \  (lam (x) (app (var power) (lit 3) (var x))))")
      [ "(lit 2)" ];
    open_ "a higher-order function applied at specialization time"
      (Metrics.Core_notation
         "(let twice (lam (f v) (app (var f) (app (var f) (var v))))\n\
         \  (lam (x) (app (var twice) (lam (y) (app (var +) (var y) (lit 1))) (var x))))")
      [ "(lit 7)" ];
    open_ "a closure crossing into an unknown call"
      (Metrics.Core_notation "(lam (g) (app (var g) (lam (y) (app (var *) (var y) (lit 2)))))")
      [ "(lam (f) (app (var f) (lit 21)))" ];
    open_ "a traversal of a statically shaped list of unknown values"
      (Metrics.Core_notation
         "(letrec ((mapinc (lam (l) (if (app (var empty?) (var l)) (lit nil)\n\
         \  (app (var cons) (app (var +) (app (var head) (var l)) (lit 1))\n\
         \       (app (var mapinc) (app (var tail) (var l))))))))\n\
         \  (lam (x) (app (var mapinc) (app (var list) (var x) (lit 7)))))")
      [ "(lit 5)" ];
    (* Recursion whose control the specializer cannot decide (task 6.1). The
       residual keeps a [LetRec] of its own — that is the program's recursion,
       not an interpreter's — and the criterion is unchanged: no evaluator, no
       Core dispatch, and the same answers. *)
    open_ "recursion on an unknown count"
      (Metrics.Core_notation
         "(letrec ((loop (lam (n) (if (app (var ==) (var n) (lit 0)) (lit 0)\n\
         \  (app (var +) (var n) (app (var loop) (app (var -) (var n) (lit 1))))))))\n\
         \  (lam (x) (app (var loop) (var x))))")
      [ "(lit 6)" ];
    open_ "a traversal of an unknown list"
      (Metrics.Core_notation
         "(letrec ((total (lam (xs) (if (app (var empty?) (var xs)) (lit 0)\n\
         \  (app (var +) (app (var head) (var xs)) (app (var total) (app (var tail) (var xs))))))))\n\
         \  (lam (l) (app (var total) (var l))))")
      [ "(app (var list) (lit 1) (lit 2) (lit 3))" ];
    open_ "a fold over a static spine"
      (Metrics.Core_notation
         "(letrec ((fold (lam (f acc xs) (if (app (var empty?) (var xs)) (var acc)\n\
         \  (app (var fold) (var f) (app (var f) (var acc) (app (var head) (var xs)))\n\
         \       (app (var tail) (var xs)))))))\n\
         \  (lam (x) (app (var fold) (lam (a b) (app (var +) (var a) (var b))) (lit 0)\n\
         \                (app (var list) (var x) (lit 2) (var x)))))")
      [ "(lit 4)" ];
  ]

(* {1 The boundary}

   Pure programs that leave interpretation behind. These are not failures of the
   collapser: an [open fn] group lowers to store operations, which residualize
   until Phase 7 can reason about the store, and a [code_view] on a value the
   specializer does not have is a dispatch that genuinely has to happen at
   runtime. What they establish is that the criterion can be failed, and that a
   residual is still correct when it is not collapsed. *)

let boundary name program arguments ~expect =
  let metrics = Metrics.measure ~depth:1 ~file ~name program in
  match metrics.Metrics.residual with
  | Error error ->
      incr failures;
      Printf.printf "FAIL boundary %s\n  no residual: %s\n" name (Error.to_string error)
  | Ok residual ->
      check (name ^ ": the measurement detects surviving interpretation")
        (expect residual.Metrics.residue);
      let globals = metrics.Metrics.globals in
      let from_source = apply ~globals metrics.Metrics.program arguments in
      let from_residual = apply ~globals residual.Metrics.term arguments in
      check (name ^ ": the uncollapsed residual is still correct")
        (Metrics.agreement from_source.outcome from_residual.outcome = Metrics.Agrees)

let test_boundary () =
  boundary "an open-recursion group"
    (Metrics.Surface "open fn step(n) =\n  if n == 0 then 0 else step(n - 1)\nfn(x) -> step(x)")
    [ "(lit 3)" ]
    ~expect:(fun residue -> residue.Residue.eval_cell_dereferences > 0);
  boundary "a runtime dispatch on a Core node"
    (Metrics.Core_notation "(lam (e) (app (var head) (app (var code_view) (var e))))")
    [ "(quote (lit 1))" ]
    ~expect:(fun residue -> residue.Residue.dispatch_sites > 0)

let () =
  List.iter criterion corpus;
  List.iter criterion open_samples;
  test_boundary ();
  Printf.printf
    "pure collapse criterion: %d samples proved at depth 1 (%d closed, %d still computing)\n"
    !proved (List.length corpus) (List.length open_samples);
  Printf.printf
    "  the depth-1 tower performed %d constructor dispatches and %d evaluator-cell reads; \n\
    \  the %d residual nodes contain none of either\n"
    !tower_dispatches !tower_dereferences !residual_nodes;
  if !failures > 0 then (
    Printf.printf "%d collapse criterion failure(s)\n" !failures;
    exit 1)
