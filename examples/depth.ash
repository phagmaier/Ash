# Depth-sensitive collapse sample (task 6.4).
#
# The one program shape whose residual may differ across tower depths: it
# observes the depth it runs at, which is §D9's deliberate opt-in. Specialized
# at depth n, the reading folds to n; specialized at depth 1, to 1. Each
# residual is correct for its own depth — what the depth-n tower reports is
# what the residual specialized at depth n computes.
fn(x) -> x + tower_depth()

tower_depth()
