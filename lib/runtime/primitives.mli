(** The pure primitives: arithmetic, comparison, and immutable lists.

    Every primitive here is {!Ash_core.Effect_class.Pure}, so a specializer may
    fold any of them once its arguments are static. The allocation, observable,
    control, and reflection classes arrive with the full registry in task 0.9;
    this module exists because arithmetic and lists are what the Phase 0
    evaluators have to be tested against, and a primitive with no effect class is
    exactly the thing §D7 forbids.

    Arity is checked by whatever applies a primitive, so every arity error reads
    the same wherever it comes from. Argument types are checked here, left to
    right, matching the evaluation order Ash gives arguments. *)

open Ash_core

val all : Value.primitive list
(** Every primitive, in a fixed order. *)

val names : string list
val find : string -> Value.primitive option

val globals : unit -> (Ident.t * Value.value) list
(** A fresh identity for each primitive, paired with its value. Each call
    allocates new identities, because a materialized tower level gets its own
    cloned global environment and must not share binders with another level. *)
