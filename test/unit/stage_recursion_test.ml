(* Memoized specialization points and residual LetRec (to-do task 6.1,
   spec §7.5).

   Phase 5 collapsed recursion the specializer could decide: the control was
   static, so unrolling reached an end. This is the other half. When the control
   is dynamic there is no end, and inlining the call again is the fragment's
   edge — before this task these programs did not specialize at all, they
   unrolled until the host stack ran out.

   The acceptance shape is the same one Phase 5 used, with one addition: stage a
   program whose recursion is driven by a value the specializer does not know,
   require that staging {e terminates}, then run the residual on concrete
   arguments and require the same answer the source gives. Every test here would
   hang or overflow without a specialization point, so termination is part of
   what is being asserted, and the residual is always executed. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_stage

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "stage_recursion_test.ash"

let ground () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Core_reader.scope_of_list named in
  let env = Env.extend globals Value.empty_env in
  ignore (registry : Primitives.t);
  (scope, env)

let read_with scope text = Core_reader.read ~scope ~file text

(* {1 Residual inspection} *)

let rec fold_nodes f accumulator node =
  let accumulator = f accumulator node in
  match Core.shape node with
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ -> accumulator
  | Core.Lam { Core.lam_body; _ } -> fold_nodes f accumulator lam_body
  | Core.Quote _ -> accumulator
  | Core.Reifier { Core.reifier_body; _ } -> fold_nodes f accumulator reifier_body
  | Core.App { Core.func; args } ->
      List.fold_left (fold_nodes f) (fold_nodes f accumulator func) args
  | Core.Let { Core.let_value; let_body; _ } ->
      fold_nodes f (fold_nodes f accumulator let_value) let_body
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      let accumulator =
        List.fold_left
          (fun accumulator binding ->
            fold_nodes f accumulator binding.Core.rec_lambda.Core.lam_body)
          accumulator rec_bindings
      in
      fold_nodes f accumulator rec_body
  | Core.If { Core.condition; consequent; alternative } ->
      fold_nodes f (fold_nodes f (fold_nodes f accumulator condition) consequent)
        alternative
  | Core.Set { Core.set_value; _ } -> fold_nodes f accumulator set_value

let calls_to ~name residual =
  fold_nodes
    (fun total node ->
      match Core.shape node with
      | Core.App { Core.func; _ } -> (
          match Core.shape func with
          | Core.Var ident when String.equal (Ident.name ident) name -> total + 1
          | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
          | Core.Let _ | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _
          | Core.Reifier _ ->
              total)
      | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          total)
    0 residual

(* Every residual function the specializer introduced, in occurrence order. *)
let residual_functions residual =
  List.rev
    (fold_nodes
       (fun found node ->
         match Core.shape node with
         | Core.LetRec { Core.rec_bindings; _ } ->
             List.rev_append rec_bindings found
         | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
         | Core.Let _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
             found)
       [] residual)

(* Calls to a residual function, by its hygienic identity rather than its
   printed name: a specialization point is named after the source function it
   specializes, and several may share that name. *)
let calls_to_ident ~ident residual =
  fold_nodes
    (fun total node ->
      match Core.shape node with
      | Core.App { Core.func; _ } -> (
          match Core.shape func with
          | Core.Var candidate when Ident.equal candidate ident -> total + 1
          | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
          | Core.Let _ | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _
          | Core.Reifier _ ->
              total)
      | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          total)
    0 residual

(* {1 The comparison} *)

let apply_at scope source arguments =
  let span = Core.span source in
  Core.app ~span ~func:source ~args:(List.map (read_with scope) arguments)

let outcome ~env node =
  match Evaluator.eval ~env node with
  | value -> Ok value
  | exception Error.Ash_error error -> Error (Error.to_string error)

let describe = function
  | Ok value -> Value.to_string value
  | Error message -> "error: " ^ message

let same_outcome a b =
  match (a, b) with
  | Ok x, Ok y -> Value.equal x y
  | Error x, Error y -> String.equal x y
  | (Ok _ | Error _), _ -> false

(* Stage [source_text] once, then check it against the source on every argument
   list in [cases].  One residual has to agree with the source everywhere,
   which is what distinguishes a specialization point from an unrolling that
   happened to be right for one input. *)
let check_recursion ?(inspect = fun _ -> ()) name ~cases source_text =
  let scope, env = ground () in
  let source = read_with scope source_text in
  match Staged_eval.fold ~env source with
  | exception Error.Ash_error error ->
      incr failures;
      Printf.printf "FAIL %s\n  staging failed: %s\n" name (Error.to_string error)
  | residual ->
      let open_names =
        Code.unresolved_dependencies ~available:(Env.idents env) residual
      in
      if open_names <> [] then (
        incr failures;
        Printf.printf "FAIL %s\n  residual is open in: %s\n" name
          (String.concat ", "
             (List.map (fun d -> Ident.name d.Code.ident) open_names)));
      List.iter
        (fun args ->
          let expected = outcome ~env (apply_at scope source args) in
          let actual = outcome ~env (apply_at scope residual args) in
          if not (same_outcome expected actual) then (
            incr failures;
            Printf.printf
              "FAIL %s on %s\n  source:   %s\n  residual: %s\n  residual Core: %s\n"
              name
              (String.concat " " args)
              (describe expected) (describe actual)
              (Core_printer.to_string residual)))
        cases;
      inspect residual

(* {1 Recursion the specializer cannot see the end of} *)

(* The canonical case: the recursion's own termination test is dynamic, so
   unrolling has no end. *)
let countdown_sum =
  "(letrec ((loop (lam (n)\n\
  \                 (if (app (var ==) (var n) (lit 0))\n\
  \                     (lit 0)\n\
  \                     (app (var +) (var n)\n\
  \                          (app (var loop) (app (var -) (var n) (lit 1))))))))\n\
  \  (lam (x) (app (var loop) (var x))))"

let test_dynamic_control () =
  check_recursion "a dynamically controlled countdown specializes"
    ~cases:[ [ "(lit 0)" ]; [ "(lit 1)" ]; [ "(lit 5)" ]; [ "(lit 12)" ] ]
    ~inspect:(fun residual ->
      match residual_functions residual with
      | [ binding ] ->
          check "the specialization point is named after the source function"
            (String.equal (Ident.name binding.Core.rec_name) "loop");
          check "it takes exactly the argument the specializer does not know"
            (List.length binding.Core.rec_lambda.Core.params = 1);
          check "and it is recursive: its body calls itself"
            (calls_to_ident ~ident:binding.Core.rec_name
               (Core.of_lambda ~span:binding.Core.rec_span
                  binding.Core.rec_lambda)
            = 1)
      | [] ->
          check "a specialization point was created" false
      | _ :: _ :: _ -> check "countdown: exactly one specialization point" false)
    countdown_sum;

  (* Recursion over a list the specializer does not have. *)
  check_recursion "a dynamically controlled list traversal specializes"
    ~cases:
      [
        [ "(lit nil)" ];
        [ "(app (var list) (lit 3))" ];
        [ "(app (var list) (lit 1) (lit 2) (lit 3) (lit 4))" ];
      ]
    ~inspect:(fun residual ->
      check "the traversal survives, because the list is unknown"
        (calls_to ~name:"empty?" residual >= 1
        && calls_to ~name:"head" residual >= 1
        && calls_to ~name:"tail" residual >= 1))
    "(letrec ((total (lam (xs)\n\
    \                  (if (app (var empty?) (var xs))\n\
    \                      (lit 0)\n\
    \                      (app (var +) (app (var head) (var xs))\n\
    \                           (app (var total) (app (var tail) (var xs))))))))\n\
    \  (lam (l) (app (var total) (var l))))";

  (* Mutual recursion. The cycle is discovered at the call that started it, so
     the outer function becomes the specialization point and its partner is
     inlined into it: [even?] calls itself after two decrements. One residual
     function is enough to close the loop, and both parities stay correct. *)
  check_recursion "mutual recursion under dynamic control specializes"
    ~cases:
      [ [ "(lit 0)" ]; [ "(lit 1)" ]; [ "(lit 6)" ]; [ "(lit 7)" ]; [ "(lit 20)" ] ]
    ~inspect:(fun residual ->
      match residual_functions residual with
      | [ binding ] ->
          check "mutual: the point is the function the cycle started at"
            (String.equal (Ident.name binding.Core.rec_name) "even?");
          check "mutual: the partner is inlined into it, so the point recurs on itself"
            (calls_to_ident ~ident:binding.Core.rec_name
               (Core.of_lambda ~span:binding.Core.rec_span binding.Core.rec_lambda)
            = 1)
      | [] | _ :: _ :: _ ->
          check "mutual: exactly one specialization point" false)
    "(letrec ((even? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #t)\n\
    \                            (app (var odd?) (app (var -) (var n) (lit 1))))))\n\
    \         (odd? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #f)\n\
    \                           (app (var even?) (app (var -) (var n) (lit 1)))))))\n\
    \  (lam (x) (app (var even?) (var x))))";

  (* An accumulator: two dynamic arguments, so the residual function takes two
     parameters. *)
  check_recursion "an accumulating loop keeps both dynamic parameters"
    ~cases:[ [ "(lit 0)"; "(lit 0)" ]; [ "(lit 4)"; "(lit 100)" ] ]
    ~inspect:(fun residual ->
      match residual_functions residual with
      | [ binding ] ->
          check "both unknown arguments became parameters"
            (List.length binding.Core.rec_lambda.Core.params = 2)
      | [] | _ :: _ :: _ -> check "accumulator: exactly one specialization point" false)
    "(letrec ((go (lam (n acc)\n\
    \               (if (app (var ==) (var n) (lit 0))\n\
    \                   (var acc)\n\
    \                   (app (var go) (app (var -) (var n) (lit 1))\n\
    \                        (app (var +) (var acc) (var n)))))))\n\
    \  (lam (x a) (app (var go) (var x) (var a))))"

(* {1 What the key is made of} *)

let multiply body =
  "(letrec ((mult (lam (k n)\n\
  \                 (if (app (var ==) (var n) (lit 0))\n\
  \                     (lit 0)\n\
  \                     (app (var +) (var k)\n\
  \                          (app (var mult) (var k) (app (var -) (var n) (lit 1))))))))\n\
  \  " ^ body ^ ")"

let test_static_projection () =
  (* The static argument is part of the key, so it is specialized into the
     residual function's body instead of being passed to it. *)
  check_recursion "a static argument is specialized in, not passed"
    ~cases:[ [ "(lit 0)" ]; [ "(lit 1)" ]; [ "(lit 5)" ] ]
    ~inspect:(fun residual ->
      match residual_functions residual with
      | [ binding ] ->
          check "the static multiplier is not a parameter"
            (List.length binding.Core.rec_lambda.Core.params = 1)
      | [] | _ :: _ :: _ -> check "static argument: exactly one specialization point" false)
    (multiply "(lam (x) (app (var mult) (lit 3) (var x)))");

  (* Two calls that differ only in a static argument are different keys, and get
     different residual functions. *)
  check_recursion "different static arguments are different specializations"
    ~cases:[ [ "(lit 0)" ]; [ "(lit 3)" ] ]
    ~inspect:(fun residual ->
      check "distinct static arguments: two specialization points"
        (List.length (residual_functions residual) = 2))
    (multiply
       "(lam (x) (app (var +) (app (var mult) (lit 3) (var x))\n\
       \                      (app (var mult) (lit 4) (var x))))");

  (* Two calls with the same key in the same block share one residual function:
     the second finds the memo entry and calls it. *)
  check_recursion "the same key is specialized once and called twice"
    ~cases:[ [ "(lit 0)" ]; [ "(lit 4)" ] ]
    ~inspect:(fun residual ->
      match residual_functions residual with
      | [ binding ] ->
          (* Its own recursive call, the call the first occurrence's unrolling
             left behind, and the second occurrence, which is nothing but a
             call: the memo entry is what makes the third one free. *)
          check "one specialization point, called three times"
            (calls_to_ident ~ident:binding.Core.rec_name residual = 3)
      | [] | _ :: _ :: _ -> check "shared key: exactly one specialization point" false)
    (multiply
       "(lam (x) (app (var +) (app (var mult) (lit 3) (var x))\n\
       \                      (app (var mult) (lit 3) (var x))))")

(* {1 Where the residual LetRec is bound} *)

let test_scope () =
  (* The recursion mentions a variable bound outside it, so the residual
     function may not be hoisted: [check_recursion] rejects an open residual. *)
  check_recursion "a specialization point may capture the enclosing scope"
    ~cases:[ [ "(lit 2)"; "(lit 0)" ]; [ "(lit 2)"; "(lit 6)" ] ]
    "(lam (b x)\n\
    \  (letrec ((loop (lam (n)\n\
    \                   (if (app (var ==) (var n) (lit 0))\n\
    \                       (lit 0)\n\
    \                       (app (var +) (var b)\n\
    \                            (app (var loop) (app (var -) (var n) (lit 1))))))))\n\
    \    (app (var loop) (var x))))";

  (* A specialization point created inside one branch of a dynamic conditional
     is not in scope in the other, so each branch gets its own. *)
  check_recursion "each branch of a dynamic conditional gets its own point"
    ~cases:
      [
        [ "(lit #t)"; "(lit 4)" ];
        [ "(lit #f)"; "(lit 4)" ];
        [ "(lit #t)"; "(lit 0)" ];
        [ "(lit #f)"; "(lit 0)" ];
      ]
    ~inspect:(fun residual ->
      check "one specialization point per branch"
        (List.length (residual_functions residual) = 2))
    "(letrec ((loop (lam (n)\n\
    \                 (if (app (var ==) (var n) (lit 0))\n\
    \                     (lit 0)\n\
    \                     (app (var +) (var n)\n\
    \                          (app (var loop) (app (var -) (var n) (lit 1))))))))\n\
    \  (lam (b x) (if (var b) (app (var loop) (var x))\n\
    \                         (app (var -) (lit 0) (app (var loop) (var x))))))";

  (* A recursive function reaching a position the specializer cannot see into is
     reified as a lambda, and the recursion inside it still terminates. *)
  check_recursion "a recursive closure crossing a dynamic boundary"
    ~cases:[ [ "(lam (f) (app (var f) (lit 5)))" ] ]
    "(letrec ((loop (lam (n)\n\
    \                 (if (app (var ==) (var n) (lit 0))\n\
    \                     (lit 0)\n\
    \                     (app (var +) (var n)\n\
    \                          (app (var loop) (app (var -) (var n) (lit 1))))))))\n\
    \  (lam (g) (app (var g) (var loop))))"

(* {1 Inlining is still the default} *)

let test_static_control_still_unrolls () =
  (* The whole Phase 5 result depends on this: a key is only met twice when the
     unrolling has stopped making progress, so recursion the specializer can
     decide unrolls exactly as before and creates no specialization point. *)
  check_recursion "static control unrolls and creates no residual function"
    ~cases:[ [ "(lit 2)" ]; [ "(lit 7)" ] ]
    ~inspect:(fun residual ->
      check "no specialization point" (residual_functions residual = []);
      check "the control flow is gone"
        (calls_to ~name:"==" residual = 0 && calls_to ~name:"-" residual = 0);
      check "three multiplications survive" (calls_to ~name:"*" residual = 3))
    "(letrec ((power (lam (n x)\n\
    \                  (if (app (var ==) (var n) (lit 0))\n\
    \                      (lit 1)\n\
    \                      (app (var *) (var x)\n\
    \                           (app (var power) (app (var -) (var n) (lit 1)) (var x)))))))\n\
    \  (lam (x) (app (var power) (lit 3) (var x))))";

  (* A partially static list is held, not passed: its spine still drives the
     unrolling even though every element is dynamic. *)
  check_recursion "a static spine of dynamic elements still unrolls"
    ~cases:[ [ "(lit 4)" ] ]
    ~inspect:(fun residual ->
      check "no specialization point" (residual_functions residual = []);
      check "the traversal is gone"
        (calls_to ~name:"empty?" residual = 0
        && calls_to ~name:"head" residual = 0
        && calls_to ~name:"tail" residual = 0))
    "(letrec ((total (lam (xs)\n\
    \                  (if (app (var empty?) (var xs))\n\
    \                      (lit 0)\n\
    \                      (app (var +) (app (var head) (var xs))\n\
    \                           (app (var total) (app (var tail) (var xs))))))))\n\
    \  (lam (x) (app (var total) (app (var list) (var x) (lit 2) (var x)))))"

(* {1 The bookkeeping is reset per run} *)

let test_counters () =
  let scope, env = ground () in
  let staged text = ignore (Staged_eval.fold ~env (read_with scope text)) in
  staged countdown_sum;
  check "the countdown created one specialization point"
    (Stage.Specialize.points_created () = 1);
  check "and emitted at least two calls to it"
    (Stage.Specialize.memoized_calls () >= 2);
  staged "(lam (x) (app (var +) (var x) (lit 1)))";
  check "a program that needs none reports none"
    (Stage.Specialize.points_created () = 0
    && Stage.Specialize.memoized_calls () = 0)

let () =
  test_dynamic_control ();
  test_static_projection ();
  test_scope ();
  test_static_control_still_unrolls ();
  test_counters ();
  if !failures > 0 then (
    Printf.printf "%d specialization-point assertion(s) failed\n" !failures;
    exit 1)
