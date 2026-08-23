# 0003 — Core AST and runtime value representation

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 0.3

## Context

`Ash Reflective Tower.md` §3 fixes the eleven Core forms and the value shapes,
but not their host representation. Several of the gaps are load-bearing: the CPS
answer type appears in the type of every continuation, the shape of `LetRec`
decides whether preallocate-then-fill can be total, and whether a primitive knows
its effect class decides whether §D7's policy is enforceable at all. These are
cheap now and expensive after the evaluator, self-interpreter, and collapser are
written against them.

## Decision

**`Value.answer = value`.** The spec's `Ans` is just a value. Evaluator
continuations are invoked in tail position and OCaml guarantees tail-call
optimization, so CPS evaluation runs in constant host stack without a
trampoline — which matters because host stack depth is an excluded observation
and must not become a semantic limit. Widening `answer` to carry an error or
effect channel changes the type of every continuation and needs a superseding
record.

**`LetRec` binds lambdas in the type, not by convention.**
`rec_binding = { rec_name; rec_lambda : lambda; rec_span }` rather than a general
expression. §3 already specifies `LetRec [(ident, Lam)…]`, and encoding it makes
the obvious implementation total: allocating cells, evaluating the lambdas in the
extended environment, and filling the cells cannot observe an unfilled sibling,
because evaluating a lambda calls nothing.

**`Reifier` has three named parameters.** `exp_param`, `env_param`, `cont_param`
rather than an identifier list, so a reifier of the wrong arity is not
representable and the whole-call reification protocol reads the same in Core, in
the evaluator, and in the self-interpreter.

**Cell contents are `value option`, and `cell` is a private record.** `None`
means preallocated but unfilled, so a read before filling is reportable rather
than silently yielding a default. Privacy means only `Value.fill_cell` can mutate
a cell: cells are the only mutable part of the value domain, and every
store-splitting argument in Phase 7 depends on knowing exactly where mutation can
occur. `continuation` is private for the same reason — its `used` flag is the
one-shot enforcement mechanism of §D4, and `mark_continuation_used` deliberately
never overwrites the recorded first-use site, because the reuse diagnostic has to
name both sites.

**Frames and environments are immutable.** `env = frame list`,
`frame = { bindings : cell Ident.Map.t }`. Mutation visible to closures comes
from cells, not from rebinding, exactly as §3 intends. A level's *global*
environment therefore cannot be a mutable frame; Phase 4 gives each materialized
level a reference to its own cloned global environment instead.

**Primitives are CPS and carry their effect class.**
`prim_impl : value list -> (value -> answer) -> answer` means control primitives
are ordinary registry entries rather than evaluator special cases.
`Effect_class.t` fixes §D7's five classes now — `Pure`,
`Allocation_or_mutation`, `Observable_effect`, `Control`, `Reflection` — with the
named predicates `may_fold_when_static` and `always_residualizes`. Task 0.9 fills
the registry and the arity/type error behaviour; the taxonomy is fixed here so no
primitive can be defined without a class.

**Runtime scalars are their own constructors, bridged to `Constant.t`.**
`Value.of_constant` and `Value.to_constant` convert, and `Constant.Nil` maps to
`Value.List []`: the empty list is a value shape, not a separate runtime
constant. The two domains are kept apart because a literal and a runtime value
are different things — `Code` and closures have no literal form, and a future
Core literal need not be a value shape.

**No catch-all matches over `Core.shape` or `Value.value`.** Every match in this
library enumerates its constructors, including the negative cases, so adding a
form or shape is a compile error at every site that interprets one. This is what
"unknown variants fail explicitly rather than falling through" means in a
statically typed host.

## Alternatives

- **A trampolined answer type (`answer = Done of value | More of (unit -> answer)`).**
  Rejected for now: OCaml's guaranteed TCO already gives constant stack for the
  shapes the evaluator produces, and a trampoline would add a step to every
  continuation invocation, distorting the §9.2 step metrics for no semantic gain.
- **`LetRec` binding arbitrary expressions.** More general, but it makes reading
  an unfilled cell a reachable state that every later phase must reason about,
  for a generality the surface language does not offer.
- **A single `Scalar of Constant.t` value constructor.** Fewer constructors, but
  it makes `Nil` and the empty list two representations of one value and forces
  every arithmetic primitive to unwrap twice.
- **Mutable frames.** Would make top-level definitions trivial, but AGENTS
  restricts mutation to cells, continuation flags, counters, and emission
  buffers, and a mutable frame captured by a closure would give a second,
  unaudited mutation channel competing with cells.
- **Effect classes deferred to task 0.9.** Rejected: a primitive record without a
  class permits defining a primitive with no policy, which is precisely the
  mistake §D7 exists to prevent.

## Semantic consequences

- A reifier is arity-three by construction; the surface `reifier(e, r, k) -> …`
  form cannot desugar to anything else.
- Cell identity is physical (`Value.same_cell`). Aliasing means shared identity,
  never equal contents, and Phase 7's store discipline inherits that definition.
- `Value.to_string` never follows cell or closure contents, because the value
  graph is cyclic as soon as a recursive function exists. Diagnostics that need
  more detail must walk the graph with their own cycle handling.
- `Core.children` includes a `Quote`'s body: quoted code is program text for
  sizing and provenance. Any caller that means "positions this node evaluates"
  must not use it.

## Test impact

`test/unit/data_model_test.ml` holds one fixture per Core form and one per value
shape, asserts that both enumerations are complete and their names distinct, and
covers `children`, `binders`, `node_count`, provenance marking, the constructor
contracts, the constant bridge in both directions, cell preallocation and
aliasing, one-shot continuation marking, environment frame order, arities, and
the effect-class policy predicates.

## Required spec or measurement changes

None. This record makes §3 precise; it changes no locked decision.
