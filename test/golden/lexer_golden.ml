(* Golden output for the surface lexer (to-do task 1.1).

   Three things are pinned here that unit assertions state poorly:

   - that every sample in the spec's §4 through §6 lexes, and into what;
   - that the ambiguous operator prefixes resolve by maximal munch, shown as a
     table a reader can check against the precedence list at a glance;
   - that a malformed literal produces a diagnostic worth reading, located
     where the mistake is.

   Regenerate with `dune runtest --auto-promote` and read the diff: a change
   here is a change to the language's lexicon or to a diagnostic, and both are
   things a reviewer should see. *)

open Ash_core
open Ash_syntax

let file = "golden.ash"
let rule () = print_endline (String.make 74 '-')

let heading title =
  print_newline ();
  rule ();
  Printf.printf "%s\n" title;
  rule ()

(* Tokens grouped by the source line they start on, so the sample and what it
   lexed to can be read side by side. *)
let show_sample title source =
  Printf.printf "\n== %s ==\n" title;
  let tokens = Lexer.tokens ~file source in
  let lines = String.split_on_char '\n' source in
  let on_line n =
    List.filter (fun t -> t.Token.span.Span.start.Span.line = n) tokens
  in
  List.iteri
    (fun index text ->
      let number = index + 1 in
      Printf.printf "  %2d | %s\n" number text;
      match on_line number with
      | [] -> ()
      | line_tokens ->
          Printf.printf "     : %s\n"
            (String.concat " "
               (List.map
                  (fun t ->
                    match t.Token.kind with
                    | Token.Eof -> "<eof>"
                    | kind -> Token.spelling kind)
                  line_tokens)))
    lines

(* Every token in full: kind, spelling, span, and whether a line break precedes
   it. This is where a span regression shows up. *)
let show_detail title source =
  Printf.printf "\n== %s ==\n" title;
  List.iter (fun line -> Printf.printf "  | %s\n" line) (String.split_on_char '\n' source);
  List.iter
    (fun token ->
      Printf.printf "  %s %-11s %-14s %s\n"
        (if token.Token.starts_line then ">" else " ")
        (Token.name token.Token.kind)
        (match token.Token.kind with
        | Token.Eof -> ""
        | kind -> Token.spelling kind)
        (Span.to_string token.Token.span))
    (Lexer.tokens ~file source)

(* Kind names rather than spellings: the question here is which token was
   produced, not what it looks like. *)
let show_kinds source =
  let tokens =
    List.filter
      (fun t -> not (Token.equal_kind t.Token.kind Token.Eof))
      (Lexer.tokens ~file source)
  in
  Printf.printf "  %-20s %s\n" source
    (String.concat " "
       (List.map
          (fun t ->
            Printf.sprintf "[%s %s]" (Token.name t.Token.kind)
              (Token.spelling t.Token.kind))
          tokens))

let show_error source =
  match Lexer.tokens ~file source with
  | tokens ->
      Printf.printf "  %-24s lexed as %s\n" (String.escaped source)
        (String.concat " "
           (List.filter_map
              (fun t ->
                match t.Token.kind with
                | Token.Eof -> None
                | kind -> Some (Token.spelling kind))
              tokens))
  | exception Error.Ash_error error ->
      Printf.printf "  %-24s %s\n" (String.escaped source) (Error.to_string error)

(* The spec's own samples *)

let samples =
  [
    ( "§4.1 bindings and mutation",
      "let x = 42\nvar counter = 0\ncounter := counter + 1" );
    ( "§4.1 functions",
      "fn square(x) = x * x\nlet double = fn(x) -> x * 2" );
    ( "§4.1 fact",
      "fn fact(n) =\n  if n == 0 then 1\n  else n * fact(n - 1)" );
    ( "§4.1 a block with symbols",
      "fn classify(n) = {\n\
      \  let m = n % 3\n\
      \  if m == 0 then 'zero else if m == 1 then 'one else 'two\n\
       }" );
    ("§4.1 lists and pipelines", "[1, 2, 3]\n1 :: [2, 3]\nxs |> map(double) |> sum");
    ("§4.2 match", "fn length(xs) =\n  match xs {\n    []      -> 0\n    _ :: ys -> 1 + length(ys)\n  }");
    ( "§4.3 quotation and splicing",
      "let e = `{ 1 + 2 * 3 }\nrun(e)                    # 7\nlet b = `{ ${a} + ${a} }\nlift(42)" );
    ( "§4.3 staged power",
      "fn power(n, x) =\n\
      \  if n == 0 then `{ 1 }\n\
      \  else `{ ${x} * ${power(n - 1, x)} }" );
    ( "§4.4 quasiquote patterns",
      "match e {\n\
      \  `{ ${a} + 0 }   -> simplify(a)\n\
      \  `{ ${f}(${x}) } -> `{ ${simplify(f)}(${simplify(x)}) }\n\
      \  _               -> e\n\
       }" );
    ( "§5.3 the money demo",
      "up {\n\
      \  let base = eval\n\
      \  eval := fn(e, r, k) -> {\n\
      \    print(indent(depth), show(e))\n\
      \    base(e, r, k)\n\
      \  }\n\
       }" );
    ( "§5.4 a reifier",
      "let my_quote = reifier(exp, env, k) -> k(arg(exp, 0))\nmy_quote(1 + 2)     # the code, not 3" );
    ("§5.5 meta_with", "meta_with(eval = tracing(eval)) {\n  fib(3)\n}");
    ( "§6 the self-interpreter",
      "open fn eval(e, r, k) =\n\
      \  match e {\n\
      \    Lit(c)         -> k(c)\n\
      \    If(c, t, f)    -> eval(c, r, fn(b) ->\n\
      \                        if truthy(b) then eval(t, r, k) else eval(f, r, k))\n\
      \  }" );
  ]

(* Operators whose prefixes are also operators. Maximal munch decides these, and
   the table is the readable statement of what it decided. *)
let ambiguous =
  [
    "a | b || c |> d";
    "x = y == z";
    "x != y !z";
    "a < b <= c > d >= e";
    "1 :: xs";
    "x := 1";
    "n - 1 -> x";
    "-x";
    "a && b";
    "`{ ${x} }";
    "empty?(xs)";
    "_ _x let letter";
    "f(x); g(y)";
  ]

let malformed =
  [
    "12abc";
    "1.5";
    "99999999999999999999";
    "\"unterminated";
    "\"broken\nstring\"";
    "\"bad \\q escape\"";
    "\"\\x2";
    "'";
    "`x";
    "$x";
    "a & b";
    "a : b";
    "x @ y";
    "empty??";
  ]

let () =
  print_endline "Ash surface lexer — golden output";
  print_endline "Regenerate with `dune runtest --auto-promote`.";

  heading "Spec samples: source and the tokens each line produced";
  List.iter (fun (title, source) -> show_sample title source) samples;

  heading "Spans and layout (`>` marks a token that starts a line)";
  show_detail "a two-line block" "let x = 1\n{ x + 2 }";
  show_detail "comments and blank lines"
    "# leading comment\n\nlet x = 1  # trailing comment\n# only a comment\nx";
  show_detail "string escapes" "\"a\\nb\" \"\\x41\" \"quote: \\\"\"";
  show_detail "an empty file" "";

  heading "Ambiguous operator prefixes, resolved by maximal munch";
  List.iter show_kinds ambiguous;

  heading "Malformed literals and characters that begin no token";
  List.iter show_error malformed
