(* Static-store splitting and dynamic joins (to-do task 7.2, spec §7.4 step 3).

   The acceptance shape is the one the fragment tests use: stage a program that
   mutates, run the residual, and require the answer the source gives. A residual
   that merely looks plausible proves nothing, so every program here is executed
   both ways. On top of that, each group states what the residual is allowed to
   contain — a store test that only compared answers would pass just as well for
   a specializer that residualized everything and proved nothing about the
   "static" half of static-store splitting. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_stage

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "store_test.ash"

let ground () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let env = Env.extend globals Value.empty_env in
  (registry, named, env)

let read_core named text = Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text

let read_surface named source =
  Desugar.program ~scope:(Desugar.scope_of_globals named) (Parser.program ~file source)

(* {1 Residual inspection} *)

let rec fold_nodes f accumulator node =
  let accumulator = f accumulator node in
  match Core.shape node with
  | Core.Quote _ -> accumulator
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
  | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Reifier _ ->
      List.fold_left (fold_nodes f) accumulator (Core.children node)

let count_shape p node =
  fold_nodes (fun total node -> if p node then total + 1 else total) 0 node

let is_set node =
  match Core.shape node with
  | Core.Set _ -> true
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
  | Core.LetRec _ | Core.If _ | Core.Quote _ | Core.Reifier _ ->
      false

let sets node = count_shape is_set node

(* Every binder a residual [Let] introduces: what the store's promotions leave
   behind, and what a substitution that ignored the write set would remove. *)
let let_binders node =
  fold_nodes
    (fun binders node ->
      match Core.shape node with
      | Core.Let { Core.let_binder; _ } -> Ident.Set.add let_binder binders
      | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          binders)
    Ident.Set.empty node

(* {1 The comparison} *)

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

let apply_at source arguments named =
  match arguments with
  | [] -> source
  | _ :: _ ->
      Core.app ~span:(Core.span source) ~func:source
        ~args:(List.map (read_core named) arguments)

(* Stage [term], normalize it as the deliverable is normalized, apply source and
   residual to the same arguments, and require the same outcome. [inspect] states
   what the residual may still contain. *)
let compare_staged ?(inspect = fun _ -> ()) ?(args = []) name ~named ~env term =
  let expected = outcome ~env (apply_at term args named) in
  match Staged_eval.fold ~env term with
  | exception Error.Ash_error error ->
      incr failures;
      Printf.printf "FAIL %s\n  staging failed: %s\n" name (Error.to_string error)
  | raw ->
      let residual = Ash_collapse.Normalize.normalize raw in
      (match Code.unresolved_dependencies ~available:(Env.idents env) residual with
      | [] -> ()
      | open_names ->
          incr failures;
          Printf.printf "FAIL %s\n  residual is open in: %s\n" name
            (String.concat ", "
               (List.map (fun d -> Ident.name d.Code.ident) open_names)));
      let actual = outcome ~env (apply_at residual args named) in
      if not (same_outcome expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  source:   %s\n  residual: %s\n  residual Core: %s\n"
          name (describe expected) (describe actual)
          (Core_printer.to_string residual))
      else inspect residual

let surface ?inspect ?args name source =
  let _, named, env = ground () in
  compare_staged ?inspect ?args name ~named ~env (read_surface named source)

let core ?inspect ?args name text =
  let _, named, env = ground () in
  compare_staged ?inspect ?args name ~named ~env (read_core named text)

let refused name ~cause text =
  let _, named, env = ground () in
  match Staged_eval.fold ~env (read_core named text) with
  | residual ->
      incr failures;
      Printf.printf "FAIL %s\n  expected a refusal, got %s\n" name
        (Core_printer.to_string residual)
  | exception Error.Ash_error error ->
      if not (Error.cause_equal error.Error.cause cause) then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong cause: %s\n" name (Error.to_string error))

let unsupported what = Error.Unsupported { what; by = "the staged evaluator" }

(* {1 Bindings the specializer holds}

   A binding nothing else can reach is the specializer's own: the write happens
   while specializing, the read folds, and the residual keeps no trace of either.
   This is the "static" half of static-store splitting, and it is stated as
   residual size rather than as an answer, because the answer alone would also
   be produced by a specializer that gave up. *)

let test_held_bindings () =
  core
    ~inspect:(fun residual ->
      check "a straight-line write leaves nothing behind"
        (Core.node_count residual = 1))
    "a write the specializer performs"
    "(let x (lit 1) (let _ (set x (lit 2)) (var x)))";

  surface
    ~inspect:(fun residual ->
      check "an accumulator folds to its answer" (Core.node_count residual = 1))
    "an accumulator written twice"
    "var total = 0\ntotal := total + 1\ntotal := total * 10\ntotal";

  surface
    ~inspect:(fun residual ->
      check "a reassigned function is applied at specialization time"
        (sets residual = 0))
    ~args:[ "(lit 4)" ] "a binding holding a closure, reassigned"
    "fn(d) -> {\n  var f = fn(z) -> z + 1\n  f := fn(z) -> z * 2\n  f(d)\n}";

  (* Cell identity, not binder identity: one binder evaluated three times is
     three places, so the writes cannot be confused with each other. *)
  surface
    ~inspect:(fun residual ->
      check "each activation's local folds separately" (Core.node_count residual = 1))
    "a local binding inside a function called repeatedly"
    "fn twice(n) = {\n  var t = n\n  t := t * 2\n  t\n}\ntwice(1) + twice(2) + twice(3)"

(* {1 Bindings the residual program owns}

   The mirror image: a binding something else can reach is given to the residual
   program, writes become residual [Set]s, and reads become the variable. Two
   names for one cell must stay one place — that is what aliasing is. *)

let test_escaping_bindings () =
  surface
    ~inspect:(fun residual ->
      check "the closure's writes survive as residual assignments"
        (sets residual = 2))
    "a closure mutating what it captured"
    "var c = 0\nfn bump() = c := c + 1\nbump()\nbump()\nc";

  surface
    ~inspect:(fun residual ->
      check "the reader and the writer name one place"
        (sets residual = 2
        && Ident.Set.cardinal
             (Ident.Set.inter (let_binders residual)
                (Core.assigned_idents residual))
           = 1))
    "two closures sharing one binding"
    "var n = 0\nfn bump() = n := n + 1\nfn peek() = n\nbump()\nbump()\npeek()";

  (* The write is made by a call the specializer inlines, so it is not written in
     the branch it happens in. That is exactly why a binder free in a lambda is
     never held: the syntactic scan a dynamic branch does would not find it. *)
  surface "a captured binding written under a dynamic branch"
    ~args:[ "(lit #t)" ]
    "fn(b) -> {\n  var c = 0\n  fn bump() = c := c + 1\n  if b then bump() else 0\n  c\n}";
  surface "a captured binding not written under a dynamic branch"
    ~args:[ "(lit #f)" ]
    "fn(b) -> {\n  var c = 0\n  fn bump() = c := c + 1\n  if b then bump() else 0\n  c\n}"

(* {1 Dynamic joins}

   §7.4's own example. The specializer cannot decide which branch runs, so it
   cannot hold a value either branch writes: the binding is given up before the
   fork, both branches write to the residual place, and the read after the join
   is the residual program's. *)

let branching =
  "fn(b) -> {\n  var x = 0\n  if b then x := 1 else x := 2\n  x\n}"

let test_dynamic_joins () =
  let inspect residual =
    check "both writes survive, and one place holds them"
      (sets residual = 2
      && Ident.Set.cardinal (Core.assigned_idents residual) = 1);
    check "the place is bound outside the branch it is written in"
      (Ident.Set.subset (Core.assigned_idents residual) (let_binders residual))
  in
  surface ~inspect ~args:[ "(lit #t)" ] "§7.4's branch, taken" branching;
  surface ~inspect ~args:[ "(lit #f)" ] "§7.4's branch, not taken" branching;

  (* A branch that writes and one that does not still have to agree afterwards:
     the value after the join is not the one the specializer was holding. *)
  let one_sided =
    "fn(b) -> {\n  var x = 7\n  if b then { x := 8\n    0 } else 0\n  x\n}"
  in
  surface ~args:[ "(lit #t)" ] "a write in one branch only, taken" one_sided;
  surface ~args:[ "(lit #f)" ] "a write in one branch only, not taken" one_sided;

  (* A binding neither branch writes stays the specializer's, in the same
     program as one that does. Splitting the store is the point: it is not all
     residual or all static. *)
  surface
    ~inspect:(fun residual ->
      check "only the written binding was given up"
        (Ident.Set.cardinal (Core.assigned_idents residual) = 1);
      check "the held one reached the residual as a constant, not as a place"
        (count_shape
           (fun node ->
             match Core.shape node with
             | Core.Lit constant -> Constant.equal constant (Constant.Num 5)
             | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
             | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _
             | Core.Reifier _ ->
                 false)
           residual
        = 1))
    ~args:[ "(lit #t)" ] "one binding split, one held"
    "fn(b) -> {\n\
    \  var x = 0\n\
    \  var y = 5\n\
    \  if b then x := 1 else x := 2\n\
    \  x + y\n\
     }";

  let nested =
    "fn(a, b) -> {\n\
    \  var x = 0\n\
    \  if a then { if b then x := 1 else x := 2 } else x := 3\n\
    \  x\n\
     }"
  in
  List.iter
    (fun (name, args) -> surface ~args name nested)
    [
      ("nested branches, true true", [ "(lit #t)"; "(lit #t)" ]);
      ("nested branches, true false", [ "(lit #t)"; "(lit #f)" ]);
      ("nested branches, false", [ "(lit #f)"; "(lit #t)" ]);
    ];

  (* Promotion does not need a branch: a value the specializer does not have,
     written to a place it was holding, gives the place up on the spot. *)
  surface
    ~inspect:(fun residual ->
      check "the promoted write folded into its use" (sets residual = 0))
    ~args:[ "(lit 4)" ] "a dynamic value written to a held binding"
    "fn(d) -> {\n  var x = 1\n  x := d + 1\n  x * 2\n}"

(* {1 Where proof is unavailable}

   Refusing is part of the design, not a gap in it: an assignment the store
   cannot place is said out loud rather than performed on the specializer's own
   state or emitted against a binding that is not there. *)

let test_refusals () =
  refused "a recursive group's name is not a binding the store tracks"
    ~cause:(unsupported "assignment to `f`, which the abstract store does not track")
    "(letrec ((f (lam () (lit 1)))) (let _ (set f (lam () (lit 2))) (app (var f))))";

  (* A parameter specialized into a memoized point's body is one value shared by
     every call to it. When the store can hold it the point's body gets its own
     place and the program stages (see {!test_specialization_points}); when it
     cannot, the only place would be outside the residual function, and one
     call's write would be the next call's starting value. *)
  refused "a specialized parameter the store cannot place inside the point"
    ~cause:
      (unsupported
         "a specialization point whose specialized parameter `a` is assigned")
    "(letrec ((f (lam (a n)\n\
    \             (if (app (var ==) (var n) (lit 0))\n\
    \                 (app (lam () (var a)))\n\
    \                 (let _ (set a (app (var +) (var a) (lit 1)))\n\
    \                   (app (var f) (lit 1) (app (var -) (var n) (lit 1))))))))\n\
    \  (lam (k) (app (var f) (lit 1) (var k))))"

(* Recursion the specializer cannot see the end of, over a binding it assigns:
   the point's body carries its own place, so every call starts where the source
   does rather than where the previous call left off. *)
let test_specialization_points () =
  let program =
    "(letrec ((f (lam (a n)\n\
    \             (if (app (var ==) (var n) (lit 0)) (var a)\n\
    \                 (let _ (set a (app (var +) (var a) (lit 1)))\n\
    \                   (app (var f) (lit 1) (app (var -) (var n) (lit 1))))))))\n\
    \  (lam (k) (app (var f) (lit 1) (var k))))"
  in
  List.iter
    (fun argument ->
      core ~args:[ argument ] ("a point over an assigned parameter, " ^ argument) program)
    [ "(lit 0)"; "(lit 1)"; "(lit 4)" ]

(* Handing an environment to another level ends the specializer's exclusive
   claim on what is in it. {!Store.holdable} refuses any scope that builds a
   reifier, so this needs one inherited from outside the held binding's scope —
   and a tower to shift into, which is what a measurement attaches. *)
let test_reflective_boundary () =
  let metrics =
    Ash_collapse.Metrics.measure ~file ~name:"reifier over a held binding"
      (Ash_collapse.Metrics.Core_notation
         "(let r (reifier (e n c) (lit 9))\n\
         \  (let x (lit 1) (let _ (set x (lit 2)) (app (var r)))))")
  in
  match metrics.Ash_collapse.Metrics.residual with
  | Ok residual ->
      incr failures;
      Printf.printf "FAIL a reifier over a held binding\n  staged to %s\n"
        (Core_printer.to_string residual.Ash_collapse.Metrics.term)
  | Error error ->
      check "the reflective boundary is refused while the store holds a binding"
        (Error.cause_equal error.Error.cause
           (unsupported "reifier application while the abstract store holds a binding"))

(* {1 The join itself}

   Every held cell a branch assigns is promoted before the fork, so two forks
   that describe a surviving binding differently is a state the staged evaluator
   should not be able to reach. The guard is still written, and tested here
   directly, because "unreachable" is a claim about today's rules and the next
   rule added below them inherits the refusal rather than having to remember
   it. *)

let test_join () =
  Store.reset ~assigned:Ident.Set.empty;
  let shared = Value.cell (Value.Num 0) in
  let branch_local = Value.cell (Value.Num 9) in
  let x = Ident.fresh "x" and y = Ident.fresh "y" in
  Store.track_held shared ~binder:x (Value.Num 0);
  let before = Store.snapshot () in
  Store.track_held branch_local ~binder:y (Value.Num 9);
  let left = Store.snapshot () in
  Store.restore before;
  let right = Store.snapshot () in
  (match Store.join ~before ~left ~right with
  | Ok joined ->
      let joined = Store.bindings_of joined in
      check "a binding both branches agree on survives the join"
        (List.length joined = 1 && Ident.equal (Store.binder_of (List.hd joined)) x);
      check "a binding a branch created does not"
        (not
           (List.exists
              (fun binding -> Ident.equal (Store.binder_of binding) y)
              joined))
  | Error binding ->
      incr failures;
      Printf.printf "FAIL the join refused an agreeing store (`%s`)\n"
        (Ident.name (Store.binder_of binding)));

  Store.restore before;
  Store.write shared (Value.Num 1);
  let left = Store.snapshot () in
  Store.restore before;
  let right = Store.snapshot () in
  (match Store.join ~before ~left ~right with
  | Ok _ ->
      incr failures;
      Printf.printf "FAIL the join accepted two branches that disagree\n"
  | Error binding ->
      check "the join names the binding the branches disagree about"
        (Ident.equal (Store.binder_of binding) x));
  Store.reset ~assigned:Ident.Set.empty

(* {1 The normalizer's write-set guard}

   ADR 0033's store guard was defensive until now: no residual contained a
   [Set], so nothing could have been rewritten wrongly. A residual the store
   built is the first term where it decides something. Substituting the initial
   value into the read after the join would answer 0 for both branches, so this
   is a test of the guard and not only of the specializer. *)

let test_the_normalizer_guard () =
  let _, named, env = ground () in
  let term = read_surface named branching in
  let raw = Staged_eval.fold ~env term in
  let once = Ash_collapse.Normalize.normalize raw in
  let twice = Ash_collapse.Normalize.normalize once in
  check "normalizing a residual with a store is idempotent"
    (Core.equal_structure once twice);
  check "the assigned binding is not substituted away"
    (Ident.Set.subset (Core.assigned_idents once) (let_binders once));
  check "normalization neither introduced nor removed a write"
    (Ident.Set.cardinal (Core.assigned_idents raw)
    = Ident.Set.cardinal (Core.assigned_idents once));
  List.iter
    (fun (argument, expected) ->
      let applied = apply_at once [ argument ] named in
      check ("the normalized residual still answers " ^ Value.to_string expected)
        (same_outcome (outcome ~env applied) (Ok expected)))
    [ ("(lit #t)", Value.Num 1); ("(lit #f)", Value.Num 2) ]

let () =
  test_held_bindings ();
  test_escaping_bindings ();
  test_dynamic_joins ();
  test_refusals ();
  test_specialization_points ();
  test_reflective_boundary ();
  test_join ();
  test_the_normalizer_guard ();
  if !failures > 0 then (
    Printf.printf "%d store assertion(s) failed\n" !failures;
    exit 1);
  print_endline "store splitting: held bindings, dynamic joins, and refusals"
