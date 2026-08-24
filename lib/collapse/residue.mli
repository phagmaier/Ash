(** What is left of interpretation in a residual program (spec §9.4).

    The collapse report's sharp questions are about the residual's {e syntax},
    not about what a run of it happens to do: did any evaluator group
    dereference survive, is any Core constructor still dispatched on, is any name
    still looked up at runtime, is any reflective boundary still crossed. Those
    are decided here, by one walk of the residual.

    Callees are identified by hygienic identity, never by printed name: a
    residual application names the exact global binding the specializer emitted
    (task 5.2), so resolving that identifier in the environment the residual will
    run in says precisely which primitive it is. A local binder that happens to
    print [head] resolves to nothing and is counted as nothing. *)

open Ash_core

type t = {
  nodes : int;  (** Every Core node in the residual, quoted subterms included. *)
  nodes_by_origin : (string * int) list;
      (** Nodes grouped by the source file their provenance ultimately points
          at, sorted by file name. A node the specializer invented keeps the
          origin of the code it came from (spec §D1's provenance rule), so this
          says which source each surviving node is interpretation {e of}. *)
  generated_nodes : int;  (** Nodes carrying a generated marker. *)
  eval_cell_dereferences : int;
      (** Applications of [open_deref]. An [open_deref] in a term is exactly one
          evaluator-group dereference, which is why the open-recursion cells are
          spelled apart from ordinary ones in the registry. *)
  evaluator_calls : int;
      (** Applications whose callee is itself an [open_deref] — a surviving call
          to a group member, which is what an interpreter's recursive step looks
          like once it is written down. *)
  dispatch_sites : int;
      (** Applications of [code_view] or [code_match]: a Core constructor being
          dispatched on at runtime. *)
  named_var_lookups : int;  (** [NamedVar] nodes: lookups by printed name. *)
  reflection_boundaries : (string * int) list;
      (** Applications of reflection-class primitives, by primitive name, sorted.
          Empty for the pure fragment. *)
}

val survey : env:Value.env -> Core.t -> t
(** Walk [node], resolving callee identities in [env] — the environment the
    residual will be run in. Calling this is observationally inert. *)

val interpreter_residue : t -> own:string -> int
(** Nodes whose origin is a file other than [own], the program's own source:
    what is left of some {e other} program's text, which is the thing the
    collapse criterion is about. *)
