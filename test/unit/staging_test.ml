(* End-to-end staging regressions from spec §4.3--§4.4 (to-do task 3.4). *)

open Ash_core
open Ash_syntax
open Ash_runtime

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "staging.ash"

let ground () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Desugar.scope_of_globals named in
  let env = Env.extend globals Value.empty_env in
  (globals, named, scope, env)

let evaluate source =
  let globals, named, scope, env = ground () in
  let term = Desugar.program ~scope (Parser.program ~file source) in
  (globals, named, Evaluator.eval ~env term)

let attempt f =
  match f () with
  | value -> Ok value
  | exception Error.Ash_error error -> Error error

let check_value name expected source =
  match attempt (fun () -> let _, _, value = evaluate source in value) with
  | Ok actual ->
      if not (Value.equal expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Value.to_string expected) (Value.to_string actual))
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name
        (Error.to_string error)

let power_definition =
  "fn power(n, x) =\n\
  \  if n == 0 then `{ 1 }\n\
  \  else `{ ${x} * ${power(n - 1, x)} }\n"

let pow5_definition = power_definition ^ "let pow5 = `{ fn(y) -> ${power(5, `{ y })} }\n"

let test_staged_power () =
  check_value "the documented staged power computes pow5(2)" (Value.Num 32)
    (pow5_definition ^ "run(pow5)(2)");
  match attempt (fun () -> evaluate (pow5_definition ^ "pow5")) with
  | Error error ->
      incr failures;
      Printf.printf "FAIL staged power did not produce code: %s\n"
        (Error.to_string error)
  | Ok (globals, named, Value.Code generated) ->
      let expected =
        Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file
          "(lam (z) (app (var *) (var z) (app (var *) (var z) (app (var *) (var z) (app (var *) (var z) (app (var *) (var z) (lit 1)))))))"
      in
      check "staged power produces alpha-correct code"
        (Alpha.equal expected generated);
      check "staged power produces closed code"
        (Code.is_closed ~available:(Env.idents (Env.extend globals Value.empty_env))
           generated)
  | Ok
      ( _, _,
        ( Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
        | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
        | Value.Environment _ | Value.Cell _ | Value.Primitive _ ) ) ->
      check "staged power produces Code" false

let simplify_definition =
  "fn simplify(e) =\n\
  \  match e {\n\
  \    `{ ${a} + 0 }   -> simplify(a)\n\
  \    `{ ${a} * 1 }   -> simplify(a)\n\
  \    `{ ${a} * 0 }   -> `{ 0 }\n\
  \    `{ ${f}(${x}) } -> `{ ${simplify(f)}(${simplify(x)}) }\n\
  \    _               -> e\n\
  \  }\n"

let test_simplifier () =
  let simplifies name input expected =
    check_value name (Value.Bool true)
      (simplify_definition ^ "simplify(`{ " ^ input ^ " }) == `{ " ^ expected ^ " }")
  in
  simplifies "simplify removes addition by zero recursively" "(2 * 1) + 0" "2";
  simplifies "simplify removes multiplication by one" "(2 + 3) * 1" "2 + 3";
  simplifies "simplify folds multiplication by zero" "(2 + 3) * 0" "0";
  simplifies "simplify descends through application"
    "(fn(z) -> z)(((2 * 1) + 0))" "(fn(q) -> q)(2)";
  simplifies "simplify leaves an unmatched form unchanged" "1 + 2" "1 + 2"

let () =
  test_staged_power ();
  test_simplifier ();
  if !failures > 0 then (
    Printf.printf "%d staging assertion(s) failed\n" !failures;
    exit 1)
