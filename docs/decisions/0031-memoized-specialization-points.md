# 0031 — Memoized specialization points and residual `LetRec`

Status: accepted. Task 6.1. Spec §7.5, §7.4 step 2.

## Context

Phase 5 collapsed the pure fragment by inlining every call. That is exactly
right while the specializer can decide the recursion's control: `power(3, x)`
unrolls to three multiplications, a traversal of a statically shaped list
disappears into the arithmetic it performed, and no interpretation survives.

It is exactly wrong when the control is dynamic. `loop(n)` whose base case tests
an unknown `n` has no end to unroll to: the conditional residualizes, the else
branch is specialized, the recursive call is inlined, and the process repeats
until the host stack runs out. Before this task those programs did not
specialize at all — they were the fragment's edge, recorded as such in the
Phase 5 handoff.

§7.5 says what to do: memoize on `(function identity, static projection of
args)` → residual function name, emit a residual `LetRec`, call it. It does not
say *when* a call becomes a specialization point, and that choice is the whole
design.

## Decision

**Inlining stays the default. A call becomes a specialization point only when
its own key is already being inlined.**

A key is a function's identity — its lambda together with the environment it
closed over, both compared physically, which is what makes a `LetRec`-bound
function's recursive call the same function — plus a projection of each
argument:

| Projection | When | In the residual function |
| --- | --- | --- |
| `Known v` | `v` is static all the way down | specialized into the body; compared between calls by `Value.equal` |
| `Held v` | `v`'s constructor is known but its contents are partly dynamic — a list with a static spine and dynamic elements | specialized into the body; compared by identity |
| `Unknown` | `v` is residual code | becomes a parameter |

While a call is being inlined its key is *active*. Meeting an active key again
is a cycle the unroller cannot leave, so the specializer stops, emits a residual
function, and calls it. Three consequences follow from making that the only
trigger:

1. **Everything Phase 5 collapsed still collapses, unchanged.** A key repeats
   only when unrolling has stopped making progress. `power(3, x)` walks
   `3, 2, 1, 0` — four different keys. A traversal of a static spine of dynamic
   elements walks four different `Held` lists, because `tail` of a list is not
   that list. Checked, not assumed: with the criterion suite unchanged it still
   reported 906,684 dispatches, 2,125,537 cell reads and 142 residual nodes, and
   every pre-existing counter in `test/golden/collapse.expected` is what it was
   — the file changes only by gaining the new report line and the new sample.
2. **Termination is decided by the projection, not by a budget.** Recursion
   whose static argument shrinks terminates by unrolling; recursion whose static
   projection stops changing terminates by tying a knot. Recursion whose static
   argument *grows* — an accumulator that conses a longer list each step — still
   does not terminate. That is task 6.2's budget, and it is deliberately not
   smuggled in here.
3. **A call with no `Unknown` argument may still become a point.** Same
   function, same values, pure: the source program diverges, and the residual is
   a zero-argument residual function that calls itself. A stage-time hang
   becomes a correct diverging residual.

**The point belongs to the call that started the inlining, not to the one that
discovered the cycle.** The cycle is almost always discovered inside a dynamic
conditional's branch, and a residual function bound in a branch is unreachable
from anywhere else — including from the next call with the same key, which is
the sharing a memo table exists for. So `Specialize` records, at each entered
call, the context it was made in: the open emission blocks, the visible
specialization-point scopes, and the calls already being inlined. Committing a
point reinstalls that context, specializes the body there, and binds the
`LetRec` there. The entered call's own key is deliberately not active inside,
so the recursive call reaches the memo table and emits a call to the point being
defined. That is what ties the knot.

**A specialization point is bound where it was created, never hoisted.** Its
body may mention binders that let-insertion introduced earlier in the same
block, and the static values specialized into it may be partially static data
whose dynamic parts are residual variables of that block. `Emit` therefore
carries an ordered list of block items — let-insertions and `LetRec` groups —
instead of a list of bindings, and a point's scope ends when its block does.
Two branches of a dynamic conditional each get their own point; the same key met
twice in one block gets one point, and the second occurrence is nothing but a
call to it.

## Alternatives

**Make every call with a dynamic argument a specialization point** (offline
partial evaluation's usual rule, applied online). Rejected: it destroys Phase 5.
`power(3, x)` has a dynamic argument and static control, and would residualize
into a function per unrolling step rather than into three multiplications.

**Restart the outer call as a specialization point when a cycle is found.**
This is the same placement decision, reached by aborting the in-flight inlining
and redoing it. Rejected: the abort has to unwind emission buffers and counters
that the aborted attempt already mutated, and the staged evaluator is in CPS, so
the continuation to restart with is not obviously recoverable. Recording the
entry context and building the point in it gets the same placement without
anything to undo. The cost is one unrolled copy of the body at the outer call,
which is a normal partial-evaluation outcome, not an error.

**Commit the whole active cycle as one mutual `LetRec` group.** Rejected as
unnecessary. Because the point is built in the outer call's context with the
inner keys no longer active, mutual recursion closes on the outer function
alone: `even?` becomes the point and `odd?` is inlined into it, so the point
recurs on itself after two decrements. One residual function, correct for both
parities.

**Hoist points to the outermost block where they would be in scope.** Rejected
for now: deciding that requires tracking which binders each open block
introduces, and duplication across conditional branches costs residual size
rather than correctness. Task 6.3's normalizer is where that belongs.

## Semantic consequences

- No Core form is added: the residual `LetRec` is the Core form that has existed
  since 0.3, and §7.5's "emit a residual `LetRec`" is met literally.
- The residual of a dynamically recursive program is no longer a literal or a
  straight-line expression; it contains recursion. That recursion is the
  program's own, not an interpreter's, and the collapse criterion is unchanged:
  zero eval-cell dereferences, zero evaluator calls, zero constructor dispatch,
  zero `NamedVar` lookups, zero reflection boundaries.
- `Identity` mode is untouched. All of this is inside the `Lift` branch of
  `apply`, so the ground evaluator's behaviour is bit-for-bit what it was.
- Specialization-point bookkeeping is observationally inert (AGENTS §D
  instrumentation rule): it changes which residual a program specializes to,
  never what that residual computes, and it produces no output.

## Test impact

- New: `test/unit/stage_recursion_test.ml`, 12 programs. All but the two
  static-control regressions would have overflowed the host stack before this
  change, so termination is part of what is asserted; each residual is executed against its source on several argument
  lists, because one residual has to agree with the source everywhere. It covers
  a dynamically controlled countdown, a traversal of an unknown list, mutual
  recursion, an accumulator with two dynamic parameters, a static argument
  specialized in rather than passed, distinct static arguments getting distinct
  points, one key shared by two calls, capture of an enclosing dynamic binding,
  a point per conditional branch, a recursive closure crossing a dynamic
  boundary, and — the regression that matters most — that static control still
  unrolls and creates no point at all.
- `test/laws/collapse_criterion_test.ml` gains two open samples whose recursion
  is dynamically controlled, so the milestone-2 criterion now covers residuals
  that contain a `LetRec`. 73 samples, 250 residual nodes.
- `test/golden/collapse.expected` gains a `Specialization points:` line
  everywhere and one new sample, "recursion on an unknown argument", which is
  where that counter is not zero. The golden file's own rule — every counter
  non-zero in at least one sample — is what required the new sample.

## Measurement changes

`Metrics.specialization` gains `specialization_points` and `memoized_calls`,
reported as `Specialization points: N (M calls)`. §7.5 asks for generalizations
to be instrumented because a program that collapses without generalizing is a
stronger result; the same argument applies one step earlier. Zero specialization
points says every recursion in the program was decided at specialization time.

Report figures from before this change are still comparable — the numbers that
existed did not move — but the criterion suite's totals did, because it has two
more samples. The Phase 5 totals (71 samples, 906,684 dispatches, 2,125,537 cell
reads, 142 residual nodes) are superseded by 73 samples, 906,708 dispatches,
2,125,589 cell reads, and 250 residual nodes.

## Known limitations

- Recursion whose static projection *grows* still does not terminate at
  specialization time. Task 6.2.
- A recursive closure that crosses a dynamic boundary is reified by
  `reify_value`, which is not itself a specialization point; the recursion
  inside it terminates, but a closure that passes *itself* across a boundary on
  each step does not. Task 6.2.
- The same key met in two branches of a dynamic conditional produces two
  residual functions. Correct, larger than necessary; task 6.3.
