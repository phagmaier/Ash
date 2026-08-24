# 0019 — Closed Code execution uses the explicit level-global environment

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 3.2
- **Amends:** 0009 (Reflection now contains `run`) and 0014 (primitive callbacks)

Task 3.3's [ADR 0020](0020-fixed-lift-domain.md) subsequently adds the evaluator's
`~lift` callback and the `lift` member of Reflection without changing `run`.

## Context

Task 3.2 requires `run` to execute closed Code, report every unresolved
dependency with useful locations, and never inherit the caller's lexical state.
Quotation from task 3.1 preserves the hygienic identities of both lexical and
global references, so a useful definition of closedness must distinguish a
quoted local variable from the primitive identities deliberately supplied to a
level. It must also say what nested `Quote` and explicit `NamedVar` nodes mean.

The primitive protocol had only an `apply` callback. That is sufficient for
`callcc` and `invoke`, but a `run` implementation inside the registry would
otherwise have to capture one particular evaluator or environment when the
registry was constructed. Either would be wrong once tower levels own separate
machines and cloned globals.

## Decision

**Code is closed relative to the current level's explicit global environment.**
`Code.unresolved_dependencies ~available` walks binding structure by hygienic
identity. A free `Var` is resolved only when its exact identity is in
`available`; printed-name equality is irrelevant. The ground evaluator installs
the environment passed to its top-level `Evaluator.run` as the machine's global
environment. The surface harness passes only the registry globals there. A
`Let`, lambda, or closure frame introduced during that evaluation is never
added, so ``let x = 1; run(`{ x })`` is rejected even though `x` is live at the
call site.

**Analysis reports all dependencies and all occurrence locations.** One result
entry represents one free identity and carries every source span where it is
referenced. Entries and spans follow first source occurrence, not identifier-map
order, because allocation order is an excluded observation. `Error.Open_code`
carries this full structure; the runtime check is an Evaluate-phase error whose
primary span is the `run` call and whose message lists the quoted locations.

**The whole Code tree is checked.** A `Set` target is a reference, and a nested
`Quote` retains the surrounding lexical scope and is traversed. This matches
`Alpha.free_idents`: open Code may be assembled, but Code handed to `run` is
closed as a whole. `NamedVar` is not an unresolved lexical dependency. It is an
explicit request for printed-name lookup when execution occurs, and that lookup
still sees only the global environment chosen above.

**Reflection primitives receive a `run` callback from their applying evaluator.**
`Value.primitive.prim_impl` now receives `~run` alongside `~apply`. The ground
callback performs analysis, then enters the same open-recursive machine with the
machine's global environment and the primitive call's continuation. Thus
recursive evaluation remains interceptable, effects use the same registry, and
control transfers compose normally. The direct-style oracle supplies only a
refusing callback and continues to reject the non-Pure `run` primitive before
its implementation can execute.

`run` is the first member of `Effect_class.Reflection`. Immutable Code
construction remains Pure; `lift`, `reflect`, and `up` arrive in later tasks.

## Alternatives

**Require literally no free `Var` nodes.** Rejected: ordinary quoted arithmetic
contains hygienic references to global primitives such as `+`. Rewriting those
as `NamedVar` would turn ordinary staging into name-resolved reflection and make
the collapse report misleading.

**Analyze against the caller environment.** Rejected by spec D5. It silently
introduces cross-stage persistence and makes a local binding available merely
because `run` was called beneath it.

**Use the outermost frame of the caller environment at each call.** Rejected:
that guesses which frame is global from representation. The evaluator entry
already knows the explicit level environment and records it once on the machine;
Phase 4 can supply each materialized level's own global directly.

**Stop at the first free variable.** Rejected by the task requirement and by
diagnostic usefulness. A code generator should not require one run/fix cycle per
missing dependency.

**Special-case a primitive named `run` in the evaluator.** Rejected: a registry
member should retain the same arity/type behavior as every primitive, and
matching a user-constructed primitive by printed name would make behavior depend
on a string rather than its registered operation. The evaluator callback keeps
the dependency in the correct direction without an identity special case.

## Consequences

- `Ash_core.Code` exposes deterministic, location-preserving closedness analysis.
- `Ash_core.Error` gains `Open_code`; exhaustive cause matches must handle it.
- A machine records the explicit environment of its current top-level run.
- Primitive implementations receive both evaluator callbacks, `~apply` and
  `~run`; ordinary primitives ignore the latter.
- The registry grows from 36 to 37 primitives and Reflection is exactly `run`.
- Running Code uses the active machine and observable stream but no caller
  lexical frame.

## Test impact

`test/unit/run_test.ml` covers closed arithmetic, closures, recursive code,
observable effects, all unresolved identities and repeated occurrence spans,
caller lexical isolation, nested quotations, global availability, explicit
`NamedVar`, and type errors. `code_test`'s existing hygiene checks remain the
construction half of the boundary. `primitives_test.ml` independently pins
`run`'s class, arity, and type behavior, while the full differential and layer
suites exercise the widened primitive protocol.

## Required spec or measurement changes

Spec D5 now states the level-global basis, complete location reporting, nested
quotation rule, and `NamedVar` boundary. Spec D7's Reflection row now includes
`run`. No measurement definition changes; later reports already count reflection
boundaries by class.
