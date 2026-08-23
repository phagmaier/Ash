(* Unit tests for the pure primitives and the frozen direct-style oracle
   (to-do task 0.7). *)

open Ash_core
open Ash_syntax
open Ash_runtime

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_string name expected actual =
  if not (String.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name expected actual)

(* A ground environment: the pure primitives, bound to fresh identities, with a
   reader scope that names them. *)
let ground () =
  let globals = Primitives.globals (Primitives.create ()) in
  let env = Env.extend globals Value.empty_env in
  let scope =
    Core_reader.scope_of_list
      (List.map (fun (ident, _) -> (Ident.name ident, ident)) globals)
  in
  (env, scope)

let run text =
  let env, scope = ground () in
  Oracle.eval ~env (Core_reader.read ~scope ~file:"o.ash" text)

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

let check_num name expected text = check_value name (Value.Num expected) text
let check_bool name expected text = check_value name (Value.Bool expected) text

let check_error name ~cause text =
  match run text with
  | value ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an error, got %s\n" name (Value.to_string value)
  | exception Error.Ash_error error ->
      if not (Error.cause_equal error.Error.cause cause) then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong cause: %s\n" name (Error.to_string error));
      if error.Error.phase <> Error.Evaluate then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong phase: %s\n" name (Error.to_string error))

(* Primitives: the oracle's half of the D7 rule *)

let test_primitive_boundary () =
  let non_pure =
    List.filter_map
      (fun (name, cls) ->
        if Effect_class.equal cls Effect_class.Pure then None else Some name)
      Primitives.classification
  in
  (* If the registry ever holds only pure primitives this test proves nothing,
     so it says so rather than passing vacuously. *)
  check "the registry has primitives the oracle must refuse" (non_pure <> []);
  (* Running an effect at oracle time would move it out of the program, which is
     exactly the mistake D7 exists to prevent. The refusal is by class, so a
     primitive added to any other class is refused the day it is registered. *)
  List.iter
    (fun name ->
      check_error ("the oracle refuses `" ^ name ^ "`")
        ~cause:(Error.Unsupported { what = name; by = "the direct-style oracle" })
        (Printf.sprintf "(app (var %s))" name))
    non_pure;
  check "and it runs every pure one it is given"
    (List.for_all
       (fun name ->
         match Primitives.class_of name with
         | Some cls -> Effect_class.may_fold_when_static cls
         | None -> false)
       (Primitives.by_class Effect_class.Pure))

(* Arithmetic *)

let test_arithmetic () =
  check_num "addition" 3 "(app (var +) (lit 1) (lit 2))";
  check_num "subtraction" (-1) "(app (var -) (lit 1) (lit 2))";
  check_num "multiplication" 12 "(app (var *) (lit 3) (lit 4))";
  check_num "division truncates toward zero" (-3) "(app (var /) (lit -7) (lit 2))";
  check_num "remainder takes the sign of the dividend" (-1)
    "(app (var %) (lit -7) (lit 2))";
  check_num "nested arithmetic" 14
    "(app (var +) (lit 2) (app (var *) (lit 3) (lit 4)))";
  check_error "division by zero is an error" ~cause:Error.Division_by_zero
    "(app (var /) (lit 1) (lit 0))";
  check_error "remainder by zero is an error" ~cause:Error.Division_by_zero
    "(app (var %) (lit 1) (lit 0))";
  check_error "arithmetic on a string is a type error"
    ~cause:(Error.Unexpected { found = "a string"; expected = "a number" })
    "(app (var +) (lit \"a\") (lit 1))";
  (* Arguments are checked left to right, so the first bad one is reported. *)
  check_error "the first bad argument is the one reported"
    ~cause:(Error.Unexpected { found = "a boolean"; expected = "a number" })
    "(app (var +) (lit #t) (lit \"a\"))"

let test_comparison () =
  check_bool "less than" true "(app (var <) (lit 1) (lit 2))";
  check_bool "less or equal" true "(app (var <=) (lit 2) (lit 2))";
  check_bool "greater than" false "(app (var >) (lit 1) (lit 2))";
  check_bool "greater or equal" true "(app (var >=) (lit 2) (lit 1))";
  check_bool "numeric equality" true "(app (var ==) (lit 2) (lit 2))";
  check_bool "inequality" true "(app (var !=) (lit 2) (lit 3))";
  check_bool "strings compare structurally" true
    "(app (var ==) (lit \"a\") (lit \"a\"))";
  check_bool "symbols compare structurally" true "(app (var ==) (lit 'a) (lit 'a))";
  check_bool "a symbol is not its string" false "(app (var ==) (lit 'a) (lit \"a\"))";
  check_bool "unit equals unit" true "(app (var ==) (lit unit) (lit unit))";
  check_bool "lists compare elementwise" true
    "(app (var ==) (app (var list) (lit 1) (lit 2)) (app (var list) (lit 1) (lit 2)))";
  check_bool "lists of different length differ" false
    "(app (var ==) (app (var list) (lit 1)) (app (var list) (lit 1) (lit 2)))";
  (* Closures carry identity, so equal bodies are still different values. *)
  check_bool "two closures are two values" false
    "(app (var ==) (lam (x) (var x)) (lam (x) (var x)))";
  check_bool "a closure equals itself" true
    "(let f (lam (x) (var x)) (app (var ==) (var f) (var f)))";
  check_bool "negation" false "(app (var not) (lit #t))"

(* Functions, closures, and lexical scope *)

let test_functions () =
  check_num "applying a lambda" 1 "(app (lam (x) (var x)) (lit 1))";
  check_num "a lambda with several parameters" 3
    "(app (lam (x y) (app (var +) (var x) (var y))) (lit 1) (lit 2))";
  check_num "a nullary lambda" 7 "(app (lam () (lit 7)))";
  check_num "higher-order application" 5
    "(app (lam (f x) (app (var f) (var x))) (lam (n) (app (var +) (var n) (lit 1))) (lit 4))";
  check_num "closures capture their environment" 11
    "(let a (lit 1) (let f (lam (x) (app (var +) (var x) (var a))) (app (var f) (lit 10))))";
  (* A closure sees the environment it was made in, not the one it is called
     from: the inner `a` is a different binding entirely. *)
  check_num "a later binding of the same name does not reach a closure" 11
    "(let a (lit 1)\n\
    \   (let f (lam (x) (app (var +) (var x) (var a)))\n\
    \     (let a (lit 100) (app (var f) (lit 10)))))";
  check_num "a parameter shadows an outer binding" 2
    "(let x (lit 1) (app (lam (x) (var x)) (lit 2)))";
  check_num "currying by nesting" 3
    "(app (app (lam (x) (lam (y) (app (var +) (var x) (var y)))) (lit 1)) (lit 2))";
  check_error "applying a number is a type error"
    ~cause:(Error.Unexpected { found = "a number"; expected = "a function" })
    "(app (lit 1) (lit 2))";
  check_error "too few arguments is an arity error"
    ~cause:(Error.Arity_error { callee = None; expected = "2"; actual = 1 })
    "(app (lam (x y) (var x)) (lit 1))";
  check_error "a named function is named in its arity error"
    ~cause:(Error.Arity_error { callee = Some "f"; expected = "1"; actual = 2 })
    "(letrec ((f (lam (n) (var n)))) (app (var f) (lit 1) (lit 2)))";
  check_error "a primitive arity error names the primitive"
    ~cause:(Error.Arity_error { callee = Some "+"; expected = "2"; actual = 3 })
    "(app (var +) (lit 1) (lit 2) (lit 3))"

(* If and Let *)

let test_control () =
  check_num "the true branch" 1 "(if (lit #t) (lit 1) (lit 2))";
  check_num "the false branch" 2 "(if (lit #f) (lit 1) (lit 2))";
  (* Only the branch taken is evaluated, so the other may be nonsense. *)
  check_num "the untaken branch is not evaluated" 1
    "(if (lit #t) (lit 1) (app (var /) (lit 1) (lit 0)))";
  check_num "a computed condition" 10
    "(let n (lit 3) (if (app (var <) (var n) (lit 5)) (lit 10) (lit 20)))";
  (* No truthiness: a condition is a boolean or it is a mistake. *)
  check_error "a non-boolean condition is a type error"
    ~cause:(Error.Unexpected { found = "a number"; expected = "a boolean" })
    "(if (lit 1) (lit 1) (lit 2))";
  check_num "let binds its body" 3 "(let x (lit 3) (var x))";
  check_num "let values see the enclosing scope" 4
    "(let x (lit 1) (let y (app (var +) (var x) (lit 3)) (var y)))";
  check_num "nested lets shadow" 2 "(let x (lit 1) (let x (lit 2) (var x)))"

(* LetRec *)

let test_recursion () =
  check_num "factorial" 120
    "(letrec ((fact (lam (n)\n\
    \                 (if (app (var ==) (var n) (lit 0))\n\
    \                     (lit 1)\n\
    \                     (app (var *) (var n) (app (var fact) (app (var -) (var n) (lit 1))))))))\n\
    \  (app (var fact) (lit 5)))";
  (* The spec's benchmark: 20! is the largest factorial that fits a machine
     word, so this also pins the numeric domain. *)
  check_num "factorial of twenty" 2432902008176640000
    "(letrec ((fact (lam (n)\n\
    \                 (if (app (var ==) (var n) (lit 0))\n\
    \                     (lit 1)\n\
    \                     (app (var *) (var n) (app (var fact) (app (var -) (var n) (lit 1))))))))\n\
    \  (app (var fact) (lit 20)))";
  check_bool "mutual recursion" true
    "(letrec ((even? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #t) (app (var odd?) (app (var -) (var n) (lit 1))))))\n\
    \         (odd? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #f) (app (var even?) (app (var -) (var n) (lit 1)))))))\n\
    \  (app (var even?) (lit 10)))";
  check_num "a recursive group is visible in its own body" 1
    "(letrec ((f (lam (n) (var n)))) (app (var f) (lit 1)))";
  check_num "an empty recursive group is legal" 5 "(letrec () (lit 5))"

(* Immutable lists *)

let test_lists () =
  check_value "the empty list" (Value.List []) "(lit nil)";
  check_value "building a list" (Value.List [ Value.Num 1; Value.Num 2 ])
    "(app (var list) (lit 1) (lit 2))";
  check_value "consing" (Value.List [ Value.Num 0; Value.Num 1 ])
    "(app (var cons) (lit 0) (app (var list) (lit 1)))";
  check_num "head" 1 "(app (var head) (app (var list) (lit 1) (lit 2)))";
  check_value "tail" (Value.List [ Value.Num 2 ])
    "(app (var tail) (app (var list) (lit 1) (lit 2)))";
  check_bool "the empty list is empty" true "(app (var empty?) (lit nil))";
  check_bool "a cons is not empty" false
    "(app (var empty?) (app (var cons) (lit 1) (lit nil)))";
  check_num "length" 3 "(app (var length) (app (var list) (lit 1) (lit 2) (lit 3)))";
  check_error "head of the empty list is an error"
    ~cause:(Error.Unexpected { found = "the empty list"; expected = "a non-empty list" })
    "(app (var head) (lit nil))";
  check_error "tail of the empty list is an error"
    ~cause:(Error.Unexpected { found = "the empty list"; expected = "a non-empty list" })
    "(app (var tail) (lit nil))";
  check_error "consing onto a number is a type error"
    ~cause:(Error.Unexpected { found = "a number"; expected = "a list" })
    "(app (var cons) (lit 1) (lit 2))";
  (* The spec's `length` example, written recursively over an immutable list. *)
  check_num "a recursive list function" 3
    "(letrec ((len (lam (xs)\n\
    \                (if (app (var empty?) (var xs))\n\
    \                    (lit 0)\n\
    \                    (app (var +) (lit 1) (app (var len) (app (var tail) (var xs))))))))\n\
    \  (app (var len) (app (var list) (lit 7) (lit 8) (lit 9))))";
  check_value "building a list recursively"
    (Value.List [ Value.Num 2; Value.Num 4 ])
    "(letrec ((double (lam (xs)\n\
    \                   (if (app (var empty?) (var xs))\n\
    \                       (lit nil)\n\
    \                       (app (var cons) (app (var *) (lit 2) (app (var head) (var xs)))\n\
    \                                       (app (var double) (app (var tail) (var xs))))))))\n\
    \  (app (var double) (app (var list) (lit 1) (lit 2))))"

(* Mutation and evaluation order *)

let test_mutation_and_order () =
  check_value "set returns unit" Value.Unit "(let x (lit 1) (set x (lit 2)))";
  check_num "set updates the binding" 2 "(let x (lit 1) (let _ (set x (lit 2)) (var x)))";
  (* The cell is shared with the closure that captured it, which is why bindings
     hold cells rather than values. *)
  check_num "mutation reaches a closure that already captured the binding" 110
    "(let a (lit 1)\n\
    \  (let f (lam (x) (app (var +) (var x) (var a)))\n\
    \    (let _ (set a (lit 100)) (app (var f) (lit 10)))))";
  (* Arguments are evaluated left to right: the assignment happens before the
     read, so the read sees the new value. *)
  check_value "arguments are evaluated left to right"
    (Value.List [ Value.Unit; Value.Num 1 ])
    "(let x (lit 0) (app (var list) (set x (lit 1)) (var x)))";
  (* The function position is evaluated before the arguments, so its error is
     the one that surfaces. *)
  check_error "the function position is evaluated first"
    ~cause:Error.Division_by_zero
    "(app (app (var /) (lit 1) (lit 0)) (app (var head) (lit nil)))"

(* Frozen: what the oracle refuses *)

let test_frozen () =
  let refused what = Error.Unsupported { what; by = "the direct-style oracle" } in
  check_error "quotation is refused" ~cause:(refused "quote") "(quote (lit 1))";
  check_error "reifiers are refused" ~cause:(refused "reifier")
    "(reifier (e r k) (app (var k) (var e)))";
  check_error "name resolution is refused" ~cause:(refused "named-var x")
    "(named-var \"x\")";

  (* An effectful primitive must never run here: folding it would move the effect
     out of the program, which is the mistake D7 exists to prevent. *)
  let logged = ref [] in
  let printer =
    {
      Value.prim_name = "print";
      prim_arity = Value.Exactly 1;
      prim_class = Effect_class.Observable_effect;
      prim_impl =
        (fun ~call_site:_ ~apply:_ args k ->
          logged := args;
          k Value.Unit);
    }
  in
  let ident = Ident.fresh "print" in
  let env = Env.extend [ (ident, Value.Primitive printer) ] Value.empty_env in
  let scope = Core_reader.scope_of_list [ ("print", ident) ] in
  let term = Core_reader.read ~scope ~file:"o.ash" "(app (var print) (lit 1))" in
  (match Oracle.eval ~env term with
  | value ->
      incr failures;
      Printf.printf "FAIL an effectful primitive is refused\n  got %s\n"
        (Value.to_string value)
  | exception Error.Ash_error error ->
      check "an effectful primitive is refused"
        (Error.cause_equal error.Error.cause
           (Error.Unsupported { what = "print"; by = "the direct-style oracle" })));
  check "and it did not run" (!logged = []);

  (* Refusals carry the location of what was refused. *)
  match run "(app (lam (x) (quote (var x))) (lit 1))" with
  | _ ->
      incr failures;
      Printf.printf "FAIL a refusal is located\n"
  | exception Error.Ash_error error ->
      check_string "a refusal is located" "o.ash:1:15-30"
        (Span.to_string error.Error.span)

let () =
  test_primitive_boundary ();
  test_arithmetic ();
  test_comparison ();
  test_functions ();
  test_control ();
  test_recursion ();
  test_lists ();
  test_mutation_and_order ();
  test_frozen ();
  if !failures > 0 then (
    Printf.printf "%d oracle assertion(s) failed\n" !failures;
    exit 1)
