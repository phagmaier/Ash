(** Core terms and a level's globals, as ordinary Ash data.

    The self-interpreter reads its subject as data, and quotation is Phase 3, so
    a term reaches it as tagged lists rather than as {!Ash_core.Value.Code}. This
    module is the one place that encoding is written down; {!Ash_self.Self} is
    its only caller, and [lib/self/eval.ash] is the reader that has to agree with
    it.

    An identifier encodes as [[name, id]] — printed name plus unique id, never a
    string alone, so lexical identity survives the round trip (spec §D1). The id
    is opaque: the interpreter compares encoded identifiers and never reads the
    number, which is what keeps the gensym counter an excluded observation
    (AGENTS invariant 10). *)

open Ash_core

val ident : Ident.t -> Value.value
val term : Core.t -> Value.value

val globals : (Ident.t * Value.value) list -> Value.value
(** The level below's global bindings, as a list of [[identifier, op]]. Only
    primitives can cross: a binding whose value is not a primitive has no
    interpreted counterpart and is refused rather than encoded as something the
    interpreter would misread. A primitive crosses unwrapped, which is what lets
    the interpreter run under itself — a wrapped one would arrive at the second
    layer as the first layer's wrapper, a list rather than something applicable.
    @raise Invalid_argument on a non-primitive binding. *)

val reveal : Value.value -> Value.value
(** What the interpreter's own [reveal] does to a host value: replace each value
    the interpreted level constructs for itself — a closure, reifier, or
    continuation — with its tag, and recurse through lists. This is what makes
    the two evaluators' answers comparable at all, since an interpreted closure
    is not a host one. Primitives are left alone because they need no
    counterpart: both levels hold the same primitive, and primitives compare by
    name. Cells, code, and environments are left alone too, but for the opposite
    reason — they compare by identity, so a program that returns one is asking a
    question this encoding cannot answer, and answering it wrongly would be worse
    than the comparison failing. *)

val datum : globals:(Ident.t * Value.value) list -> Value.value -> Core.t
(** A Core term that evaluates to [value]. Core literals hold only constants, so
    a list becomes a call of the [list] primitive and a primitive becomes a
    reference to the global that denotes it — which is how an encoded program and
    an encoded set of globals can be written {e into} a term rather than passed
    beside it, and therefore how one layer of interpretation composes with the
    next.
    @raise Invalid_argument on a value with no such term — a closure, reifier,
    continuation, cell, environment, or code — or if [globals] does not bind
    [list] or a primitive the value mentions. *)
