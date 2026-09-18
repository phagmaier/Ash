(** Static and dynamic value predicates and conversions (spec §7.1).

    Static data are real {!Ash_core.Value.value} shapes (numbers, booleans, strings,
    symbols, unit, immutable lists, closures, primitives, cells, etc.).

    Dynamic data are unrecorded {!Ash_core.Value.Code} containing
    {!Ash_core.Core.t} residual syntax. Task 9.1 also records Code handed to a
    statically known evaluator wrapper; that syntax is a static Code value and
    reifies as quotation.

    Stage-polymorphic operations inspect values using these predicates to decide
    whether to fold pure computation at stage time or residualize dynamic code. *)

open Ash_core
open Ash_runtime

val reset_static_codes : unit -> unit
val is_static_code : Core.t -> bool
val static_code : Core.t -> Value.value
val record_static_codes : Value.value -> Value.value
(** Distinguish syntax passed to a statically known evaluator wrapper from
    residual syntax whose runtime value is unknown.  Knowledge is scoped to one
    specialization run and keyed by physical node identity.

    [record_static_codes] recursively records Code inside a static result such
    as [code_view]'s list of constructor fields. *)

val is_dynamic : Value.value -> bool
(** True iff the value is unrecorded, dynamic {!Value.Code}. *)

val is_static : Value.value -> bool
(** True iff the value is not dynamic {!Value.Code}. *)

val static_value : Value.value -> bool
(** Named policy predicate alias for {!is_static} (AGENTS §D7). *)

val is_purely_static : Value.value -> bool
(** True iff the value and all its sub-elements (for lists) are static. Note
    the deliberate coarseness: closures, environments, cells, and primitives
    count as static by identity rather than by deep inspection. What this
    decides is keying and observation depth, never whether a value may be
    serialized — closures and cells still never cross into residual syntax. *)

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
(** Convert a value to {!Core.t}. Dynamic {!Value.Code} returns its residual
    syntax directly; statically known Code becomes [Quote syntax]. Other values
    are converted via {!Evaluator.lift_value}. *)

val maybe_lift :
  mode:Mode.t -> call_site:Span.t -> Machine.t -> Value.value -> Value.value
(** In {!Mode.Identity} mode, returns the value unchanged.
    In {!Mode.Lift} mode, returns dynamic {!Value.Code} wrapping the lifted
    syntax (spec §7.3). *)
