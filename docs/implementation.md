# Ash implementation guide

How the codebase is organized and how to work in it. Read
`docs/semantics.md` for what the code means; read this for where it lives
and how to verify a change. Session rules and the task plan live in
`AGENTS.md` and `to-do.md`.

## 1. Repository layout

| Path | Contents |
|------|----------|
| `lib/core/` | Core AST, values, identifiers, spans, errors, effects, Code ops |
| `lib/syntax/` | Lexer, parser, surface AST, desugarer, Core reader/printer |
| `lib/runtime/` | CPS evaluator, oracle, machine, primitive registry, IO |
| `lib/self/` | `eval.ash` (self-interpreter in Ash) plus its loader |
| `lib/tower/` | Levels, lazy materialization, depth interposition |
| `lib/stage/` | Staged evaluator, store, emitter, specialization points |
| `lib/collapse/` | Metrics, residue survey, classification, human/JSON reports |
| `bin/main.ml` | `ash` CLI: demos, collapse reports |
| `examples/` | Runnable programs; demos embedded into `ash.examples` by a dune rule |
| `test/unit/` | Focused module tests |
| `test/differential/` | Shared-corpus agreement suites |
| `test/laws/` | Executable specification laws |
| `test/golden/` | Pinned CLI outputs (`demos`, `collapse`, `traced_fibonacci`, lexer/parser/desugar) |
| `docs/decisions/` | ADRs 0001–0042, the per-decision rationale |
| `docs/progress/` | Depth cost, traced-Fibonacci index, Phase 10 measurements + raw JSON |
| `scripts/` | `measure_phase10.py`, the one-command measurement reproduction |

## 2. Layering rule

Lower layers never import higher ones. `core` knows nothing of the tower or
staging; the runtime cannot see the tower (the tower installs each machine's
level neighbourhood from above); staging and collapse build on the machine
without changing its protocol. Concretely: `lib/core/dune` depends on
nothing above it, `lib/runtime` depends on `core` and `syntax` values only,
`lib/tower` depends on `runtime`, `lib/stage` on `runtime`+`tower` types, and
`lib/collapse` on all of them. A change that makes `core` import `tower` is
wrong no matter what test it fixes.

Instrumentation follows the same direction: counters live in the machine,
are incremented by the evaluator, and are read by the report. Nothing in the
evaluator reads them, which is what makes measurement observationally inert.

## 3. Module guide

- `lib/core/ident.ml` — fresh-ID allocation, `Canon` renumbering.
  `alpha.ml` is the binding-aware traversal over it.
- `lib/core/core.ml` — the eleven Core constructors, spans, provenance,
  `assigned_idents` (shared by the store and the normalizer).
- `lib/core/value.ml` — value domain, environments, cells, one-shot
  continuation flags.
- `lib/core/effect_class.ml`, `observation.ml` — the staging policy inputs:
  whether a primitive may fold, and how much of each argument it inspects.
- `lib/syntax/` — `lexer`, `parser` (handwritten, source-located),
  `desugar` (surface to Core; quotation/splicing lower here),
  `core_reader`/`core_printer` (canonical notation round-trip).
- `lib/runtime/machine.ml` — open-recursion cells, overlay pointer,
  level neighbourhood, global env, counters.
- `lib/runtime/evaluator.ml` — the CPS production evaluator; `oracle.ml` is
  the frozen direct-style counterpart.
- `lib/runtime/primitives.ml` — the registry; every primitive carries exactly
  one effect class.
- `lib/self/eval.ash` — the CPS Core evaluator written in Ash, dispatching
  on Core constructor patterns over real Code (`Self` loads and lowers it).
- `lib/tower/level.ml`, `tower.ml` — per-level state and lazy
  materialization; `depth.ml` interposes the identity interpreter that gives
  "depth k" its testable meaning.
- `lib/stage/staged_eval.ml` — identity/lift evaluator modes;
  `stage_value.ml` (static/dynamic predicates, `may_fold`),
  `store.ml` (held/residual bindings, fork/join), `emit.ml` (scoped
  let-insertion buffers), `specialize.ml` (keys, memo table, budgets).
- `lib/collapse/metrics.ml` — source/tower/specialization/residual
  measurement; `residue.ml` — the residual AST walk;
  `classification.ml` — the conservative four-way label;
  `normalize.ml` — the residual normalizer; `report.ml` — the one renderer
  shared by the CLI and the golden tests.

## 4. CLI

```
opam exec -- dune exec ash -- --help
opam exec -- dune exec ash -- --demo tracing
opam exec -- dune exec ash -- --demo level-2-counting
opam exec -- dune exec ash -- --demo traced-fibonacci
opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1
opam exec -- dune exec ash -- --collapse examples/traced_fibonacci.ash --depth 1 --show-residual
opam exec -- dune exec ash -- --collapse <file> --depth N --json
```

Demos print trace, value, and levels through one renderer pinned in
`test/golden/demos.expected`. The collapse report prints what the tower did
beside what the residual contains; `--show-residual` adds canonical residual
Core and exact output bytes; `--json` emits the same measurement as
structured data for `scripts/measure_phase10.py`.

## 5. Tests

| Class | Where | What it proves |
|-------|-------|----------------|
| Unit | `test/unit/` (~30 files) | one module's contract: hygiene, env/cells, reader/printer, continuations, reifiers, `meta_with`, lift/run, staging fragments, store, budgets, normalization, effect policy |
| Differential | `test/differential/` | shared-corpus agreement: oracle↔CPS, host↔self-interpreter, layer iteration, source↔raw-residual |
| Laws | `test/laws/` (8 files) | specification claims at depth: open recursion, tower transparency, pure criterion, depth invariance, effect order, static and dynamic reflection |
| Golden | `test/golden/` | byte-pinned CLI outputs; regenerate with `dune runtest --auto-promote` |
| Corpus | `test/differential/corpus.ml` | the one program list every evaluator comparison reads |

Run `opam exec -- dune build @all` then `opam exec -- dune runtest`. Add a
regression test before repairing any invariant violation; never weaken an
invariant to make a test pass.

## 6. Decisions and progress notes

ADRs are numbered by task order: 0001–0009 bootstrap and primitives,
0010–0017 surface language and self-interpreter, 0018–0021 code and staging
foundations, 0022–0025 lazy tower and depth, 0026–0034 pure collapser and
depth results, 0035–0037 effects, 0038 overlays, 0039–0040 static and dynamic
reflection, 0041 release formatting, 0042 primitive error levels. Start from 0008 (CPS/open recursion), 0025 (depth), 0030 (what
the pure criterion claims), 0034 (depth readings), 0037 (failure agreement),
and 0040 (dynamic reflection and classification).

`docs/progress/0001-depth-cost.md` is the per-level cost baseline (~5x flat),
`0002-traced-fibonacci.md` indexes the static-reflection demo artifact, and
`0003-phase10-measurements.md` with `phase10-measurements.json` pins every
published classification number with its host versions.

## 7. Common tasks

- New Core form: extend `core.ml`, then every exhaustive match (oracle, CPS
  evaluator, self-interpreter, staged evaluator, printer, alpha) — the
  compiler lists them. Cite the new spec section and add an ADR.
- New primitive: assign exactly one effect class in `primitives.ml` and its
  observation signature; control/reflection members need bespoke staging
  rules, not a class change.
- New collapse behavior: update `staged_eval`/`store`/`specialize`, then
  `residue.ml` if new syntax can survive, then the report and goldens.
- New measurement: extend `metrics.ml` and `report.ml` together (human and
  JSON in the same change) and pin raw data under `docs/progress/`.
