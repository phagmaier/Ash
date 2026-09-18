(** Conservative, measured four-way collapse classification (spec §9.3). *)

type kind = Depth_invariant_full | Depth_sensitive_full | Partial | Opaque

type precheck = {
  observes_depth : bool;
  dynamic_named_var : bool;
  reflection_under_dynamic_condition : bool;
}

type t = {
  kind : kind;
  precheck : precheck;
  reasons : string list;
  tower_residual_agree : bool;
  conservative : bool;
}

val name : kind -> string
val classify : Metrics.t -> t
