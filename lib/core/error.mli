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
  | Open_code of Code.dependency list
      (** [run] was given Code with unresolved hygienic dependencies. The list
          contains every identity and every occurrence location in source order,
          rather than stopping at the first unbound variable. *)
  | Unliftable_value of { found : string; value : string; path : int list }
      (** [lift] reached a value outside its fixed domain. [path] is a sequence
          of one-based immutable-list indexes from the argument to the rejected
          value, so a nested failure identifies where the value came from rather
          than reporting only its type. [value] is its finite opaque rendering. *)
  | Unexpected_character of char  (** A character no token can start with. *)
  | Unterminated of string
      (** Input ended inside the named construct, e.g. ["string literal"]. *)
  | Unexpected of { found : string; expected : string }
      (** Both parts are noun phrases: ["expected a Core form, found an
          integer"]. Runtime type errors use this too — a value's phrase comes
          from {!Value.type_phrase} — because the {!phase} already says whether a
          mismatch was syntactic or dynamic. *)
  | Unknown_form of string  (** A head atom that names no Core form. *)
  | Malformed_form of { form : string; expected : string }
      (** A recognized form with the wrong shape or arity; [expected] shows the
          form's canonical spelling. *)
  | Arity_error of { callee : string option; expected : string; actual : int }
      (** A call with the wrong number of arguments. [callee] is a name when one
          is known; anonymous functions have none. *)
  | Unsupported of { what : string; by : string }
      (** A construct a deliberately restricted component refuses, such as the
          frozen direct-style oracle meeting a reifier. Not a program error in
          general — only in that component. *)
  | Division_by_zero
  | Continuation_reuse of { captured : Span.t; first_used : Span.t }
      (** A one-shot continuation was invoked a second time (spec §D4). Both
          sites are carried because neither alone explains the mistake: the
          error is reported where the second invocation was written, and what a
          reader needs is where the continuation came from and where it already
          went. *)
  | Meta_error of string
      (** A meta level raised deliberately with [meta_error] (spec §5.2). The
          error belongs to the level that raised it, which is the level a lower
          one reflected into: a reifier body running at level [n + 1] fails at
          level [n + 1] and never resumes level [n]. *)
  | Immutable_binding of string
      (** A surface assignment named a binding introduced by [let] rather than
          [var]. Mutability is a property of the binder, not of the cell, so the
          desugarer decides this statically: Core [Set] assigns to whatever cell
          a binder is bound to, and nothing later in the pipeline could tell the
          two kinds of binding apart. *)
  | No_matching_clause of string
      (** A [match] ran out of clauses. The payload is the printed scrutinee, so
          the diagnostic can say what failed to match without the error type
          depending on the value domain. *)
  | Duplicate_binder of string
      (** One binder list binds a printed name twice. The reader works in names,
          so allowing it would make resolution depend on the order bindings were
          entered, and it would build a frame no name lookup could resolve. *)
  | Inconsistent_pattern_binders of {
      expected : string list;
      actual : string list;
    }
      (** Two arms of an alternative pattern bind different name sets. Both
          lists are sorted so diagnostics and structural comparisons are
          independent of traversal order. *)
  | End_of_input
      (** An observable input primitive was called with nothing left to read.
          A program-level condition rather than a host failure: input is
          scripted rather than taken from the host, so this is as reproducible
          as any other error. *)
  | Budget_exhausted of {
      what : string;  (** The budget's name, e.g. ["inlining-depth"]. *)
      limit : int;
      callee : string option;
          (** The function specialization gave up on, when one is named. *)
    }
      (** Specialization ran out of budget and had nothing left to generalize:
          every argument of the call it was working on is already dynamic
          (spec §7.5). Not a program error — the program is fine, and running it
          is unaffected — but the specializer must say so rather than diverge.
          The limits are deterministic counts, never wall time. *)

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
    [" at level 1"] appended when the error belongs to a meta level above the
    base program. Level 0 is the base program itself (levels are relative, spec
    §D9), so it is not named: it would appear on every ordinary diagnostic and
    distinguish nothing. *)

val to_string_debug : t -> string
(** As {!to_string} but with unique identifier IDs. Never use in golden output. *)

val pp : Format.formatter -> t -> unit
