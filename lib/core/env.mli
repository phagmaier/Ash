(** Operations over lexical environments: chains of frames mapping hygienic
    identifiers to cells.

    The representation lives in {!Value}, because environments, cells, and values
    are mutually recursive. This module owns the operations the evaluator needs:
    {!lookup}, {!lookup_by_name}, {!bind}, {!extend}, {!preallocate}, and
    {!assign_exn}.

    Frames are immutable and searched innermost first, so shadowing is just frame
    order. Values are reached through cells, so an assignment from anywhere — a
    [Set], a meta level, a filled recursive binding — is visible to every closure
    that already captured the binding, without rebuilding any environment. *)

type binding_state =
  | Unbound  (** No frame binds this identifier. *)
  | Unfilled  (** Bound to a preallocated cell that has not been filled. *)
  | Bound of Value.value

type name_lookup =
  | Name_unbound
  | Name_found of Value.cell
  | Name_ambiguous of Ident.t list
      (** The innermost frame that mentions the name binds several distinct
          identifiers that print alike. There is no non-arbitrary answer: picking
          one by allocation order would make the gensym counter observable, so
          the ambiguity is reported instead. *)

(** {1 Lookup by identity} *)

val lookup : Value.env -> Ident.t -> Value.cell option
(** Innermost binding of [ident], or [None]. Identity only: two identifiers that
    print alike are different bindings. *)

val lookup_exn :
  phase:Error.phase -> span:Span.t -> ?level:int -> Value.env -> Ident.t -> Value.cell
(** @raise Error.Ash_error with {!Error.Unbound_ident} located at [span]. *)

val state : Value.env -> Ident.t -> binding_state
(** Distinguishes unbound from bound-but-unfilled, which [LetRec] needs and which
    a plain [value option] would conflate. *)

val read_exn :
  phase:Error.phase -> span:Span.t -> ?level:int -> Value.env -> Ident.t -> Value.value
(** @raise Error.Ash_error with {!Error.Unbound_ident} or
    {!Error.Unfilled_binding}. *)

(** {1 Lookup by printed name}

    This is what [NamedVar] uses: reflective code builds variable references from
    runtime strings and has no binder ID to offer. Ordinary compiled code never
    takes this path, and the collapse report counts the name lookups that
    survive specialization. *)

val lookup_by_name : Value.env -> string -> name_lookup

val lookup_by_name_exn :
  phase:Error.phase -> span:Span.t -> ?level:int -> Value.env -> string -> Value.cell
(** @raise Error.Ash_error with {!Error.Unbound_name} or
    {!Error.Ambiguous_name}. *)

(** {1 Extension}

    Each of these pushes exactly one frame, so a binding introduced by a [Let]
    cannot silently overwrite a sibling in an enclosing frame. *)

val bind : Ident.t -> Value.value -> Value.env -> Value.env
val bind_cell : Ident.t -> Value.cell -> Value.env -> Value.env

val extend : (Ident.t * Value.value) list -> Value.env -> Value.env
(** For applying a closure or reifier to its arguments.
    @raise Invalid_argument on a repeated binder identity. *)

val extend_cells : (Ident.t * Value.cell) list -> Value.env -> Value.env

val preallocate : Ident.t list -> Value.env -> Value.env
(** Push a frame binding each identifier to an unfilled cell, for [LetRec]:
    allocate, evaluate the lambdas in the extended environment, then fill. Reading
    one of these bindings before it is filled is an error, never a default value.
    @raise Invalid_argument on a repeated binder identity. *)

(** {1 Assignment} *)

val assign :
  Value.env -> Ident.t -> Value.value -> bool
(** Fill the cell [ident] is bound to, returning [false] if it is unbound.
    Assignment never creates a binding — that is what makes closure-visible
    mutation and [LetRec] filling the same mechanism. *)

val assign_exn :
  phase:Error.phase ->
  span:Span.t ->
  ?level:int ->
  Value.env ->
  Ident.t ->
  Value.value ->
  unit
(** @raise Error.Ash_error with {!Error.Unbound_ident}. *)

(** {1 Description} *)

val depth : Value.env -> int
(** Number of frames. *)

val idents : Value.env -> Ident.Set.t
(** Every identifier bound anywhere in the chain, shadowed ones included. *)
