# 0004 — Environment operations and structured errors

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 0.4

## Context

`Ash Reflective Tower.md` §3 gives the environment representation —
`Env = List<Frame>`, `Frame = Map<Ident, Cell>` — and §D1 introduces `NamedVar`,
which resolves a printed name against a first-class environment at evaluation
time. It does not say what a name lookup does when one frame binds two distinct
identifiers that print alike, nor what an error carries. Task 0.4 requires source
locations in unbound-name errors, and AGENTS requires errors carrying phase,
span, tower level, and cause, formatted only at the CLI boundary.

## Decision

**A name bound twice in one frame is an error, not a choice.**
`Env.lookup_by_name` searches frames innermost first. Within the innermost frame
that mentions the name, one match is returned, and two or more yield
`Name_ambiguous` — reported as `Error.Ambiguous_name`. The obvious alternative,
letting the most recently allocated binder win, would make the gensym counter
semantically observable, and D9 lists gensym-counter observation among the
channels explicitly excluded from observational equivalence. An excluded channel
that decides which value a program reads is not excluded at all.

Ordinary code cannot reach this: surface syntax cannot bind one name twice in a
single frame, and each `Let`, application, and recursive group pushes its own
frame, so ordinary shadowing is frame order. Only reflective or specializer-built
frames can produce it, and those get a clear diagnostic rather than an arbitrary
answer.

**Binding state is a three-way answer.** `Env.state` returns `Unbound`,
`Unfilled`, or `Bound v`. A `value option` would conflate "no such binding" with
"preallocated `LetRec` cell not yet filled", and those need different
diagnostics. `Env.read_exn` raises `Unbound_ident` or `Unfilled_binding`
accordingly.

**Assignment never creates a binding.** `Env.assign` fills the cell an identifier
is already bound to and reports failure otherwise. This makes `Set`, filling a
recursive binding, and a meta-level write the same operation on the same cell,
which is what makes mutation visible to closures that already captured the
binding.

**One frame per extension.** `bind`, `extend`, and `preallocate` each push
exactly one frame, so a binding can never overwrite a sibling in an enclosing
frame. `Value.frame_of_list` rejects a repeated binder identity outright rather
than silently keeping the last one; repeated printed names remain legal, since
that is the point of hygienic identity.

**Errors are structured and raised as an exception.** `Error.t` carries
`phase`, `span`, `level : int option`, and a `cause` variant, and `Ash_error`
carries it. Errors propagate as an OCaml exception rather than through the CPS
answer type: `answer = value` stays the type of a *successful* computation
(ADR 0003), and continuations invoked in tail position do not have to thread an
error channel they never inspect. `level` is relative to the base program per D9
and is `None` for phases that belong to no level, such as reading and parsing.

**Rendering never prints unique IDs.** `Error.to_string` prints identifiers by
printed name, so two distinct binders that print alike render identically. IDs
appear only in `Error.to_string_debug`, which golden output must not use. Spans
carry generated provenance into diagnostics, so an error on emitted code names
the phase that emitted it.

## Alternatives

- **Most-recently-allocated binder wins for name lookup.** Simple and total, but
  it promotes the gensym counter to a semantic channel and breaks D9's exclusion
  list, which the Phase 6 depth-invariance claim relies on.
- **Innermost-frame name shadowing resolved by insertion order.** Requires
  ordered frames rather than `Ident.Map`, contradicting §3, and still makes the
  answer depend on construction order rather than on lexical structure.
- **Errors in the answer type (`answer = (value, error) result`).** More
  principled in isolation, but it adds a match to every continuation invocation
  on the hot path and distorts the §9.2 step metrics, for a channel no
  continuation examines. If Phase 4's `meta_error` turns out to need errors as
  ordinary values at level *n+1*, that is a level-crossing mechanism, not a
  change to the ground answer type — and it gets its own record.
- **A generic `Message of string` cause.** Rejected: it is the escape hatch that
  turns structured errors back into strings, and every phase that "just needs one
  more case" is exactly the phase that should extend the `cause` variant.

## Semantic consequences

- `NamedVar` resolution is total on well-formed frames and reports ambiguity
  otherwise. The collapse report can count both surviving name lookups and
  ambiguities as reflection residue.
- Because assignment never binds, a `Set` to an unbound identifier is an error
  rather than a top-level definition. Top-level definition is a separate
  mechanism the driver owns.
- Adding an `Error.phase` or `Error.cause` breaks every exhaustive match over
  them, which is intended: a new failure mode should force every reporter to
  decide how to present it.

## Test impact

`test/unit/env_test.ml` covers shadowing by identity across frames,
closure-visible mutation through shared cells (and the fact that rebinding is
*not* visible), recursive preallocation with its unfilled-read error, name lookup
including innermost-frame resolution and the ambiguity case, and the failure
behaviour of every `_exn` operation. `test/unit/error_test.ml` covers every phase
and cause, level rendering, generated-provenance rendering, and the guarantee
that same-name binders render identically while the debug form separates them.

## Required spec or measurement changes

None. This record settles a case §D1 left open and fixes the error contract
AGENTS requires.
