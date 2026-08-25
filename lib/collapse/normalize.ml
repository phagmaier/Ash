(** The residual normalizer (spec §8's Phase 6, to-do task 6.3).

    Two residuals of the same program are never structurally equal: every
    specialization run allocates fresh binder identities, and the emitter wraps
    dynamic operations in chains of administrative lets. A depth-invariance
    claim compared on raw terms would therefore fail for the wrong reason, and a
    claim compared on raw {e identical} runs would hold for none — either way
    the comparison says nothing. What the claim needs is one canonical shape,
    and that is this module.

    [normalize] applies three rewrites, each semantics-preserving by
    construction:

    - {b Alpha-canonicalization} ({!Ash_core.Alpha.canonicalize}): binders are
      renumbered by first occurrence, so two terms that differ only by the
      identities some run allocated become structurally equal.
    - {b Administrative-let flattening}: [let x = (let y = ey in ex) in b]
      becomes [let y = ey in let x = ex in b], however deep the nesting. This is
      pure rearrangement — [ey] was already evaluated before [ex], and neither
      mentions [x] — so no binding moves across a lambda, an [If] branch, or a
      [LetRec] group, which keeps the placement rule of ADR 0031 intact.
    - {b Trivial-binding elimination}: [let x = v in b] with [v] a literal or an
      unassigned variable substitutes [v] for [x]; with [b] never mentioning
      [x] at all, the binding simply goes away. Nothing else is ever
      substituted, so no code is duplicated, no work is reordered, and an
      unused-but-effectful binding is kept exactly where it was. A mention that
      cannot follow the substitution — a [Set] target, which reads the binding
      to find its cell, or a variable inside a [Quote] or [Reifier] body —
      keeps the whole binding rather than being rewritten, and a variable
      {e value} that anything assigns is not substituted at all (see
      {!assigned_idents}).

    Hygiene makes the substitution capture-free by construction (AGENTS
    invariant 1): identifiers are unique, so no binder inside [b] can shadow the
    ones being substituted, and no reference outside can reach in.

    The preservation claim is about terms that can actually run: every free
    identity of [t] is bound in the environment [t] runs against, which every
    residual satisfies (a staged answer is closed over its level's globals, and
    {!Ash_stage.Code.unresolved_dependencies} is what rejects one that is not).
    Reading a bound variable cannot fail, which is why moving such a read to
    the use site — or dropping it with an unused binding — is invisible. On a
    term with a genuinely unbound variable in value position the rewrite would
    move or remove the failure that read raises, so do not normalize one.

    What is deliberately {e not} transformed: a {!Core.Quote} body is data the
    program computes with, and a {!Core.Reifier} body is another level's code;
    rewriting either would change what the program means rather than how it is
    spelled. Alpha-canonicalization still descends into both, because a quoted
    variable referring to an enclosing binder has to follow that binder's
    renaming — that is what alpha-equivalence means here.

    Idempotent by construction: the flattening pass leaves a term in which no
    let has a trivial or let-shaped value, and renaming such a term neither
    reintroduces one nor changes structure. *)

open Ash_core

(* Every identity something assigns, anywhere in the term: {!Core.assigned_idents}.

   Substituting a variable for a binder trades one read at the binding site for
   a read at each use, and the two disagree exactly when a write lands in
   between: [let x = y in (set y 6); x] captured [y]'s old value, while the
   substituted body would see the new one. So a variable {e value} is
   substitutable only when nothing writes to it.

   The definition lives in {!Core} rather than here because the specializer's
   abstract store reads the same set to decide which bindings it may hold
   (ADR 0036). Two write sets that could drift apart would let this module
   rewrite a residual the store built. Literals need no such guard — nothing can
   assign one. *)
let assigned_idents = Core.assigned_idents

(* A value that may stand in for its binder: copying it to the use sites costs
   nothing and can be read as often as the body likes. *)
let substitutable ~assigned value =
  match Core.shape value with
  | Core.Lit _ -> true
  | Core.Var ident -> not (Ident.Set.mem ident assigned)
  | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _ | Core.LetRec _
  | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
      false

(* Where a binder is referenced, classified. Substituting may only remove a
   binding every one of whose references is an ordinary variable occurrence
   outside data. A [Set] target is a reference — assignment reads the binding to
   find its cell — and so is anything under a [Quote] or [Reifier] body: those
   are values and another level's code, and eliminating the binding would leave
   their mentions dangling rather than rewrite them. Hygiene decides the rest:
   identities are allocated once, so no binder below can rebind [for_] and a
   same-printed name is simply a different variable. *)
type occurrence = Blocked | Used | Unused

let join a b =
  match (a, b) with
  | Blocked, _ | _, Blocked -> Blocked
  | Used, _ | _, Used -> Used
  | Unused, Unused -> Unused

let rec occurrence_of ~for_ node =
  match Core.shape node with
  | Core.Var ident when Ident.equal ident for_ -> Used
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ -> Unused
  | Core.Set { Core.set_target; set_value } ->
      if Ident.equal set_target for_ then Blocked else occurrence_of ~for_ set_value
  | Core.Lam lambda -> occurrence_of ~for_ lambda.Core.lam_body
  | Core.App { Core.func; args } ->
      List.fold_left
        (fun acc arg -> join acc (occurrence_of ~for_ arg))
        (occurrence_of ~for_ func) args
  | Core.Let { Core.let_value; let_body; _ } ->
      join (occurrence_of ~for_ let_value) (occurrence_of ~for_ let_body)
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      List.fold_left
        (fun acc binding ->
          join acc (occurrence_of ~for_ binding.Core.rec_lambda.Core.lam_body))
        (occurrence_of ~for_ rec_body)
        rec_bindings
  | Core.If { Core.condition; consequent; alternative } ->
      List.fold_left
        (fun acc branch -> join acc (occurrence_of ~for_ branch))
        (occurrence_of ~for_ condition)
        [ consequent; alternative ]
  | Core.Quote quoted | Core.Reifier { Core.reifier_body = quoted; _ } ->
      (* A mention inside data cannot be rewritten, so it blocks elimination
         whatever kind of node it is. *)
      if occurrence_of ~for_ quoted = Unused then Unused else Blocked

(* Bottom-up rewrite: normalize every child, then decide what this [Let] binds.
   Everything but [Let] rebuilds itself with its own span; [Quote] and
   [Reifier] bodies keep their structure entirely. [assigned] is the whole
   term's write set, computed once and carried down unchanged. *)
let rec rewrite ~assigned node =
  let span = Core.span node in
  let rewrite node = rewrite ~assigned node in
  match Core.shape node with
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ -> node
  | Core.Lam lambda ->
      Core.of_lambda ~span { lambda with Core.lam_body = rewrite lambda.Core.lam_body }
  | Core.App { Core.func; args } ->
      Core.app ~span ~func:(rewrite func) ~args:(List.map rewrite args)
  | Core.Let { Core.let_binder; let_value; let_body } ->
      chain ~assigned let_binder (rewrite let_value) span (rewrite let_body)
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      let bindings =
        List.map
          (fun binding ->
            Core.rec_binding ~span:binding.Core.rec_span ~name:binding.Core.rec_name
              { binding.Core.rec_lambda with
                Core.lam_body = rewrite binding.Core.rec_lambda.Core.lam_body })
          rec_bindings
      in
      Core.letrec ~span ~bindings ~body:(rewrite rec_body)
  | Core.If { Core.condition; consequent; alternative } ->
      Core.if_ ~span ~condition:(rewrite condition)
        ~consequent:(rewrite consequent)
        ~alternative:(rewrite alternative)
  | Core.Set { Core.set_target; set_value } ->
      Core.set ~span ~target:set_target ~value:(rewrite set_value)
  | Core.Quote _ -> node
  | Core.Reifier _ -> node

(* The value side of a processed [Let], against the processed body. Substitutable
   values are substituted away unless something blocks them; a let-shaped value
   contributes its own leading bindings first, however many of them there are.
   Rebuilt nodes carry the spans of the nodes they came from, so provenance
   survives normalization. *)
and chain ~assigned binder value span body =
  match Core.shape value with
  | Core.Let { Core.let_binder = inner_binder; let_value = inner_value; let_body }
    ->
      (* Flatten one level: [let b = (let b2 = v2 in w) in body] becomes
         [let b2 = v2 in let b = w in body]. The binding of [b] still has to be
         processed — [w] may itself make it trivial or further nested — and the
         recursion cannot loop, because each step consumes one leading let from
         [value]'s spine, which {!rewrite} left finite. The binding that comes
         out in front is the inner [Let] node, so it carries that node's span. *)
      let rest = chain ~assigned binder let_body span body in
      chain ~assigned inner_binder inner_value (Core.span value) rest
  | _ when substitutable ~assigned value -> (
      match occurrence_of ~for_:binder body with
      | Used -> substitute ~replacement:value ~for_:binder body
      | Unused -> body
      | Blocked -> Core.let_ ~span ~binder ~value ~body)
  | _ -> Core.let_ ~span ~binder ~value ~body

(* Substitution of a trivial value for one binder, used only where {!chain}
   proved the value substitutable — a literal, or a variable nothing writes to. Hygiene does the capture-avoiding:
   identities are allocated once, so no binder below can rebind [for_] and no
   quoted or reified body may be rewritten to follow it — those are data and
   another level's code respectively, exactly as in {!rewrite}. A [Set]'s target
   is a reference too (assignment reads the binding to find its cell), so only
   its value is descended into. *)
and substitute ~replacement ~for_ node =
  let span = Core.span node in
  match Core.shape node with
  | Core.Var ident when Ident.equal ident for_ -> replacement
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Quote _ | Core.Reifier _ ->
      node
  | Core.Lam lambda ->
      Core.of_lambda ~span
        {
          lambda with
          Core.lam_body = substitute ~replacement ~for_ lambda.Core.lam_body;
        }
  | Core.App { Core.func; args } ->
      Core.app ~span ~func:(substitute ~replacement ~for_ func)
        ~args:(List.map (substitute ~replacement ~for_) args)
  | Core.Let { Core.let_binder; let_value; let_body } ->
      Core.let_ ~span ~binder:let_binder
        ~value:(substitute ~replacement ~for_ let_value)
        ~body:(substitute ~replacement ~for_ let_body)
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      let bindings =
        List.map
          (fun binding ->
            Core.rec_binding ~span:binding.Core.rec_span ~name:binding.Core.rec_name
              {
                binding.Core.rec_lambda with
                Core.lam_body =
                  substitute ~replacement ~for_
                    binding.Core.rec_lambda.Core.lam_body;
              })
          rec_bindings
      in
      Core.letrec ~span ~bindings
        ~body:(substitute ~replacement ~for_ rec_body)
  | Core.If { Core.condition; consequent; alternative } ->
      Core.if_ ~span
        ~condition:(substitute ~replacement ~for_ condition)
        ~consequent:(substitute ~replacement ~for_ consequent)
        ~alternative:(substitute ~replacement ~for_ alternative)
  | Core.Set { Core.set_target; set_value } ->
      Core.set ~span ~target:set_target
        ~value:(substitute ~replacement ~for_ set_value)

(* The normal form: structure first, then canonical names. Canonicalizing last
   is what makes the result idempotent — renaming neither flattens nor
   reintroduces a trivial binding, and the rewrite of an already-normal term is
   the identity. The write set is stable across both passes: no rewrite here
   introduces or removes a [Set], and renaming carries it along. *)
let normalize node =
  Alpha.canonicalize (rewrite ~assigned:(assigned_idents node) node)
