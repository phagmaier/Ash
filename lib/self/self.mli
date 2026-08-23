(** Running the Ash self-interpreter on the host (to-do tasks 2.1 and 2.2).

    [lib/self/eval.ash] is a CPS evaluator for the eleven Core forms, written in
    Ash and open-recursive in the sense of spec §D3. This module is the harness
    that loads it: it lowers the interpreter with the ordinary parser and
    desugarer, evaluates it on the ground evaluator, and applies the interface it
    exports to an encoded term.

    Nothing here is a host escape hatch for the interpreter. The interpreted
    level gets exactly the globals the host level gets, and everything it cannot
    do itself — arithmetic, list operations, output, arity and type diagnostics —
    it does by applying those same primitives through [invoke].

    {1 What agrees and what does not}

    On a program that produces a value, the self-interpreter and the ground
    evaluator agree on the value ({!Encode.reveal} makes the two comparable) and
    on the observable trace. On a program that fails, they agree on the cause
    wherever the failure is one a primitive raises, which is most of them.

    Two boundaries are deliberate and tested rather than papered over:

    - {b Locations.} An encoded term carries no spans, so a failure the
      interpreted level raises is reported wherever in [eval.ash] it was raised.
      Spans cross when [Code] does, in Phase 3.
    - {b Failures this level detects itself.} Ash cannot construct a structured
      error, so an arity mismatch on an interpreted closure, a reused
      continuation, an unbound identifier, and reifier application are reported
      as {!Ash_core.Error.No_matching_clause} naming the condition instead of as
      the host's cause. *)

open Ash_core

val source : string
(** The interpreter's text, exactly as [lib/self/eval.ash] holds it. *)

val load :
  ?extra:string ->
  globals:(Ident.t * Value.value) list ->
  unit ->
  Value.value
(** Lower and evaluate the interpreter with [extra] appended as further
    statements, and answer the value of the whole program — which is [extra]'s
    last expression. [extra] defaults to ["interpret"], so the default answer is
    the interpreter's entry point. Appended statements see [eval], [apply],
    [eval_list], and [interpret], which is how a test installs a wrapper around a
    group member without this module having to reach inside. *)

val call : Value.value -> Value.value list -> Value.value
(** Apply an Ash value to arguments on a fresh default machine. *)

val eval : globals:(Ident.t * Value.value) list -> Core.t -> Value.value
(** Interpret [term] over [globals], and reveal the answer. [globals] must be the
    same list the term's identifiers were resolved against —
    {!Ash_runtime.Primitives.globals} allocates fresh identities on every call, so a term resolved against one list
    is not resolved against another. *)

val file : string
(** The file name diagnostics from the interpreter's own source carry. *)
