# 0014 — One-shot continuations, and how a primitive calls back

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 1.5

## Context

Spec §D4 asks for continuations that are first class but one-shot: storable in
data structures, passable to reifiers, invocable exactly once from anywhere, and
explicitly *not* escape-only, because an escape continuation cannot be handed to
a meta-level procedure and resumed after the meta level has done work — which is
most of what reifiers exist for. One-shot-ness is to be enforced dynamically with
a `used` flag and a clear error, precisely because the silent corruption it
prevents would otherwise surface in Phase 8.

Task 0.3 already built the continuation value with its procedure, `used` flag,
capture site, and first-use site. Task 0.8 left both applying a continuation and
the whole `Control` effect class deliberately unimplemented, naming 1.5. Two
things were missing: nothing could capture a continuation, and nothing could
invoke one.

Capturing exposed a gap. `Value.primitive` documents that primitives are in CPS
"so that control primitives are ordinary members of the registry rather than
evaluator special cases", but `prim_impl` received only the call site, the
arguments, and the continuation. `callcc` has to *apply* its argument, and there
was no way for a primitive to call an Ash function at all.

## Decision

**`callcc` is the whole `Control` class, and it is a primitive, not syntax.** It
takes one receiver, reifies the continuation of its own call as a value, and
applies the receiver to it. Nothing about control appears in Core: a surface
`callcc(f)` lowers to an ordinary application, so the eleven forms are untouched
and the self-interpreter has nothing new to handle.

**It is spelled without a slash.** `call/cc` is not a name the surface lexer can
produce — `/` is division — and a control operator a program cannot write is not
much of a control operator. The reflection-class names will be chosen the same
way.

**`prim_impl` gains an `~apply` argument.** The caller supplies it, so the
callback runs on whatever evaluator is executing: the ground evaluator passes one
that routes through the machine's open-recursion cell, which means a meta level
that replaces `apply` intercepts the call `callcc` makes just as it intercepts
every other call (spec §D3). The oracle passes its own direct-style `apply` read
as CPS — no pure primitive calls it, and passing one that raised would describe a
restriction the oracle does not actually have. Primitives that never call back
ignore the argument; the `nullary`/`unary`/`binary` wrappers drop it once.

**Applying a continuation is the evaluator's job, in `apply`.** It takes exactly
one value. The `used` flag is set *before* the transfer, so a continuation
reached again through its own resumption is caught by the same check rather than
looping. A second invocation raises the new `Error.Continuation_reuse`, carrying
both the capture site and the first-use site: the error is reported where the
second invocation was written, and neither of the other two places alone explains
the mistake.

**A continuation records its level.** `Value.continuation` now takes `~level`,
the tower level whose evaluation it would resume, and the reuse error is raised
at that level. Only level 0 exists before Phase 4, but a reifier at level `n + 1`
holds the continuation of level `n`, and a continuation that did not know its own
level could be resumed on the wrong machine. Retrofitting the field would mean
revisiting every capture site, which is exactly the argument that put open
recursion in at 0.8.

**Capture is classified `Control`, never folded.** Capturing is not itself an
observable effect, but the class says what a specializer may do, and folding a
capture during specialization would capture the specializer's continuation rather
than the program's — the same mistake §D7 names for `print`.

## Alternatives

**A `current_continuation()` primitive instead of `callcc`.** It needs no
applier, because the continuation of the primitive call is exactly the value to
return. But that continuation includes everything after the call, so resuming it
re-runs the code that received it, which makes ordinary escape use surprising and
makes handing a continuation to a receiver — the shape reifiers use — impossible
to write directly.

**Special-case `callcc` in the evaluator.** The evaluator already has `apply` in
hand, so this needs no type change. It also makes the one operator the tower is
built around a host special case rather than a registry entry, which is the thing
`AGENTS.md` names under scope control: an evaluator special case is where a
missing piece of expressiveness goes to hide.

**Give the registry an `apply` at construction.** Globals are built before any
machine exists and are cloned per tower level, so the registry would have to be
rebuilt per level or hold a mutable back-reference. Passing the applier per call
keeps the registry a description and lets each level supply its own.

**Multi-shot continuations now.** §D4 is explicit that backtracking reifiers,
`amb`, generator re-entry, and re-entrant `meta_with` all need multi-shot, and
that none of them is needed for the headline result. The `used` flag is what
makes the eventual change a decision rather than a discovery.

**Escape-only continuations.** Cheaper and sound, and it fails the one
requirement that matters: a reifier receives the continuation of the level below
and resumes it after doing work at its own level.

## Consequences

- `Value.continuation` takes `~level`; `Value.continuation_level` reads it.
- `Value.primitive.prim_impl` takes `~apply`, and `Value.applier` names the type.
  Every caller of `prim_impl` — the evaluator, the oracle, and tests that call an
  implementation directly — supplies one.
- `Error.Continuation_reuse` carries both sites; every exhaustive match over
  causes was updated.
- The registry is 26 primitives, and `Effect_class.Control` is no longer empty.
  The test that asserted it was empty now asserts it is exactly `callcc`, so
  filling it stayed a deliberate change.
- The oracle's refusals are unchanged: it still rejects any primitive that is not
  pure, so `callcc` is refused by name, and it still refuses to apply a
  continuation value.

## Test impact

`test/unit/continuation_test.ml` covers escape from a recursion, a receiver that
returns normally, the continuation of the enclosing expression rather than of the
program, abandonment of the rest of the receiver, storage in a mutable binding
and in a list, capture in one function with invocation from another after that
function returned, the reuse error with all three sites distinct and the level
recorded, reuse reached through the continuation's own resumption, the arity of
both `callcc` and a continuation, and the oracle's refusal of each. It also
checks that a replaced `apply` sees the call `callcc` makes, which is the
open-recursion property the applier exists to preserve.
