# 0024 — `up`, the meta bindings, and the group cells as Ash values

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 4.3
- **Amends:** 0009 (the reflection class gains five readers), 0015 (an `open`
  cell can now be one the desugarer did not allocate), and 0023 (`up` is the
  sugar that ADR named and deferred)

## Context

Task 4.2 built the up/down protocol and left `up` as sugar to be written. Sugar
is the easy half. The hard half is the meta bindings of spec §5.2, and in
particular `eval` and `apply`, which the spec calls *cells*: the level above must
be able to read the evaluator running the level below, wrap it, and write the
wrapper back, and every subsequent step of that level must go through the
wrapper. That is the §5.3 demo, and it is the acceptance criterion of this task.

Three things make it awkward. The evaluator group is a set of OCaml functions in
`Machine`, not Ash values, so something has to bridge the two without becoming a
second mechanism beside the group cells §D3 already requires. A primitive cannot
find the level below — one registry serves the whole tower (ADR 0017) — so
anything a meta binding reads has to come from the applying machine. And a
replacement is Ash code written at level *n+1*, so the choice of which machine
evaluates it is a semantic decision, not an implementation detail.

## Decision

**`up { E }` is a reifier applied to no arguments.** There are no arguments to
reify — only a level to reach — so the expansion is `App(Reifier(exp, env, cont),
[])`. The three reifier parameters are bound under the printed names §5.2 gives
them, so a body writes `exp`, `env`, and `cont` and gets hygienic identities. The
body ends in `resume(cont, E)`, which is step 4 of §5.2 stated as code: the level
below resumes with the body's value, unless the body resumed it earlier itself,
in which case the `up` never returns normally. `exp` is therefore the generated
call node — which is exactly "what level *n* was evaluating", since the sugar is
what it was evaluating.

**`up` takes a block, never a bare expression.** The tracing demo's body is a
statement list, and an unbraced body would have to decide how far to the right it
extends. Blocks exist to settle that.

**The remaining bindings are calls, not constants.** `meta_eval()`,
`meta_apply()`, `meta_global()`, and `tower_level()` are evaluated at the top of
the body, so each answers about the machine actually running it. A function
containing `up` called from level 0 and from inside another `up` body must see
different levels; a desugar-time constant could not.

**`eval` and `apply` are `open` bindings, and the cell they hold is the level
below's real group cell.** Reading one lowers to `open_deref` and assigning to
one to `open_set` — the same lowering an `open fn` group gets (ADR 0015), so
`eval := tracing(eval)` is a write through a cell, not a rebinding, and the
collapse report counts these dereferences with all the others. The cell is
created on demand by `Machine.meta_eval_cell` and memoized, and creating it
installs a dispatcher in the machine's own group cell that reads it.

**Materializing a cell is observationally inert.** The cell is created holding a
wrapper around the evaluator that was installed at that moment, and the
dispatcher compares physical identity: while the cell still holds that wrapper,
the machine calls the original host function directly, with the same counters and
the same host stack behaviour it had before `up` was ever used. An `up` body that
never touches `eval` therefore changes nothing about the level below, which is
required, because the expansion binds both cells unconditionally.

**A replacement runs on the machine above the cell it lives in.** The
replacement was written at level *n+1*; running it on level *n*'s machine would
make it its own interpreter and diverge on the first step. This is also the
operational content of the §5.7 level-independence law: patching level *n*'s
evaluator changes level *n* and not the level running the patch.

**The wrapper closes over the evaluator, not over the cell.** `let base = eval`
must reach the function that was installed, so `base` is a value wrapping that
function directly. A wrapper that re-read the cell would call itself. This is
also what makes a second `up { eval := … }` compose: it reads the first
replacement out of the cell and wraps it, most recent outermost.

**The evaluator gets a fifth callback, `meta`, and `Value.meta_query` is its
protocol.** `Below_eval_cell`, `Below_apply_cell`, and `Below_global_env` answer
about the level below and refuse at the base program in the same words `reflect`
does; `Tower_depth` reads a thunk the tower installs alongside `level_above` and
`level_below`. A variant rather than four more labelled arguments, because the
argument list is already long and the questions are one kind of question.

**`level` is relative and `tower_depth()` is the opt-in.** `tower_level()`
answers the machine's own level, so the base program is always 0 (§D9), and
`tower_depth()` answers how many levels the tower has materialized. Materialized
rather than conceptual: unmaterialized levels are observationally
indistinguishable from the default (ADR 0022), so the materialized count is the
only thing that is actually true about the runtime, and it is exactly the number
that changes when a program reflects. Both are registered primitives, so a
depth-sensitive program is detectable syntactically.

**The `apply` cell's protocol is `(callee, args, cont)`, without a call site.**
Spec §5.2 gives `apply` three things and a source span is not among them, so a
replacement that falls back to the default attributes the fallback to where it
was written. Declared boundary, in the manner of ADR 0016's locations: widening
the cell's protocol would change what every meta-level `apply` has to accept, and
nothing in the tower laws depends on it.

## Alternatives

**Extend `Core.Reifier` with the extra meta binders.** Rejected: it grows Core
for the convenience of one desugaring, which scope control forbids, and it
mis-states the semantics — the extra bindings are not properties of the
suspended call, they are questions about the machine running the body.

**Make `eval` an ordinary binding holding the evaluator, with `eval := f`
lowering to `Set`.** Rejected: `Set` rebinds the name in the body's environment
and the level below would never see it. The spec says *cell* for this reason, and
the cell discipline already exists.

**Give the meta level a copy of the evaluator and install it on return.**
Rejected for the reason §D8 rejects save/mutate/restore: a continuation captured
inside the body and resumed later would install a stale evaluator. Writing
through the cell has no restore step to get wrong.

**Run the replacement on the machine whose cell holds it.** Rejected: it is
non-terminating, and the fact that it is non-terminating rather than merely wrong
is the clearest statement of why level *n*'s evaluator is level *n+1*'s program.

**Let `tower_depth()` report a conceptual infinite depth, or the number of
interpreter layers.** Rejected. The tower is infinite and unmaterialized levels
cost nothing, so any conceptual number would be a constant that observed nothing;
and an interpreter layer is not a tower level (ADR 0017), so counting layers
would answer a different question than the one §D9 asks.

**Expose `eval_list` as a third cell.** Not done: §5.2's table names `eval` and
`apply`, and the default `eval_list` calls `Machine.eval` per element, so a
replaced `eval` still sees every argument. Adding it is a deliberate widening of
the meta interface, not an oversight to be fixed silently.

## Consequences

- `Value.prim_impl` gains `~meta`; every primitive that ignores it says so.
- The registry grows to 49 primitives: `meta_eval`, `meta_apply`, `meta_global`,
  `tower_level`, and `tower_depth`, all Reflection.
- `Machine` gains the two Ash-facing cells and `tower_depth`; `Machine.levels`
  gains `level_tower_depth`, which the tower supplies as a thunk.
- `Surface` gains `Up of t`; the parser accepts `up` followed by a block, and
  `up 1` is a parse error naming the missing brace.
- `Desugar.required_primitives` grows by five names, so a registry that loses one
  fails at lowering rather than at run time.
- The base program answers `tower_level()` and `tower_depth()` with 0 and refuses
  the three `Below_` readers. That refusal is the same one `reflect` gives.

## Test impact

`test/unit/up_test.ml` covers resumption and one-step materialization, laziness
for ordinary code, each of `exp`/`env`/`cont`/`global`/`level`, `tower_depth()`
at depths 0, 1, and 2, the §5.3 replacement (its answer preserved, interception
past the outermost node, and interception growing linearly with nesting depth),
level independence measured as the counter *not* moving while level 1 runs its
own body, persistence and composition of two replacements, the `apply` cell, the
inertness of untouched cells, `meta_error` ownership, and both refusals without a
tower. `test/unit/primitives_test.ml` gains the five primitives in its
classification, arity, and type tables, where the three `Below_` readers are
registered as always failing at the base program. `test/golden/parser.expected`
and `test/golden/desugar.expected` pin the surface form, the expansion, and the
`desugar/up` provenance.

## Required spec or measurement changes

None. This implements spec §5.2 and §5.3 and the `level`/`tower_depth()` split of
§D9. The §5.7 laws for transparency, reifier identity, level independence, and
depth observation are demonstrated here for one step; the depth-parameterized law
suite is task 4.4 and owns those checkboxes. `meta_with` (§5.5) remains Phase 8 —
what this task adds is the persistent mutation it is defined against.
