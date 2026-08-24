(** Collapse measurement and reporting (spec §9).

    - {!Residue}: what interpretation is left in a residual program.
    - {!Metrics}: one measurement — source run, tower run, specialization, and
      residual run.
    - {!Report}: the human report of §9.4, rendered once and used by both the
      CLI and the golden test. *)

module Residue = Residue
module Metrics = Metrics
module Report = Report

val measure :
  ?depth:int ->
  ?budget:Ash_stage.Specialize.budget ->
  file:string ->
  name:string ->
  Metrics.program ->
  Metrics.t

val report :
  ?depth:int ->
  ?budget:Ash_stage.Specialize.budget ->
  file:string ->
  name:string ->
  Metrics.program ->
  string
(** {!measure} rendered by {!Report.to_string}. *)
