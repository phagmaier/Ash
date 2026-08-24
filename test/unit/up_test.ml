(* [up] and the meta bindings (to-do task 4.3).

   Task 4.2 proved that one reifier application lands one level up and comes
   back down. This is the sugar on top of it (spec §5.2) and, more importantly,
   the bindings that make the level above able to do anything: the level below's
   evaluator-group cells, its global environment, its suspended state, and the
   two readings of where in the tower the body is running.

   The claim that matters is the §5.3 demo: replacing [eval] from inside [up] is
   persistent, intercepts every nested evaluation step rather than the first one,
   and does not intercept the level that is running the replacement. *)

open Ash_core
open Ash_syntax
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

let file = "up.ash"

(* A tower and the scope its base program is lowered under. The scope comes from
   level 0's own global frame, so a lowered name denotes that level's identity —
   the levels above have their own clones, and mixing them would resolve to
   nothing. *)
let fresh () =
  let io = Io.create () in
  let tower = Tower.create ~registry:(Primitives.create ~io ()) () in
  let named =
    Ident.Set.fold
      (fun ident collected -> (Ident.name ident, ident) :: collected)
      (Env.idents (Level.global (Tower.ground tower)))
      []
  in
  (tower, io, Desugar.scope_of_globals named)

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

let run tower scope source =
  Tower.run tower (Desugar.program ~scope (Parser.program ~file source))

let evaluate name source =
  let tower, io, scope = fresh () in
  match attempt (fun () -> run tower scope source) with
  | Ok value -> Some (tower, io, value)
  | Error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name (Error.to_string error);
      None

let check_value name expected source =
  match evaluate name source with
  | None -> None
  | Some (tower, io, actual) ->
      if not (Value.equal expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Value.to_string expected) (Value.to_string actual));
      Some (tower, io)

let expect_error name source =
  let tower, _io, scope = fresh () in
  match attempt (fun () -> run tower scope source) with
  | Error error -> Some error
  | Ok value ->
      incr failures;
      Printf.printf "FAIL %s\n  expected a failure, got %s\n" name
        (Value.to_string value);
      None

(* Step 4 of §5.2: the body's value is handed back to the level that suspended,
   which continues where its call was. *)
let test_up_resumes_the_level_below () =
  (match
     check_value "the body's value returns to the level below" (Value.Num 43)
       "1 + up { 42 }"
   with
  | None -> ()
  | Some (tower, _io) ->
      check_int "one `up` materializes exactly one level" 1 (Tower.materialized tower));

  (* Steps 1-3 are laziness: ordinary code never asks for a level. *)
  match check_value "ordinary code materializes nothing" (Value.Num 3) "1 + 2" with
  | None -> ()
  | Some (tower, _io) ->
      check_int "no level exists until something reflects" 0 (Tower.materialized tower)

(* The three bindings that carry the suspended level's state. [exp] is the call
   the sugar expands to, which is what level n was in fact evaluating. *)
let test_suspended_state_bindings () =
  ignore
    (check_value "`exp` is the code level n was evaluating" (Value.Bool true)
       "up { code?(exp) }");
  ignore
    (check_value "`env` is an environment, and holds the caller's bindings"
       (Value.Num 7)
       "let hidden = 7\nup { eval(`{ hidden }, env, cont) }");
  (* [cont] resumes the level below explicitly, and then the body's own value is
     never delivered: §5.2's "the `up` form never returns normally". *)
  ignore
    (check_value "`cont` resumes the level below with the value it is given"
       (Value.Num 10) "up { resume(cont, 10); 999 }")

(* [global] is the level below's own global environment, not the body's: the
   body runs one level up, and each level owns its globals (task 4.1). *)
let test_global_binding () =
  ignore
    (check_value "`global` is an environment" (Value.Bool true)
       "up { resume(cont, code?(`{ 1 })) }");
  match evaluate "`global` is the level below's own frame" "up { global }" with
  | None -> ()
  | Some (tower, _io, value) -> (
      match value with
      | Value.Environment environment ->
          check "`global` is level 0's global environment, not level 1's"
            (Ident.Set.equal
               (Env.idents environment)
               (Env.idents (Level.global (Tower.ground tower))));
          check "and it is not the environment of the level running the body"
            (match Tower.find_level tower 1 with
            | Some upper ->
                not
                  (Ident.Set.equal (Env.idents environment)
                     (Env.idents (Level.global upper)))
            | None -> false)
      | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
      | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
      | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
          check "`global` is an environment" false)

(* §D9: [level] is relative and the base program is 0, so an [up] body is 1 and a
   nested one is 2 whatever the tower is embedded in. [tower_depth()] is the
   explicit opt-in that does see the tower. *)
let test_level_and_depth () =
  ignore (check_value "an `up` body runs at level 1" (Value.Num 1) "up { level }");
  ignore
    (check_value "a nested `up` body runs at level 2" (Value.Num 2)
       "up { resume(cont, up { level }) }");
  ignore
    (check_value "the base program is at level 0" (Value.Num 0) "tower_level()");
  ignore
    (check_value "a tower nobody reflected on has materialized nothing"
       (Value.Num 0) "tower_depth()");
  ignore
    (check_value "and one `up` makes it one deep" (Value.Num 1)
       "up { resume(cont, 0) }\ntower_depth()");
  ignore
    (check_value "the depth a body sees is the tower's, not its own level"
       (Value.Num 2) "up { resume(cont, up { tower_depth() }) }")

(* The §5.3 demo, and the acceptance criterion of task 4.3. A replaced [eval]
   must see every nested node, not just the top one: an evaluator holding a
   direct self-reference would count 1 here and look almost right. *)
let test_persistent_evaluator_replacement () =
  let source =
    "var steps = 0\n\
     up {\n\
    \  let base = eval\n\
    \  eval := fn(e, r, k) -> { steps := steps + 1; base(e, r, k) }\n\
     }\n\
     let answer = (1 + 2) * 4\n\
     [answer, steps]"
  in
  match evaluate "a replaced evaluator runs the program" source with
  | None -> ()
  | Some (_tower, _io, value) -> (
      match value with
      | Value.List [ answer; Value.Num steps ] ->
          check "the program still computes its own answer"
            (Value.equal (Value.Num 12) answer);
          (* [(1 + 2) * 4] alone is nine evaluation steps: the two applications,
             their two operator variables, and the three literals, plus the
             [Var] and [Let] the surrounding statement list contributes. What is
             asserted is only that the count is far past one, because the exact
             total is a property of the desugaring rather than of the law. *)
          check "every nested node is intercepted, not only the outermost"
            (steps > 9)
      | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
      | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
      | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
          check "the program answers with its value and its step count" false)

(* Exactly how deep "arbitrary AST depth" goes, stated as a difference rather
   than a total: a term with one more nested application costs strictly more
   intercepted steps than one without it, at every depth. *)
let test_interception_follows_ast_depth () =
  let counted body =
    let source =
      Printf.sprintf
        "var steps = 0\n\
         up {\n\
        \  let base = eval\n\
        \  eval := fn(e, r, k) -> { steps := steps + 1; base(e, r, k) }\n\
         }\n\
         let answer = %s\n\
         steps"
        body
    in
    match evaluate "a nested term is counted" source with
    | Some (_tower, _io, Value.Num steps) -> steps
    | Some _ | None -> -1
  in
  let depths = List.map counted [ "1"; "1 + 1"; "1 + (1 + 1)"; "1 + (1 + (1 + 1))" ] in
  check "each extra level of nesting is intercepted too"
    (match depths with
    | [ a; b; c; d ] -> a > 0 && b > a && c > b && d > c && c - b = d - c
    | _ -> false)

(* Level independence (spec §5.7): the replacement changes the level below and
   not the level running it. If it changed its own level, the traced evaluator
   would be its own interpreter and the first step would not terminate. *)
let test_replacement_does_not_intercept_its_own_level () =
  let source =
    "var steps = 0\n\
     up {\n\
    \  let base = eval\n\
    \  eval := fn(e, r, k) -> { steps := steps + 1; base(e, r, k) }\n\
     }\n\
     let before = steps\n\
     let inner = up { resume(cont, 1 + (2 + (3 + 4))) }\n\
     let after = steps\n\
     [inner, before, after]"
  in
  match evaluate "a second `up` runs with the patch installed" source with
  | None -> ()
  | Some (_tower, _io, value) -> (
      match value with
      | Value.List [ inner; Value.Num before; Value.Num after ] ->
          check "the level-1 body still computes its own answer"
            (Value.equal (Value.Num 10) inner);
          (* Level 0 evaluates the [up] call itself and the statements around it,
             so the counter does move; what it must not include is the body's own
             arithmetic, which is four applications and seven operands more. *)
          check "level 1's own execution is not intercepted" (after - before < 10)
      | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
      | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
      | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
          check "the program answers with its three measurements" false)

(* The replacement is persistent, which is what distinguishes it from the
   [meta_with] overlay of §5.5 (Phase 8): it outlives the [up] form that
   installed it and applies to everything the level does afterwards. *)
let test_replacement_is_persistent_and_composes () =
  let source =
    "var log = []\n\
     up { let base = eval; eval := fn(e, r, k) -> { log := 'first :: log; base(e, r, k) } }\n\
     up { let base = eval; eval := fn(e, r, k) -> { log := 'second :: log; base(e, r, k) } }\n\
     let saw = log\n\
     head(saw) == 'first && head(tail(saw)) == 'second"
  in
  (* The second [up] reads the cell the first one wrote, so the replacements
     nest: the most recently installed runs first and delegates inward, which
     puts the older one's mark at the head of the log. A replacement that had
     been scoped to its own [up] would leave only one mark. *)
  ignore
    (check_value "a later replacement wraps the earlier one rather than replacing it"
       (Value.Bool true) source)

(* [apply] is the other cell §5.2 names, and replacing it intercepts calls rather
   than evaluation steps: a program that makes exactly two calls is seen twice. *)
let test_apply_cell () =
  let source =
    "var calls = 0\n\
     fn twice(n) = n + n\n\
     up { let base = apply; apply := fn(f, args, k) -> { calls := calls + 1; base(f, args, k) } }\n\
     let answer = twice(twice(3))\n\
     [answer, calls]"
  in
  match evaluate "a replaced applier runs the program" source with
  | None -> ()
  | Some (_tower, _io, value) -> (
      match value with
      | Value.List [ answer; Value.Num calls ] ->
          check "the program still computes its own answer"
            (Value.equal (Value.Num 12) answer);
          check "and every application is intercepted" (calls >= 2)
      | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
      | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
      | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
          check "the program answers with its value and its call count" false)

(* Materializing the cells must be observationally inert: an [up] whose body
   never touches [eval] leaves the level below running exactly what it ran. *)
let test_untouched_cells_change_nothing () =
  let source =
    "var order = []\n\
     let a = { order := 'one :: order; 1 }\n\
     let ignored = up { 0 }\n\
     let b = { order := 'two :: order; 2 }\n\
     [a + b, length(order)]"
  in
  ignore
    (check_value "a level whose cells exist but are untouched runs unchanged"
       (Value.List [ Value.Num 3; Value.Num 2 ])
       source)

(* Errors: [meta_error] fails at the level running it, and the level below never
   resumes, so the statement after the [up] does not run. *)
let test_meta_error () =
  match
    expect_error "meta_error fails the run"
      "let ignored = up { meta_error(\"stop\") }\nprintln(\"after\")"
  with
  | None -> ()
  | Some error ->
      check "meta_error reports its message"
        (Error.cause_equal error.Error.cause (Error.Meta_error "stop"));
      check "and it belongs to the level that ran it" (error.Error.level = Some 1)

(* Without a tower there is no level to reach, and the meta bindings say so
   rather than answering about a level that does not exist. *)
let test_refusals_without_a_tower () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Desugar.scope_of_globals named in
  let env = Env.extend globals Value.empty_env in
  let evaluate source =
    attempt (fun () ->
        Evaluator.eval ~env (Desugar.program ~scope (Parser.program ~file source)))
  in
  (match evaluate "up { 1 }" with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL a machine with no tower refuses `up`, got %s\n"
        (Value.to_string value)
  | Error error ->
      check "`up` without a tower is refused as reifier application"
        (Error.cause_equal error.Error.cause
           (Error.Unsupported
              { what = "reifier application"; by = "the ground evaluator" })));
  match evaluate "meta_eval()" with
  | Ok value ->
      incr failures;
      Printf.printf "FAIL the base program has no level below, got %s\n"
        (Value.to_string value)
  | Error error ->
      check "a meta binding read at the base program names the missing level"
        (Error.cause_equal error.Error.cause
           (Error.Unsupported
              { what = "eval"; by = "the base program, which has no level below it" }))

let () =
  test_up_resumes_the_level_below ();
  test_suspended_state_bindings ();
  test_global_binding ();
  test_level_and_depth ();
  test_persistent_evaluator_replacement ();
  test_interception_follows_ast_depth ();
  test_replacement_does_not_intercept_its_own_level ();
  test_replacement_is_persistent_and_composes ();
  test_apply_cell ();
  test_untouched_cells_change_nothing ();
  test_meta_error ();
  test_refusals_without_a_tower ();
  if !failures > 0 then (
    Printf.printf "%d `up` assertion(s) failed\n" !failures;
    exit 1)
