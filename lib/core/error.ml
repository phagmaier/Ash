type phase = Read | Lex | Parse | Desugar | Evaluate | Stage | Collapse

type cause =
  | Unbound_ident of Ident.t
  | Unbound_name of string
  | Ambiguous_name of { name : string; candidates : Ident.t list }
  | Unfilled_binding of Ident.t

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

let cause_message cause = message ~show_ids:false cause

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
