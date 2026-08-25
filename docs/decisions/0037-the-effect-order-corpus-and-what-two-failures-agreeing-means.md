# 0037 — The effect-order corpus, and what it means for two failures to agree

- Status: accepted
- Task: to-do 7.3
- Spec: §7.4 step 3, §8 Phase 7, §D1, §D7
- Extends ADR 0033 (the residual normalizer), ADR 0034 (depth results), ADR 0035
  (primitive effect policy) and ADR 0036 (static-store splitting)

## Context

Phase 6 closed with a claim about answers: a residual computes what the program
computes, at every depth from 0 to 5. Mutation and output make a sharper claim
available, and Phase 7's "done when" states it — *identical observable output
under `run(p)` and `run(collapse(n, p))`, and nothing printed during
compilation*. Tasks 7.1 and 7.2 built the machinery. What was missing was the
corpus that puts it under measurement: programs where the *order* of effects is
the thing that can be wrong.

Three questions had to be answered before such a corpus could be written down.

**How does a closed program contain something dynamic?** A residual that is a
function can only be compared by applying it, and what a tower run recorded
cannot be applied afterwards — the depth-invariance suite carries that
limitation explicitly. But a store test needs a conditional the specializer
cannot decide.

**How is a store compared across two runs?** It is not. Cells carry identity and
each run allocates its own (§D1); `Metrics.agreement` already answers
`Incomparable` for any value that carries identity, and a store is nothing but
such values.

**When do two runs fail the same way?** The pure corpus never had to answer
this, because every failure in it is one the specializer *decides*: it folds,
the specialization returns that error object, and comparing it against the
source run's compares an error with itself. A residualized failure is the first
one raised twice, by two different terms.

## Decision

### `deref(cell_new(v))` is how the corpus writes "dynamic"

The allocation primitives always residualize (ADR 0036 keeps the heap outside
the store's domain), so `deref(cell_new(v))` is a value the specializer cannot
see and every run reads as plainly `v`. A sample can therefore fork on a
condition the specializer must fork on, and still run to an answer two runs can
compare. This is a property of today's effect policy, not a trick: the day
allocation becomes static, these samples stop being dynamic and the corpus says
so by collapsing further, which is the right way for a boundary sample to
expire.

### The observable store is what the program reads back

Each sample states three parts: `setup` (statements run for what they do),
`answer` (the expression whose value is compared), and `store` (expressions
evaluated after `answer`). The harness composes them into one program whose
final expression is `[answer, store…]`, so a single run yields the value, the
final store, and the trace together, and a difference can still be reported as
whichever of the three it is.

This is not a weaker claim than comparing heaps would be. The reads are *in the
program*, so the specializer has to get them right along with everything else,
and a fold that moved a read across a write shows up as a wrong number. It is
also the only claim available: the alternative is comparing allocations across
runs, which §D1 forbids.

A failing sample has no store observation left to make, so the failing programs
are their own list.

### Two failures agree on cause and *source* location, not on provenance

`Metrics.agreement` compared `Span.equal`, which is structural equality
*including* provenance — the span module says in as many words that semantic
comparisons must not use it. For a folded failure the two spans are the same
object and the mistake is invisible. For a residualized failure they are not: a
residual node records the phase that emitted it (ADR 0033's provenance rule), so
the residual's `/` carries `stage/prim` over exactly the span the source run
reported, and the two runs were called different.

They are not different. They fail for the same reason at the same place in the
program the human wrote. Provenance is a fact about where a node came from, and
requiring it to match would mean *every* residualized failure is a disagreement
— that collapsing a program changed its meaning whenever the program can fail.
Agreement now compares `Span.source_span`, which strips generated layers and
leaves the human-written region.

This is the same kind of exclusion as AGENTS' invariant 10 (timing, host stack
depth, gensym counters): an observation that exists but is not part of what the
equivalence claims. It is scoped narrowly — the *site* is excluded from
provenance, not from comparison, and the cause still compares in full.

### A decided failure inside an undecided branch is a recorded boundary

```ash
var x = 0
let b = deref(cell_new(false))
if b then { println("yes"); x := 1 / 0 } else { println("no"); x := 7 }
x
```

The program answers 7. The specializer folds `1 / 0` while specializing the
branch it cannot decide, and that failure aborts the whole specialization: no
residual is produced for a program that runs perfectly well. Residualizing a
decided failure — emitting a term that raises it where it stood — is
error-and-control work no step of §7.4's fragment ordering owns.

The sample stays in the corpus as an asserted refusal rather than being dropped.
A corpus that quietly omitted it would stop reporting the limit on the day it
moved; asserting the refusal means whichever phase takes error residualization
on announces itself by failing this test.

## Consequences

- The measured claim of Phase 7 is now made, not merely enabled: at every depth
  from 0 to 5, the tower run and the normalized residual run of each sample
  agree on value, store, output and failure, and the specialization phase writes
  nothing to the program's stream.
- The collapse report stops printing `DIFFERS` for a correct residual whose
  program can fail. That was a reporting bug, visible from the CLI, that only a
  residualized failure could expose.
- Residuals are compared normalized, as task 6.4 compares them. That is what
  makes ADR 0033's store guard load-bearing rather than defensive: the guard
  only matters on a residual containing a `Set`, and this is the first corpus
  that produces one. Disabling the guard turns one sample's answer from 3 into
  4, and the test says so by name.
- `static_log` gains its first corpus sample, so §D7's compile-time channel is
  pinned as *not* program-visible output by a differential comparison rather
  than only by a unit test.

## Test impact

- `test/differential/corpus.ml`: three new lists — 15 effect-order samples, 3
  programs whose failure the residual raises, and 1 recorded boundary — plus the
  `effect_sample` record and the composition that turns one into a program.
- `test/laws/effect_order_test.ml`: new. Per depth 0–5 and per sample, three
  claims (the tower is transparent, the residual does what the tower did,
  specialization left no program output), residue cleanliness, normalizer
  idempotence on the actual residual, and one normalized residual across all
  depths. 324 checks over 19 programs.
- `test/differential/residual_test.ml`: the same programs against the *raw*
  fold, which is what says the specializer was already right before the
  normalizer touched it. 26 mutating programs, up from 8.
- Unchanged: the criterion suite's 73 samples and 250 residual nodes, the 417
  invariant and 18 depth-sensitive depth checks, every golden output.

## Required spec and measurement changes

- §8 Phase 7's status line records the corpus and closes the phase's "done when".
- §7.4 step 3 records what the corpus measures and the one boundary it names.
- No report metric changes meaning; one report *verdict* is corrected.
