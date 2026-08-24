(* Reifiers and the up/down protocol (to-do task 4.2).

   The subject is level ownership: which machine runs a reifier body, which
   level a continuation resumes, and which level an error belongs to. The full
   law matrix over depths 0-5 is task 4.4; what is proved here is that one step
   up and one step back down is exactly one step, and that it lands on the right
   level in every direction. *)

open Ash_core
open Ash_runtime
open Ash_tower

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_int name expected actual =
  if not (Int.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %d\n  actual:   %d\n" name expected actual)

let check_value name expected actual =
  if not (Value.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
      (Value.to_string expected) (Value.to_string actual))

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

let expect_error name result =
  match result with
  | Error error -> Some error
  | Ok value ->
      incr failures;
      Printf.printf "FAIL %s\n  expected a failure, got %s\n" name
        (Value.to_string value);
      None

let sp = Span.unknown
let num n = Core.lit ~span:sp (Constant.Num n)
let str text = Core.lit ~span:sp (Constant.Str text)
let var identity = Core.var ~span:sp identity
let app func args = Core.app ~span:sp ~func ~args
let let_ binder value body = Core.let_ ~span:sp ~binder ~value ~body
let ignored () = Ident.fresh "_"

(* Reifier bodies are written at level 0, so their free names resolve against
   level 0's globals however far up the body itself runs. *)
let global level name =
  match Env.lookup_by_name (Level.global level) name with
  | Env.Name_found (identity, _) -> var identity
  | Env.Name_unbound | Env.Name_ambiguous _ ->
      failwith (Printf.sprintf "test fixture has no unique `%s` global" name)

(* [make_body] receives the three meta bindings as references, which is the only
   way a body can name them: they are hygienic binders, not printed names. *)
let reifier make_body =
  let exp = Ident.fresh "e" in
  let env = Ident.fresh "r" in
  let cont = Ident.fresh "k" in
  Core.reifier ~span:sp ~exp ~env ~cont
    ~body:(make_body ~exp:(var exp) ~env:(var env) ~cont:(var cont))

(* [code_view] of an application is ['App, func, args], so the first argument of
   the reified call is the head of its third field. This is the reifier's only
   route to code it must not evaluate. *)
let first_argument ground exp =
  let head node = app (global ground "head") [ node ] in
  let tail node = app (global ground "tail") [ node ] in
  head (head (tail (tail (app (global ground "code_view") [ exp ]))))

let identity_reifier ground =
  reifier (fun ~exp ~env ~cont ->
      app (global ground "reflect") [ first_argument ground exp; env; cont ])

let fresh_tower () =
  let io = Io.create () in
  let tower = Tower.create ~registry:(Primitives.create ~io ()) () in
  (tower, io)

(* The identity reifier is the round trip up and back down, and spec §5.7 asks
   it to be observationally [fn(x) -> x]: same value, same effects, once. *)
let test_identity_reifier () =
  let tower, _io = fresh_tower () in
  let ground = Tower.ground tower in
  let identity = Ident.fresh "id" in
  let program =
    let_ identity (identity_reifier ground)
      (app (global ground "+") [ app (var identity) [ app (global ground "+") [ num 1; num 2 ] ]; num 10 ])
  in
  check_int "reifier application is the first thing to materialize a level" 0
    (Tower.materialized tower);
  check_value "the identity reifier passes its argument's value through"
    (Value.Num 13) (Tower.run tower program);
  check_int "one reifier application materializes exactly one level" 1
    (Tower.materialized tower);

  (* Effects are the sharper half of the identity claim: an argument evaluated
     twice, or evaluated at the wrong level, still produces the right number. *)
  let tower, io = fresh_tower () in
  let ground = Tower.ground tower in
  let identity = Ident.fresh "id" in
  let effectful =
    let_ identity (identity_reifier ground)
      (let_ (ignored ())
         (app (var identity) [ app (global ground "print") [ str "once" ] ])
         (num 7))
  in
  check_value "the reflected argument still returns its own value" (Value.Num 7)
    (Tower.run tower effectful);
  check "the reflected argument is evaluated exactly once"
    (List.equal Io.event_equal [ Io.Wrote "once" ] (Io.events io))

(* Whole-call reification (locked decision): a reifier receives the call, not
   its values, so an argument it never reflects is never evaluated. *)
let test_arguments_are_not_evaluated () =
  let tower, io = fresh_tower () in
  let ground = Tower.ground tower in
  let quoter = Ident.fresh "answer" in
  let program =
    let_ quoter
      (reifier (fun ~exp:_ ~env:_ ~cont -> app cont [ num 99 ]))
      (app (var quoter) [ app (global ground "print") [ str "never" ] ])
  in
  check_value "the reifier's own answer resumes the caller" (Value.Num 99)
    (Tower.run tower program);
  check "an unreflected argument produces no effect" (List.equal Io.event_equal [] (Io.events io))

(* [resume] is the named form of the same transfer, and the continuation is the
   caller's: level 0 continues where its call was. *)
let test_resume () =
  let tower, _io = fresh_tower () in
  let ground = Tower.ground tower in
  let name = Ident.fresh "answer" in
  let program =
    let_ name
      (reifier (fun ~exp:_ ~env:_ ~cont -> app (global ground "resume") [ cont; num 5 ]))
      (app (global ground "+") [ app (var name) [ num 0 ]; num 1 ])
  in
  check_value "resume returns a value to the level below" (Value.Num 6)
    (Tower.run tower program)

(* A reifier that never resumes does not return to the level below at all: its
   value is the answer of the run, and the caller's pending work never happens
   (spec §5.2, read from the other side). *)
let test_unresumed_reifier_abandons_the_level_below () =
  let tower, io = fresh_tower () in
  let ground = Tower.ground tower in
  let name = Ident.fresh "stop" in
  let program =
    let_ name
      (reifier (fun ~exp:_ ~env:_ ~cont:_ -> num 42))
      (let_ (ignored ())
         (app (var name) [ num 0 ])
         (app (global ground "print") [ str "after" ]))
  in
  check_value "the meta level's value is the answer of the run" (Value.Num 42)
    (Tower.run tower program);
  check "the abandoned level does not continue"
    (List.equal Io.event_equal [] (Io.events io))

(* The continuation handed up is one-shot like every other (spec §D4), and the
   reuse belongs to the level whose control it would have corrupted.

   Resuming does not return, so a second invocation has to come from somewhere
   that outlives the transfer: the body stores the continuation in a cell it
   shares with the level below, resumes, and the resumed level invokes it
   again. That a stored continuation crosses the level boundary at all is half
   of what this checks. *)
let test_continuation_is_one_shot () =
  let tower, _io = fresh_tower () in
  let ground = Tower.ground tower in
  let name = Ident.fresh "twice" in
  let saved = Ident.fresh "saved" in
  let program =
    let_ saved
      (app (global ground "cell_new") [ num 0 ])
      (let_ name
         (reifier (fun ~exp:_ ~env:_ ~cont ->
              let_ (ignored ())
                (app (global ground "cell_set") [ var saved; cont ])
                (app (global ground "resume") [ cont; num 1 ])))
         (let_ (ignored ())
            (app (var name) [ num 0 ])
            (app (app (global ground "deref") [ var saved ]) [ num 2 ])))
  in
  match expect_error "a resumed continuation cannot be resumed again"
          (attempt (fun () -> Tower.run tower program))
  with
  | None -> ()
  | Some error ->
      check "the second resumption is reported as continuation reuse"
        (match error.Error.cause with
        | Error.Continuation_reuse _ -> true
        | Error.Unbound_ident _ | Error.Unbound_name _ | Error.Ambiguous_name _
        | Error.Unfilled_binding _ | Error.Open_code _ | Error.Unliftable_value _
        | Error.Unexpected_character _ | Error.Unterminated _ | Error.Unexpected _
        | Error.Unknown_form _ | Error.Malformed_form _ | Error.Arity_error _
        | Error.Unsupported _ | Error.Division_by_zero | Error.Meta_error _
        | Error.Immutable_binding _ | Error.No_matching_clause _
        | Error.Duplicate_binder _ | Error.Inconsistent_pattern_binders _
        | Error.End_of_input ->
            false);
      check "the reuse names the level whose control was captured"
        (error.Error.level = Some 0)

(* Nesting is one step at a time in both directions: a reifier applied inside a
   reifier body runs at level 2, holding level 1's continuation. *)
let test_nested_reification () =
  let tower, _io = fresh_tower () in
  let ground = Tower.ground tower in
  let inner = Ident.fresh "inner" in
  let outer = Ident.fresh "outer" in
  let program =
    let_ inner
      (reifier (fun ~exp:_ ~env:_ ~cont -> app cont [ num 5 ]))
      (let_ outer
         (reifier (fun ~exp:_ ~env:_ ~cont ->
              app (global ground "resume") [ cont; app (var inner) [ num 0 ] ]))
         (app (var outer) [ num 0 ]))
  in
  check_value "a reifier applied one level up answers the level below it"
    (Value.Num 5) (Tower.run tower program);
  check_int "nesting materializes exactly two levels" 2 (Tower.materialized tower);
  check "both levels are the tower's own"
    (match (Tower.find_level tower 1, Tower.find_level tower 2) with
    | Some one, Some two -> not (Level.machine one == Level.machine two)
    | (None | Some _), (None | Some _) -> false)

(* Level ownership, stated as interception: replacing level 1's evaluator
   changes the reifier body and nothing the program itself evaluates. *)
let test_body_runs_on_the_level_above () =
  let tower, _io = fresh_tower () in
  let ground = Tower.ground tower in
  let name = Ident.fresh "one" in
  let program =
    let_ name
      (reifier (fun ~exp:_ ~env:_ ~cont -> app cont [ num 1 ]))
      (app (global ground "+") [ app (var name) [ num 0 ]; num 10 ])
  in
  let level_1 = Tower.materialize_above tower ~level:0 in
  let base = Machine.current_eval (Level.machine level_1) in
  Machine.set_eval (Level.machine level_1) (fun machine node env k ->
      match Core.shape node with
      | Core.Lit (Constant.Num _) -> k (Value.Num 99)
      | Core.Lit (Constant.Bool _ | Constant.Str _ | Constant.Sym _ | Constant.Unit
        | Constant.Nil)
      | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          base machine node env k);
  check_value "the reifier body runs on the level above, patch included"
    (Value.Num 109) (Tower.run tower program)

(* Errors belong to the level that raised them, and the level below never
   resumes: reaching level n + 1 is where an error stops (spec §5.7). *)
let test_error_ownership () =
  let tower, io = fresh_tower () in
  let ground = Tower.ground tower in
  let name = Ident.fresh "boom" in
  let program =
    let_ name
      (reifier (fun ~exp:_ ~env:_ ~cont:_ ->
           app (global ground "meta_error") [ str "boom" ]))
      (let_ (ignored ())
         (app (var name) [ app (global ground "print") [ str "before" ] ])
         (app (global ground "print") [ str "after" ]))
  in
  (match
     expect_error "meta_error fails the run"
       (attempt (fun () -> Tower.run tower program))
   with
  | None -> ()
  | Some error ->
      check "meta_error reports the message it was given"
        (Error.cause_equal error.Error.cause (Error.Meta_error "boom"));
      check "a meta level's error belongs to that meta level"
        (error.Error.level = Some 1);
      check "the level below neither ran its argument nor resumed"
        (List.equal Io.event_equal [] (Io.events io)));

  (* An ordinary evaluation error inside the body belongs to the body's level. *)
  let tower, _io = fresh_tower () in
  let ghost = Ident.fresh "ghost" in
  let name = Ident.fresh "open" in
  let program =
    let_ name
      (reifier (fun ~exp:_ ~env:_ ~cont:_ -> var ghost))
      (app (var name) [ num 0 ])
  in
  (match
     expect_error "an unbound identity in a reifier body fails"
       (attempt (fun () -> Tower.run tower program))
   with
  | None -> ()
  | Some error ->
      check "the body's own error is reported at level 1"
        (error.Error.level = Some 1
        && Error.cause_equal error.Error.cause (Error.Unbound_ident ghost)));

  (* And the same error, in code reflected back down, belongs to level 0: the
     level an expression is evaluated at is the level that owns its failure. *)
  let tower, _io = fresh_tower () in
  let ground = Tower.ground tower in
  let identity = Ident.fresh "id" in
  let program =
    let_ identity (identity_reifier ground) (app (var identity) [ var ghost ])
  in
  match
    expect_error "reflected code that fails still fails"
      (attempt (fun () -> Tower.run tower program))
  with
  | None -> ()
  | Some error ->
      check "an error in reflected code belongs to the level it ran on"
        (error.Error.level = Some 0
        && Error.cause_equal error.Error.cause (Error.Unbound_ident ghost))

(* Without a tower there is no level to shift to, and refusing is the honest
   answer: the ground evaluator alone is the base program and nothing else. *)
let test_refusals_without_a_level () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let env = Env.extend globals Value.empty_env in
  let name = Ident.fresh "r" in
  let program =
    let_ name (reifier (fun ~exp:_ ~env:_ ~cont -> app cont [ num 1 ])) (app (var name) [ num 0 ])
  in
  (match
     expect_error "a machine with no tower refuses reifier application"
       (attempt (fun () -> Evaluator.eval ~env program))
   with
  | None -> ()
  | Some error ->
      check "the refusal names reifier application and reports level 0"
        (error.Error.level = Some 0
        && Error.cause_equal error.Error.cause
             (Error.Unsupported
                { what = "reifier application"; by = "the ground evaluator" })));

  (* [reflect] fails the same way from the other direction: the base program has
     nothing below it. *)
  let machine = Evaluator.machine () in
  Machine.set_global_env machine env;
  let reflect =
    match Primitives.find registry "reflect" with
    | Some primitive -> Value.Primitive primitive
    | None -> failwith "test fixture has no `reflect` primitive"
  in
  let arguments =
    [
      Value.Code (num 1);
      Value.Environment env;
      Value.Continuation (Value.continuation ~capture:sp ~level:0 (fun value -> value));
    ]
  in
  match
    expect_error "the base program cannot reflect"
      (attempt (fun () ->
           Machine.apply machine ~call_site:sp reflect arguments (fun value -> value)))
  with
  | None -> ()
  | Some error ->
      check "the refusal says there is no level below"
        (Error.cause_equal error.Error.cause
           (Error.Unsupported
              {
                what = "reflect";
                by = "the base program, which has no level below it";
              }))

let () =
  test_identity_reifier ();
  test_arguments_are_not_evaluated ();
  test_resume ();
  test_unresumed_reifier_abandons_the_level_below ();
  test_continuation_is_one_shot ();
  test_nested_reification ();
  test_body_runs_on_the_level_above ();
  test_error_ownership ();
  test_refusals_without_a_level ();
  if !failures > 0 then (
    Printf.printf "%d reifier assertion(s) failed\n" !failures;
    exit 1)
