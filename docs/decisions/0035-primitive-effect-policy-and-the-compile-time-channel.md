# 0035 — Primitive effect policy during specialization, and the compile-time channel

Status: accepted. Task 7.1. Spec §D7, §8's Phase 7.

Builds on: 0009 (the classified primitive registry, which deferred `static_log`
to "when there is a collapser"), 0028 (partially static data and the
observation signature), 0029 (the collapse report).

## Context

§D7's trap is that folding is contagious. Every primitive with static arguments
looks foldable, and `print("hello")` has a static argument. Fold it and
*compilation* prints while running the compiled program is silent — a compiler
that is wrong rather than slow.

The classification (ADR 0009) already answered *which* primitives may run at
specialization time: `Effect_class.may_fold_when_static` is true only for
`Pure`, and `Stage_value.may_fold` consults it. Two things were nevertheless
unfinished.

**The guarantee rested on rule order rather than on structure.**
`always_residualizes` existed, was documented as D7's absolute, and had no
caller: the property held because the *one* fold path happened to consult
`may_fold`. Task 6.4 then added a second fold path — `static_reading`, which
folds `tower_depth()` and never consults `may_fold` at all. That one is
harmless (`tower_depth` is `Reflection`), but the shape of the near-miss is the
point: the next such rule inherits no protection, and "we checked the classes in
the rule we wrote" is not a guarantee about a function.

**There was no honest alternative to reach for.** §D7 says compile-time logging
gets its own primitive rather than overloading `print`. ADR 0009 agreed and
deferred it, correctly, because nothing specialized yet. Now something does, and
a user who wants to see what the specializer did has only `print` to reach for —
which is exactly the pressure that produces the bug.

## Decision

### The gate is structural

`Staged_eval.apply_primitive` checks `Effect_class.always_residualizes` in lift
mode **before** any rule that could fold — before `static_reading`, before
`may_fold`. A class that always residualizes cannot reach a fold path, whatever
is added below.

This is deliberately redundant with `may_fold` today. The redundancy is the
feature: it converts "specialization emits no program-visible output" from a
property of the current rule set into a property of the function, and the test
suite pins that it does real work. With the observable class deliberately
mis-marked as foldable, the gate holds the criterion; with the gate removed, the
same mis-marking makes compilation print.

### `static_log`, and a sixth class for it

`Effect_class.Specialization_only` is the inverse of `Observable_effect` rather
than a weaker form of it: that class may never *run* at specialization time,
this one may never *survive* it. A separate class, not a special-cased name, so
the specializer keeps reading policy off the class.

`static_log` is its only member:

- `may_fold_when_static` is true for it, so it runs when the specializer meets
  it; its argument is `Observation.Unobserved`, so a dynamic argument is logged
  as the code it stands for rather than being a reason to refuse. That is the
  useful answer at specialization time.
- It contributes `Unit` and no residual call, so the compiled program neither
  logs nor pays for it.
- It writes to `Primitives.log`, a **second stream**, never to `Primitives.io`.

The second stream is the load-bearing part. Had the log shared `io` with a tag,
"the program printed nothing" would have become "the program printed nothing
once you filter", and a test one refactor away from not filtering is not a
guarantee. Nothing in the language can read the log; no equivalence claim
consults it.

### What running it without a specializer does

Nothing observable. The ground evaluator applies `static_log` like any other
primitive, so it writes to the log stream — which has no echo, is not program
output, and is cleared per measurement phase. So a plain run is silent, a
measured run shows the specialization phase's entries in the report, and source
and residual runs agree on every trace anything compares.

### Allocation and mutation

Unchanged and now pinned: `cell_new`, `deref`, `cell_set`, and the
open-recursion trio residualize, because `may_fold_when_static` is false for
their class. Task 7.2's store discipline is what may later make some of them
static, and it will do so by earning it, not by reclassifying.

## Alternatives

**Leave `always_residualizes` unused.** Rejected: the predicate documented a
guarantee nothing enforced, and 6.4 had already added a fold path that bypassed
the rule which happened to enforce it. A dead policy predicate beside a live
near-miss is worse than no predicate.

**Give `static_log` the `Pure` class.** Rejected: it is not pure, and the class
is what the oracle and the collapser read. Pure would make it foldable for the
right reason and unclassifiable for the wrong one.

**Tag log events inside `Io` instead of a second stream.** Rejected above: the
criterion has to stay a statement about one stream with nothing filtered out.

**Make `static_log` a no-op under ordinary evaluation.** Considered. It would
make source and residual runs symmetric in the log as well as in the output.
Rejected as machinery for no gain: the primitive would need the mode it is
running under, which no primitive currently receives, to buy symmetry in a
stream no claim compares.

## Semantic consequences

- No program's meaning changes. `may_fold` already refused every observable
  primitive, so the gate re-decides nothing that was decided differently before;
  every collapse-report counter, the 73-sample criterion, and the depth results
  are numerically identical.
- The registry grows to 50 primitives, so a materialized level has 50 global
  cells rather than 49 (`test/golden/collapse.expected` re-pinned).
- The report gains a `Specialization log:` line beside `Specialization output:`.
  Reporting the compile-time channel beside the output it replaces is what makes
  the honest alternative visible at the point of temptation.

## Test impact

- New `test/unit/effect_policy_test.ml`: for `print`, `println`, `read_line`,
  and effect-beside-a-fold and two-effects-in-order programs — specialization
  wrote nothing, the call survives into the residual, and running the residual
  produces the effect in order; `cell_new`/`deref`/`cell_set` survive
  specialization; `static_log` runs at specialization time, writes only to the
  log, leaves no residual call, and still logs under a lambda where its argument
  is dynamic; the observable and compile-time classes are pinned exhaustively so
  a new member cannot be added without a decision here.
- `test/unit/data_model_test.ml` and `test/unit/primitives_test.ml`: the class
  enumeration is six, the two policy predicates are pinned to their exact class
  sets, and `static_log` is added to the independently written classification
  and arity tables.
- `test/golden/collapse.expected`: re-pinned for 50 global cells per level and
  the new report line. No other counter moved.
