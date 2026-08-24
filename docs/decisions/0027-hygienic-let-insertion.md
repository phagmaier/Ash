# 0027 — Hygienic let-insertion with scoped block buffers

- **Status:** accepted
- **Date:** 2026-08-24
- **Task:** 5.2
- **Amends:** 0026 (the staged evaluator now uses ambient block buffers)

## Context

Task 5.2 addresses code and work duplication during partial evaluation (spec §7.2). Naive emission of dynamic computations inlines syntax trees at every reference site. On duplication traps such as `fn dbl(x) -> x + x` nested $N$ deep, naive tree construction duplicates subterms exponentially, generating $O(2^N)$ nodes.

Furthermore, dynamic branches (`If`) and dynamic bodies (`Lam`) require distinct, isolated emission scopes so that bindings emitted within a branch do not leak into the enclosing block or into parallel branches.

## Decision

**Scoped block buffers via `Ash_stage.Emit`.**
Following LMS-style let-insertion (spec §7.2), `Ash_stage.Emit` manages an ambient stack of mutable block buffers.
- `Emit.emit`: when a dynamic operation is emitted, if an ambient buffer is active and the node is a non-trivial computation (i.e. not already a `Var` or `Lit`), a fresh identifier is allocated with `Ident.fresh`, the binding `{ binder; value; span }` is recorded in the buffer with provenance `"stage/let-insert"`, and `Core.var binder` is returned. Trivial variables and literals pass through directly.
- `Emit.reify_block`: runs a computation with a fresh scoped buffer, restores the previous buffer on completion, and wraps the recorded bindings in forward order as nested `Core.Let`s around the returned expression.

**Dynamic branches and bodies use isolated buffers.**
In `Ash_stage.Staged_eval`, dynamic `If` evaluates the consequent and alternative branches within independent `reify_block` invocations. Dynamic `Let` evaluates its body within `reify_block`. When a closure crosses a Lift stage boundary, the evaluator reifies the closure's lambda syntax: its parameters become dynamic `Code(Var)` values and its body is evaluated in an independent `reify_block`. The top-level `run` and `fold` wrap evaluation in `reify_block`. This reifies syntax and captured static knowledge without adding closures to the fixed lift domain.

**Linearity on duplication traps.**
Because every dynamic operation is named by a fresh `let` at first emission, subsequent references pass the generated variable without duplicating the computation or the syntax.

## Alternatives

**Direct tree inlining.** Rejected: generates $O(2^N)$ terms on duplication traps and duplicates runtime side effects.

**Delimited control (`shift`/`reset`).** Deferred: the mutable scoped buffer stack with `Fun.protect` is simple, explicit, and matches the spec's recommendation.

## Consequences

- New module `Ash_stage.Emit` (`emit.mli`, `emit.ml`), exposed through `Ash_stage.Stage.Emit`.
- Staged evaluation in `Lift` mode automatically binds dynamic expressions with hygienic `let`s.
- Lambda results residualize their syntax, and each dynamic lambda body owns an
  isolated emission buffer.
- `test/unit/stage_test.ml` tests linear emission on duplication traps and isolated branch scoping.

## Test impact

- `test/unit/stage_test.ml` verifies:
  1. $N$-nested `dbl(x)` calls produce exactly $N$ `Let`s and linear $O(N)$ node counts up to $N=8$.
  2. Dynamic `If` branches maintain distinct buffers (e.g. 3 lets in consequent, 2 lets in alternative) under a single top-level `Let`.
  3. Correct let-insertion for stage-polymorphic primitives with dynamic arguments.
  4. Lambda results residualize executable syntax with body-local lets instead
     of attempting to lift closures.
