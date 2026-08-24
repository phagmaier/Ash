# 0016 — The CPS Core evaluator written in Ash

- **Status:** accepted, amended in part by
  [0017](0017-interpreter-layers.md) and superseded for term transport and
  diagnostics by [0021](0021-real-code-self-interpreter.md)
- **Date:** 2026-08-23
- **Task:** 2.2

## Context

Task 2.2 asks for the self-interpreter: a CPS evaluator for the eleven Core
forms, written in Ash, parallel to the host evaluator, matching it on the
ordinary corpus. Spec §6 sketches it and calls it the centre of the project.
AGENTS is explicit about how gaps are to be closed: *resolve missing language
support as a Core form or desugaring, never a host escape hatch*.

The sketch in §6 assumes two things Phase 2 does not have. It matches on Core
constructor patterns (`Lit(c)`, `Var(x)`, …), which parse but do not lower until
Phase 3, and it reads its subject as code, which needs `Code` and quotation —
also Phase 3. So the question this record answers is what the interpreter reads
and what its values are, given that quotation has not arrived.

As of task 3.1, ADR 0018 supplies both Code construction and constructor-pattern
lowering, but deliberately does not rewrite this interpreter. Checklist task 3.5
owns replacing `Ash_self.Encode` after the rest of the Code foundation lands, so
the Phase 2 layer tests remain an independent check while 3.1 is introduced.

## Decision

**The interpreter lives in `lib/self/eval.ash` and is ordinary Ash.** It is
parsed by the same parser, lowered by the same desugarer, and run on the ground
evaluator. The library `ash.self` is the harness around it: the encoding, and a
loader that appends further Ash statements so a test can install a wrapper on a
group member without the harness reaching inside.

**A Core term arrives as tagged lists, not as `Code`.** `Ash_self.Encode` writes
each form as `['form, …]`, and an identifier as `[name, id]` — printed name plus
unique id, so hygiene survives the round trip (§D1). The id is opaque to the
interpreter, which only ever compares encoded identifiers, so the gensym counter
stays an excluded observation (AGENTS invariant 10). When `Code` exists, this
encoding is what it replaces; until then, a data encoding is the honest way to
say that the level below has not been built yet.

**The interpreted value domain is Ash's own, with a private tag for the values
this level constructs.** Scalars, lists, cells, and primitives represent
themselves, so a primitive can be handed one directly and arithmetic needs no
marshalling. Closures, reifiers, and continuations are lists whose head is `TAG`,
a cell the interpreter allocates and nothing else can reach — an interpreted
program cannot forge one, because it has no way to name `TAG` and every cell it
can allocate is a different cell. (Primitives were tagged too when this record
was written; ADR 0017 unwraps them, because a wrapped primitive does not survive
a second layer of interpretation.) Each closure and reifier carries a fresh cell
as its identity, so `==` on two of them compares places rather than shapes, which
is what the host means by "two closures with the same body are still two
closures".

**Dispatch is on the form tag, not on constructor patterns.** §6's `match e {
Lit(c) -> … }` needs Phase 3. An `if` chain over the tag is the same dispatch
written in what Phase 2 has; when constructor patterns lower, rewriting the chain
is mechanical and the tests do not move.

**Two primitives were added rather than worked around.**

- `invoke(f, args)` applies a callee to an argument list whose length is only
  known at run time. Core `App` has a fixed number of argument positions, so an
  evaluator's `apply`, which has built a list, cannot spread it. This is §6's
  `prim_apply`. It is in the control class: its class is its callee's, and its
  callee is a value, so nothing about its arguments being static says whether
  running it at specialization time is sound. A specializer that learns the
  callee rewrites it to a direct application under a bespoke rule; one that does
  not, residualizes it. That is the treatment `callcc` already gets.
- `list?` is the one type test. The interpreter has to distinguish an interpreted
  closure — a tagged list — from an interpreted scalar, and every other list
  operation refuses a non-list rather than answering. A predicate that answers is
  a different thing from an accessor that refuses, and only a predicate can
  choose a branch.

Both are registry entries, not host special cases: the interpreted level receives
exactly the globals a level-0 run receives, and everything it cannot do itself it
does by applying those same primitives.

**Delegating to the host is what keeps the diagnostics honest.** Arity, type,
and arithmetic failures are the host's, raised by the same primitive with the
same cause, because the interpreter applies the real primitive through `invoke`
instead of restating its rules. Applying a non-callable is delegated the same
way, so it refuses in exactly the host's words. The one primitive that cannot be
delegated is `callcc`: the host would capture the interpreter's continuation
instead of the interpreted program's, so the interpreted level implements it,
building its own one-shot continuation with a `used` cell marked before transfer.

**Two boundaries are declared rather than papered over.**

- *Locations.* An encoded term carries no spans, so a failure raised at the
  interpreted level is reported wherever in `eval.ash` it was raised. The
  differential test therefore compares value, cause, and trace, and not location.
  Spans cross when `Code` does.
- *Failures this level detects itself.* Ash cannot construct a structured error —
  a cause carries a span, and there is none to give — so an arity mismatch on an
  interpreted closure, a reused continuation, an unbound identifier, and reifier
  application report as `No_matching_clause` naming the condition. The four
  corpus programs this affects are listed in the test, and the list is asserted to
  be exactly the set that needs it: a program that starts agreeing fails there
  rather than sitting under an exemption nobody rechecks.

An `error` primitive that constructed arbitrary causes would close the second
boundary today. It is not added: the missing thing is the span, not the cause,
and a primitive that fabricated one would make every interpreted diagnostic point
somewhere untrue.

## Alternatives

- **Waiting for Phase 3 and reading real `Code`.** Rejected: it inverts the
  checklist, and the encoding is small enough that replacing it later is a
  contained change. Writing the interpreter now is also what stress-tests the
  surface language, which is the reason the surface language exists.
- **Dispatching `prim_apply` by primitive name over a 26-way chain in Ash.**
  Avoids `invoke`. Rejected: it restates the registry inside the interpreter,
  and the two would drift; arity errors would become the interpreter's own
  diagnosis rather than the host's, losing agreement on most of the error corpus.
- **A host wrapper that spreads an argument list for the interpreter.** Exactly
  the host escape hatch AGENTS rules out, and it would be invisible to the
  collapse report, which has to see the application.
- **Tagging every interpreted value, including scalars.** Unambiguous without a
  private tag, but it means marshalling at every primitive boundary — deep, for
  lists — and every line here is paid for once per tower level.
- **Leaving scalars and lists untagged and discriminating by a symbol head.** An
  interpreted program could then build a list that reads as a closure. The
  private cell costs one allocation and closes it.
- **Comparing only successful programs.** Rejected: the error corpus is where two
  evaluators most easily drift, and delegation makes most of it comparable for
  free.

## Semantic consequences

- The interpreted level's answer is compared through `Encode.reveal`, which
  replaces each value the interpreted level constructs for itself with its tag. An interpreted closure is
  not a host closure and never could be; cells, code, and environments are left
  alone, so a program that returns one is asking a question this encoding cannot
  answer, and the comparison fails rather than answering it wrongly.
- Both levels write to the same observable stream through the same primitives, so
  traces are compared, not assumed. Printing an interpreted closure would print
  its tagged list rather than `#<closure>`; nothing in the corpus does, and the
  difference is the same one `reveal` exists to name.
- `Quote` answers the encoded term at the interpreted level and a `Code` value at
  the host. That divergence is asserted as a boundary, not smoothed over.
- At task 2.2 the registry was 31 primitives. Task 3.1 adds five Pure Code
  operations, bringing the current registry to 36; `Effect_class.Control` is
  still `callcc` and `invoke`, and `Effect_class.Reflection` remains honestly
  empty until closed-code execution and the tower.

## Test impact

`test/differential/corpus.ml` now holds the corpus, and both differential tests
read it, so the second comparison cannot quietly run against easier programs than
the first. `test/differential/self_host_test.ml` compares the host evaluator and
the self-interpreter over all 91 corpus programs plus four output programs and
four control programs — the two areas the oracle refuses, and therefore the two
the existing corpus could not exercise. The harness was checked by reversing
`eval_list`'s order in `eval.ash` and confirming it produced a readable minimal
difference on exactly the two evaluation-order programs.

`test/laws/open_recursion_test.ml` (ADR 0015) exercises the interpreter through
its group cells, which is the other half of what it is for.

## Required spec or measurement changes

Spec §6's sketch is pseudo-code for the shape of the interpreter, and the shape
is what `eval.ash` has: same forms, same order, same CPS, same open group. Two
things in the sketch are deferred rather than implemented — constructor patterns,
and reading the subject as code — and §6 now says so and points here. No
semantics changed.
