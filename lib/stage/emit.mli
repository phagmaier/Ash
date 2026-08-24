(** Scoped block buffers and hygienic let-insertion (spec §7.2).

    Every emitted dynamic operation is bound by a fresh [let] in an ambient
    code buffer, preventing exponential work and code duplication when dynamic
    results are used multiple times.

    Each branch of a dynamic [If] and each dynamic [Lam] body executes within
    its own scoped [reify_block]. *)

open Ash_core

type binding = {
  binder : Ident.t;
  value : Core.t;
  span : Span.t;
}

type buffer

val create_buffer : unit -> buffer

val emit : ?name:string -> ?from:Span.t -> Core.t -> Core.t
(** Emit a dynamic computation into the active ambient buffer.
    If a buffer is active and [node] is a non-trivial computation (i.e. not
    already a variable [Var] or literal [Lit]), a fresh identifier is
    allocated, the binding [(binder, node)] is added to the buffer, and
    [Var binder] is returned.
    If no buffer is active, [node] is returned directly. *)

val emit_val : ?name:string -> ?from:Span.t -> Core.t -> Value.value
(** Like {!emit}, but wraps the resulting expression in {!Value.Code}. *)

val reify_block : (unit -> Core.t) -> Core.t
(** Execute a computation with a fresh scoped buffer. All operations emitted
    during the computation are wrapped as nested {!Core.Let}s around the
    returned expression. *)

val binding_count : buffer -> int
(** Number of bindings currently recorded in [buffer]. *)

val current_buffer : unit -> buffer option
(** The current ambient buffer, if any. *)
