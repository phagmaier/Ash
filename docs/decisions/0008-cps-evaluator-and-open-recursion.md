# 0008 — The CPS evaluator, open recursion, and instrumentation

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 0.8

## Context

Task 0.8 asks for the real evaluator in CPS with step and dispatch counting. The
checklist puts open-recursive evaluator groups at task 2.1, but the design spec
puts "evaluator holds direct self-references" first on its list of traps and calls
it "the expensive one" (§D3), and AGENTS invariant 3 states it unconditionally.
AGENTS also ranks the spec above the checklist when they pull in different
directions.

The question is therefore not whether the evaluator is open-recursive but when.

## Decision

**The evaluator is open-recursive from its first line.** `eval`, `apply`, and
`eval_list` live in mutable cells on a `Machine.t`, and every call between them
goes through `Machine.eval`, `Machine.apply`, or `Machine.eval_list`, which read
the cell on each call. No group member calls another directly and no closure
retains a direct reference to one.

Retrofitting this would mean revisiting every recursive call site in the
evaluator, and the failure it causes is silent: a meta-patch that fires once and
looks almost right. The cost of doing it now is one indirection per step, which
is a cost the collapse report exists to measure anyway.

This does not complete task 2.1, which is about the evaluator group *written in
Ash*. It does mean the host side of that invariant — cells, dereference-per-call,
instrumentation, and the "wrapping `eval` observes every nested node" acceptance
test — is in place and tested from Phase 0.

**Instrumentation goes in with the evaluator, not after it.** The machine counts
group calls, per-form constructor dispatches, cell dereferences, and `NamedVar`
lookups. These are the raw material for the §9.2 step metrics and for the collapse
report, which has to say how many dereferences and dispatch sites survived
specialization. Counters are integers no Ash value, error, identifier, or output
can depend on, and nothing in the evaluator reads them — instrumentation is
observationally inert.

Dispatches are counted by the *default* evaluator. A replacement that handles a
form itself does not count there, which is exactly the distinction the collapse
report wants.

**All eleven forms are dispatched.** `Quote` yields the code as a value and
`Reifier` yields a reifier value, both of which are the final semantics rather
than placeholders. What is genuinely not built yet — *applying* a reifier, which
needs the level above (task 4.2), and applying a continuation, which needs
one-shot enforcement (task 1.5) — is refused with `Error.Unsupported` naming the
missing piece. Refusing loudly with a name beats either pretending the form does
not exist or shipping code no test can reach.

**Primitives receive the real continuation.** Unlike the oracle, which invokes a
pure primitive with the identity continuation, the CPS evaluator passes `k`
through. That is what will let a control primitive do something other than
return, without the evaluator special-casing it.

**The differential corpus compares value, cause, and location.** Two independent
implementations can agree on every value and still disagree about where a failure
happened; a report that points at the wrong place is a real defect. The corpus
also pins the two observations most likely to drift silently — argument
evaluation order and mutation — and the harness was checked by reversing
`eval_list` and confirming it produced a readable minimal difference.

## Alternatives

- **Direct self-recursion now, cells at task 2.1.** Follows the checklist order
  literally. Rejected: it is the first trap in the spec's list, the rewrite
  touches every recursive call, and the bug it produces looks like a working
  demo.
- **Threading the group as an explicit record parameter instead of cells.** Also
  open recursion, but a meta level replaces a binding at runtime, mid-evaluation;
  a parameter would have to be re-threaded from the top, which is precisely what
  "intercepts every nested step" rules out.
- **Counting later, once something needs the numbers.** Rejected: retrofitting
  counters means touching the same call sites again, and the §9.2 metrics are the
  primary deliverable rather than a diagnostic afterthought.
- **A trampolined answer type.** Unnecessary: OCaml's guaranteed tail-call
  optimization already keeps CPS evaluation in constant host stack, verified here
  by a hundred thousand Ash tail calls. A trampoline would add a step to every
  continuation invocation and distort the step metrics.
- **Making the oracle open-recursive too.** No: the oracle's value is being
  simple enough to believe by reading, and it is frozen precisely so it cannot
  drift toward the system it checks.

## Semantic consequences

- Replacing a group cell takes effect from the next step, not the next top-level
  evaluation. Nothing may cache a group member across steps.
- `Machine.cell_dereferences` equals `Machine.steps` while the group is the
  default one. When the collapser removes interpretation, the surviving
  dereference count is what it has removed against.
- `Env.lookup_by_name` now returns the identity it found alongside the cell, so a
  caller holding only a string can still report `Unfilled_binding` against a real
  identifier. `Env.read_by_name_exn` is what `NamedVar` evaluates through.
- The CPS evaluator handles `NamedVar`, `Quote`, and `Reifier` while the oracle
  refuses them. That divergence is deliberate, is the oracle's frozen boundary,
  and is asserted in the differential test so a later change cannot move it
  quietly.

## Test impact

`test/unit/evaluator_test.ml` covers `fact(20)`, a hundred thousand Ash tail
calls in constant host stack, open recursion (a wrapped `eval` observing every
nested node in order rather than only the root, a wrapped `apply` intercepting
every application, and a replacement taking effect immediately), the exact step
and per-form dispatch counts of one application, counter reset, instrumentation
inertness, and the reflective forms with their honest refusals.

`test/differential/oracle_cps_test.ml` compares the oracle and the CPS evaluator
on 46 programs — values, mutation and evaluation order, and failures by cause and
span — plus the frozen-boundary divergences.

## Required spec or measurement changes

None. This record brings task 0.8 forward into §D3's requirement rather than
changing either.
