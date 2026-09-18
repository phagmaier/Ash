# 0042 — Primitive diagnostics carry their level

- **Status:** accepted
- **Date:** 2026-09-18
- **Tasks:** review repairs
- **Builds on:** 0009, 0014, 0023

## Context

ADR 0023 deferred threading the level through primitive argument diagnostics:
a primitive's type and domain errors carried no level, and "nothing in the
tower laws depends on it yet." The tower-law suite pinned the gap with a
tripwire test asserting `level = None`, stating that taking up the deferred
item is what fails first. The post-release review found the same gap
independently (a type error raised inside a level-1 reifier body reported
nowhere instead of level 1) and took it up.

## Decision

Every failure a primitive raises carries the level of the evaluator that ran
it. `fail`, `type_error`, `wrong_arity`, and the argument accessors in
`lib/runtime/primitives.ml` take the applying level; the nullary/unary/binary
wrappers and every bespoke implementation pass it through. Implementations
that cannot fail keep ignoring it explicitly (`~level:_`), as ADR 0023
already requires. The oracle is unchanged: it has no tower level, so its
`None` stays honest rather than becoming a fictitious `Some 0`.

## Limits

Rendering is unchanged at level 0 (`None` and `Some 0` both stay silent), so
no golden output moves. `Metrics.agreement` compares failures by cause and
source span only, so cross-run equivalence is unaffected. `Error.equal`
remains level-sensitive by design: it now distinguishes a level-1 primitive
diagnostic from a level-0 one, which is the point.

## Evidence

`tower_laws_test.ml`'s tripwire now asserts `Some 0` at depth 0, and
`evaluator_test.ml` asserts `Some 1` for type, arity, and division failures
raised on a materialized level-1 machine. Full suite green.
