(* Pinned Core for the surface-to-Core lowering (to-do task 1.4).

   The output is the canonical Core notation, so it is read the same way the
   Core reader reads it. Binders are renamed deterministically by the printer,
   which is what keeps the file independent of the identifier counter. *)

open Ash_core
open Ash_syntax
open Ash_runtime

let file = "golden.ash"
let rule () = print_endline (String.make 74 '-')

let heading title =
  print_newline ();
  rule ();
  Printf.printf "%s\n" title;
  rule ()

let scope () =
  Desugar.scope_of_globals
    (List.map
       (fun (ident, _) -> (Ident.name ident, ident))
       (Primitives.globals (Primitives.create ())))

let lower source = Desugar.program ~scope:(scope ()) (Parser.program ~file source)

let show source =
  Printf.printf "  %-40s => %s\n" source (Core_printer.to_string (lower source))

let show_program title source =
  Printf.printf "\n== %s ==\n" title;
  List.iter (fun line -> Printf.printf "  | %s\n" line) (String.split_on_char '\n' source);
  Printf.printf "  =>\n%s\n" (Core_printer.to_string (lower source))

let show_error source =
  match lower source with
  | lowered -> Printf.printf "  %-34s lowered to %s\n" source (Core_printer.to_string lowered)
  | exception Error.Ash_error error ->
      Printf.printf "  %-34s %s\n" source (Error.to_string error)

(* Which rewrite produced each node, innermost generator last, so the table
   shows that a lowered program still knows where every invented node came
   from. *)
let rec generators node =
  let own = Span.generators (Core.span node) in
  own @ List.concat_map generators (Core.children node)

let show_provenance source =
  let names = List.sort_uniq String.compare (generators (lower source)) in
  Printf.printf "  %-40s %s\n" source
    (match names with [] -> "(nothing generated)" | _ -> String.concat " " names)

let sugar =
  [
    "1; 2";
    "let x = 1; x";
    "var x = 1; x := 2";
    "fn f(n) = n";
    "fn(x) -> x";
    "true && false";
    "true || false";
    "!true";
    "0 - 1";
    "let x = 1; -x";
    "[]";
    "[1, 2]";
    "1 :: [2]";
    "[1] |> length";
    "1 |> cons([])";
    "{ let x = 1; x + 1 }";
    "if true then 1 else 2";
    "1 == 2";
    "1 + 2 * 3";
    "open fn f(n) = f(n)";
    "open fn f() = 1; f := fn() -> 2";
  ]

let provenance =
  [
    "1 + 2"; "1; 2"; "let x = 1"; "fn f() = 1"; "open fn f() = 1"; "[1]";
    "true && false"; "match 1 { _ -> 2 }";
  ]

let errors =
  [
    "nope";
    "let x = 1; x := 2";
    "head := 1";
    "fn f() = 1; fn f() = 2";
    "fn f() = 1; f := fn() -> 2";
    "`{ 1 + 2 }";
    "match e { Lit(c) -> c }";
    "match e { `{ ${a} + 0 } -> a }";
  ]

let () =
  print_endline "Ash surface-to-Core desugaring — golden output";
  print_endline "Binder names are chosen by the Core printer, not by the desugarer.";

  heading "Derived sugar, one construct at a time";
  List.iter show sugar;

  heading "Documented programs";
  show_program "§4.1 fact" "fn fact(n) =\n  if n == 0 then 1\n  else n * fact(n - 1)\nfact(5)";
  show_program "§4.1 classify"
    "fn classify(n) = {\n\
    \  let m = n % 3\n\
    \  if m == 0 then 'zero else if m == 1 then 'one else 'two\n\
     }";
  show_program "§4.2 length"
    "fn length(xs) =\n\
    \  match xs {\n\
    \    []      -> 0\n\
    \    _ :: ys -> 1 + length(ys)\n\
    \  }";
  show_program "mutual recursion in one group"
    "fn even(n) = if n == 0 then true else odd(n - 1)\n\
     fn odd(n) = if n == 0 then false else even(n - 1)";
  show_program "alternatives share one body"
    "match [7] {\n  [x] | x :: [] -> x + 1\n  _ -> 0\n}";
  show_program "closure-visible mutation"
    "var c = 0\nfn bump() = c := c + 1\nbump()\nc";

  heading "Provenance: which rewrite invented which node";
  List.iter show_provenance provenance;

  heading "Diagnostics";
  List.iter show_error errors
