let folded = 40 + 2
let trace = deref(cell_new(true))
[folded, meta_with(eval = if trace then fn(e, r, k) -> { println('trace); eval(e, r, k) } else eval) { 1 + 2 }]
