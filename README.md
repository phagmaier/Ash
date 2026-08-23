# Ash

Ash is a small hygienic language with a CPS self-interpreter, a lazily
materialized reflective tower, and a staged partial evaluator that explains where
interpreter behavior can and cannot be erased.

The detailed design is in [`Ash Reflective Tower.md`](Ash%20Reflective%20Tower.md),
and the ordered implementation plan is in [`to-do.md`](to-do.md).

## Requirements

- OCaml 5.2 or newer
- Dune 3.16 or newer
- opam is recommended for managing the toolchain

The currently verified development environment uses OCaml 5.4.1 and Dune 3.24.2.

## Build and test

Run commands inside the active opam switch:

```sh
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune exec ash -- --help
```

The CLI is only a bootstrap shell at present. Follow the first unchecked task in
`to-do.md` to continue implementation.

## Repository layout

| Path | Contents |
|------|----------|
| `bin/` | CLI entry point |
| `lib/core/` | `ash.core`: spans, constants, hygienic identifiers, the Core AST, values, environments, and errors |
| `lib/syntax/` | `ash.syntax`: s-expression data, and the canonical Core reader and printer |
| `lib/` | `ash`: version metadata, and later the layers above Core |
| `test/unit/` | module-level behaviour tests |
| `docs/decisions/` | numbered architecture decision records |
| `docs/progress/` | experiment and reproducibility notes |

Lower layers never import higher ones: `ash.core` knows nothing about the tower,
staging, or classification.

## Core identity model

Ash identifiers are hygienic by construction. `Ash_core.Ident.t` pairs a printed
name with a unique ID, so `fn(x) -> x` and an unrelated `x` are different terms
even though they print alike, and only `Ident.fresh` (and its derivatives) can
allocate one. The ID counter is an excluded observation: never compare terms by
raw IDs, canonicalize them with `Ident.Canon` first. `Erase_names` (the default)
renumbers and erases printed names, so alpha-renamed terms become structurally
equal; `Keep_names` renumbers but keeps names for readable printing. Register any
identifier that is free in the compared term with `Canon.fix` before traversal.

`Ash_core.Span` carries locations through surface syntax, Core, residual
provenance, and errors. A node invented by a later phase is not location-less: it
keeps the positions of the source it came from and adds a `Generated` marker
naming the phase, so `Span.source_span` still points diagnostics at user text
while `Span.generators` explains where the node came from.

See [`docs/decisions/0002-core-constants-and-identifiers.md`](docs/decisions/0002-core-constants-and-identifiers.md)
for the numeric domain and alpha-equivalence rationale.

## Core and values

`Ash_core.Core` is the eleven-form Core language — `Lit`, `Var`, `NamedVar`,
`Lam`, `App`, `Let`, `LetRec`, `If`, `Set`, `Quote`, `Reifier` — with a span on
every node. `NamedVar` is a distinct form rather than a `Var` with a null ID,
because a name resolved against an environment that is not statically known is a
specialization barrier the collapse report has to count. `LetRec` is a Core form
and binds lambdas in the type, so the preallocate-then-fill implementation cannot
observe an unfilled cell.

`Ash_core.Value` is the runtime domain: scalars, immutable lists, closures,
reifiers, one-shot continuations, first-class environments, cells, `Code`, and
primitives. `Code` lives in the same domain as everything else, which is what
makes the collapser online — a static value is a real value, a dynamic value is
`Code`. Cells are the only mutable part and can only be mutated through
`Value.fill_cell`; environments and frames are immutable. Primitives are CPS and
carry an `Ash_core.Effect_class`, so no primitive can exist without a staging
policy.

No match over a Core form or value shape in this project uses a catch-all case:
adding a variant is meant to be a compile error at every site that interprets
one. See
[`docs/decisions/0003-core-and-value-representation.md`](docs/decisions/0003-core-and-value-representation.md).

## Environments and errors

`Ash_core.Env` operates on the frame chains in `Value`: `lookup`, `state`,
`lookup_by_name`, `bind`, `extend`, `preallocate`, and `assign`. Frames are
immutable and searched innermost first, so shadowing is frame order; values are
reached through cells, so an assignment is visible to every closure that already
captured the binding. `Env.state` distinguishes unbound from bound-but-unfilled,
which `LetRec` preallocation needs. Assignment never creates a binding.

A single frame that binds two distinct identifiers printing alike makes a
`NamedVar` lookup ambiguous, and Ash reports that rather than picking one:
resolving by allocation order would make the gensym counter observable, and that
channel is explicitly excluded from Ash's equivalence claims.

`Ash_core.Error` carries the phase, span, tower level, and a structured cause,
and is formatted only at the boundary. Rendered diagnostics print identifiers by
printed name and never by unique ID, so golden output cannot depend on allocation
order; `Error.to_string_debug` adds IDs for interactive use only. See
[`docs/decisions/0004-environments-and-structured-errors.md`](docs/decisions/0004-environments-and-structured-errors.md).

## Writing Core down

`Ash_syntax.Core_reader` reads the canonical Core notation — a debug and test
format, not the Ash surface syntax, which is Phase 1. Every form has exactly one
spelling:

```text
(lit 42)  (lit #t)  (lit "s")  (lit 'sym)  (lit unit)  (lit nil)
(var x)
(named-var "x")
(lam (x y) body)
(app f arg ...)
(let x value body)
(letrec ((f (lam (n) body)) ...) body)
(if condition consequent alternative)
(set x value)
(quote core)
(reifier (exp env cont) body)
```

The notation is written in printed names, but Core is hygienic, so the reader
resolves names to identities: each binder allocates a fresh identifier and
occurrences under it read as that identifier. Two reads of the same text are
alpha-equivalent, not equal. A name with no binder in scope is an error — pass a
`scope` to read open terms. Quoted code is read in the enclosing scope, so a
quoted variable keeps the binder ID of the binding it was written under, and one
binder list may not bind a printed name twice. Comments start with `;`, since
`#t` and `#f` need the hash. See
[`docs/decisions/0005-canonical-core-notation.md`](docs/decisions/0005-canonical-core-notation.md).

`Ash_syntax.Core_printer` prints that notation back. Because several binders can
print alike, it renames as it goes, and further than capture-avoidance strictly
requires: **a printed binder never shadows a name already visible**, so within
any scope one printed name denotes exactly one binder. A term whose *free*
identifiers print alike has no faithful written form and is refused rather than
printed misleadingly.

## Comparing terms

Binder identities come from a global counter, so terms that mean the same thing
are almost never structurally equal. Every equivalence claim Ash makes is up to
alpha-equivalence, and `Ash_core.Alpha` is where that lives:

- `Alpha.equal` decides alpha-equivalence directly, walking both terms in step.
  It is the comparison to reach for by default.
- `Alpha.canonicalize` rewrites a term so that `Core.equal_structure` on
  canonicalized terms *is* alpha-equivalence — for normalizers and for report
  keys. Canonical identities are numbered negatively so they can never collide
  with an allocated one.
- `Core.equal_structure` is plain structural equality ignoring spans. It is
  deliberately *not* alpha-equivalence.

`read (print t)` is alpha-equivalent to `t`, never equal to it: reading allocates
fresh identities. `Core_printer.to_string (Alpha.canonicalize t)` is the stable
textual key for a term. See
[`docs/decisions/0006-core-printing-and-alpha-equivalence.md`](docs/decisions/0006-core-printing-and-alpha-equivalence.md).

## Development workflow

Read `AGENTS.md` before changing code. At the end of each completed task, update
the checklist's Current state and Handoff log so a later session can resume from
the single prompt `continue`.
