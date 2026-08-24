(** How much of an argument a primitive inspects (spec §7.3, §7.4 step 1).

    {!Effect_class} says whether a primitive may run at specialization time at
    all. This module says how much of each argument has to be known first, which
    is what makes {e partially static} immutable data useful: a list whose spine
    is known but whose elements are dynamic is still a real list, and [head],
    [tail], [empty?], [length], and [cons] answer from the spine alone. That is
    the "the environment's shape is static while its contents are dynamic"
    discipline, stated once per primitive instead of guessed by the specializer.

    Only the specializer reads these; the ground evaluator applies every
    primitive to fully known values and never consults them. *)

type t =
  | Whole_value
      (** The argument's value decides the result, so it must be static all the
          way down: [+], [==], [not], the [Code] observers. *)
  | Shape_only
      (** Only the argument's own constructor is inspected — whether it is a
          list, and how long. Elements may be dynamic. *)
  | Unobserved
      (** The argument is carried into the result without being inspected, so it
          may be dynamic: the head of a [cons], the members of a [list]. *)

type signature = {
  positional : t list;  (** Observation of each leading argument. *)
  remaining : t;  (** Observation of every argument past [positional]. *)
}

val whole_values : signature
(** Every argument fully observed: the conservative default, and the only sound
    choice for a primitive that has not stated otherwise. *)

val of_positional : ?remaining:t -> t list -> signature
(** [of_positional ~remaining ts] observes argument [i] as [List.nth ts i], and
    every further argument as [remaining] (default {!Whole_value}). *)

val uniform : t -> signature
(** Every argument observed the same way, whatever the arity. *)

val at : signature -> int -> t
(** Observation of the zero-based argument position [index]. *)

val name : t -> string
(** Report and diagnostic name, e.g. ["shape-only"]. *)

val equal : t -> t -> bool
