# 0005 — The canonical Core s-expression notation

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 0.5

## Context

Core needs a written form long before the surface language exists: the
differential corpus, the self-interpreter's test inputs, and every diagnostic
that shows a term all need one. `to-do.md` calls it "the early debug/test
format, not the user-facing parser". The open questions are what the notation
looks like, and — because Core is hygienic while any notation is written in
printed names — where identities come from when a term is read.

## Decision

**One spelling per form.** Every Core form is written as a parenthesised list
whose head names the form: `(lit 42)`, `(var x)`, `(named-var "x")`,
`(lam (x y) body)`, `(app f arg ...)`, `(let x value body)`,
`(letrec ((f (lam (n) body)) ...) body)`, `(if c t e)`, `(set x value)`,
`(quote core)`, `(reifier (exp env cont) body)`. There are no abbreviations: a
bare `42` is not a literal and a bare `x` is not a variable. Terseness is the
surface language's job (Phase 1); this notation's job is to be unambiguous, so
that a printed term reads back as the same term and a golden file has exactly one
correct content.

**The layer is split in two.** `Sexp` reads and writes data with spans and knows
nothing about Core; `Core_reader` validates shape and arity and resolves names.
That keeps "this is not a well-formed datum" and "this is not a well-formed Core
form" as different diagnostics, and it gives the Phase 0.6 printer a datum type
to build rather than a string to concatenate.

**The reader resolves names to identities.** Each binder allocates a fresh
`Ident.t` and occurrences under it read as that identity. Two reads of the same
text are therefore alpha-equivalent but not equal, which is the correct
relationship: the text names binding structure, not identities. A name with no
binder in scope is an error, because there is no identity to give it; open terms
are read by supplying a `scope`, which is also how globals will be threaded in.

**Quoted code is read in the enclosing scope.** A `(quote (var x))` under
`(lam (x) …)` carries that lambda's binder ID, per §D1: splicing it under an
unrelated binder of the same name cannot capture it. `(named-var "x")` is the
deliberate exception and stays a string.

**One binder list may not bind a printed name twice.** `(lam (x x) …)` is
rejected with `Duplicate_binder` rather than resolving to whichever `x` was
entered last. The reader has only names to work with, so accepting it would make
resolution depend on entry order, and it would build exactly the frame that
ADR 0004 says `lookup_by_name` cannot resolve.

**`;` starts a comment, not `#`.** The surface language uses `#` (spec §4.1), but
this notation needs `#t` and `#f`, so the two cannot coexist. The notations are
separate and stay separate.

## Alternatives

- **Terse notation** — bare atoms as variables, bare numbers as literals,
  `(fn (x) e)` style. Shorter to write, but it makes "one spelling per term"
  false, which weakens every round-trip and golden test, and it invites the debug
  notation to drift toward being a second surface syntax.
- **Reading straight from text to Core with no datum layer.** Fewer moving parts,
  but lexical and structural errors become one undifferentiated category, and the
  printer would have nothing to build but strings.
- **Allocating a fresh identity for every free name.** Would let any text be read,
  but silently turns a typo into a new global and makes two occurrences of the
  same free name different variables. An explicit scope is the honest version.
- **Reading quoted code in an empty scope.** Simpler, but it contradicts §D1:
  quoted variables must carry the binder ID of the binding they were written
  under, which is what makes hygiene intrinsic rather than a discipline.
- **Letting a duplicate binder shadow within one list.** Matches some Lisps, but
  it makes the meaning depend on entry order and produces frames whose name
  lookups are unresolvable.

## Semantic consequences

- `Core_reader.read` is not idempotent on identities and must never be used to
  test structural equality of terms across reads. Comparison across reads is
  alpha-equivalence, which is task 0.6.
- Because every binder allocates, reading a large corpus advances the gensym
  counter. That remains an excluded observation; nothing may depend on the
  numbers.
- `Error` gained six syntactic causes (`Unexpected_character`, `Unterminated`,
  `Unexpected`, `Unknown_form`, `Malformed_form`, `Duplicate_binder`) and the
  structural comparisons `cause_equal` and `equal`. Adding them broke every
  exhaustive match over causes, which is the intended cost: each reporter had to
  decide how to present the new failures.

## Test impact

`test/unit/reader_test.ml` covers the datum round trip for every canonical form
and every datum shape, comment and newline handling, span accuracy including
across lines, reading each of the eleven forms, binder resolution (own binder,
shadowing, two reads allocating different identities, quoted variables keeping
their enclosing binder, mutual recursion in a group, supplied scopes, `set`
targeting an existing binding), span survival into Core, and eighteen malformed
inputs each checked for both its structured cause and its exact rendered
location.

## Required spec or measurement changes

None. The spec does not fix a Core notation; this record establishes one and
scopes it to debugging and testing.
