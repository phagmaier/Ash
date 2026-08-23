open Ash_core

let by = "the ground evaluator"
let fail ~span ?level cause = Error.raise_cause ~phase:Error.Evaluate ~span ?level cause
let unsupported ~span what = fail ~span (Error.Unsupported { what; by })

let type_error ~span ~expected value =
  fail ~span (Error.Unexpected { found = Value.type_phrase value; expected })

(* Every recursive call below goes through [Machine], never directly to one of
   these functions: that is what makes a replaced cell intercept the next step
   rather than the next top-level evaluation. *)

let eval_default machine node env k =
  Machine.count_dispatch machine (Core.shape node);
  let span = Core.span node in
  match Core.shape node with
  | Core.Lit constant -> k (Value.of_constant constant)
  | Core.Var ident -> k (Env.read_exn ~phase:Error.Evaluate ~span env ident)
  | Core.NamedVar name ->
      (* Resolution by printed name is what the collapse report counts as
         surviving reflection, so it is counted from the first step. *)
      Machine.count_named_var_lookup machine;
      k (Env.read_by_name_exn ~phase:Error.Evaluate ~span env name)
  | Core.Lam lambda ->
      k (Value.Closure { Value.clo_lambda = lambda; clo_env = env; clo_name = None })
  | Core.Quote quoted -> k (Value.Code quoted)
  | Core.Reifier definition ->
      k (Value.Reifier { Value.reif_def = definition; reif_env = env; reif_name = None })
  | Core.If { Core.condition; consequent; alternative } ->
      Machine.eval machine condition env (fun value ->
          match value with
          | Value.Bool true -> Machine.eval machine consequent env k
          | Value.Bool false -> Machine.eval machine alternative env k
          | (Value.Num _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
            | Value.Closure _ | Value.Reifier _ | Value.Continuation _
            | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _) as
            other ->
              type_error ~span:(Core.span condition) ~expected:"a boolean" other)
  | Core.Let { Core.let_binder; let_value; let_body } ->
      Machine.eval machine let_value env (fun value ->
          Machine.eval machine let_body (Env.bind let_binder value env) k)
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      (* Allocate every cell, then fill them with closures over the extended
         environment. Evaluating a lambda calls nothing, so no cell can be
         observed while it is still empty. *)
      let inner =
        Env.preallocate (List.map (fun b -> b.Core.rec_name) rec_bindings) env
      in
      List.iter
        (fun binding ->
          Env.assign_exn ~phase:Error.Evaluate ~span:binding.Core.rec_span inner
            binding.Core.rec_name
            (Value.Closure
               {
                 Value.clo_lambda = binding.Core.rec_lambda;
                 clo_env = inner;
                 clo_name = Some binding.Core.rec_name;
               }))
        rec_bindings;
      Machine.eval machine rec_body inner k
  | Core.Set { Core.set_target; set_value } ->
      Machine.eval machine set_value env (fun value ->
          Env.assign_exn ~phase:Error.Evaluate ~span env set_target value;
          k Value.Unit)
  | Core.App { Core.func; args } ->
      Machine.eval machine func env (fun callee ->
          Machine.eval_list machine args env (fun arguments ->
              Machine.apply machine ~call_site:span callee arguments k))

(* Left to right, and the tail of the list is evaluated inside the continuation
   of its head, so evaluation order is the same whether or not an argument
   captures control. *)
let eval_list_default machine nodes env k =
  match nodes with
  | [] -> k []
  | node :: rest ->
      Machine.eval machine node env (fun value ->
          Machine.eval_list machine rest env (fun values -> k (value :: values)))

let apply_default machine ~call_site callee arguments k =
  let given = List.length arguments in
  let arity_error ~callee_name ~expected =
    fail ~span:call_site
      (Error.Arity_error { callee = callee_name; expected; actual = given })
  in
  match callee with
  | Value.Closure { Value.clo_lambda; clo_env; clo_name } ->
      let params = clo_lambda.Core.params in
      if List.compare_lengths params arguments <> 0 then
        arity_error
          ~callee_name:(Option.map Ident.name clo_name)
          ~expected:(string_of_int (List.length params))
      else
        Machine.eval machine clo_lambda.Core.lam_body
          (Env.extend (List.combine params arguments) clo_env)
          k
  | Value.Primitive primitive ->
      if not (Value.arity_matches primitive.Value.prim_arity given) then
        arity_error
          ~callee_name:(Some primitive.Value.prim_name)
          ~expected:(Value.arity_to_string primitive.Value.prim_arity)
      else
        (* The real continuation, not the identity one: that is what lets a
           control primitive do something other than return. [apply] goes back
           through the machine cell, so a primitive calling an Ash function is
           as interceptable as any other call (§D3). *)
        primitive.Value.prim_impl ~call_site
          ~apply:(fun ~call_site callee arguments k ->
            Machine.apply machine ~call_site callee arguments k)
          arguments k
  | Value.Reifier _ ->
      (* Applying a reifier runs one level up with the caller's expression,
         environment, and continuation. There is no level above yet. *)
      unsupported ~span:call_site "reifier application"
  | Value.Continuation continuation -> (
      match arguments with
      | [ value ] ->
          if Value.continuation_used continuation then
            (* One-shot is enforced dynamically (§D4), and the report names both
               sites: where the continuation came from and where it already
               went. Neither alone explains the mistake. *)
            fail ~span:call_site
              ~level:(Value.continuation_level continuation)
              (Error.Continuation_reuse
                 {
                   captured = Value.continuation_capture_site continuation;
                   first_used =
                     (match Value.continuation_first_use continuation with
                     | Some site -> site
                     | None -> Value.continuation_capture_site continuation);
                 })
          else (
            (* Marked before the transfer, so a continuation that invokes itself
               is caught by the same check rather than looping. *)
            Value.mark_continuation_used continuation ~at:call_site;
            continuation.Value.cont_invoke value)
      | [] | _ :: _ :: _ ->
          arity_error ~callee_name:(Some "continuation") ~expected:"1")
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
  | Value.Environment _ | Value.Cell _ | Value.Code _ ->
      type_error ~span:call_site ~expected:"a function" callee

let machine () =
  Machine.create ~eval:eval_default ~apply:apply_default ~eval_list:eval_list_default

let run machine ~env node = Machine.eval machine node env (fun value -> value)
let eval ~env node = run (machine ()) ~env node
