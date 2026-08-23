open Ash_core

type kind =
  | Int of int
  | String of string
  | Symbol of string
  | True
  | False
  | Ident of string
  | Let
  | Var
  | Fn
  | If
  | Then
  | Else
  | Match
  | Open
  | Up
  | Meta_with
  | Reifier
  | Pipe_forward
  | Or
  | And
  | Eq
  | Ne
  | Lt
  | Le
  | Gt
  | Ge
  | Cons
  | Plus
  | Minus
  | Star
  | Slash
  | Percent
  | Bang
  | Assign
  | Equals
  | Arrow
  | Bar
  | Dot
  | Comma
  | Semicolon
  | Lparen
  | Rparen
  | Lbrace
  | Rbrace
  | Lbracket
  | Rbracket
  | Underscore
  | Quote_open
  | Splice_open
  | Eof

type t = { kind : kind; span : Span.t; starts_line : bool }

(* The reserved words. Everything else a program can write as a name is an
   [Ident]: `run`, `lift`, `reflect`, `resume`, `eval`, and `print` are ordinary
   bindings, so reserving them would stop a program from shadowing what it is
   reflecting on — which is much of the point. A word is reserved only when the
   parser must recognize it before it can parse what follows, which is why
   `meta_with` is here: its argument list contains `=`, and that is not an
   expression. *)
let keywords =
  [
    ("true", True);
    ("false", False);
    ("let", Let);
    ("var", Var);
    ("fn", Fn);
    ("if", If);
    ("then", Then);
    ("else", Else);
    ("match", Match);
    ("open", Open);
    ("up", Up);
    ("meta_with", Meta_with);
    ("reifier", Reifier);
  ]

let keyword_of_string text = List.assoc_opt text keywords
let is_keyword text = Option.is_some (keyword_of_string text)

let spelling = function
  | Int n -> string_of_int n
  | String s -> Constant.escape_string s
  | Symbol s -> "'" ^ s
  | True -> "true"
  | False -> "false"
  | Ident name -> name
  | Let -> "let"
  | Var -> "var"
  | Fn -> "fn"
  | If -> "if"
  | Then -> "then"
  | Else -> "else"
  | Match -> "match"
  | Open -> "open"
  | Up -> "up"
  | Meta_with -> "meta_with"
  | Reifier -> "reifier"
  | Pipe_forward -> "|>"
  | Or -> "||"
  | And -> "&&"
  | Eq -> "=="
  | Ne -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="
  | Cons -> "::"
  | Plus -> "+"
  | Minus -> "-"
  | Star -> "*"
  | Slash -> "/"
  | Percent -> "%"
  | Bang -> "!"
  | Assign -> ":="
  | Equals -> "="
  | Arrow -> "->"
  | Bar -> "|"
  | Dot -> "."
  | Comma -> ","
  | Semicolon -> ";"
  | Lparen -> "("
  | Rparen -> ")"
  | Lbrace -> "{"
  | Rbrace -> "}"
  | Lbracket -> "["
  | Rbracket -> "]"
  | Underscore -> "_"
  | Quote_open -> "`{"
  | Splice_open -> "${"
  (* End of input is a token so that "what was expected here" has somewhere to
     point, but it is not written down, so it has no spelling. *)
  | Eof -> ""

let quoted kind = Printf.sprintf "`%s`" (spelling kind)

let describe kind =
  match kind with
  | Int _ -> "an integer literal"
  | String _ -> "a string literal"
  | Symbol _ -> "a symbol literal"
  | Ident name -> Printf.sprintf "the name `%s`" name
  | True | False | Let | Var | Fn | If | Then | Else | Match | Open | Up | Meta_with
  | Reifier ->
      Printf.sprintf "the keyword %s" (quoted kind)
  | Pipe_forward | Or | And | Eq | Ne | Lt | Le | Gt | Ge | Cons | Plus | Minus | Star
  | Slash | Percent | Bang | Assign | Equals | Arrow | Bar | Dot ->
      Printf.sprintf "the operator %s" (quoted kind)
  | Comma | Semicolon | Lparen | Rparen | Lbrace | Rbrace | Lbracket | Rbracket ->
      quoted kind
  | Underscore -> "the wildcard `_`"
  | Quote_open -> "the start of a quotation `` `{ ``"
  | Splice_open -> "the start of a splice `${`"
  | Eof -> "end of input"

let name = function
  | Int _ -> "int"
  | String _ -> "string"
  | Symbol _ -> "symbol"
  | Ident _ -> "ident"
  | True | False | Let | Var | Fn | If | Then | Else | Match | Open | Up | Meta_with
  | Reifier ->
      "keyword"
  | Pipe_forward | Or | And | Eq | Ne | Lt | Le | Gt | Ge | Cons | Plus | Minus | Star
  | Slash | Percent | Bang | Assign | Equals | Arrow | Bar | Dot ->
      "operator"
  | Comma | Semicolon | Lparen | Rparen | Lbrace | Rbrace | Lbracket | Rbracket
  | Underscore ->
      "punctuation"
  | Quote_open | Splice_open -> "quotation"
  | Eof -> "eof"

(* Enumerated rather than defaulted so a new token shape forces this match to be
   revisited instead of silently comparing unequal. *)
let equal_kind a b =
  match (a, b) with
  | Int x, Int y -> Int.equal x y
  | String x, String y -> String.equal x y
  | Symbol x, Symbol y -> String.equal x y
  | Ident x, Ident y -> String.equal x y
  | True, True | False, False -> true
  | Let, Let | Var, Var | Fn, Fn | If, If | Then, Then | Else, Else -> true
  | Match, Match | Open, Open | Up, Up | Meta_with, Meta_with | Reifier, Reifier -> true
  | Pipe_forward, Pipe_forward | Or, Or | And, And | Eq, Eq | Ne, Ne -> true
  | Lt, Lt | Le, Le | Gt, Gt | Ge, Ge | Cons, Cons -> true
  | Plus, Plus | Minus, Minus | Star, Star | Slash, Slash | Percent, Percent -> true
  | Bang, Bang | Assign, Assign | Equals, Equals | Arrow, Arrow | Bar, Bar | Dot, Dot ->
      true
  | Comma, Comma | Semicolon, Semicolon -> true
  | Lparen, Lparen | Rparen, Rparen | Lbrace, Lbrace | Rbrace, Rbrace -> true
  | Lbracket, Lbracket | Rbracket, Rbracket | Underscore, Underscore -> true
  | Quote_open, Quote_open | Splice_open, Splice_open -> true
  | Eof, Eof -> true
  | ( ( Int _ | String _ | Symbol _ | True | False | Ident _ | Let | Var | Fn | If
      | Then | Else | Match | Open | Up | Meta_with | Reifier | Pipe_forward | Or | And
      | Eq | Ne | Lt | Le | Gt | Ge | Cons | Plus | Minus | Star | Slash | Percent
      | Bang | Assign | Equals | Arrow | Bar | Dot | Comma | Semicolon | Lparen
      | Rparen | Lbrace | Rbrace | Lbracket | Rbracket | Underscore | Quote_open
      | Splice_open | Eof ),
      _ ) ->
      false

let equal a b = equal_kind a.kind b.kind && Span.equal a.span b.span

let to_string token =
  Printf.sprintf "%s %s at %s" (name token.kind) (spelling token.kind)
    (Span.to_string token.span)

let pp formatter token = Format.pp_print_string formatter (to_string token)
