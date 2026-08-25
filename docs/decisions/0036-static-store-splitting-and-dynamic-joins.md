# 0036 — Static-store splitting and dynamic joins

- Status: accepted
- Task: to-do 7.2
- Spec: §7.4 step 3, §D7
- Supersedes nothing; extends ADR 0033 (the residual normalizer) and ADR 0035
  (primitive effect policy)

## Context

Until this change the staged evaluator refused `Core.Set` outright. That refusal
was honest — performing a write during specialization mutates the *specializer's*
state rather than the program's, and emitting one needs a residual place to write
to — but it put every mutating program outside the collapser, including the
corpus's eight mutation and evaluation-order programs and everything an `open fn`
group lowers to.

Spec §7.4 names the hard case directly:

```ash
if dynamic_cond then x := 1 else x := 2
use(x)
```

The specializer cannot decide which branch runs, so it cannot decide what `x`
holds afterwards. It must emit both writes and join the store at the merge point.

## Decision

An abstract store, `Ash_stage.Store`, decides for each binding whether the
specializer or the residual program owns it, and forks and joins that decision at
dynamic conditionals.

### A cell is either held or residual

- **Held** — the specializer owns the cell. Writes update it, reads fold, and the
  residual keeps no trace of either. The contents live *in the cell itself*, so
  an ordinary `Core.Var` read finds them with no store lookup at all.
- **Residual** — the residual program owns the cell. It stands for a residual
  binding; writes become `Core.Set` nodes emitted into the block in the order
  they happen, and reads become that variable.

Every decision is gated on `Core.assigned_idents` of the whole term: a binder
nothing assigns takes exactly the path it took before this module existed. The
entire pure corpus specializes to bit-identical residuals, and the criterion
suite's figures are unchanged.

### Keyed by the cell, never by the binder

Two names for one cell are one place — that is what aliasing is — and one binder
evaluated twice is two places. Keying on `Value.same_cell` gets both right at
once: two closures over the same `var` write to the same residual binding, while
a `var` local to a recursive function folds separately in every activation. A
binder-keyed store would confuse the second for the first.

### Holdability is syntactic, local, and over-approximate

`Store.holdable` is the proof obligation, asked once per binder (memoized —
a hygienic identity has exactly one scope). A binding is held only if, within
its scope, it is:

- not free in any `Lam` or `LetRec` body — that closure can be reified into
  residual code, shared by a specialization point's single body, or called from a
  dynamic position, and then its reads and writes run in the residual program's
  order rather than in ours;
- not mentioned inside a `Quote` — quoted code is data the program may `run`;
- not spelled by a `NamedVar` — name lookup finds the cell without mentioning its
  identity, so identity-based reasoning cannot see the reach;
- not in a scope containing a `Reifier` node — applying one hands the whole
  calling environment to the level above.

Failing any clause is not a refusal: the binding is residualized, which is the
whole of *residualize when proof is unavailable*.

The first clause does more work than it looks like. Because a held binder is
never free in a lambda, every write to it is *written in its own scope* — no
inlined callee can assign it — which is what makes the syntactic scan below
sound, and what keeps a promotion's binding in a block that dominates every later
read of it.

### Dynamic joins: promote before the fork

At a conditional whose condition is dynamic:

1. Every held cell whose binder is assigned in either branch is **promoted**
   first: its current value is bound in the enclosing block, and from there the
   cell stands for that binding. The residual program needs *one* place both
   branches write to, and it has to be bound where both branches — and everything
   after the join — can see it.
2. The store is snapshotted, the consequent specialized, the snapshot restored,
   the alternative specialized.
3. `Store.join` keeps only the bindings that were live before the fork (a cell a
   branch created has left scope) and requires both forks to describe each of
   them the same way.

Step 1 is what makes step 3's agreement the ordinary outcome. The disagreement
case refuses rather than picking a side; it is a guard at a site today's rules
cannot reach, kept for the same reason ADR 0035's effect gate is kept — the next
rule added below it inherits the refusal instead of having to remember it — and
tested directly against the module rather than through a program.

A write of a *dynamic* value to a held cell promotes it on the spot, with no
branch involved: the value being written is what the residual binding starts
from.

### Where the specializer still refuses

- An assignment to a cell the store does not track — a `LetRec` name, or a
  binding that reached the specializer from outside the term. There is no
  residual place to write to and no proof the write is the specializer's alone.
- A specialization point whose *specialized* parameter is assigned and cannot be
  held. A parameter specialized into the point's body is one value shared by every
  call; the store can give it a place inside the body when it may hold it, but a
  parameter it cannot hold is residualized at its binding site — outside the
  residual function — where one call's write would be the next call's starting
  value.
- A reifier application or a `reflect` while the store holds a binding. The level
  the environment is handed to may write the cell, and a value already folded
  from it cannot be taken back.

### One write set, shared with the normalizer

`Core.assigned_idents` is now defined once in `Ash_core.Core` and read by both
the store and `Ash_collapse.Normalize`. This is load-bearing rather than tidy.
The normalizer may substitute a variable for its binder only when nothing assigns
it, and may not eliminate a binding a `Set` targets; those guards were defensive
while no residual contained a `Set`. A residual this store builds is the first
term where they decide anything: the promoted binding of §7.4's example is a
literal, and a normalizer with a narrower write set would substitute it into the
read after the join and answer `0` for both branches.

## Alternatives considered

**Residualize every mutable binding.** Sound, and about a tenth of the code:
every `var` becomes a residual `let`, every write a residual `Set`, and the
residual program does all the joining. Rejected because it makes the "static" in
static-store splitting vacuous — `var x = 1; x := x + 1; x * 10` would emit three
residual operations instead of folding to `20`, and the store would never split
anything.

**Speculate and restart at the branch.** Specialize both branches, join, and on
disagreement promote the offending cells and redo both branches to a fixpoint.
More precise — two branches that write the same static value could stay held —
but the discarded attempts have side effects the specializer would have to
sandbox: emitted-binding counts the budget watches, sticky generalizations, the
compile-time log. Rejected as a large amount of machinery bought with a small
amount of precision. The syntactic pre-promotion above is sound because
`holdable` already guarantees every write to a held binder is written in its own
scope.

**A binding-time analysis pass.** The standard offline answer, and the wrong
shape for this specializer: staging here is online and value-driven
(`maybe_lift`, ADR 0026), and a separate pre-pass would need its own account of
tower levels and reflection to agree with the one the evaluator has.

## Scope

The store's domain is *bindings*, not heap allocations. `cell_new`, `deref`,
`cell_set` and the open-group trio `open_cell`, `open_deref`, `open_set` are
still `Allocation_or_mutation` and still residualize, so an `open fn` group
remains the criterion suite's boundary sample and the collapse report still
counts surviving evaluator-cell dereferences. Making allocation static needs an
escape analysis over values rather than over scopes, and it is what Phase 9's
reflective collapse will need; it is not what §7.4 step 3 asks for.

## Semantic consequences

- `Core.Set` reaches a residual for the first time. Nothing else about the
  residual language changes.
- Specialization can now perform a write. It is the specializer's own cell, never
  a cell the program can observe by another route — that is what `holdable`
  proves — and no observable effect is added: §D7's absolute is untouched, and
  `Effect_class` is unchanged.
- The refusals above are new failure modes for programs that previously failed
  anyway, with a message naming the binding rather than the feature.

## Test impact

- `test/unit/store_test.ml`: held bindings folding away, escaping bindings and
  aliases residualizing, §7.4's branch in both directions, one-sided writes,
  nested branches, one binding split while another stays held, promotion on a
  dynamic write, the three refusals, `Store.join` directly, and the normalizer's
  write-set guard on a residual the store built.
- `test/differential/residual_test.ml`: the corpus's eight mutation and
  evaluation-order programs now compare source against residual.
- `test/golden/collapse.expected`: a held store binding, mutation across a
  dynamic branch, and an assignment the store cannot place.
- `test/unit/collapse_test.ml` and `test/unit/stage_test.ml`: the boundary moved,
  so both now pin where it is rather than where it was.
- Unchanged: the criterion suite's 73 samples, 906,708 dispatches, 2,125,589
  cell reads, 250 residual nodes; the 417 invariant and 18 depth-sensitive
  checks.

## Required spec and measurement changes

- §7.4 step 3 and §8 Phase 7 record that store splitting is done and what its
  domain is.
- §10's trap "static store update across a dynamic branch → wrong values,
  silently" is now addressed and marked.
- No report metric changes meaning. The golden report gains two samples and
  replaces one.
