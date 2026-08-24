type phase = Read | Lex | Parse | Desugar | Evaluate | Stage | Collapse

type cause =
  | Unbound_ident of Ident.t
  | Unbound_name of string
  | Ambiguous_name of { name : string; candidates : Ident.t list }
  | Unfilled_binding of Ident.t
  | Open_code of Code.dependency list
  | Unliftable_value of { found : string; value : string; path : int list }
  | Unexpected_character of char
  | Unterminated of string
  | Unexpected of { found : string; expected : string }
  | Unknown_form of string
  | Malformed_form of { form : string; expected : string }
  | Arity_error of { callee : string option; expected : string; actual : int }
  | Unsupported of { what : string; by : string }
  | Division_by_zero
  | Continuation_reuse of { captured : Span.t; first_used : Span.t }
  | Meta_error of string
  | Immutable_binding of string
  | No_matching_clause of string
  | Duplicate_binder of string
  | Inconsistent_pattern_binders of { expected : string list; actual : string list }
  | End_of_input
  | Budget_exhausted of { what : string; limit : int; callee : string option }

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
  | Open_code dependencies ->
      let dependency item =
        Printf.sprintf "`%s` at %s" (ident item.Code.ident)
          (String.concat ", " (List.map Span.to_string item.Code.occurrences))
      in
      Printf.sprintf "code is open; unresolved dependencies: %s"
        (String.concat "; " (List.map dependency dependencies))
  | Unliftable_value { found; value; path } ->
      let origin =
        match path with
        | [] -> "the lift argument"
        | _ :: _ ->
            "the lift argument"
            ^ String.concat ""
                (List.map (fun index -> Printf.sprintf " list item %d" index) path)
      in
      Printf.sprintf "cannot lift %s from %s: %s is outside the fixed lift domain"
        value origin found
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
  | Continuation_reuse { captured; first_used } ->
      Printf.sprintf
        "this continuation is one-shot: captured at %s, it was already invoked at %s"
        (Span.to_string captured) (Span.to_string first_used)
  | Meta_error message -> Printf.sprintf "meta level raised: %s" message
  | Immutable_binding name ->
      Printf.sprintf "`%s` is bound by `let`, so it cannot be assigned; bind it with `var`"
        name
  | No_matching_clause value -> Printf.sprintf "no clause matches the value %s" value
  | Duplicate_binder name ->
      Printf.sprintf "`%s` is bound twice in the same binder list" name
  | Inconsistent_pattern_binders { expected; actual } ->
      let names items = "{" ^ String.concat ", " items ^ "}" in
      Printf.sprintf "pattern alternatives must bind the same names: expected %s, found %s"
        (names expected) (names actual)
  | End_of_input -> "no input left to read"
  | Budget_exhausted { what; limit; callee } ->
      Printf.sprintf
        "specialization exhausted its %s budget of %d%s, and every argument is already dynamic"
        what limit
        (match callee with
        | Some name -> Printf.sprintf " while specializing `" ^ name ^ "`"
        | None -> "")

let cause_message cause = message ~show_ids:false cause

let cause_equal a b =
  match (a, b) with
  | Unbound_ident x, Unbound_ident y -> Ident.equal x y
  | Unbound_name x, Unbound_name y -> String.equal x y
  | Ambiguous_name x, Ambiguous_name y ->
      String.equal x.name y.name && List.equal Ident.equal x.candidates y.candidates
  | Unfilled_binding x, Unfilled_binding y -> Ident.equal x y
  | Open_code x, Open_code y ->
      List.equal
        (fun left right ->
          Ident.equal left.Code.ident right.Code.ident
          && List.equal Span.equal left.Code.occurrences right.Code.occurrences)
        x y
  | Unliftable_value x, Unliftable_value y ->
      String.equal x.found y.found
      && String.equal x.value y.value
      && List.equal Int.equal x.path y.path
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
  | Continuation_reuse x, Continuation_reuse y ->
      Span.equal x.captured y.captured && Span.equal x.first_used y.first_used
  | Meta_error x, Meta_error y -> String.equal x y
  | Immutable_binding x, Immutable_binding y -> String.equal x y
  | No_matching_clause x, No_matching_clause y -> String.equal x y
  | Duplicate_binder x, Duplicate_binder y -> String.equal x y
  | Inconsistent_pattern_binders x, Inconsistent_pattern_binders y ->
      List.equal String.equal x.expected y.expected
      && List.equal String.equal x.actual y.actual
  | End_of_input, End_of_input -> true
  | Budget_exhausted x, Budget_exhausted y ->
      String.equal x.what y.what
      && Int.equal x.limit y.limit
      && Option.equal String.equal x.callee y.callee
  | ( ( Unbound_ident _ | Unbound_name _ | Ambiguous_name _ | Unfilled_binding _
      | Open_code _ | Unliftable_value _
      | Unexpected_character _ | Unterminated _ | Unexpected _ | Unknown_form _
      | Malformed_form _ | Arity_error _ | Unsupported _ | Division_by_zero
      | Continuation_reuse _ | Meta_error _ | Immutable_binding _
      | No_matching_clause _
      | Duplicate_binder _
      | Inconsistent_pattern_binders _ | End_of_input | Budget_exhausted _ ),
      _ ) ->
      false

let equal a b =
  a.phase = b.phase
  && Span.equal a.span b.span
  && Option.equal Int.equal a.level b.level
  && cause_equal a.cause b.cause

(* Levels are relative (spec §D9): the base program is level 0, so naming it
   would appear on every ordinary diagnostic and say nothing. A level is
   reported exactly when the error belongs to a meta level above the program. *)
let render ~show_ids error =
  let level =
    match error.level with
    | None | Some 0 -> ""
    | Some n -> Printf.sprintf " at level %d" n
  in
  Printf.sprintf "%s: %s error%s: %s" (Span.to_string error.span)
    (phase_name error.phase) level
    (message ~show_ids error.cause)

let to_string error = render ~show_ids:false error
let to_string_debug error = render ~show_ids:true error
let pp formatter error = Format.pp_print_string formatter (to_string error)
