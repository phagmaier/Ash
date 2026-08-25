# 0033 — The residual normalizer

Status: accepted. Task 6.3. Spec §8's Phase 6 ("after let-flattening
normalization"), traps list ("Comparing residuals without normalizing → the
invariance claim is vacuous").

## Context

Phase 6's completion claim compares residuals across tower depths:
`collapse(n, p) ≅α collapse(1, p)`. Two raw residuals of the same program are
never structurally equal — every specialization run allocates fresh binder
identities — and even an alpha-insensitive comparison would still be comparing
the emitter's administrative let-nesting rather than the program. A claim about
depth invariance needs one canonical shape to compare in, and the spec already
names it: let-flattening normalization.

The normalizer is also the piece a sloppy version could most easily break. It
runs on residual programs, which contain effects (observable output now, store
operations from Phase 7 on), so "flatten" must never mean "reorder", "hoist",
or "drop".

## Decision

`Ash_collapse.Normalize.normalize` is one function with three rewrites, applied
bottom-up, then canonical renaming:

1. **Administrative-let flattening.** `let x = (let y = ey in ex) in b`
   becomes `let y = ey in let x = ex in b`, however deep the nesting. This is
   pure rearrangement: `ey` was already evaluated before `ex`, neither mentions
   `x`, and no binding moves across a lambda, an `If` branch, or a `LetRec`
   group — ADR 0031's placement rule survives untouched.
2. **Trivial-binding elimination.** `let x = v in b` with `v` a literal or an
   *unassigned* variable substitutes `v` for `x`; if `b` does not mention `x`
   at all, the binding goes away. Nothing else is ever substituted, so no code
   is duplicated and no work is reordered.
3. **Alpha-canonicalization** (`Alpha.canonicalize`) runs last, so two terms
   that differ only by the identities some run allocated become structurally
   equal.

### The blocked cases

Substitution may only remove a binding whose references are all ordinary
variable occurrences. Three kinds of mention cannot follow one, and keep the
whole binding instead:

- **A `Set` target.** Assignment reads the binding to find its cell; rewriting
  or removing it would write somewhere else, or nowhere.
- **Anything inside a `Quote` body.** Quoted code is data the program computes
  with; rewriting it changes what the program means.
- **Anything inside a `Reifier` body.** Another level's code; same reasoning.

This is why elimination has its own occurrence classifier rather than reusing
`Alpha.free_idents`: the distinction needed is not free-vs-bound but
*rewritable-vs-not*, and `free_idents` deliberately treats quotes as
transparent.

The mirror-image guard is about the *value*, not the mentions. Substituting a
variable trades one read at the binding site for a read at each use, and the
two disagree exactly when a write lands in between: `let x = y in (set y 6); x`
captured `y`'s old value, and a substituted body would see the new one. So a
variable value is substitutable only when nothing in the term assigns it. The
write set is collected over the whole term rather than over the binding's body,
because a closure built under the binding can outlive it and be called after a
write made anywhere else — and over `Quote`/`Reifier` bodies too, which are
code that may yet run. Literals need no guard; nothing can assign one.

### What the term is assumed to be

A term that can run: every identity free in it is bound in the environment it
runs against. Every residual is (a staged answer is closed over its level's
globals, and `Code.unresolved_dependencies` is what rejects one that is not).
This is what makes a variable read effect-free, and therefore movable to the
use site or droppable with an unused binding. On a term carrying a genuinely
unbound variable in value position the rewrite would move or erase the failure
that read raises, so such a term is out of scope rather than silently
mishandled.

### What normalization does not do

- No dead-code elimination beyond trivial bindings: an unused *effectful*
  binding stays exactly where it was.
- No hoisting out of conditionals or lambdas, in either direction.
- No merging of duplicate residual functions. The same key met in two branches
  of a dynamic conditional still produces two residual functions (recorded as a
  known issue since task 6.1); that is correct, and deduplicating it is not
  required by any acceptance criterion.
- No change inside `Quote`/`Reifier` bodies. Canonical renaming follows
  enclosing binders into quotations — that is what alpha-equivalence means for
  a quoted variable — but introduces nothing and removes nothing.

### Idempotence

By construction: after the rewrite no `Let` has a trivial or let-shaped value,
renaming such a term neither reintroduces one nor changes structure, and
canonicalization is idempotent. So `normalize ∘ normalize = normalize` holds as
exact structural equality, which is what lets 6.4 compare normal forms without
caring which side was normalized twice.

### Where it applies

`Metrics.measure` normalizes the staged residual before the residue survey and
the residual run. The measurement therefore describes the deliverable — the
canonical shape every comparison uses — rather than the emitter's raw output.

## Alternatives

**Normalize only inside the depth-comparison test.** Rejected: the report would
then describe a different term than the one every equivalence claim is made
about, and two notions of "the residual" would coexist.

**Full A-normal-form conversion.** Rejected: it rebuilds every node, moves
bindings between positions the specializer chose deliberately, and buys nothing
for the comparison that flattening plus trivial elimination does not.

**Substitution guarded by capture-avoiding renaming.** Rejected as unnecessary
machinery: intrinsic hygiene (AGENTS invariant 1) means identifiers are unique,
so no binder below can shadow the one being substituted. The guard that *is*
needed is the occurrence classifier above, which is about data and set targets,
not capture.

## Semantic consequences

- Normalization preserves semantics for the terms it is defined on (above):
  value, failure cause and location, and observable trace are unchanged. This
  is asserted over programs with output, failures, unbound references, and
  assignment, not claimed.
- Residual provenance survives: rebuilt nodes carry the spans of the nodes they
  came from, so `Residue.survey` attributes origins exactly as before.
- Report figures shift slightly downward where a residual contained flattenable
  or trivial bindings (`test/golden/collapse.expected` re-pinned; two samples
  shrank). Prior reports remain reproducible from their pinned revisions.

## Test impact

- New `test/unit/normalize_test.ml`: each rewrite pinned against expected
  shapes; idempotence over every term in the suite; effect counterexamples
  (sequential prints, branch-local and lambda-local effects, unused effectful
  bindings, set targets, quoted references, an alias of an assigned variable
  both under its binding and captured by an escaping closure, and a literal
  that still substitutes beside a write); same-printed-name shadowing;
  quotation and reifier immutability; whole-program semantic preservation
  including failure and unbound-reference samples; origin attribution across
  files.
- `test/golden/collapse.expected`: re-pinned; residual sizes shrink slightly,
  no counter other than size moved.
