(** Structured errors.

    An error carries the phase that raised it, the source span it happened at,
    the tower level it belongs to, and a structured cause. Nothing formats an
    error except the CLI boundary and tests, so a diagnostic can be inspected,
    compared, and reported differently by different front ends.

    Rendering deliberately prints identifiers by printed name only. Unique IDs are
    an excluded observation (AGENTS invariant 10): putting them in a message would
    make golden diagnostics depend on allocation order. {!to_string_debug} adds
    them for interactive debugging and must not be used in golden output. *)

type phase =
  | Read  (** The canonical Core s-expression reader. *)
  | Lex
  | Parse
  | Desugar
  | Evaluate
  | Stage
  | Collapse

type cause =
  | Unbound_ident of Ident.t
      (** A hygienic variable with no binding in the environment chain. *)
  | Unbound_name of string  (** A [NamedVar] that resolved to nothing. *)
  | Ambiguous_name of { name : string; candidates : Ident.t list }
      (** One frame binds several distinct identifiers that print alike, so a
          name lookup has no non-arbitrary answer. Choosing by allocation order
          would make the gensym counter observable, which is exactly what the
          excluded-observation rule forbids. *)
  | Unfilled_binding of Ident.t
      (** A recursive binding read before its cell was filled. *)
  | Unexpected_character of char  (** A character no token can start with. *)
  | Unterminated of string
      (** Input ended inside the named construct, e.g. ["string literal"]. *)
  | Unexpected of { found : string; expected : string }
      (** Both parts are noun phrases: ["expected a Core form, found an
          integer"]. *)
  | Unknown_form of string  (** A head atom that names no Core form. *)
  | Malformed_form of { form : string; expected : string }
      (** A recognized form with the wrong shape or arity; [expected] shows the
          form's canonical spelling. *)
  | Duplicate_binder of string
      (** One binder list binds a printed name twice. The reader works in names,
          so allowing it would make resolution depend on the order bindings were
          entered, and it would build a frame no name lookup could resolve. *)

type t = {
  phase : phase;
  span : Span.t;
  level : int option;
      (** The tower level, counted relative to the base program (spec §D9).
          [None] for errors that belong to no particular level, such as reader
          and parser diagnostics. *)
  cause : cause;
}

exception Ash_error of t
(** Raised by the [_exn] operations. Caught and formatted at the CLI boundary. *)

val make : phase:phase -> span:Span.t -> ?level:int -> cause -> t
val fail : t -> 'a
val raise_cause : phase:phase -> span:Span.t -> ?level:int -> cause -> 'a

val phase_name : phase -> string

val cause_message : cause -> string
(** The cause alone, without location or phase. *)

val cause_equal : cause -> cause -> bool
(** Structural equality of causes. Differential tests compare reported failures
    with this rather than with rendered text, so rewording a message cannot
    change what a test asserts. *)

val equal : t -> t -> bool
(** Structural equality including phase, span, and level. *)

val to_string : t -> string
(** ["file:1:5: evaluate error: unbound identifier `x`"], with
    [" at level 1"] appended when the error belongs to a level. *)

val to_string_debug : t -> string
(** As {!to_string} but with unique identifier IDs. Never use in golden output. *)

val pp : Format.formatter -> t -> unit
