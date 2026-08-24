# The §5.3 demo: a program reaches up and rewrites the machine underneath itself.
#
# `up { … }` suspends this level and runs its body one level up. There, `eval`
# is the cell holding *this* level's evaluator, so assigning to it replaces the
# evaluator that is running this very file, mid-flight.
#
# Nothing about `fib` changes. It is written, and stays, an ordinary function.
#
# The trace prints one line per evaluated Core node. That it prints many lines
# rather than one is the open-recursion invariant (§D3): every recursive step of
# the evaluator goes through the cell, so a replacement intercepts all of them
# and not just the outermost.

fn fib(n) = if n < 2 then n else fib(n - 1) + fib(n - 2)

up {
  let base = eval
  eval := fn(e, r, k) -> {
    println(head(code_view(e)))
    base(e, r, k)
  }
}

fib(3)
