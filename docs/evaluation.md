# Ash research evaluation

Where interpretation ends and compilation begins, measured. This document
presents the four collapse classes with their measured representatives, the
depth results, what each residue consists of and why it survives, the
limitations, and the precise claims — including what is not claimed. Method
and terminology are defined in `docs/semantics.md`; reproduction commands are
in `README.md`.

## 1. The question

Not "reflection can be collapsed" — Amin & Rompf's Purple already establishes
that — but the sharper question from the spec's §1: **where is the boundary
between reflection that is merely a static description of altered semantics,
and reflection that constitutes irreducible runtime semantic choice?** The
answer below is a classifier plus numbers, not a theorem: five checked-in
programs, four depths each, twenty tower/residual pairs, every pair agreeing
on value-or-failure and exact output.

## 2. Method

`python3 scripts/measure_phase10.py` emits `docs/progress/phase10-measurements.json`:
for each of the five `examples/classification_*.ash` programs at requested
interposition depths 0–3, the exact JSON collapse report, the tower-step ratio
`steps(N)/steps(N−1)`, and the host versions (OCaml 5.4.1, Dune 3.24.2, opam
2.5.2, Python 3.14.7). Agreement means same outcome (two failures agree on
cause and source location, provenance excluded) and byte-identical observable
output; specialization output must be empty in all twenty cases, and it is.
`docs/progress/0003-phase10-measurements.md` indexes the raw file. Nothing
below is quoted from anywhere but that JSON and the golden reports.

## 3. The four classes, measured

| Program | Class | Depth 0/1/2/3 tower steps | Depth 1/2/3 ratios | Source → residual nodes |
|---|---|---:|---:|---:|
| `classification_invariant.ash` (`40 + 2`) | DEPTH-INVARIANT, FULL | 8 / 56 / 292 / 1472 | 7.00 / 5.21 / 5.04 | 4 → 1 |
| `classification_sensitive.ash` (`tower_depth() + 1`) | DEPTH-SENSITIVE, FULL | 11 / 71 / 366 / 1841 | 6.45 / 5.15 / 5.03 | 5 → 6 |
| `classification_partial.ash` | PARTIAL | 65 / 577 / 3184 / 16223 | 8.88 / 5.52 / 5.10 | 47 → 50 |
| `classification_opaque.ash` | OPAQUE | 49 / 465 / 2600 / 13279 | 9.49 / 5.59 / 5.11 | 39 → 45 |
| `classification_persistent.ash` | OPAQUE | 25 / 316 / 1896 / 9802 | 12.64 / 6.00 / 5.17 | 48 → 48 |

**Depth-invariant, full.** `40 + 2` folds to the literal `42` at every depth;
the residual is one node with zero eval-cell dereferences, zero dispatch
sites, zero `NamedVar` lookups, and zero reflection boundaries. Reason
reported: "no interpretation sites found."

**Depth-sensitive, full.** `tower_depth() + 1` folds the depth reading to the
stated depth, so the residual differs per depth (`0+1`, `1+1`, `2+1`, `3+1`
— outcomes 1, 2, 3, 4) while each matches what its depth's tower did, with
zero residue of any kind. Reason reported: "program reads tower_depth()."
This is the class that makes cross-depth alpha-equivalence a false theorem;
per-depth semantic equivalence is the claim, and all four depths satisfy it.

**Partial.** `let folded = 40 + 2` beside a runtime trace flag driving a
scoped `meta_with` evaluator choice over `1 + 2`. The `40 + 2` folds to `42`
— partiality is witnessed by that folded work, not by net size reduction: the
residual is 50 nodes from 47, because the retained boundary keeps exact syntax
and adds runtime plumbing (`meta_current_eval`, `meta_current_apply`,
`meta_with_run`: three source-located sites). Outcome `[42, 3]` agrees
exactly, with no specialization output.

**Opaque, scoped.** The same runtime choice with no foldable work outside it:
45 nodes from 39, the same three boundary sites, nothing static to witness.
The OPAQUE label records that no net AST reduction was measured across the
dynamic evaluator boundary — a conservative observation, not an impossibility
proof.

**Opaque, persistent.** A runtime flag choosing a persistent `up` replacement
keeps all 48 nodes and one `open_deref`, with five sites
(`meta_eval`, `meta_apply`, `meta_global`, `tower_level`, plus the retained
reifier). Retaining the whole Core is necessary, not lazy: an installed
evaluator observes all subsequent syntax, including administrative lets the
specializer would otherwise introduce, so even normalizing the boundary would
change what a dynamic tracer can print (ADR 0040). A narrower
evaluator-state join is explicitly future work.

## 4. Depth results

Two facts, kept apart. First, ordinary programs are depth-invariant after
normalization: `test/laws/depth_invariance_test.ml` checks 417 invariant
comparisons over depths 0–5 against one shared environment (cloned globals
give each environment its own identities, so cross-measurement comparison
would be meaningless). Second, depth observers differ per depth and remain
correct per depth (18 checks): each residual computes what its depth's tower
reported. The normalizer is load-bearing here — raw specializations differ by
fresh identities, so comparing without normalizing would void the claim.

The per-level cost converges toward the baseline's flat factor of five
(`docs/progress/0001-depth-cost.md`): depth-1 ratios on these tiny programs
read 7.00–12.64x (first-interposition setup amortized over a few dozen
steps), depth-3 ratios read 5.03–5.17x. No curve is assumed; the script
records ratios, not a fit.

## 5. The static-reflection control

The classification above would be unconvincing without proof that known
reflection does collapse. `examples/traced_fibonacci.ash` is that control: a
statically known persistent tracing wrapper around recursive Fibonacci with a
runtime cell read keeping the recursion residual. The 251-node residual holds
one specialization point for the recursion and `println` calls inlined at the
dispatch sites the wrapper intercepted — zero eval-cell dereferences, zero
dispatch sites, zero `NamedVar` lookups, zero reflection boundaries, zero
foreign-origin nodes. Tower: `2` after 2,598 evaluator-group calls. Residual:
`2` after 582, with byte-identical 59-line output. Static evaluator change is
configuration; dynamic evaluator choice is boundary. That sentence is the
evaluation's one-line result.

## 6. Cost baseline

One interposed identity level costs a flat factor of five past the first
level (`fact(5)`: 162 program steps; 960 at depth 1; 590,000 at depth 5 —
all unobservable, value 120 throughout). Level-0 steps never change with
depth; the tower runs 16.3M evaluator calls through five stacked interpreters
in constant host stack. Five is a floor for the smallest possible
interpreter, not a prediction about interpreters that do real work — the spec
explicitly deletes any constant-factor prediction, and this number does not
reinstate it.

## 7. Limitations

- **Conservative classifier.** Membership is undecidable in general. PARTIAL
  can overstate residue; OPAQUE is a measured label for "dynamic evaluator
  identity dominates with no net reduction," not a universality result. The
  pre-check is deliberately syntactic: a conditional inside a scoped override
  retains the fragment even when deeper analysis could decide it.
- **Asserted refusals, not silent gaps.** A decidable failure inside an
  undecidable branch aborts specialization; programs holding abstract-store
  bindings at a reflective boundary are refused; closure reification under
  budget pressure fails with `Budget_exhausted`. Each is pinned by a test.
- **Excluded observations.** Timing, host stack depth, resource exhaustion,
  gensym counters, span provenance — and heap words, which vary with the
  OCaml runtime. Two failures agree on cause and source location only.
- **Scope of the sweep.** Classification is measured at depths 0–3; the
  tower, depth, and effect laws run 0–5. Residuals execute through the ground
  evaluator; there is no native backend (spec §11 scopes it as a victory
  lap for a restricted fragment).
- **Monovariant specialization.** One residual function per static key; no
  polyvariant splitting beyond budget-driven generalization.

## 8. Claims

**Claimed:** a small, fully self-hosted reflective tower with explicit scoped
meta-mutation, plus a machine-checked classification of which reflective
modifications eliminate completely versus leave interpreter residue, with
quantitative collapse-invariance and residue measurements. The `ash
--collapse` report is the evidence: every figure in §3 is reproducible by one
script command from a clean checkout.

**Not claimed:** that reflection in general collapses (Amin & Rompf); that
scoped override with correct continuation interaction is new (it has ancestry
in `dynamic-wind`, `parameterize`, delimited dynamic binding, effect
handlers); any scaling curve; any performance result — all step counts are
counted evaluator-group calls, never wall time.
