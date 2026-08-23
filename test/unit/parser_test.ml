(* Unit tests for the surface precedence parser (to-do task 1.2). *)

open Ash_core
open Ash_syntax

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

let parse source = Parser.expression ~file:"t.ash" source
let parse_program source = Parser.program ~file:"t.ash" source

let rendered source = Surface_printer.to_string (parse source)
let rendered_program source = Surface_printer.program_to_string (parse_program source)

let check_parse name expected source = check_string name expected (rendered source)

let check_parse_error name ~location ~cause source =
  match parse source with
  | expression ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an error, parsed: %s\n" name
        (Surface_printer.to_string expression)
  | exception Error.Ash_error error ->
      if error.phase <> Error.Parse then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong phase: %s\n" name (Error.to_string error));
      if not (String.equal location (Span.to_string error.span)) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected at: %s\n  reported at: %s\n" name location
          (Span.to_string error.span));
      if not (Error.cause_equal cause error.cause) then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong cause: %s\n" name (Error.to_string error))

let test_atoms_and_compounds () =
  check_parse "integer" "42" "42";
  check_parse "string" "\"a\\nb\"" "\"a\\nb\"";
  check_parse "symbol" "'zero" "'zero";
  check_parse "booleans" "true" "true";
  check_parse "unit" "()" "()";
  check_parse "a grouped expression stays visible" "(group (+ 1 2))" "(1 + 2)";
  check_parse "an empty list" "(list)" "[]";
  check_parse "a list" "(list 1 (+ 2 3) (call f 4))" "[1, 2 + 3, f(4)]";
  check_parse "an empty call" "(call f)" "f()";
  check_parse "a call" "(call f 1 (+ 2 3))" "f(1, 2 + 3)";
  check_parse "calls associate left" "(call (call f x) y)" "f(x)(y)";
  check_parse "an empty block" "(block)" "{}";
  check_parse "a block" "(block (let x 1) (:= x (+ x 1)) x)"
    "{ let x = 1\n x := x + 1; x }"

let test_bindings_and_functions () =
  check_parse "an immutable binding" "(let x 42)" "let x = 42";
  check_parse "a mutable binding" "(var counter 0)" "var counter = 0";
  check_parse "a named function"
    "(fn square (params x) (* x x))" "fn square(x) = x * x";
  check_parse "a multi-parameter function"
    "(fn (params x y) (+ x y))" "fn(x, y) -> x + y";
  check_parse "a zero-parameter function"
    "(fn (params) 0)" "fn() -> 0";
  check_parse "a function body may start on the next line"
    "(fn fact (params n) (if (== n 0) 1 (* n (call fact (- n 1)))))"
    "fn fact(n) =\n  if n == 0 then 1\n  else n * fact(n - 1)";
  check_parse "a conditional"
    "(if (call ready? x) (call yes x) (if false 0 1))"
    "if ready?(x) then yes(x) else if false then 0 else 1";
  check_parse "mutation is below pipelines and associates right"
    "(:= x (:= y (|> z f)))" "x := y := z |> f"

let test_precedence () =
  let cases =
    [
      ("pipeline below or", "(|> a (|| b c))", "a |> b || c");
      ("or below and", "(|| a (&& b c))", "a || b && c");
      ("and below comparisons", "(&& a (== b c))", "a && b == c");
      ("comparisons below cons", "(== a (:: b c))", "a == b :: c");
      ("cons below addition", "(:: a (+ b c))", "a :: b + c");
      ("addition below multiplication", "(+ a (* b c))", "a + b * c");
      ("multiplication below unary", "(* a (- b))", "a * -b");
      ("unary below application", "(- (call f x))", "-f(x)");
      ("pipeline associates left", "(|> (|> a b) c)", "a |> b |> c");
      ("or associates left", "(|| (|| a b) c)", "a || b || c");
      ("and associates left", "(&& (&& a b) c)", "a && b && c");
      ("comparisons associate left", "(< (!= (== a b) c) d)", "a == b != c < d");
      ("cons associates right", "(:: a (:: b c))", "a :: b :: c");
      ("addition associates left", "(- (+ a b) c)", "a + b - c");
      ("multiplication associates left", "(% (/ (* a b) c) d)", "a * b / c % d");
      ("unary nests right", "(! (- x))", "!-x");
    ]
  in
  List.iter (fun (name, expected, source) -> check_parse name expected source) cases;
  check_parse "the complete precedence ladder"
    "(|> a (|| b (&& c (== d (:: e (+ f (* g (- (call (call h i) j)))))))))"
    "a |> b || c && d == e :: f + g * -h(i)(j)"

let test_layout () =
  check_string "newlines separate top-level statements"
    "(let x 1)\n(var y 2)\n(:= y (+ x y))"
    (rendered_program "let x = 1\nvar y = 2\ny := x + y");
  check_string "semicolons separate top-level statements" "(call f)\n(call g)"
    (rendered_program "f(); g();");
  check_string "blank lines and comments still separate statements" "a\nb"
    (rendered_program "a # first\n\n# between\nb");
  check_parse "a line-leading binary operator continues an expression" "(+ a b)"
    "a\n+ b";
  check_parse "layout inside calls is whitespace" "(call f 1 (+ 2 3))"
    "f(\n  1,\n  2 + 3\n)"

let rec check_source_spans expression =
  check "a parsed node has a known span" (not (Span.is_unknown expression.Surface.span));
  check_string "a parsed node keeps the source file" "t.ash" (Span.file expression.span);
  match expression.shape with
  | Surface.Literal _ | Surface.Name _ -> ()
  | Surface.Binding binding -> check_source_spans binding.binding_value
  | Surface.Named_function function_ -> check_source_spans function_.function_body
  | Surface.Function function_ -> check_source_spans function_.body
  | Surface.Call call ->
      check_source_spans call.callee;
      List.iter check_source_spans call.arguments
  | Surface.Block statements | Surface.List_literal statements ->
      List.iter check_source_spans statements
  | Surface.Conditional conditional ->
      check_source_spans conditional.condition;
      check_source_spans conditional.consequent;
      check_source_spans conditional.alternative
  | Surface.Unary unary -> check_source_spans unary.unary_operand
  | Surface.Binary binary ->
      check_source_spans binary.left;
      check_source_spans binary.right
  | Surface.Assignment assignment -> check_source_spans assignment.assignment_value
  | Surface.Group grouped -> check_source_spans grouped

let test_spans () =
  let expression = parse "fn f(x) = { var y = x + 1\n y := f(y) }" in
  check_string "the root span covers the complete declaration" "t.ash:1:1-2:13"
    (Span.to_string expression.span);
  check_source_spans expression;
  match expression.shape with
  | Surface.Named_function function_ -> (
      check_string "the function name is located" "t.ash:1:4-5"
        (Span.to_string function_.function_name.span);
      match function_.function_body.shape with
      | Surface.Block [ _; { shape = Surface.Assignment assignment; _ } ] ->
          check_string "the assignment operator is located" "t.ash:2:4-6"
            (Span.to_string assignment.assignment_operator_span)
      | Surface.Literal _ | Surface.Name _ | Surface.Binding _ | Surface.Named_function _
      | Surface.Function _ | Surface.Call _ | Surface.Block _ | Surface.Conditional _
      | Surface.List_literal _ | Surface.Unary _ | Surface.Binary _ | Surface.Assignment _
      | Surface.Group _ ->
          check "the body keeps its two statements" false)
  | Surface.Literal _ | Surface.Name _ | Surface.Binding _ | Surface.Function _
  | Surface.Call _ | Surface.Block _ | Surface.Conditional _ | Surface.List_literal _
  | Surface.Unary _ | Surface.Binary _ | Surface.Assignment _ | Surface.Group _ ->
      check "the declaration keeps its shape" false

let test_errors () =
  check_parse_error "a missing expression" ~location:"t.ash:1:8"
    ~cause:(Error.Unexpected { found = "end of input"; expected = "an expression" })
    "let x =";
  check_parse_error "a missing else" ~location:"t.ash:1:17"
    ~cause:
      (Error.Unexpected { found = "end of input"; expected = "the keyword `else`" })
    "if true then one";
  check_parse_error "duplicate parameters" ~location:"t.ash:1:7-8"
    ~cause:(Error.Duplicate_binder "x") "fn(x, x) -> x";
  check_parse_error "a trailing call comma" ~location:"t.ash:1:5-6"
    ~cause:(Error.Unexpected { found = "`)`"; expected = "an expression after `,`" })
    "f(x,)";
  check_parse_error "a non-name assignment target" ~location:"t.ash:1:1-5"
    ~cause:
      (Error.Unexpected
         {
           found = "an expression that is not a name";
           expected = "a name on the left of `:=`";
         })
    "f(x) := 1";
  check_parse_error "field access is an explicit unsupported construct"
    ~location:"t.ash:1:2-3"
    ~cause:(Error.Unsupported { what = "field access"; by = "the Ash surface language" })
    "x.y";
  check_parse_error "same-line statements need a semicolon" ~location:"t.ash:1:3-4"
    ~cause:(Error.Unexpected { found = "the name `y`"; expected = "end of input" })
    "x y"

let () =
  test_atoms_and_compounds ();
  test_bindings_and_functions ();
  test_precedence ();
  test_layout ();
  test_spans ();
  test_errors ();
  check_int "all parser assertions passed" 0 !failures;
  if !failures > 0 then exit 1
