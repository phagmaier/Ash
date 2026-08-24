(* Layer agreement (to-do task 2.3).

   `Self.interpreting` turns a Core term into another Core term — the
   interpreter applied to the encoded program and the encoded globals — so the
   result is itself something a further layer can interpret. That gives a ladder:

     layer 0   the ground evaluator runs the program
     layer 1   the ground evaluator runs the interpreter, which runs the program
     layer 2   … which runs the interpreter, which runs the program

   Every layer must answer the same thing and leave the same trace. That is the
   iteration half of task 2.3, and it is a stronger statement than layer 1's
   agreement alone: layer 2 only works if the encoding survives being applied to
   the interpreter's own lowering, and if a primitive handed down two levels is
   still something the bottom level can apply.

   Layer 2 is the ground evaluator running an interpreter running an interpreter,
   so its cost is the product of the two. Which programs it runs is decided by a
   deterministic Ash-level step budget rather than by wall time (AGENTS test
   expectations): a program is compared at layer 2 when its layer-0 run takes at
   most [budget] evaluator steps. Today that admits every corpus program but the
   ten-thousand-iteration loop, and the numbers are printed so a change in either
   direction is visible. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_self

let failures = ref 0

let file = "l.ash"

(* Evaluator steps at layer 0, which is what decides whether a program is small
   enough to run twice interpreted. Deterministic, and a property of the program
   rather than of the machine the suite runs on. *)
let budget = 800

type outcome = { result : (Value.value, Error.t) result; trace : Io.event list }

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

(* Failures the interpreted level detects itself rather than delegating; the same
   boundary `self_host_test.ml` names, reached the same way at every layer. Here
   it is enough that both layers diagnose it themselves, which is what comparing
   causes only when the interpreted one is not a self-diagnosis amounts to. *)
let self_diagnosed error =
  match error.Error.cause with
  | Error.No_matching_clause _ -> true
  | Error.Unbound_ident _ | Error.Unbound_name _ | Error.Ambiguous_name _
  | Error.Unfilled_binding _ | Error.Open_code _ | Error.Unliftable_value _
  | Error.Unexpected_character _
  | Error.Unterminated _
  | Error.Unexpected _ | Error.Unknown_form _ | Error.Malformed_form _
  | Error.Arity_error _ | Error.Division_by_zero | Error.Continuation_reuse _
  | Error.Immutable_binding _ | Error.Unsupported _ | Error.Duplicate_binder _
  | Error.Inconsistent_pattern_binders _ | Error.End_of_input ->
      false

let difference ~reference ~compared a b =
  match (a.result, b.result) with
  | Ok x, Ok y when not (Value.equal (Encode.reveal x) y) ->
      Some
        (Printf.sprintf "value: %s gave %s, %s gave %s" reference
           (Value.to_string (Encode.reveal x))
           compared (Value.to_string y))
  | Ok x, Error e ->
      Some
        (Printf.sprintf "%s gave %s where %s failed: %s" reference (Value.to_string x)
           compared (Error.to_string e))
  | Error e, Ok y ->
      Some
        (Printf.sprintf "%s failed where %s gave %s: %s" reference compared
           (Value.to_string y) (Error.to_string e))
  | Error x, Error y
    when (not (Error.cause_equal x.Error.cause y.Error.cause)) && not (self_diagnosed y) ->
      Some
        (Printf.sprintf "cause: %s said %s, %s said %s" reference
           (Error.cause_message x.Error.cause)
           compared
           (Error.cause_message y.Error.cause))
  | (Ok _ | Error _), (Ok _ | Error _) ->
      if List.equal Io.event_equal a.trace b.trace then None
      else
        Some
          (Printf.sprintf "output: %s left [%s], %s left [%s]" reference
             (String.concat "; " (List.map Io.event_to_string a.trace))
             compared
             (String.concat "; " (List.map Io.event_to_string b.trace)))

let compared_at_layer_2 = ref 0
let skipped = ref []

let compare_layers name term ~globals ~io =
  let run evaluate =
    Io.clear io;
    let result = attempt evaluate in
    { result; trace = Io.events io }
  in
  let env () = Env.extend globals Value.empty_env in
  let machine = Evaluator.machine () in
  let ground = run (fun () -> Evaluator.run machine ~env:(env ()) term) in
  let steps = Machine.steps machine in
  let report layer outcome =
    match difference ~reference:"the ground evaluator" ~compared:layer ground outcome with
    | None -> ()
    | Some explanation ->
        incr failures;
        Printf.printf "FAIL %s\n  %s\n" name explanation
  in
  report "layer 1" (run (fun () -> Self.eval ~layers:1 ~globals term));
  if steps > budget then skipped := (name, steps) :: !skipped
  else (
    incr compared_at_layer_2;
    report "layer 2" (run (fun () -> Self.eval ~layers:2 ~globals term)))

let registry () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  (globals, named, Primitives.io registry)

let agree name text =
  let globals, named, io = registry () in
  compare_layers name
    (Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text)
    ~globals ~io

let agree_surface name source =
  let globals, named, io = registry () in
  match
    attempt (fun () ->
        Desugar.program ~scope:(Desugar.scope_of_globals named) (Parser.program ~file source))
  with
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  did not lower: %s\n" name (Error.to_string error)
  | Ok term -> compare_layers name term ~globals ~io

(* Output and control again, because they are the two things the encoding is
   most likely to lose on the way down a second level: an effect has to reach the
   one stream through two interpreters, and a capture has to happen at the layer
   that owns the continuation rather than at either of the ones below it. *)
let extra =
  [
    ("output: a write", "(app (var println) (lit 1))");
    ("output: writes in order",
     "(let _ (app (var println) (lit 1)) (app (var print) (lit \"a\")))");
    ("control: an escape",
     "(app (var callcc) (lam (k) (app (var +) (lit 1) (app (var k) (lit 10)))))");
    ("control: an unused capture",
     "(app (var callcc) (lam (k) (app (var +) (lit 1) (lit 2))))");
    (* A closure crossing two encodings still has no host counterpart, and every
       layer must say so the same way. *)
    ("a returned closure", "(lam (x) (var x))");
    ("a list of closures", "(app (var list) (lam (x) (var x)) (lit 1))");
    (* A primitive travels down unwrapped, so it is still the same primitive two
       levels below and still compares by name. *)
    ("a primitive as a value", "(app (var ==) (var head) (var head))");
    ("a primitive passed and applied",
     "(app (lam (f) (app (var f) (app (var list) (lit 7)))) (var head))");
  ]

let () =
  List.iter (fun (name, text) -> agree ("value: " ^ name) text) Corpus.values;
  List.iter (fun (name, text) -> agree ("effect: " ^ name) text) Corpus.effects;
  List.iter (fun (name, text) -> agree ("error: " ^ name) text) Corpus.errors;
  List.iter (fun (name, source) -> agree_surface ("surface: " ^ name) source) Corpus.surface;
  List.iter
    (fun (name, source) -> agree_surface ("surface error: " ^ name) source)
    Corpus.surface_errors;
  List.iter (fun (name, text) -> agree name text) extra;
  let total =
    List.length Corpus.values + List.length Corpus.effects + List.length Corpus.errors
    + List.length Corpus.surface + List.length Corpus.surface_errors
    + List.length extra
  in
  Printf.printf "layer agreement: %d programs at layer 1, %d of them at layer 2\n" total
    !compared_at_layer_2;
  List.iter
    (fun (name, steps) ->
      Printf.printf "  over the %d-step budget, so layer 1 only: %s (%d steps)\n" budget name
        steps)
    (List.rev !skipped);
  if !failures > 0 then (
    Printf.printf "%d layer disagreement(s)\n" !failures;
    exit 1)
