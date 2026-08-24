# 0029 — What the collapse report measures, and what it does not claim

- **Status:** accepted
- **Date:** 2026-08-24
- **Task:** 5.4
- **Builds on:** 0025 (what tower depth means) and 0028 (the staged fragment)

## Context

Spec §9.4 asks for collapsibility to be an *observable property of the
implementation* rather than a yes/no compiler outcome, and §8 puts the
instrumentation in Phase 5 rather than later because §9's report depends on it.
Task 5.4 is the first version of that report.

The counters it needs mostly existed already: `Machine` counts group calls,
cell dereferences, per-form dispatch, and `NamedVar` lookups; `Primitives`
counts `open_deref` calls, which is why the open-recursion cells are spelled
apart from ordinary cells in the registry; `Tower.size_metrics` already
separates §9.1's two size measurements. What was missing was the walk of the
residual, the measurement that puts three runs of one program side by side, and
a renderer.

## Decision

**The report is three runs and one walk.** `Ash_collapse.Metrics.measure` runs
one program on the ground evaluator (what it means), at a stated tower depth
(what interposed interpretation costs), through the specializer (what
specialization costs), and then runs the residual (what the collapsed program
costs). All four share one tower's ground globals and one buffered output
stream, and each phase starts from cleared counters, so a figure belongs to the
phase it is printed under.

**Interpretation left in the residual is decided syntactically**, by
`Ash_collapse.Residue.survey`, and callees are identified by hygienic identity:
a residual application names the exact global binding the specializer emitted,
so resolving that identifier in the environment the residual will run in says
which primitive it is. A local binder that happens to print `open_deref` is a
different identity and is counted as nothing. The four questions the criterion
asks are answered as:

- **surviving eval-cell dereferences** — applications of `open_deref`;
- **surviving evaluator calls** — applications whose callee is itself an
  `open_deref`, which is what an interpreter's recursive step looks like once it
  is written down;
- **constructor dispatch sites** — applications of `code_view` or `code_match`;
- **`NamedVar` lookups residualized** — `NamedVar` nodes.

**Interpreter residue is attributed by provenance.** Every node keeps the origin
of the code it came from even after the specializer invents it, so residual
nodes are grouped by source file and residue is the nodes that came from some
file other than the program's own. This is the definition that will still mean
something when the input contains an interpreter's text.

**Agreement between runs is stated honestly, or not stated.** Closure equality
is identity (§D1), so a value carrying a closure, continuation, reifier,
environment, or cell cannot be compared between two runs at all. The report says
`carries identity: not comparable across runs` rather than comparing lambda
syntax and calling it agreement — proving a residual *function* correct means
applying it, which is what the differential tests do and what a report cannot.

**The printed report excludes heap words.** `Tower.size_metrics` measures
reachable words, which is a real representation measurement and also varies with
the OCaml runtime rather than with the program. The metrics record still carries
it for the measurement suite that reports it with its environment pinned (task
10.4); the human report, which is golden-tested, prints the structural counts
instead. Everything printed is a counter or an AST walk.

**The report says what it is not.** The residual is the program specialized on
its own — the pure fragment of §7.4 step 1. Erasing a level's interposed
evaluator is *static reflective collapse*, task 9.1: it needs the meta `eval`
binding to be foldable when the evaluator's identity is statically known, which
is a Phase 9 decision and not a Phase 5 one. The tower figures are therefore the
measured cost that collapse is set against, not a cost this residual removed,
and the report ends by saying so rather than leaving a reader to infer it from
the numbers.

## Alternatives

**Count residue by running the residual and reading the machine counters.**
Rejected: running any Core dispatches on Core constructors, so the number would
never be zero and would say nothing about what survived specialization. The
criterion is about the residual's syntax.

**Classify each program into §9.3's four classes now.** Rejected as out of
order: the conservative pre-check and the four-way classification are task 10.2,
and a class printed before its pre-check exists would be a claim with nothing
behind it.

**Print the residual Core in the report.** Rejected for now: §9.4's report does
not, and pinning residual syntax is what task 6.3's normalizer and 6.4's
depth comparison are for. The golden test pins the measurements.

**Report a per-level step ratio.** Rejected: §9.2 is explicit that the ratio
should be measured and allowed to say what it says, not baked into a report as
though it were constant. The per-level counts are printed; the arithmetic is
left to the reader and to task 10.4's measurement suite.

## Consequences

- New library `ash.collapse` (`Ash_collapse`) with `Residue`, `Metrics`,
  `Report`, and the `Collapse` facade. It sits above `ash.stage` and
  `ash.tower` and below the CLI, which matches the layering rule: nothing in the
  runtime or the collapser's own inputs can see it.
- `Ash_tower.Depth.interposed_term` exposes the term that is interposed at each
  level, so the per-level interpreter size the report multiplies by depth is
  measured from what is actually installed.
- `ash --collapse FILE [--depth N]` prints the report.
- `generalizations` is carried and always zero: task 6.2 is what makes it
  anything else, and the field exists so the report's shape does not change when
  it arrives.

## Test impact

- `test/golden/collapse.expected` pins the report for nine samples chosen so
  that every counter is non-zero in at least one of them: full folding,
  the same program at depths 0/1/3, a residual that still depends on an unknown
  argument, a traversal of a statically shaped list, an open-recursion group
  (surviving dereferences), a `code_view` dispatch (surviving dispatch site),
  observable output (specialization prints nothing), and a program outside the
  fragment (no residual, and the report says why).
- `test/unit/collapse_test.ml` pins what the numbers mean: each survey counter
  in isolation, the hygiene of callee identification, residue attribution across
  two source files, and the measurement's invariants — level 0's cost does not
  depend on depth, specialization leaves no output, and a fully static program's
  residual is its answer and costs less than the source run.
- The report's depth figures reproduce `docs/progress/0001-depth-cost.md`
  exactly (162 level-0 steps for `fact(5)`; 960, 4720, and 23600 at levels 1, 2,
  and 3), which is an independent cross-check that the two measurements are of
  the same thing.
