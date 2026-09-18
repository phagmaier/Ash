# Phase 9: the reflective tracing evaluator collapses into an ordinary fib.
#
#   opam exec -- dune exec ash -- --collapse examples/traced_fibonacci.ash --depth 1 --show-residual
#
# The input is a runtime cell read, so specialization cannot precompute fib(3).
# The residual retains recursive Fibonacci with trace calls at its former eval
# sites. The cell read happens before the evaluator is replaced; the trace then
# shows every Core node evaluated by fib itself.

fn fib(n) = if n < 2 then n else fib(n - 1) + fib(n - 2)

let input = deref(cell_new(3))

up {
  let base = eval
  eval := fn(e, r, k) -> {
    println(head(code_view(e)))
    base(e, r, k)
  }
}

fib(input)
