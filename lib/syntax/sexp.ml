open Ash_core

type t = { datum : datum; span : Span.t }

and datum =
  | Int of int
  | Bool of bool
  | Str of string
  | Sym of string
  | Atom of string
  | List of t list

let datum_name = function
  | Int _ -> "an integer"
  | Bool _ -> "a boolean"
  | Str _ -> "a string"
  | Sym _ -> "a symbol"
  | Atom _ -> "an identifier"
  | List _ -> "a list"

(* Reading.

   The cursor is the one piece of mutable state in this module. It is scoped to a
   single read and observable nowhere else, so it is a local counter rather than
   part of any Ash value. *)

type cursor = {
  source : string;
  file : string;
  mutable offset : int;
  mutable line : int;
  mutable column : int;
}

let cursor ~file source = { source; file; offset = 0; line = 1; column = 1 }
let position c = Span.position ~file:c.file ~line:c.line ~column:c.column ~offset:c.offset
let at_end c = c.offset >= String.length c.source
let peek c = if at_end c then None else Some c.source.[c.offset]

let advance c =
  (match c.source.[c.offset] with
  | '\n' ->
      c.line <- c.line + 1;
      c.column <- 1
  | _ -> c.column <- c.column + 1);
  c.offset <- c.offset + 1

let fail ~span cause = Error.raise_cause ~phase:Error.Lex ~span cause

let is_whitespace = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false
let is_delimiter = function
  | '(' | ')' | '"' | ';' -> true
  | c -> is_whitespace c

let rec skip_ignorable c =
  match peek c with
  | Some ch when is_whitespace ch ->
      advance c;
      skip_ignorable c
  | Some ';' ->
      let rec to_end_of_line () =
        match peek c with
        | None -> ()
        | Some '\n' -> advance c
        | Some _ ->
            advance c;
            to_end_of_line ()
      in
      to_end_of_line ();
      skip_ignorable c
  | Some _ | None -> ()

let hex_value ~span ch =
  match ch with
  | '0' .. '9' -> Char.code ch - Char.code '0'
  | 'a' .. 'f' -> Char.code ch - Char.code 'a' + 10
  | 'A' .. 'F' -> Char.code ch - Char.code 'A' + 10
  | _ -> fail ~span (Error.Unexpected { found = Printf.sprintf "`%c`" ch; expected = "a hexadecimal digit" })

let read_string_literal c ~start =
  advance c (* the opening quote *);
  let buffer = Buffer.create 16 in
  let rec loop () =
    match peek c with
    | None -> fail ~span:(Span.make ~start ~stop:(position c)) (Error.Unterminated "string literal")
    | Some '"' ->
        advance c;
        Buffer.contents buffer
    | Some '\\' -> (
        (* The span covers the backslash and the character after it, so a bad
           escape is underlined as written rather than pointed at halfway. *)
        let escape_start = position c in
        advance c;
        match peek c with
        | None ->
            fail ~span:(Span.make ~start ~stop:(position c)) (Error.Unterminated "string literal")
        | Some escape ->
            advance c;
            let escape_span = Span.make ~start:escape_start ~stop:(position c) in
            (match escape with
            | 'n' -> Buffer.add_char buffer '\n'
            | 't' -> Buffer.add_char buffer '\t'
            | 'r' -> Buffer.add_char buffer '\r'
            | '\\' -> Buffer.add_char buffer '\\'
            | '"' -> Buffer.add_char buffer '"'
            | 'x' ->
                let digit () =
                  match peek c with
                  | None ->
                      fail ~span:(Span.make ~start ~stop:(position c))
                        (Error.Unterminated "string literal")
                  | Some ch ->
                      advance c;
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
        advance c;
        Buffer.add_char buffer ch;
        loop ()
  in
  let contents = loop () in
  { datum = Str contents; span = Span.make ~start ~stop:(position c) }

let read_token c =
  let buffer = Buffer.create 16 in
  let rec loop () =
    match peek c with
    | Some ch when not (is_delimiter ch) ->
        Buffer.add_char buffer ch;
        advance c;
        loop ()
    | Some _ | None -> Buffer.contents buffer
  in
  loop ()

let is_decimal_integer text =
  let digits = if String.length text > 0 && text.[0] = '-' then String.sub text 1 (String.length text - 1) else text in
  String.length digits > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) digits

let is_readable_atom text =
  String.length text > 0
  && (not (is_decimal_integer text))
  && text.[0] <> '\''
  && text.[0] <> '#'
  && String.for_all
       (fun c -> (not (is_delimiter c)) && Char.code c >= 0x20 && Char.code c <> 0x7f)
       text

let classify_token ~span text =
  if String.equal text "#t" then Bool true
  else if String.equal text "#f" then Bool false
  else if String.length text > 0 && text.[0] = '#' then
    fail ~span (Error.Unexpected { found = Printf.sprintf "`%s`" text; expected = "`#t` or `#f`" })
  else if is_decimal_integer text then
    match int_of_string_opt text with
    | Some n -> Int n
    | None ->
        fail ~span
          (Error.Unexpected
             { found = Printf.sprintf "`%s`" text; expected = "an integer that fits in a machine word" })
  else Atom text

let rec read_datum c =
  skip_ignorable c;
  let start = position c in
  match peek c with
  | None -> None
  | Some '(' ->
      advance c;
      let items = read_list c ~start in
      Some { datum = List items; span = Span.make ~start ~stop:(position c) }
  | Some ')' ->
      advance c;
      fail ~span:(Span.make ~start ~stop:(position c))
        (Error.Unexpected { found = "`)`"; expected = "a datum" })
  | Some '"' -> Some (read_string_literal c ~start)
  | Some '\'' ->
      advance c;
      let name = read_token c in
      let span = Span.make ~start ~stop:(position c) in
      if String.equal name "" then
        fail ~span (Error.Unexpected { found = "`'`"; expected = "a symbol name" })
      else Some { datum = Sym name; span }
  | Some ch when Char.code ch < 0x20 || Char.code ch = 0x7f ->
      (* Whitespace and comments are already gone, so any remaining control
         character is not part of a token; letting it into an atom would produce
         a name that cannot be written back out. *)
      advance c;
      fail ~span:(Span.make ~start ~stop:(position c)) (Error.Unexpected_character ch)
  | Some ch ->
      let text = read_token c in
      let span = Span.make ~start ~stop:(position c) in
      (* Only a delimiter can stop a token, so an empty token would mean the
         character cannot begin one at all. *)
      if String.equal text "" then fail ~span:(Span.point start) (Error.Unexpected_character ch)
      else Some { datum = classify_token ~span text; span }

and read_list c ~start =
  let rec loop acc =
    skip_ignorable c;
    match peek c with
    | None -> fail ~span:(Span.make ~start ~stop:(position c)) (Error.Unterminated "list")
    | Some ')' ->
        advance c;
        List.rev acc
    | Some _ -> (
        match read_datum c with
        | Some item -> loop (item :: acc)
        | None -> fail ~span:(Span.make ~start ~stop:(position c)) (Error.Unterminated "list"))
  in
  loop []

let of_string ?(file = "<string>") source =
  let c = cursor ~file source in
  let rec loop acc =
    match read_datum c with Some datum -> loop (datum :: acc) | None -> List.rev acc
  in
  loop []

let one_of_string ?(file = "<string>") source =
  match of_string ~file source with
  | [ datum ] -> datum
  | [] ->
      Error.raise_cause ~phase:Error.Lex
        ~span:(Span.point (Span.start_of_file file))
        (Error.Unexpected { found = "end of input"; expected = "a datum" })
  | _ :: extra :: _ ->
      Error.raise_cause ~phase:Error.Lex ~span:extra.span
        (Error.Unexpected { found = datum_name extra.datum; expected = "end of input" })

(* Writing *)

let rec to_string sexp =
  match sexp.datum with
  | Int n -> string_of_int n
  | Bool true -> "#t"
  | Bool false -> "#f"
  | Str s -> Constant.escape_string s
  | Sym s -> "'" ^ s
  | Atom s -> s
  | List items -> "(" ^ String.concat " " (List.map to_string items) ^ ")"

let pp formatter sexp = Format.pp_print_string formatter (to_string sexp)
