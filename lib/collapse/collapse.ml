module Residue = Residue
module Metrics = Metrics
module Report = Report

let measure = Metrics.measure
let report ?depth ?budget ~file ~name program =
  Report.to_string (measure ?depth ?budget ~file ~name program)
