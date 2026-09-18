module Residue = Residue
module Metrics = Metrics
module Report = Report

let measure = Metrics.measure
let report ?depth ?budget ?show_residual ~file ~name program =
  Report.to_string ?show_residual (measure ?depth ?budget ~file ~name program)
