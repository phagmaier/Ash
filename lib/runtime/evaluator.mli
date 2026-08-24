(** The real evaluator: Core in continuation-passing style.

    This is the production evaluator, not a variant of the oracle. It is in CPS
    from the start because a reflective procedure receives the continuation of the
    level below, and in direct style that continuation lives on the host stack
    where nothing can reach it (spec §D2). Every recursive call goes through the
    machine's open-recursion cells, so a meta level that replaces [eval]
    intercepts every nested step (§D3).

    All eleven Core forms are dispatched. [Quote] yields the code as a value and
    [Reifier] yields a reifier value.

    {e Applying} a reifier is the up half of the tower protocol (spec §5.4), and
    it happens in [App] rather than in [apply]: the arguments are not evaluated,
    so the decision needs the whole call expression, which an applier never sees.
    The call, the caller's environment, and the caller's one-shot continuation
    become values, and the reifier's body runs on the machine of the level above,
    which {!Ash_tower.Tower} materializes on demand. The body keeps the lexical
    environment the reifier was written in — the machine changes, the meaning of
    free identities does not — and runs under the identity continuation, so a
    body that never resumes gives its own value as the answer of the run.

    The [reflect] primitive is the down half: it evaluates Code on the machine
    below and transfers to a continuation captured there. Its result is the
    result of the reifier body, so the identity reifier is the identity function,
    effects included.

    A machine with no tower installed ({!Machine.levels}) is the base program and
    nothing else: applying a reifier and reflecting are both refused with
    {!Ash_core.Error.Unsupported} naming the missing level rather than
    materializing one no tower knows about. Applying a reifier to values that are
    already computed — through [invoke], say — is refused for the same reason: it
    has no whole call to reify.

    Every error carries the level of the machine that raised it, counted from the
    base program (spec §D9). An error inside a reifier body belongs to the level
    above and never resumes the level below; the same error in reflected code
    belongs to the level that evaluated it.

    Applying a continuation transfers to it. It takes exactly one value, and it
    is one-shot: the used flag is set {e before} the transfer, so a continuation
    reached again through its own resumption is caught rather than looping, and a
    second invocation raises {!Ash_core.Error.Continuation_reuse} naming where the
    continuation was captured and where it already went (spec §D4).

    [lift] converts only the fixed scalar, unit, immutable-list, and Code domain.
    Non-empty lists refer to the current machine's exact hygienic [list] global;
    rejected values raise {!Ash_core.Error.Unliftable_value} with their nested
    data-origin path (spec §D6).

    The dynamic semantics are the ones ADR 0007 fixed for the oracle: the function
    position is evaluated first, then arguments left to right; [If] requires a
    boolean; [Set] evaluates to unit. Agreement with the oracle on the pure corpus
    is a tested law, not an aspiration.

    Ash tail calls pass the continuation through unchanged and every host call is
    in tail position, so a tail-recursive Ash loop runs in constant host stack. *)

open Ash_core

val machine : unit -> Machine.t
(** A machine with the default evaluator group installed. *)

val run : Machine.t -> env:Value.env -> Core.t -> Value.value
(** Evaluate to completion with the identity continuation, leaving the machine's
    counters to be read afterwards. [env] is also installed as this evaluation's
    explicit global environment: [lift] resolves hygienic list construction and
    [run] executes closed Code there, never in a lexical frame introduced while
    evaluating [Core.t]. *)

val eval : env:Value.env -> Core.t -> Value.value
(** Convenience for callers with nothing to ask the counters. *)
