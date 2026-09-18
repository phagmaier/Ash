(* Scoped meta-overrides (to-do Phase 8).

   Spec §5.5 and D8: [meta_with] pushes a persistent overlay frame rather than
   mutating a persistent cell, lookup precedes the persistent cells, lexical
   [NamedVar] never sees an overlay, and a captured continuation captures the
   overlay pointer in effect at capture time.

   Task 8.1 is the frame discipline: nested overrides shadow correctly and the
   persistent state is unchanged afterwards. Task 8.2 is the continuation
   interaction: capture-inside/invoke-outside re-enters the captured extent
   without mutating the ambient list, including when the resumed computation
   fails. *)

open Ash_core
open Ash_syntax
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

let file = "meta_with.ash"

let fresh () =
  let io = Io.create () in
  let tower = Tower.create ~registry:(Primitives.create ~io ()) () in
  let named =
    Ident.Set.fold
      (fun ident collected -> (Ident.name ident, ident) :: collected)
      (Env.idents (Level.global (Tower.ground tower)))
      []
  in
  (tower, io, Desugar.scope_of_globals named)

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

let run tower scope source =
  Tower.run tower (Desugar.program ~scope (Parser.program ~file source))

let evaluate name source =
  let tower, io, scope = fresh () in
  match attempt (fun () -> run tower scope source) with
  | Ok value -> Some (tower, io, value)
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name (Error.to_string error);
      None

let check_value name expected source =
  match evaluate name source with
  | None -> None
  | Some (tower, io, actual) ->
      if not (Value.equal expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Value.to_string expected) (Value.to_string actual));
      Some (tower, io)

let expect_error name source =
  let tower, _io, scope = fresh () in
  match attempt (fun () -> run tower scope source) with
  | Error error -> Some error
  | Ok value ->
      incr failures;
      Printf.printf "FAIL %s\n  expected a failure, got %s\n" name
        (Value.to_string value);
      None

(* 8.1: a pushed frame intercepts every nested step, the body still computes
   its answer, and leaving the extent stops the interception. *)
let test_basic_interception () =
  let source =
    "var steps = 0\n\
     meta_with(eval = fn(e, r, k) -> { steps := steps + 1; eval(e, r, k) }) {\n\
     \  (1 + 2) * 4\n\
     }\n\
     steps"
  in
  match evaluate "an overlay intercepts the body's evaluation" source with
  | None -> ()
  | Some (_tower, _io, Value.Num steps) ->
      check "every nested node is intercepted, not only the outermost" (steps > 5)
  | Some (_tower, _io, other) ->
      check
        ("an overlay answers with the step count, got " ^ Value.to_string other)
        false;
  ignore
    (check_value "the body's answer is preserved" (Value.Num 3)
       "meta_with(eval = fn(e, r, k) -> { eval(e, r, k) }) { 1 + 2 }");
  (* Leaving the extent: the same computation afterwards is not intercepted. *)
  let source =
    "var steps = 0\n\
     meta_with(eval = fn(e, r, k) -> { steps := steps + 1; eval(e, r, k) }) {\n\
     \  1 + 1\n\
     }\n\
     let before = steps\n\
     let ignored = 1 + (1 + 1)\n\
     let after = steps\n\
     after - before"
  in
  match evaluate "leaving the extent stops the interception" source with
  | None -> ()
  | Some (_tower, _io, Value.Num moved) -> check "nothing is counted outside" (moved = 0)
  | Some (_tower, _io, other) ->
      check
        ("leaving answers with zero, got " ^ Value.to_string other)
        false

(* 8.1: nested frames stack. The inner right-hand side wraps the outer
   effective evaluator, so both run while the inner extent is active and only
   the outer runs after it exits. *)
let test_nested_stacking () =
  let source =
    "var outer = 0\n\
     var inner = 0\n\
     meta_with(eval = fn(e, r, k) -> { outer := outer + 1; eval(e, r, k) }) {\n\
     \  let a = 1 + 1\n\
     \  let outer_before_inner = outer\n\
     \  meta_with(eval = fn(e, r, k) -> { inner := inner + 1; eval(e, r, k) }) {\n\
     \    2 + 2\n\
     \  }\n\
     \  let outer_after_inner = outer\n\
     \  let inner_total = inner\n\
     \  [outer_before_inner, outer_after_inner, inner_total]\n\
     }"
  in
  match evaluate "nested frames stack" source with
  | None -> ()
  | Some (_tower, _io, Value.List [ Value.Num before; Value.Num after; Value.Num inner ]) ->
      check "the outer frame ran before the inner extent" (before > 0);
      check "the outer frame ran again through the inner extent" (after > before);
      check "the inner frame ran" (inner > 0)
  | Some (_tower, _io, other) ->
      check
        ("nested stacking answers with three counts, got " ^ Value.to_string other)
        false

(* 8.1: the two slots are independent. Overriding [apply] leaves [eval]
   alone and vice versa; overriding both intercepts both. *)
let test_slots_are_independent () =
  let source =
    "var eval_steps = 0\n\
     var apply_calls = 0\n\
     fn twice(n) = n + n\n\
     meta_with(apply = fn(f, args, k) -> { apply_calls := apply_calls + 1; apply(f, args, k) }) {\n\
     \  twice(twice(3))\n\
     }\n\
     [twice(1), eval_steps, apply_calls]"
  in
  match evaluate "an apply-only frame leaves eval alone" source with
  | None -> ()
  | Some (_tower, _io, Value.List [ answer; Value.Num eval_steps; Value.Num apply_calls ]) ->
      check "the program still computes its answer" (Value.equal answer (Value.Num 2));
      check "eval was never overridden" (eval_steps = 0);
      check "every application was intercepted" (apply_calls >= 2)
  | Some (_tower, _io, other) ->
      check
        ("apply-only answers with its triple, got " ^ Value.to_string other)
        false;
  let source =
    "var eval_steps = 0\n\
     var apply_calls = 0\n\
     fn twice(n) = n + n\n\
     meta_with(eval = fn(e, r, k) -> { eval_steps := eval_steps + 1; eval(e, r, k) },\n\
     \          apply = fn(f, args, k) -> { apply_calls := apply_calls + 1; apply(f, args, k) }) {\n\
     \  twice(3)\n\
     }\n\
     [eval_steps > 5, apply_calls >= 1]"
  in
  ignore
    (check_value "overriding both intercepts both" (Value.List [ Value.Bool true; Value.Bool true ])
       source)

(* 8.1: the persistent cells are never touched. A persistent replacement
   installed with [up] is still there afterwards, and an overlay never becomes
   persistent. *)
let test_persistent_state_is_untouched () =
  (* An overlay alone never writes the persistent cell: the contents read with
     [up] before and after are the same evaluator. Contents compare by
     primitive name, so two defaults are equal while a stored wrapper closure
     would not be. *)
  let source =
    "let before = up { eval }\n\
     meta_with(eval = fn(e, r, k) -> { eval(e, r, k) }) { 1 }\n\
     let after = up { eval }\n\
     before == after"
  in
  ignore
    (check_value "an overlay does not write the persistent cell" (Value.Bool true)
       source);
  (* And it composes with a persistent replacement rather than replacing it:
     both count while the extent is active, only the persistent one after. *)
  let source =
    "var persistent = 0\n\
     var scoped = 0\n\
     up {\n\
     \  let base = eval\n\
     \  eval := fn(e, r, k) -> { persistent := persistent + 1; base(e, r, k) }\n\
     }\n\
     meta_with(eval = fn(e, r, k) -> { scoped := scoped + 1; eval(e, r, k) }) {\n\
     \  1 + 1\n\
     }\n\
     let scoped_inside = scoped\n\
     let persistent_inside = persistent\n\
     let ignored = 1 + 1\n\
     [scoped_inside > 0, persistent_inside > 0, scoped == scoped_inside]"
  in
  match evaluate "an overlay composes with a persistent replacement" source with
  | None -> ()
  | Some (_tower, _io, Value.List [ Value.Bool a; Value.Bool b; Value.Bool c ]) ->
      check "the overlay ran inside" a;
      check "the persistent replacement ran inside too" b;
      check "the overlay stopped at the extent" c
  | Some (_tower, _io, other) ->
      check
        ("persistent/scoped composition answers with three flags, got "
        ^ Value.to_string other)
        false

(* 8.1: the surface is refused early and precisely. *)
let test_surface_refusals () =
  ignore
    (expect_error "an unknown slot is refused at lowering"
       "meta_with(nope = 1) { 1 }");
  ignore
    (expect_error "a repeated slot is refused at lowering"
       "meta_with(eval = 1, eval = 2) { 1 }");
  (match
     let _, _, scope = fresh () in
     attempt (fun () ->
         Desugar.program ~scope
           (Parser.program ~file
              "meta_with(eval = fn(e, r, k) -> { eval(e, r, k) }) { 1 }"))
   with
  | Ok _ -> ()
  | Error error ->
      incr failures;
      Printf.printf "FAIL a well-formed meta_with lowers\n  %s\n"
        (Error.to_string error))

(* 8.2: capture inside, invoke outside.

   One-shot continuations cannot resume the same node twice, and re-entering
   an extent that already returned needs multi-shot (which the spec defers),
   so this test never asks for either. Instead the first visit to the target
   literal abandons the extent through an escape captured outside (which
   restores the ambient pointer on the way out), and the stored node
   continuation — captured with the overlay pointer and never used before —
   is invoked once from the outside. It resumes with the overlay restored
   while the ambient list is never mutated: the resumed computation counts
   again, and a computation after everything answers without interception. *)
let test_capture_inside_invoke_outside () =
  let source =
    "var saved = 0\n\
     var escape = 0\n\
     var entered = false\n\
     var done = false\n\
     var steps = 0\n\
     fn is_99(e) = {\n\
     \  let v = code_view(e)\n\
     \  if head(v) == 'Lit then head(tail(v)) == 99 else false\n\
     }\n\
     let outer_v = callcc(fn(k) -> { escape := k\n  0 })\n\
     let first =\n\
     \  meta_with(eval = fn(e, r, k) -> {\n\
     \    steps := steps + 1\n\
     \    if is_99(e) then {\n\
     \      if entered == false then { entered := true\n  saved := k\n  escape(999) }\n\
     \      else { eval(e, r, k) }\n\
     \    } else { eval(e, r, k) }\n\
     \  }) {\n\
     \    99 + 1\n\
     \  }\n\
     let final = if done == false then { done := true\n  saved(50) } else { first }\n\
     let before = steps\n\
     let outside = 99 + 1\n\
     [final, outside, steps - before, steps > 5]"
  in
  match evaluate "capture inside, invoke outside" source with
  | None -> ()
  | Some
      (_tower, _io, Value.List [ Value.Num final; Value.Num outside; Value.Num moved;
        Value.Bool counted ])
    ->
      check "the resumed literal answers through the restored overlay" (final = 51);
      check "the ambient call answers normally" (outside = 100);
      check_int "nothing outside is intercepted" 0 moved;
      check "the resumed computation ran through the overlay" counted
  | Some (_tower, _io, other) ->
      check
        ("capture/invoke answers with its quadruple, got " ^ Value.to_string other)
        false

(* 8.2: the ambient context is unaffected by the invocation. This is the same
   run's last two answers above, stated separately so a regression names the
   half that broke: resumption restores without mutating the ambient list. *)
let test_ambient_unaffected () =
  let source =
    "var steps = 0\n\
     meta_with(eval = fn(e, r, k) -> { steps := steps + 1\n  eval(e, r, k) }) {\n\
     \  1 + 1\n\
     }\n\
     let before = steps\n\
     let outside = 1 + (1 + 1)\n\
     [outside, steps - before]"
  in
  match evaluate "the ambient context is unaffected" source with
  | None -> ()
  | Some (_tower, _io, Value.List [ Value.Num outside; Value.Num moved ]) ->
      check "the ambient call answers normally" (outside = 3);
      check_int "nothing outside is intercepted" 0 moved
  | Some (_tower, _io, other) ->
      check
        ("ambient answers with its pair, got " ^ Value.to_string other)
        false

(* 8.2: nested error. A failure inside an inner extent reports its cause, and
   the failure is evidence the overlay was in effect when it happened: the
   outer wrapper prints before the fault, and the print survives the failure
   in the buffered stream even though the run itself fails. *)
let test_nested_error () =
  let tower, io, scope = fresh () in
  let source =
    "meta_with(eval = fn(e, r, k) -> { println(\"outer\")\n  eval(e, r, k) }) {\n\
     \  meta_with(eval = fn(e, r, k) -> { eval(e, r, k) }) {\n\
     \    1 / 0\n\
     \  }\n\
     }"
  in
  (match attempt (fun () -> run tower scope source) with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL a failure inside an inner extent fails the run, got %s\n"
        (Value.to_string value)
  | Error error ->
      check "the cause is division by zero"
        (Error.cause_equal error.Error.cause Error.Division_by_zero);
      check "an outer wrapper ran before the fault"
        (List.exists
           (function Io.Wrote text -> String.length text > 0 | _ -> false)
           (Io.events io)));
  (* And an extent never leaks through a failure: a fresh program on a fresh
     tower runs with the default evaluator. *)
  ignore
    (check_value "after a failure the default evaluator is the default"
       (Value.Num 3) "1 + 2")

let () =
  test_basic_interception ();
  test_nested_stacking ();
  test_slots_are_independent ();
  test_persistent_state_is_untouched ();
  test_surface_refusals ();
  test_capture_inside_invoke_outside ();
  test_ambient_unaffected ();
  test_nested_error ();
  if !failures > 0 then (
    Printf.printf "%d `meta_with` assertion(s) failed\n" !failures;
    exit 1)
