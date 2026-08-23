(* Unit tests for the surface lexer (to-do task 1.1). *)

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

(* Which token shapes the corpus below has actually produced. A kind nobody
   lexes is a kind nobody tested, so the run ends by checking the list. *)
let seen = ref []

let note kind =
  if not (List.exists (Token.equal_kind kind) !seen) then seen := kind :: !seen

let lex text = Lexer.tokens ~file:"t.ash" text

let tokens text =
  let all = lex text in
  List.iter (fun t -> note t.Token.kind) all;
  List.filter (fun t -> not (Token.equal_kind t.Token.kind Token.Eof)) all

let kinds text = List.map (fun t -> t.Token.kind) (tokens text)
let spellings text = List.map (fun t -> Token.spelling t.Token.kind) (tokens text)

let check_kinds name expected text =
  let actual = kinds text in
  if not (List.equal Token.equal_kind expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  source:   %s\n  expected: %s\n  actual:   %s\n" name
      (String.escaped text)
      (String.concat " " (List.map Token.spelling expected))
      (String.concat " " (List.map Token.spelling actual)))

let check_error name ~cause ~location text =
  match lex text with
  | produced ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an error, lexed %d token(s)\n" name
        (List.length produced)
  | exception Error.Ash_error error ->
      if not (Error.cause_equal error.Error.cause cause) then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong cause: %s\n" name (Error.to_string error));
      if not (String.equal location (Span.to_string error.Error.span)) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected at: %s\n  reported at: %s\n" name location
          (Span.to_string error.Error.span));
      if error.Error.phase <> Error.Lex then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong phase: %s\n" name (Error.to_string error))

(* Literals *)

let test_literals () =
  check_kinds "integers" [ Token.Int 0; Token.Int 42; Token.Int 1000000 ] "0 42 1000000";
  (* Negation is an operator, so a literal is never negative: the precedence
     table lists unary minus, and `n - 1` must not lex as `n` and `-1`. *)
  check_kinds "a minus is an operator, not part of the literal"
    [ Token.Ident "n"; Token.Minus; Token.Int 1 ] "n - 1";
  check_kinds "so is a leading one" [ Token.Minus; Token.Int 1 ] "-1";
  check_kinds "booleans are keywords, not names" [ Token.True; Token.False ] "true false";
  check_kinds "strings carry their contents, not their spelling"
    [ Token.String "a\nb"; Token.String "A"; Token.String "\"" ]
    "\"a\\nb\" \"\\x41\" \"\\\"\"";
  check_kinds "an empty string" [ Token.String "" ] "\"\"";
  check_kinds "symbols" [ Token.Symbol "zero"; Token.Symbol "empty?" ] "'zero 'empty?";
  check_string "a string literal round-trips through its spelling" "\"a\\nb\""
    (String.concat "" (spellings "\"a\\nb\""))

(* Names and reserved words *)

let test_names () =
  check_kinds "every keyword"
    [
      Token.True; Token.False; Token.Let; Token.Var; Token.Fn; Token.If; Token.Then;
      Token.Else; Token.Match; Token.Open; Token.Up; Token.Meta_with; Token.Reifier;
    ]
    "true false let var fn if then else match open up meta_with reifier";
  check_int "the keyword table is the whole list" 13 (List.length Token.keywords);
  (* A keyword is only a keyword whole: `letter` is a name that starts with one. *)
  check_kinds "a name that begins with a keyword"
    [ Token.Ident "letter"; Token.Ident "ifs"; Token.Ident "upward" ]
    "letter ifs upward";
  (* `empty?` is a registered primitive, so the surface must be able to name it.
     `!` is prefix negation and never part of a name, or `x!y` would depend on
     spacing. *)
  check_kinds "a trailing question mark is part of the name"
    [ Token.Ident "empty?"; Token.Lparen; Token.Ident "xs"; Token.Rparen ]
    "empty?(xs)";
  check_kinds "a name may start with an underscore"
    [ Token.Ident "_x"; Token.Ident "_fresh1" ] "_x _fresh1";
  check_kinds "but a bare underscore is the wildcard"
    [ Token.Underscore; Token.Cons; Token.Ident "ys" ] "_ :: ys";
  check "is_name accepts a name" (Lexer.is_name "xs" && Lexer.is_name "empty?");
  check "is_name accepts a generated name" (Lexer.is_name "_fresh");
  check "is_name rejects a keyword" (not (Lexer.is_name "let"));
  check "is_name rejects a number" (not (Lexer.is_name "1x"));
  check "is_name rejects an operator suffix" (not (Lexer.is_name "x!"));
  check "is_name rejects the empty string" (not (Lexer.is_name ""))

(* Operators and punctuation, resolved by maximal munch *)

let test_operators () =
  check_kinds "the two-character operators"
    [
      Token.Pipe_forward; Token.Or; Token.And; Token.Eq; Token.Ne; Token.Le; Token.Ge;
      Token.Cons; Token.Assign; Token.Arrow;
    ]
    "|> || && == != <= >= :: := ->";
  check_kinds "and the one-character ones their prefixes could have been"
    [
      Token.Bar; Token.Lt; Token.Gt; Token.Bang; Token.Equals; Token.Minus; Token.Plus;
      Token.Star; Token.Slash; Token.Percent; Token.Dot;
    ]
    "| < > ! = - + * / % .";
  (* The longest match wins with no space to help: `|>` is one token even when
     `|` and `>` would both be valid there. *)
  check_kinds "the longest operator wins"
    [ Token.Ident "a"; Token.Or; Token.Ident "b"; Token.Pipe_forward; Token.Ident "c" ]
    "a||b|>c";
  check_kinds "including when the shorter one would also parse"
    [ Token.Ident "x"; Token.Ne; Token.Bang; Token.Ident "y" ] "x!=!y";
  check_kinds "punctuation"
    [
      Token.Comma; Token.Semicolon; Token.Lparen; Token.Rparen; Token.Lbrace;
      Token.Rbrace; Token.Lbracket; Token.Rbracket;
    ]
    ", ; ( ) { } [ ]"

let test_staging () =
  check_kinds "a quotation and a splice are one token each"
    [
      Token.Quote_open; Token.Splice_open; Token.Ident "x"; Token.Rbrace; Token.Plus;
      Token.Int 1; Token.Rbrace;
    ]
    "`{ ${x} + 1 }";
  (* The brace must follow immediately: neither character means anything alone. *)
  check_error "a backtick with no brace"
    ~cause:(Error.Unexpected { found = "`x`"; expected = "`{` after a backtick" })
    ~location:"t.ash:1:1-2" "`x";
  check_error "a dollar with no brace"
    ~cause:(Error.Unexpected { found = "`x`"; expected = "`{` after `$`" })
    ~location:"t.ash:1:1-2" "$x";
  check_error "a backtick at the end of input"
    ~cause:(Error.Unexpected { found = "end of input"; expected = "`{` after a backtick" })
    ~location:"t.ash:1:1-2" "`"

(* Layout: comments, blank lines, and which tokens start one *)

let starts text =
  List.map (fun t -> t.Token.starts_line) (Lexer.tokens ~file:"t.ash" text)

let test_layout () =
  check_kinds "a comment runs to end of line"
    [ Token.Ident "x"; Token.Ident "y" ] "x # comment with let and 12abc in it\ny";
  check_kinds "a comment may end the file" [ Token.Ident "x" ] "x # trailing";
  check_kinds "a file may be only a comment" [] "# nothing else";
  check_kinds "and may be empty" [] "";
  (* The spec's blocks separate statements by newline as well as by `;`, so the
     parser needs to know where a line began. *)
  (* The lists include the Eof flag, which reports the layout at the end. *)
  check "the first token of a file starts a line"
    (List.equal Bool.equal [ true; false; false; false ] (starts "a b c"));
  check "a token after a newline starts a line"
    (List.equal Bool.equal
       [ true; false; true; false; true; false ]
       (starts "a b\nc d\ne"));
  check "a comment line still ends the line"
    (List.equal Bool.equal [ true; true; true ] (starts "a # note\nb\n"));
  check "blank lines do not add tokens"
    (List.equal Bool.equal [ true; true; true ] (starts "a\n\n\nb\n"));
  check "end of input reports the layout it found"
    (List.equal Bool.equal [ true; true ] (starts "a\n"));
  check "and does not invent one"
    (List.equal Bool.equal [ true; false ] (starts "a"))

(* Spans *)

let test_spans () =
  let located text =
    List.map
      (fun t -> Printf.sprintf "%s@%s" (Token.spelling t.Token.kind) (Span.to_string t.Token.span))
      (tokens text)
  in
  check_string "every token carries where it was written"
    "let@t.ash:1:1-4 x@t.ash:1:5-6 =@t.ash:1:7-8 42@t.ash:1:9-11"
    (String.concat " " (located "let x = 42"));
  check_string "spans cross lines correctly"
    "x@t.ash:1:1-2 +@t.ash:2:3-4 y@t.ash:3:1-2"
    (String.concat " " (located "x\n  +\ny"));
  check_string "a span covers the whole literal, escapes included"
    "\"a\\nb\"@t.ash:1:1-7"
    (String.concat " " (located "\"a\\nb\""));
  (* End of input is a token so a parser has somewhere to point when a
     construct runs off the end. *)
  let last = List.nth (lex "x y") 2 in
  check "the stream ends with exactly one Eof"
    (Token.equal_kind last.Token.kind Token.Eof);
  check_string "at the end of the input" "t.ash:1:4"
    (Span.to_string last.Token.span);
  check_int "and nothing follows it" 3 (List.length (lex "x y"))

(* Malformed literals *)

let test_malformed_literals () =
  (* Splitting is the hazard: `12abc` as `12` then `abc` would parse as an
     application in some positions and a syntax error in others. *)
  check_error "a number running into a name"
    ~cause:(Error.Unexpected { found = "`12abc`"; expected = "an integer literal" })
    ~location:"t.ash:1:1-6" "12abc";
  check_error "a fractional literal"
    ~cause:
      (Error.Unexpected
         {
           found = "`1.5`";
           expected = "an integer literal (Ash has no floating-point numbers)";
         })
    ~location:"t.ash:1:1-4" "1.5";
  check_error "an integer too large for the host"
    ~cause:
      (Error.Unexpected
         {
           found = "`99999999999999999999`";
           expected = "an integer that fits in a machine word";
         })
    ~location:"t.ash:1:1-21" "99999999999999999999";
  (* A field access on an integer is a grammar question, not a lexical one. *)
  check_kinds "a dot not followed by a digit is an operator"
    [ Token.Int 1; Token.Dot; Token.Ident "x" ] "1.x";
  check_error "an unterminated string" ~cause:(Error.Unterminated "string literal")
    ~location:"t.ash:1:1-6" "\"open";
  check_error "a string literal does not span lines"
    ~cause:(Error.Unterminated "string literal") ~location:"t.ash:1:1-4" "\"ab\ncd\"";
  check_error "an unterminated escape" ~cause:(Error.Unterminated "string literal")
    ~location:"t.ash:1:1-4" "\"a\\";
  check_error "an unknown escape"
    ~cause:(Error.Unexpected { found = "`\\q`"; expected = "a string escape" })
    ~location:"t.ash:1:2-4" "\"\\q\"";
  check_error "a bad hex escape"
    ~cause:(Error.Unexpected { found = "`z`"; expected = "a hexadecimal digit" })
    ~location:"t.ash:1:2-4" "\"\\xzz\"";
  check_error "a quote with no symbol name"
    ~cause:(Error.Unexpected { found = "`'`"; expected = "a symbol name" })
    ~location:"t.ash:1:1-2" "'"

let test_stray_characters () =
  (* Characters that begin no token are reported as themselves rather than
     turned into a token the parser would have to reject. *)
  check_error "a lone ampersand" ~cause:(Error.Unexpected_character '&')
    ~location:"t.ash:1:3-4" "a & b";
  check_error "a lone colon" ~cause:(Error.Unexpected_character ':')
    ~location:"t.ash:1:3-4" "a : b";
  check_error "an at sign" ~cause:(Error.Unexpected_character '@')
    ~location:"t.ash:1:1-2" "@";
  check_error "a question mark with no name before it"
    ~cause:(Error.Unexpected_character '?') ~location:"t.ash:1:1-2" "?";
  check_error "a doubled question mark" ~cause:(Error.Unexpected_character '?')
    ~location:"t.ash:1:7-8" "empty??"

(* The spec's samples lex *)

let test_spec_samples () =
  let lexes name source =
    match lex source with
    | (_ : Token.t list) -> ()
    | exception Error.Ash_error error ->
        incr failures;
        Printf.printf "FAIL %s does not lex\n  %s\n" name (Error.to_string error)
  in
  lexes "fact" "fn fact(n) =\n  if n == 0 then 1\n  else n * fact(n - 1)";
  lexes "classify"
    "fn classify(n) = {\n  let m = n % 3\n  if m == 0 then 'zero else 'two\n}";
  lexes "pipelines" "xs |> map(double) |> sum";
  lexes "staged power"
    "fn power(n, x) =\n  if n == 0 then `{ 1 }\n  else `{ ${x} * ${power(n - 1, x)} }";
  lexes "quasiquote patterns"
    "match e {\n  `{ ${a} + 0 } -> simplify(a)\n  _ -> e\n}";
  lexes "the money demo"
    "up {\n  let base = eval\n  eval := fn(e, r, k) -> { print(show(e)) base(e, r, k) }\n}";
  lexes "meta_with" "meta_with(eval = tracing(eval)) {\n  fib(3)\n}";
  lexes "a reifier" "let my_quote = reifier(exp, env, k) -> k(arg(exp, 0))";
  lexes "the self-interpreter"
    "open fn eval(e, r, k) =\n  match e {\n    Lit(c) -> k(c)\n  }"

(* Nothing untested *)

let all_kinds =
  [
    Token.Int 0; Token.String "s"; Token.Symbol "s"; Token.True; Token.False;
    Token.Ident "x"; Token.Let; Token.Var; Token.Fn; Token.If; Token.Then; Token.Else;
    Token.Match; Token.Open; Token.Up; Token.Meta_with; Token.Reifier;
    Token.Pipe_forward; Token.Or; Token.And; Token.Eq; Token.Ne; Token.Lt; Token.Le;
    Token.Gt; Token.Ge; Token.Cons; Token.Plus; Token.Minus; Token.Star; Token.Slash;
    Token.Percent; Token.Bang; Token.Assign; Token.Equals; Token.Arrow; Token.Bar;
    Token.Dot; Token.Comma; Token.Semicolon; Token.Lparen; Token.Rparen; Token.Lbrace;
    Token.Rbrace; Token.Lbracket; Token.Rbracket; Token.Underscore; Token.Quote_open;
    Token.Splice_open; Token.Eof;
  ]

(* Payloads differ between a test corpus and this list, so coverage is by
   constructor. A new token kind lands here as a failure naming itself. *)
let canonical = function
  | Token.Int _ -> Token.Int 0
  | Token.String _ -> Token.String "s"
  | Token.Symbol _ -> Token.Symbol "s"
  | Token.Ident _ -> Token.Ident "x"
  | other -> other

let test_coverage () =
  check_int "every token kind is enumerated" 50 (List.length all_kinds);
  check "token kinds are distinct"
    (List.length all_kinds
    = List.length
        (List.sort_uniq compare (List.map (fun k -> Token.spelling k ^ Token.name k) all_kinds)));
  let produced = List.map canonical !seen in
  List.iter
    (fun kind ->
      check
        (Printf.sprintf "the corpus lexes %s (%s)" (Token.describe kind)
           (Token.name kind))
        (List.exists (Token.equal_kind kind) produced))
    all_kinds;
  (* Every kind has all three renderings. *)
  List.iter
    (fun kind ->
      check ("a describing phrase for " ^ Token.name kind)
        (String.length (Token.describe kind) > 0);
      check ("a tag for " ^ Token.describe kind) (String.length (Token.name kind) > 0);
      check ("a spelling for " ^ Token.describe kind)
        (Token.equal_kind kind Token.Eof || String.length (Token.spelling kind) > 0))
    all_kinds;
  check_string "Eof has no spelling" "" (Token.spelling Token.Eof);
  check_string "a token renders with its location" "int 42 at t.ash:1:1-3"
    (Token.to_string (List.hd (lex "42")))

let () =
  test_literals ();
  test_names ();
  test_operators ();
  test_staging ();
  test_layout ();
  test_spans ();
  test_malformed_literals ();
  test_stray_characters ();
  test_spec_samples ();
  test_coverage ();
  if !failures > 0 then (
    Printf.printf "%d lexer assertion(s) failed\n" !failures;
    exit 1)
