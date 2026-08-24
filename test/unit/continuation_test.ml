(* First-class one-shot continuations (to-do task 1.5).

   The point of D4 is that these are first class and not escape-only: a
   continuation can be stored, carried across function boundaries, and invoked
   after the call that captured it has already returned. What it cannot be is
   invoked twice, and the second attempt must say where the continuation came
   from and where it already went. *)

open Ash_core
open Ash_syntax
open Ash_runtime

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "k.ash"

let ground () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  ( Desugar.scope_of_globals named,
    Core_reader.scope_of_list named,
    Env.extend globals Value.empty_env )

let lower source =
  let scope, _, _ = ground () in
  Desugar.program ~scope (Parser.program ~file source)

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

let run source =
  let scope, _, env = ground () in
  Evaluator.eval ~env (Desugar.program ~scope (Parser.program ~file source))

let check_value name expected source =
  match attempt (fun () -> run source) with
  | Ok actual ->
      if not (Value.equal expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Value.to_string expected) (Value.to_string actual))
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name (Error.to_string error)

let check_error name ~cause source =
  match attempt (fun () -> run source) with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an error, got %s\n" name (Value.to_string value)
  | Error error ->
      if not (Error.cause_equal error.Error.cause cause) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Error.cause_message cause) (Error.to_string error))

(* {1 Capturing} *)

let test_capture () =
  check_value "a receiver that returns normally gives its value" (Value.Num 42)
    "callcc(fn(k) -> 42)";
  (* What is captured is the continuation of the [callcc] call, so invoking it
     resumes the enclosing addition rather than returning from the program. *)
  check_value "the continuation includes what encloses the call" (Value.Num 11)
    "1 + callcc(fn(k) -> k(10))";
  (* 101 would mean the transfer returned into the receiver instead of past it. *)
  check_value "the rest of the receiver is abandoned" (Value.Num 3)
    "1 + callcc(fn(k) -> { k(2)\n  100 })";
  check_value "escaping from a recursion" (Value.Num 7)
    "fn find(xs, target, escape) =\n\
    \  if empty?(xs) then 0\n\
    \  else if head(xs) == target then escape(target)\n\
    \  else find(tail(xs), target, escape)\n\
     callcc(fn(k) -> find([1, 3, 7, 9], 7, k)) + 0";
  check_value "not escaping returns normally" (Value.Num 0)
    "fn find(xs, target, escape) =\n\
    \  if empty?(xs) then 0\n\
    \  else if head(xs) == target then escape(target)\n\
    \  else find(tail(xs), target, escape)\n\
     callcc(fn(k) -> find([1, 3], 7, k))"

(* {1 First class}

   Storable, carried across a function boundary, and invoked after the call that
   captured it has returned — none of which an escape-only continuation can do. *)

let test_first_class () =
  check_value "a stored continuation is invoked after its capture returned"
    (Value.Num 1)
    "var saved = 0\n\
     let v = callcc(fn(k) -> { saved := k\n  0 })\n\
     if v == 0 then saved(1) else v";
  check_value "captured in one function, invoked from another" (Value.Num 7)
    "var saved = 0\n\
     fn capture() = callcc(fn(k) -> { saved := k\n  'fresh })\n\
     fn resume(v) = saved(v)\n\
     let first = capture()\n\
     if first == 'fresh then resume(7) else first";
  check_value "a continuation survives in a data structure" (Value.Num 5)
    "var saved = []\n\
     let v = callcc(fn(k) -> { saved := [k]\n  0 })\n\
     if v == 0 then head(saved)(5) else v";
  (* A continuation is a value like any other: comparing one with itself is
     identity, and it is not equal to a different one. *)
  check_value "a continuation is equal to itself" (Value.Bool true)
    "var saved = 0\n\
     let v = callcc(fn(k) -> { saved := k\n  0 })\n\
     saved == saved"

(* {1 One shot} *)

let reuse_program =
  "var saved = 0\n\
   let v = callcc(fn(k) -> { saved := k\n  0 })\n\
   if v == 0 then saved(1) else saved(2)"

let test_one_shot () =
  (match attempt (fun () -> run reuse_program) with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL a second invocation must fail, got %s\n" (Value.to_string value)
  | Error error -> (
      check "a second invocation is reported at the evaluate phase"
        (error.Error.phase = Error.Evaluate);
      (* The meta-context travels with the continuation: the error belongs to the
         level whose evaluation it would have resumed. *)
      check "the reuse error carries the continuation's level"
        (error.Error.level = Some 0);
      match error.Error.cause with
      | Error.Continuation_reuse { captured; first_used } ->
          (* Three distinct places, and the diagnostic has all three: where it was
             captured, where it went, and where the mistake was written. *)
          check "the capture site is where callcc was written"
            (not (Span.equal captured error.Error.span));
          check "the first use is not the capture site"
            (not (Span.equal captured first_used));
          check "the second use is reported at its own site"
            (not (Span.equal first_used error.Error.span));
          check "every site is real source"
            (List.for_all
               (fun span -> String.equal (Span.file span) file && not (Span.is_unknown span))
               [ captured; first_used; error.Error.span ])
      | Error.Unbound_ident _ | Error.Unbound_name _ | Error.Ambiguous_name _
      | Error.Unfilled_binding _ | Error.Unexpected_character _ | Error.Unterminated _
      | Error.Unexpected _ | Error.Unknown_form _ | Error.Malformed_form _
      | Error.Arity_error _ | Error.Unsupported _ | Error.Division_by_zero
      | Error.Meta_error _ | Error.Immutable_binding _ | Error.No_matching_clause _
      | Error.Duplicate_binder _ | Error.Open_code _ | Error.Unliftable_value _
      | Error.Inconsistent_pattern_binders _ | Error.End_of_input | Error.Budget_exhausted _ ->
          incr failures;
          Printf.printf "FAIL a second invocation reported the wrong cause: %s\n"
            (Error.to_string error)));

  (* The flag is set before the transfer, so a continuation reached again through
     its own resumption is caught rather than looping. *)
  check "reuse through the continuation's own resumption is caught"
    (match
       attempt (fun () ->
           run
             "var saved = 0\n\
              var n = 0\n\
              let v = callcc(fn(k) -> { saved := k\n  0 })\n\
              n := n + 1\n\
              if n < 3 then saved(n) else v")
     with
    | Error { Error.cause = Error.Continuation_reuse _; _ } -> true
    | Ok _ | Error _ -> false)

(* {1 Arity} *)

let test_arity () =
  check_error "a continuation takes exactly one value"
    ~cause:(Error.Arity_error { callee = Some "continuation"; expected = "1"; actual = 0 })
    "callcc(fn(k) -> k())";
  check_error "and refuses two"
    ~cause:(Error.Arity_error { callee = Some "continuation"; expected = "1"; actual = 2 })
    "callcc(fn(k) -> k(1, 2))";
  check_error "callcc takes exactly one receiver"
    ~cause:(Error.Arity_error { callee = Some "callcc"; expected = "1"; actual = 0 })
    "callcc()";
  check_error "callcc applies its argument, so a non-function is a type error"
    ~cause:(Error.Unexpected { found = "a number"; expected = "a function" })
    "callcc(1)"

(* {1 The oracle does not grow up} *)

let test_oracle_refuses () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let env = Env.extend globals Value.empty_env in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Desugar.scope_of_globals named in
  let term = Desugar.program ~scope (Parser.program ~file "callcc(fn(k) -> 1)") in
  (match attempt (fun () -> Oracle.eval ~env term) with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL the oracle ran a control primitive, giving %s\n"
        (Value.to_string value)
  | Error error ->
      check "the oracle refuses callcc by name"
        (Error.cause_equal error.Error.cause
           (Error.Unsupported { what = "callcc"; by = "the direct-style oracle" })));
  (* And it refuses a continuation value even if one reaches it, so nothing can
     smuggle control into the frozen evaluator. *)
  let kont = Ident.fresh "kont" in
  let env =
    Env.extend
      [ (kont, Value.Continuation (Value.continuation ~capture:Span.unknown ~level:0 (fun v -> v))) ]
      Value.empty_env
  in
  let read_scope = Core_reader.scope_of_list [ ("kont", kont) ] in
  match
    attempt (fun () ->
        Oracle.eval ~env
          (Core_reader.read ~scope:read_scope ~file "(app (var kont) (lit 1))"))
  with
  | Ok _ ->
      incr failures;
      Printf.printf "FAIL the oracle applied a continuation\n"
  | Error error ->
      check "the oracle refuses to apply a continuation"
        (Error.cause_equal error.Error.cause
           (Error.Unsupported { what = "continuation"; by = "the direct-style oracle" }))

(* {1 The captured continuation is the machine's} *)

let test_open_recursion () =
  (* A primitive that calls back into Ash goes through the machine's apply cell,
     so a replaced apply sees the call [callcc] makes. If it did not, a meta
     level could not intercept a control primitive's callback (§D3). *)
  let scope, _, env = ground () in
  let term = Desugar.program ~scope (Parser.program ~file "callcc(fn(k) -> 1)") in
  let machine = Evaluator.machine () in
  let seen = ref 0 in
  let inner = Machine.current_apply machine in
  Machine.set_apply machine (fun machine ~call_site callee arguments k ->
      (match callee with Value.Closure _ -> incr seen | _ -> ());
      inner machine ~call_site callee arguments k);
  let value = Evaluator.run machine ~env term in
  check "the receiver was applied" (Value.equal (Value.Num 1) value);
  check "and the replaced apply saw it" (!seen = 1)

(* {1 Shape} *)

let test_lowering () =
  (* [callcc] is an ordinary global, not syntax: the desugarer emits a plain call
     and nothing about control appears in Core. *)
  let lowered = lower "callcc(fn(k) -> k(1))" in
  check "callcc lowers to an ordinary application"
    (match Core.shape lowered with Core.App _ -> true | _ -> false);
  check "and needs no new Core form"
    (List.for_all
       (fun name -> not (String.equal name "callcc"))
       (List.map Core.kind_name (Core.children lowered)))

let () =
  test_capture ();
  test_first_class ();
  test_one_shot ();
  test_arity ();
  test_oracle_refuses ();
  test_open_recursion ();
  test_lowering ();
  if !failures > 0 then (
    Printf.printf "%d continuation assertion(s) failed\n" !failures;
    exit 1)
