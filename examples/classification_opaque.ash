let trace = deref(cell_new(true))
meta_with(eval = if trace then fn(e, r, k) -> { println('trace); eval(e, r, k) } else eval) { 1 + 2 }
