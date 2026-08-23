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
        Encode.datum ~globals (Encode.term term);
        Encode.datum ~globals (Encode.globals globals);
      ]

let rec nest ~globals ~layers term =
  if layers <= 0 then term
  else nest ~globals ~layers:(layers - 1) (interpreting ~globals term)

let eval ?(layers = 1) ~globals term =
  Evaluator.eval ~env:(Env.extend globals Value.empty_env) (nest ~globals ~layers term)
