open Ash_core

type binding = {
  binder : Ident.t;
  value : Core.t;
  span : Span.t;
}

(* A block records what has to be bound around the expression it finally
   produces, in the order the specializer produced it. Ordinary emissions are
   [Let]s; a specialization point is a [LetRec] group, and it has to sit exactly
   where it was created rather than being hoisted, because its body may mention
   let-inserted binders that only exist from that position onwards. *)
type item =
  | Value_binding of binding
  | Recursive_group of {
      bindings : Core.rec_binding list;
      span : Span.t;
    }

type buffer = { mutable items : item list }

let create_buffer () = { items = [] }

let binding_count buf =
  List.length
    (List.filter
       (function Value_binding _ -> true | Recursive_group _ -> false)
       buf.items)

let recursive_group_count buf =
  List.length
    (List.filter
       (function Recursive_group _ -> true | Value_binding _ -> false)
       buf.items)

type stack = buffer list

let buffer_stack : stack ref = ref []

let stack () = !buffer_stack

(* Residual bindings emitted during this specialization run. This is the size
   signal the budget watches: a deep unrolling that folds away emits nothing,
   while one that is not making progress emits at every step. *)
let emitted = ref 0

let emitted_count () = !emitted
let reset_counts () = emitted := 0

let with_stack installed f =
  let saved = !buffer_stack in
  buffer_stack := installed;
  Fun.protect f ~finally:(fun () -> buffer_stack := saved)

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
        buf.items <- Value_binding { binder; value = node; span } :: buf.items;
        incr emitted;
        Core.var ~span binder

let emit_val ?name ?from node =
  Value.Code (emit ?name ?from node)

let emit_letrec ?from bindings =
  match bindings with
  | [] -> ()
  | _ :: _ -> (
      match current_buffer () with
      | None ->
          invalid_arg
            "Emit.emit_letrec: a specialization point needs an enclosing block"
      | Some buf ->
          let span =
            match from with
            | Some s -> Span.generated ~by:"stage/specialize" ~from:s
            | None -> (List.hd bindings).Core.rec_span
          in
          buf.items <- Recursive_group { bindings; span } :: buf.items)

let reify_block f =
  let buf = create_buffer () in
  let body = with_buffer buf f in
  List.fold_right
    (fun item acc ->
      match item with
      | Value_binding { binder; value; span } ->
          Core.let_ ~span ~binder ~value ~body:acc
      | Recursive_group { bindings; span } -> Core.letrec ~span ~bindings ~body:acc)
    (List.rev buf.items) body
