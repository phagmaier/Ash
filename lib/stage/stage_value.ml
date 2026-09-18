open Ash_core
open Ash_runtime

(* [Value.Code] serves two roles during specialization: residual syntax whose
   runtime value is unknown, and syntax handed to a statically known evaluator
   wrapper as its [e] argument.  Phase 9 needs to keep those apart without
   widening Core's runtime value domain.  Known syntax is recorded by physical
   node identity for one specialization run. *)
let static_codes = ref []

let reset_static_codes () = static_codes := []

let is_static_code node = List.exists (fun known -> known == node) !static_codes

let static_code node =
  if not (is_static_code node) then static_codes := node :: !static_codes;
  Value.Code node

let rec record_static_codes = function
  | Value.Code node -> static_code node
  | Value.List items -> Value.List (List.map record_static_codes items)
  | ( Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.Closure _ | Value.Reifier _ | Value.Continuation _
    | Value.Environment _ | Value.Cell _ | Value.Primitive _ ) as value ->
      value

let is_dynamic = function
  | Value.Code node -> not (is_static_code node)
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
  | Value.Code node -> is_static_code node

(* A value whose own constructor is known at specialization time. Unrecorded
   [Code] fails this because it stands for a value the residual program will
   compute; evaluator syntax registered by [static_code] passes. A list passes
   even when its elements are dynamic, which is exactly the partially static
   data the pure fragment needs. *)
let is_shape_static value = not (is_dynamic value)

let observation_satisfied observed value =
  match observed with
  | Observation.Unobserved -> true
  | Observation.Shape_only -> is_shape_static value
  | Observation.Whole_value -> is_purely_static value

(* Folding a primitive during specialization is sound when its class permits it
   at all and nothing it actually inspects is dynamic. Arguments it merely
   carries into its result may be dynamic: [cons] does not look at the value it
   conses, and [list] looks at none of its arguments. *)
let may_fold primitive arguments =
  Effect_class.may_fold_when_static primitive.Value.prim_class
  &&
  let signature = primitive.Value.prim_observes in
  let rec every index = function
    | [] -> true
    | argument :: rest ->
        observation_satisfied (Observation.at signature index) argument
        && every (index + 1) rest
  in
  every 0 arguments

let dynamic_code = function
  | Value.Code node when not (is_static_code node) -> Some node
  | Value.Code _ -> None
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
  | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
      None

let lift_to_code ~call_site machine = function
  | Value.Code node when is_static_code node -> Core.quote ~span:call_site node
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
      | Value.Code node when not (is_static_code node) -> value
      | Value.Code _
      | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
      | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
      | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
          Value.Code (lift_to_code ~call_site machine value))
