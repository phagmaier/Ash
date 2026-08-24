open Ash_core

let by = "the direct-style oracle"
let fail ~span cause = Error.raise_cause ~phase:Error.Evaluate ~span cause
let unsupported ~span what = fail ~span (Error.Unsupported { what; by })

let type_error ~span ~expected value =
  fail ~span (Error.Unexpected { found = Value.type_phrase value; expected })

let arity_error ~span ~callee ~expected ~actual =
  fail ~span (Error.Arity_error { callee; expected; actual })

let rec eval env node =
  let span = Core.span node in
  match Core.shape node with
  | Core.Lit constant -> Value.of_constant constant
  | Core.Var ident -> Env.read_exn ~phase:Error.Evaluate ~span env ident
  | Core.NamedVar name ->
      (* Resolving a variable by name against a first-class environment is what
         reflective code does; ordinary compiled code never produces it. *)
      unsupported ~span ("named-var " ^ name)
  | Core.Lam lambda ->
      Value.Closure { Value.clo_lambda = lambda; clo_env = env; clo_name = None }
  | Core.App { Core.func; args } ->
      let callee = eval env func in
      let arguments = eval_list env args in
      apply ~span callee arguments
  | Core.Let { Core.let_binder; let_value; let_body } ->
      let value = eval env let_value in
      eval (Env.bind let_binder value env) let_body
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      (* Allocate every cell first, then fill them with closures over the
         extended environment: that is what makes the group mutually recursive,
         and evaluating a lambda cannot observe a cell that is still empty. *)
      let inner =
        Env.preallocate (List.map (fun b -> b.Core.rec_name) rec_bindings) env
      in
      List.iter
        (fun binding ->
          let closure =
            Value.Closure
              {
                Value.clo_lambda = binding.Core.rec_lambda;
                clo_env = inner;
                clo_name = Some binding.Core.rec_name;
              }
          in
          Env.assign_exn ~phase:Error.Evaluate ~span:binding.Core.rec_span inner
            binding.Core.rec_name closure)
        rec_bindings;
      eval inner rec_body
  | Core.If { Core.condition; consequent; alternative } -> (
      match eval env condition with
      | Value.Bool true -> eval env consequent
      | Value.Bool false -> eval env alternative
      (* No truthiness coercion: a condition is a boolean or it is a mistake. *)
      | (Value.Num _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
        | Value.Closure _ | Value.Reifier _ | Value.Continuation _
        | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _) as other
        ->
          type_error ~span:(Core.span condition) ~expected:"a boolean" other)
  | Core.Set { Core.set_target; set_value } ->
      let value = eval env set_value in
      Env.assign_exn ~phase:Error.Evaluate ~span env set_target value;
      Value.Unit
  | Core.Quote _ -> unsupported ~span "quote"
  | Core.Reifier _ -> unsupported ~span "reifier"

(* Left to right, forced by the let rather than left to the host's argument
   evaluation order, because the order is observable through effects and through
   which of two bad arguments is reported. *)
and eval_list env = function
  | [] -> []
  | node :: rest ->
      let value = eval env node in
      value :: eval_list env rest

and apply ~span callee arguments =
  let given = List.length arguments in
  match callee with
  | Value.Closure { Value.clo_lambda; clo_env; clo_name } ->
      let params = clo_lambda.Core.params in
      if List.compare_lengths params arguments <> 0 then
        arity_error ~span
          ~callee:(Option.map Ident.name clo_name)
          ~expected:(string_of_int (List.length params))
          ~actual:given
      else
        eval
          (Env.extend (List.combine params arguments) clo_env)
          clo_lambda.Core.lam_body
  | Value.Primitive primitive ->
      if not (Effect_class.equal primitive.Value.prim_class Effect_class.Pure) then
        (* Folding an effect at oracle time would move it out of the program,
           which is the mistake D7 exists to prevent. *)
        unsupported ~span primitive.Value.prim_name
      else if not (Value.arity_matches primitive.Value.prim_arity given) then
        arity_error ~span
          ~callee:(Some primitive.Value.prim_name)
          ~expected:(Value.arity_to_string primitive.Value.prim_arity)
          ~actual:given
      else
        (* A pure primitive invokes its continuation exactly once in tail
           position, so the identity continuation returns its result. The
           applier is the direct-style [apply] read as CPS; no pure primitive
           calls it, and passing one that raised would be a lie about what this
           evaluator does rather than a restriction it enforces.

           The oracle evaluates the base program and nothing else, so its level
           is 0 and there is no level below it to reflect into. *)
        primitive.Value.prim_impl ~call_site:span ~level:0
          ~apply:(fun ~call_site callee arguments k ->
            k (apply ~span:call_site callee arguments))
          ~lift:(fun ~call_site _ -> unsupported ~span:call_site "lift")
          ~run:(fun ~call_site _ _ -> unsupported ~span:call_site "run")
          ~reflect:(fun ~call_site ~code:_ ~env:_ ~cont:_ _ ->
            unsupported ~span:call_site "reflect")
          arguments
          (fun value -> value)
  | Value.Reifier _ -> unsupported ~span "reifier"
  | Value.Continuation _ -> unsupported ~span "continuation"
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
  | Value.Environment _ | Value.Cell _ | Value.Code _ ->
      type_error ~span ~expected:"a function" callee

let eval ~env node = eval env node
