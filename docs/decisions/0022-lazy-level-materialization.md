# 0022 — Tower levels materialize one step at a time

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 4.1

## Context

The reflective tower is conceptually unbounded, but spec §6.1 requires levels
above the highest reflected-upon one to remain potential rather than physical.
Task 4.1 must establish that fast path before reifier application gives it a
language-level caller in task 4.2. It must also make the locked per-level state
decision concrete: each level gets cloned hygienic globals and fresh
open-recursion cells, while primitive values and their observable stream remain
shared.

The size terminology is another correctness boundary. An eager semantic tower
contains one interpreter AST per depth, but the lazy runtime does not. Reporting
the conceptual node formula as physical storage would claim that the
implementation contains data it never allocated.

## Decision

**Ground is present but is not an upper materialization.** `Tower.t` retains a
level-0 `Level.t` separately and starts with an empty upper-level list, so
`Tower.materialized` is zero on the ordinary ground fast path. `Tower.run`
evaluates through that ground level and has no route that can allocate an upper
level.

**Reflection materializes only the adjacent level.**
`Tower.materialize_above ~level:n` requires level *n* already to exist, returns
an existing level *n+1* when present, and otherwise allocates exactly that one
level. It cannot skip potential levels. Task 4.2 will use this operation for
reifier application; exposing the materialization boundary separately here lets
4.1 test laziness without pretending the up/down protocol already exists.

**Every `Level.t` owns one cloned global environment and one fresh machine.** A
level calls `Primitives.globals` once, extends an empty environment with those
bindings, creates its own `Evaluator.machine`, and installs that same environment
as the machine's explicit global. Binder identities, binding cells, evaluator
group cells, replacements, and counters are consequently independent between
levels. The tower shares one `Primitives.t`, so the primitive values and IO event
stream remain common to the whole tower as ADRs 0009 and 0017 require.

**Physical and semantic size are different records with different units.** The
materialized-runtime record reports the upper-level count, cloned global-cell
count, evaluator-group-cell count, and actual OCaml heap words reachable from
the complete tower value. `Obj.reachable_words` counts shared objects once and
includes the ground/registry baseline; it is observational instrumentation and
is never exposed to Ash evaluation. The expanded-semantic record uses
`Core.node_count` and reports exactly
`program_nodes + depth * interpreter_nodes_per_level`. Quoted Core is included,
following the existing `Core.node_count` decision. A requested semantic depth
below the number of levels already materialized is rejected as contradictory.

## Alternatives

**Store ground in the materialized list.** Rejected because a fresh tower would
then report one materialized level while the spec defines the ordinary fast path
as `materialized == 0`. Keeping the unavoidable host baseline separate makes the
number mean upper levels that laziness actually created.

**Materialize through an arbitrary requested index.** Rejected because a call
from level 0 that silently creates levels 1 through 5 would defeat the
one-reflection/one-level acceptance criterion and could hide an ownership bug in
the future reifier protocol.

**Clone the primitive registry per level.** Rejected because observable output
would split into separate streams and a primitive crossing interpreter layers
would cease to be the shared value fixed by ADR 0017. Fresh binders and cells,
not fresh primitive implementations, are the independence boundary.

**Estimate physical size with interpreter node counts.** Rejected because no
interpreter AST is duplicated in the lazy runtime representation. Structural
counts explain which retained components grew, while reachable heap words
measure the representation that actually exists.

**Report allocated bytes around materialization.** Rejected because allocation
traffic includes temporary values and GC state. Reachability measures retained
representation instead of work performed while constructing it.

## Consequences

- `ash.tower` is a new layer above `ash.runtime`, containing `Level` and `Tower`.
- Ordinary evaluation cannot accidentally materialize an upper level.
- Reifier work in 4.2 has one ownership-preserving operation for obtaining the
  adjacent level and cannot skip a level.
- Patching a materialized machine or mutating one global cell cannot alter any
  other level's machine or global cell.
- Heap-word measurements are host/runtime-version dependent and belong to the
  reproducibility environment, not Ash's observable semantics.
- Reifier application still raises the deliberate task-4.2 refusal; this record
  introduces no partial cross-level semantics.

## Test impact

`test/unit/tower_test.ml` checks that ordinary Core leaves the upper count at
zero; the first materialization request creates exactly level 1; repeated and
nested requests reuse or create exactly the expected adjacent level; three
levels have distinct global identities, global cells, and evaluator machines;
and a replacement installed at level 1 affects neither level 0 nor level 2. It
also pins the physical structural counts, verifies reachable representation
growth, and checks the expanded node formula stays unchanged by laziness.

## Required spec or measurement changes

No semantic change. This implements spec §6.1 and the two distinct size names
from §9.1. Later reporting may add more structural components, but it must keep
actual reachable representation and expanded semantic nodes separate.
