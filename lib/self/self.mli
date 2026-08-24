(** Running the Ash self-interpreter on the host (to-do tasks 2.1 and 2.2).

    [lib/self/eval.ash] is a CPS evaluator for the eleven Core forms, written in
    Ash and open-recursive in the sense of spec §D3. This module is the harness
    that loads it: it lowers the interpreter with the ordinary parser and
    desugarer, evaluates it on the ground evaluator, and applies the interface it
    exports to a term carried as real [Code].

    Nothing here is a host escape hatch for the interpreter. The interpreted
    level gets exactly the globals the host level gets, and everything it cannot
    do itself — arithmetic, list operations, output, arity and type diagnostics —
    it does by applying those same primitives through [invoke].

    {1 Comparison boundary}

    On a program that produces a value, the self-interpreter and the ground
    evaluator agree on the value ({!reveal} makes identity-bearing host and
    interpreted values comparable) and on the observable trace. Source spans
    cross the level boundary with [Code]. The interpreter delegates
    applications through the source-preserving primitive protocol and raises its
    own closed set of structured evaluator causes at the subject node, so host
    and interpreted failures agree on both cause and location. *)

open Ash_core

val source : string
(** The interpreter's text, exactly as [lib/self/eval.ash] holds it. *)

val program :
  ?extra:string -> globals:(Ident.t * Value.value) list -> unit -> Core.t
(** The interpreter lowered to Core, with [extra] appended as further statements.
    [extra] defaults to ["interpret"], so the term's value is the interpreter's
    entry point. Appended statements see [eval], [apply], [eval_list], and
    [interpret], which is how a caller installs a wrapper around a group member
    without this module having to reach inside. *)

val load :
  ?extra:string ->
  globals:(Ident.t * Value.value) list ->
  unit ->
  Value.value
(** {!program}, evaluated on the ground evaluator. *)

val call : Value.value -> Value.value list -> Value.value
(** Apply an Ash value to arguments on a fresh default machine. *)

val reveal : Value.value -> Value.value
(** Replace host closures, reifiers, and continuations with the symbolic tags
    returned by the interpreter's own [reveal], recursively through lists. *)

val interpreting :
  ?extra:string -> globals:(Ident.t * Value.value) list -> Core.t -> Core.t
(** The term that interprets [term]: the interpreter applied to [Code term] and
    its Code-keyed primitive globals, with both written into the term rather
    than passed beside it. The result is an ordinary Core term, so it can itself be
    the program a further layer interprets — which is what makes {!eval} with
    [~layers:2] mean the interpreter running under itself. *)

val eval :
  ?layers:int -> globals:(Ident.t * Value.value) list -> Core.t -> Value.value
(** Interpret [term] through [layers] layers of the self-interpreter (one by
    default; zero is the ground evaluator) and answer the revealed result. A
    caller that wants one particular layer patched builds the nesting itself out
    of {!interpreting}, since which layer carries the patch is the whole question
    a depth test is asking. [globals] must be the same list the
    term's identifiers were resolved against —
    {!Ash_runtime.Primitives.globals} allocates fresh identities on every call,
    so a term resolved against one list is not resolved against another.

    Layers cost what nesting an interpreter costs: layer 2 is the ground
    evaluator running the interpreter running the interpreter running the
    program, so it is far slower than layer 1 and belongs on small programs. *)

val file : string
(** The file name diagnostics from the interpreter's own source carry. *)
