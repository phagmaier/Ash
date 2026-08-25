# Examples

Executable Ash programs and milestone demonstrations. Each one is embedded into
`ash.examples` by the rule in `dune`, so the CLI and the golden test run the
same source this directory holds and neither can drift from it.

Run one:

```sh
opam exec -- dune exec ash -- --demos            # list them
opam exec -- dune exec ash -- --demo tracing
opam exec -- dune exec ash -- --demo level-2-counting
```

What each prints is stored in `test/golden/demos.expected` and compared by
`dune runtest`, so these are research evidence rather than illustrations.

| File | What it shows |
|------|---------------|
| `tracing.ash` | Spec §5.3. A program reaches up and replaces the evaluator running it, mid-flight. The trace has one line per evaluated Core node: if open recursion (§D3) regressed, it would print a handful of lines and still return the right answer. |
| `fact.ash` | The collapse report's sample program (spec §9.4). Nothing in it is unknown, so it folds to its answer: `--collapse` prints what the tower costs beside what the residual costs. |
| `depth.ash` | The depth-sensitive shape (task 6.4, spec §9.3's second class). It reads `tower_depth()`, so its residual differs per depth: specialized at depth n, the reading folds to n, and the residual run matches what the depth-n tower did — while the ground source run says 0, which the report states honestly as a difference. |
| `level_2_counting.ash` | Spec §5.6. Level 1 is made to interpret level 0, and level 2 then counts the work level 1 does. The ratio between the two counters is the per-level cost of a tower nobody has collapsed — the measurement Phase 5 exists to reduce. |

`fact.ash` is not a demo — it is an ordinary program, run with:

```sh
opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1
```

Depth measurements for the same machinery are in
`docs/progress/0001-depth-cost.md`, and the report reproduces them.
