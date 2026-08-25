(* Unit tests for static/dynamic values and maybe-lift evaluator mode (to-do task 5.1). *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_stage

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_string name expected actual =
  if not (String.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name expected actual)

let file = "stage_test.ash"

let ground () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Core_reader.scope_of_list named in
  let env = Env.extend globals Value.empty_env in
  (registry, globals, named, scope, env)

let read_with scope text = Core_reader.read ~scope ~file text

let evaluate ?(mode = Mode.Identity) text =
  let _, _, _, scope, env = ground () in
  let term = read_with scope text in
  Staged_eval.eval ~mode ~env term

let fold_term text =
  let _, _, _, scope, env = ground () in
  let term = read_with scope text in
  Staged_eval.fold ~env term

let check_value ?(mode = Mode.Identity) name expected text =
  match evaluate ~mode text with
  | actual ->
      if not (Value.equal expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Value.to_string expected) (Value.to_string actual))
  | exception Error.Ash_error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name (Error.to_string error)

let check_error ?(mode = Mode.Identity) name ~cause text =
  match evaluate ~mode text with
  | value ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an error, got %s\n" name (Value.to_string value)
  | exception Error.Ash_error error ->
      if not (Error.cause_equal error.Error.cause cause) then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong cause: %s\n" name (Error.to_string error))

let check_folded name expected_text source_text =
  try
    let _, _, _, scope, _ = ground () in
    let actual_core = fold_term source_text in
    let expected_core = read_with scope expected_text in
    if not (Alpha.equal expected_core actual_core) then (
      incr failures;
      Printf.printf "FAIL %s\n  expected Core: %s\n  actual Core:   %s\n" name
        (Core_printer.to_string expected_core) (Core_printer.to_string actual_core))
  with Error.Ash_error error ->
    incr failures;
    Printf.printf "FAIL %s\n  unexpected error: %s\n" name (Error.to_string error)

(* 1. Value model & Policy Predicates *)

let test_value_predicates () =
  let _, _, _, _scope, env = ground () in
  let dummy_span = Span.point (Span.position ~file ~line:1 ~column:1 ~offset:0) in
  let code_val = Value.Code (Core.lit ~span:dummy_span (Constant.Num 42)) in
  let num_val = Value.Num 42 in
  let bool_val = Value.Bool true in
  let str_val = Value.Str "hello" in
  let sym_val = Value.Sym "sym" in
  let unit_val = Value.Unit in
  let list_static = Value.List [ Value.Num 1; Value.Num 2 ] in
  let list_dyn = Value.List [ Value.Num 1; code_val ] in

  check "Num is static" (Stage_value.is_static num_val);
  check "Num is not dynamic" (not (Stage_value.is_dynamic num_val));
  check "Num is static_value" (Stage_value.static_value num_val);
  check "Num is purely static" (Stage_value.is_purely_static num_val);

  check "Bool is static" (Stage_value.is_static bool_val);
  check "Str is static" (Stage_value.is_static str_val);
  check "Sym is static" (Stage_value.is_static sym_val);
  check "Unit is static" (Stage_value.is_static unit_val);

  check "Code is dynamic" (Stage_value.is_dynamic code_val);
  check "Code is not static" (not (Stage_value.is_static code_val));
  check "Code is not static_value" (not (Stage_value.static_value code_val));
  check "Code is not purely static" (not (Stage_value.is_purely_static code_val));
  check "dynamic_code extracts Core from Code" (Option.is_some (Stage_value.dynamic_code code_val));
  check "dynamic_code returns None for Num" (Option.is_none (Stage_value.dynamic_code num_val));

  check "static list is static" (Stage_value.is_static list_static);
  check "static list is purely static" (Stage_value.is_purely_static list_static);
  check "mixed list is not purely static" (not (Stage_value.is_purely_static list_dyn));

  let machine = Staged_eval.machine () in
  Machine.set_global_env machine env;
  let lifted_num = Stage_value.lift_to_code ~call_site:dummy_span machine num_val in
  check "lift_to_code on Num produces Lit"
    (match Core.shape lifted_num with Core.Lit (Constant.Num 42) -> true | _ -> false);

  let lifted_code = Stage_value.lift_to_code ~call_site:dummy_span machine code_val in
  check "lift_to_code on Code returns same node" (Alpha.equal (match code_val with Value.Code c -> c | _ -> assert false) lifted_code);

  let id_lifted = Stage_value.maybe_lift ~mode:Mode.Identity ~call_site:dummy_span machine num_val in
  check "maybe_lift Identity leaves Num untouched" (Value.equal num_val id_lifted);

  let staged_lifted = Stage_value.maybe_lift ~mode:Mode.Lift ~call_site:dummy_span machine num_val in
  check "maybe_lift Lift produces Code"
    (match staged_lifted with
    | Value.Code node -> (match Core.shape node with Core.Lit (Constant.Num 42) -> true | _ -> false)
    | _ -> false)

(* 2. Mode Operations *)

let test_mode () =
  check "Mode.Identity is_identity" (Mode.is_identity Mode.Identity);
  check "Mode.Identity is not is_lift" (not (Mode.is_lift Mode.Identity));
  check "Mode.Lift is_lift" (Mode.is_lift Mode.Lift);
  check "Mode.Lift is not is_identity" (not (Mode.is_identity Mode.Lift));
  check_string "Mode.Identity name" "identity" (Mode.name Mode.Identity);
  check_string "Mode.Lift name" "lift" (Mode.name Mode.Lift);
  check "Mode.equal Identity Identity" (Mode.equal Mode.Identity Mode.Identity);
  check "Mode.equal Lift Lift" (Mode.equal Mode.Lift Mode.Lift);
  check "not Mode.equal Identity Lift" (not (Mode.equal Mode.Identity Mode.Lift));
  check "Mode.compare Identity Lift < 0" (Mode.compare Mode.Identity Mode.Lift < 0);
  check "Mode.compare Lift Identity > 0" (Mode.compare Mode.Lift Mode.Identity > 0)

(* 3. Ordinary Evaluation in Identity Mode *)

let test_identity_mode () =
  check_value ~mode:Mode.Identity "arithmetic in identity mode" (Value.Num 7)
    "(app (var +) (lit 1) (app (var *) (lit 2) (lit 3)))";
  check_value ~mode:Mode.Identity "if true in identity mode" (Value.Num 10)
    "(if (lit #t) (lit 10) (lit 20))";
  check_value ~mode:Mode.Identity "if false in identity mode" (Value.Num 20)
    "(if (lit #f) (lit 10) (lit 20))";
  check_value ~mode:Mode.Identity "let in identity mode" (Value.Num 30)
    "(let x (lit 10) (let y (lit 20) (app (var +) (var x) (var y))))";
  check_value ~mode:Mode.Identity "lambda in identity mode" (Value.Num 13)
    "(app (lam (x y) (app (var +) (app (var *) (var x) (var y)) (lit 1))) (lit 3) (lit 4))";
  check_value ~mode:Mode.Identity "factorial in identity mode" (Value.Num 120)
    "(letrec ((fact (lam (n)\n\
    \                 (if (app (var ==) (var n) (lit 0))\n\
    \                     (lit 1)\n\
    \                     (app (var *) (var n) (app (var fact) (app (var -) (var n) (lit 1))))))))\n\
    \  (app (var fact) (lit 5)))";
  check_value ~mode:Mode.Identity "list ops in identity mode" (Value.Num 10)
    "(app (var head) (app (var list) (lit 10) (lit 20) (lit 30)))";
  check_value ~mode:Mode.Identity "callcc in identity mode" (Value.Num 42)
    "(app (var callcc) (lam (k) (app (var +) (lit 1) (app (var k) (lit 42)))))";
  check_error ~mode:Mode.Identity "type error in identity mode"
    ~cause:(Error.Unexpected { found = "a number"; expected = "a boolean" })
    "(if (lit 1) (lit 10) (lit 20))";
  check_error ~mode:Mode.Identity "div by zero in identity mode"
    ~cause:Error.Division_by_zero
    "(app (var /) (lit 10) (lit 0))";
  let _, _, _, scope, _ = ground () in
  let quoted = read_with scope "(lit 1)" in
  check_value ~mode:Mode.Identity "quote remains code in identity mode"
    (Value.Code quoted) "(quote (lit 1))";
  check_value ~mode:Mode.Identity "let binds code normally in identity mode"
    (Value.Code quoted) "(let x (quote (lit 1)) (var x))";
  check_error ~mode:Mode.Identity "code condition is a type error in identity mode"
    ~cause:(Error.Unexpected { found = "code"; expected = "a boolean" })
    "(if (quote (lit #t)) (lit 1) (lit 2))";
  check_error ~mode:Mode.Identity "code callee is a type error in identity mode"
    ~cause:(Error.Unexpected { found = "code"; expected = "a function" })
    "(app (quote (lam (x) (var x))) (lit 1))"

(* 4. Staged Constant Folding in Lift Mode *)

let test_constant_folding () =
  (* Pure arithmetic folding *)
  check_folded "fold 1 + 2 * 3" "(lit 7)"
    "(app (var +) (lit 1) (app (var *) (lit 2) (lit 3)))";
  check_folded "fold 10 - 4" "(lit 6)"
    "(app (var -) (lit 10) (lit 4))";
  check_folded "fold 10 / 2" "(lit 5)"
    "(app (var /) (lit 10) (lit 2))";
  check_folded "fold 10 % 3" "(lit 1)"
    "(app (var %) (lit 10) (lit 3))";

  (* Comparisons & equality *)
  check_folded "fold 3 < 5" "(lit #t)"
    "(app (var <) (lit 3) (lit 5))";
  check_folded "fold 10 <= 9" "(lit #f)"
    "(app (var <=) (lit 10) (lit 9))";
  check_folded "fold 10 > 5" "(lit #t)"
    "(app (var >) (lit 10) (lit 5))";
  check_folded "fold 5 >= 5" "(lit #t)"
    "(app (var >=) (lit 5) (lit 5))";
  check_folded "fold 1 == 1" "(lit #t)"
    "(app (var ==) (lit 1) (lit 1))";
  check_folded "fold 1 != 2" "(lit #t)"
    "(app (var !=) (lit 1) (lit 2))";
  check_folded "fold not(false)" "(lit #t)"
    "(app (var not) (lit #f))";

  (* List operations *)
  check_folded "fold head([10, 20, 30])" "(lit 10)"
    "(app (var head) (app (var list) (lit 10) (lit 20) (lit 30)))";
  check_folded "fold length([10, 20, 30])" "(lit 3)"
    "(app (var length) (app (var list) (lit 10) (lit 20) (lit 30)))";
  check_folded "fold empty?([])" "(lit #t)"
    "(app (var empty?) (lit nil))";
  check_folded "fold empty?([1])" "(lit #f)"
    "(app (var empty?) (app (var list) (lit 1)))";

  (* Type tests *)
  check_folded "fold list?([1, 2])" "(lit #t)"
    "(app (var list?) (app (var list) (lit 1) (lit 2)))";
  check_folded "fold list?(123)" "(lit #f)"
    "(app (var list?) (lit 123))";
  check_folded "fold code?(123)" "(lit #f)"
    "(app (var code?) (lit 123))";
  check_folded "fold code?(\"str\")" "(lit #f)"
    "(app (var code?) (lit \"str\"))";

  (* Constant propagation through Let *)
  check_folded "fold let x = 10; let y = 20; x + y" "(lit 30)"
    "(let x (lit 10) (let y (lit 20) (app (var +) (var x) (var y))))";
  check_folded "fold nested let chain" "(lit 20)"
    "(let a (app (var *) (lit 2) (lit 3)) (let b (app (var +) (var a) (lit 4)) (app (var *) (var b) (lit 2))))";

  (* Static conditionals *)
  check_folded "fold if true 42 100" "(lit 42)"
    "(if (lit #t) (lit 42) (lit 100))";
  check_folded "fold if false 42 100" "(lit 100)"
    "(if (lit #f) (lit 42) (lit 100))";
  check_folded "fold if (3 < 5) 42 100" "(lit 42)"
    "(if (app (var <) (lit 3) (lit 5)) (lit 42) (lit 100))";

  (* Function application with static arguments *)
  check_folded "fold (fn(x, y) -> x * y + 1)(3, 4)" "(lit 13)"
    "(app (lam (x y) (app (var +) (app (var *) (var x) (var y)) (lit 1))) (lit 3) (lit 4))";
  check_folded "fold curried application" "(lit 30)"
    "(let add (lam (x) (lam (y) (app (var +) (var x) (var y))))\
    \  (app (app (var add) (lit 10)) (lit 20)))";

  (* Quote is a runtime constructor even though its payload is static. *)
  check_folded "preserve quote in residual code"
    "(quote (lit 1))" "(quote (lit 1))";
  let _, _, _, quote_scope, quote_env = ground () in
  let quote_source = read_with quote_scope "(quote (lit 1))" in
  let quote_residual = Staged_eval.fold ~env:quote_env quote_source in
  check "executing a residual quote returns Code"
    (Value.equal (Value.Code (read_with quote_scope "(lit 1)"))
       (Evaluator.eval ~env:quote_env quote_residual));

  (* A closure is never serialized.  Its lambda syntax is residualized, and
     its dynamic body receives an isolated let-insertion scope. *)
  let _, _, _, lambda_scope, lambda_env = ground () in
  let lambda_source =
    read_with lambda_scope "(lam (x) (app (var +) (var x) (lit 1)))"
  in
  let residual_lambda = Staged_eval.fold ~env:lambda_env lambda_source in
  check "reify lambda syntax with an isolated body"
    (match Core.shape residual_lambda with
    | Core.Lam { lam_body; _ } ->
        (match Core.shape lam_body with Core.Let _ -> true | _ -> false)
    | _ -> false);
  let applied =
    Core.app ~span:(Core.span residual_lambda) ~func:residual_lambda
      ~args:[ Core.lit ~span:(Core.span residual_lambda) (Constant.Num 2) ]
  in
  check "reified lambda executes like its source"
    (Value.equal (Value.Num 3) (Evaluator.eval ~env:lambda_env applied))

(* 5. Staged Residualization with Dynamic Code *)

let test_staged_residualization () =
  let _, _, named, _scope, env = ground () in
  let machine = Staged_eval.machine ~mode:Mode.Lift () in
  Machine.set_global_env machine env;

  (* Free/dynamic variable bound in env *)
  let x_ident = Ident.fresh "x" in
  let dummy_span = Span.point (Span.position ~file ~line:1 ~column:1 ~offset:0) in
  let dyn_x = Value.Code (Core.var ~span:dummy_span x_ident) in
  let env_with_x = Env.bind x_ident dyn_x env in

  (* x + (1 + 2) -> residual: let v = x + 3 in v *)
  let term1 =
    Core.app ~span:dummy_span
      ~func:(Core.var ~span:dummy_span (List.assoc "+" named))
      ~args:[
        Core.var ~span:dummy_span x_ident;
        Core.app ~span:dummy_span
          ~func:(Core.var ~span:dummy_span (List.assoc "+" named))
          ~args:[ Core.lit ~span:dummy_span (Constant.Num 1); Core.lit ~span:dummy_span (Constant.Num 2) ];
      ]
  in
  let result1 = Staged_eval.run ~mode:Mode.Lift machine ~env:env_with_x term1 in
  let v1 = Ident.fresh "v" in
  let expected1 =
    Core.let_ ~span:dummy_span ~binder:v1
      ~value:(Core.app ~span:dummy_span
                ~func:(Core.var ~span:dummy_span (List.assoc "+" named))
                ~args:[ Core.var ~span:dummy_span x_ident; Core.lit ~span:dummy_span (Constant.Num 3) ])
      ~body:(Core.var ~span:dummy_span v1)
  in
  (match result1 with
  | Value.Code res_code ->
      check "x + (1 + 2) residualizes to let v = x + 3 in v" (Alpha.equal expected1 res_code)
  | _ -> check "result1 is Code" false);

  (* (2 * 3) + x -> residual: let v = 6 + x in v *)
  let term2 =
    Core.app ~span:dummy_span
      ~func:(Core.var ~span:dummy_span (List.assoc "+" named))
      ~args:[
        Core.app ~span:dummy_span
          ~func:(Core.var ~span:dummy_span (List.assoc "*" named))
          ~args:[ Core.lit ~span:dummy_span (Constant.Num 2); Core.lit ~span:dummy_span (Constant.Num 3) ];
        Core.var ~span:dummy_span x_ident;
      ]
  in
  let result2 = Staged_eval.run ~mode:Mode.Lift machine ~env:env_with_x term2 in
  let v2 = Ident.fresh "v" in
  let expected2 =
    Core.let_ ~span:dummy_span ~binder:v2
      ~value:(Core.app ~span:dummy_span
                ~func:(Core.var ~span:dummy_span (List.assoc "+" named))
                ~args:[ Core.lit ~span:dummy_span (Constant.Num 6); Core.var ~span:dummy_span x_ident ])
      ~body:(Core.var ~span:dummy_span v2)
  in
  (match result2 with
  | Value.Code res_code ->
      check "(2 * 3) + x residualizes to let v = 6 + x in v" (Alpha.equal expected2 res_code)
  | _ -> check "result2 is Code" false);

  (* Dynamic conditional: if x then (1 + 2) else (3 * 4) -> let v = if x then 3 else 12 in v *)
  let term3 =
    Core.if_ ~span:dummy_span
      ~condition:(Core.var ~span:dummy_span x_ident)
      ~consequent:(Core.app ~span:dummy_span
                     ~func:(Core.var ~span:dummy_span (List.assoc "+" named))
                     ~args:[ Core.lit ~span:dummy_span (Constant.Num 1); Core.lit ~span:dummy_span (Constant.Num 2) ])
      ~alternative:(Core.app ~span:dummy_span
                      ~func:(Core.var ~span:dummy_span (List.assoc "*" named))
                      ~args:[ Core.lit ~span:dummy_span (Constant.Num 3); Core.lit ~span:dummy_span (Constant.Num 4) ])
  in
  let result3 = Staged_eval.run ~mode:Mode.Lift machine ~env:env_with_x term3 in
  let v3 = Ident.fresh "v" in
  let expected3 =
    Core.let_ ~span:dummy_span ~binder:v3
      ~value:(Core.if_ ~span:dummy_span
                ~condition:(Core.var ~span:dummy_span x_ident)
                ~consequent:(Core.lit ~span:dummy_span (Constant.Num 3))
                ~alternative:(Core.lit ~span:dummy_span (Constant.Num 12)))
      ~body:(Core.var ~span:dummy_span v3)
  in
  (match result3 with
  | Value.Code res_code ->
      check "dynamic if folds branches into let v = if x then 3 else 12 in v" (Alpha.equal expected3 res_code)
  | _ -> check "result3 is Code" false);

  (* Non-pure primitive (e.g. print) residualizes in Lift mode *)
  let print_ident = List.assoc "print" named in
  let term4 =
    Core.app ~span:dummy_span
      ~func:(Core.var ~span:dummy_span print_ident)
      ~args:[ Core.lit ~span:dummy_span (Constant.Str "hello") ]
  in
  let result4 = Staged_eval.run ~mode:Mode.Lift machine ~env term4 in
  let v4 = Ident.fresh "v" in
  let expected4 =
    Core.let_ ~span:dummy_span ~binder:v4
      ~value:(Core.app ~span:dummy_span
                ~func:(Core.var ~span:dummy_span print_ident)
                ~args:[ Core.lit ~span:dummy_span (Constant.Str "hello") ])
      ~body:(Core.var ~span:dummy_span v4)
  in
  (match result4 with
  | Value.Code res_code ->
      check "print(\"hello\") residualizes in Lift mode" (Alpha.equal expected4 res_code)
  | _ -> check "result4 is Code" false)

(* 6. Pure Error Detection at Stage Time *)

let test_stage_errors () =
  check_error ~mode:Mode.Lift "stage-time division by zero"
    ~cause:Error.Division_by_zero
    "(app (var /) (lit 10) (lit 0))";
  check_error ~mode:Mode.Lift "stage-time type error"
    ~cause:(Error.Unexpected { found = "a number"; expected = "a boolean" })
    "(if (lit 1) (lit 10) (lit 20))";
  check_error ~mode:Mode.Lift "stage-time head on empty list"
    ~cause:(Error.Unexpected { found = "the empty list"; expected = "a non-empty list" })
    "(app (var head) (lit nil))";
  (* Assignment is staged now (task 7.2), but only where the abstract store can
     say who owns the place. A recursive group's name is not a binding the store
     tracks, so the specializer says so rather than writing into its own state. *)
  check_error ~mode:Mode.Lift "assignment the store does not track is refused"
    ~cause:
      (Error.Unsupported
         {
           what = "assignment to `f`, which the abstract store does not track";
           by = "the staged evaluator";
         })
    "(letrec ((f (lam () (lit 1)))) (let _ (set f (lam () (lit 2))) (app (var f))))"

let test_staging_invariants () =
  let registry, globals, named, scope, env = ground () in
  let span = Span.point (Span.position ~file ~line:1 ~column:1 ~offset:0) in

  (* A mismatched public run request must fail before an observable primitive
     can execute under the Identity wiring. *)
  let print_term = read_with scope "(app (var print) (lit \"wrong-time\"))" in
  let identity_machine = Staged_eval.machine ~mode:Mode.Identity () in
  (match Staged_eval.run ~mode:Mode.Lift identity_machine ~env print_term with
  | _ -> check "mode mismatch is rejected" false
  | exception Invalid_argument _ -> check "mode mismatch is rejected" true
  | exception Error.Ash_error _ -> check "mode mismatch is rejected" false);
  check "mode mismatch emits no IO" (Io.events (Primitives.io registry) = []);
  let lift_machine = Staged_eval.machine ~mode:Mode.Lift () in
  (match Staged_eval.run lift_machine ~env print_term with
  | Value.Code _ -> check "run derives Lift mode from machine wiring" true
  | _ -> check "run derives Lift mode from machine wiring" false);
  check "correctly wired specialization also emits no IO"
    (Io.events (Primitives.io registry) = []);

  (* Residual primitive identity comes from the exact primitive value, not the
     first local binding with the same printed name. *)
  let global_plus = List.assoc "+" named in
  let shadow_plus = Ident.fresh "+" in
  let x = Ident.fresh "x" in
  let staged_env =
    env
    |> Env.bind shadow_plus (Value.Num 999)
    |> Env.bind x (Value.Code (Core.var ~span x))
  in
  let call =
    Core.app ~span ~func:(Core.var ~span global_plus)
      ~args:[ Core.var ~span x; Core.lit ~span (Constant.Num 1) ]
  in
  let residual = Staged_eval.fold ~env:staged_env call in
  let rec applied_ident node =
    match Core.shape node with
    | Core.Let { let_value; let_body = _; _ } -> applied_ident let_value
    | Core.App { func; _ } ->
        (match Core.shape func with Core.Var ident -> Some ident | _ -> None)
    | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.LetRec _
    | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ -> None
  in
  check "residual primitive keeps the exact global identifier"
    (match applied_ident residual with
    | Some ident -> Ident.equal ident global_plus && not (Ident.equal ident shadow_plus)
    | None -> false);
  let shadowed_runtime_env =
    env |> Env.bind shadow_plus (Value.Num 999) |> Env.bind x (Value.Num 1)
  in
  check "hygienic residual primitive ignores the same-name local binding"
    (Value.equal (Value.Num 2)
       (Evaluator.eval ~env:shadowed_runtime_env residual));

  (* A Code nested inside immutable data makes the whole argument dynamic. *)
  let xs = Ident.fresh "xs" in
  let mixed = Value.List [ Value.Code (Core.var ~span x) ] in
  let mixed_env = Env.bind xs mixed (Env.bind x (Value.Code (Core.var ~span x)) env) in
  let equality =
    Core.app ~span ~func:(Core.var ~span (List.assoc "==" named))
      ~args:
        [ Core.var ~span xs;
          Core.app ~span ~func:(Core.var ~span (List.assoc "list" named))
            ~args:[ Core.lit ~span (Constant.Num 0) ] ]
  in
  let equality_residual = Staged_eval.fold ~env:mixed_env equality in
  let runtime_env = Env.bind x (Value.Num 0) (Env.extend globals Value.empty_env) in
  check "nested dynamic values prevent primitive folding"
    (Value.equal (Value.Bool true) (Evaluator.eval ~env:runtime_env equality_residual));

  (* Specializing either arm of a dynamic conditional cannot mutate the shared
     specialization environment. *)
  let cell = Ident.fresh "cell" in
  let cond = Ident.fresh "cond" in
  let mutation_env =
    env
    |> Env.bind cell (Value.Num 0)
    |> Env.bind cond (Value.Code (Core.var ~span cond))
  in
  let branch value =
    Core.set ~span ~target:cell ~value:(Core.lit ~span (Constant.Num value))
  in
  let mutation =
    Core.if_ ~span ~condition:(Core.var ~span cond)
      ~consequent:(branch 1) ~alternative:(branch 2)
  in
  (match Staged_eval.fold ~env:mutation_env mutation with
  | _ -> check "dynamic branch mutation is refused" false
  | exception Error.Ash_error _ -> check "dynamic branch mutation is refused" true);
  check "refused branch mutation leaves specialization state unchanged"
    (Value.equal (Value.Num 0)
       (Env.read_exn ~phase:Error.Stage ~span mutation_env cell))

(* 7. Hygienic Let-Insertion on Duplication Traps *)

let rec count_nodes node =
  1 + match Core.shape node with
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ -> 0
  | Core.Lam { lam_body; _ } -> count_nodes lam_body
  | Core.Quote _ -> 0
  | Core.Reifier { reifier_body; _ } -> count_nodes reifier_body
  | Core.If { condition; consequent; alternative } ->
      count_nodes condition + count_nodes consequent + count_nodes alternative
  | Core.Let { let_value; let_body; _ } ->
      count_nodes let_value + count_nodes let_body
  | Core.LetRec { rec_bindings; rec_body } ->
      List.fold_left (fun acc b -> acc + count_nodes b.Core.rec_lambda.Core.lam_body) 0 rec_bindings + count_nodes rec_body
  | Core.Set { set_value; _ } -> count_nodes set_value
  | Core.App { func; args } ->
      count_nodes func + List.fold_left (fun acc a -> acc + count_nodes a) 0 args

let rec count_lets node =
  match Core.shape node with
  | Core.Let { let_value; let_body; _ } -> 1 + count_lets let_value + count_lets let_body
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Quote _ -> 0
  | Core.Lam { lam_body; _ } -> count_lets lam_body
  | Core.Reifier { reifier_body; _ } -> count_lets reifier_body
  | Core.If { condition; consequent; alternative } ->
      count_lets condition + count_lets consequent + count_lets alternative
  | Core.LetRec { rec_bindings; rec_body } ->
      List.fold_left (fun acc b -> acc + count_lets b.Core.rec_lambda.Core.lam_body) 0 rec_bindings + count_lets rec_body
  | Core.Set { set_value; _ } -> count_lets set_value
  | Core.App { func; args } ->
      count_lets func + List.fold_left (fun acc a -> acc + count_lets a) 0 args

let test_let_insertion () =
  let _, _, named, _, env = ground () in
  let dummy_span = Span.point (Span.position ~file ~line:1 ~column:1 ~offset:0) in
  let x_ident = Ident.fresh "x" in
  let dyn_x = Value.Code (Core.var ~span:dummy_span x_ident) in
  let env_with_x = Env.bind x_ident dyn_x env in

  (* Helper to build n-nested dbl calls: dbl(x) = x + x *)
  let plus_var = Core.var ~span:dummy_span (List.assoc "+" named) in
  let dbl_fn =
    let param = Ident.fresh "a" in
    Core.lam ~span:dummy_span ~params:[ param ]
      ~body:(Core.app ~span:dummy_span ~func:plus_var
               ~args:[ Core.var ~span:dummy_span param; Core.var ~span:dummy_span param ])
  in
  let rec build_nested_dbl n arg =
    if n = 0 then arg
    else
      let inner = build_nested_dbl (n - 1) arg in
      Core.app ~span:dummy_span ~func:dbl_fn ~args:[ inner ]
  in

  (* Test for n = 1 to 8: verify number of lets = n, and node count is linear O(n) *)
  List.iter
    (fun n ->
      let term = build_nested_dbl n (Core.var ~span:dummy_span x_ident) in
      let residual = Staged_eval.fold ~env:env_with_x term in
      let lets = count_lets residual in
      let nodes = count_nodes residual in
      check (Printf.sprintf "let count for dbl^%d is %d" n n) (lets = n);
      (* With let-insertion, node count is roughly 6 * n + 1. Without it, would be > 2^n. *)
      check (Printf.sprintf "node count for dbl^%d is linear (%d nodes < %d)" n nodes (10 * n + 10))
        (nodes <= 10 * n + 10))
    [ 1; 2; 3; 4; 5; 6; 7; 8 ];

  (* Test distinct scoped buffers for branches in dynamic If *)
  let if_term =
    Core.if_ ~span:dummy_span
      ~condition:(Core.var ~span:dummy_span x_ident)
      ~consequent:(build_nested_dbl 3 (Core.var ~span:dummy_span x_ident))
      ~alternative:(build_nested_dbl 2 (Core.var ~span:dummy_span x_ident))
  in
  let residual_if = Staged_eval.fold ~env:env_with_x if_term in
  (* Under the top-level let binding of the if itself, consequent has 3 lets, alternative has 2 lets *)
  (match Core.shape residual_if with
  | Core.Let { let_value = if_node; _ } -> (
      match Core.shape if_node with
      | Core.If { consequent; alternative; _ } ->
          check "consequent branch has 3 lets" (count_lets consequent = 3);
          check "alternative branch has 2 lets" (count_lets alternative = 2)
      | _ -> check "residual_if inner is If" false)
  | _ -> check "residual_if is Let" false)

(* 7. Open Recursion & Static Recursion Folding *)

let test_open_recursion () =
  let _, _, _, scope, env = ground () in
  let term = read_with scope "(app (lam (x) (app (var +) (var x) (lit 1))) (lit 2))" in
  let machine = Staged_eval.machine ~mode:Mode.Identity () in
  let intercepted = ref 0 in
  let base_eval = Machine.current_eval machine in
  Machine.set_eval machine (fun m node env k ->
      incr intercepted;
      base_eval m node env k);
  let result = Staged_eval.run ~mode:Mode.Identity machine ~env term in
  check "open recursion in identity mode intercepts all nodes" (!intercepted > 1);
  check "result is 3" (Value.equal (Value.Num 3) result)

let test_recursion_folding () =
  check_folded "fold static factorial" "(lit 120)"
    "(letrec ((fact (lam (n)\n\
    \                 (if (app (var ==) (var n) (lit 0))\n\
    \                     (lit 1)\n\
    \                     (app (var *) (var n) (app (var fact) (app (var -) (var n) (lit 1))))))))\n\
    \  (app (var fact) (lit 5)))"

let () =
  test_value_predicates ();
  test_mode ();
  test_identity_mode ();
  test_constant_folding ();
  test_staged_residualization ();
  test_stage_errors ();
  test_staging_invariants ();
  test_let_insertion ();
  test_open_recursion ();
  test_recursion_folding ();
  if !failures > 0 then (
    Printf.printf "%d stage evaluator assertion(s) failed\n" !failures;
    exit 1)
