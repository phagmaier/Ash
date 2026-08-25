(** The abstract store: static-store splitting and dynamic joins (to-do task
    7.2, spec §7.4 step 3).

    Until this module existed the specializer refused {!Ash_core.Core.Set}
    outright, because performing a write during specialization would have
    mutated the specializer's own state instead of the program's, and emitting
    one would have needed a residual place to write to. This is the bookkeeping
    that decides, for each binding, which of the two happens.

    {1 What a binding may be}

    A cell is either {b held} — the specializer owns it, writes update it, reads
    fold — or {b residual} — the residual program owns it, writes become
    {!Ash_core.Core.Set} nodes and reads become variables. A held cell's contents
    live in the cell itself, so an ordinary [Var] read finds them with no store
    lookup and a program that never assigns anything pays nothing for this
    module existing.

    The store is keyed by the cell, never by the binder. Two names for one cell
    are one place, which is what aliasing is; one binder evaluated twice is two
    places, which is what a [var] local to a recursive function needs. Identity
    is {!Ash_core.Value.same_cell}, so neither can be mistaken for the other.

    {1 When a binding may be held}

    {!holdable} is the proof obligation, and it is deliberately syntactic and
    over-approximate: the specializer may hold a binding only while it is the
    only thing that can touch it. A binder free in a lambda fails, because that
    closure can be reified, shared by a specialization point, or called from a
    dynamic position, and then the reads and writes happen in the residual
    program's order rather than in ours. A binder mentioned in quoted data, a
    [NamedVar] that spells its printed name, or a [Reifier] anywhere in the
    scope fails for the same reason: something other than this specializer can
    reach the cell.

    Failing is not refusing. A binding the store cannot hold is residualized,
    which is the whole of {e residualize when proof is unavailable}.

    {1 Dynamic joins}

    At a conditional whose condition the specializer cannot decide, both
    branches are specialized and the store is forked. Any held cell either
    branch assigns is {!promote}d {e before} the fork — the residual program
    needs one place both branches write to, and it has to be bound where both
    can see it. What is left is joined by {!join}, which keeps only the bindings
    that outlive the branch and requires the two forks to describe each of them
    the same way.

    {1 The write set}

    {!assigned} answers from {!Ash_core.Core.assigned_idents} of the whole term
    being specialized — the same definition {!Ash_collapse.Normalize} uses to
    decide what it may substitute. That sharing is load-bearing: a residual this
    module builds is normalized afterwards, and a normalizer with a narrower
    write set would substitute a binding's initial value into a use that a
    residual [Set] was supposed to have changed.

    All of this is run state, cleared by {!reset} once per specialization. *)

open Ash_core

type slot =
  | Held of Value.value
      (** The specializer owns the contents. They live in the cell itself; this
          is the copy the fork and the join compare. *)
  | Residual of { target : Ident.t; reference : Value.value }
      (** The residual program owns the contents: [target] is the binding it
          keeps them in, and [reference] is the dynamic value — [Code (Var
          target)] — that reading the cell produces. *)

type binding
type snapshot

val reset : assigned:Ident.Set.t -> unit
(** Clear the store and install the write set of the term about to be
    specialized. *)

val assigned : Ident.t -> bool
(** Whether anything in the term being specialized assigns this binder. Every
    decision this module makes is gated on it, so a term that assigns nothing
    takes exactly the path it took before the store existed. *)

(** {1 Eligibility} *)

val holdable : binder:Ident.t -> scope:Core.t -> bool
(** Whether the specializer may own [binder]'s cell over [scope], or the
    residual program must. See the module docstring for the four ways a binding
    escapes. Memoized on the binder, which is sound because a hygienic identity
    has exactly one scope. *)

(** {1 Tracked bindings} *)

val slot : Value.cell -> slot option
(** How this cell is described, or [None] when the store does not track it.
    [None] at an assignment is where the specializer must refuse: there is no
    residual place to write to and no proof that writing here is the
    specializer's alone. *)

val track_held : Value.cell -> binder:Ident.t -> Value.value -> unit
val track_residual :
  Value.cell -> binder:Ident.t -> target:Ident.t -> reference:Value.value -> unit

val release : Value.cell -> unit
(** Forget a cell whose scope has ended. *)

val write : Value.cell -> Value.value -> unit
(** Perform a held write: update the cell and the store together.
    @raise Invalid_argument unless the cell is currently held. *)

val promote : Value.cell -> target:Ident.t -> reference:Value.value -> unit
(** Give up on a held binding: from here [target] holds the contents and reading
    the cell yields [reference]. The caller emits the binding of [target] first,
    so that the value the specializer was holding is what the residual starts
    from.
    @raise Invalid_argument unless the cell is currently held. *)

val holds_static : unit -> bool
(** Whether any binding is currently held — that is, whether the specializer is
    claiming anything at all. A dynamic conditional skips its promotion scan when
    it is not, and the reflective boundaries refuse when it is: handing an
    environment to another level while the specializer holds part of it would be
    holding a value that level can change. *)

val written_holds : Ident.Set.t -> (Value.cell * Ident.t * Value.value) list
(** The held cells whose binder is in [written], with the value each holds: what
    a dynamic conditional has to promote before forking. *)

(** {1 Forking and joining} *)

val snapshot : unit -> snapshot
val restore : snapshot -> unit
(** Reinstate a snapshot, cell contents included. Specializing the second branch
    of a dynamic conditional starts from the snapshot taken before the first. *)

val join :
  before:snapshot -> left:snapshot -> right:snapshot -> (snapshot, binding) result
(** The store after a dynamic conditional: the bindings live before the fork,
    each described the same way by both branches. [Error binding] names the
    first binding the branches disagree about — the case where no sound answer
    exists and the caller must refuse. Bindings a branch created are dropped:
    their scope ended with the branch. *)

val bindings_of : snapshot -> binding list
(** The bindings a snapshot describes, innermost first. *)

val binder_of : binding -> Ident.t
val slot_of : binding -> slot
