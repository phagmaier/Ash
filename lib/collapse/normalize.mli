(** The semantics-preserving residual normalizer (to-do task 6.3).

    One canonical shape for residuals, so that claims comparing residuals —
    the depth-invariance claim of task 6.4 above all — are claims about the
    programs rather than about which identities a run allocated or how deeply
    let-insertion happened to nest. See {!normalize} for the three rewrites and
    what each one preserves. *)

open Ash_core

val normalize : Core.t -> Core.t
(** [normalize node] alpha-canonicalizes [node], flattens administrative lets,
    and eliminates trivial bindings, without moving an effect.

    [node] is expected to be runnable: every identity free in it is bound in
    the environment it will run against, which is true of every residual and is
    what {!Ash_stage.Code.unresolved_dependencies} checks. Reading a bound
    variable cannot fail, and that is what lets such a read move to its use site
    or vanish with an unused binding.

    - Idempotent: [Core.equal_structure (normalize (normalize t))]
      [(normalize t)] holds exactly, not merely up to renaming.
    - Semantics-preserving: a run of [normalize t] agrees with a run of [t] on
      value, failure, and observable trace.
    - Order-preserving: nothing is hoisted out of a lambda, an [If] branch, or
      a [LetRec] group, no two computations swap places, and an effectful
      binding is kept even when its binder is unused.
    - Store-preserving: a variable is substituted for its binder only when
      nothing in the term assigns it, so a binding never turns into a read of
      whatever a later [Set] wrote.
    - Data-preserving: the bodies of [Quote] and [Reifier] nodes keep their
      structure; only their bound references follow canonical renaming. A
      binding mentioned only through such data — or as a [Set] target — is kept
      rather than substituted away.
    - Provenance-preserving: rebuilt nodes carry the spans of the nodes they
      came from, so residue attribution by origin still works. *)
