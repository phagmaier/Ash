(** Alpha-equivalence and canonical renaming for Core.

    Binder identities come from a global counter, so two terms that mean the same
    thing are almost never structurally equal. Every claim this project makes
    about programs being the same — the oracle agreeing with the CPS evaluator,
    a residual matching its source, depth {i k} matching depth 1 — is a claim up
    to alpha-equivalence, which makes this the comparison the whole measurement
    rests on.

    Two comparisons are offered and they are not interchangeable. {!equal}
    decides alpha-equivalence directly by walking both terms in step; it is exact
    and total. {!canonicalize} rewrites one term so that {!Core.equal_structure}
    on canonicalized terms {e is} alpha-equivalence, which is what a normalizer
    or a report that wants a stable key needs. Spans take no part in either:
    where a term was written has nothing to do with what it is. *)

val free_idents : Core.t -> Ident.Set.t
(** The identifiers a term refers to but does not bind. A [Set] target counts as
    a reference, and a [Quote]'s body is traversed like any other subterm,
    because a quoted variable refers to the binding it was written under. *)

val equal : Core.t -> Core.t -> bool
(** Alpha-equivalence: the terms differ at most by the choice of binder
    identities. Bound identifiers correspond by binding position; free ones must
    be the same identifier, since a free [x#4] and a free [y#9] denote different
    variables. *)

val canonicalize : Core.t -> Core.t
(** Rename every bound identifier to a canonical one, numbered by first
    occurrence in a left-to-right traversal. Free identifiers are left alone, and
    canonical identities occupy a disjoint numbering (see {!Ident.Canon}), so
    they cannot collide.

    For terms in which each binder identity is bound at most once — everything
    the reader produces, and everything built with fresh identities —
    [Core.equal_structure (canonicalize a) (canonicalize b)] agrees with
    {!equal}. Spans are preserved, which is why the comparison must ignore
    them. *)
