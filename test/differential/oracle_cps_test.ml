(* The oracle/CPS differential corpus (to-do task 0.8; extended in task 1.6).

   The frozen direct-style oracle and the real CPS evaluator are two independent
   implementations of the same semantics. On the ordinary corpus they must agree
   on the value a program produces, on the error it fails with, and on where that
   error is reported. A difference is a bug in one of them, and the point of
   keeping the oracle simple is that it is usually the other one. *)

open Ash_core
open Ash_syntax
open Ash_runtime

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let describe = function
  | Ok value -> Value.to_string value
  | Error error -> "error: " ^ Error.to_string error

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

(* Both evaluators run the same term, each with its own freshly celled copy of
   the same global bindings, so a program that mutates does not leak from the
   first run into the second. *)
let agree name text =
  let globals = Primitives.globals () in
  let scope =
    Core_reader.scope_of_list
      (List.map (fun (ident, _) -> (Ident.name ident, ident)) globals)
  in
  let term = Core_reader.read ~scope ~file:"d.ash" text in
  let fresh () = Env.extend globals Value.empty_env in
  let oracle = attempt (fun () -> Oracle.eval ~env:(fresh ()) term) in
  let cps = attempt (fun () -> Evaluator.eval ~env:(fresh ()) term) in
  let same =
    match (oracle, cps) with
    | Ok a, Ok b -> Value.equal a b
    | Error a, Error b ->
        Error.cause_equal a.Error.cause b.Error.cause && Span.equal a.Error.span b.Error.span
    | Ok _, Error _ | Error _, Ok _ -> false
  in
  if not same then (
    incr failures;
    Printf.printf "FAIL %s\n  program: %s\n  oracle:  %s\n  cps:     %s\n" name text
      (describe oracle) (describe cps))

(* Values *)

let values =
  [
    ("a literal", "(lit 42)");
    ("unit", "(lit unit)");
    ("the empty list", "(lit nil)");
    ("addition", "(app (var +) (lit 1) (lit 2))");
    ("nested arithmetic", "(app (var +) (lit 2) (app (var *) (lit 3) (lit 4)))");
    ("truncating division", "(app (var /) (lit -7) (lit 2))");
    ("remainder", "(app (var %) (lit -7) (lit 2))");
    ("comparison", "(app (var <) (lit 1) (lit 2))");
    ("structural equality",
     "(app (var ==) (app (var list) (lit 1) (lit 2)) (app (var list) (lit 1) (lit 2)))");
    ("closure identity", "(app (var ==) (lam (x) (var x)) (lam (x) (var x)))");
    ("negation", "(app (var not) (lit #f))");
    ("applying a lambda", "(app (lam (x) (var x)) (lit 1))");
    ("several parameters", "(app (lam (x y) (app (var -) (var x) (var y))) (lit 5) (lit 2))");
    ("a nullary lambda", "(app (lam () (lit 7)))");
    ("higher order",
     "(app (lam (f x) (app (var f) (var x))) (lam (n) (app (var +) (var n) (lit 1))) (lit 4))");
    ("currying", "(app (app (lam (x) (lam (y) (app (var +) (var x) (var y)))) (lit 1)) (lit 2))");
    ("captured environment",
     "(let a (lit 1) (let f (lam (x) (app (var +) (var x) (var a))) (app (var f) (lit 10))))");
    ("a rebinding a closure must not see",
     "(let a (lit 1) (let f (lam (x) (app (var +) (var x) (var a))) (let a (lit 100) (app (var f) (lit 10)))))");
    ("shadowing", "(let x (lit 1) (let x (lit 2) (var x)))");
    ("the true branch", "(if (lit #t) (lit 1) (lit 2))");
    ("the false branch", "(if (lit #f) (lit 1) (lit 2))");
    ("an unevaluated branch", "(if (lit #t) (lit 1) (app (var /) (lit 1) (lit 0)))");
    ("an empty recursive group", "(letrec () (lit 5))");
    ("factorial",
     "(letrec ((fact (lam (n) (if (app (var ==) (var n) (lit 0)) (lit 1) (app (var *) (var n) (app (var fact) (app (var -) (var n) (lit 1)))))))) (app (var fact) (lit 20)))");
    ("mutual recursion",
     "(letrec ((even? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #t) (app (var odd?) (app (var -) (var n) (lit 1)))))) (odd? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #f) (app (var even?) (app (var -) (var n) (lit 1))))))) (app (var even?) (lit 10)))");
    ("building a list", "(app (var cons) (lit 0) (app (var list) (lit 1) (lit 2)))");
    ("head and tail", "(app (var head) (app (var tail) (app (var list) (lit 1) (lit 2))))");
    ("a recursive list function",
     "(letrec ((len (lam (xs) (if (app (var empty?) (var xs)) (lit 0) (app (var +) (lit 1) (app (var len) (app (var tail) (var xs))))))))  (app (var len) (app (var list) (lit 7) (lit 8) (lit 9))))");
    ("a list built recursively",
     "(letrec ((double (lam (xs) (if (app (var empty?) (var xs)) (lit nil) (app (var cons) (app (var *) (lit 2) (app (var head) (var xs))) (app (var double) (app (var tail) (var xs)))))))) (app (var double) (app (var list) (lit 1) (lit 2))))");
  ]

(* Mutation and evaluation order: the two places where two implementations most
   easily drift apart without either looking wrong on its own. *)

let effects =
  [
    ("set evaluates to unit", "(let x (lit 1) (set x (lit 2)))");
    ("set updates the binding", "(let x (lit 1) (let _ (set x (lit 2)) (var x)))");
    ("mutation reaches a closure",
     "(let a (lit 1) (let f (lam (x) (app (var +) (var x) (var a))) (let _ (set a (lit 100)) (app (var f) (lit 10)))))");
    ("arguments evaluate left to right",
     "(let x (lit 0) (app (var list) (set x (lit 1)) (var x)))");
    ("the function position evaluates first",
     "(app (app (var /) (lit 1) (lit 0)) (app (var head) (lit nil)))");
    ("mutation inside a recursive group",
     "(let n (lit 0) (letrec ((bump (lam (k) (if (app (var ==) (var k) (lit 0)) (var n) (let _ (set n (app (var +) (var n) (lit 1))) (app (var bump) (app (var -) (var k) (lit 1)))))))) (app (var bump) (lit 5))))");
  ]

(* Failures: same cause, same place. *)

let errors =
  [
    ("division by zero", "(app (var /) (lit 1) (lit 0))");
    ("a type error in arithmetic", "(app (var +) (lit \"a\") (lit 1))");
    ("the first bad argument wins", "(app (var +) (lit #t) (lit \"a\"))");
    ("a non-boolean condition", "(if (lit 1) (lit 1) (lit 2))");
    ("applying a number", "(app (lit 1) (lit 2))");
    ("an anonymous arity error", "(app (lam (x y) (var x)) (lit 1))");
    ("a named arity error", "(letrec ((f (lam (n) (var n)))) (app (var f) (lit 1) (lit 2)))");
    ("a primitive arity error", "(app (var +) (lit 1) (lit 2) (lit 3))");
    ("head of the empty list", "(app (var head) (lit nil))");
    ("consing onto a number", "(app (var cons) (lit 1) (lit 2))");
    ("an unfilled recursive binding is unreachable, so this just runs",
     "(letrec ((f (lam (n) (var n)))) (app (var f) (lit 1)))");
  ]

(* The deliberate divergences. These are not failures of agreement: they are the
   boundary the oracle is frozen at, and it is checked so that a later change
   cannot quietly move it. *)

let test_frozen_boundary () =
  let refused_by_oracle text =
    let globals = Primitives.globals () in
    let scope =
      Core_reader.scope_of_list
        (List.map (fun (ident, _) -> (Ident.name ident, ident)) globals)
    in
    let term = Core_reader.read ~scope ~file:"d.ash" text in
    let fresh () = Env.extend globals Value.empty_env in
    let oracle = attempt (fun () -> Oracle.eval ~env:(fresh ()) term) in
    let cps = attempt (fun () -> Evaluator.eval ~env:(fresh ()) term) in
    let refused =
      match oracle with
      | Error error -> (
          match error.Error.cause with
          | Error.Unsupported { by; _ } -> String.equal by "the direct-style oracle"
          | Error.Unbound_ident _ | Error.Unbound_name _ | Error.Ambiguous_name _
          | Error.Unfilled_binding _ | Error.Unexpected_character _
          | Error.Unterminated _ | Error.Unexpected _ | Error.Unknown_form _
          | Error.Malformed_form _ | Error.Arity_error _ | Error.Division_by_zero
          | Error.Duplicate_binder _ ->
              false)
      | Ok _ -> false
    in
    check ("the oracle refuses " ^ text) refused;
    check ("the real evaluator handles " ^ text) (Result.is_ok cps)
  in
  refused_by_oracle "(quote (lit 1))";
  refused_by_oracle "(reifier (e r k) (var e))"

let () =
  List.iter (fun (name, text) -> agree ("value: " ^ name) text) values;
  List.iter (fun (name, text) -> agree ("effect: " ^ name) text) effects;
  List.iter (fun (name, text) -> agree ("error: " ^ name) text) errors;
  test_frozen_boundary ();
  Printf.printf "differential corpus: %d programs compared\n"
    (List.length values + List.length effects + List.length errors);
  if !failures > 0 then (
    Printf.printf "%d differential disagreement(s)\n" !failures;
    exit 1)
