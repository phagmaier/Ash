# 0040 — Dynamic reflection is a source-located specialization boundary

- **Status:** accepted
- **Date:** 2026-09-18
- **Tasks:** 10.1–10.4
- **Builds on:** 0025, 0029, 0034, 0036, 0038, 0039

## Context

The Phase 9 specializer knew the identity of every installed evaluator. A
runtime choice of `meta_with` failed when it tried to lift the captured default
`eval` primitive; a runtime branch containing `up` could stage its successor as
though the replacement were absent. The latter is unsound: a tracer would see
syntax the specializer had already erased. Also, runtime reflection can
materialize an upper level at requested interposition depth zero, while the
size reporter used to reject any materialized count above that depth.

## Decision

A lowered scoped override with a conditional evaluator choice is retained as
one reflective fragment. The fragment is closed over its current lexical
values by hygienic identity; global bindings remain global. Ordinary work
outside it continues to stage. The pre-check is intentionally syntactic: a
conditional inside the scoped construct is enough to retain it, even when a
stronger analysis could decide that condition.

A branch under a dynamic condition that contains a scoped override is
retained with source provenance. A dynamic branch containing a reifier is an
opaque persistent boundary: the entire source Core remains residual. This is a
monovariant, conservative choice, because an installed evaluator can observe
all subsequent syntax, including administrative lets that specialization would
introduce. The opaque residual bypasses administrative normalization too:
substituting even a trivial `let x = 1; x` would change the trace a dynamic
evaluator can print. A narrower continuation is not claimed without a sound evaluator
state join. The staged evaluator also tracks when its evaluator knowledge has
become dynamic inside a staged call, so it cannot fold a successor under a
stale cell identity. No closure or cell is serialized.

Residual execution attaches a lazy upper evaluator to its ground machine. It
has cloned globals and fresh group cells, so a retained scoped override or
`up` runs with the same cross-level protocol as the tower. No identity
interpreter is interposed in the residual run. A dynamic reflective residual is
compared against the tower run's answer/failure and exact output, not against
the unattached ground source run, which cannot execute `up`.

The four classes are conservative observations of a measured residual plus a
syntactic pre-check for depth readings, runtime `NamedVar`, and conditional
reflection. The OPAQUE label is used when dynamic evaluator identity dominates
and no net AST reduction is measured; PARTIAL is used when a boundary remains
but some work folds. A label is not a proof of membership for every possible
input. The report lists foreign-origin constructor cases, surviving sites with
source locations, counters,
reasons, and a JSON rendering of the raw values.

Interposed depth and materialized upper levels are distinct. A depth-zero run
may materialize one or more upper levels by reflection. Expanded semantic size
still uses the *requested interposed depth*; materialized size reports levels
actually allocated. `Tower.size_metrics` now accepts that legitimate relation.

## Limits

The monovariant fallback can retain more syntax than necessary, especially for
an `if` whose condition would be statically decidable after deeper analysis.
The PARTIAL/OPAQUE split uses a conservative syntactic witness of static pure
work outside a scoped choice together with residual size; retained syntax and
runtime plumbing can make a genuinely partial residual larger than its source.
This is not a general decision procedure. Programs whose abstract store
still owns a mutable binding at a reflective boundary are refused instead of
claiming equivalence. The existing unsupported decided failure inside an
undecided branch remains outside this phase. Timing, host stack, resource
exhaustion, gensym counters, and span provenance remain excluded observations.

## Evidence

`test/laws/dynamic_reflection_test.ml` populates all four classes; checks both
values and exact output for true/false runtime trace choices; tests a dynamic
persistent replacement both alone and stacked after a known replacement,
an evaluator that observes a trivial `let`, dynamic `NamedVar` pre-check, depth-zero runtime
materialization, and reconciliation of residue counts with a direct AST walk.
`python3 scripts/measure_phase10.py` records the raw JSON reports at depths
0–3 for all four classes and a dynamic persistent change, plus ratios and the
OCaml, Dune, opam, Python, and platform versions, in
`docs/progress/phase10-measurements.json`.
