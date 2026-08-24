open Ash_core
open Ash_runtime

let by = "the staged evaluator"

let phase_of = function
  | Mode.Identity -> Error.Evaluate
  | Mode.Lift -> Error.Stage

let fail mode ~span ~level cause =
  Error.raise_cause ~phase:(phase_of mode) ~span ~level cause

let unsupported mode ~span ~level what =
  fail mode ~span ~level (Error.Unsupported { what; by })

let type_error mode ~span ~level ~expected value =
  fail mode ~span ~level
    (Error.Unexpected { found = Value.type_phrase value; expected })

let mode_tag = function
  | Mode.Identity -> Machine.Staged_identity
  | Mode.Lift -> Machine.Staged_lift

let mode_of_machine machine =
  match Machine.evaluator_mode machine with
  | Machine.Staged_identity -> Mode.Identity
  | Machine.Staged_lift -> Mode.Lift
  | Machine.Ground ->
      invalid_arg "Staged_eval.run: machine was not created by Staged_eval.machine"

let primitive_ident machine ~call_site primitive =
  let level = Machine.level machine in
  let matching_ident frame =
    Ident.Map.fold
      (fun ident cell found ->
        match (found, Value.cell_contents cell) with
        | Some _, _ -> found
        | None, Some (Value.Primitive candidate)
          when candidate == primitive ->
            Some ident
        | None, Some (Value.Primitive _) -> None
        | None, (None | Some (Value.Num _ | Value.Bool _ | Value.Str _
          | Value.Sym _ | Value.Unit | Value.List _ | Value.Closure _
          | Value.Reifier _ | Value.Continuation _ | Value.Environment _
          | Value.Cell _ | Value.Code _)) ->
            None)
      frame.Value.bindings None
  in
  (* Static aliases are eliminated, so use the outermost binding carrying this
     exact primitive value: that is the level's hygienic global identity. *)
  match List.find_map matching_ident (List.rev (Machine.global_env machine)) with
  | Some ident -> ident
  | None ->
      fail Mode.Lift ~span:call_site ~level
        (Error.Unbound_name primitive.Value.prim_name)

let shift_up mode machine ~exp ~env ~reifier k =
  let level = Machine.level machine in
  match Machine.above machine with
  | None ->
      unsupported mode ~span:(Core.span exp) ~level "reifier application"
  | Some upper ->
      let definition = reifier.Value.reif_def in
      let continuation = Value.continuation ~capture:(Core.span exp) ~level k in
      let meta =
        [
          (definition.Core.exp_param, Value.Code exp);
          (definition.Core.env_param, Value.Environment env);
          (definition.Core.cont_param, Value.Continuation continuation);
        ]
      in
      Machine.eval upper definition.Core.reifier_body
        (Env.extend meta reifier.Value.reif_env)
        (fun value -> value)

let reflect_down mode machine ~call_site ~code ~env ~cont k =
  let level = Machine.level machine in
  match Machine.below machine with
  | None ->
      fail mode ~span:call_site ~level
        (Error.Unsupported
           { what = "reflect"; by = "the base program, which has no level below it" })
  | Some lower ->
      Machine.eval lower code env (fun value ->
          Machine.apply machine ~call_site cont [ value ] k)

let meta_view mode machine ~call_site query =
  let level = Machine.level machine in
  let below what =
    match Machine.below machine with
    | Some lower -> lower
    | None ->
        fail mode ~span:call_site ~level
          (Error.Unsupported
             { what; by = "the base program, which has no level below it" })
  in
  match query with
  | Value.Below_eval_cell -> Value.Cell (Machine.meta_eval_cell (below "eval"))
  | Value.Below_apply_cell -> Value.Cell (Machine.meta_apply_cell (below "apply"))
  | Value.Below_global_env -> Value.Environment (Machine.global_env (below "global"))
  | Value.Tower_depth -> Value.Num (Machine.tower_depth machine)

let run_code mode machine ~call_site node k =
  let global = Machine.global_env machine in
  match Code.unresolved_dependencies ~available:(Env.idents global) node with
  | [] -> Machine.eval machine node global k
  | dependencies ->
      fail mode ~span:call_site ~level:(Machine.level machine)
        (Error.Open_code dependencies)

let apply_primitive mode machine ~call_site primitive arguments k =
  let given = List.length arguments in
  let level = Machine.level machine in
  let arity_error () =
    fail mode ~span:call_site ~level
      (Error.Arity_error
         {
           callee = Some primitive.Value.prim_name;
           expected = Value.arity_to_string primitive.Value.prim_arity;
           actual = given;
         })
  in
  if not (Value.arity_matches primitive.Value.prim_arity given) then
    arity_error ()
  else
    match mode with
    | Mode.Identity ->
        primitive.Value.prim_impl ~call_site ~level
          ~apply:(fun ~call_site callee args k ->
            Machine.apply machine ~call_site callee args k)
          ~lift:(fun ~call_site value -> Evaluator.lift_value machine ~call_site value)
          ~run:(fun ~call_site node k -> run_code mode machine ~call_site node k)
          ~reflect:(fun ~call_site ~code ~env ~cont k ->
            reflect_down mode machine ~call_site ~code ~env ~cont k)
          ~meta:(fun ~call_site query -> meta_view mode machine ~call_site query)
          arguments k
    | Mode.Lift -> (
        match primitive.Value.prim_class with
        | Effect_class.Pure ->
            if List.for_all Stage_value.is_purely_static arguments then
              primitive.Value.prim_impl ~call_site ~level
                ~apply:(fun ~call_site callee args k ->
                  Machine.apply machine ~call_site callee args k)
                ~lift:(fun ~call_site value ->
                  Evaluator.lift_value machine ~call_site value)
                ~run:(fun ~call_site node k -> run_code mode machine ~call_site node k)
                ~reflect:(fun ~call_site ~code ~env ~cont k ->
                  reflect_down mode machine ~call_site ~code ~env ~cont k)
                ~meta:(fun ~call_site query -> meta_view mode machine ~call_site query)
                arguments k
            else
              let args_code =
                List.map
                  (fun a -> Stage_value.lift_to_code ~call_site machine a)
                  arguments
              in
              let prim_ident = primitive_ident machine ~call_site primitive in
              let generated = Span.generated ~by:"stage/prim" ~from:call_site in
              let node =
                Core.app ~span:generated
                  ~func:(Core.var ~span:generated prim_ident)
                  ~args:args_code
              in
              let emitted =
                Emit.emit ~from:call_site ~name:primitive.Value.prim_name node
              in
              k (Value.Code emitted)
        | Effect_class.Allocation_or_mutation
        | Effect_class.Observable_effect
        | Effect_class.Control
        | Effect_class.Reflection ->
            let args_code =
              List.map
                (fun a -> Stage_value.lift_to_code ~call_site machine a)
                arguments
            in
            let prim_ident = primitive_ident machine ~call_site primitive in
            let generated = Span.generated ~by:"stage/residualize" ~from:call_site in
            let node =
              Core.app ~span:generated
                ~func:(Core.var ~span:generated prim_ident)
                ~args:args_code
            in
            let emitted =
              Emit.emit ~from:call_site ~name:primitive.Value.prim_name node
            in
            k (Value.Code emitted))

let rec reify_value machine ~call_site = function
  | Value.Code node -> node
  | Value.Closure { Value.clo_lambda; clo_env; clo_name = _ } ->
      let params = clo_lambda.Core.params in
      let generated = Span.generated ~by:"stage/lambda" ~from:call_site in
      let dynamic_params =
        List.map
          (fun param ->
            (param, Value.Code (Core.var ~span:generated param)))
          params
      in
      let body =
        reify_eval machine clo_lambda.Core.lam_body
          (Env.extend dynamic_params clo_env)
      in
      Core.lam ~span:generated ~params ~body
  | ( Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.List _ | Value.Reifier _ | Value.Continuation _
    | Value.Environment _ | Value.Cell _ | Value.Primitive _ ) as value ->
      Stage_value.lift_to_code ~call_site machine value

and reify_eval machine node env =
  Emit.reify_block (fun () ->
      let res = Machine.eval machine node env (fun value -> value) in
      reify_value machine ~call_site:(Core.span node) res)

let eval_default mode machine node env k =
  Machine.count_dispatch machine (Core.shape node);
  let span = Core.span node in
  let level = Machine.level machine in
  match Core.shape node with
  | Core.Lit constant -> k (Value.of_constant constant)
  | Core.Var ident ->
      k (Env.read_exn ~phase:(phase_of mode) ~span ~level env ident)
  | Core.NamedVar name ->
      Machine.count_named_var_lookup machine;
      k (Env.read_by_name_exn ~phase:(phase_of mode) ~span ~level env name)
  | Core.Lam lambda ->
      k (Value.Closure { Value.clo_lambda = lambda; clo_env = env; clo_name = None })
  | Core.Quote quoted ->
      (match mode with
      | Mode.Identity -> k (Value.Code quoted)
      | Mode.Lift -> k (Value.Code (Core.quote ~span quoted)))
  | Core.Reifier definition ->
      k (Value.Reifier { Value.reif_def = definition; reif_env = env; reif_name = None })
  | Core.If { Core.condition; consequent; alternative } ->
      Machine.eval machine condition env (fun value ->
          match value with
          | Value.Bool true -> Machine.eval machine consequent env k
          | Value.Bool false -> Machine.eval machine alternative env k
          | Value.Code cond_code when Mode.is_lift mode ->
              let t_code = reify_eval machine consequent env in
              let f_code = reify_eval machine alternative env in
              let generated = Span.generated ~by:"stage/if" ~from:span in
              let node =
                Core.if_ ~span:generated ~condition:cond_code
                  ~consequent:t_code ~alternative:f_code
              in
              let emitted = Emit.emit ~from:span node in
              k (Value.Code emitted)
          | ( Value.Num _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
            | Value.Closure _ | Value.Reifier _ | Value.Continuation _
            | Value.Environment _ | Value.Cell _ | Value.Code _
            | Value.Primitive _ ) as other ->
              type_error mode ~span:(Core.span condition) ~level
                ~expected:"a boolean" other)
  | Core.Let { Core.let_binder; let_value; let_body } ->
      Machine.eval machine let_value env (fun value ->
          match value with
          | Value.Code val_code when Mode.is_lift mode ->
              let dyn_var =
                Value.Code (Core.var ~span:(Core.span let_value) let_binder)
              in
              let body_code =
                reify_eval machine let_body (Env.bind let_binder dyn_var env)
              in
              let generated = Span.generated ~by:"stage/let" ~from:span in
              let node =
                Core.let_ ~span:generated ~binder:let_binder ~value:val_code
                  ~body:body_code
              in
              let emitted = Emit.emit ~from:span node in
              k (Value.Code emitted)
          | ( Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
            | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
            | Value.Environment _ | Value.Cell _ | Value.Code _
            | Value.Primitive _ ) as static_val ->
              Machine.eval machine let_body (Env.bind let_binder static_val env) k)
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      let inner =
        Env.preallocate (List.map (fun b -> b.Core.rec_name) rec_bindings) env
      in
      List.iter
        (fun binding ->
          Env.assign_exn ~phase:(phase_of mode) ~span:binding.Core.rec_span ~level
            inner binding.Core.rec_name
            (Value.Closure
               {
                 Value.clo_lambda = binding.Core.rec_lambda;
                 clo_env = inner;
                 clo_name = Some binding.Core.rec_name;
               }))
        rec_bindings;
      Machine.eval machine rec_body inner k
  | Core.Set { Core.set_target; set_value } ->
      (match mode with
      | Mode.Lift ->
          unsupported mode ~span ~level
            "set during specialization (store splitting is not implemented)"
      | Mode.Identity ->
          Machine.eval machine set_value env (fun value ->
              Env.assign_exn ~phase:(phase_of mode) ~span ~level env set_target value;
              k Value.Unit))
  | Core.App { Core.func; args } ->
      Machine.eval machine func env (fun callee ->
          match callee with
          | Value.Reifier reifier -> shift_up mode machine ~exp:node ~env ~reifier k
          | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
          | Value.List _ | Value.Closure _ | Value.Continuation _
          | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
              Machine.eval_list machine args env (fun arguments ->
                  Machine.apply machine ~call_site:span callee arguments k))

let eval_list_default _mode machine nodes env k =
  match nodes with
  | [] -> k []
  | node :: rest ->
      Machine.eval machine node env (fun value ->
          Machine.eval_list machine rest env (fun values -> k (value :: values)))

let apply_default mode machine ~call_site callee arguments k =
  let given = List.length arguments in
  let level = Machine.level machine in
  let arity_error ~callee_name ~expected =
    fail mode ~span:call_site ~level
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
      apply_primitive mode machine ~call_site primitive arguments k
  | Value.Code func_code when Mode.is_lift mode ->
      let args_code =
        List.map
          (fun a -> Stage_value.lift_to_code ~call_site machine a)
          arguments
      in
      let generated = Span.generated ~by:"stage/app" ~from:call_site in
      let node = Core.app ~span:generated ~func:func_code ~args:args_code in
      let emitted = Emit.emit ~from:call_site node in
      k (Value.Code emitted)
  | Value.Reifier _ ->
      unsupported mode ~span:call_site ~level "reifier application"
  | Value.Continuation continuation -> (
      match arguments with
      | [ value ] ->
          if Value.continuation_used continuation then
            fail mode ~span:call_site
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
            Value.mark_continuation_used continuation ~at:call_site;
            continuation.Value.cont_invoke value)
      | [] | _ :: _ :: _ ->
          arity_error ~callee_name:(Some "continuation") ~expected:"1")
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
  | Value.Environment _ | Value.Cell _ | Value.Code _ ->
      type_error mode ~span:call_site ~level ~expected:"a function" callee

let machine ?(mode = Mode.Identity) () =
  Machine.create
    ~evaluator_mode:(mode_tag mode)
    ~eval:(eval_default mode)
    ~apply:(apply_default mode)
    ~eval_list:(eval_list_default mode)
    ()

let run ?mode machine ~env node =
  let wired_mode = mode_of_machine machine in
  let mode = Option.value mode ~default:wired_mode in
  if not (Mode.equal mode wired_mode) then
    invalid_arg
      (Printf.sprintf
         "Staged_eval.run: requested %s mode on a machine wired for %s mode"
         (Mode.name mode) (Mode.name wired_mode));
  Machine.set_global_env machine env;
  match mode with
  | Mode.Identity ->
      Machine.eval machine node env (fun value -> value)
  | Mode.Lift ->
      let res_code = reify_eval machine node env in
      Value.Code res_code

let eval ?(mode = Mode.Identity) ~env node =
  run ~mode (machine ~mode ()) ~env node

let fold ~env node =
  match eval ~mode:Mode.Lift ~env node with
  | Value.Code node -> node
  | ( Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
    | Value.Environment _ | Value.Cell _ | Value.Primitive _ ) as static ->
      let m = machine ~mode:Mode.Lift () in
      Machine.set_global_env m env;
      Evaluator.lift_value m ~call_site:(Core.span node) static
