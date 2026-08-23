open Ash_core
module Names = Map.Make (String)

type scope = Ident.t Names.t

let empty_scope = Names.empty
let scope_of_list bindings = Names.of_list bindings
let scope_find scope name = Names.find_opt name scope

let fail ~span cause = Error.raise_cause ~phase:Error.Read ~span cause

let malformed ~span ~form ~expected =
  fail ~span (Error.Malformed_form { form; expected })

let unexpected ~span ~found ~expected = fail ~span (Error.Unexpected { found; expected })

(* Canonical spellings, quoted in diagnostics so a malformed form shows what it
   should have looked like. *)
let spelling = function
  | "lit" -> "(lit <number | #t | #f | string | 'symbol | unit | nil>)"
  | "var" -> "(var <name>)"
  | "named-var" -> "(named-var \"<name>\")"
  | "lam" -> "(lam (<param> ...) <body>)"
  | "app" -> "(app <function> <argument> ...)"
  | "let" -> "(let <name> <value> <body>)"
  | "letrec" -> "(letrec ((<name> (lam (<param> ...) <body>)) ...) <body>)"
  | "if" -> "(if <condition> <consequent> <alternative>)"
  | "set" -> "(set <name> <value>)"
  | "quote" -> "(quote <core>)"
  | "reifier" -> "(reifier (<exp> <env> <cont>) <body>)"
  | other -> other

let atom_name sexp =
  match sexp.Sexp.datum with
  | Sexp.Atom name -> name
  | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.List _ ->
      unexpected ~span:sexp.Sexp.span
        ~found:(Sexp.datum_name sexp.Sexp.datum)
        ~expected:"a name"

let string_literal ~form sexp =
  match sexp.Sexp.datum with
  | Sexp.Str text -> text
  | Sexp.Int _ | Sexp.Bool _ | Sexp.Sym _ | Sexp.Atom _ | Sexp.List _ ->
      malformed ~span:sexp.Sexp.span ~form ~expected:(spelling form)

let read_literal sexp =
  match sexp.Sexp.datum with
  | Sexp.Int n -> Constant.Num n
  | Sexp.Bool b -> Constant.Bool b
  | Sexp.Str s -> Constant.Str s
  | Sexp.Sym s -> Constant.Sym s
  | Sexp.Atom "unit" -> Constant.Unit
  | Sexp.Atom "nil" -> Constant.Nil
  | Sexp.Atom _ | Sexp.List _ ->
      malformed ~span:sexp.Sexp.span ~form:"lit" ~expected:(spelling "lit")

let resolve scope sexp =
  let name = atom_name sexp in
  match Names.find_opt name scope with
  | Some ident -> ident
  | None -> fail ~span:sexp.Sexp.span (Error.Unbound_name name)

(* Binder lists. Fresh identities are allocated here and nowhere else in the
   reader, so every binding site is visible in one place. *)
let read_binders scope items =
  let rec walk seen scope idents = function
    | [] -> (List.rev idents, scope)
    | item :: rest ->
        let name = atom_name item in
        if Names.mem name seen then
          fail ~span:item.Sexp.span (Error.Duplicate_binder name);
        let ident = Ident.fresh name in
        walk
          (Names.add name ident seen)
          (Names.add name ident scope)
          (ident :: idents) rest
  in
  walk Names.empty scope [] items

let binder_items ~form sexp =
  match sexp.Sexp.datum with
  | Sexp.List items -> items
  | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.Atom _ ->
      malformed ~span:sexp.Sexp.span ~form ~expected:(spelling form)

let rec read_sexp_in scope sexp =
  let span = sexp.Sexp.span in
  match sexp.Sexp.datum with
  | Sexp.List (head :: arguments) -> read_form scope span head arguments
  | Sexp.List [] -> unexpected ~span ~found:"`()`" ~expected:"a Core form"
  | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.Atom _ ->
      unexpected ~span ~found:(Sexp.datum_name sexp.Sexp.datum) ~expected:"a Core form"

and read_form scope span head arguments =
  let form = atom_name head in
  let bad () = malformed ~span ~form ~expected:(spelling form) in
  match form with
  | "lit" -> (
      match arguments with
      | [ literal ] -> Core.lit ~span (read_literal literal)
      | [] | _ :: _ :: _ -> bad ())
  | "var" -> (
      match arguments with
      | [ name ] -> Core.var ~span (resolve scope name)
      | [] | _ :: _ :: _ -> bad ())
  | "named-var" -> (
      match arguments with
      | [ name ] -> Core.named_var ~span (string_literal ~form name)
      | [] | _ :: _ :: _ -> bad ())
  | "lam" -> Core.of_lambda ~span (read_lambda_parts scope ~span arguments)
  | "app" -> (
      match arguments with
      | func :: args ->
          Core.app ~span ~func:(read_sexp_in scope func)
            ~args:(List.map (read_sexp_in scope) args)
      | [] -> bad ())
  | "let" -> (
      match arguments with
      | [ name; value; body ] ->
          (* The value is read in the enclosing scope: a [let] does not see its
             own binding, which is what distinguishes it from [letrec]. *)
          let value = read_sexp_in scope value in
          let binder = Ident.fresh (atom_name name) in
          let inner = Names.add (Ident.name binder) binder scope in
          Core.let_ ~span ~binder ~value ~body:(read_sexp_in inner body)
      | _ -> bad ())
  | "letrec" -> (
      match arguments with
      | [ bindings; body ] -> read_letrec scope ~span bindings body
      | _ -> bad ())
  | "if" -> (
      match arguments with
      | [ condition; consequent; alternative ] ->
          Core.if_ ~span
            ~condition:(read_sexp_in scope condition)
            ~consequent:(read_sexp_in scope consequent)
            ~alternative:(read_sexp_in scope alternative)
      | _ -> bad ())
  | "set" -> (
      match arguments with
      | [ name; value ] ->
          (* Assignment never binds, so the target must already be in scope. *)
          Core.set ~span ~target:(resolve scope name) ~value:(read_sexp_in scope value)
      | _ -> bad ())
  | "quote" -> (
      match arguments with
      (* Quoted code is read in the enclosing scope, so a quoted variable keeps
         the binder ID of the binding it was written under. *)
      | [ quoted ] -> Core.quote ~span (read_sexp_in scope quoted)
      | [] | _ :: _ :: _ -> bad ())
  | "reifier" -> (
      match arguments with
      | [ params; body ] -> (
          let items = binder_items ~form params in
          match read_binders scope items with
          | [ exp; env; cont ], inner ->
              Core.reifier ~span ~exp ~env ~cont ~body:(read_sexp_in inner body)
          | _, _ -> bad ())
      | _ -> bad ())
  | other -> fail ~span:head.Sexp.span (Error.Unknown_form other)

and read_lambda_parts scope ~span arguments =
  match arguments with
  | [ params; body ] ->
      let items = binder_items ~form:"lam" params in
      let idents, inner = read_binders scope items in
      Core.lambda ~params:idents ~body:(read_sexp_in inner body)
  | _ -> malformed ~span ~form:"lam" ~expected:(spelling "lam")

and read_lambda scope sexp =
  match sexp.Sexp.datum with
  | Sexp.List ({ Sexp.datum = Sexp.Atom "lam"; _ } :: arguments) ->
      read_lambda_parts scope ~span:sexp.Sexp.span arguments
  | Sexp.List _ | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.Atom _ ->
      malformed ~span:sexp.Sexp.span ~form:"lam" ~expected:(spelling "lam")

and read_letrec scope ~span bindings body =
  let items = binder_items ~form:"letrec" bindings in
  let parts =
    List.map
      (fun item ->
        match item.Sexp.datum with
        | Sexp.List [ name; lambda ] -> (name, lambda, item.Sexp.span)
        | Sexp.List _ | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.Atom _ ->
            malformed ~span:item.Sexp.span ~form:"letrec" ~expected:(spelling "letrec"))
      items
  in
  (* Every name in the group is in scope for every lambda and for the body: that
     is what makes the group mutually recursive. *)
  let idents, inner =
    read_binders scope (List.map (fun (name, _, _) -> name) parts)
  in
  let rec_bindings =
    List.map2
      (fun ident (_, lambda, binding_span) ->
        Core.rec_binding ~span:binding_span ~name:ident (read_lambda inner lambda))
      idents parts
  in
  Core.letrec ~span ~bindings:rec_bindings ~body:(read_sexp_in inner body)

let read_sexp ?(scope = empty_scope) sexp = read_sexp_in scope sexp

let read ?(scope = empty_scope) ?file source =
  read_sexp_in scope (Sexp.one_of_string ?file source)

let read_all ?(scope = empty_scope) ?file source =
  List.map (read_sexp_in scope) (Sexp.of_string ?file source)
