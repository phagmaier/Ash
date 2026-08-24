# 0032 — Specialization budgets and generalization

Status: accepted. Task 6.2. Spec §7.5, §7.4 step 2.

## Context

Task 6.1 stops the unroller when it meets a key it is already inlining. That
covers recursion whose static projection stops changing — the common case, and
the one that made dynamically controlled recursion specialize at all.

It does nothing for recursion that never repeats a key. An accumulator that
conses a longer list every step, or a counter walking away from its base case,
presents something new each time and there is no cycle to find. ADR 0031 named
both as the remaining edge.

§7.5 says what to do: a depth/size cutoff, and on exceeding it, **generalize** —
mark an argument dynamic — and retry. It also says to instrument every
generalization, because a program that collapses without generalizing is a much
stronger result than one that does.

## Decision

### The budget

Two deterministic limits, never wall time:

| Limit | Watches | Default |
| --- | --- | --- |
| `max_inline_depth` | nested calls the unroller has followed into **one** function | 25,000 |
| `max_residual_bindings` | residual bindings emitted so far, across every block | 50,000 |

Depth is counted per function identity, so a program that nests many different
functions is not mistaken for one going nowhere.

The size limit is the more discriminating of the two, and the reason it is
phrased in emitted bindings rather than steps or nodes: **an unrolling that is
working folds, and emits nothing.** The corpus's deepest static unrolling is a
10,000-step tail-recursive loop that collapses to a single literal and emits no
bindings at all. An unrolling that is not making progress emits at every step.
The budget can therefore distinguish the two without a whistle, an embedding
test, or any analysis of the values involved.

The defaults are set to leave the entire corpus alone, and
`collapse_criterion_test.ml` now asserts that all 73 samples specialize with
**zero** generalizations. §7.5's own argument is why: a budget that generalized
a program the specializer could have decided would make every collapse result
weaker for no reason. These are the sizes at which the specializer stops
believing it is making progress, not sizes a correct program is expected to
reach.

The budget is configuration, not run state: `Specialize.reset` leaves it alone,
and `Metrics.measure` takes an optional `?budget` that it restores afterwards.

### Generalization

On pressure, the call stops being inlined and becomes a specialization point —
after giving up one more argument, when there is one to give up.

**Which argument.** The leftmost position whose projection *differs* from the
nearest enclosing call to the same function, because that is what the unrolling
is following. Failing that (the budget was reached for some other reason), the
leftmost the specializer still knows. Positions already dynamic are not
candidates: there is nothing left to give up there.

**One at a time.** §7.5 says *progressively*, and it matters: a `rev(xs, acc)`
whose list shrinks while its accumulator grows is driven by both arguments, so
one generalization is not enough. The second call generalizes the second
argument, and only then is the key fixed.

**Sticky, and monotone.** The decision is recorded against the function's
identity and applies to every later call. A generalization that applied only to
the call that triggered it would be undone by the next one and the unrolling
would resume. Because it is also monotone, this terminates: a function with *k*
parameters can be generalized at most *k* times, after which its key is constant
and the next call must find the memo table.

**Nothing left to give up is not an error.** When every argument is already
dynamic the key is as coarse as it gets, and a specialization point under it
ties its own knot. So the pressure path always produces a point and never fails.

### Where the budget can still only refuse

Reifying a closure specializes its body, which may reify further closures. That
nesting is not a call: it has no key to memoize and no argument to generalize.
A closure that reaches a dynamic position inside its own reified body — `loop =
fn(g) -> g(loop)` — would do it forever. `max_inline_depth` bounds the
reification nesting too, and exceeding it raises a new structured error,
`Error.Budget_exhausted { what; limit; callee }`, naming the budget, the limit,
and the function. This is the only place specialization gives up rather than
generalizing, and it is why the cause exists.

## Alternatives

**A homeomorphic-embedding whistle** (the standard online-PE termination test).
Rejected for now: it is a substantial piece of machinery whose benefit here
would be catching runaway unrollings a few steps earlier than a size budget
does. The size budget already separates productive unrolling from unproductive
by a property that is exactly right — whether anything is being emitted — and it
costs one counter.

**Growth detection on argument values** (generalize a position whose value got
bigger). Rejected: it is only sound for *structural* size. The corpus's
10,000-step loop has an accumulator whose *number* grows at every step and which
must not be generalized, because the whole computation folds. A rule that looked
at magnitude would destroy that result; a rule that looked only at structure
would miss the counter cases anyway. Difference from the nearest ancestor is
cheaper and does not have to decide what "bigger" means.

**Failing when the budget is exhausted at a call.** Rejected: a call whose
arguments are all dynamic can become a specialization point and terminate on its
own, so failing there would reject programs the specializer can handle.

**A left-to-right generalization order.** Kept only as the fallback. Choosing by
difference from the enclosing call points at the argument actually driving the
recursion, which is usually the accumulator or counter rather than the first
parameter.

## Semantic consequences

- Generalizing never changes what a residual computes: an argument the
  specializer knew becomes one the residual program is passed, reified through
  the same boundary conversion every other dynamic argument uses.
- A generalized residual is *larger and slower* than an ungeneralized one would
  have been, which is exactly why the report counts them.
- Nothing in `Identity` mode changes.
- `Error.Budget_exhausted` is a specializer diagnostic, not a program error: the
  program is fine and running it is unaffected.

## Test impact

- New `test/unit/stage_budget_test.ml`: a growing accumulator, a counter walking
  away from its base case (whose source diverges, so what is asserted is that
  staging terminates and says what it gave up), size pressure on an unrolling
  the specializer could otherwise decide, the self-passing closure that
  exhausts, and — the regression that matters — that the default budget
  generalizes nothing on a deep static unrolling or a knot-tying recursion.
- `test/laws/collapse_criterion_test.ml` asserts zero generalizations on all 73
  samples.
- `test/unit/collapse_test.ml` measures a budgeted program and checks both
  reasons, their order, and that they reach the rendered report; and that a
  measurement restores the configured budget.
- `test/golden/collapse.expected` gains "an accumulator too large for its
  budget", the sample where the generalization counter is not zero.
- `test/unit/error_test.ml` enumerates the new cause.

## Measurement changes

`Metrics.specialization.generalizations` stops being a hard-wired zero, and
`generalization_reasons` carries each decision. The report prints them under the
count:

```
  Generalizations:                1
    rev(acc):                     inlining-depth, 6 nested calls to it were already being inlined
```

At most six are shown, then "and N more", so a runaway program cannot bury the
rest of the report. No existing figure moved: every prior sample generalizes
nothing.
