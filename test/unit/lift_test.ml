(* Fixed-domain lifting (to-do task 3.3). *)

open Ash_core
open Ash_runtime

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_value name expected actual =
  if not (Value.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
      (Value.to_string expected) (Value.to_string actual))

let call_span =
  Span.make
    ~start:(Span.position ~file:"lift.ash" ~line:4 ~column:3 ~offset:40)
    ~stop:(Span.position ~file:"lift.ash" ~line:4 ~column:20 ~offset:57)

let value_span =
  Span.make
    ~start:(Span.position ~file:"lift.ash" ~line:3 ~column:7 ~offset:20)
    ~stop:(Span.position ~file:"lift.ash" ~line:3 ~column:8 ~offset:21)

type ground = {
  env : Value.env;
  lift_ident : Ident.t;
  list_ident : Ident.t;
  run_ident : Ident.t;
  primitive : string -> Value.value;
}

let ground () =
  let globals = Primitives.globals (Primitives.create ()) in
  let binding name =
    match
      List.find_opt (fun (ident, _) -> String.equal name (Ident.name ident)) globals
    with
    | Some binding -> binding
    | None -> invalid_arg (Printf.sprintf "missing primitive `%s`" name)
  in
  let lift_ident, _ = binding "lift" in
  let list_ident, _ = binding "list" in
  let run_ident, _ = binding "run" in
  {
    env = Env.extend globals Value.empty_env;
    lift_ident;
    list_ident;
    run_ident;
    primitive = (fun name -> snd (binding name));
  }

let lift_program ground value =
  let subject = Ident.fresh "subject" in
  let env = Env.bind subject value ground.env in
  let program =
    Core.app ~span:call_span
      ~func:(Core.var ~span:call_span ground.lift_ident)
      ~args:[ Core.var ~span:value_span subject ]
  in
  (env, program)

let lift ground value =
  let env, program = lift_program ground value in
  Evaluator.eval ~env program

let run_lift ground value =
  let env, lifted = lift_program ground value in
  Evaluator.eval ~env
    (Core.app ~span:call_span
       ~func:(Core.var ~span:call_span ground.run_ident)
       ~args:[ lifted ])

let expect_rejection name ground value ~found ~rendered ~path =
  match lift ground value with
  | answer ->
      incr failures;
      Printf.printf "FAIL %s\n  expected rejection, got %s\n" name
        (Value.to_string answer)
  | exception Error.Ash_error error ->
      check (name ^ " is an evaluate error") (error.Error.phase = Error.Evaluate);
      check (name ^ " points at the lift call") (Span.equal call_span error.Error.span);
      check (name ^ " has the structured origin")
        (Error.cause_equal error.Error.cause
           (Error.Unliftable_value { found; value = rendered; path }))

let test_scalars_and_lists () =
  let ground = ground () in
  let scalars =
    [
      Value.Num 42;
      Value.Bool true;
      Value.Str "ash";
      Value.Sym "stage";
      Value.Unit;
      Value.List [];
    ]
  in
  List.iter
    (fun value -> check_value ("run(lift(" ^ Value.to_string value ^ "))") value (run_lift ground value))
    scalars;
  let nested =
    Value.List
      [
        Value.Num 1;
        Value.List [ Value.Bool false; Value.Str "x"; Value.List [] ];
        Value.Sym "done";
        Value.Unit;
      ]
  in
  check_value "nested immutable lists lift recursively" nested (run_lift ground nested);
  match lift ground nested with
  | Value.Code node -> (
      check "lifted syntax retains source provenance"
        (Span.equal call_span (Span.source_span (Core.span node)));
      check "lifted syntax records its generator"
        (List.equal String.equal [ "lift" ] (Span.generators (Core.span node)));
      match Core.shape node with
      | Core.App { Core.func; _ } -> (
          match Core.shape func with
          | Core.Var ident ->
              check "a lifted list uses the level's hygienic list identity"
                (Ident.equal ground.list_ident ident)
          | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
          | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
              check "a lifted list calls a hygienic variable" false)
      | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          check "a non-empty lifted list is an application" false)
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
  | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
      check "lift returns Code" false

let test_code_passthrough () =
  let ground = ground () in
  let original = Core.lit ~span:value_span (Constant.Num 9) in
  (match lift ground (Value.Code original) with
  | Value.Code lifted ->
      check "lifting Code is identity, including provenance" (lifted == original)
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
  | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
      check "lifting Code returns Code" false);
  check_value "Code nested in a lifted list is spliced as computation"
    (Value.List [ Value.Num 9 ])
    (run_lift ground (Value.List [ Value.Code original ]))

let test_rejections () =
  let ground = ground () in
  let x = Ident.fresh "x" in
  let body = Core.var ~span:value_span x in
  let closure =
    Value.Closure
      {
        Value.clo_lambda = Core.lambda ~params:[ x ] ~body;
        clo_env = Value.empty_env;
        clo_name = None;
      }
  in
  let exp = Ident.fresh "exp" in
  let env = Ident.fresh "env" in
  let cont = Ident.fresh "cont" in
  let reifier =
    Value.Reifier
      {
        Value.reif_def = Core.reifier_def ~exp ~env ~cont ~body;
        reif_env = Value.empty_env;
        reif_name = None;
      }
  in
  let continuation =
    Value.Continuation
      (Value.continuation ~capture:value_span ~level:0 (fun value -> value))
  in
  let cases =
    [
      ("closure", closure, "a closure", "#<closure>");
      ("reifier", reifier, "a reifier", "#<reifier>");
      ("continuation", continuation, "a continuation", "#<continuation>");
      ( "environment",
        Value.Environment Value.empty_env,
        "an environment",
        "#<env 0 frames>" );
      ("cell", Value.Cell (Value.cell (Value.Num 1)), "a cell", "#<cell>");
      ("primitive", ground.primitive "+", "a primitive", "#<primitive +/2>");
    ]
  in
  List.iter
    (fun (name, value, found, rendered) ->
      expect_rejection ("lift rejects " ^ name) ground value ~found ~rendered ~path:[])
    cases;
  let nested = Value.List [ Value.Num 1; Value.List [ Value.Num 2; closure ] ] in
  expect_rejection "a nested rejection identifies its value origin" ground nested
    ~found:"a closure" ~rendered:"#<closure>" ~path:[ 2; 2 ];
  match lift ground nested with
  | _ -> check "nested rejection renders an origin" false
  | exception Error.Ash_error error ->
      check "the rejection message names the nested origin"
        (String.equal
           "cannot lift #<closure> from the lift argument list item 2 list item 2: a closure is outside the fixed lift domain"
           (Error.cause_message error.Error.cause))

let () =
  test_scalars_and_lists ();
  test_code_passthrough ();
  test_rejections ();
  if !failures > 0 then (
    Printf.printf "%d lift assertion(s) failed\n" !failures;
    exit 1)
