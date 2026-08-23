(** The classified primitive registry.

    Every primitive carries exactly one {!Ash_core.Effect_class}, and it carries
    it as a field rather than as something a specializer infers. That is the
    whole point of §D7: "every primitive is stage-polymorphic" is wrong in a way
    that produces incorrect compilers rather than slow ones, because folding
    [print("hi")] at specialization time means {e compiling} prints and
    {e running} does not. A primitive with no class cannot be written down here,
    so no later phase can meet one and have to guess.

    Registered so far:

    - {!Ash_core.Effect_class.Pure} — integer arithmetic, comparison, equality,
      immutable lists, and [match_error], the failure a desugared [match] falls
      through to. Foldable once every argument is static.
    - {!Ash_core.Effect_class.Allocation_or_mutation} — [cell_new], [deref],
      [cell_set]. Residualized until Phase 7's store splitting says otherwise.
    - {!Ash_core.Effect_class.Observable_effect} — [print], [println],
      [read_line], all of which go through an injectable {!Io.t} so that a trace
      is a value tests can compare.

    - {!Ash_core.Effect_class.Control} — [callcc], which reifies the current
      continuation as a one-shot value and hands it to its argument. Never
      folded: capturing during specialization would capture the specializer's
      continuation.

    {!Ash_core.Effect_class.Reflection} has no members yet: [lift], [run],
    [reflect], and [up] need staging and the tower. An empty class is not a gap
    in the classification — the class is part of a primitive's definition, so the
    property "exactly one class per primitive" holds by construction and is
    checked over whatever is registered.

    {1 Errors}

    Arity is checked by whatever applies a primitive, so every arity error reads
    the same wherever it comes from, and it is checked again inside the primitive
    because an implementation is a total function. Argument types are checked by
    the primitive, left to right, matching the order Ash evaluates arguments in,
    and reported at the call site, which is the only location a primitive
    has. *)

open Ash_core

type t
(** A registry: the primitives, plus the observable-effect stream they write to.
    An instance rather than a constant because the observable primitives are
    closed over a stream, and a deterministic test wants its own. *)

val create : ?io:Io.t -> unit -> t
(** [create ()] gives a registry over a fresh buffered stream. Pass [~io] to
    share one, or to script input.
    @raise Invalid_argument if two primitives share a name, which would let a
    lookup answer one and an environment bind the other. *)

val io : t -> Io.t
(** The stream this registry's observable primitives write to and read from. *)

val all : t -> Value.primitive list
(** Every primitive, in registry order: pure, then allocation/mutation, then
    observable, then control. *)

val find : t -> string -> Value.primitive option

val globals : t -> (Ident.t * Value.value) list
(** A fresh identity for each primitive, paired with its value. Each call
    allocates new identities, because a materialized tower level gets its own
    cloned global environment and must not share binders with another level. The
    primitive {e values} are shared, so a level that clones its globals still
    writes to the same observable stream: output is one stream of events for the
    whole tower, not one per level. *)

(** {1 The classification}

    Names and classes are the same for every registry, so these need no
    instance. *)

val names : string list
val count : int

val classification : (string * Effect_class.t) list
(** Every primitive's name and class, in registry order. Exhaustive by
    construction: it is derived from the registry rather than written down
    twice. *)

val class_of : string -> Effect_class.t option
val by_class : Effect_class.t -> string list
(** The names in one class, in registry order. Over {!Ash_core.Effect_class.all}
    these partition {!names}. *)
