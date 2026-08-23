open Ash_core

let fail ~span cause = Error.raise_cause ~phase:Error.Lex ~span cause

let is_whitespace = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false
let is_digit = function '0' .. '9' -> true | _ -> false
let is_name_start = function 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false
let is_name_char = function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false

let is_name text =
  let length = String.length text in
  if length = 0 || Token.is_keyword text then false
  else
    let body = if text.[length - 1] = '?' then String.sub text 0 (length - 1) else text in
    String.length body > 0
    && is_name_start body.[0]
    && String.for_all is_name_char body

(* Whitespace and comments, reporting whether a line ended along the way: that is
   the one thing about layout the lexer must not throw away. *)
let skip_ignorable c =
  let crossed = ref false in
  let rec loop () =
    match Cursor.peek c with
    | Some '\n' ->
        crossed := true;
        Cursor.advance c;
        loop ()
    | Some ch when is_whitespace ch ->
        Cursor.advance c;
        loop ()
    | Some '#' ->
        (* To end of line, and the newline itself is then ordinary whitespace, so
           a comment on its own line still starts a line for what follows. *)
        let rec to_end_of_line () =
          match Cursor.peek c with
          | None -> ()
          | Some '\n' -> ()
          | Some _ ->
              Cursor.advance c;
              to_end_of_line ()
        in
        to_end_of_line ();
        loop ()
    | Some _ | None -> ()
  in
  loop ();
  !crossed

let take_while c predicate =
  let buffer = Buffer.create 16 in
  let rec loop () =
    match Cursor.peek c with
    | Some ch when predicate ch ->
        Buffer.add_char buffer ch;
        Cursor.advance c;
        loop ()
    | Some _ | None -> Buffer.contents buffer
  in
  loop ()

(* Names.

   A single trailing [?] is part of the name — that is how `empty?` is written.
   A trailing [!] is not: [!] is prefix negation, and allowing it in names would
   make `x!y` depend on spacing. *)
let read_name c ~start =
  let body = take_while c is_name_char in
  let text =
    match Cursor.peek c with
    | Some '?' ->
        Cursor.advance c;
        body ^ "?"
    | Some _ | None -> body
  in
  let span = Cursor.span_from c start in
  match Token.keyword_of_string text with
  | Some keyword -> (keyword, span)
  | None ->
      if String.equal text "_" then (Token.Underscore, span) else (Token.Ident text, span)

(* Integers.

   Core's numeric domain is machine integers (ADR 0002), so a literal that is not
   one is refused here rather than truncated or split. Splitting is the real
   hazard: `12abc` lexing as `12` then `abc` would parse as an application in
   some positions and a syntax error in others, both of them confusing. *)
let read_number c ~start =
  let digits = take_while c is_digit in
  let malformed expected =
    let rest = take_while c (fun ch -> is_name_char ch || ch = '?' || ch = '.') in
    let span = Cursor.span_from c start in
    fail ~span
      (Error.Unexpected { found = Printf.sprintf "`%s%s`" digits rest; expected })
  in
  match Cursor.peek c with
  | Some '.' when Option.fold ~none:false ~some:is_digit (Cursor.peek_ahead c 1) ->
      (* Ash has one numeric type. A fractional literal is a mistake worth
         naming, not two tokens with a dot between them. *)
      malformed "an integer literal (Ash has no floating-point numbers)"
  | Some ch when is_name_start ch -> malformed "an integer literal"
  | Some _ | None -> (
      match int_of_string_opt digits with
      | Some value -> (Token.Int value, Cursor.span_from c start)
      | None ->
          fail ~span:(Cursor.span_from c start)
            (Error.Unexpected
               {
                 found = Printf.sprintf "`%s`" digits;
                 expected = "an integer that fits in a machine word";
               }))

let hex_value ~span ch =
  match ch with
  | '0' .. '9' -> Char.code ch - Char.code '0'
  | 'a' .. 'f' -> Char.code ch - Char.code 'a' + 10
  | 'A' .. 'F' -> Char.code ch - Char.code 'A' + 10
  | _ ->
      fail ~span
        (Error.Unexpected
           { found = Printf.sprintf "`%c`" ch; expected = "a hexadecimal digit" })

(* Strings. The escapes are exactly the ones [Constant.escape_string] produces,
   so a printed literal reads back as itself. A literal does not span lines: an
   unterminated one is reported at the opening quote, which is where the mistake
   is, rather than at the end of the file. *)
let read_string c ~start =
  Cursor.advance c (* the opening quote *);
  let buffer = Buffer.create 16 in
  let unterminated () = fail ~span:(Cursor.span_from c start) (Error.Unterminated "string literal") in
  let rec loop () =
    match Cursor.peek c with
    | None | Some '\n' -> unterminated ()
    | Some '"' ->
        Cursor.advance c;
        Buffer.contents buffer
    | Some '\\' -> (
        (* The span covers the backslash and the character after it, so a bad
           escape is underlined as written rather than pointed at halfway. *)
        let escape_start = Cursor.position c in
        Cursor.advance c;
        match Cursor.peek c with
        | None | Some '\n' -> unterminated ()
        | Some escape ->
            Cursor.advance c;
            let escape_span = Cursor.span_from c escape_start in
            (match escape with
            | 'n' -> Buffer.add_char buffer '\n'
            | 't' -> Buffer.add_char buffer '\t'
            | 'r' -> Buffer.add_char buffer '\r'
            | '\\' -> Buffer.add_char buffer '\\'
            | '"' -> Buffer.add_char buffer '"'
            | 'x' ->
                let digit () =
                  match Cursor.peek c with
                  | None | Some '\n' -> unterminated ()
                  | Some ch ->
                      Cursor.advance c;
                      hex_value ~span:escape_span ch
                in
                let high = digit () in
                let low = digit () in
                Buffer.add_char buffer (Char.chr ((high * 16) + low))
            | other ->
                fail ~span:escape_span
                  (Error.Unexpected
                     { found = Printf.sprintf "`\\%c`" other; expected = "a string escape" }));
            loop ())
    | Some ch ->
        Cursor.advance c;
        Buffer.add_char buffer ch;
        loop ()
  in
  let contents = loop () in
  (Token.String contents, Cursor.span_from c start)

let read_symbol c ~start =
  Cursor.advance c (* the quote *);
  let body = take_while c is_name_char in
  let text =
    match Cursor.peek c with
    | Some '?' ->
        Cursor.advance c;
        body ^ "?"
    | Some _ | None -> body
  in
  let span = Cursor.span_from c start in
  if String.equal text "" then
    fail ~span (Error.Unexpected { found = "`'`"; expected = "a symbol name" })
  else (Token.Symbol text, span)

(* Operators and punctuation, longest match first: a two-character operator is
   checked before either of its halves, so `|>` is never `|` then `>`, and `::`
   is never two failed attempts at `:`. The one-character table is what remains
   after those, which is why `:` and `&` are absent from it: neither means
   anything alone, and reporting the character is a better diagnostic than
   inventing a token the parser would have to reject. *)
let two_character = function
  | '|', '>' -> Some Token.Pipe_forward
  | '|', '|' -> Some Token.Or
  | '&', '&' -> Some Token.And
  | '=', '=' -> Some Token.Eq
  | '!', '=' -> Some Token.Ne
  | '<', '=' -> Some Token.Le
  | '>', '=' -> Some Token.Ge
  | ':', ':' -> Some Token.Cons
  | ':', '=' -> Some Token.Assign
  | '-', '>' -> Some Token.Arrow
  | _, _ -> None

let one_character = function
  | '|' -> Some Token.Bar
  | '<' -> Some Token.Lt
  | '>' -> Some Token.Gt
  | '+' -> Some Token.Plus
  | '-' -> Some Token.Minus
  | '*' -> Some Token.Star
  | '/' -> Some Token.Slash
  | '%' -> Some Token.Percent
  | '!' -> Some Token.Bang
  | '=' -> Some Token.Equals
  | '.' -> Some Token.Dot
  | ',' -> Some Token.Comma
  | ';' -> Some Token.Semicolon
  | '(' -> Some Token.Lparen
  | ')' -> Some Token.Rparen
  | '{' -> Some Token.Lbrace
  | '}' -> Some Token.Rbrace
  | '[' -> Some Token.Lbracket
  | ']' -> Some Token.Rbracket
  | _ -> None

(* A brace must follow the backtick or the dollar with nothing between: `` `{ ``
   and [${] are single tokens, and a lone backtick or dollar is not part of the
   language at all. *)
let read_brace_opener c ~start ~kind ~after =
  Cursor.advance c;
  match Cursor.peek c with
  | Some '{' ->
      Cursor.advance c;
      (kind, Cursor.span_from c start)
  | following ->
      (* The complaint is about what follows, so that is what the message names;
         the span stays on the introducer, which is the character that made a
         brace mandatory. *)
      fail
        ~span:(Cursor.span_from c start)
        (Error.Unexpected
           {
             found =
               (match following with
               | None -> "end of input"
               | Some ch -> Printf.sprintf "`%c`" ch);
             expected = Printf.sprintf "`{` after %s" after;
           })

let scan c ~start ch =
  if is_digit ch then read_number c ~start
  else if is_name_start ch then read_name c ~start
  else
    match ch with
    | '"' -> read_string c ~start
    | '\'' -> read_symbol c ~start
    (* A quotation opens with `` `{ `` and a splice with [${]: one token each,
       so the brace must follow immediately. *)
    | '`' -> read_brace_opener c ~start ~kind:Token.Quote_open ~after:"a backtick"
    | '$' -> read_brace_opener c ~start ~kind:Token.Splice_open ~after:"`$`"
    | _ -> (
        let pair =
          Option.bind (Cursor.peek_ahead c 1) (fun next -> two_character (ch, next))
        in
        match pair with
        | Some kind ->
            Cursor.advance c;
            Cursor.advance c;
            (kind, Cursor.span_from c start)
        | None -> (
            match one_character ch with
            | Some kind ->
                Cursor.advance c;
                (kind, Cursor.span_from c start)
            | None ->
                Cursor.advance c;
                fail ~span:(Cursor.span_from c start) (Error.Unexpected_character ch)))

let tokens ?(file = "<string>") source =
  let c = Cursor.create ~file source in
  (* The first token of a file starts a line, so a file that opens with a block
     statement is not a special case for the parser. *)
  let fresh_line = ref true in
  let emit kind span = { Token.kind; span; starts_line = !fresh_line } in
  let rec loop acc =
    if skip_ignorable c then fresh_line := true;
    let start = Cursor.position c in
    match Cursor.peek c with
    (* End of input reports the layout it actually found: a file ending after a
       newline starts a line, one ending mid-line does not. *)
    | None -> List.rev (emit Token.Eof (Span.point start) :: acc)
    | Some ch ->
        let kind, span = scan c ~start ch in
        let token = emit kind span in
        fresh_line := false;
        loop (token :: acc)
  in
  loop []
