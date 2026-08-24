(* Invariant OR at the Ash level (to-do task 2.1, spec §D3).

   All recursive calls among the reflective evaluator functions resolve
   dynamically through their cells, so replacing one intercepts every nested
   step rather than only the entry. The host side of this is tested in
   `test/unit/evaluator_test.ml`; what is tested here is the same law for the
   evaluator group written in Ash, which is the group the tower will actually
   replace.

   The spec's own formulation of the test is §D3's:

     var hits = 0
     up { let base = eval; eval := fn(e,r,k) -> { hits := hits + 1; base(e,r,k) } }
     run(`{ 1 + (2 * (3 - (4 / 5))) }`)
     assert hits >= 9      # every node, not just the root

   `up` and `run` are Phase 4 and Phase 3. The replacement they would perform is
   written directly here instead, which is the same operation on the same cell:
   `up` is what allocates the level, not what makes the reference dynamic. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_self

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_int name expected actual =
  if not (Int.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %d\n  actual:   %d\n" name expected actual)

let file = "or.ash"

(* One registry per run: the interpreter, the interpreted program, and the
   dereference counter all belong to the same level. *)
let level source =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let term =
    Desugar.program ~scope:(Desugar.scope_of_globals named)
      (Parser.program ~file source)
  in
  (registry, globals, term)

let host ~globals term = Evaluator.eval ~env:(Env.extend globals Value.empty_env) term

(* Run an interface appended to the interpreter against the same real-Code
   subject and Code-keyed globals that [Self.interpreting] uses. *)
let through ~extra ~globals term =
  host ~globals (Self.interpreting ~extra ~globals term)

let pair name value =
  match value with
  | Value.List [ Value.Num count; answer ] -> (count, answer)
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
  | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
      incr failures;
      Printf.printf "FAIL %s did not answer [count, value]: %s\n" name
        (Value.to_string value);
      (0, Value.Unit)

(* Wrapping one group member, in Ash. `base` holds the function the cell held;
   every reference to the member inside `base` is still a dereference, so the
   wrapper sees the nested steps too. *)
let wrapper member =
  let parameters, arguments =
    if String.equal member "apply" then ("a, b, c, d", "a, b, c, d")
    else ("a, b, c", "a, b, c")
  in
  Printf.sprintf
    "fn traced(e, prims) = {\n\
    \  var hits = 0\n\
    \  let base = %s\n\
    \  %s := fn(%s) -> {\n\
    \    hits := hits + 1\n\
    \    base(%s)\n\
    \  }\n\
    \  let answer = interpret(e, prims)\n\
    \  %s := base\n\
    \  [hits, answer]\n\
     }\n\
     traced"
    member member parameters arguments member

(* §D3's own assertion. The program has thirteen Core nodes once `1 + (2 * (3 -
   (4 / 5)))` is lowered — four applications, four operator variables, five
   literals — and a wrapper that saw only the root would report one. *)
let test_every_nested_node () =
  let registry, globals, term = level "1 + (2 * (3 - (4 / 5)))" in
  let expected = host ~globals term in
  let hits, answer =
    pair "the traced run" (through ~extra:(wrapper "eval") ~globals term)
  in
  check "the interpreted answer is the ground one"
    (Value.equal expected (Self.reveal answer));
  check "wrapping eval observes more than the entry" (hits >= 9);
  check_int "wrapping eval observes every node" (Core.node_count term) hits;
  check "the run dereferenced the group's cells"
    (Primitives.open_dereferences registry > hits)

(* The other two members are patchable on the same terms; a group where only
   `eval` were dynamic would pass the test above and still hide every
   application from a meta level. *)
let test_every_member () =
  let _, globals, term = level "fn twice(f, x) = f(f(x))\ntwice(fn(n) -> n + 1, 5)" in
  let expected = host ~globals term in
  List.iter
    (fun (member, least) ->
      let hits, answer =
        pair ("tracing " ^ member) (through ~extra:(wrapper member) ~globals term)
      in
      check
        (Printf.sprintf "tracing %s leaves the answer alone" member)
        (Value.equal expected (Self.reveal answer));
      check
        (Printf.sprintf "%s is dereferenced more than once" member)
        (hits >= least))
    [ ("eval", 2); ("apply", 4); ("eval_list", 2) ]

(* A replacement installed while evaluation is already under way takes effect at
   the next step, not at the next top-level call. This is the property that a
   group threaded as a parameter could not have. *)
let test_replacement_mid_evaluation () =
  let extra =
    "fn traced(e, prims) = {\n\
    \  var early = 0\n\
    \  var late = 0\n\
    \  let base = eval\n\
    \  eval := fn(a, b, c) -> {\n\
    \    early := early + 1\n\
    \    if early == 3 then\n\
    \      eval := fn(x, y, z) -> {\n\
    \        late := late + 1\n\
    \        base(x, y, z)\n\
    \      }\n\
    \    else 0\n\
    \    base(a, b, c)\n\
    \  }\n\
    \  let answer = interpret(e, prims)\n\
    \  eval := base\n\
    \  [late, answer]\n\
     }\n\
     traced"
  in
  let _, globals, term = level "1 + (2 * (3 - (4 / 5)))" in
  let expected = host ~globals term in
  let late, answer =
    pair "the mid-evaluation replacement" (through ~extra ~globals term)
  in
  check "a replacement mid-evaluation leaves the answer alone"
    (Value.equal expected (Self.reveal answer));
  (* Three steps ran under the first wrapper; every later one must reach the
     second, which the first one never calls. *)
  check_int "a replacement takes effect at the next step"
    (Core.node_count term - 3)
    late

(* Restoring the cell restores the group: the wrapper is not woven into anything
   that survives it. *)
let test_restoration () =
  let extra =
    "fn traced(e, prims) = {\n\
    \  var during = 0\n\
    \  let base = eval\n\
    \  eval := fn(a, b, c) -> {\n\
    \    during := during + 1\n\
    \    base(a, b, c)\n\
    \  }\n\
    \  let first = interpret(e, prims)\n\
    \  let counted = during\n\
    \  eval := base\n\
    \  let second = interpret(e, prims)\n\
    \  [counted, [first == second, during - counted]]\n\
     }\n\
     traced"
  in
  let _, globals, term = level "1 + 2 * 3" in
  let counted, rest = pair "the restored run" (through ~extra ~globals term) in
  check "the wrapper ran while it was installed" (counted > 0);
  (* The second run agrees with the first and the wrapper sees none of it: it was
     not woven into anything that outlived the cell it was written to. *)
  check "restoring the cell restores the group"
    (Value.equal (Value.List [ Value.Bool true; Value.Num 0 ]) rest)

(* Patching at depth (to-do task 2.3).

   §D3's fixture again, but with the patched interpreter itself being
   interpreted. Which layer carries the patch decides what the patch sees, and
   that is the whole claim: a layer's `eval` cell governs the evaluation that
   layer is performing, and nothing else.

   `Self.interpreting t` is the term that interprets `t`, so the outer call is
   the layer nearer the ground evaluator and the inner one is the layer nearer
   the program. *)
let test_patching_at_depth () =
  let _, globals, term = level "1 + (2 * (3 - (4 / 5)))" in
  let expected = host ~globals term in
  let run nested = Evaluator.eval ~env:(Env.extend globals Value.empty_env) nested in
  (* The patch on the layer that runs the program: it sees the program's nodes,
     exactly as it does at depth 1, even though the interpreter it is patching is
     itself running interpreted. *)
  let inner_patched =
    Self.interpreting ~globals (Self.interpreting ~extra:(wrapper "eval") ~globals term)
  in
  let inner_hits, inner_answer =
    pair "the patched inner layer" (run inner_patched)
  in
  check "an interpreted interpreter still answers the ground value"
    (Value.equal expected (Self.reveal inner_answer));
  check "patching at depth observes more than the entry" (inner_hits >= 9);
  check_int "patching at depth observes every node of the program"
    (Core.node_count term) inner_hits;
  (* The patch on the layer that runs the *interpreter*: its subject is the
     interpreter's own execution, which is thousands of steps rather than
     thirteen. Same fixture, same answer, a different thing observed. *)
  let outer_patched =
    Self.interpreting ~extra:(wrapper "eval") ~globals (Self.interpreting ~globals term)
  in
  let outer_hits, outer_answer = pair "the patched outer layer" (run outer_patched) in
  check "patching the layer below leaves the answer alone"
    (Value.equal expected (Self.reveal outer_answer));
  (* Two orders of magnitude is not a tuning constant: interpreting one node
     costs the interpreter a great many nodes of its own, so anything close to
     the program's count would mean the patch had reached the wrong subject. *)
  check "the layer below observes the interpreter, not the program"
    (outer_hits > 100 * inner_hits);
  (* `apply` and `eval_list` are patchable at depth on the same terms, and their
     counts say which steps they are: four applications, one per operator, and
     three `eval_list` calls per two-argument application — one per argument and
     one for the empty tail. *)
  List.iter
    (fun (member, expected_hits) ->
      let nested =
        Self.interpreting ~globals
          (Self.interpreting ~extra:(wrapper member) ~globals term)
      in
      let hits, answer = pair ("patching " ^ member ^ " at depth") (run nested) in
      check
        (Printf.sprintf "patching %s at depth leaves the answer alone" member)
        (Value.equal expected (Self.reveal answer));
      check_int
        (Printf.sprintf "patching %s at depth observes its own steps" member)
        expected_hits hits)
    [ ("apply", 4); ("eval_list", 12) ]

(* Instrumentation is observationally inert: the dereference counter is a
   property of the run, and reading or clearing it changes nothing about it. *)
let test_instrumentation_is_inert () =
  let registry, globals, term =
    level "fn fact(n) = if n == 0 then 1 else n * fact(n - 1)\nfact(6)"
  in
  let first = Self.eval ~globals term in
  let counted = Primitives.open_dereferences registry in
  Primitives.reset_open_dereferences registry;
  let second = Self.eval ~globals term in
  check "clearing the counter does not change the answer" (Value.equal first second);
  check "the counter starts again from zero"
    (Int.equal counted (Primitives.open_dereferences registry));
  check "an interpreted run dereferences the group" (counted > 0);
  check "the answer is the ground one"
    (Value.equal (Self.reveal (host ~globals term)) first)

let () =
  test_every_nested_node ();
  test_every_member ();
  test_replacement_mid_evaluation ();
  test_restoration ();
  test_patching_at_depth ();
  test_instrumentation_is_inert ();
  if !failures > 0 then (
    Printf.printf "%d open-recursion law assertion(s) failed\n" !failures;
    exit 1)
