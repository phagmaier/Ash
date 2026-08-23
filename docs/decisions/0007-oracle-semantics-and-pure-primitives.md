# 0007 — Oracle semantics and the pure primitives

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 0.7

## Context

`Ash Reflective Tower.md` §D2 asks for a direct-style oracle whose only job is
differential testing on the ordinary-Core corpus, and which is never extended.
Writing it forces every dynamic-semantics question that the spec leaves to the
implementation: what order arguments are evaluated in, whether `If` coerces,
what integer division does, what `==` means, and where the oracle's frozen
boundary actually falls. Each of these must be answered once, because the CPS
evaluator, the self-interpreter, and every residual program have to agree with
whatever it is.

The oracle also needs arithmetic and lists to satisfy its own acceptance
criterion, so a pure primitive set arrives here rather than waiting for the full
registry in task 0.9.

## Decision

**Evaluation order is the function position, then arguments left to right.**
Order is observable — through mutation, through which of two failing arguments
reports first — so it is fixed rather than inherited from the host, whose
argument evaluation order is unspecified. The oracle sequences with explicit
`let` bindings for exactly this reason, and a primitive checks its argument types
in the same order.

**`If` requires a boolean.** There is no truthiness coercion in Core: a condition
that is not `true` or `false` is a type error. Strictness is easier to analyse
and surfaces mistakes early, and it matches the spec's own `my_if` (§5.4), which
calls an explicit `truthy` on the value it tests rather than relying on `If` to
coerce. `truthy` will be an ordinary primitive when the self-interpreter needs
it.

**Integer division truncates toward zero and the remainder takes the sign of the
dividend**, as OCaml's `/` and `mod` do. Division by zero is an
`Error.Division_by_zero`, not a trap or a wrapped value.

**`Value.equal` — what `==` computes — is structural for scalars and lists and
by identity for everything else.** Two closures with the same body are two
closures; two cells with the same contents are two places. Primitives compare by
name, so the same primitive drawn from two cloned global environments is one
value. `Code` compares by identity for now; whether quoted code should compare by
alpha-equivalence is a Phase 3 question, and nothing that can reach this equality
has a `Code` value yet.

**The oracle's frozen boundary is drawn at reflection, staging, and control.**
It supports `Lit`, `Var`, `Lam`, `App`, `Let`, `LetRec`, `If`, and `Set`, and
refuses `NamedVar`, `Quote`, `Reifier`, applying a continuation, and any
primitive whose class is not `Pure` — always with an `Error.Unsupported` naming
what was refused and where.

`Set` is inside the line even though it mutates: it is neither reflection,
staging, nor control, the corpus in task 1.6 explicitly compares mutations, and
supporting it costs three lines because environments already hold cells.
Refusing an effectful primitive is not a restriction but the D7 rule itself —
running `print` at oracle time would move the effect out of the program.
`NamedVar` is refused because resolving a variable by name against a first-class
environment is what reflective code does, and ordinary compiled code never
produces one.

**Primitives receive their call site.** `prim_impl` takes `~call_site:Span.t`,
because a primitive that rejects an argument has no other location to report and
a diagnostic without one is not much of a diagnostic. **Arity is checked by
whatever applies the primitive**, so every arity error reads the same wherever it
comes from; the primitive checks only its argument types. A pure primitive is
invoked with the identity continuation, which is sound precisely because it is
pure: it calls its continuation exactly once, in tail position.

**Runtime type errors reuse `Error.Unexpected`.** The `phase` field already says
whether a mismatch was syntactic or dynamic, so a second cause with the same
shape and the same message would be duplication. Values contribute their
`Value.type_phrase` — `"a number"`, `"the empty list"` — so the message reads
properly either way.

## Alternatives

- **Leaving evaluation order to the host.** Free, and wrong: OCaml does not
  specify its argument order, so the oracle and the CPS evaluator could disagree
  on effectful programs and the differential corpus would be testing the host.
- **Truthiness in `If`.** Convenient in a dynamically typed language, but it
  makes every condition's static type unknowable, which the collapser will care
  about, and it silently accepts what is almost always a mistake.
- **Arbitrary-precision integers, or wrapping division by zero.** Deferred with
  ADR 0002's numeric decision; an error is the answer that cannot be silently
  wrong.
- **Structural equality for closures.** Undecidable in general, and wrong even
  where decidable: two closures over different cells behave differently.
- **Letting the oracle evaluate `Quote` or `NamedVar`.** Both are easy — a few
  lines each. That is the trap. The oracle's value comes entirely from being
  simple enough to believe by reading, and every feature it grows is a feature it
  can no longer independently check.
- **Each primitive checking its own arity.** Would let a primitive report arity
  its own way, which is precisely the inconsistency task 0.9 wants to avoid.
- **A separate `Type_error` cause.** Rejected as duplication: `phase` already
  distinguishes syntactic from dynamic, and two causes with identical shape and
  message would only make reports harder to aggregate.

## Semantic consequences

- Any evaluator claiming to agree with the oracle must evaluate the function
  position first and arguments left to right, require booleans in `If`, and match
  these arithmetic and equality definitions. These are now the reference
  semantics for the whole project.
- The oracle recurses on the host stack, carries no instrumentation, and has no
  step budget. It is unsuitable for deeply recursive or non-terminating programs.
  Host stack depth is an excluded observation, so a comparison that overflows
  there is a badly chosen test rather than a difference between evaluators.
- `Primitives.globals ()` allocates fresh identities on every call, because a
  materialized tower level gets its own cloned global environment (§6.1) and must
  not share binders with another level.
- The primitive set is pure-only and deliberately incomplete. Task 0.9 adds the
  allocation, observable, control, and reflection classes, buffered output, and
  the completeness check that every primitive has exactly one class.

## Test impact

`test/unit/oracle_test.ml` covers the primitive registry (all pure, distinct
names, fresh identities per clone), arithmetic including truncation, remainder
sign, division by zero, and left-to-right argument checking; comparison including
structural equality of lists and identity of closures; functions, closures,
lexical scope with a rebinding that a closure must not see, currying, and arity
and type errors both named and anonymous; `If` with both branches, an unevaluated
untaken branch, and a rejected non-boolean condition; `Let` shadowing; `LetRec`
with factorial, 20! as the machine-word boundary, mutual recursion, and an empty
group; immutable lists including two recursive list functions; mutation reaching
a closure that already captured the binding; the two evaluation-order
observations; and every refusal the frozen boundary makes, including that an
effectful primitive does not run and that refusals are located.

## Required spec or measurement changes

None.
