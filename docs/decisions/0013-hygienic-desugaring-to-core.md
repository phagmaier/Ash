# 0013 — Hygienic desugaring to Core

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 1.4

## Context

Spec §3 fixes eleven Core forms and lists the derived sugar in one table:
sequencing is `Let`, `and`/`or` are `If`, and lists, arithmetic, and IO are
primitives. Spec §4 gives the surface language that has to reach them. The
parser (ADR 0011, ADR 0012) deliberately stops at a source-located tree in
printed names, so this task owns the whole distance from strings to identities.

Three things had to be settled before any lowering could be written. Surface
names have to resolve to something, and Core offers two nodes for that: `Var`,
which carries a binder identity, and `NamedVar`, which resolves a string against
a first-class environment at run time and is a specialization barrier the
collapse report counts. Operators and list literals have no Core form of their
own and must become calls of primitives that live in the runtime library, which
the syntax library cannot depend on. And `match` has to become `If` over
primitive tests, including a way to fail when no clause matches, which Core
cannot express at all.

## Decision

**One identity per binder, allocated here.** The desugarer walks binding
structure once, calls `Ident.fresh` for every binder, and resolves each
occurrence through a scope. Hygiene is therefore not a later repair: a binder the
desugarer invents and a user binder that print alike are already different
identities, so `match` can bind `head` and `scrutinee` next to a user's `head`
without either seeing the other.

**Free names are a desugar error, never `NamedVar`.** `NamedVar` means "resolved
by printed name at run time", which is a property of reflective code, not a
fallback for a name the compiler could not find. Emitting one for every unbound
name would silently move a diagnosable error to run time and would inflate the
count of surviving name lookups the collapse report exists to measure.

**Globals are a parameter, and generated code resolves against them directly.**
`Desugar.scope_of_globals` takes the `(name, identity)` pairs the caller's
registry produced, so `ash.syntax` still does not depend on `ash.runtime` and a
materialized tower level can lower under its own cloned globals. A generated call
— an operator, a list literal, a match test — looks its primitive up in the
globals rather than in the lexical scope. A program that writes `fn length(xs)`
therefore gets its own `length` everywhere it wrote one and the primitive
`empty?`, `head`, and `tail` in the code the desugarer wrote, which is the
documented §4.2 program. `Desugar.required_primitives` names every primitive the
desugarer can emit so a registry and this module cannot drift apart unnoticed.

**Adjacent `fn` declarations form one `LetRec` group.** Mutual recursion is
written by writing it; any other rule would make the self-interpreter's
`eval`/`apply`/`eval-list` group need syntax that does not exist. A binding or
expression between two `fn`s ends the group, so scoping stays textual.

**A statement list ending in a definition evaluates to unit.** A file of
definitions is a legal program, and unit is what the spec already gives an
expression evaluated for effect. Rejecting it would make the obvious shape of a
library file a syntax error.

**`var` versus `let` is decided here or nowhere.** Every Core binding is a cell,
so nothing downstream can tell an assignable binding from a fixed one. The scope
records which binder came from `var`, and `:=` on anything else — including a
global — is `Error.Immutable_binding` at desugar time.

**`match` lowers to `If` over `empty?`, `head`, `tail`, and `==`, with thunked
failure.** Each clause's failure continuation is a nullary lambda holding the
clauses after it, so a pattern may mention failure several times without copying
the remaining clauses per mention; the same shape handles alternative arms. A
clause whose pattern contains an alternative binds its body as a function of the
clause's binders and each arm calls it, because the arms share one body. The
scrutinee is bound once, so it is evaluated once whatever the patterns do.

**Match failure is a primitive, `match_error`, classified pure.** Core has no way
to raise, and a match that runs out of clauses must not quietly answer unit. Pure
is the judgement division by zero already has: the result depends on nothing but
the argument, so a specializer that folds it reports at specialization time a
failure the program would certainly have reached. Its cause is
`Error.No_matching_clause`, carrying the printed scrutinee.

**`x |> f(a)` is `f(x, a)`; `x |> f` is `f(x)`.** Ash has multi-argument lambdas
and no currying, so threading into the first argument of a written call is the
rule that makes `xs |> map(double)` mean anything. A parenthesized right operand
is not a written call, so `x |> (f(a))` applies the result of `f(a)` to `x` —
that is how the other reading is asked for.

**Provenance follows shape correspondence.** A Core node produced by a surface
node of the same shape keeps that node's span unchanged: `let`, `:=`, `if`,
`fn(x) ->`, and calls are written, not invented. Everything else is marked
generated with the rewrite that made it — `desugar/seq`, `desugar/unit`,
`desugar/fn`, `desugar/operator`, `desugar/negate`, `desugar/pipe`,
`desugar/and`, `desugar/or`, `desugar/list`, `desugar/match` — keeping the
positions of the surface it came from, so a diagnostic still points at user text.

**Quotation, splicing, Core constructor patterns, and quasiquote patterns do not
lower.** They parse, and they are refused with `Error.Unsupported` naming what is
missing. Their meaning is hygienic code construction and destructuring of `Code`
values, which needs the Phase 3 quotation rules (3.1) and reflection-class
primitives that ADR 0009 deliberately left unregistered. Lowering them now would
mean inventing a code representation this phase would have to replace.

## Alternatives

**Resolve free names to `NamedVar`.** It would make every program run without a
scope, at the cost of turning a compile-time error into a run-time one and
polluting the measurement the whole project exists to produce.

**Let the desugarer import the primitive registry.** Simpler to call, but it
inverts the layering (`syntax` below `runtime`) and hardcodes one global
environment, which task 4.1 explicitly cannot have: each materialized level owns
cloned globals with their own identities.

**Compile `match` by duplicating the remaining clauses into each failure
position.** No thunks and slightly smaller output for one-clause matches, but the
size is exponential in nested refutable patterns, and the duplicated code would
appear in every later size metric.

**Answer unit when no clause matches.** It avoids a new primitive and silently
produces wrong answers. Adding a primitive whose class is stated is the same
discipline every other primitive already follows.

**Desugar `a || b` to `Let t = a in If t t b` so it answers `a`'s value.** Core's
`If` requires a boolean and Ash has no truthiness, so the extra binding would buy
nothing but a different way to fail the same type check.

**Make `let`-bound names assignable.** Cells make it possible, which is exactly
why the restriction has to be a decision rather than an accident. `var` exists in
the surface syntax; if it means nothing, it should not be in the grammar.

## Consequences

- `Ash_syntax.Desugar` is the only place identities are allocated for surface
  programs, and the only place that decides mutability.
- `Error.Immutable_binding` and `Error.No_matching_clause` are new structured
  causes; every exhaustive match over causes was updated with them.
- `match_error` joins the pure class, so the registry is 25 primitives. The
  classification, type-expectation, and arity tables in `primitives_test` cover
  it, with a new `Always_fails` expectation for a primitive whose job is to fail.
- Constructor and quasiquote patterns now fail at two different phases depending
  on the mistake: an unknown or misarranged constructor is still a parse error,
  while a well-formed one is a desugar-time `Unsupported`. Task 3.1 removes the
  second.
- Generated-node markers are already what the collapse report will need to tell
  written code from emitted code; nothing later has to reconstruct them.

## Test impact

`test/unit/desugar_test.ml` covers the lowering of every construct in the sugar
table against expected Core up to alpha-equivalence, hygiene under shadowing and
against generated binders, provenance markers and preserved positions,
first-match and evaluate-once behaviour of `match`, and every desugar-time
diagnostic. Its end-to-end section parses, lowers, and runs `fact`, the
documented `length`, pipelines, shadowing, `set` through a closure, blocks,
short-circuiting, and the documented `classify`.

`test/golden/desugar.expected` pins the Core for the sugar table, the documented
§4.1 and §4.2 programs, mutual recursion, alternative patterns, closure-visible
mutation, the provenance table, and each diagnostic.
