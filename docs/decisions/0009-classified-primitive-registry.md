# 0009 — The classified primitive registry and the observable-effect stream

- **Status:** accepted, clarified by
  [0018](0018-hygienic-code-and-refutable-shapes.md) and amended by
  [0019](0019-closed-code-run.md), [0020](0020-fixed-lift-domain.md), and
  [0021](0021-real-code-self-interpreter.md)
- **Date:** 2026-08-23
- **Task:** 0.9

## Context

Spec §D7 fixes the specialization policy per effect class rather than uniformly,
because folding `print("hello")` when its argument is static makes *compilation*
print and the compiled program silent. ADR 0007 put the class on the primitive
record and populated only the pure class, leaving the registry — every primitive
classified, observable output buffered, arity and type errors consistent — to
this task.

Two things had to be decided beyond bookkeeping: what an observable effect
actually writes to, since Ash's equivalence claims are about traces and not just
answers, and what to do about the two classes whose members belong to phases that
do not exist yet.

## Decision

**Exactly one class per primitive is a property of the type, not of a check.**
`Value.primitive` carries `prim_class`, so a primitive with no class cannot be
written down and a primitive with two is not expressible. What the type cannot
rule out is one *name* registered twice under different classes, where a lookup
would answer one and the environment bind the other, so registry construction
raises `Invalid_argument` on a duplicate name. The classification table is
derived from the registry rather than written a second time, so the two cannot
drift; the test suite carries its own independent table, so a primitive added
without a deliberate classification decision fails a test rather than inheriting
its neighbour's class.

**The registry is an instance, not a constant.** Observable primitives are closed
over an `Io.t`, so `Primitives.create ?io ()` builds a registry over a stream and
`Primitives.globals` hands out fresh identities bound to the *shared* primitive
values. A materialized tower level clones its globals — new identities — but
keeps the same stream: output is one ordered sequence of events for the whole
tower, not one per level. Names, count, and classification are the same for every
registry and stay module-level.

**Observable effects go to an injectable, recording stream.** `Ash_runtime.Io`
records `Wrote` and `Read` events in order, optionally echoing writes to a
channel for interactive use. Echoing is an addition to the record, never a
replacement: a trace is a value tests compare, which is what makes "the residual
program produced exactly the source program's effects" a checkable claim rather
than an aspiration, and it is also what would expose a specializer that ran
`print` at the wrong time.

**Input is scripted for the same reason.** `read_line` consumes lines supplied to
the stream, and running out of them is `Error.End_of_input` — a new structured
cause. Reading from the host would make a program's behaviour depend on something
outside the recorded trace, which no differential or golden test could pin down.
End of input is a program-level condition, not a host failure, so it is an
ordinary Ash error with a span rather than an exception of another kind.

**`print` writes a string's characters; a diagnostic writes its literal.**
`print("a\nb")` emits two lines, while `Value.to_string` on the same value is
`"a\nb"` with the escape visible. Printing the escaped literal would make `print`
useless for producing text, and every other value prints as it reads back.
`println` appends a newline and is a separate primitive rather than a flag,
because the trace records exactly what was emitted.

**The mutation primitives are `cell_new`, `deref`, and `cell_set`.** The spec's
table calls the third `set`, but Core already has a `Set` form for assigning a
lexical binding, and one name for two different operations in a language whose
whole subject is the difference between an environment and a store would be a
poor trade for matching the table's spelling.

**Immutable list operations stay pure.** `cons`, `list`, and `tail` allocate in
the host, but allocation is only observable when it can be mutated or compared by
identity, and `Value.equal` compares lists structurally. The allocation/mutation
class is about cells, which is what the Phase 7 store discipline reasons about.

**Control and reflection are registered empty.** `call/cc`, `resume`, and `abort`
need the one-shot continuations of task 1.5; `lift`, `run`, `reflect`, and `up`
need staging and the tower. A primitive that exists but refuses to run is a worse
answer than one that is honestly absent: it would appear in the classification, in
`globals`, and in a report, describing a capability Ash does not have. Nothing
about the classification depends on a class being populated, and the test suite
asserts the two are empty so that filling them is a deliberate, visible change.

ADR 0018 later clarifies that immutable Code construction and observation are
Pure under spec D7, so adding them does not populate Reflection. Closed-code
execution and tower-dependent operations remain bespoke reflective work.

**Arity is checked twice and reports identically.** Whatever applies a primitive
checks arity first, so every arity error names the primitive, its arity, and what
it was given, wherever the call came from. The implementation checks again because
`prim_impl` is a total function and an incomplete match would be a host crash
rather than an Ash diagnostic. A test applies every registered primitive at every
wrong count, through the evaluator and directly, and requires both paths to
produce the same cause at the call site — so consistency is a property of the
registry rather than of the primitives someone remembered to test.

Argument types are checked inside the primitive, left to right, matching Ash's
argument evaluation order, and reported at the call site, which is the only
location a primitive has. Each primitive's rejections are listed in a test table
whose keys must equal the registry's names.

## Alternatives

**A single global registry with a global output buffer.** Simpler to call, but two
tests would then share one stream, and per-level cloning in Phase 4 would have
nowhere to put a level's own state. Injecting the stream costs one parameter.

**`print` returning its argument rather than unit.** Convenient in expression
position, but it invites `print` inside otherwise pure expressions and makes the
effect easier to overlook when reading a term the collapser is about to stage.

**Stubbing control and reflection primitives that raise `Unsupported`.** Rejected
above: the classification would claim members it does not have.

**A separate `static_log` now.** §D7 suggests it for compile-time logging, but
nothing specializes yet, so it would be a primitive with no defined behaviour to
test. It belongs with the collapser.

## Consequences

- Every primitive's specialization policy is available as
  `Effect_class.may_fold_when_static` and `always_residualizes` on its class, so
  the collapser never inspects a primitive's identity to decide what it may do.
- The oracle's existing refusal of non-pure primitives now has something to
  refuse, and it refuses by class, so any primitive added to a non-pure class is
  outside the frozen oracle from the day it is registered.
- Effect-order tests (task 7.3) have a trace format to compare: `Io.events`.
- `Error.End_of_input` is a new cause; anything matching exhaustively on causes
  must handle it.

## Test impact

`test/unit/primitives_test.ml` covers the classification (including that the
classes partition the registry), registry-wide arity consistency, per-primitive
type errors, cells and aliasing, buffered output, scripted input, the stream
itself, and per-level globals. `test/unit/oracle_test.ml` now checks the frozen
boundary against the registry rather than asserting every primitive is pure.
