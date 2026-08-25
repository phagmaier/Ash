(* The source/residual differential (to-do task 5.3).

   The staged evaluator in lift mode is supposed to be the same semantics as the
   ground evaluator, with as much of the work as it can do moved earlier. So the
   whole pure half of the corpus — higher-order programs, recursion, immutable
   data — has to give the same answer twice: once run directly, once staged into
   residual Core and then run. Anything the specializer folds wrongly shows up
   here as a difference, not as a smaller residual.

   The effect half joins it at task 7.2: store splitting is what lets a [Set]
   reach a residual, and the corpus's mutation programs are the shapes that go
   wrong first — a closure that writes what it captured, two closures that share
   one binding, and argument order against a write. Task 7.3's effect-order
   programs join them, including the ones whose failure the residual raises
   rather than folds.

   What this test compares that `test/laws/effect_order_test.ml` does not is the
   {e raw} residual: the fold's own output, before normalization. That test
   compares the deliverable, which is the normalized term; this one is what says
   the specializer was already right before the normalizer touched it. The
   control half is still absent: that is §7.4's later step. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_stage

let failures = ref 0
let file = "residual.ash"

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

(* Two runs allocate two closures, and closure equality is identity (§D1), so a
   residual function is compared with its source function by the syntax it
   closes over rather than by the allocation it happens to be. *)
let rec same_value a b =
  match (a, b) with
  | Value.Closure x, Value.Closure y ->
      let span = Core.span x.Value.clo_lambda.Core.lam_body in
      Alpha.equal
        (Core.of_lambda ~span x.Value.clo_lambda)
        (Core.of_lambda ~span y.Value.clo_lambda)
  | Value.List xs, Value.List ys -> List.equal same_value xs ys
  | ( ( Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
      | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
      | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ),
      _ ) ->
      Value.equal a b

let difference source residual =
  match (source, residual) with
  | Ok a, Ok b when not (same_value a b) ->
      Some
        (Printf.sprintf "value: the source gave %s, the residual gave %s"
           (Value.to_string a) (Value.to_string b))
  | Ok a, Error e ->
      Some
        (Printf.sprintf "the source gave %s where the residual failed: %s"
           (Value.to_string a) (Error.to_string e))
  | Error e, Ok b ->
      Some
        (Printf.sprintf "the source failed where the residual gave %s: %s"
           (Value.to_string b) (Error.to_string e))
  | Error a, Error b when not (Error.cause_equal a.Error.cause b.Error.cause) ->
      Some
        (Printf.sprintf "cause: the source said %s, the residual said %s"
           (Error.cause_message a.Error.cause)
           (Error.cause_message b.Error.cause))
  | (Ok _ | Error _), (Ok _ | Error _) -> None

let compared = ref 0

(* Both notations, one comparison: the Core half is what the corpus's older
   lists are written in, and the effect-order samples are Ash the front end
   lowers, which puts the desugaring of `var`, `:=` and `&&` under the same
   claim as the staging of what it produces. *)
let agree ?(surface = false) name text =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let io = Primitives.io registry in
  let term =
    if surface then
      Desugar.program ~scope:(Desugar.scope_of_globals named) (Parser.program ~file text)
    else Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text
  in
  let fresh () = Env.extend globals Value.empty_env in
  Io.clear io;
  let source = attempt (fun () -> Evaluator.eval ~env:(fresh ()) term) in
  let source_trace = Io.events io in
  Io.clear io;
  (* Specialization is not a run of the program: a pure program leaves nothing
     behind while it is being staged, and this is where that would show. *)
  let staged = attempt (fun () -> Staged_eval.fold ~env:(fresh ()) term) in
  let staging_trace = Io.events io in
  if staging_trace <> [] then (
    incr failures;
    Printf.printf "FAIL %s\n  specialization left output: [%s]\n" name
      (String.concat "; " (List.map Io.event_to_string staging_trace)));
  match staged with
  | Error error ->
      (* Staging a pure program is allowed to reach the program's own failure,
         and then it must be the same failure. *)
      (match difference source (Error error) with
      | None -> incr compared
      | Some explanation ->
          incr failures;
          Printf.printf "FAIL %s\n  %s\n" name explanation)
  | Ok residual ->
      let env = fresh () in
      (match Code.unresolved_dependencies ~available:(Env.idents env) residual with
      | [] -> ()
      | dependencies ->
          incr failures;
          Printf.printf "FAIL %s\n  the residual is open in: %s\n" name
            (String.concat ", "
               (List.map (fun d -> Ident.name d.Code.ident) dependencies)));
      Io.clear io;
      let run = attempt (fun () -> Evaluator.eval ~env residual) in
      let residual_trace = Io.events io in
      if not (List.equal Io.event_equal source_trace residual_trace) then (
        incr failures;
        Printf.printf "FAIL %s\n  output: the source left [%s], the residual left [%s]\n"
          name
          (String.concat "; " (List.map Io.event_to_string source_trace))
          (String.concat "; " (List.map Io.event_to_string residual_trace)));
      (match difference source run with
      | None -> incr compared
      | Some explanation ->
          incr failures;
          Printf.printf "FAIL %s\n  %s\n  residual: %s\n" name explanation
            (Core_printer.to_string residual))

let () =
  List.iter (fun (name, text) -> agree ("value: " ^ name) text) Corpus.values;
  let pure = !compared in
  List.iter (fun (name, text) -> agree ("effect: " ^ name) text) Corpus.effects;
  List.iter
    (fun sample ->
      agree ~surface:true
        ("effect order: " ^ sample.Corpus.name)
        (Corpus.effect_sample_program sample))
    Corpus.effect_order;
  List.iter
    (fun (name, text) -> agree ~surface:true ("failure: " ^ name) text)
    Corpus.effect_order_failures;
  Printf.printf
    "source/residual corpus: %d pure and %d mutating programs compared\n" pure
    (!compared - pure);
  if !failures > 0 then (
    Printf.printf "%d source/residual difference(s)\n" !failures;
    exit 1)
