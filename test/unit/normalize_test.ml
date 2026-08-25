(* The residual normalizer (to-do task 6.3).

   The depth-invariance claim of 6.4 compares normalized residuals, so the
   normalizer is only as good as its weakest rewrite. This suite pins each
   rewrite separately — flattening, trivial elimination, canonical renaming —
   and then tries to break the whole contract from the effect side: nothing may
   be reordered, hoisted out of a branch or a lambda, or dropped, however pure
   the surrounding term looks. Idempotence is checked over every term the suite
   builds, because a normalizer that is not idempotent makes "compare normal
   forms" mean something different on each side of the comparison. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_collapse

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

(* One shared setup for the whole suite: two terms only compare when their free
   names resolved against the same identities, so every read goes through one
   scope and every run through one registry's stream. *)
let registry, scope, env =
  let reg = Primitives.create () in
  let globals = Primitives.globals reg in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  (* Test-local names standing for functions and variables no program here
     defines. They resolve at read time; a run that reaches one fails exactly
     like any other unbound reference, which the failure sample relies on. *)
  let extra =
    List.map (fun n -> let i = Ident.fresh n in (Ident.name i, i))
      [ "f"; "g"; "y"; "q"; "nope" ]
  in
  (reg, Core_reader.scope_of_list (named @ extra), Env.extend globals Value.empty_env)

let read ?(file = "normalize_test.ash") scope text =
  Core_reader.read ~scope ~file text

(* {1 Running a term} *)

type run = { outcome : Metrics.outcome; trace : Io.event list }

(* One registry owns one buffered stream, so each run clears it first and reads
   what that run alone printed. *)
let run ~registry env term =
  Io.clear (Primitives.io registry);
  let machine = Evaluator.machine () in
  let outcome =
    match Evaluator.run machine ~env term with
    | value -> Metrics.Answered value
    | exception Error.Ash_error error -> Metrics.Failed error
  in
  { outcome; trace = Io.events (Primitives.io registry) }

let same_run a b =
  let agree =
    Metrics.agreement a.outcome b.outcome = Metrics.Agrees
    && List.equal Io.event_equal a.trace b.trace
  in
  if not agree then
    Printf.printf "    [runs differ: %s / %s]\n" (Metrics.outcome_to_string a.outcome)
      (Metrics.outcome_to_string b.outcome);
  agree

let check_idempotent name term =
  let once = Normalize.normalize term in
  check (name ^ ": idempotent")
    (Core.equal_structure (Normalize.normalize once) once)

(* Normalization changed nothing worth naming: canonical shapes agree. *)
let unchanged name term =
  check (name ^ ": unchanged")
    (Core.equal_structure (Normalize.normalize term) (Alpha.canonicalize term))

let equals_normalized name expected_text actual =
  check (name ^ ": shape")
    (Core.equal_structure actual
       (Alpha.canonicalize (read ~file:"expected.ash" scope expected_text)))

(* {1 The rewrites} *)

let test_rewrites () =

  (* Administrative-let flattening: the inner binding comes out first. The
     inner value has to be non-trivial, or substitution would remove it before
     flattening ever sees it. *)
  let nested =
    read scope
      "(let x (let y (app (var g) (lit 1)) (app (var f) (var y))) (var x))"
  in
  equals_normalized "a let whose value is a let"
    "(let y (app (var g) (lit 1)) (let x (app (var f) (var y)) (var x)))"
    (Normalize.normalize nested);
  check_idempotent "flattening" nested;

  (* Sequential administrative lets flatten all the way out, in order. *)
  let deep =
    read scope
      "(let a (let b (app (var g) (lit 1)) (let c (app (var g) (lit 2))\n\
      \             (app (var +) (var b) (var c))))\n\
      \   (var a))"
  in
  equals_normalized "nested administrative lets"
    "(let b (app (var g) (lit 1))\n\
    \   (let c (app (var g) (lit 2))\n\
    \     (let a (app (var +) (var b) (var c)) (var a))))"
    (Normalize.normalize deep);
  check_idempotent "deep flattening" deep;

  (* Trivial bindings substitute everywhere they are used. *)
  let literal = read scope "(let x (lit 5) (app (var +) (var x) (var x)))" in
  equals_normalized "a literal binding substitutes"
    "(app (var +) (lit 5) (lit 5))"
    (Normalize.normalize literal);
  check_idempotent "literal substitution" literal;

  let alias = read scope "(let x (var y) (app (var f) (var x)))" in
  equals_normalized "a variable binding substitutes" "(app (var f) (var y))"
    (Normalize.normalize alias);
  check_idempotent "variable substitution" alias;

  (* A binding nothing mentions goes away entirely. *)
  let unused = read scope "(let x (lit 5) (var y))" in
  equals_normalized "an unused trivial binding drops" "(var y)"
    (Normalize.normalize unused);
  check_idempotent "unused binding" unused;

  (* Hygiene: binders that print alike are different identities, so substituting
     the outer [x] must not touch references belonging to the inner one. A
     substitution matching printed names would rewrite the lambda's body to
     [q]. *)
  let shadowed = read scope "(let x (var q) (app (var f) (lam (x) (var x))))" in
  equals_normalized "same-name shadowing keeps the inner binder"
    "(app (var f) (lam (x) (var x)))"
    (Normalize.normalize shadowed);
  check_idempotent "same-name shadowing" shadowed

(* {1 What must not move} *)

let test_effects () =
  let preserves name text =
    let term = read scope text in
    let normalized = Normalize.normalize term in
    unchanged name term;
    check (name ^ ": runs the same")
      (same_run (run ~registry env term) (run ~registry env normalized));
    check_idempotent name term
  in

  (* Two prints, one after the other: neither swaps nor merges. *)
  preserves "sequential effects" "(let a (app (var print) (lit \"a\")) (let b (app (var print) (lit \"b\")) (var a)))";

  (* An effect inside one branch stays inside it. *)
  preserves "an effectful branch binding"
    "(if (lit #t) (let t (app (var print) (lit \"t\")) (lit 1)) (lit 0))";

  (* An effect inside a lambda body stays under the lambda. Applied, so the
     two runs produce values that can actually be compared rather than two
     closures, which no run can compare. *)
  preserves "an effectful lambda-body binding"
    "(app (lam (z) (let u (app (var print) (lit \"u\")) (var u))) (lit 9))";

  (* An unused effectful binding still happens. *)
  preserves "an unused effectful binding"
    "(let u (app (var print) (lit \"u\")) (lit 1))";

  (* Substitution stops where it would dangle a reference. A set target reads
     the binding to find its cell; eliminating its binding would write
     somewhere else entirely — or nowhere. *)
  preserves "a set target blocks elimination"
    "(let x (lit 5) (set x (lit 6)))";

  (* An alias of a variable something writes to is not substitutable. The
     binding captured the value the variable held then; substituting would make
     the body read the value it holds now, which is a different number. The
     write is under the binding here, and outside it in the escaping case
     below — hence a write set collected over the whole term. *)
  preserves "an assigned variable is not aliased away"
    "(let y (lit 5) (let x (var y) (let z (set y (lit 6)) (var x))))";

  (* The same value, read through a closure that outlives its binding: the
     write happens after the lambda is built and before it is called, so a
     substituted body would answer 6 where the program answers 5. The term is
     not left alone — the alias binding does flatten out of value position —
     so only the run and idempotence are asserted here. *)
  let escaping_alias =
    read scope
      "(let y (lit 5)\n\
      \   (let f (let x (var y) (lam () (var x)))\n\
      \     (let z (set y (lit 6)) (app (var f)))))"
  in
  check "an alias captured by a closure survives a later write"
    (same_run (run ~registry env escaping_alias)
       (run ~registry env (Normalize.normalize escaping_alias)));
  check_idempotent "an escaping alias" escaping_alias;

  (* A literal needs no such guard — nothing can assign one — so this one still
     substitutes even though the term assigns elsewhere. *)
  let literal_beside_a_write =
    read scope "(let y (lit 5) (let x (lit 1) (let z (set y (lit 6)) (app (var +) (var x) (var y)))))"
  in
  check "a literal still substitutes beside a write"
    (same_run
       (run ~registry env literal_beside_a_write)
       (run ~registry env (Normalize.normalize literal_beside_a_write)));
  check "a literal beside a write really did substitute"
    (Residue.((survey ~env (Normalize.normalize literal_beside_a_write)).nodes)
    < Residue.((survey ~env literal_beside_a_write).nodes));
  check_idempotent "a literal beside a write" literal_beside_a_write;

  (* The same for a reference inside a quotation: the quote is data, and the
     binding it reads must still be there when the code runs. The result is
     wrapped so the runs compare values rather than code objects, whose free
     binder identity is not comparable across terms. *)
  preserves "a quoted reference blocks elimination"
    "(let x (lit 5) (let c (quote (var x)) (lit 42)))";

  (* Flattening with an effectful inner value is allowed — as rearrangement:
     the print still precedes the use. *)
  let effectful_flatten =
    read scope "(let x (let y (app (var print) (lit \"y\")) (var y)) (var x))" in
  let flattened = Normalize.normalize effectful_flatten in
  let print_precedes_use =
    match Core.shape flattened with
    | Core.Let { Core.let_value; _ } -> (
        match Core.shape let_value with
        | Core.App { Core.func; _ } -> (
            match Core.shape func with
            | Core.Var ident -> String.equal (Ident.name ident) "print"
            | _ -> false)
        | _ -> false)
    | _ -> false
  in
  check "flattening keeps the print before the use" print_precedes_use;
  check "the effectful flatten computes the same thing"
    (same_run (run ~registry env effectful_flatten) (run ~registry env flattened));
  check_idempotent "effectful flattening" effectful_flatten

(* {1 Data that is not code to be rewritten} *)

let test_data () =
  unchanged "a quotation body keeps its structure"
    (read scope "(lam (x) (quote (app (var f) (var x))))");

  (* Canonical renaming does follow enclosing binders into quotations — that is
     what alpha-equivalence means for a quoted variable. *)
  let renamed = Alpha.canonicalize (read scope "(lam (x) (quote (var x)))") in
  let renaming_follows =
    match Core.shape renamed with
    | Core.Lam { Core.params = [ param ]; lam_body } -> (
        match Core.shape lam_body with
        | Core.Quote inner -> (
            match Core.shape inner with
            | Core.Var referenced -> Ident.equal referenced param
            | _ -> false)
        | _ -> false)
    | _ -> false
  in
  check "canonical renaming follows binders into quotations" renaming_follows;

  (* A reifier's body is another level's code and is left alone too. *)
  let reifier =
    read scope "(reifier (e r k) (let m (app (var print) (lit \"m\")) (var m)))"
  in
  unchanged "a reifier body keeps its structure" reifier;
  check_idempotent "reifier bodies" reifier

(* {1 Whole programs} *)

let programs =
  [
    ("fact",
     "(letrec ((fact (lam (n) (if (app (var ==) (var n) (lit 0)) (lit 1)\n\
     \  (app (var *) (var n) (app (var fact) (app (var -) (var n) (lit 1))))))))\n\
     \  (app (var fact) (lit 5)))");
    ("higher order",
     "(let twice (lam (f v) (app (var f) (app (var f) (var v))))\n\
     \  (app (var twice) (lam (y) (app (var +) (var y) (lit 1))) (lit 7)))");
    ("lists", "(app (var length) (app (var list) (lit 1) (lit 2) (lit 3)))");
    ("output",
     "(let first (app (var print) (lit \"one\"))\n\
     \   (let second (app (var print) (lit \"two\")) (lit 42)))");
    ("failure", "(app (var head) (app (var list) (lit 1)))");
    ("unbound", "(app (var +) (var nope) (lit 1))");
  ]

let test_semantics () =
  List.iter
    (fun (name, text) ->
      let term = read scope text in
      let normalized = Normalize.normalize term in
      check (name ^ ": normalization preserves the run")
        (same_run (run ~registry env term) (run ~registry env normalized));
      check_idempotent ("program " ^ name) term)
    programs

(* {1 Provenance} *)

let test_provenance () =
  let helper = read ~file:"helper.ash" scope "(lam (n) (app (var +) (var n) (lit 1)))" in
  let argument = read ~file:"main.ash" scope "(lit 2)" in
  (* An application of one file's function to another file's constant, wrapped
     in the kind of administrative lets the specializer emits. Every rebuilt
     node keeps the span of the node it came from, so attribution survives. *)
  let mixed =
    Core.app ~span:(Core.span helper)
      ~func:
        (Core.let_ ~span:(Core.span helper)
           ~binder:(Ident.fresh "h")
           ~value:helper
           ~body:(Core.var ~span:(Core.span helper) (Ident.fresh "h")))
      ~args:[ argument ]
  in
  let before = Residue.survey ~env mixed in
  let after = Residue.survey ~env (Normalize.normalize mixed) in
  check "helper origin survives normalization"
    (List.mem_assoc "helper.ash" after.Residue.nodes_by_origin);
  check "main origin survives normalization"
    (List.mem_assoc "main.ash" after.Residue.nodes_by_origin);
  check "normalization never adds nodes"
    (after.Residue.nodes <= before.Residue.nodes)


let () =
  (try
     test_rewrites ();
     Printf.printf "rewrites ok\n";
     test_effects ();
     Printf.printf "effects ok\n";
     test_data ();
     Printf.printf "data ok\n";
     test_semantics ();
     Printf.printf "semantics ok\n";
     test_provenance ();
     Printf.printf "provenance ok\n"
   with Error.Ash_error e -> Printf.printf "ASH ERROR: %s\n" (Error.to_string e));
  if !failures > 0 then (
    Printf.printf "%d normalize test failure(s)\n" !failures;
    exit 1)
  else Printf.printf "normalize tests passed\n"
