# Phase 9: traced Fibonacci after collapse

Reproduce the complete artifact from the repository root:

```sh
opam exec -- dune exec ash -- --collapse examples/traced_fibonacci.ash --depth 1 --show-residual
```

- Source: [`examples/traced_fibonacci.ash`](../../examples/traced_fibonacci.ash).
  The `deref(cell_new(3))` read makes the input unknown to the specializer, so
  recursive Fibonacci remains in the residual. The evaluator wrapper is a
  statically known persistent `up` replacement that prints each Core node kind.
- Canonical residual Core and full report:
  [`test/golden/traced_fibonacci.expected`](../../test/golden/traced_fibonacci.expected).
  This file is exactly the command's stdout. Its `Residual Core` section has a
  residual `letrec` for Fibonacci and `println` calls in the recursive body.
- Expected program output: the `Tower output bytes` and `Residual output bytes`
  lines in that golden are the same exact escaped 59-line byte string. To see
  the unescaped trace, run
  `opam exec -- dune exec ash -- --demo traced-fibonacci`; its output is also
  pinned in [`test/golden/demos.expected`](../../test/golden/demos.expected).
- Executable acceptance check:
  [`test/golden/traced_fibonacci_golden.ml`](../../test/golden/traced_fibonacci_golden.ml).
  It verifies value and event agreement, exact output bytes, no program output
  during specialization, a recursive residual with inlined print calls, a
  readable Core round trip, and zero evaluator dereferences, dispatch sites,
  calls, reflective lookups, boundaries, or foreign-origin interpreter nodes.

The depth-1 tower returns `2` after 2,598 evaluator-group calls; the residual
returns `2` after 582. The 251-node residual has one specialization point for
runtime recursion and zero interpreter residue. These are counted operations,
not timing measurements. The report's ground `Source` baseline fails at `up`
because it has no upper level; `Tower vs residual: agrees` is the semantic
comparison for this reflective program.
