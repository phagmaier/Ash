open Ash_core

type t = {
  nodes : int;
  nodes_by_origin : (string * int) list;
  generated_nodes : int;
  eval_cell_dereferences : int;
  evaluator_calls : int;
  dispatch_sites : int;
  named_var_lookups : int;
  reflection_boundaries : (string * int) list;
}

type tally = {
  mutable count : int;
  mutable by_origin : (string * int) list;
  mutable generated : int;
  mutable derefs : int;
  mutable calls : int;
  mutable dispatch : int;
  mutable named_vars : int;
  mutable boundaries : (string * int) list;
}

let bump table key =
  match List.assoc_opt key table with
  | Some n -> (key, n + 1) :: List.remove_assoc key table
  | None -> (key, 1) :: table

let sorted table = List.sort (fun (a, _) (b, _) -> String.compare a b) table

(* The primitive an applied expression denotes, or [None]. Only a variable can
   denote one, and only by the identity the specializer emitted: a residual
   binder that shadows a global's printed name is a different identity and
   resolves to nothing here. *)
let primitive_of ~env node =
  match Core.shape node with
  | Core.Var ident -> (
      match Env.lookup env ident with
      | Some cell -> (
          match Value.cell_contents cell with
          | Some (Value.Primitive primitive) -> Some primitive
          | Some (Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _
                 | Value.Unit | Value.List _ | Value.Closure _ | Value.Reifier _
                 | Value.Continuation _ | Value.Environment _ | Value.Cell _
                 | Value.Code _)
          | None ->
              None)
      | None -> None)
  | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
  | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
      None

let is_open_deref ~env node =
  match primitive_of ~env node with
  | Some primitive -> String.equal primitive.Value.prim_name "open_deref"
  | None -> false

let survey ~env root =
  let tally =
    {
      count = 0;
      by_origin = [];
      generated = 0;
      derefs = 0;
      calls = 0;
      dispatch = 0;
      named_vars = 0;
      boundaries = [];
    }
  in
  let visit_node node =
    tally.count <- tally.count + 1;
    let span = Core.span node in
    if Span.is_generated span then tally.generated <- tally.generated + 1;
    tally.by_origin <- bump tally.by_origin (Span.file (Span.source_span span))
  in
  let visit_application ~func =
    (match primitive_of ~env func with
    | Some primitive ->
        (match primitive.Value.prim_name with
        | "open_deref" -> tally.derefs <- tally.derefs + 1
        | "code_view" | "code_match" -> tally.dispatch <- tally.dispatch + 1
        | _ -> ());
        if Effect_class.equal primitive.Value.prim_class Effect_class.Reflection then
          tally.boundaries <- bump tally.boundaries primitive.Value.prim_name
    | None -> ());
    (* An interpreter's recursive step, written down: read the group cell, then
       apply what was in it. *)
    match Core.shape func with
    | Core.App { Core.func = inner; _ } when is_open_deref ~env inner ->
        tally.calls <- tally.calls + 1
    | Core.App _ | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _
    | Core.Let _ | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _
    | Core.Reifier _ ->
        ()
  in
  let rec walk node =
    visit_node node;
    match Core.shape node with
    | Core.Lit _ | Core.Var _ -> ()
    | Core.NamedVar _ -> tally.named_vars <- tally.named_vars + 1
    | Core.Lam { Core.lam_body; _ } -> walk lam_body
    | Core.Quote quoted ->
        (* Quoted syntax is data the residual carries, not code it runs, but it
           is still nodes that exist: counted, never classified. *)
        walk_quoted quoted
    | Core.Reifier { Core.reifier_body; _ } -> walk reifier_body
    | Core.App { Core.func; args } ->
        visit_application ~func;
        walk func;
        List.iter walk args
    | Core.Let { Core.let_value; let_body; _ } ->
        walk let_value;
        walk let_body
    | Core.LetRec { Core.rec_bindings; rec_body } ->
        List.iter (fun b -> walk b.Core.rec_lambda.Core.lam_body) rec_bindings;
        walk rec_body
    | Core.If { Core.condition; consequent; alternative } ->
        walk condition;
        walk consequent;
        walk alternative
    | Core.Set { Core.set_value; _ } -> walk set_value
  and walk_quoted node =
    visit_node node;
    match Core.shape node with
    | Core.Lit _ | Core.Var _ | Core.NamedVar _ -> ()
    | Core.Lam { Core.lam_body; _ } -> walk_quoted lam_body
    | Core.Quote quoted -> walk_quoted quoted
    | Core.Reifier { Core.reifier_body; _ } -> walk_quoted reifier_body
    | Core.App { Core.func; args } ->
        walk_quoted func;
        List.iter walk_quoted args
    | Core.Let { Core.let_value; let_body; _ } ->
        walk_quoted let_value;
        walk_quoted let_body
    | Core.LetRec { Core.rec_bindings; rec_body } ->
        List.iter (fun b -> walk_quoted b.Core.rec_lambda.Core.lam_body) rec_bindings;
        walk_quoted rec_body
    | Core.If { Core.condition; consequent; alternative } ->
        walk_quoted condition;
        walk_quoted consequent;
        walk_quoted alternative
    | Core.Set { Core.set_value; _ } -> walk_quoted set_value
  in
  walk root;
  {
    nodes = tally.count;
    nodes_by_origin = sorted tally.by_origin;
    generated_nodes = tally.generated;
    eval_cell_dereferences = tally.derefs;
    evaluator_calls = tally.calls;
    dispatch_sites = tally.dispatch;
    named_var_lookups = tally.named_vars;
    reflection_boundaries = sorted tally.boundaries;
  }

let interpreter_residue t ~own =
  List.fold_left
    (fun total (file, count) -> if String.equal file own then total else total + count)
    0 t.nodes_by_origin
