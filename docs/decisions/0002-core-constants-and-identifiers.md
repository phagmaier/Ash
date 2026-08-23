# 0002 — Core constants, spans, and the hygienic identifier representation

- **Status:** accepted; the canonicalization section is amended by
  [ADR 0006](0006-core-printing-and-alpha-equivalence.md)
- **Date:** 2026-08-23
- **Task:** 0.2

## Context

`Ash Reflective Tower.md` §D1 fixes identifiers as `{ printed, id }` and §3 fixes
the literal domain as `number | bool | string | symbol | unit | []`. Neither
pins down the numeric tower, how fresh IDs are allocated, how alpha-equivalence
is decided, or how a generated node records where it came from. Those four
choices are load-bearing for the Phase 6 depth-invariance claim, so they are
settled here before Core exists rather than discovered while writing the
specializer.

## Decision

**Numbers are exact machine-word integers; there is no floating point.**
`Constant.Num of int` is the whole numeric domain. `fact(20) = 2432902008176640000`
fits in OCaml's 63-bit native `int`, so the Phase 0 acceptance corpus is exact.

**Identifiers are a private record with one process-wide counter.**
`Ident.t = private { name : string; id : int }` can only be built by `Ident.fresh`,
`Ident.derive`, `Ident.derive_as`, or `Ident.Canon`. `equal` and `compare` are ID
first; `name` exists for humans and diagnostics only. The counter is an `Atomic`
so a future multi-domain driver cannot hand out a duplicate ID, and it starts at
1 so a canonical identifier (numbered from 0) is never confused with the first
allocated one during debugging.

**Alpha-equivalence is renumbering by first occurrence, with explicit fixing of
free identifiers.** `Ident.Canon` assigns canonical slots in traversal order and
replaces every printed name with the positional `v`, so alpha-renamed terms
become structurally equal. Identifiers that are *free* in the term under
comparison must be registered with `Canon.fix` before traversal — a free `x#4`
and a free `y#9` denote different variables and must not both land in slot 0.
Binding-aware traversal is the Core layer's job (task 0.6); this module only
supplies the renumbering.

> **Amended by ADR 0006.** This record originally also offered a `Keep_names`
> policy, on the expectation that the Phase 0.6 printer would want renumbering
> with names preserved. It does not — a printer must rename to *avoid capture*,
> which renumbering does not do — so the policy was removed unused. ADR 0006 also
> moves canonical identities into a disjoint negative numbering, closing a
> collision this record did not consider.

**Generated nodes keep the span they came from plus a marker.**
`Span.origin` is either `Source` or `Generated { by; from }`, where `from` is
itself a span and may be generated again. A generated span inherits the positions
of its origin, so a diagnostic always points at real user text, while
`Span.generators` reports the chain of phases outermost first and
`Span.source_span` recovers the human-written region. Span equality includes
provenance, and spans are metadata: semantic comparison of Core must never use
them.

## Alternatives

- **Arbitrary-precision or dual int/float numbers.** Rejected for now: floats make
  differential comparison between oracle, CPS, tower, and residual runs depend on
  rounding and printing, and bignums add a dependency (ADR 0001 prefers the
  standard library) for no Phase 0–5 benefit. Adding a numeric shape later is a
  Core change requiring a superseding decision record and re-measurement.
- **Strings plus a renaming discipline.** Rejected by §D1: it makes hygiene a
  convention, and a free-variable check at `run` catches unbound, never captured.
- **De Bruijn indices in Core.** They give alpha-equivalence for free but make the
  reflective tower's `NamedVar`, first-class environments, and printed diagnostics
  much worse, and the self-interpreter must manipulate the same representation.
  Canonicalization on demand keeps names where reflection needs them.
- **Span-less generated nodes.** Rejected: the collapse report has to attribute
  residual code to source, and a `None` location degrades every downstream error.

## Semantic consequences

- Integer overflow wraps as OCaml `int` arithmetic does. Once arithmetic
  primitives exist (task 0.9) they inherit that, and both the oracle and the CPS
  evaluator must agree on it; a later decision to trap or promote must change both
  and be recorded.
- Structural equality on Core is *not* alpha-equivalence; alpha-equivalence is
  structural equality *after* canonicalization. Every test that compares terms
  must say which one it means.
- The gensym counter remains an excluded observation (AGENTS invariant 10): no
  semantics and no test may depend on the numbers it hands out. `Ident.Canon` is
  the supported way to compare, and there is deliberately no counter reset.

## Test impact

`test/unit/core_test.ml` covers span joining, provenance chains and rendering,
every constant shape with its cross-shape distinctions and total order, same-name
distinct binders in sets and maps, and canonicalization: alpha-renamed samples
collapse, shadowing survives, results are independent of allocation order, and
fixed free identifiers are neither renumbered nor counted.

## Required spec or measurement changes

None. This record fills in detail the spec left open; it changes no locked
decision.
