type phase = Read | Lex | Parse | Desugar | Evaluate | Stage | Collapse

type cause =
  | Unbound_ident of Ident.t
  | Unbound_name of string
  | Ambiguous_name of { name : string; candidates : Ident.t list }
  | Unfilled_binding of Ident.t
  | Unexpected_character of char
  | Unterminated of string
  | Unexpected of { found : string; expected : string }
  | Unknown_form of string
  | Malformed_form of { form : string; expected : string }
  | Arity_error of { callee : string option; expected : string; actual : int }
  | Unsupported of { what : string; by : string }
  | Division_by_zero
  | Duplicate_binder of string

type t = { phase : phase; span : Span.t; level : int option; cause : cause }

exception Ash_error of t

let make ~phase ~span ?level cause = { phase; span; level; cause }
let fail error = raise (Ash_error error)
let raise_cause ~phase ~span ?level cause = fail (make ~phase ~span ?level cause)

let phase_name = function
  | Read -> "read"
  | Lex -> "lex"
  | Parse -> "parse"
  | Desugar -> "desugar"
  | Evaluate -> "evaluate"
  | Stage -> "stage"
  | Collapse -> "collapse"

(* Identifiers are rendered by printed name: their IDs are an excluded
   observation, and a message carrying one would make golden diagnostics depend
   on allocation order. *)
let message ~show_ids cause =
  let ident = if show_ids then Ident.to_string else Ident.name in
  match cause with
  | Unbound_ident id -> Printf.sprintf "unbound identifier `%s`" (ident id)
  | Unbound_name name -> Printf.sprintf "no binding named `%s` in this environment" name
  | Ambiguous_name { name; candidates } ->
      if show_ids then
        Printf.sprintf "the name `%s` is bound by %s in one frame, so a name lookup cannot choose"
          name
          (String.concat ", " (List.map Ident.to_string candidates))
      else
        Printf.sprintf
          "the name `%s` is bound %d times in one frame, so a name lookup cannot choose"
          name (List.length candidates)
  | Unfilled_binding id ->
      Printf.sprintf "`%s` is used before its recursive binding is filled" (ident id)
  | Unexpected_character c -> Printf.sprintf "unexpected character `%c`" c
  | Unterminated what -> Printf.sprintf "unterminated %s" what
  | Unexpected { found; expected } ->
      Printf.sprintf "expected %s, found %s" expected found
  | Unknown_form form -> Printf.sprintf "`%s` is not a Core form" form
  | Malformed_form { form; expected } ->
      Printf.sprintf "malformed `%s`: expected %s" form expected
  | Arity_error { callee; expected; actual } ->
      Printf.sprintf "%s expects %s argument(s), given %d"
        (match callee with None -> "this function" | Some name -> "`" ^ name ^ "`")
        expected actual
  | Unsupported { what; by } -> Printf.sprintf "`%s` is not supported by %s" what by
  | Division_by_zero -> "division by zero"
  | Duplicate_binder name ->
      Printf.sprintf "`%s` is bound twice in the same binder list" name

let cause_message cause = message ~show_ids:false cause

let cause_equal a b =
  match (a, b) with
  | Unbound_ident x, Unbound_ident y -> Ident.equal x y
  | Unbound_name x, Unbound_name y -> String.equal x y
  | Ambiguous_name x, Ambiguous_name y ->
      String.equal x.name y.name && List.equal Ident.equal x.candidates y.candidates
  | Unfilled_binding x, Unfilled_binding y -> Ident.equal x y
  | Unexpected_character x, Unexpected_character y -> Char.equal x y
  | Unterminated x, Unterminated y -> String.equal x y
  | Unexpected x, Unexpected y ->
      String.equal x.found y.found && String.equal x.expected y.expected
  | Unknown_form x, Unknown_form y -> String.equal x y
  | Malformed_form x, Malformed_form y ->
      String.equal x.form y.form && String.equal x.expected y.expected
  | Arity_error x, Arity_error y ->
      Option.equal String.equal x.callee y.callee
      && String.equal x.expected y.expected
      && Int.equal x.actual y.actual
  | Unsupported x, Unsupported y ->
      String.equal x.what y.what && String.equal x.by y.by
  | Division_by_zero, Division_by_zero -> true
  | Duplicate_binder x, Duplicate_binder y -> String.equal x y
  | ( ( Unbound_ident _ | Unbound_name _ | Ambiguous_name _ | Unfilled_binding _
      | Unexpected_character _ | Unterminated _ | Unexpected _ | Unknown_form _
      | Malformed_form _ | Arity_error _ | Unsupported _ | Division_by_zero
      | Duplicate_binder _ ),
      _ ) ->
      false

let equal a b =
  a.phase = b.phase
  && Span.equal a.span b.span
  && Option.equal Int.equal a.level b.level
  && cause_equal a.cause b.cause

let render ~show_ids error =
  let level =
    match error.level with None -> "" | Some n -> Printf.sprintf " at level %d" n
  in
  Printf.sprintf "%s: %s error%s: %s" (Span.to_string error.span)
    (phase_name error.phase) level
    (message ~show_ids error.cause)

let to_string error = render ~show_ids:false error
let to_string_debug error = render ~show_ids:true error
let pp formatter error = Format.pp_print_string formatter (to_string error)
