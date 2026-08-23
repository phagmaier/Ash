open Ash_core
open Ash_syntax
open Ash_runtime

let source = Self_source.text
let file = "lib/self/eval.ash"
let entry_point = "interpret"

let load ?(extra = entry_point) ~globals () =
  let named = List.map (fun (identity, _) -> (Ident.name identity, identity)) globals in
  let program = Parser.program ~file (source ^ "\n" ^ extra ^ "\n") in
  let term = Desugar.program ~scope:(Desugar.scope_of_globals named) program in
  Evaluator.eval ~env:(Env.extend globals Value.empty_env) term

let call callee arguments =
  let machine = Evaluator.machine () in
  Machine.apply machine ~call_site:Span.unknown callee arguments (fun value -> value)

let eval ~globals term =
  call (load ~globals ()) [ Encode.term term; Encode.globals globals ]
