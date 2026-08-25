module Mode = Mode
module Value = Stage_value
module Emit = Emit
module Specialize = Specialize
module Store = Store
module Eval = Staged_eval

let eval = Staged_eval.eval
let run = Staged_eval.run
let fold = Staged_eval.fold

let is_static = Stage_value.is_static
let is_dynamic = Stage_value.is_dynamic
let is_purely_static = Stage_value.is_purely_static
let is_shape_static = Stage_value.is_shape_static
let may_fold = Stage_value.may_fold

let maybe_lift = Stage_value.maybe_lift
