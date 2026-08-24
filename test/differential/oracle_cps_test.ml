(* The oracle/CPS differential corpus (to-do tasks 0.8 and 1.6).

   The frozen direct-style oracle and the real CPS evaluator are two independent
   implementations of the same semantics. On the ordinary corpus they must agree
   on the value a program produces, on the error it fails with, on where that
   error is reported, and on the observable trace it leaves. A difference is a
   bug in one of them, and the point of keeping the oracle simple is that it is
   usually the other one.

   Since task 1.4 the corpus has two halves. The Core half is written in the
   canonical notation, which is what the self-interpreter will read; the surface
   half is written in Ash and lowered by the desugarer, which additionally puts
   the whole front end under the same comparison. *)

open Ash_core
open Ash_syntax
open Ash_runtime

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "d.ash"

type outcome = {
  result : (Value.value, Error.t) result;
  trace : Io.event list;  (** What the run observably did, in order. *)
}

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

(* What the program is supposed to do. Agreement alone is not enough: two
   evaluators that both refused everything would agree perfectly, so each entry
   also says whether it is meant to produce a value or a diagnostic. *)
type expectation = Succeeds | Fails

(* The first difference, and only the first: a report that lists everything two
   runs disagree about buries the one fact that explains the rest. The order is
   what a reader would check by hand — did they both fail, did they fail the same
   way, in the same place, having done the same things. *)
let difference oracle cps =
  match (oracle.result, cps.result) with
  | Ok a, Ok b when not (Value.equal a b) ->
      Some
        (Printf.sprintf "value: the oracle gave %s, the CPS evaluator gave %s"
           (Value.to_string a) (Value.to_string b))
  | Ok a, Error e ->
      Some
        (Printf.sprintf "the oracle gave %s where the CPS evaluator failed: %s"
           (Value.to_string a) (Error.to_string e))
  | Error e, Ok b ->
      Some
        (Printf.sprintf "the oracle failed where the CPS evaluator gave %s: %s"
           (Value.to_string b) (Error.to_string e))
  | Error a, Error b when not (Error.cause_equal a.Error.cause b.Error.cause) ->
      Some
        (Printf.sprintf "cause: the oracle said %s, the CPS evaluator said %s"
           (Error.cause_message a.Error.cause)
           (Error.cause_message b.Error.cause))
  | Error a, Error b when not (Span.equal a.Error.span b.Error.span) ->
      Some
        (Printf.sprintf "location: the oracle reported %s, the CPS evaluator reported %s"
           (Span.to_string a.Error.span) (Span.to_string b.Error.span))
  | (Ok _ | Error _), (Ok _ | Error _) ->
      if List.equal Io.event_equal oracle.trace cps.trace then None
      else
        Some
          (Printf.sprintf "output: the oracle left [%s], the CPS evaluator left [%s]"
             (String.concat "; " (List.map Io.event_to_string oracle.trace))
             (String.concat "; " (List.map Io.event_to_string cps.trace)))

(* One registry, so both runs share the primitive values and the one observable
   stream, and a fresh frame of cells per run, so a program that mutates does not
   leak from the first run into the second. The stream is cleared between runs so
   each trace is that run's alone. *)
let compare_runs name term ~expect ~globals ~io =
  let run evaluate =
    Io.clear io;
    let result = attempt (fun () -> evaluate (Env.extend globals Value.empty_env)) in
    { result; trace = Io.events io }
  in
  let oracle = run (fun env -> Oracle.eval ~env term) in
  let cps = run (fun env -> Evaluator.eval ~env term) in
  (match (expect, cps.result) with
  | Succeeds, Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  was meant to produce a value: %s\n" name
        (Error.to_string error)
  | Fails, Ok value ->
      incr failures;
      Printf.printf "FAIL %s\n  was meant to fail, gave %s\n" name
        (Value.to_string value)
  | (Succeeds | Fails), (Ok _ | Error _) -> ());
  match difference oracle cps with
  | None -> ()
  | Some explanation ->
      incr failures;
      Printf.printf "FAIL %s\n  %s\n" name explanation

let registry () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  (globals, named, Primitives.io registry)

(* A Core program, in the canonical notation. *)
let agree ~expect name text =
  let globals, named, io = registry () in
  let term = Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text in
  compare_runs name term ~expect ~globals ~io

(* An Ash program, through the parser and desugarer first. *)
let agree_surface ~expect name source =
  let globals, named, io = registry () in
  match
    attempt (fun () ->
        Desugar.program ~scope:(Desugar.scope_of_globals named) (Parser.program ~file source))
  with
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  did not lower: %s\n" name (Error.to_string error)
  | Ok term -> compare_runs name term ~expect ~globals ~io

(* The deliberate divergences. These are not failures of agreement: they are the
   boundary the oracle is frozen at, and it is checked so that a later change
   cannot quietly move it. *)

let test_frozen_boundary () =
  let refused_by_oracle text =
    let globals, named, _ = registry () in
    let term = Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text in
    let fresh () = Env.extend globals Value.empty_env in
    let oracle = attempt (fun () -> Oracle.eval ~env:(fresh ()) term) in
    let cps = attempt (fun () -> Evaluator.eval ~env:(fresh ()) term) in
    let refused =
      match oracle with
      | Error error -> (
          match error.Error.cause with
          | Error.Unsupported { by; _ } -> String.equal by "the direct-style oracle"
          | Error.Unbound_ident _ | Error.Unbound_name _ | Error.Ambiguous_name _
          | Error.Unfilled_binding _ | Error.Open_code _ | Error.Unliftable_value _
          | Error.Unexpected_character _
          | Error.Unterminated _ | Error.Unexpected _ | Error.Unknown_form _
          | Error.Malformed_form _ | Error.Arity_error _ | Error.Division_by_zero
          | Error.Continuation_reuse _ | Error.Immutable_binding _
          | Error.No_matching_clause _ | Error.Duplicate_binder _
          | Error.Inconsistent_pattern_binders _ | Error.End_of_input ->
              false)
      | Ok _ -> false
    in
    check ("the oracle refuses " ^ text) refused;
    check ("the real evaluator handles " ^ text) (Result.is_ok cps)
  in
  refused_by_oracle "(quote (lit 1))";
  refused_by_oracle "(reifier (e r k) (var e))";
  (* Control and observable effects are outside the pure corpus by construction,
     which is why neither appears above. *)
  refused_by_oracle "(app (var callcc) (lam (k) (lit 1)))";
  refused_by_oracle "(app (var println) (lit 1))";
  refused_by_oracle "(app (var cell_new) (lit 1))"

(* The harness itself: a comparison that cannot see a difference proves nothing,
   so the reporting is checked against outcomes known to differ. *)

let test_reporting () =
  let ok value = { result = Ok value; trace = [] } in
  let failed cause span = { result = Error (Error.make ~phase:Error.Evaluate ~span cause); trace = [] } in
  (* Positions are identified by file and byte offset, so two distinguishable
     points need distinguishable offsets. *)
  let point offset =
    Span.point (Span.position ~file ~line:1 ~column:(offset + 1) ~offset)
  in
  let reports name expected outcome_a outcome_b =
    match difference outcome_a outcome_b with
    | Some explanation ->
        check
          (Printf.sprintf "%s is reported as a %s difference" name expected)
          (String.length explanation > 0
          && String.length expected <= String.length explanation
          && String.equal expected (String.sub explanation 0 (String.length expected)))
    | None ->
        incr failures;
        Printf.printf "FAIL %s was not reported at all\n" name
  in
  check "identical outcomes have no difference"
    (difference (ok (Value.Num 1)) (ok (Value.Num 1)) = None);
  reports "a differing value" "value:" (ok (Value.Num 1)) (ok (Value.Num 2));
  reports "one side failing" "the oracle gave" (ok (Value.Num 1))
    (failed Error.Division_by_zero (point 0));
  reports "a differing cause" "cause:"
    (failed Error.Division_by_zero (point 0))
    (failed Error.End_of_input (point 0));
  reports "a differing location" "location:"
    (failed Error.Division_by_zero (point 0))
    (failed Error.Division_by_zero (point 7));
  reports "a differing trace" "output:"
    { result = Ok Value.Unit; trace = [ Io.Wrote "a" ] }
    { result = Ok Value.Unit; trace = [] };
  (* The pure corpus must leave no trace at all; a program that printed would
     make the two halves of every comparison incomparable. *)
  check "the corpus is silent"
    (let _, _, io = registry () in
     Io.events io = [])

let () =
  List.iter (fun (name, text) -> agree ~expect:Succeeds ("value: " ^ name) text) Corpus.values;
  List.iter (fun (name, text) -> agree ~expect:Succeeds ("effect: " ^ name) text) Corpus.effects;
  List.iter (fun (name, text) -> agree ~expect:Fails ("error: " ^ name) text) Corpus.errors;
  List.iter
    (fun (name, source) -> agree_surface ~expect:Succeeds ("surface: " ^ name) source)
    Corpus.surface;
  List.iter
    (fun (name, source) -> agree_surface ~expect:Fails ("surface error: " ^ name) source)
    Corpus.surface_errors;
  test_frozen_boundary ();
  test_reporting ();
  Printf.printf "differential corpus: %d Core and %d surface programs compared\n"
    (List.length Corpus.values + List.length Corpus.effects
    + List.length Corpus.errors)
    (List.length Corpus.surface + List.length Corpus.surface_errors);
  if !failures > 0 then (
    Printf.printf "%d differential disagreement(s)\n" !failures;
    exit 1)
