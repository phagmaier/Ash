(** One independently stateful level of the reflective tower.

    A level owns the exact global environment used by its evaluator and a fresh
    open-recursive evaluator machine. Global binder identities and their cells
    are never shared between levels. Primitive values deliberately are shared,
    so all levels use one observable IO stream (spec §6.1, task 4.1). *)

open Ash_core

type t

val create : index:int -> registry:Ash_runtime.Primitives.t -> unit -> t
(** Create a fresh level. [index] is relative to the base program and must be
    non-negative. The registry supplies shared primitive values; its globals
    factory supplies fresh identities and cells. *)

val index : t -> int
val global : t -> Value.env
(** The level's cloned global environment. *)

val machine : t -> Ash_runtime.Machine.t
(** The level's fresh open-recursion cells and observationally inert counters. *)

val run : t -> Core.t -> Value.value
(** Evaluate ordinary Core at this level in its own closed global environment. *)

val global_binding_count : t -> int
val evaluator_group_cell_count : t -> int
(** Structural components retained by this level. The group currently contains
    [eval], [apply], and [eval_list]. *)
