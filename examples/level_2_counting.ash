# The §5.6 demo: level 2 counting the work level 1 does.
#
# This is the demo that makes the collapser necessary rather than merely nice.
#
# Two replacements, in this order and for a reason. The first makes level 1
# actually interpret level 0: until something replaces level 0's evaluator, level
# 0 runs natively and level 1 has no work to do at all. The second, installed
# from level 2, counts every step level 1 then takes.
#
# The two counters therefore measure different things at different levels:
# `program_steps` is how many steps this file takes, and `interpreter_steps` is
# how many steps the interpreter above it takes to run those. The ratio is the
# per-level cost of an unerased tower.

fn fib(n) = if n < 2 then n else fib(n - 1) + fib(n - 2)

var program_steps = 0
var interpreter_steps = 0

up {
  let base = eval
  eval := fn(e, r, k) -> {
    program_steps := program_steps + 1
    base(e, r, k)
  }
}

up {
  up {
    let base = eval
    eval := fn(e, r, k) -> {
      interpreter_steps := interpreter_steps + 1
      base(e, r, k)
    }
  }
}

let answer = fib(3)
[answer, program_steps, interpreter_steps]
