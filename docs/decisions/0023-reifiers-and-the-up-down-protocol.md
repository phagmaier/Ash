# 0023 — Reifiers, the up/down protocol, and level ownership of errors

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 4.2
- **Amends:** 0009 (the reflection and control classes gain members), 0014
  (a continuation's level is now the machine's, not a constant), and 0022
  (`materialize_above` gains its language-level caller)

## Context

Task 4.1 left the tower able to materialize a level and nothing able to ask for
one: applying a reifier raised a deliberate refusal. Task 4.2 has to connect the
two halves and decide, for each of them, which level owns what — which machine
runs a reifier body, which level a continuation resumes, and which level an
error belongs to. Getting any of those wrong produces a tower that computes the
right answers for the wrong reason, which is the failure mode the whole project
is built to detect.

Three constraints shape the answer. Lower layers cannot import higher ones, so
`ash.runtime` cannot call `ash.tower`. One primitive registry serves the whole
tower (ADR 0017), so a primitive value cannot know which level is running it.
And the evaluator must keep Ash tail calls in constant host stack, which rules
out wrapping a level's evaluation in a host exception handler.

## Decision

**Reification happens in `eval`'s `App` case, not in `apply`.** A reifier
receives the whole unevaluated call (locked decision), and an applier sees
values with no call expression to hand up. Dispatching on the callee before
`eval_list` runs is what makes an unreflected argument produce no effect at all.
Applying a reifier through the applier — `invoke`, or any future spread — is
refused rather than approximated, because there is no whole call to reify.

**A reifier body runs on the machine above and in the environment below.** The
body's lexical environment is the one the reifier was written in, which belongs
to level *n*: which machine evaluates a term does not change what its free
hygienic identities mean. What changes is that replacing level *n+1*'s evaluator
cell intercepts the body and replacing level *n*'s does not. Level *n+1* is
obtained through `Tower.materialize_above`, so one reifier application
materializes exactly one level and nesting materializes exactly one more.

**The body runs under the identity continuation.** A reifier that never invokes
the continuation it was handed does not return to level *n* at all: its value is
the answer of the run, and level *n*'s pending work never happens. That is the
operational content of "level *n* never resumes", and `up` (task 4.3) is the
sugar that always resumes because its expansion ends in `cont(v)`.

**The runtime learns its neighbourhood from a neutral protocol record.**
`Machine.levels` holds the level index, a thunk for the level above, and the
machine below. The tower installs it when it creates a level; the runtime only
reads it. The thunk keeps materialization lazy, and the machine below can be a
value because a level above cannot exist before the one it interprets. A machine
with no record installed is the base program and nothing else: it answers level
0, refuses reifier application, and refuses `reflect`.

**`reflect` is a primitive with an evaluator callback, like `run`.** It
evaluates Code on the machine below and then transfers to the continuation it
was given, through the caller's own applier — invoking a lower level's
continuation is work the upper level does, and it gets the ordinary one-shot
check. Its answer is the answer of the reifier body, which is what makes the
identity reifier observationally the identity function.

**`resume` is Control; `reflect` and `meta_error` are Reflection.** `resume` is
`invoke` narrowed to one argument and inherits its callee's class, exactly as
D7 says. `meta_error` is Reflection rather than Pure because the level is part
of its result: folding it at specialization time would report the failure at
whatever level the specializer ran at, which is the mistake D7 names for
`print`.

**Every error an evaluator raises carries the level of the machine that raised
it.** Levels are relative, so ordinary evaluation reports level 0 and a reifier
body reports level 1. `raise_at` uses the same level, so an interpreted level's
failure is attributed to the level running the interpreter rather than to a
constant; the `Some 0` the continuation-reuse descriptor used to carry is gone
for that reason. A continuation-reuse error is the one deliberate exception: it
names the level whose control was corrupted, which is where the continuation
came from rather than where it was misused. `Error.to_string` prints a level
only above 0, because level 0 is the base program and naming it would appear on
every ordinary diagnostic and distinguish nothing.

**`meta_error` raises rather than producing an error value.** Task 0.4 flagged
that errors as ordinary values at level *n+1* would be a level-crossing
mechanism that must not quietly widen the ground `answer` type. It does not:
`meta_error` raises a structured `Meta_error` cause at its own level like any
other failure. Catching an error *as a value* at level *n+1* needs a handler
form Core does not have, and inventing one here would be exactly the quiet
widening that note warned against.

## Alternatives

**Attribute the level by catching and re-raising around each level's
evaluation.** Rejected: a handler installed around `Machine.eval` stays on the
host stack for the whole nested computation, so a tail-recursive Ash loop inside
a reifier body would stop running in constant host stack. Threading the level
into each raise costs a parameter and changes no operational behaviour.

**Resume level *n* automatically when a reifier body returns.** Rejected. It
makes every reifier total and deletes the abandoning reifier — the one that
replaces the lower computation instead of extending it — which is a genuine
tower behaviour and the thing `up`'s explicit `cont(v)` is defined against.

**Give the reifier body level *n+1*'s global environment instead of the
definition environment.** Rejected: a reifier's free variables are written at
level *n* and resolved hygienically, so re-resolving them against a cloned
global frame would either fail (fresh identities) or silently mean something
else. The meta bindings task 4.3 adds are extensions of the body's environment,
not a replacement for it.

**Let a primitive find its level from mutable evaluator state.** Rejected:
a mutable "current level" is unsound under captured continuations for the same
reason save/mutate/restore is unsound for `meta_with` (D8). The level travels as
an argument to the primitive and as a field on the continuation.

**Thread the level through primitive argument diagnostics too.** Deferred, not
rejected. A primitive's type and domain errors are properties of the shared
primitive value and its call site; they currently carry no level. Giving them
one means passing the level into every argument helper, and nothing in the tower
laws depends on it yet. It is recorded as a known gap rather than half-done.

## Consequences

- `Tower.create` and `Tower.materialize_above` install the level neighbourhood
  on each level's machine; that record is the entire coupling between the tower
  and the runtime.
- The registry grows to 44 primitives: `resume` in Control, `reflect` and
  `meta_error` in Reflection.
- `Value.primitive` implementations receive `level` and a `reflect` callback.
  Every primitive that ignores them says so explicitly.
- Ground diagnostics gain a level of 0, which renders identically to before.
  Diagnostics from a materialized level name it.
- The self-interpreter still refuses reifier application. It is an interpreter
  layer, not a tower level (ADR 0017), and giving an interpreted level its own
  tower is not this task's protocol.

## Test impact

`test/unit/reifier_test.ml` covers the identity reifier's value and its
exactly-once effect, arguments left unevaluated, `resume`, the abandoning
reifier, one-shot enforcement of a continuation stored across the level
boundary, nesting materializing exactly two levels, a level-1 evaluator patch
that changes the body and not the program, and error ownership in three places:
`meta_error` at level 1 with no resumption of level 0, an unbound identity in
the body at level 1, and the same unbound identity in reflected code at level 0.
Both refusals without a tower are covered. `test/unit/primitives_test.ml` gains
the three primitives in its classification, arity, and type tables.

## Required spec or measurement changes

None. This implements spec §5.4 and the level-relative numbering of §D9. The
§5.7 laws for reifier identity, level independence, and error propagation are
demonstrated here for one step; the depth-parameterized law suite is task 4.4
and owns those checkboxes.
