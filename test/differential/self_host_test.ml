(* The self-interpreter/host differential corpus (to-do task 2.2).

   `lib/self/eval.ash` is an evaluator for the same eleven forms as the ground
   evaluator in `lib/runtime`, written in Ash rather than OCaml. Acceptance for
   task 2.2 is that it matches the host evaluator on the ordinary corpus, and
   the corpus it is compared over is exactly the one the oracle and the CPS
   evaluator already agree on — the same programs, in `corpus.ml`, so that the
   second comparison cannot quietly be run against easier ones.

   What is compared, and what is not:

   - {b Value.} Compared, after {!Ash_self.Self.reveal} maps each host value
     that carries identity to its tag, since an interpreted closure is not a
     host closure and never could be.
   - {b Trace.} Compared. The interpreted level writes to the same stream
     through the same primitives.
   - {b Cause and location.} Compared for every failure. Code carries the source
     node through the level, and source-preserving evaluator primitives attribute
     both delegated and locally detected failures to that node. *)

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

(* The first difference, and only the first, in the order a reader would check
   it by hand: did they both fail, did they fail the same way, having done the
   same things. *)
let difference _name host self =
  match (host.result, self.result) with
  | Ok a, Ok b when not (Value.equal (Self.reveal a) b) ->
      Some
        (Printf.sprintf "value: the host gave %s, the self-interpreter gave %s"
           (Value.to_string (Self.reveal a))
           (Value.to_string b))
  | Ok a, Error e ->
      Some
        (Printf.sprintf "the host gave %s where the self-interpreter failed: %s"
           (Value.to_string a) (Error.to_string e))
  | Error e, Ok b ->
      Some
        (Printf.sprintf "the host failed where the self-interpreter gave %s: %s"
           (Value.to_string b) (Error.to_string e))
  | Error a, Error b when not (Error.cause_equal a.Error.cause b.Error.cause) ->
      Some
        (Printf.sprintf "cause: the host said %s, the self-interpreter said %s"
           (Error.cause_message a.Error.cause)
           (Error.cause_message b.Error.cause))
  | Error a, Error b when not (Span.equal a.Error.span b.Error.span) ->
      Some
        (Printf.sprintf "location: the host reported %s, the self-interpreter reported %s"
           (Span.to_string a.Error.span) (Span.to_string b.Error.span))
  | Error a, Error b
    when a.Error.phase <> b.Error.phase
         || not (Option.equal Int.equal a.Error.level b.Error.level) ->
      Some
        (Printf.sprintf "error context: the host said %s, the self-interpreter said %s"
           (Error.to_string a) (Error.to_string b))
  | (Ok _ | Error _), (Ok _ | Error _) ->
      if List.equal Io.event_equal host.trace self.trace then None
      else
        Some
          (Printf.sprintf "output: the host left [%s], the self-interpreter left [%s]"
             (String.concat "; " (List.map Io.event_to_string host.trace))
             (String.concat "; " (List.map Io.event_to_string self.trace)))

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
  let globals, named, io = registry () in
  let term text =
    Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text
  in
  compare_runs "error: applying a reifier"
    (term "(app (reifier (e r k) (var e)) (lit 1))") ~expect:Fails
    ~globals ~io;
  (* Code is now the common transport and result representation. *)
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
  check "the self-interpreter answers a quotation with the same Code"
    (Value.equal self host)

let test_unbound_code_keeps_its_source () =
  let globals, _, io = registry () in
  let span =
    Span.make
      ~start:(Span.position ~file ~line:7 ~column:4 ~offset:30)
      ~stop:(Span.position ~file ~line:7 ~column:11 ~offset:37)
  in
  compare_runs "error: an unbound hygienic variable"
    (Core.var ~span (Ident.fresh "missing")) ~expect:Fails ~globals ~io

let continuation_reuse =
  "var saved = 0\n\
   let v = callcc(fn(k) -> { saved := k\n  0 })\n\
   if v == 0 then saved(1) else saved(2)"

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
  agree ~expect:Succeeds "code: explicit NamedVar lookup" "(named-var \"+\")";
  agree_surface ~expect:Fails "control error: continuation reuse" continuation_reuse;
  test_boundary ();
  test_unbound_code_keeps_its_source ();
  Printf.printf
    "self-interpreter corpus: %d Core, %d surface, %d output, and %d control programs \
     compared\n"
    (List.length Corpus.values + List.length Corpus.effects + List.length Corpus.errors)
    (List.length Corpus.surface + List.length Corpus.surface_errors)
    (List.length observable) (List.length control);
  if !failures > 0 then (
    Printf.printf "%d self-interpreter disagreement(s)\n" !failures;
    exit 1)
