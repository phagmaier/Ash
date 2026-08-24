# A program with nothing unknown in it: every value the specializer needs is
# there, so the whole computation folds and the residual is the answer.
#
#   opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1
#
# The report's tower figures are what running this under one interposed
# interpreter costs; the residual is what is left after specialization.
fn fact(n) =
  if n == 0 then 1 else n * fact(n - 1)

fact(5)
