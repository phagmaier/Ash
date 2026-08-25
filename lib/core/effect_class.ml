type t =
  | Pure
  | Allocation_or_mutation
  | Observable_effect
  | Specialization_only
  | Control
  | Reflection

let all =
  [ Pure; Allocation_or_mutation; Observable_effect; Specialization_only; Control;
    Reflection ]

let name = function
  | Pure -> "pure"
  | Allocation_or_mutation -> "allocation/mutation"
  | Observable_effect -> "observable-effect"
  | Specialization_only -> "specialization-only"
  | Control -> "control"
  | Reflection -> "reflection"

let rank = function
  | Pure -> 0
  | Allocation_or_mutation -> 1
  | Observable_effect -> 2
  | Specialization_only -> 3
  | Control -> 4
  | Reflection -> 5

let equal a b =
  match (a, b) with
  | Pure, Pure -> true
  | Allocation_or_mutation, Allocation_or_mutation -> true
  | Observable_effect, Observable_effect -> true
  | Specialization_only, Specialization_only -> true
  | Control, Control -> true
  | Reflection, Reflection -> true
  | ( Pure | Allocation_or_mutation | Observable_effect | Specialization_only
    | Control | Reflection ),
    _ ->
      false

let compare a b = Int.compare (rank a) (rank b)

(* Named policy predicates rather than scattered representation tests, so the
   staging rules are readable at their use sites. *)

let may_fold_when_static = function
  | Pure | Specialization_only -> true
  | Allocation_or_mutation | Observable_effect | Control | Reflection -> false

let always_residualizes = function
  | Observable_effect -> true
  | Pure | Allocation_or_mutation | Specialization_only | Control | Reflection ->
      false

let runs_at_specialization = function
  | Specialization_only -> true
  | Pure | Allocation_or_mutation | Observable_effect | Control | Reflection ->
      false
