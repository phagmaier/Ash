type t = { shape : shape; span : Span.t }

and shape =
  | Lit of Constant.t
  | Var of Ident.t
  | NamedVar of string
  | Lam of lambda
  | App of application
  | Let of let_binding
  | LetRec of letrec
  | If of conditional
  | Set of assignment
  | Quote of t
  | Reifier of reifier

and lambda = { params : Ident.t list; lam_body : t }
and application = { func : t; args : t list }
and let_binding = { let_binder : Ident.t; let_value : t; let_body : t }
and letrec = { rec_bindings : rec_binding list; rec_body : t }
and rec_binding = { rec_name : Ident.t; rec_lambda : lambda; rec_span : Span.t }
and conditional = { condition : t; consequent : t; alternative : t }
and assignment = { set_target : Ident.t; set_value : t }

and reifier = {
  exp_param : Ident.t;
  env_param : Ident.t;
  cont_param : Ident.t;
  reifier_body : t;
}

(* Contracts. A violation here is a host bug: the reader (task 0.5) reports
   malformed input as a located Ash diagnostic long before it reaches these. *)

let check_distinct ~context idents =
  let rec walk seen = function
    | [] -> ()
    | ident :: rest ->
        if Ident.Set.mem ident seen then
          invalid_arg
            (Printf.sprintf "Core.%s: duplicate binder %s" context
               (Ident.to_string ident));
        walk (Ident.Set.add ident seen) rest
  in
  walk Ident.Set.empty idents

let make span shape = { shape; span }
let lit ~span constant = make span (Lit constant)
let var ~span ident = make span (Var ident)
let named_var ~span name = make span (NamedVar name)

let lambda ~params ~body =
  check_distinct ~context:"lambda" params;
  { params; lam_body = body }

let lam ~span ~params ~body = make span (Lam (lambda ~params ~body))
let of_lambda ~span lambda = make span (Lam lambda)
let app ~span ~func ~args = make span (App { func; args })

let let_ ~span ~binder ~value ~body =
  make span (Let { let_binder = binder; let_value = value; let_body = body })

let rec_binding ~span ~name lambda =
  { rec_name = name; rec_lambda = lambda; rec_span = span }

let letrec ~span ~bindings ~body =
  check_distinct ~context:"letrec" (List.map (fun b -> b.rec_name) bindings);
  make span (LetRec { rec_bindings = bindings; rec_body = body })

let if_ ~span ~condition ~consequent ~alternative =
  make span (If { condition; consequent; alternative })

let set ~span ~target ~value = make span (Set { set_target = target; set_value = value })
let quote ~span quoted = make span (Quote quoted)

let reifier_def ~exp ~env ~cont ~body =
  check_distinct ~context:"reifier" [ exp; env; cont ];
  { exp_param = exp; env_param = env; cont_param = cont; reifier_body = body }

let reifier ~span ~exp ~env ~cont ~body =
  make span (Reifier (reifier_def ~exp ~env ~cont ~body))

(* Accessors and provenance *)

let span node = node.span
let shape node = node.shape
let with_span span node = { node with span }

let mark_generated ~by node =
  { node with span = Span.generated ~by ~from:node.span }

(* Structure. Every match below enumerates all eleven forms; a new form must
   break these, not fall through one of them. *)

let kind_name_of_shape = function
  | Lit _ -> "lit"
  | Var _ -> "var"
  | NamedVar _ -> "named-var"
  | Lam _ -> "lam"
  | App _ -> "app"
  | Let _ -> "let"
  | LetRec _ -> "letrec"
  | If _ -> "if"
  | Set _ -> "set"
  | Quote _ -> "quote"
  | Reifier _ -> "reifier"

let kind_name node = kind_name_of_shape node.shape

let children node =
  match node.shape with
  | Lit _ | Var _ | NamedVar _ -> []
  | Lam { params = _; lam_body } -> [ lam_body ]
  | App { func; args } -> func :: args
  | Let { let_binder = _; let_value; let_body } -> [ let_value; let_body ]
  | LetRec { rec_bindings; rec_body } ->
      List.map (fun binding -> binding.rec_lambda.lam_body) rec_bindings
      @ [ rec_body ]
  | If { condition; consequent; alternative } -> [ condition; consequent; alternative ]
  | Set { set_target = _; set_value } -> [ set_value ]
  | Quote quoted -> [ quoted ]
  | Reifier { exp_param = _; env_param = _; cont_param = _; reifier_body } ->
      [ reifier_body ]

let binders node =
  match node.shape with
  | Lit _ | Var _ | NamedVar _ | App _ | If _ | Set _ | Quote _ -> []
  | Lam { params; lam_body = _ } -> params
  | Let { let_binder; let_value = _; let_body = _ } -> [ let_binder ]
  | LetRec { rec_bindings; rec_body = _ } ->
      List.map (fun binding -> binding.rec_name) rec_bindings
  | Reifier { exp_param; env_param; cont_param; reifier_body = _ } ->
      [ exp_param; env_param; cont_param ]

let rec node_count node =
  List.fold_left (fun total child -> total + node_count child) 1 (children node)
