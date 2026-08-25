(** Ash Staged Specializer and Collapser Foundations (spec §7).

    This library provides:
    - Evaluator modes ({!Mode}): standard {!Mode.Identity} and staged {!Mode.Lift}.
    - Static and dynamic value predicates and conversions ({!Value}).
    - The abstract store the specializer splits at dynamic branches ({!Store}).
    - The staged CPS evaluator ({!Eval}). *)

open Ash_core
open Ash_runtime

module Mode = Mode
module Value = Stage_value
module Emit = Emit
module Specialize = Specialize
module Store = Store
module Eval = Staged_eval

val eval : ?mode:Mode.t -> env:Ash_core.Value.env -> Core.t -> Ash_core.Value.value
(** Evaluate [node] in [env]. *)

val run :
  ?mode:Mode.t -> Machine.t -> env:Ash_core.Value.env -> Core.t -> Ash_core.Value.value
(** Run [node] on [machine] in [env]. *)

val fold : env:Ash_core.Value.env -> Core.t -> Core.t
(** Evaluate [node] in {!Mode.Lift} mode and return the resulting residual or
    constant-folded {!Core.t}. *)

val is_static : Ash_core.Value.value -> bool
val is_dynamic : Ash_core.Value.value -> bool
val is_purely_static : Ash_core.Value.value -> bool
val is_shape_static : Ash_core.Value.value -> bool

val may_fold : Ash_core.Value.primitive -> Ash_core.Value.value list -> bool
(** Whether a primitive may be applied during specialization to these
    arguments: see {!Stage_value.may_fold}. *)

val maybe_lift :
  mode:Mode.t ->
  call_site:Span.t ->
  Machine.t ->
  Ash_core.Value.value ->
  Ash_core.Value.value
