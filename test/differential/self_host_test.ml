(* The self-interpreter/host differential corpus (to-do task 2.2).

   `lib/self/eval.ash` is an evaluator for the same eleven forms as the ground
   evaluator in `lib/runtime`, written in Ash rather than OCaml. Acceptance for
   task 2.2 is that it matches the host evaluator on the ordinary corpus, and
   the corpus it is compared over is exactly the one the oracle and the CPS
   evaluator already agree on — the same programs, in `corpus.ml`, so that the
   second comparison cannot quietly be run against easier ones.

   What is compared, and what is not:

   - {b Value.} Compared, after {!Ash_self.Encode.reveal} maps each host value
     that carries identity to its tag, since an interpreted closure is not a
     host closure and never could be.
   - {b Trace.} Compared. The interpreted level writes to the same stream
     through the same primitives.
   - {b Cause.} Compared for every failure a primitive raises, which is most of
     them. The exceptions are listed in [own_diagnosis] below and are checked to
     be exactly that list.
   - {b Location.} Not compared. An encoded term carries no spans, so a failure
     is reported where in `eval.ash` it was raised. Spans cross when [Code]
     does, in Phase 3. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_self

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "s.ash"

type outcome = { result : (Value.value, Error.t) result; trace : Io.event list }

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

type expectation = Succeeds | Fails

(* Failures the interpreted level detects itself rather than delegating to a
   primitive. Ash cannot construct a structured error — a cause carries a span,
   and the encoding has none until `Code` does — so these report as
   [No_matching_clause] naming the condition. The list is closed, and a program
   that leaves it is a difference like any other: this is a boundary, not a
   licence to disagree. *)
let own_diagnosis =
  [
    "error: an anonymous arity error";
    "error: a nullary lambda given an argument";
    "error: a named arity error";
    "surface error: an arity error on a named function";
  ]

let self_diagnosed name error =
  List.mem name own_diagnosis
  &&
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

(* The first difference, and only the first, in the order a reader would check
   it by hand: did they both fail, did they fail the same way, having done the
   same things. *)
let difference name host self =
  match (host.result, self.result) with
  | Ok a, Ok b when not (Value.equal (Encode.reveal a) b) ->
      Some
        (Printf.sprintf "value: the host gave %s, the self-interpreter gave %s"
           (Value.to_string (Encode.reveal a))
           (Value.to_string b))
  | Ok a, Error e ->
      Some
        (Printf.sprintf "the host gave %s where the self-interpreter failed: %s"
           (Value.to_string a) (Error.to_string e))
  | Error e, Ok b ->
      Some
        (Printf.sprintf "the host failed where the self-interpreter gave %s: %s"
           (Value.to_string b) (Error.to_string e))
  | Error a, Error b
    when (not (Error.cause_equal a.Error.cause b.Error.cause))
         && not (self_diagnosed name b) ->
      Some
        (Printf.sprintf "cause: the host said %s, the self-interpreter said %s"
           (Error.cause_message a.Error.cause)
           (Error.cause_message b.Error.cause))
  | (Ok _ | Error _), (Ok _ | Error _) ->
      if List.equal Io.event_equal host.trace self.trace then None
      else
        Some
          (Printf.sprintf "output: the host left [%s], the self-interpreter left [%s]"
             (String.concat "; " (List.map Io.event_to_string host.trace))
             (String.concat "; " (List.map Io.event_to_string self.trace)))

(* Each entry in [own_diagnosis] must actually be one, or the list is protecting
   a program that has started agreeing and nobody noticed. *)
let exercised = Hashtbl.create 8

let compare_runs name term ~expect ~globals ~io =
  let run evaluate =
    Io.clear io;
    let result = attempt evaluate in
    { result; trace = Io.events io }
  in
  let host =
    run (fun () -> Evaluator.eval ~env:(Env.extend globals Value.empty_env) term)
  in
  let self = run (fun () -> Self.eval ~globals term) in
  (match (expect, self.result) with
  | Succeeds, Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  was meant to produce a value: %s\n" name
        (Error.to_string error)
  | Fails, Ok value ->
      incr failures;
      Printf.printf "FAIL %s\n  was meant to fail, gave %s\n" name (Value.to_string value)
  | (Succeeds | Fails), (Ok _ | Error _) -> ());
  (match (host.result, self.result) with
  | Error a, Error b
    when (not (Error.cause_equal a.Error.cause b.Error.cause)) && self_diagnosed name b
    ->
      Hashtbl.replace exercised name ()
  | (Ok _ | Error _), (Ok _ | Error _) -> ());
  match difference name host self with
  | None -> ()
  | Some explanation ->
      incr failures;
      Printf.printf "FAIL %s\n  %s\n" name explanation

let registry () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  (globals, named, Primitives.io registry)

let agree ~expect name text =
  let globals, named, io = registry () in
  let term = Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text in
  compare_runs name term ~expect ~globals ~io

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

(* Output, which the oracle refuses and the corpus above is therefore silent
   about. The interpreted level applies the same [println] to the same stream,
   so the trace is a real comparison here rather than two empty lists. *)
let observable =
  [
    ("a single write", "(app (var println) (lit 1))");
    ("writes in order",
     "(let _ (app (var println) (lit 1)) (let _ (app (var print) (lit \"a\")) (app (var println) (lit 2))))");
    ("output from inside a recursion",
     "(letrec ((down (lam (n) (if (app (var ==) (var n) (lit 0)) (lit 'done) (let _ (app (var println) (var n)) (app (var down) (app (var -) (var n) (lit 1))))))))  (app (var down) (lit 3)))");
    ("an effect that is not reached", "(if (lit #t) (lit 1) (app (var println) (lit 2)))");
  ]

(* Control, likewise: [callcc] is the one primitive the interpreted level cannot
   delegate, because the host would capture the interpreter's continuation
   instead of the program's. *)
let control =
  [
    ("an escape", "(app (var callcc) (lam (k) (app (var +) (lit 1) (app (var k) (lit 10)))))");
    ("a continuation that is never used",
     "(app (var callcc) (lam (k) (app (var +) (lit 1) (lit 2))))");
    ("escaping a recursion",
     "(app (var callcc) (lam (out) (letrec ((down (lam (n) (if (app (var ==) (var n) (lit 3)) (app (var out) (lit 'found)) (app (var down) (app (var +) (var n) (lit 1))))))) (app (var down) (lit 0)))))");
    ("a captured continuation stored and applied later",
     "(let box (app (var cell_new) (lit 0)) (let _ (app (var callcc) (lam (k) (app (var cell_set) (var box) (var k)))) (app (var deref) (var box))))");
  ]

(* The self-interpreter's own boundary, asserted so a later change cannot move
   it quietly. Quotation yields code, and the two levels do not represent code
   the same way; applying a reifier needs the level above, which is Phase 4. *)
let test_boundary () =
  let globals, named, _ = registry () in
  let term text =
    Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text
  in
  let refuses text =
    match attempt (fun () -> Self.eval ~globals (term text)) with
    | Error _ -> true
    | Ok _ -> false
  in
  check "applying a reifier is refused, as it is on the host"
    (refuses "(app (reifier (e r k) (var e)) (lit 1))");
  (* Both levels answer a quotation with the term itself. They disagree about
     what a term is represented as, which is what Phase 3 settles. *)
  let quoted = term "(quote (lit 1))" in
  let host = Evaluator.eval ~env:(Env.extend globals Value.empty_env) quoted in
  let self = Self.eval ~globals quoted in
  check "the host answers a quotation with code"
    (match host with
    | Value.Code _ -> true
    | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
    | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
    | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
        false);
  check "the self-interpreter answers a quotation with the encoded term"
    (Value.equal self (Encode.term (term "(lit 1)")))

let test_own_diagnosis_is_exercised () =
  List.iter
    (fun name ->
      check
        (Printf.sprintf "`%s` still needs the self-interpreter's own diagnosis" name)
        (Hashtbl.mem exercised name))
    own_diagnosis

let () =
  List.iter (fun (name, text) -> agree ~expect:Succeeds ("value: " ^ name) text) Corpus.values;
  List.iter
    (fun (name, text) -> agree ~expect:Succeeds ("effect: " ^ name) text)
    Corpus.effects;
  List.iter (fun (name, text) -> agree ~expect:Fails ("error: " ^ name) text) Corpus.errors;
  List.iter
    (fun (name, source) -> agree_surface ~expect:Succeeds ("surface: " ^ name) source)
    Corpus.surface;
  List.iter
    (fun (name, source) -> agree_surface ~expect:Fails ("surface error: " ^ name) source)
    Corpus.surface_errors;
  List.iter
    (fun (name, text) -> agree ~expect:Succeeds ("output: " ^ name) text)
    observable;
  List.iter (fun (name, text) -> agree ~expect:Succeeds ("control: " ^ name) text) control;
  test_boundary ();
  test_own_diagnosis_is_exercised ();
  Printf.printf
    "self-interpreter corpus: %d Core, %d surface, %d output, and %d control programs \
     compared\n"
    (List.length Corpus.values + List.length Corpus.effects + List.length Corpus.errors)
    (List.length Corpus.surface + List.length Corpus.surface_errors)
    (List.length observable) (List.length control);
  if !failures > 0 then (
    Printf.printf "%d self-interpreter disagreement(s)\n" !failures;
    exit 1)
