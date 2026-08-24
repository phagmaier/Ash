(** A lazily materialized reflective tower (spec §6.1).

    Level 0 is the ground evaluator and is retained separately. The list of
    materialized upper levels is empty until a reflective operation at level 0
    asks for level 1. Asking from a materialized level [n] creates at most the
    one fresh level [n + 1]; repeated asks return the existing level.

    This module owns materialization only. Reifier application and cross-level
    transfer arrive in tasks 4.2 and 4.3 and will use {!materialize_above}. *)

open Ash_core

type t

type materialized_runtime_size = {
  upper_levels : int;
  global_binding_cells : int;
  evaluator_group_cells : int;
  reachable_words : int;
      (** OCaml heap words reachable from the tower value, including the ground
          baseline and shared registry. This is an actual representation
          measurement, not an interpreter-AST estimate. *)
}

type expanded_semantic_size = {
  depth : int;
  program_nodes : int;
  interpreter_nodes_per_level : int;
  total_nodes : int;
      (** [program_nodes + (depth * interpreter_nodes_per_level)]. *)
}

type size_metrics = {
  materialized_runtime : materialized_runtime_size;
  expanded_semantic : expanded_semantic_size;
}

val create : ?registry:Ash_runtime.Primitives.t -> unit -> t
(** Create a tower with only its ground level. A supplied registry lets callers
    share a scripted or echoing IO stream. *)

val registry : t -> Ash_runtime.Primitives.t
val ground : t -> Level.t
val run : t -> Core.t -> Value.value
(** Run ordinary code at level 0. This never materializes an upper level. *)

val materialized : t -> int
(** Number of upper levels that physically exist. The ground level is not
    included, matching the spec's [materialized == 0] fast path. *)

val find_level : t -> int -> Level.t option
(** Return an existing level without materializing anything. Level 0 is always
    present; negative and unmaterialized indices return [None]. *)

val materialize_above : t -> level:int -> Level.t
(** Return level [level + 1], materializing it if necessary.

    The source level must already exist. This makes laziness local: first
    reflection from ground creates exactly level 1, and nested reflection from
    level 1 creates exactly level 2. *)

val size_metrics :
  t -> depth:int -> program:Core.t -> interpreter:Core.t -> size_metrics
(** Report physical runtime representation and conceptual eager expansion as
    distinct measurements with distinct units. [depth] must be non-negative and
    at least {!materialized}. Calling this function is observationally inert. *)
