(* Free identifiers.

   Scope differs per form, so this is written out rather than derived from
   [Core.children] and [Core.binders]: a [Let] binder scopes only the body, while
   a [LetRec] group scopes both the lambdas and the body. *)

let remove_all idents set =
  List.fold_left (fun set ident -> Ident.Set.remove ident set) set idents

let unions sets = List.fold_left Ident.Set.union Ident.Set.empty sets

let rec free_idents node =
  match Core.shape node with
  | Core.Lit _ | Core.NamedVar _ -> Ident.Set.empty
  | Core.Var ident -> Ident.Set.singleton ident
  | Core.Lam lambda -> free_lambda lambda
  | Core.App { Core.func; args } ->
      Ident.Set.union (free_idents func) (unions (List.map free_idents args))
  | Core.Let { Core.let_binder; let_value; let_body } ->
      Ident.Set.union (free_idents let_value)
        (Ident.Set.remove let_binder (free_idents let_body))
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      let names = List.map (fun binding -> binding.Core.rec_name) rec_bindings in
      let inside =
        Ident.Set.union
          (unions (List.map (fun b -> free_lambda b.Core.rec_lambda) rec_bindings))
          (free_idents rec_body)
      in
      remove_all names inside
  | Core.If { Core.condition; consequent; alternative } ->
      unions [ free_idents condition; free_idents consequent; free_idents alternative ]
  | Core.Set { Core.set_target; set_value } ->
      (* Assignment reads the binding to find its cell, so the target is a
         reference like any other. *)
      Ident.Set.add set_target (free_idents set_value)
  | Core.Quote quoted -> free_idents quoted
  | Core.Reifier { Core.exp_param; env_param; cont_param; reifier_body } ->
      remove_all [ exp_param; env_param; cont_param ] (free_idents reifier_body)

and free_lambda lambda = remove_all lambda.Core.params (free_idents lambda.Core.lam_body)

(* Alpha-equivalence.

   Both terms are walked in step under a correspondence between their bound
   identifiers: the n-th binder introduced on the left matches the n-th on the
   right. Shadowing works because a later binding simply replaces the earlier
   entry, and free identifiers fall through to plain identity. *)

type correspondence = { left : int Ident.Map.t; right : int Ident.Map.t; next : int }

let no_correspondence =
  { left = Ident.Map.empty; right = Ident.Map.empty; next = 0 }

let bind_pair correspondence a b =
  {
    left = Ident.Map.add a correspondence.next correspondence.left;
    right = Ident.Map.add b correspondence.next correspondence.right;
    next = correspondence.next + 1;
  }

let bind_pairs correspondence xs ys =
  if List.compare_lengths xs ys <> 0 then None
  else Some (List.fold_left2 bind_pair correspondence xs ys)

let same_var correspondence x y =
  match
    (Ident.Map.find_opt x correspondence.left, Ident.Map.find_opt y correspondence.right)
  with
  | Some i, Some j -> Int.equal i j
  | None, None -> Ident.equal x y
  | Some _, None | None, Some _ -> false

let rec equal_in correspondence a b =
  match (Core.shape a, Core.shape b) with
  | Core.Lit x, Core.Lit y -> Constant.equal x y
  | Core.Var x, Core.Var y -> same_var correspondence x y
  | Core.NamedVar x, Core.NamedVar y -> String.equal x y
  | Core.Lam x, Core.Lam y -> equal_lambda correspondence x y
  | Core.App x, Core.App y ->
      equal_in correspondence x.Core.func y.Core.func
      && List.compare_lengths x.Core.args y.Core.args = 0
      && List.for_all2 (equal_in correspondence) x.Core.args y.Core.args
  | Core.Let x, Core.Let y ->
      equal_in correspondence x.Core.let_value y.Core.let_value
      && equal_in
           (bind_pair correspondence x.Core.let_binder y.Core.let_binder)
           x.Core.let_body y.Core.let_body
  | Core.LetRec x, Core.LetRec y -> (
      match
        bind_pairs correspondence
          (List.map (fun b -> b.Core.rec_name) x.Core.rec_bindings)
          (List.map (fun b -> b.Core.rec_name) y.Core.rec_bindings)
      with
      | None -> false
      | Some inner ->
          List.for_all2
            (fun bx by -> equal_lambda inner bx.Core.rec_lambda by.Core.rec_lambda)
            x.Core.rec_bindings y.Core.rec_bindings
          && equal_in inner x.Core.rec_body y.Core.rec_body)
  | Core.If x, Core.If y ->
      equal_in correspondence x.Core.condition y.Core.condition
      && equal_in correspondence x.Core.consequent y.Core.consequent
      && equal_in correspondence x.Core.alternative y.Core.alternative
  | Core.Set x, Core.Set y ->
      same_var correspondence x.Core.set_target y.Core.set_target
      && equal_in correspondence x.Core.set_value y.Core.set_value
  | Core.Quote x, Core.Quote y ->
      (* Quoted variables are bound by the enclosing term, so the correspondence
         carries into the quotation unchanged. *)
      equal_in correspondence x y
  | Core.Reifier x, Core.Reifier y ->
      let inner =
        bind_pair
          (bind_pair
             (bind_pair correspondence x.Core.exp_param y.Core.exp_param)
             x.Core.env_param y.Core.env_param)
          x.Core.cont_param y.Core.cont_param
      in
      equal_in inner x.Core.reifier_body y.Core.reifier_body
  | ( ( Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ),
      _ ) ->
      false

and equal_lambda correspondence x y =
  match bind_pairs correspondence x.Core.params y.Core.params with
  | None -> false
  | Some inner -> equal_in inner x.Core.lam_body y.Core.lam_body

let equal a b = equal_in no_correspondence a b

(* Canonical renaming.

   Free identifiers are fixed first so they keep their identity; every binder is
   then renumbered on first sight. Subterms are sequenced with explicit lets so
   the traversal order is the source order rather than whatever order the host
   happens to evaluate constructor arguments in. *)

let canonicalize node =
  let state = Ident.Canon.create () in
  Ident.Set.iter (Ident.Canon.fix state) (free_idents node);
  let rename ident = Ident.Canon.canonical state ident in
  let rec go node =
    let span = Core.span node in
    match Core.shape node with
    | Core.Lit constant -> Core.lit ~span constant
    | Core.Var ident -> Core.var ~span (rename ident)
    | Core.NamedVar name -> Core.named_var ~span name
    | Core.Lam lambda -> Core.of_lambda ~span (go_lambda lambda)
    | Core.App { Core.func; args } ->
        let func = go func in
        Core.app ~span ~func ~args:(List.map go args)
    | Core.Let { Core.let_binder; let_value; let_body } ->
        let value = go let_value in
        let binder = rename let_binder in
        Core.let_ ~span ~binder ~value ~body:(go let_body)
    | Core.LetRec { Core.rec_bindings; rec_body } ->
        let names = List.map (fun b -> rename b.Core.rec_name) rec_bindings in
        let bindings =
          List.map2
            (fun name binding ->
              Core.rec_binding ~span:binding.Core.rec_span ~name
                (go_lambda binding.Core.rec_lambda))
            names rec_bindings
        in
        Core.letrec ~span ~bindings ~body:(go rec_body)
    | Core.If { Core.condition; consequent; alternative } ->
        let condition = go condition in
        let consequent = go consequent in
        Core.if_ ~span ~condition ~consequent ~alternative:(go alternative)
    | Core.Set { Core.set_target; set_value } ->
        let target = rename set_target in
        Core.set ~span ~target ~value:(go set_value)
    | Core.Quote quoted -> Core.quote ~span (go quoted)
    | Core.Reifier { Core.exp_param; env_param; cont_param; reifier_body } ->
        let exp = rename exp_param in
        let env = rename env_param in
        let cont = rename cont_param in
        Core.reifier ~span ~exp ~env ~cont ~body:(go reifier_body)
  and go_lambda lambda =
    let params = List.map rename lambda.Core.params in
    Core.lambda ~params ~body:(go lambda.Core.lam_body)
  in
  go node
