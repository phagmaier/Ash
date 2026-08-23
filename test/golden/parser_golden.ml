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
    ( "a multiline conditional",
      "fn fact(n) =\n  if n == 0 then 1\n  else n * fact(n - 1)" );
    ( "blocks, lists, and calls",
      "fn classify(n) = {\n  let values = [n, n + 1]\n  choose(values)(0)\n}" );
    ( "pipelines",
      "xs |> map(double) |> sum" );
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
  ]

let () =
  print_endline "Ash surface precedence parser — golden output";
  print_endline "Structural parentheses expose the grouping chosen by the parser.";

  heading "Every adjacent precedence boundary, loosest to tightest";
  List.iter show boundaries;

  heading "Associativity at every operator level";
  List.iter show associativity;

  heading "Required surface constructs";
  List.iter (fun (title, source) -> show_program title source) constructs;

  heading "Parser diagnostics";
  List.iter show_error malformed

