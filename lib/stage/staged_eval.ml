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

(* Handing this level's environment to the level above, or to the level below,
   ends the specializer's exclusive claim on everything in it. {!Store.holdable}
   already refuses any scope that {e builds} a reifier, so a held binding cannot
   reach here from the fragment the store proves; a reifier inherited from
   outside that scope can, and refusing is the honest answer — the level above
   may write the cell, and a value already folded from it cannot be taken back. *)
let across_levels mode machine ~span what =
  if Mode.is_lift mode && Store.holds_static () then
    unsupported mode ~span ~level:(Machine.level machine)
      (what ^ " while the abstract store holds a binding")

let shift_up mode machine ~exp ~env ~reifier k =
  let level = Machine.level machine in
  match Machine.above machine with
  | None ->
      unsupported mode ~span:(Core.span exp) ~level "reifier application"
  | Some upper ->
      across_levels mode machine ~span:(Core.span exp) "reifier application";
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
      across_levels mode machine ~span:call_site "reflect";
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

(* The level's own [list] binding, found in the globals the way [lift] finds it,
   so a shadowing local binding cannot capture the spine a residual rebuild
   depends on. *)
let list_ident machine ~call_site =
  fst
    (Env.lookup_by_name_exn ~phase:Error.Stage ~span:call_site
       ~level:(Machine.level machine) (Machine.global_env machine) "list")

(* The binder a residual expression stands for, when it stands for one at all.
   Only a variable names a place the residual program can assign to; anything
   else is a computation, and a store binding on it would have nowhere to
   write. *)
let residual_target node =
  match Core.shape node with
  | Core.Var ident -> Some ident
  | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
  | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
      None

(* Making a static value dynamic at a stage boundary.

   This is not the [lift] primitive: [lift] has the fixed domain of §D6 and
   refuses a closure, because serializing one is not something a program may
   ask for. The specializer is in a different position — it holds the closure's
   syntax and environment — so a closure crossing into residual code has its
   lambda reified and its body specialized under dynamic parameters, which is
   what makes the higher-order fragment stage at all. Everything the lift domain
   does accept is still converted by [lift] itself, so the two agree wherever
   both apply. *)
let rec reify_value machine ~call_site value =
  match value with
  | Value.Code node -> node
  | Value.Closure { Value.clo_lambda; clo_env; clo_name } ->
      (* Reifying a closure specializes its body, and a closure that reaches a
         dynamic position inside its own reified body would do that forever.
         There is no call here to key and no argument to generalize, so the
         depth budget is the only thing that can stop it — and saying so is
         better than diverging. *)
      let limit = (Specialize.budget ()).Specialize.max_inline_depth in
      if Specialize.reification_depth () >= limit then
        fail Mode.Lift ~span:call_site ~level:(Machine.level machine)
          (Error.Budget_exhausted
             {
               what = "reification-depth";
               limit;
               callee = Option.map Ident.name clo_name;
             });
      let params = clo_lambda.Core.params in
      let generated = Span.generated ~by:"stage/lambda" ~from:call_site in
      let dynamic_params =
        List.map
          (fun param -> (param, Value.Code (Core.var ~span:generated param)))
          params
      in
      let inner = Env.extend dynamic_params clo_env in
      let tracked = track_parameters machine ~call_site ~lambda:clo_lambda ~env:inner params in
      let body =
        Specialize.with_reification (fun () ->
            reify_eval machine clo_lambda.Core.lam_body inner)
      in
      List.iter Store.release tracked;
      Core.lam ~span:generated ~params ~body
  | Value.List (_ :: _ as items) ->
      (* A spine the specializer knows, carrying elements it may not: rebuild the
         spine in the residual program and reify each element in turn. Fully
         static lists reach the same [list] call [lift] would have built. *)
      let generated = Span.generated ~by:"stage/list" ~from:call_site in
      Core.app ~span:generated
        ~func:(Core.var ~span:generated (list_ident machine ~call_site))
        ~args:(List.map (fun item -> reify_value machine ~call_site item) items)
  | ( Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.List [] | Value.Reifier _ | Value.Continuation _
    | Value.Environment _ | Value.Cell _ | Value.Primitive _ ) as value ->
      Stage_value.lift_to_code ~call_site machine value

and reify_eval machine node env =
  Specialize.in_scope (fun () ->
      Emit.reify_block (fun () ->
          let res = Machine.eval machine node env (fun value -> value) in
          reify_value machine ~call_site:(Core.span node) res))

(* Who owns a parameter's cell: the same question a [Let] asks, asked where a
   call binds its arguments. Only parameters the term assigns are considered, so
   an ordinary call binds its arguments exactly as it did before the store
   existed. Returns the cells to forget when the body is done with them. *)
and track_parameters machine ~call_site ~lambda ~env params =
  let level = Machine.level machine in
  List.filter_map
    (fun param ->
      if not (Store.assigned param) then None
      else
        let cell =
          Env.lookup_exn ~phase:Error.Stage ~span:call_site ~level env param
        in
        let value =
          Env.read_exn ~phase:Error.Stage ~span:call_site ~level env param
        in
        let residual code =
          match residual_target code with
          | Some target ->
              Store.track_residual cell ~binder:param ~target
                ~reference:(Value.Code code)
          | None ->
              let target, binder_span =
                Emit.emit_binder ~from:call_site ~name:(Ident.name param) code
              in
              let reference = Value.Code (Core.var ~span:binder_span target) in
              Value.fill_cell cell reference;
              Store.track_residual cell ~binder:param ~target ~reference
        in
        (match Stage_value.dynamic_code value with
        | Some code -> residual code
        | None ->
            if Store.holdable ~binder:param ~scope:lambda.Core.lam_body then
              Store.track_held cell ~binder:param value
            else residual (reify_value machine ~call_site value));
        Some cell)
    params

(* The bindings a held cell has to give up before a dynamic conditional forks.

   The branches' syntactic write set is enough, and only here: a held binder is
   never free in a lambda ({!Store.holdable}), so no call inlined inside a
   branch can assign it and every write to it is written in the branch itself. *)
and promote_writes machine ~span ~branches =
  (* Nothing held is nothing to give up, so a program whose bindings are all the
     residual program's already never pays for this scan. *)
  if Store.holds_static () then
    let written =
      List.fold_left
        (fun written branch -> Ident.Set.union written (Core.assigned_idents branch))
        Ident.Set.empty branches
    in
    List.iter
      (fun (cell, binder, value) ->
        let code = reify_value machine ~call_site:span value in
        let target, binder_span =
          Emit.emit_binder ~from:span ~name:(Ident.name binder) code
        in
        Store.promote cell ~target
          ~reference:(Value.Code (Core.var ~span:binder_span target)))
      (Store.written_holds written)

(* A write the residual program performs. It is a step of that program, so it is
   emitted into the block in the order it happens rather than being folded into
   the expression its value flows to — which is unit, and known. *)
and emit_set machine ~span ~target value =
  let code = reify_value machine ~call_site:span value in
  let generated = Span.generated ~by:"stage/set" ~from:span in
  ignore
    (Emit.emit_binder ~from:span ~name:"set"
       (Core.set ~span:generated ~target ~value:code)
      : Ident.t * Span.t)

(* Calling a specialization point: only the argument positions the key knows
   nothing about are passed, because the rest are already inside the residual
   function's body. *)
and call_point machine ~call_site ~key point arguments =
  let generated = Span.generated ~by:"stage/specialize-call" ~from:call_site in
  let args =
    List.concat
      (List.map2
         (fun argument projection ->
           match projection with
           | Specialize.Unknown -> [ reify_value machine ~call_site argument ]
           | Specialize.Known _ | Specialize.Held _ -> [])
         arguments (Specialize.arguments key))
  in
  let name = Specialize.residual_name point in
  let node =
    Core.app ~span:generated ~func:(Core.var ~span:generated name) ~args
  in
  Specialize.count_call ();
  Value.Code (Emit.emit ~from:call_site ~name:(Ident.name name) node)

(* Turning a call the unroller cannot finish into a residual function.

   The point belongs to the call that {e started} the inlining, not to the one
   that discovered the cycle, so it is built in that call's context: the blocks
   open there are the blocks its [LetRec] may be bound in, and the values it
   specializes in are values that site can still name. Discovery normally
   happens inside a dynamic conditional's branch, and a residual function bound
   there would be unreachable from anywhere else — including from the next call
   with the same key, which is the sharing the memo table exists for.

   The point is registered before its body is specialized, so the recursive call
   inside the body finds it and emits a call instead of inlining again. That is
   what ties the knot. *)
and define_point machine ~call_site ~name ~lambda ~env ~key entry =
  Specialize.with_entry_context entry (fun () ->
      build_point machine ~call_site ~name ~lambda ~env ~key
        (Specialize.entry_arguments entry))

(* Building the residual function itself, in whatever context is open. *)
and build_point machine ~call_site ~name ~lambda ~env ~key arguments =
  let generated = Span.generated ~by:"stage/specialize" ~from:call_site in
  let residual =
    Ident.fresh
      (match name with Some ident -> Ident.name ident | None -> "specialized")
  in
  (* Exactly the positions the specializer knows nothing about become
     parameters, under fresh binders: the source parameter is still bound to a
     static value in a sibling specialization of the same function. *)
  let parameters = ref [] in
  let bindings =
    List.map2
      (fun (param, argument) projection ->
        match projection with
        | Specialize.Unknown ->
            let parameter = Ident.fresh (Ident.name param) in
            parameters := parameter :: !parameters;
            (param, Value.Code (Core.var ~span:generated parameter))
        | Specialize.Known _ | Specialize.Held _ -> (param, argument))
      (List.combine lambda.Core.params arguments)
      (Specialize.arguments key)
  in
  let parameters = List.rev !parameters in
  (* A parameter specialized {e into} the point's body is one value shared by
     every call to it, so a place for it has to be inside the body. The store can
     make one — it promotes into whatever block is open, and the point's body is
     open while it is specialized — but only for a binding it may hold in the
     first place. A parameter it cannot hold is residualized at its binding site,
     and that binding site is here, outside the residual function: one place
     every call would share, so one call's write would reach the next. The
     specializer refuses instead of emitting a residual that quietly shares. *)
  List.iter2
    (fun param projection ->
      match projection with
      | Specialize.Unknown -> ()
      | Specialize.Known _ | Specialize.Held _ ->
          if
            Store.assigned param
            && not (Store.holdable ~binder:param ~scope:lambda.Core.lam_body)
          then
            unsupported Mode.Lift ~span:call_site ~level:(Machine.level machine)
              (Printf.sprintf
                 "a specialization point whose specialized parameter `%s` is assigned"
                 (Ident.name param)))
    lambda.Core.params (Specialize.arguments key);
  let point = Specialize.define key residual in
  let inner = Env.extend bindings env in
  let tracked =
    track_parameters machine ~call_site ~lambda ~env:inner lambda.Core.params
  in
  let body = reify_eval machine lambda.Core.lam_body inner in
  List.iter Store.release tracked;
  let definition = Core.lambda ~params:parameters ~body in
  Emit.emit_letrec ~from:call_site
    [ Core.rec_binding ~span:generated ~name:residual definition ];
  point

(* Budget pressure (spec §7.5). The unroller has stopped believing it is making
   progress, so this call stops being inlined and becomes a specialization point
   — after giving up one more argument, when there is one to give up, so that
   the calls this one is a copy of round onto the same point instead of each
   getting their own. Generalizing is what turns a recursion presenting a fresh
   key every step into one that meets itself. *)
and pressured_point machine ~call_site ~name ~lambda ~env ~key ~pressure arguments =
  let callee = Option.map Ident.name name in
  let key =
    match
      Specialize.generalize key ~callee ~parameters:lambda.Core.params
        ~site:call_site pressure
    with
    | Some coarser -> coarser
    | None ->
        (* Nothing left to give up: every argument is already dynamic, so the
           key is already as coarse as it gets and a point under it terminates
           on its own. *)
        key
  in
  let point =
    match Specialize.lookup key with
    | Some point -> point
    | None -> (
        match Specialize.active_entry key with
        | Some entry -> define_point machine ~call_site ~name ~lambda ~env ~key entry
        | None -> build_point machine ~call_site ~name ~lambda ~env ~key arguments)
  in
  (point, key)

(* Meta readings the specializing configuration fixes outright.

   [tower_depth] is §D9's one deliberate opt-in, and the specializer's own
   position answers it. Attached to a materialized tower — which is what
   measuring at a stated depth means — the depth it specializes under is a
   static fact, and folding it is what makes a residual produced at depth {i n}
   the residual {e for} depth {i n}: executed anywhere, it reports the depth it
   was specialized under, which is what the tower at that depth reports too.
   Without an attached tower the reading stays dynamic and residualizes, which
   is the behavior every standalone caller gets.

   The other readers stay dynamic always: [meta_eval], [meta_apply], and
   [meta_global] answer with cells and environments, identity-carrying values
   the small lifting domain refuses to reify, and [tower_level] is left to the
   same rule as ever — it reads 0 here and 0 wherever this fragment runs. *)
let static_reading machine primitive =
  match primitive.Value.prim_name with
  | "tower_depth" when Option.is_some (Machine.levels machine) ->
      Some (Value.Num (Machine.tower_depth machine))
  | _ -> None

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
  let apply_now () =
    primitive.Value.prim_impl ~call_site ~level
      ~apply:(fun ~call_site callee args k ->
        Machine.apply machine ~call_site callee args k)
      ~lift:(fun ~call_site value -> Evaluator.lift_value machine ~call_site value)
      ~run:(fun ~call_site node k -> run_code mode machine ~call_site node k)
      ~reflect:(fun ~call_site ~code ~env ~cont k ->
        reflect_down mode machine ~call_site ~code ~env ~cont k)
      ~meta:(fun ~call_site query -> meta_view mode machine ~call_site query)
      arguments k
  in
  let residualize () =
    let args_code =
      List.map (fun argument -> reify_value machine ~call_site argument) arguments
    in
    let prim_ident = primitive_ident machine ~call_site primitive in
    (* Provenance says why the call survived: [stage/prim] is a foldable
       primitive whose arguments were not known well enough, [stage/residualize]
       one whose effect class forbids folding at any argument knowledge. *)
    let reason =
      if Effect_class.may_fold_when_static primitive.Value.prim_class then
        "stage/prim"
      else "stage/residualize"
    in
    let generated = Span.generated ~by:reason ~from:call_site in
    let node =
      Core.app ~span:generated
        ~func:(Core.var ~span:generated prim_ident)
        ~args:args_code
    in
    let emitted = Emit.emit ~from:call_site ~name:primitive.Value.prim_name node in
    k (Value.Code emitted)
  in
  if not (Value.arity_matches primitive.Value.prim_arity given) then arity_error ()
  else
    match mode with
    | Mode.Identity -> apply_now ()
    | Mode.Lift ->
        (* D7's one absolute, checked before any rule that could fold. Ordering
           it first is what makes "specialization emits no program-visible
           output" a property of this function rather than a coincidence of the
           rules below it: {!Stage_value.may_fold} already refuses the class,
           but {!static_reading} is a fold path that never consults [may_fold],
           and the next such rule would be too. A class that always residualizes
           cannot reach either. *)
        if Effect_class.always_residualizes primitive.Value.prim_class then
          residualize ()
        else (
          match static_reading machine primitive with
          | Some reading ->
              k (Value.Code (Stage_value.lift_to_code ~call_site machine reading))
          | None ->
              (* Everything else, including the compile-time channel: its class
                 permits folding and it inspects nothing, so it runs here and
                 contributes its unit answer rather than a residual call. *)
              if Stage_value.may_fold primitive arguments then apply_now ()
              else residualize ())

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
              (* The store forks here (spec §7.4 step 3). Every held cell either
                 branch assigns is given up first, because the residual program
                 needs one place both branches write to and it has to be bound
                 where both — and everything after the join — can see it. *)
              promote_writes machine ~span ~branches:[ consequent; alternative ];
              let before = Store.snapshot () in
              let t_code = reify_eval machine consequent env in
              let after_consequent = Store.snapshot () in
              Store.restore before;
              let f_code = reify_eval machine alternative env in
              let after_alternative = Store.snapshot () in
              (match
                 Store.join ~before ~left:after_consequent ~right:after_alternative
               with
              | Ok joined -> Store.restore joined
              | Error binding ->
                  fail mode ~span ~level
                    (Error.Unsupported
                       {
                         what =
                           Printf.sprintf
                             "a conditional whose branches leave `%s` in different \
                              places"
                             (Ident.name (Store.binder_of binding));
                         by = "the abstract store, which cannot join them";
                       }));
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
          (* The residual program owns the binding: it is bound in the residual
             [Let], every read of it is that variable, and every assignment to it
             becomes a residual [Set] on that binder. *)
          let residual_binding val_code =
            let reference =
              Value.Code (Core.var ~span:(Core.span let_value) let_binder)
            in
            let inner = Env.bind let_binder reference env in
            let tracked =
              if Store.assigned let_binder then (
                let cell =
                  Env.lookup_exn ~phase:(phase_of mode) ~span ~level inner let_binder
                in
                Store.track_residual cell ~binder:let_binder ~target:let_binder
                  ~reference;
                Some cell)
              else None
            in
            let body_code = reify_eval machine let_body inner in
            Option.iter Store.release tracked;
            let generated = Span.generated ~by:"stage/let" ~from:span in
            let node =
              Core.let_ ~span:generated ~binder:let_binder ~value:val_code
                ~body:body_code
            in
            k (Value.Code (Emit.emit ~from:span node))
          in
          (* The specializer owns the binding: it holds the value in its own
             cell, so writes update it and reads fold, and nothing of it reaches
             the residual program at all. *)
          let held_binding () =
            let inner = Env.bind let_binder value env in
            let cell =
              Env.lookup_exn ~phase:(phase_of mode) ~span ~level inner let_binder
            in
            Store.track_held cell ~binder:let_binder value;
            Machine.eval machine let_body inner (fun result ->
                Store.release cell;
                k result)
          in
          let static_binding () =
            Machine.eval machine let_body (Env.bind let_binder value env) k
          in
          match mode with
          | Mode.Identity -> static_binding ()
          | Mode.Lift -> (
              match Stage_value.dynamic_code value with
              | Some val_code -> residual_binding val_code
              | None ->
                  (* Gated on the write set: a binder nothing assigns takes
                     exactly the path it took before the store existed. *)
                  if not (Store.assigned let_binder) then static_binding ()
                  else if Store.holdable ~binder:let_binder ~scope:let_body then
                    held_binding ()
                  else residual_binding (reify_value machine ~call_site:span value)))
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
      Machine.eval machine set_value env (fun value ->
          match mode with
          | Mode.Identity ->
              Env.assign_exn ~phase:(phase_of mode) ~span ~level env set_target value;
              k Value.Unit
          | Mode.Lift -> (
              let cell =
                Env.lookup_exn ~phase:(phase_of mode) ~span ~level env set_target
              in
              match Store.slot cell with
              | Some (Store.Residual { target; _ }) ->
                  (* The residual program owns the place, so the write is one of
                     its steps: emitted into the block in the order it happens,
                     and worth nothing to the specializer, whose answer is the
                     unit every assignment evaluates to. *)
                  emit_set machine ~span ~target value;
                  k Value.Unit
              | Some (Store.Held _) -> (
                  match Stage_value.dynamic_code value with
                  | None ->
                      Store.write cell value;
                      k Value.Unit
                  | Some code ->
                      (* A value the specializer does not have, written to a place
                         it was holding: the place has to become the residual
                         program's, starting from what is being written. *)
                      let target, binder_span =
                        Emit.emit_binder ~from:span ~name:(Ident.name set_target) code
                      in
                      Store.promote cell ~target
                        ~reference:(Value.Code (Core.var ~span:binder_span target));
                      k Value.Unit)
              | None ->
                  unsupported mode ~span ~level
                    (Printf.sprintf
                       "assignment to `%s`, which the abstract store does not track"
                       (Ident.name set_target))))
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
  | Value.Closure { Value.clo_lambda; clo_env; clo_name } -> (
      let params = clo_lambda.Core.params in
      if List.compare_lengths params arguments <> 0 then
        arity_error
          ~callee_name:(Option.map Ident.name clo_name)
          ~expected:(string_of_int (List.length params))
      else
        let inline () =
          let inner = Env.extend (List.combine params arguments) clo_env in
          let tracked =
            match mode with
            | Mode.Identity -> []
            | Mode.Lift ->
                track_parameters machine ~call_site ~lambda:clo_lambda ~env:inner params
          in
          fun k ->
            Machine.eval machine clo_lambda.Core.lam_body inner (fun value ->
                List.iter Store.release tracked;
                k value)
        in
        match mode with
        | Mode.Identity -> inline () k
        | Mode.Lift ->
            (* Specialization points (spec §7.5). Inlining is still the default,
               so everything the pure fragment already collapsed collapses
               unchanged: a key is only met twice when the unrolling has nothing
               left to make progress on. *)
            let key =
              Specialize.key ~lambda:clo_lambda ~env:clo_env ~arguments
            in
            (match Specialize.lookup key with
            | Some point -> k (call_point machine ~call_site ~key point arguments)
            | None -> (
                match Specialize.active_entry key with
                | Some entry ->
                    let point =
                      define_point machine ~call_site ~name:clo_name
                        ~lambda:clo_lambda ~env:clo_env ~key entry
                    in
                    k (call_point machine ~call_site ~key point arguments)
                | None -> (
                    match Specialize.pressure_of key with
                    | Some pressure ->
                        let point, key =
                          pressured_point machine ~call_site ~name:clo_name
                            ~lambda:clo_lambda ~env:clo_env ~key ~pressure arguments
                        in
                        k (call_point machine ~call_site ~key point arguments)
                    | None ->
                        let saved = Specialize.active () in
                        Specialize.enter key ~arguments;
                        inline () (fun value ->
                            Specialize.restore saved;
                            k value)))))
  | Value.Primitive primitive ->
      apply_primitive mode machine ~call_site primitive arguments k
  | Value.Code func_code when Mode.is_lift mode ->
      (* An unknown callee: every argument crosses into residual code, closures
         and partially static data included. *)
      let args_code =
        List.map (fun argument -> reify_value machine ~call_site argument) arguments
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
  Specialize.reset ();
  (* One write set per run, shared with the normalizer that will canonicalize
     whatever this produces (ADR 0036). *)
  Store.reset ~assigned:(Core.assigned_idents node);
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
