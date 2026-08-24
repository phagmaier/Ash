open Ash_core

let by = "the ground evaluator"

(* Every error an evaluator raises belongs to the level whose machine raised it
   (spec §D9). The level is relative, so ordinary evaluation reports level 0 and
   a reifier body running one level up reports level 1. *)
let fail ~span ~level cause = Error.raise_cause ~phase:Error.Evaluate ~span ~level cause
let unsupported ~span ~level what = fail ~span ~level (Error.Unsupported { what; by })

let type_error ~span ~level ~expected value =
  fail ~span ~level (Error.Unexpected { found = Value.type_phrase value; expected })

(* The upward half of the tower protocol (spec §5.4). Level [n] suspends: the
   whole call expression, the caller's environment, and the caller's
   continuation become values, and the reifier's body runs on level [n + 1]'s
   machine, which the tower materializes on demand.

   The body keeps the lexical environment the reifier was written in, which
   belongs to level [n]: which machine evaluates a term does not change what its
   free identities mean. What does change is that replacing level [n + 1]'s
   evaluator cell intercepts the body, and replacing level [n]'s does not.

   The body runs under the identity continuation, so a reifier that never
   invokes the continuation it was handed does not return to level [n] at all:
   its value is the answer of the run. That is what "level n never resumes"
   means operationally, and [up] is the sugar that always resumes, because its
   expansion ends in [resume(cont, E)]. *)
let shift_up machine ~exp ~env ~reifier k =
  let level = Machine.level machine in
  match Machine.above machine with
  | None ->
      (* No tower is installed, so this machine is the base program and nothing
         else. Refusing names the missing level instead of materializing one the
         tower does not know about. *)
      unsupported ~span:(Core.span exp) ~level "reifier application"
  | Some upper ->
      let definition = reifier.Value.reif_def in
      (* The continuation belongs to level [n]: it resumes that machine's
         computation, and it is one-shot like every other (spec §D4). *)
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

(* The downward half (spec §5.4): [reflect] evaluates code on the level below
   the caller and transfers to a continuation captured there. The continuation
   is applied through this level's applier, because invoking a lower level's
   continuation is work this level does — and it is the same one-shot check any
   other application performs. *)
let reflect_down machine ~call_site ~code ~env ~cont k =
  let level = Machine.level machine in
  match Machine.below machine with
  | None ->
      fail ~span:call_site ~level
        (Error.Unsupported
           { what = "reflect"; by = "the base program, which has no level below it" })
  | Some lower ->
      Machine.eval lower code env (fun value ->
          Machine.apply machine ~call_site cont [ value ] k)

(* The upward half's questions, as opposed to its transfer (spec §5.2). [up]
   binds [eval], [apply], and [global] to things that belong to the level below
   the one its body runs at, and [tower_depth()] to a fact about the tower. A
   primitive cannot find any of them: the registry is shared by every level
   (ADR 0017), so only the applying machine knows which level it is. *)
let meta_view machine ~call_site query =
  let level = Machine.level machine in
  let below what =
    match Machine.below machine with
    | Some lower -> lower
    | None ->
        fail ~span:call_site ~level
          (Error.Unsupported
             { what; by = "the base program, which has no level below it" })
  in
  match query with
  | Value.Below_eval_cell -> Value.Cell (Machine.meta_eval_cell (below "eval"))
  | Value.Below_apply_cell -> Value.Cell (Machine.meta_apply_cell (below "apply"))
  | Value.Below_global_env -> Value.Environment (Machine.global_env (below "global"))
  | Value.Tower_depth -> Value.Num (Machine.tower_depth machine)

(* Every recursive call below goes through [Machine], never directly to one of
   these functions: that is what makes a replaced cell intercept the next step
   rather than the next top-level evaluation. *)

let eval_default machine node env k =
  Machine.count_dispatch machine (Core.shape node);
  let span = Core.span node in
  let level = Machine.level machine in
  match Core.shape node with
  | Core.Lit constant -> k (Value.of_constant constant)
  | Core.Var ident -> k (Env.read_exn ~phase:Error.Evaluate ~span ~level env ident)
  | Core.NamedVar name ->
      (* Resolution by printed name is what the collapse report counts as
         surviving reflection, so it is counted from the first step. *)
      Machine.count_named_var_lookup machine;
      k (Env.read_by_name_exn ~phase:Error.Evaluate ~span ~level env name)
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
              type_error ~span:(Core.span condition) ~level ~expected:"a boolean" other)
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
          Env.assign_exn ~phase:Error.Evaluate ~span:binding.Core.rec_span ~level inner
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
          Env.assign_exn ~phase:Error.Evaluate ~span ~level env set_target value;
          k Value.Unit)
  | Core.App { Core.func; args } ->
      Machine.eval machine func env (fun callee ->
          match callee with
          (* Whole-call reification: a reifier's arguments are not evaluated, so
             the decision belongs here rather than in [apply], which sees values
             and no call expression (spec §5.4, locked decision). *)
          | Value.Reifier reifier -> shift_up machine ~exp:node ~env ~reifier k
          | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
          | Value.List _ | Value.Closure _ | Value.Continuation _
          | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
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

let run_code machine ~call_site node k =
  let global = Machine.global_env machine in
  match Code.unresolved_dependencies ~available:(Env.idents global) node with
  | [] -> Machine.eval machine node global k
  | dependencies ->
      fail ~span:call_site ~level:(Machine.level machine) (Error.Open_code dependencies)

let lift_value machine ~call_site value =
  let generated = Span.generated ~by:"lift" ~from:call_site in
  let level = Machine.level machine in
  let rec lift path value =
    match value with
    | Value.Num number -> Core.lit ~span:generated (Constant.Num number)
    | Value.Bool boolean -> Core.lit ~span:generated (Constant.Bool boolean)
    | Value.Str string -> Core.lit ~span:generated (Constant.Str string)
    | Value.Sym symbol -> Core.lit ~span:generated (Constant.Sym symbol)
    | Value.Unit -> Core.lit ~span:generated Constant.Unit
    | Value.List [] -> Core.lit ~span:generated Constant.Nil
    | Value.List items ->
        let list_ident, _ =
          Env.lookup_by_name_exn ~phase:Error.Evaluate ~span:call_site ~level
            (Machine.global_env machine) "list"
        in
        let arguments =
          List.mapi (fun index item -> lift ((index + 1) :: path) item) items
        in
        Core.app ~span:generated
          ~func:(Core.var ~span:generated list_ident)
          ~args:arguments
    | Value.Code node -> node
    | ( Value.Closure _ | Value.Reifier _ | Value.Continuation _
      | Value.Environment _ | Value.Cell _ | Value.Primitive _ ) as rejected ->
        fail ~span:call_site ~level
          (Error.Unliftable_value
             {
               found = Value.type_phrase rejected;
               value = Value.to_string rejected;
               path = List.rev path;
             })
  in
  lift [] value

let apply_default machine ~call_site callee arguments k =
  let given = List.length arguments in
  let level = Machine.level machine in
  let arity_error ~callee_name ~expected =
    fail ~span:call_site ~level
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
        primitive.Value.prim_impl ~call_site ~level
          ~apply:(fun ~call_site callee arguments k ->
            Machine.apply machine ~call_site callee arguments k)
          ~lift:(fun ~call_site value -> lift_value machine ~call_site value)
          ~run:(fun ~call_site node k -> run_code machine ~call_site node k)
          ~reflect:(fun ~call_site ~code ~env ~cont k ->
            reflect_down machine ~call_site ~code ~env ~cont k)
          ~meta:(fun ~call_site query -> meta_view machine ~call_site query)
          arguments k
  | Value.Reifier _ ->
      (* Reification needs the unevaluated call expression, which [eval] has and
         an applier does not: this path is reached only when something applies a
         reifier to values that are already computed, such as [invoke]. There is
         no whole call to hand one level up, so it is refused rather than
         approximated. *)
      unsupported ~span:call_site ~level "reifier application"
  | Value.Continuation continuation -> (
      match arguments with
      | [ value ] ->
          if Value.continuation_used continuation then
            (* One-shot is enforced dynamically (§D4), and the report names both
               sites: where the continuation came from and where it already
               went. Neither alone explains the mistake. *)
            fail ~span:call_site
              (* The level whose control was corrupted, which is where the
                 continuation came from rather than where it was misused. *)
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
      type_error ~span:call_site ~level ~expected:"a function" callee

let machine () =
  Machine.create ~eval:eval_default ~apply:apply_default ~eval_list:eval_list_default

let run machine ~env node =
  Machine.set_global_env machine env;
  Machine.eval machine node env (fun value -> value)
let eval ~env node = run (machine ()) ~env node
