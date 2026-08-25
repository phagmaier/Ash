# 0034 — Depth results: folding the statically known depth reading

Status: accepted. Task 6.4. Spec §8's Phase 6, §9.3, §D9.

Builds on: 0025 (what tower depth means), 0030 (what the pure collapse
criterion claims), 0031 (specialization points), 0033 (the normalizer).

## Context

Phase 6 completes as `collapse(n, p) ≅α collapse(1, p)` for all pure `p`, after
normalization. Two facts about the implementation had to be faced before that
claim could mean anything.

**First, residuals of one program are never comparable across environments.**
Cloned globals (ADR 0022) give every environment its own global identities — a
level's `list` binding is a fresh identity per materialization — so two
residuals produced under two measurements disagree on which global they call,
and no normalization can repair it. A cross-depth comparison must therefore
resolve every specialization against *one* environment.

**Second, without depth-aware specialization the ≅α claim is vacuous and its
own escape clause dead.** The specializer ran detached from any tower, so
`C(n, p)` was literally the same run for every n — comparing a term with
itself. And `tower_depth()`, §D9's deliberate opt-in, residualized like every
reflection-class primitive, so a depth-observing program's residual executed at
depth 0 reported 0 whatever depth it was specialized at — not "semantically
correct at each depth", just blind to depth.

## Decision

### The fold

In lift mode, a nullary reflection-class reading whose answer the specializing
configuration fixes is folded rather than residualized. Today that is exactly
one primitive:

- **`tower_depth()` folds to the depth the specializer is attached to.**
  Attached to a configuration with `n` materialized levels, the reading is a
  static fact; the residual becomes the residual *for* depth `n`, and running
  it anywhere reports `n` — which is what the tower at depth `n` reports too.
  This is what makes §9.3's second class real: `C(n, p)` differs across `n`,
  each semantically equivalent to `execute_tower(n, p)`.

Everything else stays dynamic exactly as before:

- `meta_eval`, `meta_apply`, `meta_global` answer with cells and environments —
  identity-carrying values the small lifting domain refuses to reify.
- `tower_level()` keeps its old behavior: it reads 0 during specialization and
  0 wherever this fragment executes, so there is nothing to gain.
- Without an attached configuration (standalone `Stage.fold`, unit tests), no
  neighbourhood exists and `tower_depth()` residualizes as always.

The rule lives in `Staged_eval.apply_primitive` behind one predicate,
`static_reading : Machine.t -> Value.primitive -> Value.value option`. Folding
emits the
lifted constant at the call site; provenance stays with the program.

### The attachment points

A staging machine learns its depth through `Machine.set_levels`, level 0:

- `Metrics.measure` attaches the staging machine to the measurement's own
  materialized tower, whose thunk reads the live materialized count.
- `Metrics.specialize ~depth ~env` — new — attaches only a faithful depth
  reading against a caller-owned environment. No tower is materialized because
  none can matter (§7.4 step 1): the pure fragment cannot shift levels, so a
  configuration contributes exactly one observable, its depth. This is the
  entry point cross-depth comparisons use. A term that does try to shift up
  has no level to shift into, and gets the refusal back as `Error` like any
  other, so the entry point stays total.

### One environment per comparison

`Metrics.measure` keeps building its own tower per call. Comparisons across
measurements — task 6.4's whole business — go through `Metrics.specialize`
with one shared environment instead, which is why the law test builds one
tower's ground level and resolves every sample once against it.

An alternative was considered and rejected here: making `Primitives.globals`
memoize identities per registry so two towers share global names. It would
have worked mechanically but weakened three pinned properties — fresh global
identity per cloned level — that exist to keep levels independently stateful
(ADR 0022). The shared-environment approach costs nothing and touches nothing
below `ash.collapse`.

## Semantic consequences

- For programs that do not read their depth: nothing changes except where they
  are measured. Residuals were already depth-blind; now the claim that they
  are is checked rather than assumed.
- For `tower_depth()` readers: `C(n, p)` is now defined relative to `n`. A
  residual specialized at depth `n` run in a world of depth `m ≠ n` reports
  `n` — wrong for that world, right for its own, and the claim says so. This
  is precisely §9.3's DEPTH-SENSITIVE-FULLY-COLLAPSIBLE row, and the reason
  invariant claims exclude such programs.
- Standalone specialization (`Stage.fold`, `Staged_eval.run` without levels)
  is bit-for-bit unchanged.
- The report's reflection-boundary count drops to zero for folded readings:
  the boundary genuinely did not survive.

## Test impact

- New `test/laws/depth_invariance_test.ml`, the task's deliverable:
  - syntactic half — one shared environment, `Metrics.specialize` at depths
    0–5 over the pure corpus plus computing and depth-sensitive samples;
    ordinary programs alpha-equal across depths, `tower_depth()` programs
    required to differ, zero surviving interpretation everywhere;
  - semantic half — `Metrics.measure` at each affordable depth; transparency,
    program/residual agreement by application where answers are functions,
    tower/residual agreement for closed depth-sensitive answers, and residual
    cost ≤ source cost;
  - falsifiability guard — two raw specializations differ structurally while
    their normal forms coincide, proving the normalizer load-bearing;
  - budget skips reported visibly (one corpus entry stops at depth 2).
- `test/golden/collapse.expected` unchanged: no golden sample reads its depth.
- New `examples/depth.ash` documents the depth-sensitive shape; the CLI report
  shows source 0 vs tower n vs residual n at depth n, agreeing honestly that
  they differ.

## Measurement changes

None. Every counter keeps its meaning; residuals merely arrive normalized
(ADR 0033). The depth figures in the report remain the cost collapse is set
against, per ADR 0029/0030.
