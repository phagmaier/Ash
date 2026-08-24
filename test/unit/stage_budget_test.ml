(* Specialization budgets and generalization (to-do task 6.2, spec §7.5).

   Task 6.1 stopped the unroller from following a recursion whose key it meets
   again. What it cannot stop is a recursion that never repeats a key: an
   argument that grows, or a counter walking away from its base case, presents
   something new every step and there is no cycle to find.

   The budget is where the specializer stops believing it is making progress.
   On pressure it gives up one more argument of the offending function — marks
   it dynamic — and specializes under the coarser key, which is what makes the
   next call round onto a key the memo table already holds. Every one of those
   decisions is recorded with the function, the parameter, and the reason.

   These programs would not terminate at specialization time without that.
   Termination is therefore part of every assertion here, and where the source
   itself terminates the residual is run against it. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_stage

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "stage_budget_test.ash"

let ground () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Core_reader.scope_of_list named in
  let env = Env.extend globals Value.empty_env in
  ignore (registry : Primitives.t);
  (scope, env)

let read_with scope text = Core_reader.read ~scope ~file text

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at index = index + n <= h && (String.sub haystack index n = needle || at (index + 1)) in
  n = 0 || at 0

(* Run [f] under a budget, restoring whatever was configured before. *)
let under ~depth ~bindings f =
  let saved = Specialize.budget () in
  Specialize.set_budget
    { Specialize.max_inline_depth = depth; max_residual_bindings = bindings };
  Fun.protect ~finally:(fun () -> Specialize.set_budget saved) f

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

let residual_functions residual =
  List.rev
    (fold_nodes
       (fun found node ->
         match Core.shape node with
         | Core.LetRec { Core.rec_bindings; _ } -> List.rev_append rec_bindings found
         | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
         | Core.Let _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
             found)
       [] residual)

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

(* Stage under a budget the program will exceed, then require it to agree with
   the source on every case. [inspect] states what the generalization did. *)
let check_generalized ?(inspect = fun _ _ -> ()) name ~depth ~bindings ~cases
    source_text =
  let scope, env = ground () in
  let source = read_with scope source_text in
  match under ~depth ~bindings (fun () -> Staged_eval.fold ~env source) with
  | exception Error.Ash_error error ->
      incr failures;
      Printf.printf "FAIL %s\n  staging failed: %s\n" name (Error.to_string error)
  | residual ->
      let reasons = Specialize.generalizations () in
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
            Printf.printf "FAIL %s on %s\n  source:   %s\n  residual: %s\n" name
              (String.concat " " args) (describe expected) (describe actual)))
        cases;
      inspect residual reasons

(* {1 Recursion that never repeats a key} *)

let test_growing_argument () =
  (* [acc] grows a cons at every step, so no two calls ever share a key and 6.1
     has no cycle to find. The budget stops it, and giving up [acc] is what lets
     the next call meet the point. *)
  check_generalized "an accumulator that grows is generalized" ~depth:6
    ~bindings:1000
    ~cases:
      [
        [ "(lit nil)" ];
        [ "(app (var list) (lit 1))" ];
        [ "(app (var list) (lit 1) (lit 2) (lit 3) (lit 4) (lit 5) (lit 6) (lit 7))" ];
      ]
    ~inspect:(fun residual reasons ->
      check "growing: a specialization point was created"
        (residual_functions residual <> []);
      match reasons with
      | [ reason ] ->
          check "the generalized function is named"
            (String.equal reason.Specialize.gen_function "rev");
          check "the accumulator is the argument given up"
            (String.equal reason.Specialize.gen_parameter "acc");
          check "and the reason is the inlining depth"
            (match reason.Specialize.gen_pressure with
            | Specialize.Inline_depth limit -> limit = 6
            | Specialize.Residual_size _ -> false)
      | [] -> check "exactly one generalization was needed" false
      | _ :: _ :: _ -> check "exactly one generalization was needed" false)
    "(letrec ((rev (lam (xs acc)\n\
    \                (if (app (var empty?) (var xs))\n\
    \                    (var acc)\n\
    \                    (app (var rev) (app (var tail) (var xs))\n\
    \                         (app (var cons) (app (var head) (var xs)) (var acc)))))))\n\
    \  (lam (l) (app (var rev) (var l) (lit nil))))";

  (* A static counter walking away from its base case. The source diverges, so
     there is nothing to compare a residual against — what is asserted is that
     specialization terminates, says which argument it gave up, and produces a
     residual function rather than an unbounded unrolling. *)
  let scope, env = ground () in
  let runaway =
    read_with scope
      "(letrec ((up (lam (n x)\n\
      \               (if (app (var ==) (var n) (lit 0)) (lit 1)\n\
      \                   (app (var *) (var x)\n\
      \                        (app (var up) (app (var +) (var n) (lit 1)) (var x)))))))\n\
      \  (lam (x) (app (var up) (lit 1) (var x))))"
  in
  (match under ~depth:5 ~bindings:1000 (fun () -> Staged_eval.fold ~env runaway) with
  | exception Error.Ash_error error ->
      incr failures;
      Printf.printf "FAIL a runaway counter staged to an error: %s\n"
        (Error.to_string error)
  | residual ->
      check "the runaway counter produced a residual function"
        (List.length (residual_functions residual) = 1);
      check "the residual is closed"
        (Code.unresolved_dependencies ~available:(Env.idents env) residual = []);
      match Specialize.generalizations () with
      | [ reason ] ->
          check "the counter is the argument given up"
            (String.equal reason.Specialize.gen_parameter "n");
          check "the runaway generalization names its function"
            (String.equal reason.Specialize.gen_function "up")
      | [] | _ :: _ :: _ ->
          check "the runaway counter needed exactly one generalization" false)

(* {1 Size pressure} *)

let test_size_pressure () =
  (* Static control the specializer could decide, under a budget too small to
     let it: the unrolling stops partway and the rest becomes a residual
     function. The answer must not change. *)
  check_generalized "an unrolling too large for its budget stops and generalizes"
    ~depth:1000 ~bindings:12
    ~cases:[ [ "(lit 2)" ]; [ "(lit 3)" ] ]
    ~inspect:(fun residual reasons ->
      check "size: a specialization point was created"
        (residual_functions residual <> []);
      check "size: the counter is the argument given up"
        (List.exists
           (fun reason -> String.equal reason.Specialize.gen_parameter "n")
           reasons);
      check "size: the reason is the residual size"
        (List.exists
           (fun reason ->
             match reason.Specialize.gen_pressure with
             | Specialize.Residual_size limit -> limit = 12
             | Specialize.Inline_depth _ -> false)
           reasons))
    (* The accumulator is dynamic, so every step emits a multiplication before
       recursing: the budget is reached on the way down, while calls are still
       being made and there is still something to generalize. *)
    "(letrec ((power (lam (n acc x)\n\
    \                  (if (app (var ==) (var n) (lit 0)) (var acc)\n\
    \                      (app (var power) (app (var -) (var n) (lit 1))\n\
    \                           (app (var *) (var acc) (var x)) (var x))))))\n\
    \  (lam (x) (app (var power) (lit 20) (lit 1) (var x))))"

(* {1 Nothing left to give up} *)

let test_exhaustion () =
  (* A closure that reaches a dynamic position inside its own reified body.
     There is no call here to key and no argument to generalize — reification is
     not an application — so the budget is the only thing that can stop it, and
     the specializer says so instead of diverging. *)
  let scope, env = ground () in
  let self_passing =
    read_with scope
      "(letrec ((loop (lam (g) (app (var g) (var loop)))))\n\
      \  (lam (h) (app (var h) (var loop))))"
  in
  match under ~depth:8 ~bindings:1000 (fun () -> Staged_eval.fold ~env self_passing) with
  | residual ->
      incr failures;
      Printf.printf "FAIL a self-passing closure staged to %s\n"
        (Core_printer.to_string residual)
  | exception Error.Ash_error error -> (
      check "the failure is reported at the stage phase"
        (error.Error.phase = Error.Stage);
      match error.Error.cause with
      | Error.Budget_exhausted { what; limit; callee } ->
          check "it names the budget" (String.equal what "reification-depth");
          check "and the limit it reached" (limit = 8);
          check "and the function it gave up on"
            (Option.equal String.equal callee (Some "loop"));
          check "the message says which budget and how large"
            (let message = Error.cause_message error.Error.cause in
             contains ~needle:"budget" message
             && contains ~needle:"reification-depth" message
             && contains ~needle:"8" message)
      | Error.Unbound_ident _ | Error.Unbound_name _ | Error.Ambiguous_name _
      | Error.Unfilled_binding _ | Error.Open_code _ | Error.Unliftable_value _
      | Error.Unexpected_character _ | Error.Unterminated _ | Error.Unexpected _
      | Error.Unknown_form _ | Error.Malformed_form _ | Error.Arity_error _
      | Error.Unsupported _ | Error.Division_by_zero | Error.Continuation_reuse _
      | Error.Meta_error _ | Error.Immutable_binding _ | Error.No_matching_clause _
      | Error.Duplicate_binder _ | Error.Inconsistent_pattern_binders _
      | Error.End_of_input ->
          incr failures;
          Printf.printf "FAIL a self-passing closure reported the wrong cause: %s\n"
            (Error.to_string error))

(* {1 The default budget leaves working programs alone} *)

let test_default_budget_is_quiet () =
  let scope, env = ground () in
  let staged text = ignore (Staged_eval.fold ~env (read_with scope text)) in
  (* The corpus's deepest static unrolling, in miniature: it folds to a literal
     and emits nothing, so no budget should ever see it. *)
  staged
    "(letrec ((loop (lam (n acc)\n\
    \                 (if (app (var ==) (var n) (lit 0)) (var acc)\n\
    \                     (app (var loop) (app (var -) (var n) (lit 1))\n\
    \                          (app (var +) (var acc) (var n)))))))\n\
    \  (app (var loop) (lit 2000) (lit 0)))";
  check "a deep static unrolling generalizes nothing"
    (Specialize.generalization_count () = 0);
  check "and creates no specialization point" (Specialize.points_created () = 0);
  staged
    "(letrec ((loop (lam (n) (if (app (var ==) (var n) (lit 0)) (lit 0)\n\
    \                           (app (var +) (var n)\n\
    \                                (app (var loop) (app (var -) (var n) (lit 1))))))))\n\
    \  (lam (x) (app (var loop) (var x))))";
  check "a dynamically controlled recursion ties its knot without generalizing"
    (Specialize.generalization_count () = 0 && Specialize.points_created () = 1)

let () =
  test_growing_argument ();
  test_size_pressure ();
  test_exhaustion ();
  test_default_budget_is_quiet ();
  if !failures > 0 then (
    Printf.printf "%d specialization-budget assertion(s) failed\n" !failures;
    exit 1)
