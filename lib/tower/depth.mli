(** Running a program under a tower of a stated depth.

    Task 4.1 made materialization lazy and task 4.3 made [up] able to replace a
    level's evaluator. Neither of them, on its own, lets a test say "run this at
    depth 5": ordinary code materializes nothing, and a level that is
    materialized but still holds the evaluator it started with is
    {e observationally indistinguishable} from the default by construction. A
    depth built out of such levels would make the transparency law of spec §5.7
    true by definition and prove nothing.

    So depth here means levels that are actually interpreting. {!interpose}
    writes an Ash closure — [fn(e, r, k) -> base(e, r, k)] — into a level's
    evaluator cell, exactly as [up { eval := … }] does from inside the language.
    Every step of that level is then a term the level above evaluates. The
    closure is semantically the identity, so the whole point of the transparency
    law is that stacking it changes nothing an Ash program can observe; the whole
    point of the collapser is that it costs a great deal that is not observable.

    This is also the configuration Phase 5 has to squash and Phase 6.4 has to
    compare residuals across, which is why it lives here rather than in a test. *)

open Ash_core

val interposed_term : unit -> Core.t
(** The term interposed at each level, [fn(e, r, k) -> base(e, r, k)], as Core.
    Its {!Ash_core.Core.node_count} is the per-level interpreter size the §9.1
    expanded-semantic figure multiplies by depth, so the report measures what is
    actually installed rather than a number written down beside it. Each call
    allocates fresh binders, exactly as {!interpose} does. *)

val interpose : Tower.t -> level:int -> unit
(** Interpose one interpreter above [level], materializing the level that will
    run it. The level's current evaluator becomes the new one's [base], so
    repeated calls stack rather than replace.
    @raise Invalid_argument if [level] is not materialized. *)

val materialize : Tower.t -> depth:int -> unit
(** Interpose an interpreter at every level below [depth], so that levels 0 to
    [depth - 1] are each run by the level above and {!Tower.materialized} is
    [depth]. Depth 0 does nothing: the base program runs on the host. *)

val run : Tower.t -> depth:int -> Core.t -> Value.value
(** {!materialize} and then run the term at level 0. The value, and every
    observable effect, must be what depth 0 produces — that is the transparency
    law. Step counts, host stack, and wall time are deliberately not (spec
    §D9). *)
