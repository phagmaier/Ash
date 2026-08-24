open Ash_core
open Ash_syntax
open Ash_runtime

let source = Self_source.text
let file = "lib/self/eval.ash"
let entry_point = "interpret"

let program ?(extra = entry_point) ~globals () =
  let named = List.map (fun (identity, _) -> (Ident.name identity, identity)) globals in
  Desugar.program
    ~scope:(Desugar.scope_of_globals named)
    (Parser.program ~file (source ^ "\n" ^ extra ^ "\n"))

let load ?extra ~globals () =
  Evaluator.eval ~env:(Env.extend globals Value.empty_env) (program ?extra ~globals ())

let call callee arguments =
  let machine = Evaluator.machine () in
  Machine.apply machine ~call_site:Span.unknown callee arguments (fun value -> value)

let rec reveal value =
  match value with
  | Value.Closure _ -> Value.Sym "clo"
  | Value.Reifier _ -> Value.Sym "reif"
  | Value.Continuation _ -> Value.Sym "cont"
  | Value.List items -> Value.List (List.map reveal items)
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
      value

(* The program itself crosses a layer as [Quote term]. The only remaining
   transport is the level's global frame: identifier keys are one-node Code and
   primitive values remain the shared registry values, written as global
   references so another layer can evaluate this term too. *)
let globals_term ~span globals =
  let by_primitive_name = Hashtbl.create 64 in
  List.iter
    (fun (identity, value) ->
      match value with
      | Value.Primitive primitive ->
          Hashtbl.replace by_primitive_name primitive.Value.prim_name identity
      | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
      | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
      | Value.Environment _ | Value.Cell _ | Value.Code _ ->
          invalid_arg
            (Printf.sprintf "Self.interpreting: `%s` is bound to %s, not a primitive"
               (Ident.name identity) (Value.type_phrase value)))
    globals;
  let global name =
    match Hashtbl.find_opt by_primitive_name name with
    | Some identity -> identity
    | None ->
        invalid_arg
          (Printf.sprintf "Self.interpreting: `%s` is not a primitive global" name)
  in
  let list items =
    Core.app ~span ~func:(Core.var ~span (global "list")) ~args:items
  in
  let binding (identity, value) =
    match value with
    | Value.Primitive primitive ->
        list
          [
            Core.quote ~span (Core.var ~span identity);
            Core.var ~span (global primitive.Value.prim_name);
          ]
    | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
    | Value.Environment _ | Value.Cell _ | Value.Code _ ->
        invalid_arg "Self.globals_term: globals were validated above"
  in
  list (List.map binding globals)

(* The interpreter applied to the program and the globals, as one term. Writing
   the two arguments *into* the term rather than passing them beside it is what
   makes layers compose: the result is an ordinary Core term, so it can itself be
   the program a further layer interprets. *)
let interpreting ?extra ~globals term =
  let span = Span.generated ~by:"self/layer" ~from:Span.unknown in
  Core.app ~span
    ~func:(program ?extra ~globals ())
    ~args:
      [
        Core.quote ~span term;
        globals_term ~span globals;
      ]

let rec nest ~globals ~layers term =
  if layers <= 0 then term
  else nest ~globals ~layers:(layers - 1) (interpreting ~globals term)

let eval ?(layers = 1) ~globals term =
  Evaluator.eval ~env:(Env.extend globals Value.empty_env) (nest ~globals ~layers term)
