# 0006 — Core printing and alpha-equivalence

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 0.6
- **Amends:** [ADR 0002](0002-core-constants-and-identifiers.md)

## Context

Every equivalence claim this project will make — the oracle agreeing with the CPS
evaluator, a residual matching its source, depth *k* matching depth 1 — is a
claim up to alpha-equivalence, because binder identities come from a global
counter and two terms that mean the same thing are almost never structurally
equal. Task 0.6 asks for that comparison and for a printer whose output the
reader accepts.

ADR 0002 assumed the printer would want `Ident.Canon` with names preserved. That
turned out to be the wrong tool, which this record corrects.

## Decision

**Alpha-equivalence is decided by walking both terms in step**, under a
correspondence between their bound identifiers: the *n*-th binder introduced on
the left matches the *n*-th on the right, shadowing works because a later binding
replaces the earlier entry, and free identifiers must be equal as identities.
`Alpha.equal` is exact and total, and needs no renaming.

**Canonical renaming is a separate tool with a separate purpose.**
`Alpha.canonicalize` renumbers every bound identifier by first occurrence and
leaves free ones alone, so that `Core.equal_structure` on canonicalized terms
*is* alpha-equivalence. That is what a normalizer (task 6.3) and any report
wanting a stable key need, and it is what "compare through canonical IDs" in the
checklist refers to. `Core.equal_structure` compares identities and ignores
spans, and is documented as explicitly *not* alpha-equivalence.

**Canonical identities occupy a disjoint numbering.** Slot *n* becomes
`-(n + 1)`, while `Ident.fresh` counts upward from 1. Without this, a term with a
free identifier named `v` could see it collide with a renumbered binder — same
name, same number — and structural equality of canonicalized terms would quietly
stop meaning alpha-equivalence. The negative space makes the collision
unrepresentable rather than unlikely.

**The `Keep_names` canonicalization policy is removed.** ADR 0002 predicted the
printer would use it. It cannot: renumbering does not prevent capture, which is
the printer's actual problem. Rather than leave a documented policy with no user,
`Ident.Canon` is now erase-only.

**A printed binder never shadows a visible name.** The printer threads a naming
through the traversal — what each visible identifier prints as, and which names
are taken — and gives a binder its own printed name if that name is free, or that
name with the smallest number appended that is. Names of free identifiers are
seeded before the traversal, so a binder can never capture one. Because the
naming is threaded rather than mutated, leaving a scope restores it and sibling
subterms reuse the same plain names.

This is stronger than capture-avoidance requires: legitimate shadowing is also
renamed, so `(let x … (let x1 …))` appears where the source had two `x`
bindings. That is deliberate. Within any scope, one printed name denotes exactly
one binder, so printed Core can be read back knowing only the free names, and a
human reading a trace never has to work out which `x` is meant.

**Unprintable terms are refused, not approximated.** If two free identifiers
print alike, or a free identifier's name is not a readable atom, `to_string`
raises `Invalid_argument`: no reading scope could distinguish them, so any output
would be a lie. Binder names are renamed anyway, so an unreadable *binder* name
is replaced rather than rejected.

## Alternatives

- **Deciding alpha-equivalence by canonicalizing both terms and comparing.**
  Fewer moving parts, but it depends on each binder identity being bound at most
  once, which Core does not enforce, and it allocates two rewritten terms to
  answer a question about the originals. Canonicalization is kept for the cases
  that genuinely want a rewritten term.
- **De Bruijn indices in Core.** Alpha-equivalence for free, at the cost of
  making `NamedVar`, first-class environments, and every diagnostic worse, and
  forcing the self-interpreter to manipulate the same representation.
- **Printing binders as `name#id`.** Unambiguous and trivial, but the reader
  cannot read it back, and IDs are an excluded observation, so any golden output
  containing one would depend on allocation order.
- **Printing binder names verbatim and allowing shadowing.** Prettier for terms
  the reader produced, but it is only correct when no two visible binders print
  alike, and the specializer will produce terms where they do. A printer that is
  correct for hand-written input and wrong for generated input is the wrong
  default for a project whose output is generated code.
- **Renaming free identifiers to make every term printable.** Free names are the
  term's interface to the outside; renaming them changes what the term means.

## Semantic consequences

- Printed Core round-trips up to alpha-equivalence, never up to equality: the
  reader allocates fresh identities, so `read (print t)` is a different term that
  means the same thing. Nothing may compare printed-and-reread terms with
  `Core.equal_structure`.
- `Core_printer.to_string (Alpha.canonicalize t)` is the stable textual key for a
  term. Alpha-variants produce identical text; terms printed without
  canonicalizing keep the author's names and do not.
- Spans survive canonicalization, so any comparison of canonicalized terms must
  ignore them — which `Core.equal_structure` does.
- `Ident.Canon` slots are now negative. Nothing may assume canonical identities
  are non-negative, and no test may depend on the particular numbers.

## Test impact

`test/unit/alpha_test.ml` covers free-identifier computation for every form
(including the `Let` value being outside its binder's scope, `Set` targets
counting as references, and quoted variables binding normally), alpha-equivalence
positives and negatives across binder names, arities, argument counts, which
parameter is used, free-identifier identity, shadowing built by hand because text
cannot express it, recursive-group correspondence and reordering, quotation,
reifiers, and layout; then canonical renaming: meaning preservation, idempotence,
pairwise agreement with `Alpha.equal` over the corpus, and the free-identifier
collision case that motivated the negative numbering.

`test/unit/printer_test.ml` round-trips every Core form and checks the renaming
discipline directly: shadowing binders, same-name parameters, sibling scopes
reusing names, a binder next to a free name it must not take, recursive groups,
reifiers, unreadable binder names, refusal on unprintable free names, repeatable
output, and identical output for canonicalized alpha-variants.

## Required spec or measurement changes

None.
