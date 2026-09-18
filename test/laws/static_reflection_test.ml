(* Static reflective collapse (to-do task 9.1, spec §7.4 step 5).

   A persistent [up] replacement and a scoped [meta_with] overlay are static
   evaluator configuration when their wrappers are known.  Specialization must
   inline those wrappers at the dispatch sites they intercept.  Observable
   effects in a wrapper stay in the residual at those sites; the evaluator
   protocol itself does not. *)

open Ash_core
open Ash_runtime
open Ash_collapse

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let trace events = String.concat "; " (List.map Io.event_to_string events)

let same_outcome a b = Metrics.agreement a b = Metrics.Agrees

let zero_interpreter_residue residue =
  residue.Residue.eval_cell_dereferences = 0
  && residue.Residue.evaluator_calls = 0
  && residue.Residue.dispatch_sites = 0
  && residue.Residue.named_var_lookups = 0
  && residue.Residue.reflection_boundaries = []
  && Residue.interpreter_residue residue ~own:"static_reflection.ash" = 0

let check_collapses name source =
  let measured =
    Metrics.measure ~depth:1 ~file:"static_reflection.ash" ~name
      (Metrics.Surface source)
  in
  match measured.Metrics.residual with
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  specialization failed: %s\n" name
        (Error.to_string error)
  | Ok residual ->
      check (name ^ ": residual agrees with tower")
        (same_outcome measured.Metrics.tower.Metrics.run.Metrics.outcome
           residual.Metrics.run.Metrics.outcome);
      let tower_trace = measured.Metrics.tower.Metrics.run.Metrics.output in
      let residual_trace = residual.Metrics.run.Metrics.output in
      if not (List.equal Io.event_equal tower_trace residual_trace) then (
        incr failures;
        Printf.printf
          "FAIL %s: residual preserves the observable trace\n  tower:    %s\n  residual: %s\n"
          name (trace tower_trace) (trace residual_trace));
      check (name ^ ": specialization performs no program output")
        (measured.Metrics.specialization.Metrics.output = []);
      check (name ^ ": no interpreter residue survives")
        (zero_interpreter_residue residual.Metrics.residue)

let test_persistent_eval () =
  check_collapses "persistent eval counting"
    "var steps = 0\n\
     up {\n\
    \  let base = eval\n\
    \  eval := fn(e, r, k) -> { steps := steps + 1; base(e, r, k) }\n\
     }\n\
     let answer = (1 + 2) * 4\n\
     [answer, steps > 5]"

let test_scoped_eval () =
  check_collapses "scoped eval tracing"
    "meta_with(eval = fn(e, r, k) -> {\n\
    \  println(head(tail(code_view(e))))\n\
    \  println(e)\n\
    \  eval(e, r, k)\n\
     }) {\n\
    \  (1 + 2) * 4\n\
     }"

let test_persistent_apply () =
  check_collapses "persistent apply counting"
    "var calls = 0\n\
     fn twice(n) = n + n\n\
     up {\n\
    \  let base = apply\n\
    \  apply := fn(f, args, k) -> { calls := calls + 1; base(f, args, k) }\n\
     }\n\
     [twice(twice(3)), calls > 1]"

let test_scoped_apply () =
  check_collapses "scoped apply tracing"
    "fn twice(n) = n + n\n\
     meta_with(apply = fn(f, args, k) -> { println('call); apply(f, args, k) }) {\n\
    \  twice(twice(3))\n\
     }"

let test_persistent_and_scoped_stack () =
  check_collapses "persistent and scoped wrappers stack"
    "up {\n\
    \  let base = eval\n\
    \  eval := fn(e, r, k) -> { print(\"p\"); base(e, r, k) }\n\
     }\n\
     meta_with(eval = fn(e, r, k) -> { print(\"s\"); eval(e, r, k) }) {\n\
    \  1 + 2\n\
     }"

let () =
  test_persistent_eval ();
  test_scoped_eval ();
  test_persistent_apply ();
  test_scoped_apply ();
  test_persistent_and_scoped_stack ();
  if !failures > 0 then (
    Printf.printf "%d static-reflection assertion(s) failed\n" !failures;
    exit 1)
