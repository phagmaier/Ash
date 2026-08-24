# 0025 — What "tower depth" means, and how the laws are tested at it

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 4.4
- **Amends:** 0022 (lazy materialization now has a way to be asked for on
  purpose) and 0017 (an interpreter layer and a tower level are measured
  separately, and this says which one the §5.7 laws use)

## Context

Task 4.4 asks for the §5.7 laws "at depths 0–5", and the first of them —
transparency — is a claim about what a program observes at depth 0 versus depth
k. Before it can be tested, the project has to be able to say what running a
program *at* depth k is. It could not.

`Tower.run` runs at level 0. `Tower.materialize_above` allocates a level. Nothing
ran a program *underneath* n levels, and the two obvious ways to add it are not
equivalent:

- Materialize k levels and run. But ADR 0022 made materialization lazy precisely
  because an unreflected level is observationally indistinguishable from the
  default evaluator, and ADR 0024's inertness fast path made a materialized level
  whose cell is untouched run the identical host function with identical
  counters. Transparency over such a depth is true by construction. The test
  would pass on the day the tower was deleted.
- Use `Self.interpreting` layers. Those are real and already tested at layers 1
  and 2, but ADR 0017 states that a layer is not a tower level, so this would
  answer a different question than §5.7 asks.

## Decision

**Depth means levels that are actually interpreting.**
`Ash_tower.Depth.interpose` writes an Ash closure — `fn(e, r, k) -> base(e, r, k)`
— into a level's evaluator cell, which is what `up { eval := … }` does from
inside the language. Every step of that level is then a *term* the level above
has to evaluate. `Depth.materialize ~depth:k` does this at levels 0 through
k − 1, so `Tower.materialized` is k and every level below k is being run by the
one above it.

**The interposed interpreter is the identity, and that is the point.** It
forwards all three arguments and adds nothing, so anything the transparency law
detects is the tower asserting itself, not the fixture computing something. The
law is that stacking the identity five deep changes no value and no effect;
`docs/progress/0001-depth-cost.md` records that it changes the work by a factor
of five per level, which is what the collapser exists to remove.

**It reads the cell before writing it, so depths stack rather than replace.** At
depth 3 the level-0 cell holds an interpreter whose `base` is the previous one.
This is the same composition ADR 0024 requires of two `up { eval := … }` forms,
and testing it here means the harness exercises it too.

**It lives in `ash.tower`, not in the test directory.** Running a program under a
stated depth is what Phase 6.4 compares normalized residuals across and what
Phase 5's criterion is stated over, so it is a capability of the tower rather
than a fixture of one suite. Keeping it out of the tests also keeps it honest:
the harness is built from `Machine.meta_eval_cell` and ordinary Core, with no
private entry point a program could not have used.

**It is built in Core rather than in surface Ash.** `ash.tower` cannot see
`ash.syntax` — lower layers cannot import higher ones — and inverting that to
write `fn(e, r, k) -> base(e, r, k)` as text would be a dependency added for
readability. The constructed closure is the same term the desugarer would
produce, and `test/unit/up_test.ml` independently covers the surface path.

**Excluded observations are excluded by test, not by omission.** §D9 excludes
timing, host stack depth, resource exhaustion, and gensym counters.
`tower_laws_test.ml` asserts that evaluator work at the top of the tower *does*
vary with depth, so the exclusion is a recorded property rather than a silence,
and a change that accidentally made the interposed levels do nothing would fail
that test rather than quietly strengthen the others.

**Level-0 step counts are asserted invariant, which the law does not require.**
Interposing an interpreter changes who performs the base program's steps, not how
many there are. It is stronger than transparency and cheap, and a drift in it
would mean the interposition had altered the program's own evaluation.

**Depth is budgeted in counted steps.** Cost is `steps × 5^depth`, so a program
is compared at the depths it fits inside a 20 000 000-step budget and the depths
it does not are printed rather than skipped silently. Today exactly one corpus
program — a 310 019-step loop — stops short, at depth 2. No wall-clock timeout is
used anywhere, per AGENTS.md.

## Alternatives

**Define depth as materialized levels.** Rejected above: vacuous by
construction.

**Define depth as `Self.interpreting` layers.** Rejected as an answer to §5.7,
kept as the separate axis it already is. The two measure genuinely different
things — a layer re-implements the evaluator in Ash, a level replaces the running
one — and collapsing them would lose the distinction ADR 0017 was written to
keep. Both remain tested.

**Make the interposed interpreter do something observable, such as tracing.**
Rejected for the harness: an interpreter with an effect of its own would make
transparency false, since the effect stream is exactly what transparency
compares. Tracing interpreters belong in the demos (task 4.5) and in the
open-recursion law, where the count *is* the claim.

**Write the laws over a fresh, small corpus.** Rejected. `test/laws/dune` copies
`test/differential/corpus.ml` instead, so the law suite cannot come to test an
easier set of programs than the differential suites do. The copy is a build rule,
not a duplicate file.

## Consequences

- New module `Ash_tower.Depth` with `interpose`, `materialize`, and `run`.
- `test/laws/tower_laws_test.ml` covers transparency over 96 programs at depths
  0–5, depth observation, open recursion at depth, level independence, reifier
  identity including a step-capped non-terminating argument, error propagation,
  one-shot enforcement, and the excluded observations.
- The suite records one gap rather than hiding it: a primitive's own argument
  diagnostics still carry no tower level, which ADR 0023 deferred deliberately.
  A test asserts the current behaviour, so closing the gap is a visible change.
- `dune runtest` grows by about 20 seconds, almost all of it transparency at
  depths 3–5.

## Test impact

The whole of `test/laws/tower_laws_test.ml`. The laws it proves let five of the
seven §5.7 checkboxes be marked: transparency, open recursion (already marked in
Phase 2, now also at depth), reifier identity, level independence, error
propagation, and one-shot enforcement. Overlay discipline remains unmarked and
belongs to Phase 8's `meta_with`.

## Required spec or measurement changes

The §5.7 checkboxes are updated in `Ash Reflective Tower.md`, each naming the
test that discharges it. No semantics changed. `docs/progress/0001-depth-cost.md`
records the per-level multiplier as a measurement of this harness specifically,
and explicitly does not generalize it into the per-level prediction §9 deleted.
