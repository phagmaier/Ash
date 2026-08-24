# 0028 — Partially static immutable data, and reifying values at stage boundaries

- **Status:** accepted
- **Date:** 2026-08-24
- **Task:** 5.3
- **Amends:** 0026 (what "static enough to fold" means) and spec §D7's "fold when
  all arguments are static", updated in the same change
- **Confirms:** 0020 and spec §D6 — the `lift` primitive's domain is unchanged;
  §D6 already says the specializer residualizes a lambda from its syntax rather
  than lifting closures, and this task is where that starts happening

## Context

Task 5.3 is §7.4 step 1: pure higher-order Core, recursion, and immutable data.
After 5.1–5.2 the specializer already folded fully static pure primitives and
inserted hygienic lets for dynamic ones, and recursion controlled by static data
already unrolled. Two things in the fragment did not work.

**Immutable data was all-or-nothing.** `is_purely_static` walked a list
recursively, so a list holding one dynamic element was treated as entirely
unknown. Every list operation on it residualized, which means the classic
partial-evaluation win is unavailable: a loop over a list whose *spine* the
specializer knows cannot unroll if one element is dynamic. That is the opposite
of the discipline the spec states in §7.3 — "the environment's *shape* is static
while its *contents* are dynamic" — and it is the shape the self-interpreter's
own value domain has, since it represents environments and closures as lists.

**Closures could not cross a stage boundary.** A closure reaching a residual
argument position was converted with `Evaluator.lift_value`, whose domain (§D6)
deliberately refuses closures, so `g(fn(y) -> y * 2)` with `g` dynamic failed to
specialize at all. The higher-order half of the fragment therefore only worked
when every function was consumed by the specializer.

## Decision

**A primitive states how much of each argument it inspects.**
`Ash_core.Observation` adds a three-valued judgement per argument position —
`Whole_value`, `Shape_only`, `Unobserved` — and `Value.primitive` carries a
signature of them (`prim_observes`), defaulting to `Whole_value` everywhere.
`Effect_class` still says *whether* a primitive may run during specialization;
`Observation` says *what has to be known first*. The two are read together by
one named policy predicate, `Stage_value.may_fold`:

> A primitive may fold when its class permits folding at all and nothing it
> actually inspects is dynamic.

The immutable-data group is the only group that departs from the default:
`cons` observes the shape of its tail and nothing of its head; `head`, `tail`,
`empty?`, `length`, and `list?` observe only the shape of their argument;
`list` observes nothing. Arithmetic, comparison, `==`, and the `Code` observers
keep the whole-value judgement, so structural equality over a list with dynamic
elements still residualizes.

Consequently `Value.List` is a *partially static* value: its spine is known and
its elements may be `Code`. `Stage_value.is_shape_static` names that condition;
`is_purely_static` keeps its old meaning and is now only what `Whole_value`
requires.

**Stage boundaries reify; they do not `lift`.**
`Staged_eval.reify_value` is now the single conversion used wherever a value
crosses into residual code — residual primitive calls, residual applications,
branch and lambda results. It handles what `lift` cannot:

- a closure is reified into its lambda syntax, with dynamic parameters and its
  body specialized in its own `reify_block`;
- a non-empty list is rebuilt as a residual `list` call over reified elements,
  which is what carries partially static data into the residual program;
- everything else is converted by `Evaluator.lift_value` exactly as before.

The `lift` primitive keeps the fixed §D6 domain. The distinction is deliberate:
a program asking to serialize a closure is asking for something Ash does not
have, while the specializer holds that closure's syntax and environment and can
residualize it. Where both apply they produce the same Core.

## Alternatives

**Infer shape-staticness in the specializer instead of declaring it.** Rejected:
it makes the specializer guess a semantic property of each primitive, and a
wrong guess is an unsound fold rather than a slow one. Declaring it at the
definition site means a new primitive is conservative by default.

**Key the policy off primitive names in `ash.stage`.** Rejected: the knowledge
would live away from the definitions it describes, and adding a primitive
without touching the table would be silent.

**Give lists a dedicated partially-static representation.** Rejected as
premature: `Value.List` with `Code` elements already is that representation, and
a second one would have to be threaded through the ground evaluator, which never
sees a dynamic value.

**Let a closure at a boundary keep failing.** Rejected: it excludes the
higher-order half of §7.4 step 1, which this task exists to deliver.

## Semantic consequences

- Folding `head`/`tail`/`cons`/`length` on a known spine removes immutable-list
  allocations from the residual program. This is sound under the classification
  already recorded for these primitives: a `List` cannot be mutated and is
  compared structurally, so its allocation is not observable.
- A primitive that folds may fail at specialization time. That was already true
  (division by zero, type errors); it now also covers `head` of a spine the
  specializer knows to be empty. The failure is the one the program would
  certainly have reached, reported at the same place.
- Residualizing a closure duplicates its body once per boundary crossing. Code
  growth, not incorrectness; Phase 6.1's memoization is what bounds it.
- Recursion driven by *dynamic* control still does not terminate at
  specialization time. That is Phase 6.1 (memoized specialization points and
  residual `LetRec`) and 6.2 (budgets and generalization), and is unchanged by
  this task.

## Test impact

- `test/unit/stage_fragment_test.ml` (new) stages higher-order, recursive, and
  immutable-data programs whose results still depend on unknown arguments, then
  runs each residual on concrete arguments and requires the source's answer. It
  also pins what must *not* fold — structural equality, `list?`, and `length`
  over unknown values — and unit-tests `Stage_value.may_fold` directly.
- `test/differential/residual_test.ml` (new) compares source execution with
  residual execution over the whole pure half of the shared corpus, including
  the traces, and checks that specialization itself leaves no output.
- `test/unit/stage_test.ml`, the tower laws, and the self-interpreter
  differentials are unchanged and still pass.
