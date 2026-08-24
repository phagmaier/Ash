# 0026 — Static/dynamic values, stage polymorphism, and the maybe-lift evaluator mode

- **Status:** accepted
- **Date:** 2026-08-24
- **Task:** 5.1
- **Amends:** 0009 (primitive classification during specialization) and 0020 (the lift domain at stage boundaries)

## Context

Phase 5 begins Milestone 2: the pure staged collapser that eliminates interpretation overhead in pure Ash programs.

Online partial evaluation (spec §7) requires that static values and dynamic code coexist in a single domain: static data are real runtime values (`Value.value`), while dynamic data are residual syntax wrapped as `Value.Code(Core.t)`. Furthermore, Amin & Rompf's collapsing result hinges on one shared evaluator parameterized by `maybe_lift`:
- In `Identity` mode (`maybe_lift = id`), the evaluator performs standard evaluation.
- In `Lift` mode (`maybe_lift = lift`), static computations fold and static results are lifted to `Code` at stage boundaries.

Pure primitives must be stage-polymorphic (spec §D7): when all arguments are static, they compute their value at specialization time; when any argument is dynamic, they lift all arguments to `Code` and emit a residual application. Non-pure primitives (effects, mutation, control, reflection) must not fold blindly.

## Decision

**Static data are real values; dynamic data are `Code(Core.t)`.**
The value domain (`Value.value`) already contains `Code of Core.t`. `Ash_stage.Stage_value` provides named policy predicates (`is_static`, `is_dynamic`, `is_purely_static`, `static_value`, `dynamic_code`) rather than ad-hoc representation checks.

**`Mode.t` is `Identity | Lift`.**
`Ash_stage.Mode` defines the evaluation modes. In `Identity` mode, `maybe_lift` is the identity. In `Lift` mode, `maybe_lift` converts static values to `Value.Code` using `Evaluator.lift_value`.
Each `Machine.t` records whether its evaluator group is ground, staged-Identity,
or staged-Lift wiring. `Staged_eval.run` derives its default mode from that tag
and rejects an explicit mismatch before setting the environment or evaluating
the term. This makes the public API unable to execute Identity callbacks while
claiming Lift semantics.

**One evaluator source supports both modes.**
`Ash_stage.Staged_eval` provides `eval_default`, `apply_default`, and `eval_list_default` parameterized by `Mode.t`.
- In `Identity` mode, it behaves identically to the production CPS ground evaluator.
- In `Lift` mode, pure primitives fold only when arguments are recursively static, `If` with a static condition evaluates only the taken branch, `Let` with static values propagates bindings without emitting administrative lets, and dynamic expressions residualize `Code`.
- Lift-only handling of `Code` in conditions, bindings, and applications is
  explicitly mode-gated. Identity mode therefore preserves the ground
  evaluator's values and type errors.
- A residual primitive application finds the outermost environment binding that
  contains the exact primitive record by physical identity. It never
  reconstructs lexical identity from the primitive's printed name.
- `Quote` produces residual `Core.Quote` in Lift mode, so executing the residual
  still returns Code. Core `Set` is rejected in Lift mode until Phase 7 provides
  explicit store splitting; specialization never mutates the source store.
- Errors on pure static expressions (such as division by zero or type errors) are caught at stage time (spec §D7).

**Open recursion is maintained.**
All recursive evaluator steps go through `Machine.eval`, `Machine.apply`, and `Machine.eval_list`, ensuring that meta replacements and instrumentation intercept every step across both modes.

## Alternatives

**Build a separate offline abstract interpreter.** Rejected: online staging unifies evaluation and specialization, which is essential for collapsing reflective towers without duplicate language semantics.

**Treat all primitives as stage-polymorphic.** Rejected (spec §D7): folding non-pure primitives like `print` at specialization time produces compilers that perform runtime effects at compile time.

## Consequences

- New library `ash.stage` (`Ash_stage`) with `Mode`, `Stage_value`, `Staged_eval`, and `Stage`.
- `Evaluator.lift_value` is exported from `Ash_runtime.Evaluator`.
- `Machine.create` accepts an explicit semantic wiring tag, defaulting to ground.
- `test/unit/stage_test.ml` covers predicates, mode consistency, Identity
  equivalence for Code, constant folding, recursive dynamic detection,
  hygienic primitive identity, effect and mutation exclusion, error
  preservation, open recursion, and static recursion.

## Test impact

- `test/unit/stage_test.ml` tests:
  1. Policy predicates and `maybe_lift` behavior.
  2. Mode operations (`equal`, `compare`, `to_string`).
  3. `Identity` mode evaluation agreement with ground runtime.
  4. Constant folding of arithmetic, comparisons, logic, and list operations in `Lift` mode.
  5. Constant propagation through static `Let` bindings.
  6. Stage-polymorphic residualization when dynamic arguments (`Code`) are encountered.
  7. Stage-time error detection for division by zero and type errors.
  8. Open recursion interception and static recursion folding.
  9. Mode mismatch rejection before IO, Quote preservation, Identity-mode Code
     behavior, nested dynamic data, exact primitive hygiene, and Set rejection
     without specialization-state mutation.
- Full regression suite (`dune runtest`) passes cleanly across all test classes.
