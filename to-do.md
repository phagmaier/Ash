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

- **Phase:** 0 — Core
- **Next:** 0.8 — implement the real evaluator in CPS
- **Last verified:** 2026-08-23 — clean-tree `dune build @all`, `dune runtest`,
  and `dune exec ash -- --help` pass with `ash.core` (identifiers, Core, values,
  environments, errors, alpha-equivalence), `ash.syntax` (s-expressions, reader,
  printer), and `ash.runtime` (pure primitives, direct-style oracle)
- **Blocker:** none

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

- [ ] **0.8 Implement the real evaluator in CPS.**
  - Make `eval`, `apply`, and `eval-list` explicitly CPS.
  - Implement `LetRec` with preallocated cells and closures in the extended env.
  - Count evaluator steps and constructor dispatches from the start.
  - Accept: `fact(20)` works and agrees with the oracle on the initial corpus.

- [ ] **0.9 Implement the classified primitive registry.**
  - Classify every primitive as pure, allocation/mutation, observable effect,
    control, or reflection. Buffer observable output for deterministic tests.
  - Accept: every primitive has exactly one class and consistent arity/type errors.

## Phase 1 — surface language and continuations

- [ ] **1.1 Implement the lexer with source spans.**
  - Cover comments, literals, symbols, names, keywords, operators,
    quotation/splice tokens, and punctuation.
  - Accept: golden tests cover ambiguous operators and malformed literals.

- [ ] **1.2 Implement the precedence parser.**
  - Cover bindings, mutation, functions, calls, blocks, conditionals, lists,
    pipelines, and the exact precedence/associativity table from the spec.
  - Accept: parser golden tests include every precedence boundary.

- [ ] **1.3 Implement patterns and pattern parsing.**
  - Cover wildcard, literals, variables, list patterns, alternatives, Core
    constructors, and quasiquote patterns; reject inconsistent binders.
  - Accept: the documented `length` and `simplify` examples parse.

- [ ] **1.4 Hygienically desugar surface syntax to Core.**
  - Lower sequencing, `var`, named functions, match, Boolean sugar, lists, and
    pipelines; preserve spans and generated-node provenance.
  - Accept: end-to-end tests cover `fact`, `length`, pipelines, shadowing, and set.

- [ ] **1.5 Implement first-class one-shot continuations.**
  - Retain continuation procedure, used flag, capture site, and meta-context.
  - Mark used before transfer; report capture and first-use sites on reuse.
  - Accept: storage, delayed/cross-function invocation, and second-use error pass.

- [ ] **1.6 Build the oracle/CPS differential corpus.**
  - Compare values, errors, mutations, and buffered output across recursion,
    closures, shadowing, lists, and failures.
  - Accept: all pure cases agree with readable minimal differences on failure.

## Phase 2 — self-interpreter and open recursion

- [ ] **2.1 Define and enforce open-recursive evaluator groups.**
  - Store `eval`, `apply`, and `eval-list` in mutable per-level cells.
  - Every intra-group call must dynamically dereference its cell; instrument each
    dereference. Never capture direct group references in closures.
  - Accept: wrapping `eval` observes every nested AST node, not just entry.

- [ ] **2.2 Write the CPS Core evaluator in Ash.**
  - Keep it parallel to the host evaluator. Resolve missing language support as a
    Core form or desugaring, never a host escape hatch.
  - Accept: it matches the host evaluator on the ordinary corpus.

- [ ] **2.3 Test iteration and invariant OR.**
  - Test self-interpreter layers 1 and 2 plus the spec's patch-depth fixture.
  - Accept: all layers agree and recursive evaluation remains patchable.

## Phase 3 — code and staging foundations

- [ ] **3.1 Implement hygienic quotation, splicing, and code patterns.**
  - Quoted lexical variables retain binder IDs; runtime string construction uses
    explicit `NamedVar`.
  - Accept: adversarial same-name splices cannot capture or be captured.

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
