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
  | Specialization_only
      (** [static_log]: §D7's compile-time channel, {e defined} to run when the
          specializer meets it and to leave nothing behind. The inverse of
          {!Observable_effect} rather than a weaker form of it — that one may
          never run at specialization time, this one may never survive it — and
          a separate class so the rule is read off the class instead of a name.
          Nothing it does is program-visible output. *)
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
(** True for {!Pure} and {!Specialization_only}. A primitive whose arguments are
    all static may be executed during specialization only if this holds; a
    {!Specialization_only} primitive inspects nothing, so it qualifies whatever
    it is handed. *)

val always_residualizes : t -> bool
(** True only for {!Observable_effect}: no argument knowledge ever justifies
    running it at specialization time. The specializer checks this {e before}
    any rule that could fold, so the D7 guarantee is structural rather than a
    property of the order the other rules happen to be written in. *)

val runs_at_specialization : t -> bool
(** True only for {!Specialization_only}: the primitive runs when the
    specializer meets it and contributes nothing to the residual. A residual
    containing one would mean the specializer skipped it, so this is what a
    test asserts against. *)
