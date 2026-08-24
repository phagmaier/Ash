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
      immutable lists, code construction/observation (including [code_name]),
      [list?], [match_error], and source-directed [raise_at]. Foldable once every
      argument is static; the last two deterministically raise rather than
      return.
    - {!Ash_core.Effect_class.Allocation_or_mutation} — [cell_new], [deref],
      [cell_set], and the open-recursion trio [open_cell], [open_deref],
      [open_set]. Residualized until Phase 7's store splitting says otherwise.
    - {!Ash_core.Effect_class.Observable_effect} — [print], [println],
      [read_line], all of which go through an injectable {!Io.t} so that a trace
      is a value tests can compare.

    - {!Ash_core.Effect_class.Control} — [callcc], which reifies the current
      continuation as a one-shot value and hands it to its argument, [resume],
      which transfers to a continuation a meta level is holding, and [invoke],
      which applies a callee to an argument list whose length is only known at
      run time, with [invoke_at] its source-preserving self-interpreter form.
      None is folded automatically: capturing during specialization would
      capture the specializer's continuation, and invocation's class is its
      callee's, which no amount of knowledge about its arguments settles.

    - {!Ash_core.Effect_class.Reflection} — [lift], which converts only the fixed
      liftable domain to Code using level-hygienic list construction, [run],
      which requires Code to have no unresolved lexical dependencies and
      evaluates it in the current level's explicit global environment, [reflect],
      which drops one level to evaluate Code there and resume a continuation
      captured there, [meta_error], which fails at the level running it, and the
      five readers behind [up]'s meta bindings (spec §5.2): [meta_eval] and
      [meta_apply], the level below's group cells; [meta_global], its global
      environment; [tower_level], the relative level of the caller; and
      [tower_depth], the one explicitly depth-sensitive observation of §D9. All
      are evaluator-dependent and need bespoke specialization rules: each
      answers a question about {e which machine is asking}, which is precisely
      what a specializer running somewhere else may not answer.

    {1 Open recursion}

    [open_cell], [open_deref], and [open_set] are the ordinary store operations
    under different names, and the difference in name is the point. They are what
    an [open fn] group lowers to (spec §D3), so an [open_deref] in a term is one
    evaluator-group dereference and nothing else, and {!open_dereferences} counts
    the ones a run actually performs. The surviving dereferences in a residual
    program are precisely the interpreter residue §9 classifies.

    Immutable Code operations are pure per spec D7; [lift] and [run] are
    Reflection because they cross into or execute a stage using the active
    evaluator level.

    {1 The level a primitive runs at}

    One registry serves the whole tower: the primitive {e values} are shared, so
    a primitive cannot know its level and is told it by the evaluator applying
    it. Four primitives need the number itself. [callcc] stamps the captured
    continuation with the level it resumes, [meta_error] fails at the level that
    ran it, [raise_at] attributes an interpreted level's failure to the level
    running the interpreter, and [tower_level] answers with it. [reflect] needs
    more than the number — the machine below — and gets it as a callback for the
    same reason; [meta_eval], [meta_apply], [meta_global], and [tower_depth] read
    a second callback for the same reason again. [up] itself is not a primitive:
    it is surface sugar over a reifier whose body is extended with those
    readers.

    {1 Errors}

    Arity is checked by whatever applies a primitive, so every arity error reads
    the same wherever it comes from, and it is checked again inside the primitive
    because an implementation is a total function. Argument types are checked by
    the primitive, left to right, matching the order Ash evaluates arguments in,
    and reported at the call site. [invoke_at] and [raise_at] deliberately use
    the span of a Code argument instead, so an interpreted failure points into
    the subject program rather than the evaluator helper. *)

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

val open_dereferences : t -> int
(** How many times [open_deref] read an open-recursion cell, counted across this
    registry's whole lifetime. Instrumentation is observationally inert: no
    primitive reads this, so nothing an Ash program computes, prints, or fails
    with can depend on it. *)

val reset_open_dereferences : t -> unit

val all : t -> Value.primitive list
(** Every primitive, in registry order: pure, then allocation/mutation, then
    observable, control, and reflection. *)

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
