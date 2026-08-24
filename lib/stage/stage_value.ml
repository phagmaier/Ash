open Ash_core
open Ash_runtime

let is_dynamic = function
  | Value.Code _ -> true
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
  | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
      false

let is_static value = not (is_dynamic value)

let static_value = is_static

let rec is_purely_static = function
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit -> true
  | Value.List items -> List.for_all is_purely_static items
  | Value.Closure _ | Value.Reifier _ | Value.Continuation _
  | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
      true
  | Value.Code _ -> false

let dynamic_code = function
  | Value.Code node -> Some node
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
  | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
      None

let lift_to_code ~call_site machine = function
  | Value.Code node -> node
  | ( Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
    | Value.Environment _ | Value.Cell _ | Value.Primitive _ ) as static ->
      Evaluator.lift_value machine ~call_site static

let maybe_lift ~mode ~call_site machine value =
  match mode with
  | Mode.Identity -> value
  | Mode.Lift -> (
      match value with
      | Value.Code _ -> value
      | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
      | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
      | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
          Value.Code (lift_to_code ~call_site machine value))
