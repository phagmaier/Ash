# AGENTS.md — AI session GPS

## 1. Mission

Build Ash: a hygienic language with a CPS self-interpreter, a lazily materialized
reflective tower, and a staged collapser that explains where interpretation can
and cannot be erased. The measured four-way classification is the primary
deliverable; a native backend is optional.

## 2. File map

Read files only when this table says so. Do not bulk-load the spec or README.

| File | Purpose | When to load |
|------|---------|--------------|
| `AGENTS.md` | This file — rules and map | **Always**, at session start. |
| `to-do.md` | Active checklist, Current state, locked decisions | **Every session**, before coding: first unchecked item is the next task. |
| `Ash Reflective Tower.md` | Design spec and semantics (immutable source of truth) | **Only** when implementing new Core forms, reflection, staging, or when a task cites a spec section (§). |
| `docs/decisions/*.md` | Numbered architecture decisions (ADRs) | **Only** when a task touches a locked decision (D1–D9) or you must record a new one. |
| `docs/progress/handoff-log.md` | Archived per-task history | Only to recover context from a past session; append a new entry after each completed task. |
| `README.md` | Human-facing intro | **Never.** It is for humans; contains nothing an AI needs. |

Session protocol:

- The first unchecked item in `to-do.md` is the default next task. When the user
  says `continue`, do not ask — start it.
- Mark `[x]` only after implementation, tests, and docs satisfy its acceptance
  criterion. Leave partial work unchecked and record the blocker in Current state.
- After each completed task: update **Current state** in `to-do.md`, prepend a
  handoff entry to `docs/progress/handoff-log.md`, then stop.
- If evidence requires a spec change, write an ADR, update the spec, and update
  the plan in the same change. Never silently diverge.
- Commit only when explicitly asked.

## 3. Core invariants (non-negotiable)

1. **Hygiene:** identity = printed name + unique ID, never a string alone;
   `NamedVar` stays a distinct reflective Core node.
2. **CPS production evaluator:** direct style exists only as the frozen pure-Core
   oracle; never extend it.
3. **Open recursion:** every call among `eval` / `apply` / `eval_list`
   dynamically dereferences the current level's cell — no closure may capture a
   direct group-member reference.
4. **One-shot continuations:** mark used before transfer; fail clearly on second
   invocation.
5. **Closed `run`:** never inherits the caller's environment.
6. **Small lifting domain:** never serialize closures, continuations,
   environments, or cells.
7. **Effect-aware staging:** static pure ops may fold; IO always residualizes;
   mutation needs store reasoning; control/reflection get bespoke rules.
8. **Persistent meta overlays:** never implement `meta_with` via
   save/mutate/restore.
9. **Per-level state:** materialized levels get cloned globals and fresh
   open-recursion cells.
10. **Scoped claims:** timing, host stack depth, resource exhaustion, and gensym
    counters are excluded observations; depth-sensitive code gets per-depth
    semantic comparison, never cross-depth alpha-equivalence.

Add a regression test before repairing any violation. Never weaken an invariant
to make a test pass.

## 4. Golden commands

```sh
opam exec -- dune build @all                                # compile
opam exec -- dune runtest                                   # full suite
opam exec -- dune exec ash -- --help                        # CLI smoke
opam exec -- dune exec ash -- --demo tracing                # milestone demo 1
opam exec -- dune exec ash -- --demo level-2-counting       # milestone demo 2
opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1   # report
```

Host: OCaml 5.2+, Dune 3.16+, active opam switch, standard library by default.
Golden outputs live in `test/golden/demos.expected` and
`test/golden/collapse.expected`; regenerate with `dune runtest --auto-promote`.

## 5. Critical warnings (the top traps)

1. **Hygiene:** identifiers are `(name, id)` pairs. Comparing or resolving by
   printed string alone causes capture bugs no free-variable checker can see
   (spec D1). Alpha-canonicalize before comparing terms.
2. **Open recursion:** a direct self-reference inside the evaluator makes
   meta-patches intercept exactly one step instead of every nested step — the
   most expensive mistake on the spec's trap list (D3). Every recursive call
   reads its cell.
3. **`print` folding:** folding `print("hi")` on a static argument compiles the
   print and runs nothing — the compiled program is silently wrong (D7).
   Observable effects always residualize; check the effect class before any fold
   rule.

Other standing constraints: handwritten source-located parser; lower library
layers never import higher ones (`core` knows nothing of tower/staging);
instrumentation must be observationally inert; structured errors formatted only
at the CLI boundary; nontermination tests use counted Ash step budgets, never
wall time.
