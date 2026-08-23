# Ash implementation plan

This is Ash's authoritative execution checklist. Design rationale and semantics
live in `Ash Reflective Tower.md`; this file turns them into verifiable tasks.

## Session protocol

- Read `AGENTS.md`, this file, and the relevant spec sections at session start.
- The first unchecked item in document order is the default next task.
- Mark `[x]` only after implementation, tests, and documentation satisfy the
  stated acceptance criterion. Leave partial work unchecked.
- After each task, update **Current state** and prepend a **Handoff log** entry.
- If evidence requires a spec change, write a decision record, update the spec,
  and update this plan in the same change. Never silently diverge.

## Current state

- **Phase:** 3 — code and staging foundations
- **Next:** 3.2 — implement closed-code analysis and `run`
- **Last verified:** 2026-08-23 — `opam exec -- dune build @all`,
  `opam exec -- dune runtest --force`, and `opam exec -- dune exec ash -- --help`
  pass from a clean `_build` with the hygienic desugarer, `open fn` groups, the
  Ash self-interpreter (`lib/self/eval.ash`) running at layers 1 and 2, the
  36-primitive registry (including the five pure Code operations), the
  desugar/continuation/parser/lexer/Core/runtime suites, the open-recursion law
  suite including patching at depth, and three differential comparisons over the
  shared 91-program corpus (73 Core, 18 surface): oracle/CPS, CPS/layer 1, and
  layers 0/1/2
- **Blocker:** none

Phase 2 is complete. `open fn` is a surface binding form that lowers to
open-recursion cells; the CPS Core evaluator is written in Ash and agrees with
the host evaluator; and it runs under itself, with every layer agreeing and each
layer's `eval` cell governing exactly the evaluation that layer performs. Task
3.1 now supplies hygienic `Code`, quotation/splicing, and both constructor and
quasiquote patterns. The self-interpreter deliberately retains its Phase 2 data
encoding until task 3.5, after 3.2–3.4 complete the Code foundation; that task
owns both declared boundaries rather than changing the layer tests during 3.1.

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

- [ ] **3.2 Implement closed-code analysis and `run`.**
  - Report all unresolved dependencies; never inherit caller lexical state.
  - Accept: closed code runs and open code fails with useful locations.

- [ ] **3.3 Implement the fixed `lift` domain.**
  - Lift scalars, unit, immutable liftable lists, and code. Reject closures,
    continuations, environments, and cells with origin-aware errors.
  - Accept: nested lifting and every rejection category have focused tests.

- [ ] **3.4 Add staged-power and simplifier regressions.**
  - Accept: `pow5(2) == 32`; generated code is closed/alpha-correct; quasiquote
    simplifier cases match the spec.

- [ ] **3.5 Retire `Ash_self.Encode` in favour of `Code`.**
  - Rewrite `lib/self/eval.ash` to dispatch on Core constructor patterns over
    real Code, after 3.2–3.4 establish closed execution and the complete Code
    regression surface. Delete the temporary encoding rather than growing it.
  - Accept: the interpreter dispatches on constructor patterns, spans cross into
    the interpreted level, the differential test compares failure location as
    well as cause, and `Ash_self.Encode` is removed.

## Phase 4 — lazy tower (milestone 1)

- [ ] **4.1 Implement lazy machine/level materialization.**
  - Each level owns cloned globals and fresh open-recursion cells.
  - Track actual materialized size separately from expanded semantic size.
  - Accept: ordinary code creates no upper level; first reflection creates one.

- [ ] **4.2 Implement reifiers and the up/down protocol.**
  - Implement whole-call reification, `reflect`, `resume`, and `meta_error` with
    correct level ownership.
  - Accept: identity reifier evaluates effects once; errors reach only level n+1.

- [ ] **4.3 Implement `up` and all meta bindings.**
  - Bind `exp`, `env`, `cont`, evaluator cells, `global`, resume/error helpers,
    relative `level`, and explicit `tower_depth()`.
  - Accept: persistent evaluator replacement intercepts arbitrary AST depth and
    does not change the evaluator running its own level.

- [ ] **4.4 Complete tower law tests except overlays.**
  - Cover transparency at depths 0–5, OR, reifier identity, level independence,
    error propagation, one-shot enforcement, and depth observation.
  - Explicitly exclude timing, host stack, resources, and gensym counters.

- [ ] **4.5 Package tracing and level-2 counting demos.**
  - Store expected output and expose reproducible CLI commands.
  - Accept: tracing logs every node and level 2 counts level-1 evaluator work.

## Phase 5 — pure collapser (milestone 2)

- [ ] **5.1 Add static/dynamic values and `maybe-lift` evaluator mode.**
  - Static data are real values; dynamic data are `Code(Core)`.
  - One evaluator source supports identity and lifting modes.
  - Accept: ordinary evaluation and constant-folding tests both pass.

- [ ] **5.2 Implement hygienic let-insertion.**
  - Use scoped block buffers, fresh IDs, and distinct buffers for dynamic branch
    and lambda bodies. Preserve operation count and evaluation order.
  - Accept: nested emission stays linear on duplication traps.

- [ ] **5.3 Stage pure higher-order Core, recursion, and immutable data.**
  - Fold only fully static pure operations; residualize dynamic computation.
  - Accept: residual execution matches recursive/higher-order source programs.

- [ ] **5.4 Implement initial collapse metrics and report.**
  - Count semantic/materialized/residual size, interpreter nodes, eval-cell
    dereferences, dispatch sites, `NamedVar` lookups, evaluator calls,
    generalizations, and reflection boundaries, with provenance/reasons.
  - Accept: human output has stable golden tests.

- [ ] **5.5 Prove the pure Phase 5 criterion.**
  - Compare source, tower, and residual runs.
  - Accept: every depth-1 pure sample is equivalent with zero Core dispatch and
    zero surviving eval-cell dereferences.

## Phase 6 — depth and recursion control

- [ ] **6.1 Implement memoized specialization points and residual `LetRec`.**
  - Key by function identity plus canonical static argument projection.
  - Accept: recursive programs specialize without infinite unrolling.

- [ ] **6.2 Implement specialization budgets and generalization.**
  - Progressively mark arguments dynamic on budget pressure; report every reason.
  - Accept: hostile recursive cases terminate with useful diagnostics.

- [ ] **6.3 Implement a semantics-preserving residual normalizer.**
  - Alpha-canonicalize and flatten administrative lets without moving effects.
  - Accept: normalization is idempotent and passes effect counterexamples.

- [ ] **6.4 Establish depth results for the pure corpus.**
  - Compare normalized residuals at depths 1–5.
  - Accept: ordinary programs equal depth 1; `tower_depth()` examples differ but
    remain semantically correct at each depth.

## Phase 7 — mutation and effects

- [ ] **7.1 Enforce primitive effect policy during specialization.**
  - IO always residualizes; allocation/mutation residualizes until proven by the
    store discipline; `static_log` is explicitly compile-time-only.
  - Accept: specialization emits no program-visible output.

- [ ] **7.2 Implement static-store splitting and dynamic joins.**
  - Fork and conservatively merge abstract stores while retaining alias/cell
    identity; residualize when proof is unavailable.
  - Accept: dynamic-branch mutation and alias fixtures match source behavior.

- [ ] **7.3 Build the effect-order differential corpus.**
  - Compare values, output, errors, and observable store at depths 0–5.
  - Accept: tower and residual runs agree; compilation has no runtime effects.

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

## Handoff log

Prepend entries, newest first. Include completed task, exact verification, design
decisions, known issues, and exact next task.

### 2026-08-23 — task 3.1

- Completed 3.1: hygienic quotation, splicing, constructor patterns, and
  quasiquote patterns.
  - A quotation lowers to `Quote` of a Core template. Every `${...}` position is
    a fresh free `Var` marker replaced by the pure `code_splice` primitive using
    exact identifier identity. Quoted lexical binders remain visible to nested
    quotations inside splice expressions; otherwise unbound quoted names get a
    fresh identity so Code may be open while it is assembled.
  - `Ash_core.Code` implements the identity substitution and alpha-aware
    quasiquote template matcher. `Value.equal` now compares Code with
    `Alpha.equal`, so allocation order and parameter spelling are not Code
    observations.
  - `code?` and `code_view` expose all eleven Core forms without enlarging the
    value domain: syntactic fields are Code, identifiers are one-node `Var` Code,
    and recursive bindings are pairs of identifier and lambda Code. Constructor
    patterns lower to a guarded view; `code_match` supplies Code captures to the
    full patterns inside quasiquote holes. `NamedVar(string)` is the explicit
    runtime-string constructor required by D1.
  - The registry grows from 31 to 36 primitives. All five Code operations are
    Pure under D7 because they inspect or construct immutable values;
    `Effect_class.Reflection` remains empty until evaluator-dependent execution
    and tower operations arrive.
- Acceptance: `test/unit/code_test.ml` and `test/unit/desugar_test.ml` exercise
  both adversarial directions. A free `x` spliced under `fn(x)` remains free and
  distinct from the binder; a binder `x` carried by a splice remains distinct
  from same-named template code. They also cover nested quotation scope, open
  quoted names, explicit `NamedVar`, alpha-aware Code equality, constructor
  fields, quasiquote holes, and non-Code splice errors. `primitives_test.ml`
  enumerates all eleven `code_view` tags and independently pins class, arity,
  and type behavior.
- Settled the pre-Phase-3 match question: a structural pattern on the wrong
  value shape refutes and falls through. `match 5 { [] -> 'empty; _ -> 'other }`
  now answers `'other`; `list?` and `code?` guard accessors. Directly calling an
  accessor on a wrong value remains a type error. ADR 0018 records this semantic
  change, the Code representation, and the primitive classification.
- Parser/desugarer review: no grammar rewrite was needed. Added parser coverage
  for a nested quotation inside a splice and a quoted named definition. Quote
  bodies remain one statement-shaped expression; a multi-statement quoted body
  is written as an explicit inner block, consistently with the existing surface
  AST. Golden lowering now exposes quotation, constructor/quasiquote matches,
  and the wrong-shape guards.
- Scope decision: `lib/self/eval.ash`, `Ash_self.Encode`, and the layer tests are
  semantically unchanged. Added task 3.5 to retire the encoding only after
  3.2–3.4, accepting when constructor dispatch replaces tag dispatch, spans
  cross into the interpreted level, failure locations join causes in the
  differential comparison, and the encoding module is deleted.
- Verified from a clean `_build` with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, and `git diff --check` all pass. The
  suite reports 73 Core plus 18 surface differential programs; 99 programs at
  self-interpreter layer 1; and 98 at layer 2, with only the 310019-step loop
  above the unchanged 800-step budget.
- Known issues: the two Phase 2 interpreter boundaries deliberately remain —
  its temporary data encoding carries no spans, and failures detected in Ash do
  not yet have the host cause/location pair. Task 3.5 owns both. Closed-code
  checking and execution are not part of 3.1; open Code cannot be passed to
  `run` until 3.2.
- Next: 3.2 — implement closed-code analysis and `run`, reporting every
  unresolved dependency and never inheriting caller lexical state.

### 2026-08-23 — task 2.3 (Phase 2 complete)

- Completed 2.3: iteration and invariant OR at depth.
  - **A layer is a term transformer.** `Self.interpreting t` builds the Core term
    that interprets `t` — the interpreter applied to the encoded program and the
    encoded globals, with both written *into* the term rather than passed beside
    it — so the result is itself something a further layer can interpret and
    layer *n* is *n* applications of one function. `Encode.datum` is what makes a
    value writable into a term: a list becomes a call of `list` and a primitive
    becomes a reference to the global that denotes it, Core literals holding only
    constants.
  - **Layer 2 forced one change to 2.2's representation.** A primitive now
    crosses levels unwrapped. `Encode.datum` writes a primitive as a `Var`, and a
    `Var` is resolved by whatever level evaluates it, so a wrapped primitive
    would arrive at the bottom level as the *middle* level's wrapper — a list,
    not something applicable. Three things fell out, all improvements: the
    `'prim` case in `apply` disappeared (a primitive is not tagged, so it takes
    the branch that delegates below, which is what applying a primitive means);
    `callcc` is recognized by value, `f == callcc`, so a program that renames it
    is still caught and one that shadows it with its own function correctly is
    not; and `Encode.reveal` leaves a primitive alone, so a program that returns
    one is now comparable rather than merely tagged alike.
  - **Layer-2 coverage is decided by a step budget, not a clock.** A program runs
    at layer 2 when its layer-0 run takes at most 800 evaluator steps — a
    property of the program, not of the machine. That admits 98 of 99 programs;
    the ten-thousand-iteration loop is the exclusion and its step count is
    printed.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all passed. `git diff --check` passed.
  The suite takes about ten seconds, essentially all of it layer 2.
- Acceptance 2.3, all layers agree: `test/differential/self_layers_test.ml`
  compares layers 0, 1, and 2 on all 91 corpus programs plus eight written for
  this task — output and control, which are the two things most likely to be lost
  on the way down a second level, and closures and primitives as values, which
  are what `reveal` and the unwrapping decision are about. It was checked by
  re-wrapping primitives in `eval.ash`, which left layer 1 almost entirely
  passing and broke layer 2 across the board.
- Acceptance 2.3, still patchable: `test/laws/open_recursion_test.ml` gains the
  patch-depth fixture. §D3's `1 + (2 * (3 - (4 / 5)))` with the patch on the
  layer that runs it observes 13 nodes — exactly the count at depth 1, even
  though the patched interpreter is itself being interpreted; with the patch on
  the layer beneath, 3540 steps, because its subject is the interpreter rather
  than the program. `apply` and `eval_list` at depth observe 4 and 12, which are
  the four operator applications and the three `eval_list` calls each
  two-argument application makes. Every variant answers the ground value.
- Decisions: ADR 0017 records layer composition, the primitive representation
  change (amending ADR 0016, which now says so), the step budget, and why layer 3
  is not tested — it runs, but takes about two minutes on the smallest useful
  program, which is a suite nobody runs rather than a stronger claim. Spec §5.7's
  open-recursion law is ticked; it asked to be tested in Phase 2 and now is,
  at depth.
- Known issues: the two boundaries 2.2 declared are unchanged — an encoded term
  carries no spans, and Ash cannot construct a structured error. Both are Phase 3
  questions about `Code`, not about the interpreter. Layer 3 and beyond work but
  are untested for cost.
- Next: Phase 3, task 3.1. Note for that work: `Code` arriving is what replaces
  `Ash_self.Encode`, lets `eval.ash` dispatch with constructor patterns instead
  of an `if` chain over the form tag, and carries the spans that would close both
  known boundaries.

### 2026-08-23 — tasks 2.1 and 2.2

- Completed 2.1: open-recursive evaluator groups at the Ash level.
  - `open fn` is now a surface binding form. The lexer had reserved `open` since
    1.1; the parser accepts it only as the head of a definition, `Surface`
    records it as `function_open` on a named function, and adjacent declarations
    of the *same* kind form one group — a `fn` run ends where an `open fn` run
    begins.
  - Lowering is cells, not `LetRec`: one `open_cell` per member, an `open_set`
    filling each with its lambda, and every reference to a member — inside the
    group and after it — as `open_deref` of that cell. `member := …` writes
    through the cell with `open_set` rather than rebinding the name, so every
    dereference already written sees the replacement. Members are assignable;
    plain `fn` bindings still are not.
  - References *after* the group are dereferences too. §D3's wording is about the
    group's own recursion, but an external caller holding the function directly
    would be a reference no replacement reaches, and the spec's own test is
    written from outside the group.
  - Three primitives were added, spelled apart from `cell_new`/`deref`/`cell_set`
    so the collapse report can count evaluator dereferences without guessing
    which cells were an interpreter's: `open_cell`, `open_deref`, `open_set`,
    all allocation/mutation. `Primitives.open_dereferences` counts reads
    performed (after the read succeeds — a refused read is not a dereference) and
    is observationally inert.
- Completed 2.2: the CPS Core evaluator written in Ash, `lib/self/eval.ash`,
  loaded and run by the new `ash.self` library.
  - It is parallel to the host evaluator: same eleven forms, same evaluation
    order, same CPS, same open group. It reads a term as tagged list data because
    quotation is Phase 3, and dispatches on the form tag with an `if` chain
    because Core constructor patterns do not lower until Phase 3 either.
  - Interpreted scalars, lists, and cells represent themselves; closures,
    reifiers, continuations, and primitives are lists headed by a private cell
    the interpreted program cannot name or forge. Each closure carries a fresh
    cell as its identity, so `==` compares places rather than shapes.
  - Two primitives were added rather than worked around: `invoke(f, args)`,
    which is §6's `prim_apply` and applies a callee to a run-time-length argument
    list (control class — its class is its callee's), and `list?`, the one type
    test, needed to tell a tagged closure from a scalar without an accessor that
    refuses. No host escape hatch: the interpreted level gets exactly the globals
    a level-0 run gets, and delegates everything else to them, which is why its
    arity, type, and arithmetic diagnostics are the host's.
  - `callcc` is the one primitive it cannot delegate — the host would capture the
    interpreter's continuation — so the interpreted level builds its own one-shot
    continuation, marked used before transfer.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all passed. `git diff --check` passed.
- Acceptance 2.1: `test/laws/open_recursion_test.ml` shows a wrapper on `eval`
  observing every nested AST node — thirteen for §D3's `1 + (2 * (3 - (4 / 5)))`,
  against the nine the spec asks for as a lower bound, and equal to
  `Core.node_count` — plus `apply` and `eval_list` patchable on the same terms, a
  replacement installed mid-evaluation taking effect at the next step (counted
  exactly), restoration of the cell restoring the group, and the dereference
  counter being inert.
- Acceptance 2.2: `test/differential/self_host_test.ml` compares the host
  evaluator and the self-interpreter on all 91 corpus programs plus 4 output and
  4 control programs, on value, cause, and observable trace. The corpus moved to
  `test/differential/corpus.ml` and both differential tests read it, so the
  second comparison cannot be run against easier programs than the first. The
  harness was checked by reversing `eval_list`'s order in `eval.ash`, which
  produced a readable minimal difference on exactly the two evaluation-order
  programs.
- Decisions: ADR 0015 (`open fn`, why references outside the group dereference
  too, why the `open_*` trio is spelled apart, why the counter is on the
  registry) and ADR 0016 (the interpreter's encoding and value domain, `invoke`
  and `list?`, delegation as the way to keep diagnostics honest, and the two
  declared boundaries). Spec §6 gained a note saying which two things in its
  sketch are deferred and pointing at ADR 0016; AGENTS gained `lib/self/` in the
  layout. The registry is 31 primitives and `Effect_class.Control` is now
  `callcc` and `invoke`.
- Known issues: **locations do not cross the encoding.** A term encoded as data
  carries no spans, so a failure raised at the interpreted level is reported
  inside `eval.ash`; the differential test therefore compares cause and not
  location. **Ash cannot construct a structured error**, so four corpus programs
  — the three closure arity errors and the surface one — report as
  `No_matching_clause` naming the condition instead of the host's
  `Arity_error`. Both are listed in `self_host_test.ml`, and the exemption list
  is asserted to be exactly the set that needs it, so a program that starts
  agreeing fails rather than sitting under an exemption nobody rechecks. Both
  are Phase 3 questions: they are about `Code` carrying spans, not about the
  interpreter. Printing an interpreted closure would print its tagged list rather
  than `#<closure>`; nothing in the corpus does.
- Next: 2.3 — test iteration and invariant OR. Run the self-interpreter on
  itself (layers 1 and 2) plus the spec's patch-depth fixture, and check that all
  layers agree and that recursive evaluation stays patchable at depth. The
  encoding is the thing to watch: layer 2 interprets layer 1's *encoded* text, so
  `Ash_self.Encode` has to survive being applied to the lowering of `eval.ash`
  itself.

### 2026-08-23 — tasks 1.5 and 1.6 (Phase 1 complete)

- Completed 1.5: first-class one-shot continuations.
  - `callcc` is registered in the previously empty `Control` class. It reifies
    the continuation of its own call and applies its receiver to it. Nothing
    about control reaches Core: a surface `callcc(f)` lowers to an ordinary
    application, so the eleven forms and the future self-interpreter are
    untouched. Spelled without a slash because `/` is division and a control
    operator a program cannot write is not much of one.
  - Capturing exposed a real gap: `Value.primitive` claimed control primitives
    could be ordinary registry members, but `prim_impl` had no way to call an Ash
    function. It now takes `~apply`, supplied by the caller — the ground
    evaluator routes it through the machine's open-recursion cell, so a replaced
    `apply` intercepts a primitive's callback too (§D3), and the oracle passes
    its own direct-style apply read as CPS. A test asserts the interception.
  - Applying a continuation is handled in `Evaluator.apply`: exactly one
    argument, the `used` flag set **before** the transfer, and a second
    invocation raising `Error.Continuation_reuse` with both the capture site and
    the first-use site, reported at the second invocation and at the
    continuation's level.
  - The meta-context retained is the tower level: `Value.continuation` takes
    `~level` and `Value.continuation_level` reads it. Only level 0 exists before
    Phase 4; the field is there now because retrofitting it means revisiting
    every capture site.
- Completed 1.6: the oracle/CPS differential corpus, extended from 46 to 91
  programs and from one comparison to four.
  - Each program is compared on value, failure cause, failure location, and
    observable trace, and only the **first** difference is reported: a report
    that lists everything two runs disagree about buries the one fact that
    explains the rest.
  - The corpus has a Core half (73 programs in canonical notation, which is what
    the self-interpreter will read) and a surface half (18 Ash programs lowered
    by the desugarer, which puts the parser and desugarer under the same
    comparison). Both cover recursion, closures, shadowing, lists, mutation,
    evaluation order, and failures.
  - Every entry declares `Succeeds` or `Fails`. Agreement alone proves nothing —
    two evaluators that both refused everything would agree perfectly — and the
    check immediately caught one entry that had been filed under errors while
    succeeding by design.
  - The harness's own reporting is tested against outcomes known to differ, and
    the frozen boundary now also covers `callcc`, observable effects, and cells.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all passed. `git diff --check` passed.
- Acceptance 1.5: `test/unit/continuation_test.ml` covers storage in a mutable
  binding and in a list, capture in one function with invocation from another
  after that function returned, escape from a recursion, abandonment of the rest
  of the receiver, the second-use error with all three sites distinct and the
  level recorded, reuse reached through the continuation's own resumption, both
  arities, and the oracle's refusal of `callcc` and of applying a continuation.
- Acceptance 1.6: all 91 programs agree; the failure path reports one readable
  difference, checked directly.
- Decisions: ADR 0014 records `callcc` as a primitive rather than syntax, its
  spelling, the `~apply` widening of `prim_impl` and why the applier is the
  caller's, before-transfer marking, the three-site reuse diagnostic, the level
  field as the retained meta-context, and why multi-shot waits. Added the
  `Continuation_reuse` error cause. The registry is 26 primitives and
  `Effect_class.Control` is no longer empty; the test that asserted it was empty
  now asserts it is exactly `callcc`, so filling it stayed deliberate.
- Known issues: none within Phase 1. Multi-shot continuations, and therefore
  backtracking reifiers, `amb`, generator re-entry, and re-entrant `meta_with`,
  are deferred by §D4. `Effect_class.Reflection` is still honestly empty. The
  differential corpus compares traces but every pure program leaves an empty one,
  because the oracle refuses observable primitives by design; trace comparison
  becomes load-bearing when residual programs arrive.
- Next: 2.1 — the Ash-level open-recursive evaluator group. The host side is
  done (`Ash_runtime.Machine`, ADR 0008) with its acceptance test at host level;
  what remains is storing `eval`, `apply`, and `eval-list` in per-level cells in
  Ash, instrumenting every dereference, and testing the same law there: wrapping
  `eval` must observe every nested AST node, not just entry.

### 2026-08-23 — task 1.4

- Completed: `Ash_syntax.Desugar`, the hygienic lowering from the surface tree to
  the eleven Core forms.
  - Names become identities here and nowhere else: one `Ident.fresh` per binder,
    every occurrence resolved through a scope. A free name is a located desugar
    error rather than a `NamedVar`, so resolution by printed name stays a
    property of reflective code and of the collapse report's count.
  - Globals are a parameter (`Desugar.scope_of_globals`), so `ash.syntax` still
    does not depend on `ash.runtime` and task 4.1's per-level cloned globals will
    drop straight in. Generated calls resolve against the globals rather than the
    lexical scope, which is what makes the documented `fn length(xs)` work while
    it shadows the `length` primitive.
  - Sugar lowered: statement sequencing, `let`/`var` with static mutability,
    `:=`, named functions as `LetRec` groups over adjacent declarations, lambdas,
    blocks, conditionals, `&&`/`||` as `If`, `!`/unary `-`, list literals, cons,
    comparison and arithmetic operators, pipelines, and `match`.
  - `match` binds its scrutinee once and thunks each clause's failure
    continuation, so a pattern can mention failure repeatedly without copying the
    remaining clauses; alternative clauses bind their shared body as a function of
    the clause's binders. Falling off the end calls the new `match_error`
    primitive.
  - Provenance: a Core node produced by a surface node of the same shape keeps
    its span; every invented node keeps the same positions and records its
    rewrite (`desugar/seq`, `desugar/unit`, `desugar/fn`, `desugar/operator`,
    `desugar/negate`, `desugar/pipe`, `desugar/and`, `desugar/or`,
    `desugar/list`, `desugar/match`).
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all passed from a clean build. The full
  suite includes the new `test/unit/desugar_test.ml` and
  `test/golden/desugar.expected`, the updated `primitives_test`, and the retained
  46-program oracle/CPS differential corpus.
- Acceptance: `test/unit/desugar_test.ml` parses, lowers, and runs `fact(5)` and
  `fact(20)`, the documented §4.2 `length` over `[1,2,3]` and `[]`, pipeline
  chains into both a user function and a primitive, shadowing (`let x = 1; let x
  = x + 1; x` is 2, and a shadowed `list` does not change what `[…]` means), and
  `set` through a closure (`var c = 0; fn bump() = c := c + 1` is visible after
  two calls). Shape tests compare each sugar row against expected Core up to
  alpha-equivalence, and `test/golden/desugar.expected` pins the documented
  programs, the provenance table, and every diagnostic.
- Decisions: ADR 0013 records identity allocation here, free names as errors,
  globals as a parameter with generated calls bypassing the lexical scope,
  adjacent `fn` declarations as one `LetRec` group, a trailing definition
  evaluating to unit, static `var`/`let` mutability, the thunked `match`
  lowering, `match_error` as a pure primitive, the Elixir-style pipeline rule,
  and the shape-correspondence provenance rule. Added the `Immutable_binding` and
  `No_matching_clause` error causes and the `match_error` primitive (registry now
  25).
- Known issues: none within 1.4. Quotation, splicing, Core constructor patterns,
  and quasiquote patterns are refused with `Unsupported` naming the missing
  phase; 3.1 removes those refusals. Match compilation is intentionally
  unoptimized — an irrefutable last clause still allocates its failure thunk —
  because residualization, not the desugarer, is where size is meant to be won.
- Next: 1.5 — first-class one-shot continuations: retain the continuation
  procedure, used flag, capture site, and meta-context; mark used before
  transfer; report both capture and first-use sites on reuse; and cover storage,
  delayed and cross-function invocation, and the second-use error.

### 2026-08-23 — task 1.3

- Completed: the complete source-located pattern grammar and the match,
  quotation, and splice syntax needed to represent it.
  - `Surface.pattern` covers wildcard, integer/string/symbol/boolean/unit
    literals, variables, list patterns, right-associative cons, alternatives,
    all eleven Core constructors, quasiquote patterns, and grouping.
    `Surface.pattern_binders` retains source order for hygienic lowering.
  - `Parser.pattern` and match-clause parsing share the same implementation.
    Match clauses use newline/semicolon layout and cannot be empty. Core
    constructor spellings form a closed vocabulary with exact arity checks.
  - Quotation is syntax-only at this phase. A splice is tagged as either
    `Expression_splice` or `Pattern_splice`, so quasiquote holes can contain full
    patterns and participate in binder validation without being reinterpreted
    after parsing.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/parser_test.exe`,
  `opam exec -- dune exec test/unit/error_test.exe`,
  `opam exec -- dune runtest`, `opam exec -- dune build @all`, and
  `opam exec -- dune exec ash -- --help` all passed. The full suite retained the
  46-program oracle/CPS differential corpus. `git diff --check` passed.
- Acceptance: the exact documented `length` and `simplify` programs parse and
  are pinned structurally in `test/golden/parser.expected`. The same golden also
  shows every Core constructor pattern, both pattern precedence rows, expression
  versus pattern splices, and located failures for duplicate binders,
  inconsistent alternatives, unknown/wrong-arity constructors, stray splices,
  and malformed lists. Unit tests traverse expression and pattern trees to
  verify their source spans.
- Decisions: ADR 0012 records unique binders per match path; identical binder
  sets across alternative arms; right-associative pattern cons; the closed,
  arity-checked Core constructor vocabulary; context-tagged splices; and
  newline/semicolon match-clause layout. Added the structured
  `Inconsistent_pattern_binders` error cause. The spec's contradictory
  constructor illustration now uses separate clauses instead of one
  differently-binding alternative; ADR 0011 was clarified to place syntax-only
  quote/splice parsing here while retaining all hygiene and execution semantics
  for Phase 3.
- Known issues: none within 1.3. Quote/splice nodes deliberately have no dynamic
  or hygienic meaning yet; 1.4 only needs to preserve them, while Phase 3 defines
  code construction, hygiene, lifting, and execution.
- Next: 1.4 — hygienically desugar sequencing, `var`, named functions, match,
  Boolean sugar, lists, and pipelines to Core while preserving spans and
  generated-node provenance; prove `fact`, `length`, pipelines, shadowing, and
  mutation end to end.

### 2026-08-23 — task 1.2

- Completed: the source-located surface AST, handwritten precedence parser, and
  structural debug printer.
  - `Ash_syntax.Surface` preserves located names, binding mutability, recursive
    named declarations, anonymous functions, calls, blocks, conditionals, lists,
    mutation, grouping, and unary/binary operators for hygienic lowering in 1.4.
    Whole nodes and operator tokens retain spans; no hygienic ID is allocated by
    parsing.
  - `Ash_syntax.Parser.expression` accepts exactly one statement-shaped form;
    `Parser.program` accepts statement lists separated by newline or `;`.
    Newlines remain whitespace wherever the grammar already expects an
    expression, including after a function `=` and inside calls/lists.
  - The recursive-descent layers implement the spec table literally: pipeline,
    `||`, `&&`, comparisons, right-associative `::`, additive, multiplicative,
    unary, and left-associative calls. Other binary layers associate left.
    Mutation is right-associative below pipelines and requires a name target.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/parser_test.exe`,
  `opam exec -- dune runtest`, `opam exec -- dune build @all`, and
  `opam exec -- dune exec ash -- --help` all passed. The full test run retained
  the 46-program oracle/CPS differential result. `git diff --check` passed.
- Acceptance: `test/golden/parser.expected` exposes every adjacent precedence
  boundary, the complete precedence ladder, and associativity at every level,
  plus bindings, mutation, named/anonymous functions, calls, blocks,
  conditionals, lists, pipelines, layout, and located diagnostics. Focused unit
  tests additionally traverse parsed trees to ensure all nodes have source spans.
- Decisions: ADR 0011 records contextual statement layout; explicit surface AST
  retention; left association for every binary row not marked otherwise by the
  spec; right association for cons and mutation; mutation below pipelines;
  trailing-comma rejection; and parser-level rejection of field access, which
  ADR 0010 had required because Ash has no field-bearing values.
- Known issues: none within 1.2. Reserved syntax for match/patterns, quotation,
  and tower forms remains deliberately unparsed until its checklist task, so no
  placeholder AST claims unsupported semantics.
- Next: 1.3 — add wildcard, literal, variable, list, alternative, Core
  constructor, and quasiquote patterns; reject inconsistent binders; make the
  documented `length` and `simplify` examples parse.

### 2026-08-23 — task 1.1

- Completed: the surface lexer, its token vocabulary, and the first golden tests.
  - `Ash_syntax.Token`: the 50-kind lexicon of spec §4, with three renderings —
    `spelling` (write it back as source), `describe` (the noun phrase after
    "expected" or "found"), and `name` (the tag reports print). Every token
    carries a span and whether a line break precedes it.
  - `Ash_syntax.Lexer`: `#` comments, integer/string/symbol/boolean literals,
    names and the thirteen reserved words, operators by maximal munch, `` `{ ``
    and `${` as single tokens, and punctuation. `is_name` is the single place
    that knows what a name looks like.
  - `Ash_syntax.Cursor`: extracted from the s-expression reader and now shared
    with it, so the two notations cannot disagree about where a character is.
    `Sexp` is unchanged apart from using it.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are
  `test/unit/lexer_test.ml` and `test/golden/`; both were validated by
  perturbing the lexer — dropping `|>` from the two-character table and letting
  a number run into a name — and confirming each produced a readable failure and
  a reviewable golden diff before being restored.
- Acceptance: `test/golden/lexer.expected` pins the maximal-munch table for
  every ambiguous operator prefix (`| || |>`, `= ==`, `! !=`, `< <=`, `> >=`,
  `: :: :=`, `- ->`, `&&`, `` ` ``/`$` plus brace) and the rendered diagnostic
  for every malformed literal and stray character, alongside the token stream
  for each §4–§6 sample in the spec. The unit test ends by checking the corpus
  produced every token kind, so a kind nobody lexes fails naming itself.
- Decisions: ADR 0010 records the surface lexicon and layout — `#` comments here
  and `;` there, a `starts_line` flag rather than newline tokens or mandatory
  semicolons, malformed literals refused rather than split, `?` allowed at the
  end of a name and `!` never in one, reserving a word only when the parser must
  recognize it before parsing what follows (which is why `meta_with` is reserved
  and `run`/`lift`/`reflect`/`eval` are not), maximal munch with `:` and `&`
  deliberately absent from the one-character table, and golden files compared by
  dune's `diff` action so the diff is the review.
- Known issues: none. `.` is lexed although no parser consumes it yet — Ash
  values have no fields, so 1.2 will reject it in the grammar, which gives a
  better message than rejecting it in the scanner.
- Next: 1.2 — the precedence parser: bindings, mutation, functions, calls,
  blocks, conditionals, lists, pipelines, and the spec's exact
  precedence/associativity table, with golden tests at every precedence
  boundary.

### 2026-08-23 — task 0.9 (Phase 0 complete)

- Completed: the classified primitive registry and the observable-effect stream.
  - `Ash_runtime.Io`: an injectable stream recording `Wrote` and `Read` events in
    order, with scripted input, an optional echo channel, and `trace`/`text`
    renderings. Observable effects are values a test can compare rather than
    characters that have left the process.
  - `Ash_runtime.Primitives` is now a registry instance over a stream, not a
    constant list. Added `cell_new`, `deref`, `cell_set` (allocation/mutation)
    and `print`, `println`, `read_line` (observable effect) to the existing
    eighteen pure primitives. `classification`, `class_of`, `by_class`, `names`,
    and `count` are derived from the registry rather than written twice;
    construction refuses a duplicate name, which is the only way two classes
    could attach to one name.
  - Control and reflection are registered empty. `call/cc` needs 1.5 and `lift`,
    `run`, `reflect`, `up` need staging and the tower; a primitive that exists
    but refuses to run would claim a capability Ash does not have.
  - `Error.End_of_input` is a new cause, for `read_line` past the last line.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/primitives_test.ml`; the harness was validated by perturbing the
  registry four ways — reclassifying `print` as pure, dropping `println`'s
  newline, making `cell_set` write a constant, and giving `not` the wrong arity —
  and confirming each produced a readable failure before being restored.
- Acceptance: every primitive has exactly one class (the classes partition the
  registry, checked over `Effect_class.all`, and the test carries its own
  classification table so an unclassified addition fails), and arity and type
  errors are consistent registry-wide — every primitive is applied at every wrong
  count, through the evaluator and directly, and both paths must report the same
  cause at the call site; each primitive's rejections are listed in a table whose
  keys must equal the registry's names.
- Decisions: ADR 0009 records the registry-as-instance shape, buffered and
  scripted IO, `print` writing a string's characters while a diagnostic writes its
  literal, `cell_set` rather than the spec's `set` (Core already has a `Set`
  form), immutable list operations staying pure because the allocation class is
  about cells, and empty control/reflection classes over stubs.
- Known issues: none. `test/unit/oracle_test.ml` now checks the frozen boundary
  against the registry — it refuses every non-pure primitive by class, so a
  primitive added to any other class is outside the oracle the day it is
  registered.
- Next: 1.1 — the lexer with source spans. Phase 0 is complete: Core, the
  reader/printer, the oracle, the CPS evaluator, and the primitive registry all
  pass their acceptance criteria from a clean process.

### 2026-08-23 — task 0.8

- Completed: added `Machine` and `Evaluator` to `ash.runtime`.
  - `Machine`: `eval`, `apply`, and `eval_list` in mutable cells, with every
    group call going through the module so each one re-reads its cell, plus
    counters for group calls, per-form dispatches, cell dereferences, and
    `NamedVar` lookups.
  - `Evaluator`: all eleven Core forms in CPS. `LetRec` preallocates cells then
    fills them with closures over the extended environment. `Quote` yields code
    and `Reifier` yields a reifier value; applying a reifier (needs 4.2) or a
    continuation (needs 1.5) is refused with `Error.Unsupported` naming the
    missing piece. Primitives receive the real continuation, not the identity
    one.
  - `Env.lookup_by_name` now returns the identity alongside the cell, and
    `Env.read_by_name_exn` is what `NamedVar` evaluates through; `Core` gained
    `kind_names`, `kind_count`, and `kind_index` for per-form counters.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/evaluator_test.ml` and `test/differential/oracle_cps_test.ml`; the
  differential harness was validated by reversing `eval_list` and confirming it
  reported a readable minimal difference before being restored.
- Acceptance: `fact(20)` gives 2432902008176640000, and the oracle and CPS
  evaluator agree on 46 programs — values, mutation, evaluation order, and
  failures compared by both cause and span. A hundred thousand Ash tail calls run
  in constant host stack, confirming the CPS/TCO assumption from ADR 0003.
- Decisions: ADR 0008 records making the evaluator open-recursive from the first
  line rather than at 2.1. The spec puts direct self-references first on its list
  of traps and AGENTS invariant 3 is unconditional, both of which outrank
  checklist ordering; retrofitting would touch every recursive call site and the
  failure it causes is silent. It also records instrumentation going in with the
  evaluator, refusing unbuilt operations by name, and comparing differential
  failures by location as well as cause.
- Known issues: none. Task 2.1's host side is satisfied and tested; its Ash-level
  half remains, and the checklist entry now says so.
- Next: 0.9 — the classified primitive registry: every primitive in exactly one
  effect class, buffered observable output for deterministic tests, and
  consistent arity and type errors.

### 2026-08-23 — task 0.7

- Completed: added the `ash.runtime` library (`lib/runtime/`) with `Primitives`
  and `Oracle`, plus the supporting core changes they needed.
  - `Oracle` (112 lines): direct-style evaluation of `Lit`, `Var`, `Lam`, `App`,
    `Let`, `LetRec`, `If`, and `Set`. It refuses `NamedVar`, `Quote`, `Reifier`,
    applying a continuation, and any primitive that is not `Pure`, reporting
    `Error.Unsupported` with the location of what it refused.
  - `Primitives`: the pure set — `+ - * / %`, `< <= > >=`, `== !=`, `not`,
    `cons`, `head`, `tail`, `empty?`, `length`, `list` — all `Effect_class.Pure`,
    with `globals ()` allocating fresh identities per call so a materialized
    level can clone them.
  - `Error` gained `Arity_error`, `Unsupported`, and `Division_by_zero`; `Value`
    gained `type_phrase` and `equal`, and `prim_impl` now takes `~call_site` so a
    primitive that rejects an argument can locate the complaint.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/oracle_test.ml`, checked to fail loudly by perturbing an expected
  value before restoring it.
- Acceptance: arithmetic, functions and closures, lexical scope, `If`, `Let`,
  `LetRec` (factorial, 20!, mutual recursion, empty group), and immutable-list
  fixtures including two recursive list functions all pass, alongside the
  refusals that keep the oracle frozen.
- Decisions: ADR 0007 fixes the dynamic semantics every later evaluator must
  match — function position first then arguments left to right, `If` requiring a
  boolean with no truthiness coercion, truncating division with a
  sign-of-dividend remainder and division by zero an error, and `==` structural
  on scalars and lists but identity elsewhere — plus the oracle's frozen
  boundary, central arity checking, and reusing `Error.Unexpected` for runtime
  type errors since `phase` already distinguishes them.
- Known issues: none. The primitive set is deliberately pure-only; 0.9 adds the
  other four classes, buffered output, and the completeness check. `truthy` is
  not implemented yet — the self-interpreter's `my_if` will need it in 2.2.
- Next: 0.8 — the real evaluator in CPS: explicit CPS `eval`, `apply`, and
  `eval-list`, `LetRec` via preallocated cells, evaluator-step and
  constructor-dispatch counters from the start, `fact(20)` working, and agreement
  with the oracle on the initial corpus.

### 2026-08-23 — task 0.6

- Completed: added `Alpha` to `ash.core` and `Core_printer` to `ash.syntax`.
  - `Alpha.equal` decides alpha-equivalence by walking both terms in step under a
    correspondence between their bound identifiers; free identifiers must be
    equal as identities. `Alpha.canonicalize` renumbers bound identifiers by
    first occurrence so that `Core.equal_structure` on canonicalized terms *is*
    alpha-equivalence. `Alpha.free_idents` supports both and the printer.
  - `Core.equal_structure`: structural equality ignoring spans, documented as
    explicitly not alpha-equivalence.
  - `Core_printer`: prints the canonical notation with capture-avoiding renaming.
    A printed binder never shadows a visible name, so within any scope one
    printed name denotes exactly one binder. Terms whose free identifiers print
    alike are refused rather than printed misleadingly.
  - `Sexp.is_readable_atom` keeps the lexical rules in one place.
  - `Ident.Canon` is now erase-only and numbers canonical slots negatively.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/alpha_test.ml` and `test/unit/printer_test.ml`, both checked to fail
  loudly by perturbing an expected value before restoring it.
- Acceptance: `read(print(core))` is alpha-equivalent for all twenty-two printer
  fixtures, covering every Core form plus shadowing binders, same-name
  parameters, same-name recursive binders, same-name reifier parameters,
  quotation of a variable bound outside the quote, a binder adjacent to a free
  name of the same spelling, and an unreadable binder name. Alpha-equivalence is
  additionally checked pairwise against canonical structural equality over a
  ten-term corpus.
- Decisions: ADR 0006 records deciding alpha-equivalence by lockstep walk rather
  than by canonicalizing both terms, the disjoint negative numbering for
  canonical identities, the never-shadow printing discipline, and refusing to
  print terms with indistinguishable free names. It also amends ADR 0002, whose
  `Keep_names` policy was predicted to serve the printer and did not — the
  printer must avoid capture, which renumbering does not do — so the policy was
  removed unused.
- Known issues: none. Note that printed-and-reread terms must never be compared
  with `Core.equal_structure`; reading allocates fresh identities, so the
  relationship is alpha-equivalence.
- Next: 0.7 — the frozen direct-style oracle: pure ordinary Core only, explicitly
  forbidding reflection, staging, and continuation extensions, with arithmetic,
  functions, lexical scope, `If`, `Let`, `LetRec`, and immutable-list fixtures.

### 2026-08-23 — task 0.5

- Completed: added the `ash.syntax` library (`lib/syntax/`) with `Sexp` and
  `Core_reader`, plus supporting changes in `ash.core`.
  - `Sexp`: s-expression data with spans — integers, `#t`/`#f`, strings with the
    same escapes `Constant.escape_string` emits, `'symbols`, bare atoms, and
    lists — with `of_string`, `one_of_string`, and a canonical `to_string` that
    is the round-trip partner of the reader. Comments use `;`, because the
    surface language's `#` collides with `#t`/`#f`.
  - `Core_reader`: one spelling per Core form, validating shape and arity and
    resolving printed names to fresh hygienic identities. Quoted code is read in
    the enclosing scope so a quoted variable keeps its binder ID; a name with no
    binder is an error unless a supplied `scope` provides one; one binder list
    may not bind a name twice.
  - `Error` gained six syntactic causes and the structural comparisons
    `cause_equal` and `equal`; `Core` gained `of_lambda`.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/reader_test.ml`, checked to fail loudly by perturbing an expected
  value before restoring it.
- Acceptance: every Core form's canonical text round-trips through
  `Sexp.of_string`/`to_string` unchanged and reads back as the expected form, and
  eighteen malformed inputs are each checked for both their structured cause and
  their exact rendered location, including across a newline.
- Decisions: ADR 0005 records the one-spelling-per-form notation, the split
  between the datum layer and Core validation, name-to-identity resolution with
  explicit scopes for open terms, quoted code reading in the enclosing scope, and
  rejecting a printed name bound twice in one binder list rather than resolving
  it by entry order.
- Known issues: none. Note that `read` is deliberately not idempotent on
  identities — two reads of the same text are alpha-equivalent, not equal — so
  cross-read comparison must wait for 0.6's alpha-equivalence.
- Next: 0.6 — the Core printer and alpha-equivalence: print deterministic
  readable binders and compare through canonical IDs, with
  `read(print(core))` alpha-equivalent for every form including shadowing,
  `LetRec`, quotation, and reifiers.

### 2026-08-23 — task 0.4

- Completed: added `Env` and `Error` to `lib/core/`.
  - `Env`: `lookup`, `lookup_exn`, `state`, `read_exn`, `lookup_by_name`,
    `lookup_by_name_exn`, `bind`, `bind_cell`, `extend`, `extend_cells`,
    `preallocate`, `assign`, `assign_exn`, `depth`, and `idents`. `state` is a
    three-way `Unbound | Unfilled | Bound` answer so a preallocated `LetRec` cell
    is never confused with an absent binding. Assignment fills an existing cell
    and never creates a binding, which is what makes `Set`, recursive filling,
    and meta-level writes one mechanism.
  - `Error`: phase, span, relative tower level, and a structured cause
    (`Unbound_ident`, `Unbound_name`, `Ambiguous_name`, `Unfilled_binding`),
    raised as `Error.Ash_error` and formatted only at the boundary.
  - `Value.frame_of_list` now rejects a repeated binder identity instead of
    silently dropping a binding.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/env_test.ml` and `test/unit/error_test.ml`; both were checked to
  fail loudly by perturbing an expected value before restoring it.
- Acceptance: tests cover shadowing by identity across frames, closure-visible
  mutation through shared cells (and that rebinding is deliberately *not*
  visible to a captured chain), recursive preallocation including the
  unfilled-read error, name lookup with innermost-frame resolution and the
  ambiguous case, and the failure behaviour of every `_exn` operation with its
  span, phase, level, and rendered message.
- Decisions: ADR 0004 records that a name bound twice in one frame is an error
  rather than a winner chosen by allocation order — deciding it by ID would make
  the gensym counter observable, and D9 excludes that channel — plus the
  three-way binding state, assignment never binding, one frame per extension, and
  errors propagating as an exception rather than through `answer`, with rendering
  that never prints unique IDs so golden diagnostics stay stable.
- Known issues: none. Note for 0.8 and 4.2 that if `meta_error` needs errors as
  ordinary values at level *n+1*, that is a level-crossing mechanism and must not
  quietly widen the ground `answer` type.
- Next: 0.5 — the canonical Core s-expression reader (debug/test format, not the
  surface parser): validate shape and arity, retain source spans, and report
  malformed forms with their location.

### 2026-08-23 — task 0.3

- Completed: added `Core`, `Value`, and `Effect_class` to `lib/core/`.
  - `Core`: all eleven forms with a span on every node, validating constructors
    (a lambda, `letrec`, or reifier that repeats a binder *identity* raises
    `Invalid_argument`, while repeating a printed name is legal), plus
    `kind_name`, `children`, `binders`, `node_count`, `with_span`, and
    `mark_generated`. `LetRec` bindings hold a `lambda` rather than an arbitrary
    expression, and `Reifier` has three named parameters.
  - `Value`: scalars, immutable lists, closures, reifiers, one-shot
    continuations, first-class environments, cells, `Code`, and CPS primitives.
    `answer = value`. `cell` and `continuation` are private records so mutation
    stays centralized in `fill_cell` and `mark_continuation_used`; cell contents
    are `value option` so a preallocated `LetRec` cell reads as unfilled rather
    than as a default. Environments and frames are immutable.
  - `Effect_class`: §D7's five classes with `may_fold_when_static` and
    `always_residualizes`, required on every primitive from the start.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/data_model_test.ml` (93 assertion sites, several iterating over
  every fixture); the harness was checked to fail loudly by perturbing an
  expected value before restoring it.
- Acceptance: there is a fixture for every Core form and every value shape, the
  test asserts both enumerations are complete with distinct names, and no match
  over a Core form or value shape anywhere in the library uses a catch-all —
  including the negative arms of `to_constant` and the printers — so a new
  variant is a compile error rather than a fallthrough.
- Decisions: ADR 0003 records `answer = value` (relying on OCaml's guaranteed
  TCO, since host stack depth is an excluded observation), lambda-only `LetRec`
  bindings, the three-parameter reifier, private cells and continuations with
  option-typed cell contents, immutable frames, CPS primitives carrying an
  effect class, and separate runtime scalars bridged to `Constant.t`.
- Known issues: because frames are immutable, a level's global environment needs
  a per-level reference rather than a mutable frame — that lands with lazy level
  materialization in 4.1. `Core.children` deliberately includes a `Quote` body,
  so evaluator traversals must not use it to mean "evaluated positions".
- Next: 0.4 — explicit environments and cells (`lookup`, `lookup-by-name`,
  `bind`, `extend`, `preallocate`, `assign`, with located unbound-name errors).
  Note that `lookup-by-name` needs a documented rule for two same-name binders in
  one frame, since `Ident.Map` has no insertion order.

### 2026-08-23 — task 0.2

- Completed: added the `ash.core` library (`lib/core/`) with `Span`, `Constant`,
  and `Ident`.
  - `Span`: positions, joining, and a provenance model where a generated node
    inherits its origin's positions and adds a `Generated { by; from }` marker;
    `source_span` recovers the human-written region and `generators` reports the
    nested phase chain.
  - `Constant`: the closed literal domain `Num | Bool | Str | Sym | Unit | Nil`
    with structural equality, a total order, `type_name` for error messages, and
    escaping printers.
  - `Ident`: `private { name; id }` so allocation stays centralized in one
    `Atomic` counter; identity is the ID, the name is for humans;
    `Ident.Set`/`Ident.Map`; and `Ident.Canon` renumbering by first occurrence
    under `Erase_names` (alpha-equivalence) or `Keep_names` (readable printing),
    with `fix` for free identifiers.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`,
  `opam exec -- dune exec ash -- --help`, and
  `opam exec -- dune exec ash -- --version` all passed. New unit tests live in
  `test/unit/core_test.ml` (88 assertions, all passing).
- Acceptance: same-name/different-ID binders stay distinct through `equal`,
  `compare`, `Set`, `Map`, and canonicalization; alpha-renamed identifier
  sequences canonicalize to structurally equal results, independently of
  allocation order.
- Decisions: ADR 0002 records the integer-only numeric domain, the private
  identifier record with a single atomic counter, first-occurrence
  canonicalization with explicit fixing of free identifiers, and the generated
  span provenance model.
- Known issues: canonicalization is currently sequence-level because Core does not
  exist yet; binding-aware alpha-equivalence over terms is task 0.6 and must call
  `Canon.fix` on the free identifiers of the terms it compares.
- Next: 0.3 — implement the complete Core and value data model.

### 2026-08-23 — task 0.1

- Completed: switched the host decision to OCaml, recorded ADR 0001, initialized
  Git, and added the Dune library/CLI/test/documentation skeleton.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`,
  `opam exec -- dune exec ash -- --help`, and
  `opam exec -- dune exec ash -- --version` all passed.
- Known issues: none. The CLI intentionally contains only bootstrap help/version.
- Next: 0.2 — source spans, constants, and hygienic identifiers.

### 2026-08-23 — planning

- Completed: execution plan and repository-wide agent guidance.
- Verified: workspace originally contained only `Ash Reflective Tower.md` and was
  not a Git repository.
- Next: superseded by the completed task 0.1 entry above.
- Decisions: initially selected Racket; superseded by ADR 0001 selecting OCaml.
