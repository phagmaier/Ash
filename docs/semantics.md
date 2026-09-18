# Ash semantics

What an Ash program means, and what the implementation guarantees about that
meaning. This is a reader's guide to the behavior the test suite pins down;
the design source of truth remains `Ash Reflective Tower.md`, and the
per-decision rationale lives in `docs/decisions/0001`–`0040`.

## 1. Core language

Core is the only language the evaluators interpret. It has eleven forms
(`lib/core/core.mli`): `Lit`, `Var`, `NamedVar`, `Lam`, `App`, `Let`,
`LetRec`, `If`, `Set`, `Quote`, `Reifier`. Every match over Core is written
without a catch-all case, so adding a form is a compile error at every
interpreter rather than a silent fallthrough.

Values (`lib/core/value.mli`) are numbers, booleans, strings, symbols, unit,
immutable lists, closures, reifiers, one-shot continuations, first-class
environments, cells, `Code(Core)`, and primitives. Evaluation order is fixed:
the function position first, then arguments left to right; `If` requires a
boolean; `Set` evaluates to unit (ADR 0007).

Every Core node carries a source span plus a generated-node marker. Spans are
metadata: semantic comparison ignores them. A node the specializer invents
keeps the span of the source it came from, so residue attribution and error
locations survive into the residual.

## 2. Hygiene

Identity is a `(printed-name, unique-id)` pair (`lib/core/ident.mli`,
spec §D1, ADR 0002). Two binders that both print as `x` are different terms;
comparison by printed string alone is a capture bug no free-variable checker
can see.

Consequences, all load-bearing:

- Quotation and splicing are hygienic by construction. A splice marker is a
  fresh identity occurring free in the template; replacing that identity
  cannot capture or be captured (`lib/core/code.mli`, ADR 0018).
- Alpha-equivalence is structural equality after canonicalization
  (`lib/core/alpha.mli`). The printer emits readable binders; the reader,
  printer, and normalizer all compare through canonical IDs.
- Specializer-generated binders (let-insertion, specialization points) use
  fresh IDs and can never collide with user binders.
- `NamedVar(string)` is a distinct Core node, not a `Var` with a null ID. It
  resolves by printed name against a first-class environment at evaluation
  time and exists for reflective code that builds variable references from
  runtime strings. The specializer sees the difference: a `NamedVar` whose
  environment is not statically known is a specialization barrier, and the
  collapse report counts the survivors (`lib/collapse/residue.mli`).

## 3. CPS evaluator and the frozen oracle

The production evaluator is in continuation-passing style from day one
(`lib/runtime/evaluator.mli`, spec §D2, ADR 0008). Direct style exists only
as the frozen oracle (`lib/runtime/oracle.mli`, ADR 0007): pure ordinary Core,
never extended with reflection, staging, or continuations. Its job is
differential testing — `test/differential/oracle_cps_test.ml` requires oracle
and CPS evaluator to agree on value, error cause and location, mutation, and
buffered output over the shared corpus.

CPS is required because reflective procedures receive the continuation of the
level below, which in direct style lives on the host stack where nothing can
reach it. Ash tail calls pass the continuation through unchanged with every
host call in tail position, so tail-recursive Ash loops run in constant host
stack.

## 4. Open recursion

`eval`, `apply`, and `eval_list` live in mutable per-level cells, and every
call among them dereferences its cell (`lib/runtime/machine.mli`, spec §D3,
ADR 0008). No group member captures a direct reference to another. A meta
level that replaces `eval` therefore intercepts every nested step, not just
the entry call — the tracing demo (`examples/tracing.ash`) prints one line
per node precisely because of this, and would print a handful of lines if the
invariant regressed.

The Ash side mirrors the host side: `open fn` lowers each member reference to
`open_deref` and each member assignment to `open_set` without touching Core
(ADR 0015). The law is `test/laws/open_recursion_test.ml`; every dereference,
call, and constructor dispatch is counted, and the counters are
observationally inert — no Ash value, error, identifier, or output can read
them.

## 5. Continuations, environments, `run`, `lift`

Continuations are first-class and one-shot (`lib/core/value.mli`, ADR 0014).
The used flag is set before transfer, so a continuation reached again through
its own resumption is caught; a second invocation raises
`Continuation_reuse` naming the capture site and the first-use site.
`callcc` is a primitive, not syntax, so Core is untouched.

Environments are explicit frame chains keyed by hygienic IDs, with `lookup`,
`lookup-by-name`, `bind`, `extend`, `preallocate`, and `assign` (ADR 0004).
`LetRec` preallocates cells and fills them with closures over the extended
environment. Unbound-name errors carry source locations.

`run` takes closed code only (ADR 0019): it reports every unresolved
lexical dependency and never inherits the caller's lexical state. `lift`
converts only the fixed domain — scalars, unit, immutable liftable lists, and
code — and rejects closures, continuations, environments, and cells with
origin-aware errors (ADR 0020). `NamedVar` is not a lexical dependency of
code: it explicitly asks for lookup by name at evaluation time.

## 6. Tower materialization and depth

Levels materialize lazily (`lib/tower/tower.mli`, ADR 0022). The tower starts
as ground level 0 only; ordinary code creates no upper level, and first
reflection creates exactly one. Each materialized level owns cloned globals
and fresh open-recursion cells; primitives (and hence the observable IO
stream) are shared. Track materialized size separately from expanded semantic
size (`n·|I| + |p|`): the former is measured from the heap, the latter is what
an eager tower would contain (spec §9.1, ADR 0040).

Reifiers receive the whole unevaluated call expression, the caller's
environment, and the caller's one-shot continuation, and run one level up
(ADR 0023). `reflect` evaluates code on the machine below and transfers to a
continuation captured there; errors reach only level n+1. `up { E }` is a
reifier over no arguments ending in `resume(cont, E)`; `eval`/`apply` are
bound as cells on the level below's group, so a replacement is persistent and
composes, runs on the machine above the cell, and leaves the evaluator
running its own level unchanged (ADR 0024). `meta_with` pushes a persistent
overlay frame rather than mutating a cell, so nested overrides shadow without
touching persistent state; continuations capture the overlay pointer and
invoke it without mutating the ambient context (ADR 0038). `NamedVar` never
sees overlays — only explicit lexical environments.

`Ash_tower.Depth` defines "running at depth k": it interposes a real Ash
identity interpreter at every level below k, so every step of level n is a
term level n+1 evaluates (ADR 0025). A materialized-but-untouched level would
make transparency vacuous, so depth is built from levels that actually
interpret. `level` is relative; `tower_depth()` is the one explicit opt-in to
depth sensitivity (spec §D9).

## 7. Staging

Static data are real values; dynamic data are `Code(Core)`; one evaluator
source serves identity and lifting modes (`lib/stage/staged_eval.mli`,
`lib/stage/stage_value.mli`, ADR 0026). Partially static data are real:
a list with a static spine and dynamic elements still answers `head`,
`tail`, and `length` from the spine, per each primitive's declared
observation depth (`lib/core/observation.mli`).

Let-insertion (`lib/stage/emit.mli`, ADR 0027) binds every emitted dynamic
operation in a scoped block buffer under a fresh ID, with distinct buffers
for dynamic branch and lambda bodies, preserving operation count and order.
Specialization points (`lib/stage/specialize.mli`, ADR 0031) key calls by
function identity (lambda plus closed-over environment, compared physically)
plus per-argument projection — known (compared by value), held (compared by
identity), unknown (becomes a residual parameter). Inlining is the default;
a call whose own key is already being inlined becomes a residual function
bound by `LetRec` where the inlining began. Budgets
(`max_inline_depth`, `max_residual_bindings`) generalize the leftmost
argument that differs from the nearest enclosing call to the same function;
generalization is sticky and monotone, so k parameters mean at most k
generalizations before the key is fixed (ADR 0032). Closure reification has
no key to generalize and can only refuse with `Budget_exhausted`.

Statically known evaluator changes are staged configuration (ADR 0039): a
Lift-wired static level chain runs the closed meta protocol and inlines known
`eval`/`apply` wrappers at their dispatch sites, keeping wrapper effects in
the residual. A runtime evaluator choice is a measured boundary instead: a
conditional scoped choice is retained as one reflective fragment with source
provenance while independent work still folds; a persistent replacement under
a dynamic condition retains the whole Core, because an installed evaluator
observes all subsequent syntax including administrative lets (ADR 0040).

## 8. Effects

Every primitive carries exactly one effect class
(`lib/core/effect_class.mli`, ADR 0009/0035): pure, allocation/mutation,
observable effect, specialization-only (`static_log`), control, reflection.
The gate is structural: the staged evaluator consults
`always_residualizes` before any rule that could fold, so mis-marking the
observable class as foldable still cannot make compilation print. IO always
residualizes; `static_log` runs at specialization time onto a second stream
and leaves no residual call; allocation/mutation residualize until the store
discipline proves otherwise; control and reflection get bespoke rules.

The abstract store (`lib/stage/store.mli`, ADR 0036) decides per binding who
owns the cell: held (specializer owns it; writes update, reads fold) or
residual (writes become `Set` nodes, reads become variables). Keyed by cell,
so aliases stay one place and one binder evaluated twice stays two. Holding
is a syntactic proof asked once per binder — not free in any lambda, quoted
data, `NamedVar`-spelled name, or reifier scope — and failure residualizes
rather than refuses. At a dynamic conditional, held bindings either branch
assigns are promoted before the fork; the join keeps only what outlives the
branch and requires both forks to agree. The write set
(`Core.assigned_idents`) is shared with the normalizer, so the two phases
cannot disagree about what a later `Set` changes. One asserted refusal
remains: a failure the specializer can decide, inside a branch it cannot,
aborts specialization instead of becoming a residual failure.

## 9. Normalization

`Ash_collapse.Normalize.normalize` (ADR 0033) gives residuals one canonical
shape: flatten value-position lets however deep they nest, substitute trivial
bindings (a literal, or a variable nothing assigns), then alpha-canonicalize
last. Guards: a mention that cannot follow a substitution keeps its binding
(`Set` targets read their cell; quoted code is data; reifier bodies are
another level's code); nothing hoists out of a lambda, branch, or `LetRec`
group; unused effectful bindings still happen; dynamic-reflection regions
and their captured bindings are not administratively rewritten, since a
runtime evaluator may inspect exact constructor steps. Idempotence is exact
structural equality; `Metrics.measure` normalizes before surveying and
running the residual.

## 10. Classification

The four classes (spec §9.3, `lib/collapse/classification.mli`, ADR 0040)
are conservative observations of a measured residual plus a syntactic
pre-check for depth readings, potentially dynamic `NamedVar`, and reflection
under a dynamic condition:

| Class | Property |
|-------|----------|
| DEPTH-INVARIANT, FULL | residual alpha-equivalent across depths, zero interpreter residue |
| DEPTH-SENSITIVE, FULL | residuals differ across depths; each matches what its depth's tower did, with zero residue |
| PARTIAL | a reflective boundary remains but independent static work folds |
| OPAQUE | dynamic evaluator identity dominates; collapse is approximately the identity function |

Membership is undecidable in general; PARTIAL can overstate residue and
OPAQUE is a measured conservative label, not an impossibility proof. For
non-invariant classes the criterion is semantic preservation at each depth —
`execute(C(n,p)) ≈ execute_tower(n, p)` — never cross-depth
alpha-equivalence. The `ash --collapse` report (§9.4, `lib/collapse/report.mli`)
is the classification mechanized: sizes, steps, residue cases and
source-located sites, surviving dereferences/dispatches/lookups/boundaries,
generalizations with reasons, and JSON rendering of the same numbers. Totals
reconcile with a direct residual AST walk (`Residue.survey`). The five
checked-in samples in `examples/classification_*.ash` populate all four
classes at depths 0–3; raw numbers and host versions are pinned in
`docs/progress/phase10-measurements.json` and reproduced by
`python3 scripts/measure_phase10.py`.

## 11. Tested laws

Each law is an executable file, not a comment:

- Oracle/CPS agreement on the shared corpus (`test/differential/oracle_cps_test.ml`).
- Self-interpreter/host agreement and layer 1–2 iteration
  (`test/differential/self_host_test.ml`, `test/differential/self_layers_test.ml`).
- Open recursion at host and Ash level (`test/unit/evaluator_test.ml`,
  `test/laws/open_recursion_test.ml`).
- Tower transparency, level independence, error propagation, one-shot
  enforcement, depth observation at depths 0–5 (`test/laws/tower_laws_test.ml`).
- Pure collapse criterion: source, depth-1 tower, and residual agree with
  zero dispatch and zero surviving dereferences
  (`test/laws/collapse_criterion_test.ml`).
- Depth invariance for ordinary programs; per-depth equivalence for
  `tower_depth()` observers (`test/laws/depth_invariance_test.ml`).
- Effect order: value, observable store reads, output, and failure agree at
  depths 0–5 with empty specialization output
  (`test/laws/effect_order_test.ml`, `test/differential/residual_test.ml`).
- Static reflection leaves zero interpreter residue
  (`test/laws/static_reflection_test.ml`); dynamic reflection populates all
  four classes with byte-exact output agreement
  (`test/laws/dynamic_reflection_test.ml`).
- Budgets/generalization terminate hostile recursion with diagnostics
  (`test/unit/stage_budget_test.ml`); normalization is idempotent and
  effect-safe (`test/unit/normalize_test.ml`); golden CLI outputs are pinned
  (`test/golden/`).

## 12. Excluded observations

The equivalence claims deliberately exclude timing, host stack depth,
resource exhaustion, gensym counters, and span provenance (AGENTS.md
invariant 10; spec §D9). Two failures agree on cause and source location,
never on the generated layers a residual node carries. Per-level step
counters grow ~5x per interposed level (`docs/progress/0001-depth-cost.md`) —
that cost is the measurement that motivates the collapser, not a defect in
the tower. Nontermination tests use counted Ash step budgets, never wall
time.
