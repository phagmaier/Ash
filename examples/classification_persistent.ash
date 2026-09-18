let trace = deref(cell_new(true))
if trace then up { let base = eval; eval := fn(e, r, k) -> { println('trace); base(e, r, k) } } else ()
1 + 2
