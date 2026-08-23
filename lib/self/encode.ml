open Ash_core

let sym text = Value.Sym text
let ident identity =
  Value.List [ Value.Str (Ident.name identity); Value.Num (Ident.id identity) ]
let idents identities = Value.List (List.map ident identities)

let rec term node =
  match Core.shape node with
  | Core.Lit constant -> Value.List [ sym "lit"; Value.of_constant constant ]
  | Core.Var identity -> Value.List [ sym "var"; ident identity ]
  | Core.NamedVar name -> Value.List [ sym "named_var"; Value.Str name ]
  | Core.Lam lambda -> lam lambda
  | Core.App { Core.func; args } ->
      Value.List [ sym "app"; term func; Value.List (List.map term args) ]
  | Core.Let { Core.let_binder; let_value; let_body } ->
      Value.List [ sym "let"; ident let_binder; term let_value; term let_body ]
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      let binding b =
        Value.List [ ident b.Core.rec_name; lam b.Core.rec_lambda ]
      in
      Value.List
        [ sym "letrec"; Value.List (List.map binding rec_bindings); term rec_body ]
  | Core.If { Core.condition; consequent; alternative } ->
      Value.List [ sym "if"; term condition; term consequent; term alternative ]
  | Core.Set { Core.set_target; set_value } ->
      Value.List [ sym "set"; ident set_target; term set_value ]
  (* The quoted term is data, and here it is data twice over: the encoding of a
     quotation is the encoding of what it quotes. Reading one back out is Phase
     3's problem, when [Code] exists at this level. *)
  | Core.Quote quoted -> Value.List [ sym "quote"; term quoted ]
  | Core.Reifier { Core.exp_param; env_param; cont_param; reifier_body } ->
      Value.List
        [
          sym "reifier";
          idents [ exp_param; env_param; cont_param ];
          term reifier_body;
        ]

and lam lambda =
  Value.List [ sym "lam"; idents lambda.Core.params; term lambda.Core.lam_body ]

let globals bindings =
  Value.List
    (List.map
       (fun (identity, value) ->
         match value with
         | Value.Primitive primitive ->
             Value.List
               [ ident identity; Value.Str primitive.Value.prim_name; value ]
         | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
         | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
         | Value.Environment _ | Value.Cell _ | Value.Code _ ->
             invalid_arg
               (Printf.sprintf "Encode.globals: `%s` is bound to %s, not a primitive"
                  (Ident.name identity) (Value.type_phrase value)))
       bindings)

let rec reveal value =
  match value with
  | Value.Closure _ -> sym "clo"
  | Value.Reifier _ -> sym "reif"
  | Value.Continuation _ -> sym "cont"
  | Value.Primitive _ -> sym "prim"
  | Value.List items -> Value.List (List.map reveal items)
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.Environment _ | Value.Cell _ | Value.Code _ ->
      value
