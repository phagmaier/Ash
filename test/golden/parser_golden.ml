(* Structural golden output for the precedence parser (to-do task 1.2). *)

open Ash_core
open Ash_syntax

let file = "golden.ash"
let rule () = print_endline (String.make 74 '-')

let heading title =
  print_newline ();
  rule ();
  Printf.printf "%s\n" title;
  rule ()

let show source =
  let parsed = Parser.expression ~file source in
  Printf.printf "  %-54s => %s\n" source (Surface_printer.to_string parsed)

let show_program title source =
  Printf.printf "\n== %s ==\n" title;
  List.iter (fun line -> Printf.printf "  | %s\n" line) (String.split_on_char '\n' source);
  Printf.printf "  =>\n%s\n"
    (Surface_printer.program_to_string (Parser.program ~file source))

let show_error source =
  match Parser.expression ~file source with
  | expression ->
      Printf.printf "  %-28s parsed as %s\n" source (Surface_printer.to_string expression)
  | exception Error.Ash_error error ->
      Printf.printf "  %-28s %s\n" source (Error.to_string error)

let show_pattern source =
  let parsed = Parser.pattern ~file source in
  Printf.printf "  %-54s => %s\n" source
    (Surface_printer.pattern_to_string parsed)

let show_pattern_error source =
  match Parser.pattern ~file source with
  | pattern ->
      Printf.printf "  %-28s parsed as %s\n" source
        (Surface_printer.pattern_to_string pattern)
  | exception Error.Ash_error error ->
      Printf.printf "  %-28s %s\n" source (Error.to_string error)

let boundaries =
  [
    "a |> b || c";
    "a || b && c";
    "a && b == c";
    "a == b :: c";
    "a :: b + c";
    "a + b * c";
    "a * -b";
    "-f(x)";
    "a |> b || c && d == e :: f + g * -h(i)(j)";
  ]

let associativity =
  [
    "a |> b |> c";
    "a || b || c";
    "a && b && c";
    "a == b != c < d <= e > f >= g";
    "a :: b :: c";
    "a + b - c";
    "a * b / c % d";
    "!-x";
    "f(x)(y)";
    "x := y := z |> f";
  ]

let constructs =
  [
    ( "bindings, mutation, and layout",
      "let x = 42\nvar counter = 0\ncounter := counter + 1" );
    ( "named and anonymous functions",
      "fn square(x) = x * x\nlet double = fn(x) -> x * 2" );
    ( "§D3 open-recursive group",
      "open fn eval(e, r, k) = apply(e, r, k)\nopen fn apply(f, vs, k) = k(vs)" );
    ( "a multiline conditional",
      "fn fact(n) =\n  if n == 0 then 1\n  else n * fact(n - 1)" );
    ( "blocks, lists, and calls",
      "fn classify(n) = {\n  let values = [n, n + 1]\n  choose(values)(0)\n}" );
    ( "pipelines",
      "xs |> map(double) |> sum" );
    ( "§5.3 the tracing demo",
      "up {\n\
      \  let base = eval\n\
      \  eval := fn(e, r, k) -> { print(show(e)); base(e, r, k) }\n\
      }\n\
      fib(3)" );
    ( "§4.2 documented length",
      "fn length(xs) =\n\
      \  match xs {\n\
      \    []      -> 0\n\
      \    _ :: ys -> 1 + length(ys)\n\
      \  }" );
    ( "§4.4 documented simplify",
      "fn simplify(e) =\n\
      \  match e {\n\
      \    `{ ${a} + 0 }   -> simplify(a)\n\
      \    `{ ${a} * 1 }   -> simplify(a)\n\
      \    `{ ${a} * 0 }   -> `{ 0 }\n\
      \    `{ ${f}(${x}) } -> `{ ${simplify(f)}(${simplify(x)}) }\n\
      \    _               -> e\n\
      \  }" );
    ( "all Core constructor patterns",
      "match e {\n\
      \  Lit(c) -> 0\n\
      \  Var(x) -> 0\n\
      \  NamedVar(s) -> 0\n\
      \  Lam(ps,b) -> 0\n\
      \  App(f,args) -> 0\n\
      \  Let(x,v,b) -> 0\n\
      \  LetRec(bs,b) -> 0\n\
      \  If(c,t,f) -> 0\n\
      \  Set(x,v) -> 0\n\
      \  Quote(q) -> 0\n\
      \  Reifier(ps,b) -> 0\n\
       }" );
  ]

let patterns =
  [
    "_";
    "-1 | \"x\" | 'ok | true | false | ()";
    "[x, _, 3]";
    "x :: y :: ys";
    "[x] | x :: []";
    "App(f, [x, xs])";
    "`{ ${a} + 0 }";
    "`{ ${f}(${x}) }";
  ]

let malformed =
  [
    "let x =";
    "if true then one";
    "fn(x, x) -> x";
    "f(x,)";
    "[1,]";
    "f(x) := 1";
    "x.y";
    "x y";
    "${x}";
    "match x {}";
    (* [up] takes a block, not an expression: how far to the right an
       unbraced body would extend is exactly what blocks settle. *)
    "up 1";
  ]

let malformed_patterns =
  [ "x :: x"; "x | y"; "Foo(x)"; "Lit(x, y)"; "[x,]"; "`{ ${x} + ${x} }" ]

let () =
  print_endline "Ash surface precedence parser — golden output";
  print_endline "Structural parentheses expose the grouping chosen by the parser.";

  heading "Every adjacent precedence boundary, loosest to tightest";
  List.iter show boundaries;

  heading "Associativity at every operator level";
  List.iter show associativity;

  heading "Required surface constructs";
  List.iter (fun (title, source) -> show_program title source) constructs;

  heading "Patterns, alternatives, constructors, and quasiquotation";
  List.iter show_pattern patterns;

  heading "Parser diagnostics";
  List.iter show_error malformed;
  List.iter show_pattern_error malformed_patterns
