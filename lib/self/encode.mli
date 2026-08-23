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
(** The level below's global bindings, as a list of [[identifier, name, op]].
    Only primitives can cross: a binding whose value is not a primitive has no
    interpreted counterpart and is refused rather than encoded as something the
    interpreter would misread.
    @raise Invalid_argument on a non-primitive binding. *)

val reveal : Value.value -> Value.value
(** What the interpreter's own [reveal] does to a host value: replace each value
    that carries identity — a closure, reifier, continuation, or primitive — with
    its tag, and recurse through lists. This is what makes the two evaluators'
    answers comparable at all, since an interpreted closure is not a host one.
    Cells, code, and environments are left alone: they compare by identity, so a
    program that returns one is asking a question this encoding cannot answer,
    and answering it wrongly would be worse than the comparison failing. *)
