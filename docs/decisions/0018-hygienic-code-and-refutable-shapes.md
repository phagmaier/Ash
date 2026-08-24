# 0018 — Hygienic Code construction and refutable value shapes

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 3.1
- **Amends:** 0013 (quotation and code patterns now lower)

Task 3.5's [ADR 0021](0021-real-code-self-interpreter.md) subsequently completes
the encoding retirement scheduled by this record.

## Context

Task 3.1 requires quotation, splicing, constructor patterns, and quasiquote
patterns, accepting when adversarial same-name splices cannot capture or be
captured. The parser has represented all four since task 1.3, and Core and the
runtime value domain have had `Quote` and `Code` since Phase 0, but ADR 0013
deliberately refused to connect them before their hygienic semantics existed.

Two adjacent questions had to be settled with that connection. First, Code
components include identifiers and recursive bindings, but the fixed value
domain has no `Ident` or binding value and must not grow merely for convenient
reflection. Second, list patterns currently call `empty?` before establishing
that their subject is a list. In a dynamically typed match this makes a wrong
shape raise instead of letting the next clause run; constructor patterns would
repeat the same problem for non-Code subjects.

The self-interpreter is intentionally not part of this task. Its Phase 2 layer
tests exercise `Ash_self.Encode` at depths 1 and 2. Replacing that encoding in
the same change that introduces Code would change the tested transport and the
interpreter dispatch together, weakening those tests as evidence for 3.1.

## Decision

**A quotation lowers to a Core template plus exact-identity splices.** Each
expression hole becomes a fresh free `Var` marker in a quoted template. The pure
`code_splice(template, marker, replacement)` operation replaces only that
marker identity in expression positions. No alpha-renaming is needed: a
same-printed binder is a different identity and therefore cannot capture the
replacement; identities carried by the replacement likewise cannot bind
adjacent template nodes. The replacement keeps its own spans and provenance.

**Quoted names have lexical identities even when the resulting Code is open.**
A name bound outside or within the quotation keeps that binder's identity. An
otherwise unresolved name receives one fresh identity per quotation and printed
name, allowing open Code to be assembled for later explicit evaluation. This is
not implicit `NamedVar`: outside a quotation, an unbound source name remains a
desugar error. Runtime lookup by string is requested explicitly with the pure
`NamedVar(string)` Code constructor.

**Nested quotation inside a splice sees the surrounding quoted binders.** In the
staged-power shape `` `{ fn(y) -> ${power(n, `{ y })} } ``, `y` is not a runtime
Ash value at construction time, but the nested quotation must still use the
outer template's binder identity. The lowering therefore carries a quotation
scope separately from the runtime scope used to evaluate a splice.

**Code observation uses a small immutable view.** `code_view` returns a list
headed by the exact constructor symbol (`'Lit`, `'Var`, …). Literal and string
fields use their ordinary Ash values. Every syntactic field is `Code`; an
identifier is represented by one-node `Code(Var ident)`, parameter lists are
lists of those values, and a recursive binding is `[Code(Var name), Code(Lam)]`.
This represents all eleven forms without enlarging the value domain or exposing
the host ID counter. `code?` guards the view.

**Quasiquote patterns are alpha-aware templates.** Each pattern hole is another
fresh free marker. `code_match(template, subject, markers...)` walks both Core
trees under a binder correspondence, treats markers as single-node wildcards,
and returns either `[]` or `[[captures...]]`; the outer singleton distinguishes
a successful zero-hole pattern from failure. The full surface patterns inside
`${...}` then match those captured Code values. `Code` equality also changes
from host identity to `Alpha.equal`, because binder allocation and parameter
spelling are not observations of generated code.

**Immutable Code operations are Pure, not Reflection.** Spec D7 explicitly puts
Code constructors in the pure class: these operations inspect or produce only
immutable values and may fold when all arguments are static. The Reflection
class remains empty through 3.1; closed-code `run` in 3.2 is the first operation
whose meaning invokes an evaluator, and tower operations follow in Phase 4.
This corrects ADR 0013's provisional wording that Phase 3 code construction
would require reflection-class primitives.

**A structural pattern on the wrong value shape refutes.** List patterns first
use `list?`; constructor patterns first use `code?`. Accessors run only after the
guard. Thus `match 5 { [] -> 'empty; _ -> 'other }` answers `'other`, and the
same clause-order-independent rule applies to a `Lit(...)` pattern on a number.
A malformed value inside an accessor called directly remains a type error.

**Retiring `Ash_self.Encode` is task 3.5, not task 3.1.** That task will convert
`eval.ash` to constructor dispatch over real Code after 3.2–3.4 have completed
the Code foundation. Its acceptance is: the interpreter dispatches on
constructor patterns, spans cross into the interpreted level, the differential
test compares failure location as well as cause, and the temporary encoding
module is deleted.

## Alternatives

**Build Code recursively with a primitive for every Core constructor.** This
would expose a large API and still need a representation for binders and
`LetRec`. A quoted template plus exact marker substitution is smaller and makes
the hygiene argument local.

**Use printed marker names.** Rejected: a user can write the same name, and the
entire point of D1 is that hygiene may never depend on naming discipline.

**Add `Ident`, lambda, and binding variants to `Value`.** Rejected by the small
value/lifting domain and unnecessary: one-node Code values retain identity and
span without another representation to serialize later.

**Classify Code operations as Reflection.** Rejected by D7 and by their actual
semantics. They neither invoke an evaluator nor inspect tower state.

**Keep list mismatch as a dynamic type error.** This makes `match` outcome
depend on whether a refutable structural pattern is written before a wildcard,
and forces every constructor-pattern user to guard the whole match manually.
Shape mismatch is failure of the pattern; direct accessor misuse is still an
error.

**Rewrite `eval.ash` now.** Rejected for scope and evidence. Constructor
patterns are ready, but closed execution and the interpreter's full Code
transport are owned by later Phase 3 work. The explicit 3.5 prevents the
temporary encoding from becoming an unowned permanent boundary.

## Consequences

- `Ash_core.Code` owns identity-based splicing and alpha-aware template matching.
- The pure registry grows from 31 to 36 entries: `code?`, `code_view`,
  `code_splice`, `code_match`, and `NamedVar`. Reflection remains empty.
- Surface quotations can be open; ordinary unbound expressions still fail in
  desugaring. `run` will perform the closedness check in 3.2.
- Constructor views retain child Core nodes and therefore their spans. Task 3.5
  can pass those nodes recursively rather than reconstructing span-less data.
- `Ash_self.Encode`, `lib/self/eval.ash`, and the layer tests are unchanged in
  3.1. The registry expansion is visible to their global frame but does not
  change the interpreter's representation or dispatch.
- Match lowering is slightly larger because every list step is guarded. Later
  normalization may remove guards proven redundant; the desugarer stays simple
  and semantically total first.

## Test impact

`test/unit/code_test.ml` checks exact-identity splicing, both directions of
same-name non-capture, free-identifier preservation, alpha-aware template
matching, and captured binder identity. `test/unit/desugar_test.ml` checks static
and dynamic quotation, nested quotation scope, open quoted names, explicit
`NamedVar`, alpha-aware Code equality, constructor patterns, quasiquote holes,
wrong-shape fallthrough, and non-Code splice errors. `primitives_test.ml`
enumerates all eleven `code_view` tags and independently pins every new
primitive's class, arity, and type behavior. Parser tests cover the nested
quote/splice and quoted-definition edges without changing the grammar. Golden
desugaring exposes the generated Core and the new list guards.

## Required spec or measurement changes

Spec §4.2–§4.4 now states wrong-shape refutation, open-quotation identity,
alpha-aware Code comparison/patterns, and the pure Code operations. Spec §6 and
ADRs 0016–0017 are clarified: Code capability arriving in 3.1 no longer implies
that the self-interpreter transport changes in the same task; checklist task 3.5
owns that retirement explicitly.
