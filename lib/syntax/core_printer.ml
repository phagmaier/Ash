open Ash_core
module Names = Set.Make (String)

(* The naming in force at a point in the traversal: what each visible identifier
   prints as, and which names are taken. It is threaded rather than mutated, so
   leaving a scope restores the enclosing naming and sibling scopes are free to
   reuse the same names. *)
type naming = { printed : string Ident.Map.t; used : Names.t }

let fallback_base = "v"

let free_naming node =
  Ident.Set.fold
    (fun ident naming ->
      let name = Ident.name ident in
      if not (Sexp.is_readable_atom name) then
        invalid_arg
          (Printf.sprintf
             "Core_printer: the free identifier %s has no readable printed name"
             (Ident.to_string ident));
      if Names.mem name naming.used then
        invalid_arg
          (Printf.sprintf
             "Core_printer: two free identifiers both print as `%s`, so the term has no \
              faithful written form"
             name);
      { printed = Ident.Map.add ident name naming.printed; used = Names.add name naming.used })
    (Alpha.free_idents node)
    { printed = Ident.Map.empty; used = Names.empty }

let bind_name naming ident =
  let base =
    if Sexp.is_readable_atom (Ident.name ident) then Ident.name ident else fallback_base
  in
  let rec choose attempt =
    let candidate = if attempt = 0 then base else base ^ string_of_int attempt in
    if Names.mem candidate naming.used then choose (attempt + 1) else candidate
  in
  let name = choose 0 in
  ( name,
    { printed = Ident.Map.add ident name naming.printed; used = Names.add name naming.used }
  )

let bind_names naming idents =
  let names, naming =
    List.fold_left
      (fun (names, naming) ident ->
        let name, naming = bind_name naming ident in
        (name :: names, naming))
      ([], naming) idents
  in
  (List.rev names, naming)

let printed_name naming ident =
  match Ident.Map.find_opt ident naming.printed with
  | Some name -> name
  | None ->
      (* Every identifier is either bound by an enclosing form or free, and the
         free ones were seeded before the traversal began. *)
      invalid_arg
        (Printf.sprintf "Core_printer: %s is neither bound nor free in the term"
           (Ident.to_string ident))

let constant_datum = function
  | Constant.Num n -> Sexp.Int n
  | Constant.Bool b -> Sexp.Bool b
  | Constant.Str s -> Sexp.Str s
  | Constant.Sym s -> Sexp.Sym s
  | Constant.Unit -> Sexp.Atom "unit"
  | Constant.Nil -> Sexp.Atom "nil"

let node span datum = { Sexp.datum; span }
let atom span text = node span (Sexp.Atom text)

let rec to_sexp_in naming core =
  let span = Core.span core in
  let form items = node span (Sexp.List items) in
  match Core.shape core with
  | Core.Lit constant -> form [ atom span "lit"; node span (constant_datum constant) ]
  | Core.Var ident -> form [ atom span "var"; atom span (printed_name naming ident) ]
  | Core.NamedVar name -> form [ atom span "named-var"; node span (Sexp.Str name) ]
  | Core.Lam lambda -> lambda_sexp naming ~span lambda
  | Core.App { Core.func; args } ->
      form ((atom span "app" :: to_sexp_in naming func :: List.map (to_sexp_in naming) args))
  | Core.Let { Core.let_binder; let_value; let_body } ->
      (* The value is outside the binder's scope, so it prints under the
         enclosing naming. *)
      let value = to_sexp_in naming let_value in
      let name, inner = bind_name naming let_binder in
      form [ atom span "let"; atom span name; value; to_sexp_in inner let_body ]
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      let names, inner =
        bind_names naming (List.map (fun b -> b.Core.rec_name) rec_bindings)
      in
      let bindings =
        List.map2
          (fun name binding ->
            let binding_span = binding.Core.rec_span in
            node binding_span
              (Sexp.List
                 [
                   atom binding_span name;
                   lambda_sexp inner ~span:binding_span binding.Core.rec_lambda;
                 ]))
          names rec_bindings
      in
      form
        [
          atom span "letrec"; node span (Sexp.List bindings); to_sexp_in inner rec_body;
        ]
  | Core.If { Core.condition; consequent; alternative } ->
      form
        [
          atom span "if";
          to_sexp_in naming condition;
          to_sexp_in naming consequent;
          to_sexp_in naming alternative;
        ]
  | Core.Set { Core.set_target; set_value } ->
      form
        [
          atom span "set";
          atom span (printed_name naming set_target);
          to_sexp_in naming set_value;
        ]
  | Core.Quote quoted ->
      (* Quoted variables are bound by the enclosing term, so the naming carries
         into the quotation unchanged. *)
      form [ atom span "quote"; to_sexp_in naming quoted ]
  | Core.Reifier { Core.exp_param; env_param; cont_param; reifier_body } ->
      let names, inner = bind_names naming [ exp_param; env_param; cont_param ] in
      form
        [
          atom span "reifier";
          node span (Sexp.List (List.map (atom span) names));
          to_sexp_in inner reifier_body;
        ]

and lambda_sexp naming ~span lambda =
  let names, inner = bind_names naming lambda.Core.params in
  node span
    (Sexp.List
       [
         atom span "lam";
         node span (Sexp.List (List.map (atom span) names));
         to_sexp_in inner lambda.Core.lam_body;
       ])

let to_sexp core = to_sexp_in (free_naming core) core
let to_string core = Sexp.to_string (to_sexp core)

let free_scope core =
  Core_reader.scope_of_list
    (List.map (fun ident -> (Ident.name ident, ident))
       (Ident.Set.elements (Alpha.free_idents core)))
