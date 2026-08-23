# 0015 — `open fn`: open-recursive evaluator groups at the Ash level

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 2.1

## Context

ADR 0008 put the host evaluator's group — `eval`, `apply`, `eval_list` — in
mutable cells from Phase 0, and tested there that a replacement intercepts every
nested step. What that record explicitly did *not* complete is the rest of task
2.1: the evaluator group written in Ash, which is the group a materialized tower
level will actually replace.

Spec §D3 asks for surface support so that the discipline is enforced rather than
remembered:

```ash
open fn eval(e, r, k) = …
```

with the meaning that references to group members compile to cell dereferences
through the current level's meta-environment rather than to direct calls. The
lexer has reserved `open` since task 1.1; nothing consumed it.

## Decision

**`open fn` is a surface binding form, and it lowers to cells rather than to
`LetRec`.** Core does not grow: the eleven forms are untouched, and an open group
is ordinary `Let`, `Lam`, and primitive application.

For a run of adjacent `open fn` declarations, the desugarer

1. binds one identity per member to a fresh cell (`open_cell`),
2. fills each cell with the member's lambda (`open_set`),
3. lowers **every** reference to a member's name — inside the group and after it
   — as `open_deref` of that cell, and every `member := …` as `open_set`.

A plain `fn` run and an `open fn` run are different binding forms, so a run of
one ends where the other begins rather than the two sharing a group.

**References after the group are dereferences too**, not just references within
it. §D3's wording is about the group's own recursion, but a caller that captured
the function directly would hold a reference no replacement reaches, and the
spec's own test — `let base = eval; eval := …` — is written from outside the
group. One rule, no boundary to get wrong.

**Group members are assignable and plain functions are not.** Replacing a member
is what a meta level does, so `eval := wrapper` must be legal; `f := …` on a
plain `fn` stays the immutable-binding error it already was. Assignment writes
*through* the cell rather than rebinding the name, so every dereference already
written sees the replacement.

**The store operations are spelled apart from the ordinary ones.** `open_cell`,
`open_deref`, and `open_set` do exactly what `cell_new`, `deref`, and `cell_set`
do. The difference in name is the point: an `open_deref` in a term is one
evaluator-group dereference and nothing else, so the collapse report can count
the ones that survive specialization without inferring which cells belonged to an
interpreter. §9's classification and this invariant are the same phenomenon seen
from opposite ends, and the spec's instruction is to instrument the cell from the
beginning.

`Primitives.open_dereferences` counts reads performed, not reads written, and it
counts them after the read succeeds — a refused read is not a dereference. The
counter lives on the registry rather than on a machine because an Ash-level group
is not the host machine's group; it is observationally inert, since no primitive
reads it and nothing an Ash program computes, prints, or fails with can depend on
it.

**Their class is allocation/mutation.** They are the store, and the store
residualizes by default. Phase 5 is where a specializer that has established
interpreter identity folds a dereference away, and that is a bespoke rule about
what is known, not a reclassification.

## Alternatives

- **`LetRec` plus a cell per member, dereferenced only inside the group.** This
  is §D3 read narrowly. Rejected: it leaves every external caller holding a
  direct reference, which is the same silent failure §D3 exists to prevent, and
  it makes the spec's own test unwritable.
- **Reusing `cell_new`/`deref`/`cell_set`.** Fewer primitives, and semantically
  identical. Rejected: the collapse report would then have to guess which cells
  were an interpreter's, and the number it exists to produce is exactly the count
  of surviving evaluator dereferences.
- **A Core form for open binding.** Rejected: Core is deliberately closed, and
  nothing here needs a new evaluation rule. Every later layer would have to grow
  a case for a form that means "`Let` of a cell".
- **A parameterized group threaded as an argument.** Also open recursion in a
  sense, but a replacement installed mid-evaluation would not be seen until the
  group was re-threaded from the top, which is what "intercepts every nested
  step" rules out. ADR 0008 rejected this on the host side for the same reason.
- **Counting dereferences in the desugarer.** That counts sites, not steps. The
  report wants steps.

## Semantic consequences

- An open group's binder holds a cell, so its name is not a function value:
  reading it costs a dereference and can be intercepted. This is a real cost per
  step, and it is the cost the collapse report exists to measure.
- The cell is created holding unit and filled immediately afterwards. No
  dereference can observe the placeholder, by the same argument that makes
  `LetRec` preallocation total: filling evaluates lambdas, and evaluating a
  lambda calls nothing.
- `Desugar.required_primitives` grows by three, so a registry that lacks them
  fails at lowering rather than at run time.
- The `desugar/open` provenance marker names the rewrite, so a residual program
  can still say which dereferences the desugarer wrote.

## Test impact

`test/laws/open_recursion_test.ml` is new and tests the law where it now lives:
wrapping `eval` in Ash observes every nested AST node (thirteen, for §D3's
`1 + (2 * (3 - (4 / 5)))`, against the nine the spec asks for as a lower bound);
`apply` and `eval_list` are patchable on the same terms; a replacement installed
while evaluation is under way takes effect at the next step, counted exactly;
restoring the cell restores the group; and the dereference counter is
observationally inert.

`test/unit/desugar_test.ml` pins the lowering of a single open function, of an
adjacent pair, of a reference after the group, of a replacement, and of a plain
group that must not merge with an open one, plus the two diagnostics.
`test/golden/parser.expected` and `test/golden/desugar.expected` pin the syntax
and the emitted Core.

## Required spec or measurement changes

None. This is §D3's surface support, built where §D3 says to build it.
