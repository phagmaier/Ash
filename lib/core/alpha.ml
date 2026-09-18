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
   entry, and free identifiers fall through to plain identity.

   A [NamedVar] is compared by more than its string. It resolves by printed
   name against the lexical environment at run time, so it observes the
   innermost in-scope binder printing its name: [let x = 1 in NamedVar "x"]
   answers 1 while [let y = 1 in NamedVar "x"] fails unbound, and no renaming
   of binders makes those the same term. The scopes carried alongside the
   correspondence exist for exactly this check — with no [NamedVar] in either
   term they are never consulted. *)

type correspondence = { left : int Ident.Map.t; right : int Ident.Map.t; next : int }

(* Binders in scope on each side, innermost scope first, each scope in binding
   order. Scopes are pushed everywhere the correspondence binds, so the two
   stay in step by construction. *)
type scopes = { scope_left : Ident.t list list; scope_right : Ident.t list list }

let no_scopes = { scope_left = []; scope_right = [] }

let push_scope scopes xs ys =
  { scope_left = xs :: scopes.scope_left; scope_right = ys :: scopes.scope_right }

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

(* The binders a reflective lookup for [name] could observe, innermost first.
   Length matters as well as identity: two same-name binders in one scope make
   the lookup ambiguous, which is a different behavior from resolving. *)
let observable scope name =
  List.filter
    (fun ident -> String.equal (Ident.name ident) name)
    (List.concat scope)

let same_observation scopes correspondence x y =
  String.equal x y
  &&
  let left = observable scopes.scope_left x
  and right = observable scopes.scope_right y in
  List.compare_lengths left right = 0
  && List.for_all2 (same_var correspondence) left right

let rec equal_in scopes correspondence a b =
  match (Core.shape a, Core.shape b) with
  | Core.Lit x, Core.Lit y -> Constant.equal x y
  | Core.Var x, Core.Var y -> same_var correspondence x y
  | Core.NamedVar x, Core.NamedVar y -> same_observation scopes correspondence x y
  | Core.Lam x, Core.Lam y -> equal_lambda scopes correspondence x y
  | Core.App x, Core.App y ->
      equal_in scopes correspondence x.Core.func y.Core.func
      && List.compare_lengths x.Core.args y.Core.args = 0
      && List.for_all2 (equal_in scopes correspondence) x.Core.args y.Core.args
  | Core.Let x, Core.Let y ->
      equal_in scopes correspondence x.Core.let_value y.Core.let_value
      && equal_in
            (push_scope scopes [ x.Core.let_binder ] [ y.Core.let_binder ])
            (bind_pair correspondence x.Core.let_binder y.Core.let_binder)
            x.Core.let_body y.Core.let_body
  | Core.LetRec x, Core.LetRec y -> (
      let xs = List.map (fun b -> b.Core.rec_name) x.Core.rec_bindings
      and ys = List.map (fun b -> b.Core.rec_name) y.Core.rec_bindings in
      match bind_pairs correspondence xs ys with
      | None -> false
      | Some inner ->
          let scopes = push_scope scopes xs ys in
          List.for_all2
            (fun bx by ->
              equal_lambda scopes inner bx.Core.rec_lambda by.Core.rec_lambda)
            x.Core.rec_bindings y.Core.rec_bindings
          && equal_in scopes inner x.Core.rec_body y.Core.rec_body)
  | Core.If x, Core.If y ->
      equal_in scopes correspondence x.Core.condition y.Core.condition
      && equal_in scopes correspondence x.Core.consequent y.Core.consequent
      && equal_in scopes correspondence x.Core.alternative y.Core.alternative
  | Core.Set x, Core.Set y ->
      same_var correspondence x.Core.set_target y.Core.set_target
      && equal_in scopes correspondence x.Core.set_value y.Core.set_value
  | Core.Quote x, Core.Quote y ->
      (* Quoted variables are bound by the enclosing term, so the correspondence
         — and the scopes a reflective lookup observes — carry into the
         quotation unchanged. *)
      equal_in scopes correspondence x y
  | Core.Reifier x, Core.Reifier y ->
      let xs = [ x.Core.exp_param; x.Core.env_param; x.Core.cont_param ]
      and ys = [ y.Core.exp_param; y.Core.env_param; y.Core.cont_param ] in
      let inner =
        bind_pair
          (bind_pair
             (bind_pair correspondence x.Core.exp_param y.Core.exp_param)
             x.Core.env_param y.Core.env_param)
          x.Core.cont_param y.Core.cont_param
      in
      equal_in (push_scope scopes xs ys) inner x.Core.reifier_body y.Core.reifier_body
  | ( ( Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ),
      _ ) ->
      false

and equal_lambda scopes correspondence x y =
  match bind_pairs correspondence x.Core.params y.Core.params with
  | None -> false
  | Some inner ->
      equal_in (push_scope scopes x.Core.params y.Core.params) inner x.Core.lam_body
        y.Core.lam_body

let equal a b = equal_in no_scopes no_correspondence a b

(* Canonical renaming.

   Free identifiers are fixed first so they keep their identity; every binder is
   then renumbered on first sight. Subterms are sequenced with explicit lets so
   the traversal order is the source order rather than whatever order the host
   happens to evaluate constructor arguments in.

   One exception: a binder a same-name [NamedVar] observes in its scope keeps
   its identity. Renaming it while leaving the lookup string behind changes
   what the term reads — [let x = 1 in NamedVar "x"] answers 1, but with the
   binder renumbered to [v0] the lookup fails unbound — so canonicalization
   must not do it. The price is allocation-sensitivity for such terms: two runs
   allocate different identities, and fixed identities compare by identity, so
   canonical forms of behaviorally identical [NamedVar]-observing terms are not
   structurally equal. Compare those with {!equal}, which decides the same
   observation exactly. Nothing in the measurement compares such terms
   structurally: a program that can observe a binder by name never claims
   depth-invariance. *)

(* The binders a same-name [NamedVar] observes in its scope, innermost match
   only: an outer same-name binder is shadowed, and renaming it cannot change
   what the lookup finds. Quoted and reified bodies count as observing: quoted
   code can be spliced back under a same-name binder, and a reifier body runs
   with its lexical environment. *)
let observed_binders node =
  let pinned = ref Ident.Set.empty in
  let rec go scope node =
    match Core.shape node with
    | Core.NamedVar name -> (
        match
          List.find_opt
            (fun ident -> String.equal (Ident.name ident) name)
            (List.concat scope)
        with
        | Some binder -> pinned := Ident.Set.add binder !pinned
        | None -> ())
    | Core.Lit _ | Core.Var _ -> ()
    | Core.Lam lambda -> go (lambda.Core.params :: scope) lambda.Core.lam_body
    | Core.App { Core.func; args } ->
        go scope func;
        List.iter (go scope) args
    | Core.Let { Core.let_binder; let_value; let_body } ->
        go scope let_value;
        go ([ let_binder ] :: scope) let_body
    | Core.LetRec { Core.rec_bindings; rec_body } ->
        let names = List.map (fun binding -> binding.Core.rec_name) rec_bindings in
        List.iter
          (fun binding -> go (names :: scope) binding.Core.rec_lambda.Core.lam_body)
          rec_bindings;
        go (names :: scope) rec_body
    | Core.If { Core.condition; consequent; alternative } ->
        go scope condition;
        go scope consequent;
        go scope alternative
    | Core.Set { Core.set_value; _ } -> go scope set_value
    | Core.Quote quoted -> go scope quoted
    | Core.Reifier { Core.exp_param; Core.env_param; Core.cont_param; reifier_body } ->
        go ([ exp_param; env_param; cont_param ] :: scope) reifier_body
  in
  go [] node;
  !pinned

let canonicalize node =
  let state = Ident.Canon.create () in
  let free = free_idents node in
  Ident.Set.iter (Ident.Canon.fix state) free;
  (* Observed binders keep their identity so the lookup still finds them. Free
     identifiers are already fixed, and fixing twice raises, so they are
     excluded — which is also correct, since a fixed identity is exactly what
     preserves the observation. *)
  Ident.Set.iter
    (fun ident ->
      if not (Ident.Set.mem ident free) then Ident.Canon.fix state ident)
    (observed_binders node);
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
