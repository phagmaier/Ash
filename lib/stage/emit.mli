(** Scoped block buffers and hygienic let-insertion (spec §7.2).

    Every emitted dynamic operation is bound by a fresh [let] in an ambient
    code buffer, preventing exponential work and code duplication when dynamic
    results are used multiple times.

    Each branch of a dynamic [If] and each dynamic [Lam] body executes within
    its own scoped [reify_block].

    A block also carries the specialization points created inside it. They are
    [LetRec] groups rather than [Let]s, and they are placed where they were
    created rather than hoisted: a residual function's body may mention binders
    that let-insertion introduced earlier in the same block, so moving the group
    outwards would take those references out of scope. *)

open Ash_core

type binding = {
  binder : Ident.t;
  value : Core.t;
  span : Span.t;
}

type buffer
type stack
(** The open blocks, innermost first. *)

val create_buffer : unit -> buffer

val stack : unit -> stack
(** The blocks open right now. *)

val with_stack : stack -> (unit -> 'a) -> 'a
(** Run [f] with exactly these blocks open, restoring the current ones
    afterwards. This is how a specialization point is built where its call
    started rather than where its cycle was discovered: the residual function is
    bound, and everything it emits is bound, in the block that was open when the
    unrolling began. *)

val emit : ?name:string -> ?from:Span.t -> Core.t -> Core.t
(** Emit a dynamic computation into the active ambient buffer.
    If a buffer is active and [node] is a non-trivial computation (i.e. not
    already a variable [Var] or literal [Lit]), a fresh identifier is
    allocated, the binding [(binder, node)] is added to the buffer, and
    [Var binder] is returned.
    If no buffer is active, [node] is returned directly. *)

val emit_binder : ?name:string -> ?from:Span.t -> Core.t -> Ident.t * Span.t
(** Bind [node] in the active block whatever it is, and return the binder
    together with the span the binding was given. Unlike {!emit} this never
    declines: the store promotes a held binding by naming its current value, and
    a literal left unbound is not a place the residual program can assign to.
    @raise Invalid_argument when no block is active. *)

val emit_val : ?name:string -> ?from:Span.t -> Core.t -> Value.value
(** Like {!emit}, but wraps the resulting expression in {!Value.Code}. *)

val emit_letrec : ?from:Span.t -> Core.rec_binding list -> unit
(** Add a residual [LetRec] group at the current position of the active buffer.
    Everything emitted after this point, and the block's own result expression,
    is inside its scope. An empty group is a no-op.
    @raise Invalid_argument when no block is active: a specialization point has
    nowhere to be bound. *)

val reify_block : (unit -> Core.t) -> Core.t
(** Execute a computation with a fresh scoped buffer. All operations emitted
    during the computation are wrapped as nested {!Core.Let}s, and all
    specialization points created during it as {!Core.LetRec}s, around the
    returned expression, in emission order. *)

val emitted_count : unit -> int
(** Residual bindings emitted since {!reset_counts}, across every block. The
    specialization budget watches this: an unrolling that folds away emits
    nothing, while one that is not making progress emits at every step. *)

val reset_counts : unit -> unit
(** Zero {!emitted_count}. Called once per specialization run. *)

val binding_count : buffer -> int
(** Number of let-inserted bindings currently recorded in [buffer]. *)

val recursive_group_count : buffer -> int
(** Number of specialization-point groups currently recorded in [buffer]. *)

val current_buffer : unit -> buffer option
(** The current ambient buffer, if any. *)
