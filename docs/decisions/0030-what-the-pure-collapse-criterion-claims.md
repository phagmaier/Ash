# 0030 — What the pure Phase 5 criterion claims, and what it leaves to Phase 9

- **Status:** accepted
- **Date:** 2026-08-24
- **Task:** 5.5
- **Builds on:** 0025 (what tower depth means), 0028 (the staged pure fragment),
  0029 (what the report measures)

## Context

Spec §8 states Phase 5's completion as: `collapse(1, p)` for pure `p` behaves as
`p` and contains **zero** Core-constructor dispatch and **zero** surviving
`eval`-cell dereferences. The checklist's 5.5 restates it as "every depth-1 pure
sample is equivalent with zero Core dispatch and zero surviving eval-cell
dereferences".

`collapse(1, p)` admits two readings, and they are separated by an entire phase
of work:

- **(A)** Specialize `p`. Compare the residual against the depth-1 tower run,
  which is where the interpretation the residual does not contain was actually
  performed.
- **(B)** Specialize the depth-1 *configuration* — the interposed evaluator
  together with the program — so that the residual is what is left after the
  tower itself was squashed.

Reading (B) requires the meta `eval` binding to fold when the evaluator's
identity is statically known. That is *static reflective modification*, which
§7.4's fragment ordering puts at step 5 and §8 puts in Phase 9. Phase 5 is
§7.4 step 1: pure higher-order Core, recursion, and immutable data, with no
reflection in the fragment at all. Under reading (B), Phase 5 could not be
completed before Phase 9, which contradicts the spec's own ordering; §8's own
Phase 5 line says "over the pure fragment only (§7.4 step 1)".

## Decision

**Phase 5's criterion is reading (A), and the suite says so in its own header.**

`test/laws/collapse_criterion_test.ml` proves, for each pure sample at depth 1:

1. the source run, the depth-1 tower run, and the residual run agree — on the
   value, on the failure's cause and location, and on the observable trace;
2. the residual contains zero surviving eval-cell dereferences, zero surviving
   evaluator calls, zero Core-constructor dispatch sites, zero residualized
   `NamedVar` lookups, zero reflection boundaries, and no nodes originating in
   any other source;
3. specialization left no observable output;
4. the residual costs no more to run than the source.

**Three things stop this from being a tautology**, because a closed pure program
folds to a literal and a literal trivially contains no dispatch:

- The **premise is asserted**: the depth-1 tower run must have performed the
  interpretation the residual is claimed not to contain — Core dispatches and
  evaluator-cell reads, both greater than zero. Across the suite that is 906,684
  dispatches and 2,125,537 cell reads, against 142 residual nodes containing
  neither.
- **Six samples do not fold to a literal.** Their value is a function of an
  argument the specializer does not have, so the residual still computes; each is
  checked to still be a lambda with a non-trivial body, and equivalence is
  established by *applying* source and residual to the same arguments. Closure
  equality is identity (§D1), so that is the only honest comparison — the report
  refuses to call two closures equal, and so does this suite.
- **The criterion is shown to be falsifiable.** The boundary section runs pure
  programs that *do* leave interpretation behind — an `open fn` group, whose
  dereferences residualize until Phase 7 can reason about the store, and a
  `code_view` on a value the specializer does not have — and requires the
  measurement to report the survival. It also requires those uncollapsed
  residuals to still be *correct*, which is the difference between "not
  collapsed" and "wrong".

**The failure corpus is inside the claim.** A pure program that fails is still a
pure program, and the specializer may fold a certain failure at specialization
time — but only into the failure the program actually has, at the place it has
it. The suite accepts a specialization-time failure exactly when its cause and
span match the source's, and otherwise requires a residual whose run fails
identically.

## What is not claimed

The residual is `p` specialized on its own. The depth-1 figures are
interpretation that a tower performs and this residual does not contain — not
interpretation this residual removed from a tower. Reading (B) remains open work
and its prerequisites are named: task 9.1 (specialize statically known evaluator
changes, inlining known wrappers at former dispatch sites) and, before it, task
6.1's memoized specialization points.

A related prerequisite surfaced while scoping this task and is recorded here so
it is not rediscovered: in lift mode `Quote` residualizes, so a program the
specializer is *holding as syntax* is dynamic to it. A self-interpreter applied
to a known program therefore would not fold — the dispatch would residualize and
the recursion, being dynamically controlled, would not terminate. Distinguishing
a statically known `Code` value from an unknown one is a prerequisite of the
first Futamura projection (§7.6), not of this criterion.

## Alternatives

**Claim reading (B) and defer the evidence.** Rejected: it would report a result
the implementation does not have.

**Prove the criterion only over closed corpus programs.** Rejected: every
residual would be a literal and the zero-dispatch half would hold for the
uninteresting reason. The samples that still compute are what make the claim
about staging rather than about constant folding.

**Compare residual functions by their lambda syntax.** Rejected for the same
reason ADR 0029 rejected it in the report: matching syntax is not agreement, and
saying "agrees" on that basis claims more than was checked.

## Test impact

- `test/laws/collapse_criterion_test.ml` (new): 71 samples at depth 1 — the
  pure corpus's 44 values and 21 failures, plus 6 that still compute — followed
  by the two boundary programs. It prints what the tower performed and what the
  residuals contain, so the suite's output is the result rather than only its
  assertion.
- The suite was checked against deliberate violations before being accepted: a
  program with a surviving `open_deref` fails the criterion, and a residual that
  folds to a literal fails the "still computes" check.
