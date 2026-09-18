open Ash_core

type kind = Depth_invariant_full | Depth_sensitive_full | Partial | Opaque

type precheck = {
  observes_depth : bool;
  dynamic_named_var : bool;
  reflection_under_dynamic_condition : bool;
}

type t = {
  kind : kind;
  precheck : precheck;
  reasons : string list;
  tower_residual_agree : bool;
  conservative : bool;
}

let name = function
  | Depth_invariant_full -> "DEPTH-INVARIANT, FULL"
  | Depth_sensitive_full -> "DEPTH-SENSITIVE, FULL"
  | Partial -> "PARTIAL"
  | Opaque -> "OPAQUE"

let primitive_of env node =
  match Core.shape node with
  | Core.Var ident -> (
      match Env.lookup env ident with
      | Some cell -> (
          match Value.cell_contents cell with
          | Some (Value.Primitive primitive) -> Some primitive
          | _ -> None)
      | None -> None)
  | _ -> None

let primitive_name env node =
  Option.map (fun primitive -> primitive.Value.prim_name) (primitive_of env node)

let rec has_if node =
  (match Core.shape node with Core.If _ -> true | _ -> false)
  || List.exists has_if (Core.children node)

let rec has_reifier node =
  (match Core.shape node with Core.Reifier _ -> true | _ -> false)
  || List.exists has_reifier (Core.children node)

let rec persistent_dynamic_choice node =
  (match Core.shape node with
  | Core.If { Core.condition; consequent; alternative } ->
      (match Core.shape condition with Core.Lit (Constant.Bool _) -> false | _ -> true)
      && (has_reifier consequent || has_reifier alternative)
  | _ -> false)
  || List.exists persistent_dynamic_choice (Core.children node)

let static_pure_outside_scoped_choice ~env root =
  let rec walk node =
    let dynamic_scoped_root =
      match Core.shape node with
      | Core.Let { Core.let_binder; _ } ->
          String.equal (Ident.name let_binder) "outer_eval"
          && List.mem "desugar/meta_with" (Span.generators (Core.span node))
          && has_if node
      | _ -> false
    in
    if dynamic_scoped_root then false
    else
      let here =
        match Core.shape node with
        | Core.App { Core.func; args } -> (
            match primitive_of env func with
            | Some primitive ->
                Effect_class.equal primitive.Value.prim_class Effect_class.Pure
                && List.for_all
                     (fun arg ->
                       match Core.shape arg with Core.Lit _ -> true | _ -> false)
                     args
            | None -> false)
        | _ -> false
      in
      here || List.exists walk (Core.children node)
  in
  walk root

let precheck ~env root =
  let depth = ref false in
  let named = ref false in
  let dynamic_reflection = ref false in
  let rec has_reflection node =
    (match Core.shape node with
    | Core.Reifier _ -> true
    | Core.App { Core.func; _ } -> (
        match primitive_name env func with
        | Some ("meta_with_run" | "meta_eval" | "meta_apply") -> true
        | _ -> false)
    | _ -> false)
    || List.mem "desugar/meta_with" (Span.generators (Core.span node))
    || List.exists has_reflection (Core.children node)
  in
  let rec walk under_dynamic node =
    (match Core.shape node with
    | Core.NamedVar _ -> named := true
    | Core.App { Core.func; _ } ->
        if primitive_name env func = Some "tower_depth" then depth := true
    | Core.If { Core.condition; consequent; alternative } ->
        let condition_unknown =
          match Core.shape condition with Core.Lit (Constant.Bool _) -> false | _ -> true
        in
        if condition_unknown && (has_reflection consequent || has_reflection alternative)
        then dynamic_reflection := true
    | _ -> ());
    match Core.shape node with
    | Core.If { Core.condition; consequent; alternative } ->
        let unknown =
          match Core.shape condition with Core.Lit (Constant.Bool _) -> false | _ -> true
        in
        walk under_dynamic condition;
        walk (under_dynamic || unknown) consequent;
        walk (under_dynamic || unknown) alternative
    | _ -> List.iter (walk under_dynamic) (Core.children node)
  in
  walk false root;
  (* A scoped override whose own value chooses an evaluator also crosses the
     boundary. The outer [If] need not enclose the lowered meta operation. *)
  let rec scoped_choice node =
    let here =
      List.mem "desugar/meta_with" (Span.generators (Core.span node))
      &&
      let rec has_if n =
        match Core.shape n with
        | Core.If _ -> true
        | _ -> List.exists has_if (Core.children n)
      in
      has_if node
    in
    here || List.exists scoped_choice (Core.children node)
  in
  { observes_depth = !depth;
    dynamic_named_var = !named;
    reflection_under_dynamic_condition = !dynamic_reflection || scoped_choice root }

let classify (metrics : Metrics.t) =
  let precheck = precheck ~env:metrics.globals metrics.program in
  match metrics.residual with
  | Error _ ->
      { kind = Opaque; precheck; tower_residual_agree = false;
        reasons = [ "specialization produced no executable residual" ];
        conservative = true }
  | Ok residual ->
      let residue = residual.Metrics.residue in
      let comparison =
        Metrics.agreement metrics.tower.run.outcome residual.Metrics.run.outcome
      in
      let same_output =
        List.equal Ash_runtime.Io.event_equal metrics.tower.run.output
          residual.Metrics.run.output
      in
      let agrees = comparison = Metrics.Agrees && same_output in
      let differs = comparison = Metrics.Differs || not same_output in
      let incomparable = comparison = Metrics.Incomparable && same_output in
      let reflection_survives = residue.reflection_boundaries <> [] in
      let interpretation_survives =
        residue.eval_cell_dereferences > 0 || residue.evaluator_calls > 0
        || residue.dispatch_sites > 0 || residue.named_var_lookups > 0
        || residue.control_sites > 0
        || reflection_survives
        || Residue.interpreter_residue residue ~own:metrics.file > 0
      in
      let dynamic = precheck.reflection_under_dynamic_condition in
      let static_work =
        static_pure_outside_scoped_choice ~env:metrics.globals metrics.program
      in
      let persistent = persistent_dynamic_choice metrics.program in
      let opaque =
        persistent
        || (dynamic && not static_work
            && residue.nodes >= Core.node_count metrics.program)
      in
      let kind =
        if differs then Opaque
        else if opaque then Opaque
        else if interpretation_survives || dynamic || precheck.dynamic_named_var
        then Partial
        else if precheck.observes_depth then Depth_sensitive_full
        else Depth_invariant_full
      in
      let reasons =
        (if differs then [ "tower and residual observations differ" ] else [])
        @ (if incomparable then
             [ "identity-carrying result needs an application test for comparison" ]
           else [])
        @ (if dynamic then [ "evaluator identity may depend on a runtime condition" ] else [])
        @ (if precheck.dynamic_named_var then [ "printed-name lookup may depend on a runtime environment" ] else [])
        @ (if precheck.observes_depth then [ "program reads tower_depth()" ] else [])
        @ (if interpretation_survives then [ "residual AST contains interpretation sites" ] else [])
        @ (if dynamic && static_work && not persistent then
             [ "statically known pure work outside the reflective boundary folds" ]
           else [])
        @ (if persistent then
             [ "persistent runtime evaluator choice preserves source syntax" ]
           else [])
        @ (if opaque then [ "no net AST reduction across the dynamic evaluator boundary" ] else [])
      in
      { kind; precheck; tower_residual_agree = agrees;
        reasons = (if reasons = [] then [ "no interpretation sites found" ] else reasons);
        conservative = true }
