(* Closed-code analysis and execution (to-do task 3.2). *)

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

let file = "run.ash"

let ground ?io () =
  let registry =
    match io with
    | None -> Primitives.create ()
    | Some stream -> Primitives.create ~io:stream ()
  in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Desugar.scope_of_globals named in
  let env = Env.extend globals Value.empty_env in
  (registry, scope, env)

let evaluate ?io source =
  let registry, scope, env = ground ?io () in
  let term = Desugar.program ~scope (Parser.program ~file source) in
  (registry, Evaluator.eval ~env term)

let attempt f =
  match f () with
  | value -> Ok value
  | exception Error.Ash_error error -> Error error

let check_value name expected source =
  match attempt (fun () -> snd (evaluate source)) with
  | Ok actual ->
      if not (Value.equal expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Value.to_string expected) (Value.to_string actual))
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name
        (Error.to_string error)

let test_closed_code_runs () =
  check_value "closed arithmetic runs" (Value.Num 7) "run(`{ 1 + 2 * 3 })";
  check_value "a closed generated closure runs" (Value.Num 42)
    "let succ = run(`{ fn(x) -> x + 1 })\nsucc(41)";
  check_value "closed recursive code runs" (Value.Num 120)
    (String.concat "\n"
       [
         "let fact = run(`{ {";
         "  fn fact(n) = if n == 0 then 1 else n * fact(n - 1)";
         "  fact";
         "} })";
         "fact(5)";
       ]);
  let io = Io.create () in
  let _, value = evaluate ~io "run(`{ println(\"from run\") })" in
  check "effects use the registry's global primitive"
    (Value.equal Value.Unit value);
  check_string "effects retain the ordinary observable stream" "from run\n"
    (Io.text io)

let test_open_code_reports_every_dependency () =
  let source = "run(`{ x + y + x })" in
  match attempt (fun () -> snd (evaluate source)) with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL open code was accepted, returning %s\n"
        (Value.to_string value)
  | Error error -> (
      check "open code is rejected during evaluation"
        (error.Error.phase = Error.Evaluate);
      check_string "the run call is the primary diagnostic site" "run.ash:1:1-20"
        (Span.to_string error.Error.span);
      match error.Error.cause with
      | Error.Open_code dependencies ->
          check_int "both unresolved identities are reported" 2
            (List.length dependencies);
          check "dependencies follow first source occurrence"
            (List.equal String.equal [ "x"; "y" ]
               (List.map (fun dependency -> Ident.name dependency.Code.ident) dependencies));
          check "every occurrence of each identity is retained"
            (match dependencies with
            | [ x; y ] ->
                List.length x.Code.occurrences = 2
                && List.length y.Code.occurrences = 1
            | [] | [ _ ] | _ :: _ :: _ -> false);
          check "dependency locations point into the quoted source"
            (List.for_all
               (fun dependency ->
                 List.for_all
                   (fun span -> String.equal (Span.file span) file)
                   dependency.Code.occurrences)
               dependencies);
          check_string "the rendered cause includes every use location"
            "code is open; unresolved dependencies: `x` at run.ash:1:8-9, run.ash:1:16-17; `y` at run.ash:1:12-13"
            (Error.cause_message error.Error.cause)
      | Error.Unbound_ident _ | Error.Unbound_name _ | Error.Ambiguous_name _
      | Error.Unfilled_binding _ | Error.Unexpected_character _ | Error.Unterminated _
      | Error.Unexpected _ | Error.Unknown_form _ | Error.Malformed_form _
      | Error.Arity_error _ | Error.Unsupported _ | Error.Division_by_zero
      | Error.Continuation_reuse _ | Error.Meta_error _ | Error.Immutable_binding _
      | Error.No_matching_clause _ | Error.Duplicate_binder _
      | Error.Unliftable_value _ | Error.Inconsistent_pattern_binders _
      | Error.End_of_input | Error.Budget_exhausted _ ->
          incr failures;
          Printf.printf "FAIL open code reported the wrong cause: %s\n"
            (Error.to_string error))

let test_run_does_not_inherit_lexical_state () =
  match attempt (fun () -> snd (evaluate "let x = 40\nrun(`{ x + 2 })")) with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL run inherited its caller's x, returning %s\n"
        (Value.to_string value)
  | Error { Error.cause = Error.Open_code [ dependency ]; _ } ->
      check_string "the caller binding remains an unresolved dependency" "x"
        (Ident.name dependency.Code.ident);
      check_string "the dependency points to the quote, not the caller binding"
        "run.ash:2:8-9"
        (Span.to_string (List.hd dependency.Code.occurrences))
  | Error error ->
      incr failures;
      Printf.printf "FAIL lexical isolation reported the wrong error: %s\n"
        (Error.to_string error);

  (* [NamedVar] asks explicitly for name lookup, but [run] still gives it only
     the global environment. The lexical [x] is therefore not visible. *)
  match attempt (fun () -> snd (evaluate "let x = 40\nrun(NamedVar(\"x\"))")) with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL NamedVar inherited its caller's x, returning %s\n"
        (Value.to_string value)
  | Error error ->
      check "explicit lookup happens after closedness analysis"
        (Error.cause_equal error.Error.cause (Error.Unbound_name "x"));
      check_string "explicit lookup keeps the generated Code location"
        "run.ash:2:5-18 (generated by desugar/call): evaluate error: no binding named `x` in this environment"
        (Error.to_string error)

let test_closedness_rules () =
  let span = Span.unknown in
  let x = Ident.fresh "x" in
  let y = Ident.fresh "y" in
  let global = Ident.fresh "+" in
  let body =
    Core.app ~span ~func:(Core.var ~span global)
      ~args:[ Core.var ~span x; Core.var ~span y ]
  in
  let bound_x = Core.lam ~span ~params:[ x ] ~body in
  let unresolved =
    Code.unresolved_dependencies ~available:(Ident.Set.singleton global) bound_x
  in
  check "lambda binders close their exact identities"
    (match unresolved with
    | [ dependency ] -> Ident.equal dependency.Code.ident y
    | [] | _ :: _ :: _ -> false);
  check "is_closed uses the same analysis"
    (Code.is_closed
       ~available:(Ident.Set.add y (Ident.Set.singleton global))
       bound_x);
  let nested_quote = Core.quote ~span (Core.var ~span y) in
  check "a nested quotation retains its lexical dependency"
    (match Code.unresolved_dependencies ~available:Ident.Set.empty nested_quote with
    | [ dependency ] -> Ident.equal dependency.Code.ident y
    | [] | _ :: _ :: _ -> false);
  check "a Set target is a dependency"
    (match
       Code.unresolved_dependencies ~available:Ident.Set.empty
         (Core.set ~span ~target:y ~value:(Core.lit ~span Constant.Unit))
     with
    | [ dependency ] -> Ident.equal dependency.Code.ident y
    | [] | _ :: _ :: _ -> false);
  let exp = Ident.fresh "exp" in
  let env = Ident.fresh "env" in
  let cont = Ident.fresh "cont" in
  check "reifier parameters bind their body"
    (Code.is_closed ~available:Ident.Set.empty
       (Core.reifier ~span ~exp ~env ~cont ~body:(Core.var ~span exp)));
  check "NamedVar is explicit lookup, not an unresolved lexical identity"
    (Code.is_closed ~available:Ident.Set.empty (Core.named_var ~span "x"))

let test_run_type_error () =
  match attempt (fun () -> snd (evaluate "run(1)")) with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL run accepted a number, returning %s\n" (Value.to_string value)
  | Error error ->
      check "run requires Code"
        (Error.cause_equal error.Error.cause
           (Error.Unexpected { found = "a number"; expected = "code" }));
      check_string "run's type error is at its call" "run.ash:1:1-7"
        (Span.to_string error.Error.span)

let () =
  test_closed_code_runs ();
  test_open_code_reports_every_dependency ();
  test_run_does_not_inherit_lexical_state ();
  test_closedness_rules ();
  test_run_type_error ();
  if !failures > 0 then (
    Printf.printf "%d run assertion(s) failed\n" !failures;
    exit 1)
