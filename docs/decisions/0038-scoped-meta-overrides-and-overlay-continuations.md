# 0038 — Scoped meta-overrides and overlay continuations

- **Status:** accepted
- **Date:** 2026-09-18
- **Task:** 8.1, 8.2
- **Amends:** 0009 (the reflection class gains three readers/runners), 0014
  (a captured continuation now captures the overlay pointer too), 0024 (the
  group cells gain a scoped counterpart that never writes them)

## Context

Task 4.3 left `meta_with` (§5.5) as Phase 8: persistent mutation (`up { eval
:= … }`) existed, dynamic scope did not. Spec D8 already chose the mechanism —
overlay frames, never save/mutate/restore — and named the hard part:
a continuation captured inside the extent and invoked outside it must see the
overlay while the ambient list is unaffected. One-shot continuations (D4) make
this sharp: re-entrant resumption (using one node continuation twice) needs
multi-shot, which the spec defers, so the law test must capture once and
resume once.

Three constraints shape the answer. Lower layers cannot import higher ones, so
the overlay frame type lives in `ash.core` alongside `meta_query`, and the
machine passes three closures over its pointer to every primitive. One
registry serves the whole tower (ADR 0017), so only the applying machine knows
which overlays are current. And Core is untouched: `meta_with` lowers to
primitives and lets, like `up` lowers to a reifier.

## Decision

**Overlays are a persistent list per machine.** `Machine.overlays` is a
mutable pointer to `Value.overlay_frame list`, each frame holding optional
`eval`/`apply` overrides. Pushing prepends and shares the tail; capturing
shares the spine; leaving resets the pointer. Frames are never mutated and
persistent cells never touched — that is what makes this dynamic scope rather
than save/mutate/restore (invariant 8). Lookup precedes persistent cells:
innermost `Some` wins, `None` falls through. `NamedVar` never sees the list:
it searches only explicit environments, and desugaring never puts a frame
there (the body lowers under the surrounding scope; only the right-hand sides
bind `eval`/`apply`, to the outer effective evaluator).

**`meta_with(eval = E, apply = F) { B }` is surface sugar.** The parser takes
`=`-bound overrides (at least one) plus a block, like `up` takes a block.
Lowering validates slots (`eval`/`apply` only, no duplicates), reads the outer
effective evaluator with two new Reflection readers, lowers each right-hand
side under `eval`/`apply` bound to those readings (in source order), and calls
a third Reflection primitive `meta_with_run(new_eval_or_unit,
new_apply_or_unit, fn() -> B)`. `unit` means "leave alone". Core is untouched;
provenance is `desugar/meta_with`.

**`meta_with_run` brackets.** It pushes one frame, runs the thunk through the
machine's own `apply`, and restores the saved pointer on return and on
failure — so an error never leaks an extent. Abandoning through a captured
continuation needs no special case here: invoking that continuation restores
its own captured pointer (below), which pops the leaked frame on the way out.

**Dispatch checks overlays first and runs wrappers above.** `Machine.eval`
and `Machine.apply` consult the overlay stack before the group cell. A hit
runs on the machine above (materializing on demand, like the persistent
dispatcher), so a wrapper never intercepts its own execution; without a tower
installed it runs locally with overlays disabled, which computes the right
value for delegating wrappers but only intercepts the top node — tower runs
(which is what every law test uses) intercept every nested step. Wrappers
close over the outer effective evaluator, so nesting composes most-recent-
outermost, like persistent replacements do.

**Continuations capture the pointer.** `Machine.capture_continuation` wraps
every Ash-visible continuation (reifier suspensions, persistent-dispatch
continuations, overlay-dispatch continuations, and `callcc` via its new
`~overlay` control) so invoking restores the target machine's pointer before
resuming, without touching the ambient list or any cell. `callcc` captures
`overlay_current()` alongside the level; `meta_with_run` restores on return.

## Alternatives

**Save/mutate/restore the persistent cell around the body.** Rejected by D8
and invariant 8: a continuation captured inside and invoked outside would see
whatever the cell holds at invoke time (ambient), not at capture time, and
under multi-shot "restore" has no meaning. Overlays sidestep this; the test
that would catch the mistake is 8.2.

**Put the pushed frame in the lexical environment so direct `eval` reads see
it.** Rejected by the locked hygiene decision: `NamedVar` searches explicit
environments, never overlays. The body lowers under the surrounding scope, so
a direct `eval` there answers the surrounding binding, not the pushed value —
while every evaluation step still goes through the pushed frame. Right-hand
sides are the one place that names the dynamic evaluator, and they see the
outer one.

**Make overlay-dispatch continuations multi-shot so re-entrant tests pass.**
Rejected: continuations are one-shot (D4), and re-entrant `meta_with` is
deferred to multi-shot work by the spec itself. The 8.2 test captures once
(an abandoned literal's node continuation, via an outer escape that pops the
leaked frame on the way out) and resumes once; no node continuation is used
twice and no `callcc` call itself goes through an overlay that would wrap it
twice.

**Run no-tower wrappers on a fresh ephemeral upper machine.** Deferred, not
rejected. The current fallback (run locally with overlays disabled) computes
the right value for delegating wrappers and is what ground source runs do,
but it intercepts only the top node there. Tower runs — which is what the
laws measure — intercept every nested step. A temp upper would close the gap
for ground runs; nothing in Phase 8's acceptance needs it.

## Consequences

- `Value` gains `Current_eval`/`Current_apply` queries, `overlay_frame`, and
  `overlay_control`; every `prim_impl` takes `~overlay` (ignored with `_`
  except by `callcc` and `meta_with_run`).
- The registry grows 50 → 53 primitives: `meta_current_eval`,
  `meta_current_apply`, `meta_with_run`, all Reflection. Collapse goldens now
  report 53 global cells; dispatch/cell figures and 250 residual nodes are
  unchanged, and the pure corpus still collapses bit-identically.
- `Machine` gains overlays, `overlay_control`, and `capture_continuation`;
  `Evaluator` and `Staged_eval` use both for reifier suspensions and the two
  new readers. The oracle refuses overlays (it has no machine).
- Surface gains `Meta_with`; the parser, printer, and desugarer handle it;
  unknown/repeated slots fail at lowering, an empty list at parsing.
- `test/unit/meta_with_test.ml` proves 8.1 (interception past the outermost
  node, nested stacking, slot independence, persistent untouched, surface
  refusals) and 8.2 (capture-inside/invoke-outside with restored overlay and
  unaffected ambient, plus a nested-error law test where the outer wrapper's
  print survives the inner division-by-zero).

## Test impact

`meta_with_test.ml` (8 tests, see above). `primitives_test.ml` gains the
three classifications, arities (via the generic loop), and type expectations
(`meta_current_*` answer at the base; `meta_with_run` with two units and a
non-function thunk reports the applier's type error). `parser_test.ml`
covers the new spans. `desugar_test.ml` is unchanged (shapes still pin `up`;
`meta_with` is pinned end-to-end instead). Golden collapse output is
re-promoted for 53 cells only.

## Required spec or measurement changes

Spec §5.7's overlay law and §8's Phase 8 become done, citing this record. No
counter changes meaning or value; the collapse report counts the three new
Reflection boundaries where they survive (as it already does for `meta_*`).
