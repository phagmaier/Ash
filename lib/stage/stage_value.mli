(** Static and dynamic value predicates and conversions (spec §7.1).

    Static data are real {!Ash_core.Value.value} shapes (numbers, booleans, strings,
    symbols, unit, immutable lists, closures, primitives, cells, etc.).

    Dynamic data are {!Ash_core.Value.Code} containing {!Ash_core.Core.t} syntax.

    Stage-polymorphic operations inspect values using these predicates to decide
    whether to fold pure computation at stage time or residualize dynamic code. *)

open Ash_core
open Ash_runtime

val is_dynamic : Value.value -> bool
(** True iff the value is dynamic {!Value.Code}. *)

val is_static : Value.value -> bool
(** True iff the value is not dynamic {!Value.Code}. *)

val static_value : Value.value -> bool
(** Named policy predicate alias for {!is_static} (AGENTS §D7). *)

val is_purely_static : Value.value -> bool
(** True iff the value and all its sub-elements (for lists) are static. *)

val is_shape_static : Value.value -> bool
(** True iff the value's own constructor is known at specialization time, which
    is everything but dynamic {!Value.Code}. A list is shape-static even when
    its elements are dynamic: its spine is a real spine. *)

val may_fold : Value.primitive -> Value.value list -> bool
(** True iff [primitive] may be applied during specialization to [arguments]:
    its {!Effect_class} permits folding and every argument it inspects is known
    to the depth it inspects (see {!Ash_core.Observation}). *)

val dynamic_code : Value.value -> Core.t option
(** Extract the {!Core.t} syntax from a dynamic {!Value.Code}, or [None]. *)

val lift_to_code : call_site:Span.t -> Machine.t -> Value.value -> Core.t
(** Convert a value to {!Core.t}. If the value is already {!Value.Code}, its
    enclosed syntax is returned directly without re-wrapping. Otherwise, it is
    converted via {!Evaluator.lift_value}. *)

val maybe_lift :
  mode:Mode.t -> call_site:Span.t -> Machine.t -> Value.value -> Value.value
(** In {!Mode.Identity} mode, returns the value unchanged.
    In {!Mode.Lift} mode, returns dynamic {!Value.Code} wrapping the lifted
    syntax (spec §7.3). *)
