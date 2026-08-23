(* Hygienic lowering of surface syntax to Core (to-do task 1.4).

   Two kinds of assertion. Shape tests compare the lowered term with the Core
   the table in `Desugar`'s documentation promises, up to alpha-equivalence,
   because the identities are fresh by construction and their numbers mean
   nothing. End-to-end tests parse, lower, and run, which is the only way to see
   that hygiene, scope, and the primitives the desugarer emits agree with each
   other. *)

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

let file = "d.ash"

(* One registry per run: the globals are what generated calls resolve against,
   and a fresh set of identities each time is what a materialized tower level
   would get too. *)
let ground () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let env = Env.extend globals Value.empty_env in
  (Desugar.scope_of_globals named, Core_reader.scope_of_list named, env)

let lower source =
  let scope, _, _ = ground () in
  Desugar.program ~scope (Parser.program ~file source)

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

(* {1 Shapes} *)

let check_shape name source expected_core =
  let scope, read_scope, _ = ground () in
  match
    attempt (fun () ->
        ( Desugar.program ~scope (Parser.program ~file source),
          Core_reader.read ~scope:read_scope ~file expected_core ))
  with
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name (Error.to_string error)
  | Ok (lowered, expected) ->
      if not (Alpha.equal lowered expected) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Core_printer.to_string expected)
          (Core_printer.to_string lowered))

let test_shapes () =
  check_shape "a literal is a literal" "42" "(lit 42)";
  check_shape "an empty program is unit" "" "(lit unit)";
  check_shape "a statement separator is a let nothing mentions" "1\n2"
    "(let _ (lit 1) (lit 2))";
  check_shape "a semicolon separates the same way" "1; 2" "(let _ (lit 1) (lit 2))";
  check_shape "a binding scopes over the rest of the list" "let x = 1\nx + 1"
    "(let x (lit 1) (app (var +) (var x) (lit 1)))";
  check_shape "a trailing definition evaluates to unit" "let x = 1"
    "(let x (lit 1) (lit unit))";
  check_shape "var lowers like let" "var x = 1" "(let x (lit 1) (lit unit))";
  check_shape "assignment is Set" "var x = 1\nx := 2" "(let x (lit 1) (set x (lit 2)))";
  check_shape "a named function is a recursive group" "fn f(n) = f(n)"
    "(letrec ((f (lam (n) (app (var f) (var n))))) (lit unit))";
  check_shape "adjacent named functions share one group"
    "fn even(n) = odd(n)\nfn odd(n) = even(n)\neven(1)"
    "(letrec ((even (lam (n) (app (var odd) (var n))))\n\
     \         (odd (lam (n) (app (var even) (var n)))))\n\
     \  (app (var even) (lit 1)))";
  check_shape "a binding between them starts a new group"
    "fn f() = 1\nlet x = 2\nfn g() = 3"
    "(letrec ((f (lam () (lit 1)))) (let x (lit 2) (letrec ((g (lam () (lit 3)))) (lit unit))))";
  (* An open group is cells, not a [LetRec]: the binder holds the cell, every
     reference to the name is a dereference of it, and an assignment writes
     through it. That indirection is the whole of invariant OR (spec §D3). *)
  check_shape "an open function is a cell that holds it" "open fn f(n) = f(n)"
    "(let f (app (var open_cell) (lit unit))\n    \  (let _ (app (var open_set) (var f)\n    \                (lam (n) (app (app (var open_deref) (var f)) (var n))))\n    \    (lit unit)))";
  check_shape "adjacent open functions share one group"
    "open fn even(n) = odd(n)\nopen fn odd(n) = even(n)"
    "(let even (app (var open_cell) (lit unit))\n    \  (let odd (app (var open_cell) (lit unit))\n    \    (let _ (app (var open_set) (var even)\n    \                  (lam (n) (app (app (var open_deref) (var odd)) (var n))))\n    \      (let _ (app (var open_set) (var odd)\n    \                    (lam (n) (app (app (var open_deref) (var even)) (var n))))\n    \        (lit unit)))))";
  check_shape "a reference after the group is a dereference too"
    "open fn f(n) = n\nf(1)"
    "(let f (app (var open_cell) (lit unit))\n    \  (let _ (app (var open_set) (var f) (lam (n) (var n)))\n    \    (app (app (var open_deref) (var f)) (lit 1))))";
  check_shape "replacing a group member writes through the cell"
    "open fn f(n) = n\nf := fn(n) -> n"
    "(let f (app (var open_cell) (lit unit))\n    \  (let _ (app (var open_set) (var f) (lam (n) (var n)))\n    \    (app (var open_set) (var f) (lam (n) (var n)))))";
  check_shape "a plain group and an open group do not merge"
    "fn f() = 1\nopen fn g() = 2"
    "(letrec ((f (lam () (lit 1))))\n    \  (let g (app (var open_cell) (lit unit))\n    \    (let _ (app (var open_set) (var g) (lam () (lit 2))) (lit unit))))";
  check_shape "an anonymous function is a lambda" "fn(x) -> x" "(lam (x) (var x))";
  check_shape "a block is a statement list" "{ let x = 1\n x }"
    "(let x (lit 1) (var x))";
  check_shape "a conditional is If" "if true then 1 else 2"
    "(if (lit #t) (lit 1) (lit 2))";
  check_shape "binary operators are primitive calls" "1 * 2"
    "(app (var *) (lit 1) (lit 2))";
  check_shape "cons is a primitive call" "1 :: []"
    "(app (var cons) (lit 1) (lit nil))";
  (* A [-] beginning a line continues the previous expression, so this needs
     the explicit separator. *)
  check_shape "negation subtracts from zero" "let x = 1; -x"
    "(let x (lit 1) (app (var -) (lit 0) (var x)))";
  check_shape "not is a primitive call" "!true" "(app (var not) (lit #t))";
  (* [If] keeps requiring a boolean, so the sugar cannot answer the left
     operand's value the way a truthiness language would. *)
  check_shape "and is a conditional" "true && false"
    "(if (lit #t) (lit #f) (lit #f))";
  check_shape "or is a conditional" "false || true" "(if (lit #f) (lit #t) (lit #t))";
  check_shape "the empty list is the nil literal" "[]" "(lit nil)";
  check_shape "a list literal calls list" "[1, 2]" "(app (var list) (lit 1) (lit 2))";
  check_shape "a pipeline into a call inserts the first argument" "1 |> cons([])"
    "(app (var cons) (lit 1) (lit nil))";
  check_shape "a pipeline into a name applies it" "[1] |> length"
    "(app (var length) (app (var list) (lit 1)))";
  (* Parenthesizing is how the other reading is written. *)
  check_shape "a parenthesized right operand is the function itself"
    "let f = fn(x) -> x\n1 |> (f(2))"
    "(let f (lam (x) (var x)) (app (app (var f) (lit 2)) (lit 1)))";
  check_shape "grouping disappears" "(1 + 2)" "(app (var +) (lit 1) (lit 2))"

(* {1 Hygiene} *)

let rec binders_of node =
  Core.binders node @ List.concat_map binders_of (Core.children node)

let test_hygiene () =
  (* Two bindings that print alike are two identities, which is the whole
     difference between hygiene and a renaming convention. *)
  let shadowing = lower "let x = 1\nlet x = x + 1\nx" in
  let bound = binders_of shadowing in
  check "shadowing allocates distinct identities"
    (match bound with
    | [ outer; inner ] ->
        Ident.same_name outer inner && not (Ident.equal outer inner)
    | _ -> false);
  (* The names the match lowering invents are ordinary binders, so the only
     thing keeping them from capturing a user's [head] is that they are
     different identities. *)
  let captured = lower "let head = 10\nmatch [1, 2] { h :: t -> h + head }" in
  check "a generated binder does not capture a user name"
    (List.length (List.sort_uniq Ident.compare (binders_of captured))
    = List.length (binders_of captured))

(* {1 Provenance} *)

let rec node_at path node =
  match path with
  | [] -> node
  | index :: rest -> node_at rest (List.nth (Core.children node) index)

let test_provenance () =
  let lowered = lower "1 + 2" in
  check_string "an operator call records its rewrite" "desugar/operator"
    (String.concat "," (Span.generators (Core.span lowered)));
  check_string "the operator's variable is generated too" "desugar/operator"
    (String.concat "," (Span.generators (Core.span (node_at [ 0 ] lowered))));
  check "an operand keeps its own source span"
    (not (Span.is_generated (Core.span (node_at [ 1 ] lowered))));
  (* Positions survive the rewrite: a diagnostic on a generated node still
     points at the text the user wrote. *)
  let source = Span.source_span (Core.span lowered) in
  check "a generated node keeps user positions"
    ((Span.file source = file) && not (Span.is_generated source));
  check_string "sequencing records its rewrite" "desugar/seq"
    (String.concat "," (Span.generators (Core.span (lower "1\n2"))));
  check_string "a named function records its rewrite" "desugar/fn"
    (String.concat "," (Span.generators (Core.span (lower "fn f() = 1"))));
  check_string "a list literal records its rewrite" "desugar/list"
    (String.concat "," (Span.generators (Core.span (lower "[1]"))));
  check_string "match records its rewrite" "desugar/match"
    (String.concat "," (Span.generators (Core.span (lower "match 1 { _ -> 2 }"))));
  check "a binding the user wrote is not generated"
    (not (Span.is_generated (Core.span (lower "let x = 1"))))

(* {1 Running} *)

let evaluate ?io source =
  let registry = match io with None -> Primitives.create () | Some io -> Primitives.create ~io () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Desugar.scope_of_globals named in
  let env = Env.extend globals Value.empty_env in
  Evaluator.eval ~env (Desugar.program ~scope (Parser.program ~file source))

let check_value name expected source =
  match attempt (fun () -> evaluate source) with
  | Ok actual ->
      if not (Value.equal expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Value.to_string expected) (Value.to_string actual))
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name (Error.to_string error)

let check_error name ~phase ~cause source =
  match attempt (fun () -> evaluate source) with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an error, got %s\n" name (Value.to_string value)
  | Error error ->
      if not (Error.cause_equal error.Error.cause cause && error.Error.phase = phase) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s error: %s\n  actual:   %s\n" name
          (Error.phase_name phase) (Error.cause_message cause) (Error.to_string error))

let fact = "fn fact(n) =\n  if n == 0 then 1\n  else n * fact(n - 1)\n"

let length_program =
  "fn length(xs) =\n\
  \  match xs {\n\
  \    []      -> 0\n\
  \    _ :: ys -> 1 + length(ys)\n\
  \  }\n"

let test_end_to_end () =
  check_value "fact(5)" (Value.Num 120) (fact ^ "fact(5)");
  check_value "fact(20)" (Value.Num 2432902008176640000) (fact ^ "fact(20)");
  (* The user's [length] shadows the primitive, and the [empty?], [head], and
     [tail] the match lowering emits still reach the primitives. *)
  check_value "the documented length" (Value.Num 3) (length_program ^ "length([1, 2, 3])");
  check_value "length of the empty list" (Value.Num 0) (length_program ^ "length([])");
  check_value "a pipeline chain" (Value.Num 9)
    "fn add(a, b) = a + b\n2 |> add(3) |> add(4)";
  check_value "a pipeline into a primitive" (Value.Num 3) "[1, 2, 3] |> length";
  check_value "shadowing takes the innermost binding" (Value.Num 2)
    "let x = 1\nlet x = x + 1\nx";
  check_value "a shadowed global is only shadowed where it was written"
    (Value.List [ Value.Num 5; Value.Num 1 ])
    "let list = 5\n[list, 1]";
  check_value "a generated binder cannot capture" (Value.Num 11)
    "let head = 10\nmatch [1, 2] { h :: t -> h + head }";
  check_value "set is visible through a closure" (Value.Num 2)
    "var c = 0\nfn bump() = c := c + 1\nbump()\nbump()\nc";
  check_value "set evaluates to unit" Value.Unit "var c = 0\nc := 1";
  check_value "blocks sequence and scope" (Value.Num 6)
    "fn f(n) = {\n  let m = n + 1\n  m * 2\n}\nf(2)";
  check_value "short-circuit and does not evaluate its right operand"
    (Value.Bool false) "false && 1 == 1";
  check_value "short-circuit or does not evaluate its right operand"
    (Value.Bool true) "true || 1 == 1";
  check_value "a symbol classifier" (Value.Sym "one")
    "fn classify(n) = {\n\
    \  let m = n % 3\n\
    \  if m == 0 then 'zero else if m == 1 then 'one else 'two\n\
     }\nclassify(4)"

let test_match () =
  check_value "clauses are tried in order" (Value.Sym "two")
    "match 2 { 1 -> 'one\n2 -> 'two\n_ -> 'other }";
  check_value "a wildcard catches what is left" (Value.Sym "other")
    "match 9 { 1 -> 'one\n2 -> 'two\n_ -> 'other }";
  check_value "a variable pattern binds the scrutinee" (Value.Num 5)
    "match 5 { x -> x }";
  check_value "a list pattern checks length" (Value.Num 3)
    "match [1, 2] { [a] -> 1\n[a, b] -> a + b\n_ -> 0 }";
  check_value "a list pattern rejects a longer list" (Value.Num 0)
    "match [1, 2, 3] { [a, b] -> a + b\n_ -> 0 }";
  check_value "alternatives without binders" (Value.Sym "small")
    "match 3 { 1 | 2 | 3 -> 'small\n_ -> 'big }";
  (* Both arms bind the same name, so the shared body is a function of it. *)
  check_value "alternatives that bind" (Value.Num 7)
    "match [7] { [x] | x :: [] -> x\n_ -> 0 }";
  check_value "a nested pattern" (Value.Num 12)
    "match [1, 2] { a :: [b] -> a * 10 + b\n_ -> 0 }";
  check_value "the scrutinee is evaluated once" (Value.Num 1)
    "var calls = 0\nfn bump() = { calls := calls + 1\n [1] }\nmatch bump() { _ -> calls }";
  check_error "a match with no matching clause fails" ~phase:Error.Evaluate
    ~cause:(Error.No_matching_clause "3")
    "match 3 { 1 -> 'one\n2 -> 'two }"

let test_errors () =
  check_error "an unbound name is a desugar error" ~phase:Error.Desugar
    ~cause:(Error.Unbound_name "nope") "nope + 1";
  check_error "an immutable binding cannot be assigned" ~phase:Error.Desugar
    ~cause:(Error.Immutable_binding "x") "let x = 1\nx := 2";
  check_error "a global cannot be assigned" ~phase:Error.Desugar
    ~cause:(Error.Immutable_binding "head") "head := 1";
  check_error "assigning an unbound name is a desugar error" ~phase:Error.Desugar
    ~cause:(Error.Unbound_name "x") "x := 1";
  check_error "a parameter cannot be assigned" ~phase:Error.Desugar
    ~cause:(Error.Immutable_binding "x") "fn f(x) = x := 1\nf(1)";
  (* The parser already refuses this, so the phase says so; the desugarer
     keeps its own check for trees it is handed rather than parses. *)
  check_error "duplicate parameters are refused" ~phase:Error.Parse
    ~cause:(Error.Duplicate_binder "x") "fn f(x, x) = x";
  check_error "duplicate functions in one group are refused" ~phase:Error.Desugar
    ~cause:(Error.Duplicate_binder "f") "fn f() = 1\nfn f() = 2";
  check_error "duplicate open functions in one group are refused" ~phase:Error.Desugar
    ~cause:(Error.Duplicate_binder "f") "open fn f() = 1\nopen fn f() = 2";
  (* A plain function is not a group member, so it is not replaceable; only the
     cell an [open fn] binds may be written through. *)
  check_error "a plain named function cannot be replaced" ~phase:Error.Desugar
    ~cause:(Error.Immutable_binding "f") "fn f() = 1\nf := fn() -> 2";
  check_error "quotation does not lower yet" ~phase:Error.Desugar
    ~cause:
      (Error.Unsupported
         {
           what = "a quotation";
           by = "the desugarer, which lowers no code construction before Phase 3";
         })
    "`{ 1 + 2 }";
  check_error "constructor patterns do not lower yet" ~phase:Error.Desugar
    ~cause:
      (Error.Unsupported
         {
           what = "the `Lit(<pattern>)` pattern";
           by = "the desugarer, which lowers no code construction before Phase 3";
         })
    "match e { Lit(c) -> c }";
  check_error "quasiquote patterns do not lower yet" ~phase:Error.Desugar
    ~cause:
      (Error.Unsupported
         {
           what = "a quasiquote pattern";
           by = "the desugarer, which lowers no code construction before Phase 3";
         })
    "match e { `{ ${a} + 0 } -> a }"

let test_registry_agreement () =
  let registered = Primitives.names in
  List.iter
    (fun name ->
      check
        (Printf.sprintf "the desugarer's `%s` is registered" name)
        (List.mem name registered))
    Desugar.required_primitives;
  (* An empty scope has no globals, so anything that lowers to a primitive call
     says which name it could not find rather than emitting a dangling
     identity. *)
  match
    attempt (fun () -> Desugar.program (Parser.program ~file "1 + 2"))
  with
  | Ok _ ->
      incr failures;
      Printf.printf "FAIL lowering under the empty scope must fail\n"
  | Error error ->
      check "the empty scope reports the missing primitive"
        (Error.cause_equal error.Error.cause (Error.Unbound_name "+"))

let test_expression_entry () =
  let scope, read_scope, _ = ground () in
  let lowered = Desugar.expression ~scope (Parser.expression ~file "let x = 1") in
  check "a lone definition lowers like a one-statement program"
    (Alpha.equal lowered
       (Core_reader.read ~scope:read_scope ~file "(let x (lit 1) (lit unit))"))

let () =
  test_shapes ();
  test_hygiene ();
  test_provenance ();
  test_end_to_end ();
  test_match ();
  test_errors ();
  test_registry_agreement ();
  test_expression_entry ();
  if !failures > 0 then (
    Printf.printf "%d desugar assertion(s) failed\n" !failures;
    exit 1)
