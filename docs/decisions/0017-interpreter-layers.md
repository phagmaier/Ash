# 0017 — Composing layers of the self-interpreter

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 2.3
- **Amends:** 0016 (the interpreted representation of a primitive)

## Context

Task 2.3 asks for layers 1 and 2 of the self-interpreter plus the spec's
patch-depth fixture, accepting when all layers agree and recursive evaluation
remains patchable. Layer 2 means the interpreter interpreting the interpreter
interpreting a program.

Task 2.2 left the interpreter reachable only as a host application: `Self.eval`
loaded it, then applied the resulting closure to two host values. Nothing about
that composes — a host value is not something a second layer can be handed,
because the thing a layer interprets is a *term*.

## Decision

**A layer is a term transformer.** `Self.interpreting term` builds the Core term
that interprets `term`: the interpreter applied to the encoded program and the
encoded globals, with both arguments written *into* the term rather than passed
beside it. The result is an ordinary Core term, so it is itself something a
further layer can interpret, and layer *n* is *n* applications of one function.

Writing a value into a term needs `Encode.datum`, which answers a Core term that
evaluates to a given value. Core literals hold constants only, so the two shapes
that are not constants are built: a list becomes a call of `list`, and a
primitive becomes a reference to the global that denotes it.

**A primitive crosses levels unwrapped.** ADR 0016 said closures, reifiers,
continuations, *and primitives* were tagged lists. The first three still are; a
primitive is now represented by itself. Layer 2 is what forced the change and is
the reason the difference matters.

A wrapped primitive does not survive a second level. `Encode.datum` writes a
primitive as `Var`, and a `Var` is resolved by whatever level evaluates it — so
at layer 2 the "operation" reaching the bottom level would be the middle level's
*wrapper*: a list, not something applicable. Unwrapped, `invoke` reaches the same
primitive however many levels it passed through, because at every level a value
that is not a tagged list is passed to the level below unchanged.

Three things fall out, all improvements:

- The `'prim` case in `apply` disappears. A primitive is not tagged, so it takes
  the branch that delegates to the level below, which is exactly what applying a
  primitive means.
- `callcc` is recognized **by value** rather than by a name carried in a wrapper:
  `f == callcc`, with `callcc` the interpreter's own binding. Primitives compare
  by name, so a program that renames `callcc` is still caught and a program that
  shadows it with its own function is correctly not.
- `Encode.reveal` no longer maps a primitive to a tag. Both levels hold the same
  primitive and primitives compare by name, so a program that returns one is now
  comparable instead of merely tagged alike.

**Which programs run at layer 2 is decided by a step budget, not by a clock.**
Layer 2 costs the product of two interpretations. A program is compared at layer
2 when its layer-0 run takes at most 800 evaluator steps — a deterministic
property of the program, not of the machine the suite runs on, as AGENTS requires
of budgets. Today that admits 98 of the 99 programs; the one it excludes is the
ten-thousand-iteration loop, and the test prints its step count so a change in
either direction is visible rather than silent.

**Layer 3 is not tested.** It runs — `Self.eval ~layers:3` is the same
function — but takes about two minutes on the smallest useful program, which is a
suite that nobody runs rather than a stronger claim. The interesting step is 1 to
2, where the encoding first has to survive being applied to the interpreter's own
lowering; 2 to 3 repeats it.

## Alternatives

- **Keeping the host-application entry point and special-casing layer 2.** It
  would need a way to inject two host values into a term, which is `Encode.datum`
  again, and a second code path that the ordinary case does not exercise.
- **Keeping primitives wrapped and unwrapping per level.** The interpreter would
  have to know how many levels down it is running, which is exactly the
  information a level does not have and, under §D9, should not need.
- **Giving each level cloned primitives of its own.** That is task 4.1's cloned
  globals, and it is about identities, not about representation: the values are
  shared deliberately so that output is one stream for the whole tower. It would
  not have made a wrapper applicable.
- **Selecting layer-2 programs by hand.** Rejected: a hand-picked list drifts
  toward the programs that pass, which is the failure mode sharing `corpus.ml`
  exists to prevent.
- **Selecting them by wall time.** Rejected outright by AGENTS, and it would make
  which laws are checked depend on the machine.

## Semantic consequences

- Every layer answers the same value and leaves the same trace. That is now a
  tested law rather than an expectation, and it is a stronger statement than
  layer 1's agreement: layer 2 only passes if the encoding survives being applied
  to the interpreter's own lowering and if a primitive handed down twice is still
  applicable.
- A layer's `eval` cell governs the evaluation *that layer* performs. Patching
  the layer that runs the program observes the program's thirteen nodes whether
  that layer is running on the host or being interpreted itself; patching the
  layer beneath it observes the interpreter's own execution — some 3500 steps for
  the same fixture. Same fixture, same answer, different subject.
- The interpreter is four lines shorter and has one less concept in it, which
  matters because every line is paid for once per tower level.

## Test impact

`test/differential/self_layers_test.ml` compares layers 0, 1, and 2 on all 91
corpus programs plus eight written for this record — output and control, which
are the two things most likely to be lost on the way down a second level, and
closures and primitives as values, which are what `reveal` and the unwrapping
decision are about. It was checked by re-wrapping primitives in `eval.ash`, which
left layer 1 almost entirely passing and broke layer 2 across the board — the
difference the layer is there to find.

`test/laws/open_recursion_test.ml` gains the patch-depth fixture: §D3's program
with the patch on the layer that runs it (thirteen nodes, exactly the count at
depth 1), on the layer beneath it (two orders of magnitude more), and on `apply`
and `eval_list` at depth, whose counts — four applications and twelve
`eval_list` calls — say which steps they are.

## Required spec or measurement changes

Spec §5.7's open-recursion law is now checked at arbitrary depth, as it asked to
be in Phase 2, and its checkbox is ticked. §6 already records that the subject
arrives as data; nothing about the tower's semantics changed.
