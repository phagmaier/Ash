# 0039 — Static reflection as a closed staged meta protocol

- **Status:** accepted
- **Date:** 2026-09-18
- **Task:** 9.1
- **Builds on:** 0024 (`up` and evaluator cells), 0026 (the staged evaluator),
  0035 (effect policy), 0038 (persistent overlay frames)

## Context

The runtime already represents a persistent evaluator replacement and a scoped
overlay as callable Ash values. That is enough to run reflection, but not to
specialize it. A known `up` body was sent to a ground tower level, where a
wrapper's `print` would happen while compiling; reflection, control, and open
cell primitives otherwise residualized wholesale. `meta_with` likewise left its
readers and runner behind. Neither route could satisfy task 9.1: inline a known
wrapper at each dispatch site, preserve its effects there, and leave zero
interpreter residue.

One representation issue is load-bearing. `Value.Code node` historically meant
"the residual program will compute this expression." An evaluator wrapper's
`e` argument is also `Code`, but its syntax is already known. Treating the two
as one makes `println(e)` print the value of `node` in the residual rather than
the code value the tower printed.

## Decision

**A specialization attached to a configuration gets a lazy parallel chain of
Lift-wired machines.** Reifier application materializes the next staged machine,
not a ground evaluator. Each level has fresh cloned global cells, a link to the
level below, and the same relative level and materialized-depth observations.
Meta bodies and evaluator wrappers therefore obey the ordinary staging rules:
observable effects residualize and static computation folds.

**Only the closed meta protocol executes during specialization.** The bespoke
allowlist consists of the meta readers, `tower_level`, `meta_with_run`, `resume`,
known default `eval`/`apply` values, and `open_deref`/`open_set` on evaluator
cells returned by `meta_eval` or `meta_apply`. Those cells are registered by
identity for the run. The same operations on ordinary program cells keep the
Phase 7 store policy, and an unknown override remains residual rather than being
guessed static. Primitive effect classes do not change.

**Known code is run-scoped staging knowledge.** A staged machine packages the
syntax passed to an evaluator wrapper through a configurable meta-code
constructor. `Stage_value` records those Core nodes by physical identity for
the current run. They count as static and reify to `Quote(node)`; an unrecorded
`Value.Code node` remains dynamic residual syntax. Static Code returned inside
the result of `code_view`, `code_splice`, `code_match`, and `NamedVar` is
recorded recursively as well, so a wrapper may inspect and print constructor
fields without turning them into computations. Core and the runtime value
variants stay unchanged.

**Known wrappers use the runtime's existing open recursion and overlay
discipline.** A persistent write still fills the real evaluator-group cell and
an overlay still pushes an immutable frame. Their dispatch calls now target the
next Lift-wired machine, so the wrapper is specialized in place and its call to
the captured base evaluator continues on the lower machine. No second
evaluator-change mechanism is introduced.

## Alternatives

**Run the meta body on the ground tower and only stage later wrapper calls.**
Rejected: effects performed while installing a change would escape to the
compiler's program stream, and the evaluator executing a closure would depend
on which half of the protocol happened to call it.

**Make all Reflection or Control primitives fold when their arguments look
static.** Rejected: `callcc`, `run`, arbitrary cells, and dynamic evaluator
identity retain exactly the hazards their effect classes record. Task 9.1 needs
a protocol allowlist, not a weaker D7.

**Add `StaticCode` to the runtime value type.** Rejected: the distinction belongs
to one specialization run, not to Ash's runtime data model. A run-scoped table
keeps the fixed value domain and makes reset explicit.

## Consequences

- Persistent and scoped `eval` and `apply` wrappers inline at every dispatch
  site they affect. `print` and `println` calls survive in source order.
- The staged meta chain clones globals per level, preserving invariant 9 while
  sharing immutable values and hygienic identifiers.
- Dynamic reflection is unchanged and remains task 10.1.
- The no-tower runtime overlay behavior from ADR 0038 is unchanged; this
  decision concerns Lift-mode specialization attached to a configuration.

## Test impact

`test/laws/static_reflection_test.ml` has five samples: persistent eval
counting, scoped eval tracing (including printing known Code), persistent apply
counting, scoped apply tracing, and persistent/scoped stacking. At depth 1 each
tower outcome and byte trace agrees with the residual; specialization produces
no program output; and the residual has zero eval-cell dereferences, evaluator
calls, constructor dispatch, `NamedVar` lookup, reflection boundary, or node
from an interpreter source.

The full pre-existing suite remains unchanged in result: 73 pure criterion
samples retain 906,708 tower dispatches, 2,125,589 evaluator-cell reads, and 250
residual nodes; the effect-order suite retains 324 checks; the depth suite
retains 417 invariant and 18 depth-sensitive checks.
