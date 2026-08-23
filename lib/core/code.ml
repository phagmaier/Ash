let mem_ident ident idents = List.exists (Ident.equal ident) idents

(* Intrinsic identity is what makes substitution small: no alpha-renaming is
   necessary when a subtree crosses a binder that merely prints the same name.
   The [blocked] bit still makes the operation total for a host-built template
   that reuses the marker identity as an actual binder. *)
let splice ~marker ~replacement template =
  let rec go ~blocked node =
    let span = Core.span node in
    match Core.shape node with
    | Core.Lit constant -> Core.lit ~span constant
    | Core.Var ident when (not blocked) && Ident.equal ident marker -> replacement
    | Core.Var ident -> Core.var ~span ident
    | Core.NamedVar name -> Core.named_var ~span name
    | Core.Lam lambda ->
        let shadows = mem_ident marker lambda.Core.params in
        Core.lam ~span ~params:lambda.Core.params
          ~body:(go ~blocked:(blocked || shadows) lambda.Core.lam_body)
    | Core.App { Core.func; args } ->
        let func = go ~blocked func in
        Core.app ~span ~func ~args:(List.map (go ~blocked) args)
    | Core.Let { Core.let_binder; let_value; let_body } ->
        let value = go ~blocked let_value in
        Core.let_ ~span ~binder:let_binder ~value
          ~body:
            (go ~blocked:(blocked || Ident.equal let_binder marker) let_body)
    | Core.LetRec { Core.rec_bindings; rec_body } ->
        let shadows =
          List.exists
            (fun binding -> Ident.equal binding.Core.rec_name marker)
            rec_bindings
        in
        let inside_blocked = blocked || shadows in
        let bindings =
          List.map
            (fun binding ->
              let lambda = binding.Core.rec_lambda in
              let parameter_shadows = mem_ident marker lambda.Core.params in
              Core.rec_binding ~span:binding.Core.rec_span
                ~name:binding.Core.rec_name
                (Core.lambda ~params:lambda.Core.params
                   ~body:
                     (go ~blocked:(inside_blocked || parameter_shadows)
                        lambda.Core.lam_body)))
            rec_bindings
        in
        Core.letrec ~span ~bindings ~body:(go ~blocked:inside_blocked rec_body)
    | Core.If { Core.condition; consequent; alternative } ->
        let condition = go ~blocked condition in
        let consequent = go ~blocked consequent in
        Core.if_ ~span ~condition ~consequent
          ~alternative:(go ~blocked alternative)
    | Core.Set { Core.set_target; set_value } ->
        Core.set ~span ~target:set_target ~value:(go ~blocked set_value)
    | Core.Quote quoted -> Core.quote ~span (go ~blocked quoted)
    | Core.Reifier { Core.exp_param; env_param; cont_param; reifier_body } ->
        let shadows =
          mem_ident marker [ exp_param; env_param; cont_param ]
        in
        Core.reifier ~span ~exp:exp_param ~env:env_param ~cont:cont_param
          ~body:(go ~blocked:(blocked || shadows) reifier_body)
  in
  go ~blocked:false template

type correspondence = {
  pattern : int Ident.Map.t;
  subject : int Ident.Map.t;
  next : int;
}

let empty_correspondence =
  { pattern = Ident.Map.empty; subject = Ident.Map.empty; next = 0 }

let bind_pair correspondence pattern subject =
  {
    pattern = Ident.Map.add pattern correspondence.next correspondence.pattern;
    subject = Ident.Map.add subject correspondence.next correspondence.subject;
    next = correspondence.next + 1;
  }

let bind_pairs correspondence patterns subjects =
  if List.compare_lengths patterns subjects <> 0 then None
  else Some (List.fold_left2 bind_pair correspondence patterns subjects)

let same_var correspondence pattern subject =
  match
    ( Ident.Map.find_opt pattern correspondence.pattern,
      Ident.Map.find_opt subject correspondence.subject )
  with
  | Some left, Some right -> Int.equal left right
  | None, None -> Ident.equal pattern subject
  | Some _, None | None, Some _ -> false

let match_template ~holes ~template subject =
  let template_free = Alpha.free_idents template in
  let valid_holes =
    List.length (List.sort_uniq Ident.compare holes) = List.length holes
    && List.for_all (fun hole -> Ident.Set.mem hole template_free) holes
  in
  let captures = ref Ident.Map.empty in
  let capture hole node =
    if Ident.Map.mem hole !captures then false
    else (
      captures := Ident.Map.add hole node !captures;
      true)
  in
  let rec nodes correspondence patterns subjects =
    List.compare_lengths patterns subjects = 0
    && List.for_all2 (node correspondence) patterns subjects
  and node correspondence pattern subject =
    match Core.shape pattern with
    | Core.Var ident when mem_ident ident holes -> capture ident subject
    | Core.Lit expected -> (
        match Core.shape subject with
        | Core.Lit actual -> Constant.equal expected actual
        | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
        | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            false)
    | Core.Var expected -> (
        match Core.shape subject with
        | Core.Var actual -> same_var correspondence expected actual
        | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
        | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            false)
    | Core.NamedVar expected -> (
        match Core.shape subject with
        | Core.NamedVar actual -> String.equal expected actual
        | Core.Lit _ | Core.Var _ | Core.Lam _ | Core.App _ | Core.Let _
        | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            false)
    | Core.Lam expected -> (
        match Core.shape subject with
        | Core.Lam actual -> lambda correspondence expected actual
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.App _ | Core.Let _
        | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            false)
    | Core.App expected -> (
        match Core.shape subject with
        | Core.App actual ->
            node correspondence expected.Core.func actual.Core.func
            && nodes correspondence expected.Core.args actual.Core.args
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.Let _
        | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            false)
    | Core.Let expected -> (
        match Core.shape subject with
        | Core.Let actual ->
            node correspondence expected.Core.let_value actual.Core.let_value
            && node
                 (bind_pair correspondence expected.Core.let_binder
                    actual.Core.let_binder)
                 expected.Core.let_body actual.Core.let_body
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
        | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            false)
    | Core.LetRec expected -> (
        match Core.shape subject with
        | Core.LetRec actual -> (
            match
              bind_pairs correspondence
                (List.map
                   (fun binding -> binding.Core.rec_name)
                   expected.Core.rec_bindings)
                (List.map
                   (fun binding -> binding.Core.rec_name)
                   actual.Core.rec_bindings)
            with
            | None -> false
            | Some inner ->
                List.for_all2
                  (fun left right ->
                    lambda inner left.Core.rec_lambda right.Core.rec_lambda)
                  expected.Core.rec_bindings actual.Core.rec_bindings
                && node inner expected.Core.rec_body actual.Core.rec_body)
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
        | Core.Let _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            false)
    | Core.If expected -> (
        match Core.shape subject with
        | Core.If actual ->
            node correspondence expected.Core.condition actual.Core.condition
            && node correspondence expected.Core.consequent actual.Core.consequent
            && node correspondence expected.Core.alternative actual.Core.alternative
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
        | Core.Let _ | Core.LetRec _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            false)
    | Core.Set expected -> (
        match Core.shape subject with
        | Core.Set actual ->
            same_var correspondence expected.Core.set_target actual.Core.set_target
            && node correspondence expected.Core.set_value actual.Core.set_value
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
        | Core.Let _ | Core.LetRec _ | Core.If _ | Core.Quote _ | Core.Reifier _ ->
            false)
    | Core.Quote expected -> (
        match Core.shape subject with
        | Core.Quote actual -> node correspondence expected actual
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
        | Core.Let _ | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Reifier _ ->
            false)
    | Core.Reifier expected -> (
        match Core.shape subject with
        | Core.Reifier actual ->
            let inner =
              bind_pair
                (bind_pair
                   (bind_pair correspondence expected.Core.exp_param
                      actual.Core.exp_param)
                   expected.Core.env_param actual.Core.env_param)
                expected.Core.cont_param actual.Core.cont_param
            in
            node inner expected.Core.reifier_body actual.Core.reifier_body
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
        | Core.Let _ | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ ->
            false)
  and lambda correspondence expected actual =
    match bind_pairs correspondence expected.Core.params actual.Core.params with
    | None -> false
    | Some inner -> node inner expected.Core.lam_body actual.Core.lam_body
  in
  if not valid_holes then None
  else if node empty_correspondence template subject then
    let captured = List.map (fun hole -> Ident.Map.find_opt hole !captures) holes in
    if List.for_all Option.is_some captured then Some (List.map Option.get captured)
    else None
  else None
