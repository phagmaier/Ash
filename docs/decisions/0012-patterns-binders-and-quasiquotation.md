# 0012 — Patterns, binder consistency, and quasiquotation

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 1.3

## Context

Spec §4.2–§4.4 requires ordinary list matching, alternatives, patterns over all
eleven Core forms, and quasiquote patterns whose `${...}` holes bind pieces of
code. The checklist additionally requires inconsistent alternatives to be
rejected. That matters before desugaring: an alternative has one clause body, so
every successful arm must provide that body with the same lexical bindings.

The original constructor illustration put all eleven differently-binding Core
patterns in one alternative before one arrow. That conflicts with the binder
rule and cannot give the shared body a coherent scope. This decision corrects
the illustration to use separate clauses.

Quasiquote patterns also force expression quotation into the parser earlier than
its Phase 3 semantics. The same token `${` means an evaluated expression hole in
an expression quotation and a pattern-binding hole in a quasiquote pattern; an
untyped placeholder would lose that distinction precisely where hygiene will
later need it.

## Decision

**Patterns are source-located nodes mutually recursive with surface
expressions.** The pattern forms are wildcard, literal, variable, list, cons,
alternative, Core constructor, quasiquote, and parenthesized group. Match nodes
contain a scrutinee and non-empty located clauses. Names remain located strings;
as in ADR 0011, hygienic IDs are allocated only by the desugarer.

**Pattern precedence has two rows.** Alternative `|` is loosest and associates
into a flat list. Cons `::` is tighter and right-associative, matching expression
cons. Parentheses group a pattern. Lists and Core constructor arguments are
comma-separated and reject trailing commas, consistently with expression lists
and calls.

**Every single match path binds a name at most once.** `x :: x`, `[x, x]`,
`App(x, x)`, and repeated quasiquote holes such as `` `{ ${x} + ${x} } `` are
parse errors at the repeated binder. Repeated names in separate alternative
arms are not duplicates because only one arm runs.

**Every arm of an alternative binds the same name set.** Sets are compared after
sorting so allocation and traversal order cannot enter a diagnostic. Source
order is retained on the AST for the later hygienic binding pass. `[x] | x :: []`
is valid; `x | y` and `x | _` are rejected with a structured
`Inconsistent_pattern_binders` cause.

**Core constructor patterns form a closed, arity-checked vocabulary.** They are
exactly `Lit/1`, `Var/1`, `NamedVar/1`, `Lam/2`, `App/2`, `Let/3`, `LetRec/2`,
`If/3`, `Set/2`, `Quote/1`, and `Reifier/2`, following the surface shapes in
spec §4.4. A call-shaped name outside that table is an unknown Core form, and a
known name with the wrong argument count is malformed syntax. This prevents a
misspelling from silently becoming a pattern form the matcher cannot implement.

**Splices carry their syntactic role.** A `Surface.Splice` contains either an
`Expression_splice` or a `Pattern_splice`. While parsing an expression quote,
`${...}` contains an expression. While parsing a quasiquote pattern it contains
a full pattern, so binder collection and consistency checking use the same rules
as every other pattern. Splice syntax outside a quotation is rejected. This task
parses `Quote` and `Splice` nodes but assigns them no dynamic meaning; hygiene,
closed-code checks, and execution remain Phase 3 work.

**Match clauses use the statement-layout rule.** A newline or `;` after a clause
body begins the next pattern, and `}` closes the match. A match must have at
least one clause. A leading `|` continues an alternative pattern before its
arrow; it is not a separate clause marker.

## Alternatives

**Bind the union of alternative names and fill missing bindings.** There is no
honest value for a missing binder, and adding one would enlarge the value domain
only to make an ill-scoped pattern run. Rejecting the clause is local and keeps
the body statically meaningful.

**Treat repeated binders as equality constraints.** This silently adds nonlinear
pattern semantics and would require an equality policy for closures, cells,
environments, continuations, and code. Explicit guards can express equality
later without changing what binding means.

**Represent every splice as an expression.** A quasiquote pattern hole would
then need to be reinterpreted after parsing, losing the located pattern tree and
delaying duplicate/inconsistent-binder errors. The tagged splice representation
makes the distinction explicit now.

**Accept arbitrary constructor names and defer validation.** That would turn
typos into matcher failures and prevent exhaustive handling of the closed Core
language. The constructor set is already fixed, so parsing can validate it.

## Consequences

- `Parser.pattern` is a focused entry point for tests and tools; match parsing
  uses the same implementation.
- `Surface.pattern_binders` reports unique source-order binders for
  parser-produced patterns. An alternative uses its first arm's order after all
  arms have been checked for the same set.
- `Surface_printer` distinguishes `(splice ...)` from `(pattern-splice ...)`, so
  the golden output exposes context loss immediately.
- The spec's constructor example now uses eleven clauses. This is a clarification
  of the already-required binder invariant, not a change to Core semantics.

## Test impact

`test/unit/parser_test.ml` covers every pattern form, both pattern precedence
rows, binder extraction, duplicate and inconsistent binders, all Core
constructors and their arities, quotation context, pattern spans, and the exact
documented `length` and `simplify` programs.

`test/golden/parser.expected` prints both acceptance programs, all constructor
patterns, representative standalone patterns, expression versus pattern
splices, and the structured diagnostics for each rejected binder or constructor
case.

