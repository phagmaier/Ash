(** The frozen direct-style oracle.

    Around a hundred lines of ordinary recursive evaluation whose only job is to
    say what a pure Core program means, so that the CPS evaluator, the
    self-interpreter, the tower, and every residual program can be checked
    against something independent (spec §D2):

    {v
    for every p in the pure corpus:  Oracle.eval p  =  the real evaluator on p
    v}

    {1 Frozen}

    This module is deliberately never extended. It supports [Lit], [Var], [Lam],
    [App], [Let], [LetRec], [If], and [Set], and refuses [NamedVar], [Quote],
    [Reifier], and any primitive that is not
    {!Ash_core.Effect_class.Pure} — with an {!Ash_core.Error.Unsupported} naming
    what it refused. Its value as an oracle comes entirely from being simple
    enough to believe by reading, and every feature added to it is a feature it
    can no longer independently check.

    Reflective procedures need the continuation of the level below, which in
    direct style lives on the host stack where nothing can reach it. That is why
    the real evaluator is in CPS and this one can never grow up.

    {1 What it is not}

    It carries no instrumentation, no step budget, and no tower level, and it
    recurses on the host stack, so it is unsuitable for deeply recursive programs
    and for anything that must not terminate. Host stack depth is an excluded
    observation, so a comparison that overflows here is a badly chosen test
    rather than a difference between evaluators. *)

open Ash_core

val eval : env:Value.env -> Core.t -> Value.value
(** Evaluate a pure Core term.

    Arguments are evaluated left to right, after the function position.
    [If] requires a boolean: there is no truthiness coercion in Core.

    @raise Error.Ash_error with phase {!Error.Evaluate}. *)
