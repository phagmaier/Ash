(** Evaluator modes for the staged specializer (spec §7.3).

    [Identity] mode evaluates a term to its standard runtime value: [maybe_lift] is
    the identity function.

    [Lift] mode stages the evaluation: static data folds and static results are
    lifted into [Code] (spec §D6). *)

type t =
  | Identity
  | Lift

val is_identity : t -> bool
val is_lift : t -> bool
val name : t -> string
val equal : t -> t -> bool
val compare : t -> t -> int
val to_string : t -> string
val pp : Format.formatter -> t -> unit
