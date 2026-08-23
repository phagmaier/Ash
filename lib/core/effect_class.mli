(** How a primitive behaves when the specializer meets it (spec §D7).

    "Every primitive is stage-polymorphic" is wrong in a way that produces
    incorrect compilers rather than slow ones: folding [print("hello")] at
    specialization time means {e compilation} prints and running the compiled
    program does not. The policy is therefore per class, and the class is part of
    a primitive's definition rather than something the specializer guesses.

    The registry that assigns exactly one class to every primitive is task 0.9;
    this module only fixes the taxonomy and the two policy predicates the
    collapser consults. *)

type t =
  | Pure
      (** Arithmetic, comparison, immutable list operations, [Code]
          constructors. Foldable when every argument is static. *)
  | Allocation_or_mutation
      (** [cell_new], [deref], [set]. Residualized by default; static only under
          the explicit store-splitting discipline of Phase 7. *)
  | Observable_effect
      (** [print], [read], IO. Never executed at specialization time. Compile-time
          logging gets its own [static_log] primitive instead of overloading
          these. *)
  | Control  (** [call/cc], [resume], [abort]. Bespoke rules. *)
  | Reflection
      (** [up], [reflect], reifier application. Bespoke rules; this is what the
          collapse classification is actually measuring. *)

val all : t list
(** Every class, in declaration order. Exhaustive by construction, so a report
    that iterates it cannot silently omit a class. *)

val name : t -> string
(** Report and diagnostic name, e.g. ["allocation/mutation"]. *)

val equal : t -> t -> bool
val compare : t -> t -> int

val may_fold_when_static : t -> bool
(** True only for {!Pure}. A primitive whose arguments are all static may be
    executed during specialization only if this holds. *)

val always_residualizes : t -> bool
(** True only for {!Observable_effect}: no argument knowledge ever justifies
    running it at specialization time. *)
