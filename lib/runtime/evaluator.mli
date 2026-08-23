(** The real evaluator: Core in continuation-passing style.

    This is the production evaluator, not a variant of the oracle. It is in CPS
    from the start because a reflective procedure receives the continuation of the
    level below, and in direct style that continuation lives on the host stack
    where nothing can reach it (spec §D2). Every recursive call goes through the
    machine's open-recursion cells, so a meta level that replaces [eval]
    intercepts every nested step (§D3).

    All eleven Core forms are dispatched. [Quote] yields the code as a value and
    [Reifier] yields a reifier value; {e applying} a reifier needs the level above
    and is task 4.2, refused until then with {!Ash_core.Error.Unsupported} naming
    what is missing rather than pretending it does not exist.

    Applying a continuation transfers to it. It takes exactly one value, and it
    is one-shot: the used flag is set {e before} the transfer, so a continuation
    reached again through its own resumption is caught rather than looping, and a
    second invocation raises {!Ash_core.Error.Continuation_reuse} naming where the
    continuation was captured and where it already went (spec §D4).

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
    counters to be read afterwards. *)

val eval : env:Value.env -> Core.t -> Value.value
(** Convenience for callers with nothing to ask the counters. *)
