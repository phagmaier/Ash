open Ash_core

type binding = {
  binder : Ident.t;
  value : Core.t;
  span : Span.t;
}

type buffer = {
  mutable bindings : binding list;
}

let create_buffer () = { bindings = [] }

let binding_count buf = List.length buf.bindings

let buffer_stack : buffer list ref = ref []

let current_buffer () =
  match !buffer_stack with
  | [] -> None
  | buf :: _ -> Some buf

let with_buffer buf f =
  buffer_stack := buf :: !buffer_stack;
  Fun.protect f ~finally:(fun () ->
      match !buffer_stack with
      | [] -> ()
      | _ :: rest -> buffer_stack := rest)

let is_trivial node =
  match Core.shape node with
  | Core.Var _ | Core.Lit _ -> true
  | Core.NamedVar _ | Core.Lam _ | Core.Quote _ | Core.Reifier _ | Core.If _
  | Core.Let _ | Core.LetRec _ | Core.Set _ | Core.App _ ->
      false

let emit ?name ?from node =
  if is_trivial node then
    node
  else
    match current_buffer () with
    | None -> node
    | Some buf ->
        let span =
          match from with
          | Some s -> Span.generated ~by:"stage/let-insert" ~from:s
          | None -> Span.generated ~by:"stage/let-insert" ~from:(Core.span node)
        in
        let binder_name = Option.value name ~default:"v" in
        let binder = Ident.fresh binder_name in
        buf.bindings <- { binder; value = node; span } :: buf.bindings;
        Core.var ~span binder

let emit_val ?name ?from node =
  Value.Code (emit ?name ?from node)

let reify_block f =
  let buf = create_buffer () in
  let body = with_buffer buf f in
  let emitted_bindings = List.rev buf.bindings in
  List.fold_right
    (fun { binder; value; span } acc ->
      Core.let_ ~span ~binder ~value ~body:acc)
    emitted_bindings body
