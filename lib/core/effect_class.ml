type t =
  | Pure
  | Allocation_or_mutation
  | Observable_effect
  | Control
  | Reflection

let all = [ Pure; Allocation_or_mutation; Observable_effect; Control; Reflection ]

let name = function
  | Pure -> "pure"
  | Allocation_or_mutation -> "allocation/mutation"
  | Observable_effect -> "observable-effect"
  | Control -> "control"
  | Reflection -> "reflection"

let rank = function
  | Pure -> 0
  | Allocation_or_mutation -> 1
  | Observable_effect -> 2
  | Control -> 3
  | Reflection -> 4

let equal a b =
  match (a, b) with
  | Pure, Pure -> true
  | Allocation_or_mutation, Allocation_or_mutation -> true
  | Observable_effect, Observable_effect -> true
  | Control, Control -> true
  | Reflection, Reflection -> true
  | (Pure | Allocation_or_mutation | Observable_effect | Control | Reflection), _ ->
      false

let compare a b = Int.compare (rank a) (rank b)

(* Named policy predicates rather than scattered representation tests, so the
   staging rules are readable at their use sites. *)

let may_fold_when_static = function
  | Pure -> true
  | Allocation_or_mutation | Observable_effect | Control | Reflection -> false

let always_residualizes = function
  | Observable_effect -> true
  | Pure | Allocation_or_mutation | Control | Reflection -> false
