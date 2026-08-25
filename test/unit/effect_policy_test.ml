(* Primitive effect policy during specialization (to-do task 7.1, spec §D7).

   The trap D7 names is always one rule away: fold [print("hi")] because its
   argument is static, and now {e compilation} prints while running the compiled
   program does not. The acceptance criterion is therefore a negative —
   specialization emits no program-visible output — and a negative is only worth
   something with the positive beside it. So each case here asserts three things
   at once: what specialization wrote (nothing), what the residual still
   contains (the call), and what running the residual produces (the effect, in
   order).

   The compile-time channel is the other half, and the exact inverse:
   [static_log] is defined to run at specialization time and to leave nothing
   behind. It writes to a stream that is not the program's output, because
   otherwise "specialization printed nothing" would quietly become
   "specialization printed nothing once you ignore some of what it printed". *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_collapse

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_written name ~expected actual =
  if not (List.equal String.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: [%s]\n  actual:   [%s]\n" name
      (String.concat "; " (List.map String.escaped expected))
      (String.concat "; " (List.map String.escaped actual)))

let file = "effect_policy_test.ash"

(* One registry per case, so what a stream holds is that case's alone. *)
let ground ?input () =
  let registry = Primitives.create ?io:(Option.map (fun i -> Io.create ~input:i ()) input) () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  (registry, globals, Core_reader.scope_of_list named, Env.extend globals Value.empty_env)

let read scope text = Core_reader.read ~scope ~file text

let specialize ~env term =
  let machine = Ash_stage.Staged_eval.machine ~mode:Ash_stage.Mode.Lift () in
  match Ash_stage.Staged_eval.run machine ~env term with
  | Value.Code residual -> Some residual
  | _ -> None
  | exception Error.Ash_error _ -> None

let run ~env term =
  match Evaluator.run (Evaluator.machine ()) ~env term with
  | value -> Some value
  | exception Error.Ash_error _ -> None

(* Does [term] still call the global named [name]? By identity, not by printed
   name: the residual refers to the identity the environment bound, and a
   same-printed binding elsewhere would be a different variable. *)
let calls ~globals name term =
  match
    List.find_map
      (fun (ident, _) -> if String.equal (Ident.name ident) name then Some ident else None)
      globals
  with
  | None -> false
  | Some ident ->
      let rec search node =
        (match Core.shape node with
        | Core.Var found -> Ident.equal found ident
        | _ -> false)
        || List.exists search (Core.children node)
      in
      search term

(* {1 Observable effects always residualize} *)

(* Specialize [text], then run what came back. [survives] is the primitive whose
   call the residual must still contain, [output] what running it must write. *)
let residualizes label ~survives ~output ?input text =
  let registry, globals, scope, env = ground ?input () in
  let io = Primitives.io registry in
  let term = read scope text in
  match specialize ~env term with
  | None -> check (label ^ ": specializes") false
  | Some residual ->
      (* The criterion itself. Nothing the program could observe was produced
         while specializing — not reordered, not buffered elsewhere: nothing. *)
      check_written (label ^ ": specialization wrote nothing") ~expected:[] (Io.written io);
      check_written (label ^ ": and logged nothing") ~expected:[]
        (Io.written (Primitives.log registry));
      check (label ^ ": the call survives into the residual")
        (calls ~globals survives residual);
      Io.clear io;
      (match run ~env residual with
      | None -> check (label ^ ": the residual runs") false
      | Some _ -> ());
      check_written (label ^ ": the residual produces the effect") ~expected:output
        (Io.written io)

let test_observable () =
  (* A static argument is exactly the case that tempts a naive folder. *)
  residualizes "print with a static argument" ~survives:"print" ~output:[ "hi" ]
    "(app (var print) (lit \"hi\"))";
  residualizes "println with a static argument" ~survives:"println" ~output:[ "7\n" ]
    "(app (var println) (lit 7))";

  (* Nullary, so there is no argument knowledge to hide behind: the class alone
     has to be what stops it. Specializing must not consume the input line. *)
  residualizes "read_line" ~survives:"read_line" ~output:[ "answer\n" ]
    ~input:[ "answer" ]
    "(app (var println) (app (var read_line)))";

  (* Order is a trace property, and folding one of two effects would show up
     here as a reordering rather than as a missing line. *)
  residualizes "two effects keep their order" ~survives:"println"
    ~output:[ "one\n"; "two\n" ]
    "(let a (app (var println) (lit \"one\"))\n\
    \   (let b (app (var println) (lit \"two\")) (app (var +) (lit 1) (lit 2))))";

  (* Around a fold, not instead of one: the arithmetic collapses, the effect
     does not, and the residual is smaller than the source without being
     quieter. *)
  residualizes "an effect beside a fold" ~survives:"print" ~output:[ "x" ]
    "(let a (app (var print) (lit \"x\")) (app (var +) (lit 20) (lit 22)))";

  (* Exhaustive over the class, so a new observable primitive cannot be added
     without a decision about it here. *)
  check "the observable class is exactly the three streamed primitives"
    (List.equal String.equal
       [ "print"; "println"; "read_line" ]
       (Primitives.by_class Effect_class.Observable_effect))

(* {1 Allocation and mutation residualize until Phase 7 proves otherwise} *)

let test_mutation () =
  residualizes "cell allocation" ~survives:"cell_new" ~output:[]
    "(app (var deref) (app (var cell_new) (lit 1)))";
  residualizes "a dereference" ~survives:"deref" ~output:[]
    "(app (var deref) (app (var cell_new) (lit 1)))";
  (* [cell_set] too, through a program whose answer is the read after the write:
     folding either half would answer 2 at specialization time instead of
     leaving the store operations for the run. *)
  residualizes "a store write" ~survives:"cell_set" ~output:[]
    "(let c (app (var cell_new) (lit 1))\n\
    \   (let w (app (var cell_set) (var c) (lit 2)) (app (var deref) (var c))))"

(* {1 The compile-time channel} *)

let test_static_log () =
  let registry, globals, scope, env = ground () in
  let io = Primitives.io registry in
  let log = Primitives.log registry in
  let term =
    read scope
      "(let l (app (var static_log) (lit \"specializing\"))\n\
      \   (app (var +) (lit 20) (lit 22)))"
  in
  match specialize ~env term with
  | None -> check "static_log: specializes" false
  | Some residual ->
      (* Ran at specialization time: that is the definition, not an
         optimization. *)
      check_written "static_log: ran while specializing" ~expected:[ "specializing\n" ]
        (Io.written log);
      (* And is not program-visible output, which is what keeps the criterion
         above a statement about one stream. *)
      check_written "static_log: wrote no program output" ~expected:[] (Io.written io);
      (* Left nothing behind, so the compiled program neither logs nor pays. *)
      check "static_log: does not survive into the residual"
        (not (calls ~globals "static_log" residual));
      Io.clear log;
      (match run ~env residual with
      | Some (Value.Num 42) -> ()
      | _ -> check "static_log: the residual still computes the answer" false);
      check_written "static_log: the residual logs nothing when run" ~expected:[]
        (Io.written log);

      (* A dynamic argument is not a reason to refuse: what the specializer
         knows is the code, and the code is the useful thing to log. *)
      let registry, globals, scope, env = ground () in
      let log = Primitives.log registry in
      let dynamic =
        read scope
          "(lam (x) (let l (app (var static_log) (var x)) (app (var +) (var x) (lit 1))))"
      in
      (match specialize ~env dynamic with
      | None -> check "static_log: specializes under a lambda" false
      | Some residual ->
          check "static_log: a dynamic argument still logs"
            (List.length (Io.written log) = 1);
          check "static_log: and still leaves nothing behind"
            (not (calls ~globals "static_log" residual));
          check_written "static_log: still no program output" ~expected:[]
            (Io.written (Primitives.io registry)))

(* {1 The policy is read off the class} *)

let test_policy_is_structural () =
  (* Every primitive the specializer may run is in a class that says so, and no
     primitive is in both camps. The specializer consults these and never a
     name, which is what makes adding a primitive a classification decision
     rather than a staging decision. *)
  List.iter
    (fun (name, cls) ->
      check
        (Printf.sprintf "`%s` is not both always-residualizing and foldable" name)
        (not
           (Effect_class.always_residualizes cls && Effect_class.may_fold_when_static cls)))
    Primitives.classification;
  check "the compile-time class is exactly static_log"
    (List.equal String.equal [ "static_log" ]
       (Primitives.by_class Effect_class.Specialization_only))

(* {1 What the measurement reports} *)

let test_measurement () =
  (* The report's own claim, made over a program that prints: specialization
     output is empty and the residual carries the effect. *)
  let metrics =
    Metrics.measure ~file ~name:"effect policy"
      (Metrics.Surface "println(\"hello\")\n20 + 22")
  in
  check "the measurement records no specialization output"
    (metrics.Metrics.specialization.Metrics.output = []);
  check "and no specialization log for a program that does not use one"
    (metrics.Metrics.specialization.Metrics.log = []);
  match metrics.Metrics.residual with
  | Error _ -> check "the measured program has a residual" false
  | Ok residual ->
      check "the residual reproduces the source trace"
        (List.equal Io.event_equal metrics.Metrics.source.Metrics.output
           residual.Metrics.run.Metrics.output)

(* {1 Entry} *)

let () =
  test_observable ();
  test_mutation ();
  test_static_log ();
  test_policy_is_structural ();
  test_measurement ();
  if !failures > 0 then (
    Printf.printf "%d effect-policy failure(s)\n" !failures;
    exit 1)
  else Printf.printf "effect policy: observable residualizes, static_log does not\n"
