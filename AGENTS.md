# AGENTS.md

These instructions apply to the entire Ash repository.

## Mission and sources of truth

Build Ash: a hygienic language with a CPS self-interpreter, lazily materialized
reflective tower, and staged collapser that explains where interpretation can and
cannot be erased. The measured four-way classification is the primary deliverable;
a native backend is optional.

At the start of every coding session, read:

1. `AGENTS.md` for workflow and constraints.
2. `to-do.md` for task order, current state, and handoff.
3. Relevant sections of `Ash Reflective Tower.md`.
4. Decision records and tests for the component being changed.

Explicit decisions in `docs/decisions/` take precedence, followed by the design
spec, then the checklist. If they conflict, update all affected documents in the
same change. Never silently diverge from the spec.

When the user says **`continue`**, do not ask what to do. Inspect current state,
then complete the first unchecked item in `to-do.md`. If it is partially done,
finish it before moving on.

## Stack

- Host: **OCaml 5.2+**, built with **Dune 3.16+**.
- Tests: Dune test executables with focused assertions initially; add Alcotest or
  QCheck only when their benefit justifies a dependency decision.
- Representation: immutable algebraic data types and records except for explicit
  Ash cells, continuation flags, counters, and scoped emission buffers.
- Parser: handwritten, source-located; host `read` is not the Ash surface parser.
- Backend: emit hygienic Core and run it with the ground evaluator first.
- Dependencies: use OCaml's standard library by default. Justify external packages
  in a decision record.

Use the active opam switch. These are the canonical verification commands:

```sh
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune exec ash -- --help
```

Keep one compile, full-test, and CLI-smoke command current here and in
`README.md`. The packaged milestone demos are `dune exec ash -- --demo NAME`;
`test/golden/demos.expected` stores what each prints.

## Semantic invariants

1. **Intrinsic hygiene:** lexical identity is printed name plus unique ID, never
   a string alone. `NamedVar` remains a distinct reflective Core node.
2. **CPS production evaluator:** direct style is a frozen pure-Core oracle only.
3. **Open recursion:** every recursive call among `eval`, `apply`, `eval-list`,
   and future evaluator-group members dynamically dereferences the current
   level's cell. No closure may retain a direct group-member reference.
4. **One-shot first-class continuations:** mark used before transfer; fail clearly
   on a second invocation.
5. **Closed `run`:** never inherit an implicit caller environment.
6. **Small lifting domain:** do not serialize closures, continuations,
   environments, or cells.
7. **Effect-aware staging:** fully static pure operations may fold; IO always
   residualizes; mutation needs explicit store reasoning; control/reflection use
   bespoke rules.
8. **Persistent meta overlays:** never implement `meta_with` with
   save/mutate/restore.
9. **Per-level state:** lazily materialized levels get cloned globals and fresh
   open-recursion cells.
10. **Scoped claims:** timing, host stack depth, resource exhaustion, and gensym
    counters are excluded observations. Depth-sensitive code gets per-depth
    semantic comparison, not cross-depth alpha-equivalence.

Add a regression test before repairing a violation of these rules whenever
practical. Never weaken one merely to make a test pass.

## Intended layout

```text
bin/                     CLI entry point
lib/
  core/                  identifiers, AST, values, env, alpha-equivalence
  syntax/                lexer, parser, desugaring, printers
  runtime/               CPS evaluator, primitives, continuations, errors
  self/                  the Ash self-interpreter and its encoding
  tower/                 levels, open-recursive cells, reifiers, overlays
  stage/                 static/dynamic values, emission, specialization
  collapse/              normalization, classification, reports, metrics
test/
  unit/                  module-level behavior
  differential/          oracle/CPS/tower/residual comparisons
  laws/                  semantic invariants across depths
  golden/                parser, printer, diagnostics, CLI/report snapshots
examples/                executable milestones and classification samples
docs/decisions/          numbered architecture decision records
docs/progress/           experiment and reproducibility notes
```

Lower layers cannot import higher layers. Core knows nothing about tower or
staging; ground runtime knows nothing about classification. Break cycles by
extracting neutral protocol/data modules, not dynamic loading.

## Per-task workflow

1. Inspect files and working-tree changes. Preserve unrelated user work.
2. Use the first unchecked task and its acceptance criterion as the scope.
3. Implement the smallest end-to-end slice that proves that criterion.
4. Add focused tests; bugs get a failing regression first when practical.
5. Run focused tests, then the full suite appropriate to the current phase.
6. Update behavior/command documentation.
7. Mark the checkbox only after acceptance genuinely passes.
8. Update `to-do.md` **Current state** and prepend a **Handoff log** entry with:
   completed work, exact commands/results, decisions, known issues, and next task.

Leave partial tasks unchecked. If blocked, record the exact blocker and completed
partial work. A future `continue` session must never need to guess task status.

Commit only when asked or when an active workflow explicitly requires it. Never
discard or overwrite unrelated working-tree changes.

## Coding conventions

- Prefer explicit variants/records and exhaustive `match` in semantic code. Keep
  compiler warnings enabled and treat non-exhaustive matches as errors.
- Follow OCaml naming conventions: `snake_case` values/modules files,
  `UpperCamelCase` modules and constructors, `_exn` for deliberately raising
  lookup variants, and descriptive `x_to_y` conversion names.
- Carry source spans through surface AST, Core, residual provenance, and errors.
  Generated nodes retain their origin plus a generated marker.
- Centralize fresh IDs. Syntax comparisons alpha-normalize and never depend on
  global allocation order.
- Keep observable effects injectable/buffered for exact trace comparison.
- Instrumentation is observationally inert: it cannot affect Ash values, output,
  IDs, specialization decisions, or errors.
- Use structured errors carrying phase, span, tower level, and cause. Format only
  at the CLI boundary.
- Prefer named policy predicates (`static-value?`, `observable-effect?`) over
  scattered representation tricks.
- Comment semantic reasons and invariants, not obvious mechanics.
- Add contracts or clear checks at module boundaries; keep proven hot internals
  straightforward.

## Test expectations

- Unit tests cover constructors, environments, parser behavior, and primitives.
- Differential tests compare oracle, CPS evaluator, self-interpreter, tower, and
  residual execution wherever each exists.
- Law tests cover hygiene, open recursion, reifier identity, level independence,
  overlays, one-shot use, and effect preservation.
- Golden tests cover printed Core, diagnostics, CLI reports, and demo traces.
- Generated tests exercise alpha-renaming, parse/print round trips, and small
  terminating pure programs.

Nontermination tests use deterministic Ash-level step budgets, never wall time.
Depth tests normally cover 0–5. Capture output; specialization and tests must not
leak unexpected output.

Before checking off a phase, run its full suite from a clean process and record
the command/result in the handoff log. Stubs, skipped tests, and mocked semantics
do not satisfy milestones.

## Decision records

Create `docs/decisions/NNNN-title.md` when a choice:

- changes a locked decision or Core semantics;
- adds a dependency or host escape hatch;
- changes staging/effect behavior;
- weakens an acceptance criterion or equivalence claim; or
- makes report metrics incomparable with prior results.

Record context, decision, alternatives, semantic consequences, test impact, and
required spec/measurement changes. Keep established results, implementation
choices, and Ash's measured contribution distinct; do not casually claim novelty.

## Scope control

- Build a boring correct tower before broad reflective features.
- Complete the pure collapser before store splitting and dynamic reflection.
- Multi-shot continuations, native code, and later Futamura projections wait
  until the required release is complete.
- Do not expand Core or `lift` merely for convenience.
- Preserve instrumentation required by the collapse report.
- If the self-interpreter exposes missing expressiveness, decide whether it is a
  genuine Core form or surface desugaring. Never hide it in host special cases.
