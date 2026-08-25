# Ash implementation plan

This is Ash's authoritative execution checklist. Design rationale and semantics
live in `Ash Reflective Tower.md`; this file turns them into verifiable tasks.

## Session protocol

- Read `AGENTS.md`, this file, and the relevant spec sections at session start.
- The first unchecked item in document order is the default next task.
- Mark `[x]` only after implementation, tests, and documentation satisfy the
  stated acceptance criterion. Leave partial work unchecked.
- After each task, update **Current state** and prepend a Handoff log entry to
  `docs/progress/handoff-log.md`.
- If evidence requires a spec change, write a decision record, update the spec,
  and update this plan in the same change. Never silently diverge.

## Current state

- **Phase:** 7 — mutation and effects. 7.1 and 7.2 done.
- **Next:** 7.3 — the effect-order differential corpus
- **Last verified:** 2026-08-24 from a removed `_build` — `opam exec -- dune
  build @all`, `opam exec -- dune runtest --force`, `opam exec -- dune exec ash
  -- --help`, `opam exec -- dune exec ash -- --demos`, and
  `opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1` all
  pass. Task 7.2 split the store: a binding is either the specializer's — writes
  update its cell, reads fold, nothing survives — or the residual program's,
  with writes becoming `Set` nodes and reads a variable, and the store is keyed
  by cell identity so aliases stay one place and two activations stay two. At a
  conditional the specializer cannot decide, every held binding either branch
  assigns is given up before the fork and the two stores are joined afterwards,
  which is what makes §7.4's `if d then x := 1 else x := 2; use(x)` come out
  right while a binding no branch writes still folds. `Core.assigned_idents` is
  now one definition shared with the normalizer, so ADR 0033's write-set guards
  decide something for the first time. Nothing pure moved: the whole pure corpus
  specializes to bit-identical residuals. Task 6.3 gave residuals one canonical
  shape: administrative lets
  flatten, trivial bindings substitute away, alpha-canonical renaming runs
  last, and no effect moves — idempotent by construction, pinned by unit tests
  over flattening, hygiene, effect-order counterexamples, and whole programs.
  Task 6.4 made specialization depth-aware and measured the result: ordinary
  corpus programs produce alpha-equal residuals at depths 0–5, while
  `tower_depth()` samples produce one residual per depth, each matching what
  that depth's tower did — 417 invariant checks and 18 depth-sensitive checks,
  with the normalizer proven load-bearing (raw specializations differ by fresh
  identities; their normal forms coincide). Nothing prior moved: the collapse
  report's counters are unchanged for every sample that does not read its
  depth, the criterion suite still proves its 73 depth-1 samples against the
  same 906,708-dispatch / 2,125,589-cell-read tower figures and the same 250
  residual nodes, and standalone specialization (`Stage.fold`, unattached
  machines) residualizes `tower_depth()` exactly as before.
  **Milestone 2 remains done**, and the criterion still covers: 73 pure
  samples at depth 1 — the corpus's values and failures, plus eight whose
  residual is a function, compared by application, two of them keeping a
  residual `LetRec` of the program's own recursion — agreeing across the
  source, tower, and residual runs, with zero surviving eval-cell dereferences,
  evaluator calls, Core dispatch sites, `NamedVar` lookups, and reflection
  boundaries in every residual. The criterion is falsifiable and shown to be.
  Also intact: the collapse report (5.4), the staged pure fragment (5.3),
  hygienic let-insertion (5.2), the static/dynamic value model and
  `maybe-lift` mode (5.1), lazy tower (depths 0–5), the hygienic desugarer,
  `open fn` groups, the self-interpreter (`lib/self/eval.ash`) at layers 1 and
  2, the 50-primitive registry, the full regression suite (unit, differential,
  laws, golden), and both packaged milestone demos.
- **Blocker:** none

Milestone 1 is done. The tower is real: a program can reach up and replace the
evaluator running it, the replacement intercepts every nested step and not the
level running it, and both of the spec's demos are packaged and pinned.

Milestone 2 is done. For the pure fragment, the interpretation is removable and
the removal is measured rather than asserted: `ash --collapse` prints what a
tower performs beside what the residual contains, and the law suite proves the
two are what §8's Phase 5 asks for. The scope is exact and written down in ADR
0030 — `collapse(1, p)` is *specialize `p`, and compare against what the depth-1
tower did*, not *squash the tower*, which is §7.4 step 5 and task 9.1.

Two things the rest of Phase 6 inherits. First, `Ash_tower.Depth` is the
definition of "running at depth k" — levels that are actually interpreting, not
merely materialized (ADR 0025) — and it is what 6.4 compares residuals across.
Second, `docs/progress/0001-depth-cost.md` is the baseline: one interposed level
costs a flat 5x, so `fact(5)` is 162 steps of program and 590 000 steps of
machinery at depth 5, none of it observable; the collapse report reproduces
those figures from the same counters.

The fragment's edge is gone. 6.1 made recursion the specializer cannot see the
end of terminate, by keying calls and tying the knot when a key repeats. 6.2
covered the rest — recursion that never repeats a key, because an argument grows
or a counter walks away from its base case — with a budget that generalizes one
argument at a time. Termination now has an argument behind it rather than a
hope: generalizing is sticky and monotone, so a function with *k* parameters is
generalized at most *k* times, after which its key is constant and the next call
must find the memo table. The one place the specializer can only refuse is
closure reification, which is not a call and has nothing to generalize.

## Locked decisions

- Host: OCaml 5.2+ with Dune 3.16+; prefer the standard library.
- Parser: handwritten, with source spans on surface nodes and errors.
- Identifiers: hygienic `(printed-name, unique-id)`; `NamedVar` is distinct and
  searches only explicit lexical environments, never meta overlays.
- Evaluator: CPS production evaluator; frozen direct-style oracle for pure Core.
- Continuations: first-class and one-shot, dynamically enforced.
- Reifiers receive the whole call expression, environment, and continuation.
- Globals and open-recursion cells are cloned per materialized tower level.
- `level` is relative; `tower_depth()` explicitly opts into depth sensitivity.
- `meta_with` uses persistent overlay frames and structural sharing.
- First backend is residual Core executed by the ground evaluator.

## Phase 0 — bootstrap and Core

- [x] **0.1 Initialize the OCaml project skeleton.**
  - Add `dune-project`, `ash.opam`, `lib/`, `bin/`, `test/`, `examples/`,
    `docs/decisions/`, `docs/progress/`, `README.md`, and `.gitignore`.
  - Initialize Git only if this directory is still not a repository.
  - Add an empty CLI help path and smoke test; put verified commands in
    `AGENTS.md` and `README.md`.
  - Accept: `dune build @all`, `dune runtest`, and
    `dune exec ash -- --help` pass on a clean checkout.

- [x] **0.2 Implement source spans, constants, and hygienic identifiers.**
  - Separate printed names from identity; centralize fresh-ID generation.
  - Add deterministic ID canonicalization for printing and tests.
  - Accept: same-name/different-ID binders remain distinct, while alpha-renamed
    samples canonicalize to structurally equal terms.

- [x] **0.3 Implement the complete Core and value data model.**
  - Core: `Lit`, `Var`, `NamedVar`, `Lam`, `App`, `Let`, `LetRec`, `If`, `Set`,
    `Quote`, `Reifier`.
  - Values: scalars, immutable lists, closures, reifiers, continuations,
    environments, cells, code, and primitives.
  - Accept: constructor fixtures cover every variant; unknown variants fail
    explicitly rather than falling through.

- [x] **0.4 Implement explicit environments and cells.**
  - Add lexical frame chains keyed by hygienic IDs plus `lookup`,
    `lookup-by-name`, `bind`, `extend`, `preallocate`, and `assign`.
  - Include source locations in unbound-name errors.
  - Accept: tests cover shadowing, closure-visible mutation, recursive
    preallocation, name lookup, and failure behavior.

- [x] **0.5 Implement a canonical Core s-expression reader.**
  - This is the early debug/test format, not the user-facing parser.
  - Validate shape/arity and retain source spans.
  - Accept: every Core form round-trips; malformed forms identify their location.

- [x] **0.6 Implement the Core printer and alpha-equivalence.**
  - Print deterministic readable binders and compare through canonical IDs.
  - Accept: `read(print(core))` is alpha-equivalent for every form, including
    shadowing, `LetRec`, quotation, and reifiers.

- [x] **0.7 Implement the frozen direct-style oracle.**
  - Support pure ordinary Core only; explicitly forbid reflection, staging, and
    continuation extensions.
  - Accept: arithmetic, functions, lexical scope, `If`, `Let`, `LetRec`, and
    immutable-list fixtures pass.

- [x] **0.8 Implement the real evaluator in CPS.**
  - Make `eval`, `apply`, and `eval-list` explicitly CPS.
  - Implement `LetRec` with preallocated cells and closures in the extended env.
  - Count evaluator steps and constructor dispatches from the start.
  - Accept: `fact(20)` works and agrees with the oracle on the initial corpus.

- [x] **0.9 Implement the classified primitive registry.**
  - Classify every primitive as pure, allocation/mutation, observable effect,
    control, or reflection. Buffer observable output for deterministic tests.
  - Accept: every primitive has exactly one class and consistent arity/type errors.
  - The control and reflection classes are registered empty: their members need
    one-shot continuations (1.5) and staging/the tower (Phases 3–4), and ADR 0009
    records why a stub is worse than an honest absence. Filling them is a
    deliberate change that a test currently asserts against.

## Phase 1 — surface language and continuations

- [x] **1.1 Implement the lexer with source spans.**
  - Cover comments, literals, symbols, names, keywords, operators,
    quotation/splice tokens, and punctuation.
  - Accept: golden tests cover ambiguous operators and malformed literals.
  - Tokens also carry whether a line break precedes them. The spec's blocks
    separate statements by newline as well as by `;`, and 1.2 decides what to do
    with that; ADR 0010 records why the lexer records layout rather than
    consuming it.

- [x] **1.2 Implement the precedence parser.**
  - Cover bindings, mutation, functions, calls, blocks, conditionals, lists,
    pipelines, and the exact precedence/associativity table from the spec.
  - Accept: parser golden tests include every precedence boundary.

- [x] **1.3 Implement patterns and pattern parsing.**
  - Cover wildcard, literals, variables, list patterns, alternatives, Core
    constructors, and quasiquote patterns; reject inconsistent binders.
  - Accept: the documented `length` and `simplify` examples parse.

- [x] **1.4 Hygienically desugar surface syntax to Core.**
  - Lower sequencing, `var`, named functions, match, Boolean sugar, lists, and
    pipelines; preserve spans and generated-node provenance.
  - Accept: end-to-end tests cover `fact`, `length`, pipelines, shadowing, and set.
  - Quotation, splicing, Core constructor patterns, and quasiquote patterns parse
    but do not lower: they are refused by name until 3.1 gives them hygienic code
    construction, which also needs reflection-class primitives ADR 0009 left
    unregistered. ADR 0013 records that and the rest of the lowering.

- [x] **1.5 Implement first-class one-shot continuations.**
  - Retain continuation procedure, used flag, capture site, and meta-context.
  - Mark used before transfer; report capture and first-use sites on reuse.
  - Accept: storage, delayed/cross-function invocation, and second-use error pass.
  - `callcc` is the whole control class and is a primitive, not syntax, so Core
    is untouched. Capturing needed a primitive to be able to call an Ash
    function, so `prim_impl` gained an `~apply` argument routed through the
    machine's open-recursion cell. The meta-context retained is the tower level;
    only level 0 exists before Phase 4. ADR 0014 records all of it.

- [x] **1.6 Build the oracle/CPS differential corpus.**
  - Compare values, errors, mutations, and buffered output across recursion,
    closures, shadowing, lists, and failures.
  - Accept: all pure cases agree with readable minimal differences on failure.
  - 91 programs: 73 in Core notation and 18 in Ash lowered by the desugarer, so
    the front end is compared against two evaluators rather than one. Each entry
    declares whether it produces a value or a diagnostic, because two evaluators
    that both refused everything would agree perfectly. The oracle's refusals —
    quotation, reifiers, `callcc`, observable effects, cells — are checked as a
    boundary, not as agreement.

## Phase 2 — self-interpreter and open recursion

- [x] **2.1 Define and enforce open-recursive evaluator groups.**
  - Store `eval`, `apply`, and `eval-list` in mutable per-level cells.
  - Every intra-group call must dynamically dereference its cell; instrument each
    dereference. Never capture direct group references in closures.
  - Accept: wrapping `eval` observes every nested AST node, not just entry.
  - Host side was already done in 0.8 (`Ash_runtime.Machine`, ADR 0008). The Ash
    side is `open fn`, a surface binding form that binds each member's name to a
    cell and lowers every reference to it — inside the group and after it — as
    `open_deref`, and every `member := …` as `open_set`. Core is untouched. ADR
    0015 records it; `test/laws/open_recursion_test.ml` is the law.

- [x] **2.2 Write the CPS Core evaluator in Ash.**
  - Keep it parallel to the host evaluator. Resolve missing language support as a
    Core form or desugaring, never a host escape hatch.
  - Accept: it matches the host evaluator on the ordinary corpus.
  - `lib/self/eval.ash`, run by `ash.self`. Quotation is Phase 3, so a term
    arrives as tagged list data; two primitives were added rather than worked
    around (`invoke`, which is §6's `prim_apply`, and `list?`). ADR 0016 records
    the encoding, the value domain, and the two declared boundaries — locations,
    and failures the interpreted level detects itself.

- [x] **2.3 Test iteration and invariant OR.**
  - Test self-interpreter layers 1 and 2 plus the spec's patch-depth fixture.
  - Accept: all layers agree and recursive evaluation remains patchable.
  - A layer is a term transformer: `Self.interpreting t` is the term that
    interprets `t`, so layer *n* is *n* applications of it. Layer 2 forced one
    change to 2.2's representation — a primitive crosses levels unwrapped,
    because a wrapped one arrives at the bottom level as the middle level's
    wrapper. ADR 0017 records that, the deterministic step budget that decides
    which programs run at layer 2, and why layer 3 is not tested.

## Phase 3 — code and staging foundations

- [x] **3.1 Implement hygienic quotation, splicing, and code patterns.**
  - Quoted lexical variables retain binder IDs; runtime string construction uses
    explicit `NamedVar`.
  - Accept: adversarial same-name splices cannot capture or be captured.
  - Quotation lowers to a quoted Core template with fresh-identity markers and
    pure `code_splice` calls. Constructor patterns use guarded `code_view`;
    quasiquote patterns use alpha-aware `code_match`; Code equality is
    alpha-equivalence. ADR 0018 records the semantics and the decision that a
    structural pattern on the wrong value shape falls through.

- [x] **3.2 Implement closed-code analysis and `run`.**
  - Report all unresolved dependencies; never inherit caller lexical state.
  - Accept: closed code runs and open code fails with useful locations.

- [x] **3.3 Implement the fixed `lift` domain.**
  - Lift scalars, unit, immutable liftable lists, and code. Reject closures,
    continuations, environments, and cells with origin-aware errors.
  - Accept: nested lifting and every rejection category have focused tests.

- [x] **3.4 Add staged-power and simplifier regressions.**
  - Accept: `pow5(2) == 32`; generated code is closed/alpha-correct; quasiquote
    simplifier cases match the spec.

- [x] **3.5 Retire `Ash_self.Encode` in favour of `Code`.**
  - Rewrite `lib/self/eval.ash` to dispatch on Core constructor patterns over
    real Code, after 3.2–3.4 establish closed execution and the complete Code
    regression surface. Delete the temporary encoding rather than growing it.
  - Accept: the interpreter dispatches on constructor patterns, spans cross into
    the interpreted level, the differential test compares failure location as
    well as cause, and `Ash_self.Encode` is removed.

## Phase 4 — lazy tower (milestone 1)

- [x] **4.1 Implement lazy machine/level materialization.**
  - Each level owns cloned globals and fresh open-recursion cells.
  - Track actual materialized size separately from expanded semantic size.
  - Accept: ordinary code creates no upper level; first reflection creates one.

- [x] **4.2 Implement reifiers and the up/down protocol.**
  - Implement whole-call reification, `reflect`, `resume`, and `meta_error` with
    correct level ownership.
  - Accept: identity reifier evaluates effects once; errors reach only level n+1.

- [x] **4.3 Implement `up` and all meta bindings.**
  - Bind `exp`, `env`, `cont`, evaluator cells, `global`, resume/error helpers,
    relative `level`, and explicit `tower_depth()`.
  - Accept: persistent evaluator replacement intercepts arbitrary AST depth and
    does not change the evaluator running its own level.
  - `up { E }` is a reifier applied to no arguments, its body ending in
    `resume(cont, E)`; Core is untouched. `eval` and `apply` are bound the way an
    `open fn` member is, so they are `open_deref`/`open_set` on the level below's
    real group cell and a replacement is persistent and composes. Materializing a
    cell is observationally inert, and a replacement runs on the machine above the
    cell — running it on its own would make it its own interpreter. Five
    Reflection primitives back the readings, and `tower_depth()` reports the
    materialized depth. ADR 0024 records all of it, including why `eval_list` is
    deliberately not a third cell.

- [x] **4.4 Complete tower law tests except overlays.**
  - Cover transparency at depths 0–5, OR, reifier identity, level independence,
    error propagation, one-shot enforcement, and depth observation.
  - Explicitly exclude timing, host stack, resources, and gensym counters.
  - Depth had no meaning the project could test: materialized-but-untouched
    levels are observationally the default evaluator by construction, so
    transparency over them would be vacuous. `Ash_tower.Depth` therefore
    interposes a real Ash identity interpreter at every level below the stated
    depth. `test/laws/tower_laws_test.ml` runs the whole differential corpus plus
    observable-output programs — 96 in all — at depths 0–5, budgeted in counted
    steps. ADR 0025 records the definition and the alternatives;
    `docs/progress/0001-depth-cost.md` records what a level costs.

- [x] **4.5 Package tracing and level-2 counting demos.**
  - Store expected output and expose reproducible CLI commands.
  - Accept: tracing logs every node and level 2 counts level-1 evaluator work.
  - `examples/tracing.ash` and `examples/level_2_counting.ash`, embedded into
    `ash.examples` by a dune rule the way `lib/self/eval.ash` is, so the CLI and
    the golden test cannot run different source. `ash --demo NAME` runs one and
    `ash --demos` lists them; `test/golden/demos.expected` stores exactly what
    the command prints, through the one renderer both use.

## Phase 5 — pure collapser (milestone 2)

- [x] **5.1 Add static/dynamic values and `maybe-lift` evaluator mode.**
  - Static data are real values; dynamic data are `Code(Core)`.
  - One evaluator source supports identity and lifting modes.
  - Accept: ordinary evaluation and constant-folding tests both pass.

- [x] **5.2 Implement hygienic let-insertion.**
  - Use scoped block buffers, fresh IDs, and distinct buffers for dynamic branch
    and lambda bodies. Preserve operation count and evaluation order.
  - Accept: nested emission stays linear on duplication traps.

- [x] **5.3 Stage pure higher-order Core, recursion, and immutable data.**
  - Fold only fully static pure operations; residualize dynamic computation.
  - Accept: residual execution matches recursive/higher-order source programs.

- [x] **5.4 Implement initial collapse metrics and report.**
  - Count semantic/materialized/residual size, interpreter nodes, eval-cell
    dereferences, dispatch sites, `NamedVar` lookups, evaluator calls,
    generalizations, and reflection boundaries, with provenance/reasons.
  - Accept: human output has stable golden tests.

- [x] **5.5 Prove the pure Phase 5 criterion.**
  - Compare source, tower, and residual runs.
  - Accept: every depth-1 pure sample is equivalent with zero Core dispatch and
    zero surviving eval-cell dereferences.

## Phase 6 — depth and recursion control

- [x] **6.1 Implement memoized specialization points and residual `LetRec`.**
  - Key by function identity plus canonical static argument projection.
  - Accept: recursive programs specialize without infinite unrolling.
  - The key is the lambda plus the environment it closed over, both compared
    physically, and a projection of each argument: *known* (static all the way
    down, compared by value), *held* (constructor known, contents partly
    dynamic — compared by identity), *unknown* (residual code). Known and held
    arguments are specialized into the residual function's body; unknown ones
    become its parameters. Inlining stays the default and a call becomes a
    point only when its own key is already being inlined, so everything Phase 5
    collapsed still collapses unchanged. The point belongs to the call that
    started the inlining, not the one that found the cycle, and is bound by a
    `LetRec` where it was created rather than hoisted. ADR 0031.

- [x] **6.2 Implement specialization budgets and generalization.**
  - Progressively mark arguments dynamic on budget pressure; report every reason.
  - Accept: hostile recursive cases terminate with useful diagnostics.
  - Two deterministic limits: nested calls the unroller may follow into one
    function, and residual bindings emitted. The size limit is the
    discriminating one because *an unrolling that is working folds and emits
    nothing* — the corpus's deepest static unrolling is a 10,000-step loop that
    collapses to one literal and emits no bindings. On pressure the call becomes
    a specialization point after giving up the leftmost argument that differs
    from the nearest enclosing call to the same function; the decision is sticky
    per function and monotone, so *k* parameters means at most *k*
    generalizations before the key is fixed. Reification is the one place that
    can only refuse (`Error.Budget_exhausted`), because it is not a call and has
    no argument to give up. ADR 0032.

- [x] **6.3 Implement a semantics-preserving residual normalizer.**
  - Alpha-canonicalize and flatten administrative lets without moving effects.
  - Accept: normalization is idempotent and passes effect counterexamples.
  - `Ash_collapse.Normalize.normalize` applies three rewrites, each
    semantics-preserving by construction: value-position lets flatten however
    deep they nest, trivial bindings (a literal, or a variable nothing in the
    term assigns) substitute away, and alpha-canonical renaming runs last. A
    mention that cannot follow a substitution keeps its whole binding — a `Set`
    target reads its cell, quoted code is data, a reifier body is another
    level's code. Nothing hoists
    out of a lambda, branch, or `LetRec` group; an unused effectful binding
    still happens; idempotence is exact structural equality. `Metrics.measure`
    normalizes before surveying and running the residual. ADR 0033.

- [x] **6.4 Establish depth results for the pure corpus.**
  - Compare normalized residuals at depths 1–5.
  - Accept: ordinary programs equal depth 1; `tower_depth()` examples differ
    but remain semantically correct at each depth.
  - Specialization became depth-aware: attached to a configuration as level 0,
    it folds the statically known `tower_depth()` reading to that depth's
    number (`Metrics.measure` attaches to its real materialized tower;
    `Metrics.specialize ~depth ~env` carries only the faithful reading), so
    ordinary programs produce alpha-equal residuals at depths 0–5 while depth
    observers produce one per depth, each matching what that depth's tower did
    — §9.3's first two classes, measured. `test/laws/depth_invariance_test.ml`
    drives one shared environment for all syntactic comparisons (cloned
    globals give each environment its own identities), proves the normalizer
    load-bearing (raw specializations differ by fresh identities), and requires
    the depth-sensitive samples to fail the invariance check. Budgeted steps,
    skips reported. `examples/depth.ash` shows the shape from the CLI. ADR
    0034.

## Phase 7 — mutation and effects

- [x] **7.1 Enforce primitive effect policy during specialization.**
  - IO always residualizes; allocation/mutation residualizes until proven by the
    store discipline; `static_log` is explicitly compile-time-only.
  - Accept: specialization emits no program-visible output.
  - The gate is structural: `Staged_eval.apply_primitive` consults
    `Effect_class.always_residualizes` before any rule that could fold —
    before `static_reading`, before `may_fold` — so an observable effect cannot
    reach a fold path whatever is added below it. Deliberately redundant with
    `may_fold` today, and pinned as load-bearing: mis-mark the observable class
    as foldable and the gate holds the criterion; remove the gate and the same
    mis-marking makes compilation print. `static_log` is §D7's compile-time
    channel in its own class, `Specialization_only` — the inverse of the
    observable class, running when the specializer meets it and leaving no
    residual call — writing to a second stream that is not program-visible
    output. Allocation and mutation are unchanged and now pinned. ADR 0035.

- [x] **7.2 Implement static-store splitting and dynamic joins.**
  - Fork and conservatively merge abstract stores while retaining alias/cell
    identity; residualize when proof is unavailable.
  - Accept: dynamic-branch mutation and alias fixtures match source behavior.
  - `Ash_stage.Store` decides per binding who owns the cell: *held* means the
    specializer owns it — writes update it, reads fold, nothing survives — and
    *residual* means the residual program owns it, writes becoming `Set` nodes
    and reads a variable. Keyed by the cell rather than the binder, so two names
    for one cell stay one place and one binder evaluated twice stays two.
    Holding is a syntactic proof asked once per binder — not free in any lambda,
    not in quoted data, not spelled by a `NamedVar`, no reifier in scope — and
    failing it residualizes rather than refuses. At a dynamic conditional every
    held binding either branch assigns is given up *before* the fork, then the
    two stores are joined, keeping only what outlives the branch and requiring
    both forks to agree. `Core.assigned_idents` now lives in `Ash_core.Core` and
    is read by both the store and the normalizer, which is what makes ADR 0033's
    value-side guard load-bearing rather than defensive: a residual with a `Set`
    is the first term where substituting a binding's initial value would answer
    with the value before the branch. The domain is bindings, not heap
    allocations — `cell_new`/`deref`/`cell_set` and the open-group trio still
    residualize, so an `open fn` group is still the criterion's boundary sample.
    ADR 0036.

- [ ] **7.3 Build the effect-order differential corpus.**
  - Compare values, output, errors, and observable store at depths 0–5.
  - Accept: tower and residual runs agree; compilation has no runtime effects.
  - Compare *normalized* residuals, as 6.4 does: this corpus is what exercises
    the normalizer's store guard end to end, and a store comparison against raw
    residuals would pass for the wrong reason.

## Phase 8 — scoped meta-overrides

- [ ] **8.1 Implement persistent overlay frames and `meta_with`.**
  - Overlay meta lookup precedes persistent cells; lexical `NamedVar` never sees
    overlays. Never use save/mutate/restore.
  - Accept: nested overrides shadow correctly without changing persistent state.

- [ ] **8.2 Capture overlay context in continuations.**
  - Invocation follows the captured context pointer without mutating ambient
    context.
  - Accept: capture-inside/invoke-outside and nested-error law tests pass.

## Phase 9 — statically known reflective collapse

- [ ] **9.1 Specialize known persistent and scoped evaluator changes.**
  - Inline known wrappers at former dispatch sites while preserving effects.
  - Accept: tracing/counting transformations leave zero interpreter residue.

- [ ] **9.2 Deliver the traced-Fibonacci demo.**
  - Include source, residual Core, report, expected output, and CLI command.
  - Accept: tower and residual output agree byte-for-byte, print calls are inlined
    at former eval sites, and interpreter residue is zero.

## Phase 10 — dynamic reflection and classification

- [ ] **10.1 Split meta state into static and dynamic knowledge.**
  - Specialize monovariantly on known evaluator identity; residualize the smallest
    sound evaluator fragment at dynamic choices and retain provenance.
  - Accept: a runtime trace flag yields an accurately explained partial residual.

- [ ] **10.2 Implement conservative four-way classification.**
  - Pre-check depth observation, dynamic `NamedVar`, and reflection under dynamic
    conditions. Classify depth-invariant full, depth-sensitive full, partial, or
    opaque, clearly labeling conservative results.
  - Accept: curated adversarial samples populate and validate all four classes.

- [ ] **10.3 Complete human and JSON collapse reports.**
  - List residue cases/sites, surviving dereferences, dispatch, generalizations,
    boundaries, and reasons.
  - Accept: totals reconcile with a direct residual AST walk.

- [ ] **10.4 Run the reproducible measurement suite.**
  - Store semantic/materialized/residual sizes, steps, and per-level ratios without
    assuming a curve; pin environment versions and preserve raw data.
  - Accept: every published number is reproduced by one documented command.

## Phase 11 — documentation and release

- [ ] **11.1 Write semantics and implementation documentation.**
  - Cover hygiene, CPS, OR, tower materialization, staging, effects,
    normalization, classification, tested laws, and excluded observations.

- [ ] **11.2 Write the research evaluation.**
  - Present all four classes, depth results, residue explanations, limitations,
    and precise claims without overstating novelty.

- [ ] **11.3 Produce a reproducible release.**
  - From a clean checkout run formatting, compilation, all test classes, demos,
    and measurements; pin OCaml/Dune/dependency versions.
  - Accept: `README.md` alone lets a new user reproduce both milestones and the
    classification report.

## Optional work — after Phase 11 only

- [ ] Multi-shot continuations with explicit store/overlay semantics.
- [ ] Second Futamura projection, then the third only if it is stable.
- [ ] Native backend for a deliberately restricted residual subset.
- [ ] Delimited-control let-insertion comparison.

> Historical handoff logs moved to docs/progress/handoff-log.md.
