# 0021 — The self-interpreter consumes real Code with source-directed errors

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 3.5
- **Amends:** 0016 (temporary term representation and diagnostic boundaries),
  0017 (layer transport), and 0018 (scheduled encoding retirement)

## Context

Phase 2 needed the self-interpreter before quotation and constructor patterns
existed. ADR 0016 therefore chose a temporary tagged-list representation for
Core, and declared two boundaries: source spans did not cross a layer, and an
error detected by the Ash evaluator itself could not reproduce the host's
structured cause. ADR 0018 assigned removal of both boundaries to task 3.5,
after quotation, closed `run`, lifting, and the staged-Code regressions existed.

Real Code solves term identity and provenance, but not by itself the location of
a delegated primitive call. Calling the ordinary `invoke` helper would still
attribute an arity or type error to `eval.ash`. The interpreter also needs the
printed component of a binder for explicit `NamedVar` lookup without exposing
its allocation ID.

## Decision

**A subject crosses a layer as real Code.** `Self.interpreting term` writes
`Quote term` into the layer application. The interpreter dispatches over all
eleven Core constructor patterns. Syntactic fields and identifiers retain the
Code view fixed by ADR 0018, including every child span and exact hygienic
identity. The temporary `Ash_self.Encode` module is deleted.

**Only the primitive global frame still needs materialization.** The harness
writes each global as `[Code(Var identity), primitive]`. Primitive values remain
unwrapped, preserving ADR 0017's layer-composition result. `Self.reveal` retains
the comparison-only mapping from host closures, reifiers, and continuations to
the symbolic tags returned by the interpreted level; this is a value-domain
comparison boundary, not a term encoding.

**Printed lookup uses a narrow immutable Code operation.** The Pure `code_name`
primitive accepts only Code containing `Var` and returns its printed name. It
does not reveal the unique ID. Interpreted environments continue to key ordinary
lookup by the exact one-node Code value; `code_name` is used only in the
`NamedVar` path.

**Application carries its source node.** The Ash open-recursive `apply` member
now has the interface `apply(f, values, k, site)`, where `site` is the whole
subject `App` as Code. The Control primitive `invoke_at(site, f, values)` is the
list-spreading operation of `invoke`, but supplies `Core.span site` to the active
evaluator's apply callback. Primitive failures and non-callable applications
therefore retain the interpreted program's location. The extra argument is
observable to evaluator wrappers and is covered by the open-recursion law.

**Locally detected failures use a closed source-error protocol.** The Pure
`raise_at(site, descriptor)` primitive recognizes only the evaluator causes the
self-interpreter constructs: unbound and ambiguous lookup, arity, unexpected
value shape, one-shot continuation reuse, and unsupported reifier application.
It raises an Evaluate-phase structured error at `Core.span site`; continuation
reuse also retains capture and first-use spans and level 0, the only runtime
level before Phase 4. Unknown or malformed descriptors are ordinary structured
type errors, not arbitrary host exceptions. Like `match_error`, `raise_at`
always fails deterministically and is Pure for staging classification.

The registry consequently grows from 38 to 41 primitives: Pure gains
`code_name` and `raise_at`, Control gains `invoke_at`, and Reflection remains
exactly `lift` and `run`.

## Alternatives

**Keep tagged data beside Code.** Rejected: it would preserve the two declared
boundaries and leave two representations of Core for every later tower change.

**Expose identifier IDs or add an `Ident` value variant.** Rejected by intrinsic
hygiene and the fixed value domain. Printed-name access is sufficient for
explicit `NamedVar`; identity remains the Code value itself.

**Use ordinary `invoke` and accept helper locations.** Rejected because task 3.5
explicitly requires spans to cross and the differential comparison to include
location. A cause at the wrong source node is not equivalent evaluation.

**Add one primitive per error cause.** Rejected as unnecessary registry surface.
The descriptor protocol is closed and independently tested, while a completely
general host-error constructor would be an unjustified escape hatch.

**Store the current application in a mutable ambient cell.** Rejected because
continuation transfer and nested evaluation would make save/mutate/restore
incorrect for the same reason meta overlays cannot use it.

## Consequences

- `lib/self/eval.ash` is the spec §6 constructor-dispatch evaluator over Code.
- Program and child spans survive every self-interpreter layer.
- Host/self failures compare cause, span, phase, and level with no exemption
  list for locally diagnosed arity errors.
- A named interpreted closure retains its binder so arity diagnostics name it
  like the host evaluator.
- One-shot interpreted continuations retain capture and first-use Code nodes.
- The interpreter's `apply` wrapper interface has four parameters; `eval` and
  `eval_list` retain three.
- Phase 4 must replace the currently fixed level-0 field in interpreted
  continuation errors when materialized levels acquire their own relative level.

## Test impact

`self_host_test.ml` now compares every failure's location and context as well as
cause, removes the four-program self-diagnosis exemption, checks an unbound
hygienic variable with a synthetic source span, checks continuation reuse, and
requires quotations to return the same Code. `self_layers_test.ml` applies the
same complete error comparison at layers 1 and 2. `open_recursion_test.ml`
patches the four-argument `apply` at depth. `primitives_test.ml` pins the three
new classifications, arities, type boundaries, printed-name behavior, closed
error protocol, and source-directed failure locations.

The existing 99-program layer-1 and 98-program layer-2 comparisons still pass,
so replacing the transport did not weaken the Phase 2 iteration evidence.

## Required spec or measurement changes

Spec §6 now describes real-Code transport, source-directed application, and
structured interpreted failures. The Phase 3 roadmap records transport
retirement as completed. README and the checklist no longer describe the Phase
2 encoding as current. No report metric changes; all three new operations are
ordinary classified primitive calls and remain visible to later staging.
