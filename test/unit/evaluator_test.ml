(* Unit tests for the CPS evaluator and its machine (to-do task 0.8). *)

open Ash_core
open Ash_syntax
open Ash_runtime

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_int name expected actual =
  if not (Int.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %d\n  actual:   %d\n" name expected actual)

let check_string name expected actual =
  if not (String.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name expected actual)

let sp =
  Span.make
    ~start:(Span.position ~file:"e.ash" ~line:1 ~column:1 ~offset:0)
    ~stop:(Span.position ~file:"e.ash" ~line:1 ~column:2 ~offset:1)

let ground () =
  let globals = Primitives.globals (Primitives.create ()) in
  let scope =
    Core_reader.scope_of_list
      (List.map (fun (ident, _) -> (Ident.name ident, ident)) globals)
  in
  (Env.extend globals Value.empty_env, scope)

let read_with scope text = Core_reader.read ~scope ~file:"e.ash" text

let run text =
  let env, scope = ground () in
  Evaluator.eval ~env (read_with scope text)

let check_value name expected text =
  match run text with
  | actual ->
      if not (Value.equal expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Value.to_string expected) (Value.to_string actual))
  | exception Error.Ash_error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name (Error.to_string error)

let check_error name ~cause text =
  match run text with
  | value ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an error, got %s\n" name (Value.to_string value)
  | exception Error.Ash_error error ->
      if not (Error.cause_equal error.Error.cause cause) then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong cause: %s\n" name (Error.to_string error))

let factorial n =
  Printf.sprintf
    "(letrec ((fact (lam (n)\n\
    \                 (if (app (var ==) (var n) (lit 0))\n\
    \                     (lit 1)\n\
    \                     (app (var *) (var n) (app (var fact) (app (var -) (var n) (lit 1))))))))\n\
    \  (app (var fact) (lit %d)))"
    n

(* The acceptance fixture *)

let test_factorial () =
  check_value "fact(20)" (Value.Num 2432902008176640000) (factorial 20);
  check_value "fact(0)" (Value.Num 1) (factorial 0);
  check_value "fact(5)" (Value.Num 120) (factorial 5)

(* CPS keeps the host stack flat *)

let test_tail_calls () =
  (* An Ash tail call passes the continuation through unchanged and every host
     call is in tail position, so this must not grow the host stack. In direct
     style the same program would need a hundred thousand host frames. *)
  check_value "a hundred thousand tail calls" (Value.Num 100000)
    "(letrec ((loop (lam (n acc)\n\
    \                 (if (app (var ==) (var n) (lit 0))\n\
    \                     (var acc)\n\
    \                     (app (var loop) (app (var -) (var n) (lit 1))\n\
    \                                     (app (var +) (var acc) (lit 1)))))))\n\
    \  (app (var loop) (lit 100000) (lit 0)))"

(* Open recursion: the invariant the tower rests on *)

let test_open_recursion () =
  let env, scope = ground () in
  let term = read_with scope "(app (lam (x) (app (var +) (var x) (lit 1))) (lit 2))" in
  let machine = Evaluator.machine () in
  let base = Machine.current_eval machine in
  let seen = ref [] in
  (* Exactly the shape of the spec's money demo: wrap the eval cell and watch. *)
  Machine.set_eval machine (fun m node environment k ->
      seen := Core.kind_name node :: !seen;
      base m node environment k);
  let result = Evaluator.run machine ~env term in
  check "a wrapped evaluator still computes" (Value.equal (Value.Num 3) result);
  let observed = List.rev !seen in
  (* An evaluator holding a direct self-reference would report exactly one node:
     the root. Every nested node must appear. *)
  check "wrapping eval observes more than the root" (List.length observed > 1);
  check_string "wrapping eval observes every nested node"
    "app; lam; lit; app; var; var; lit" (String.concat "; " observed);

  (* The same for apply: replacing the cell intercepts every application, not
     just the outermost one. *)
  let machine = Evaluator.machine () in
  let applications = ref 0 in
  let base_apply = Machine.current_apply machine in
  Machine.set_apply machine (fun m ~call_site callee arguments k ->
      incr applications;
      base_apply m ~call_site callee arguments k);
  let env, scope = ground () in
  let term = read_with scope "(app (var +) (app (var +) (lit 1) (lit 2)) (lit 3))" in
  check "a wrapped apply still computes"
    (Value.equal (Value.Num 6) (Evaluator.run machine ~env term));
  check_int "wrapping apply intercepts every application" 2 !applications;

  (* A replacement is free to short-circuit, and the change takes effect from the
     next step rather than the next top-level evaluation. *)
  let machine = Evaluator.machine () in
  Machine.set_eval machine (fun _ node _ k ->
      match Core.shape node with
      | Core.Lit _ -> k (Value.Num 99)
      | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          k Value.Unit);
  let env, scope = ground () in
  check "a replacement takes effect immediately"
    (Value.equal (Value.Num 99) (Evaluator.run machine ~env (read_with scope "(lit 1)")))

(* Instrumentation *)

let test_counters () =
  let env, scope = ground () in
  let machine = Evaluator.machine () in
  let (_ : Value.value) = Evaluator.run machine ~env (read_with scope "(lit 1)") in
  check_int "a literal is one step" 1 (Machine.steps machine);
  check_int "and one dispatch" 1 (Machine.total_dispatches machine);
  check_int "counted against its own form" 1
    (List.assoc "lit" (Machine.dispatches machine));

  (* The cost model of one application, written down: four eval calls, two
     eval-list calls (the arguments and the empty tail), and one apply. *)
  let env, scope = ground () in
  let machine = Evaluator.machine () in
  let (_ : Value.value) =
    Evaluator.run machine ~env (read_with scope "(app (lam (x) (var x)) (lit 1))")
  in
  check_int "eval calls" 4 (Machine.eval_calls machine);
  check_int "eval-list calls" 2 (Machine.eval_list_calls machine);
  check_int "apply calls" 1 (Machine.apply_calls machine);
  check_int "steps are the sum" 7 (Machine.steps machine);
  (* Every group call is a cell dereference: that is the tower's per-step cost
     and the site the collapser has to eliminate. *)
  check_int "every step dereferenced a cell" 7 (Machine.cell_dereferences machine);
  check_string "dispatches are counted per form" "lit=1; var=1; lam=1; app=1"
    (String.concat "; "
       (List.filter_map
          (fun (name, count) ->
            if count = 0 then None else Some (Printf.sprintf "%s=%d" name count))
          (Machine.dispatches machine)));

  check "every Core form has a dispatch slot"
    (List.length (Machine.dispatches machine) = Core.kind_count);
  check "dispatch slots are named after the forms"
    (List.equal String.equal Core.kind_names
       (List.map fst (Machine.dispatches machine)));

  Machine.reset_counters machine;
  check_int "counters reset" 0 (Machine.steps machine);
  check_int "dispatches reset" 0 (Machine.total_dispatches machine);

  (* Counting cannot change what a program computes. *)
  let env, scope = ground () in
  let machine = Evaluator.machine () in
  let with_counting = Evaluator.run machine ~env (read_with scope (factorial 10)) in
  let env, scope = ground () in
  let plain = Evaluator.eval ~env (read_with scope (factorial 10)) in
  check "instrumentation is inert" (Value.equal with_counting plain);
  check "and it did count" (Machine.steps machine > 0)

(* Forms the oracle refuses but the real evaluator handles *)

let test_reflective_forms () =
  let x = Ident.fresh "x" in
  let env = Env.extend [ (x, Value.Num 7) ] Value.empty_env in
  let machine = Evaluator.machine () in
  let term = Core_reader.read ~file:"e.ash" "(named-var \"x\")" in
  check "a named variable resolves against the environment"
    (Value.equal (Value.Num 7) (Evaluator.run machine ~env term));
  check_int "and the lookup is counted" 1 (Machine.named_var_lookups machine);
  (match Core_reader.read ~file:"e.ash" "(named-var \"nope\")" with
  | term -> (
      match Evaluator.eval ~env term with
      | (_ : Value.value) ->
          incr failures;
          Printf.printf "FAIL an unresolved name is an error\n"
      | exception Error.Ash_error error ->
          check "an unresolved name is an error"
            (Error.cause_equal error.Error.cause (Error.Unbound_name "nope"))));

  check "quotation yields the code as a value"
    (match run "(quote (lit 1))" with
    | Value.Code quoted -> String.equal "lit" (Core.kind_name quoted)
    | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
    | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
        false);
  check "a quoted term is not evaluated"
    (match run "(quote (app (var /) (lit 1) (lit 0)))" with
    | Value.Code _ -> true
    | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.List _ | Value.Closure _ | Value.Continuation _ | Value.Reifier _
    | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
        false);
  check "a reifier form yields a reifier value"
    (match run "(reifier (e r k) (var e))" with
    | Value.Reifier _ -> true
    | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.List _ | Value.Closure _ | Value.Continuation _ | Value.Code _
    | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
        false);

  (* What is honestly not built yet says so, and says which piece is missing. *)
  let refused what = Error.Unsupported { what; by = "the ground evaluator" } in
  check_error "applying a reifier awaits the level above"
    ~cause:(refused "reifier application")
    "(app (reifier (e r k) (var e)) (lit 1))";
  let kont = Ident.fresh "kont" in
  let env =
    Env.extend
      [ (kont, Value.Continuation (Value.continuation ~capture:sp (fun v -> v))) ]
      Value.empty_env
  in
  let scope = Core_reader.scope_of_list [ ("kont", kont) ] in
  match Evaluator.eval ~env (read_with scope "(app (var kont) (lit 1))") with
  | (_ : Value.value) ->
      incr failures;
      Printf.printf "FAIL applying a continuation awaits one-shot enforcement\n"
  | exception Error.Ash_error error ->
      check "applying a continuation awaits one-shot enforcement"
        (Error.cause_equal error.Error.cause (refused "continuation application"))

let () =
  test_factorial ();
  test_tail_calls ();
  test_open_recursion ();
  test_counters ();
  test_reflective_forms ();
  if !failures > 0 then (
    Printf.printf "%d evaluator assertion(s) failed\n" !failures;
    exit 1)
