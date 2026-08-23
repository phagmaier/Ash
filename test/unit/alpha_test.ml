(* Unit tests for free identifiers, alpha-equivalence, and canonical renaming
   (to-do task 0.6). *)

open Ash_core
open Ash_syntax

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_int name expected actual =
  if not (Int.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %d\n  actual:   %d\n" name expected actual)

let read text = Core_reader.read ~file:"a.ash" text

(* Reading twice gives alpha-variants: the text names binding structure, and the
   identities come from the reader. That is what makes it a corpus for this. *)
let equivalent name text = check name (Alpha.equal (read text) (read text))

let sp =
  Span.make
    ~start:(Span.position ~file:"a.ash" ~line:1 ~column:1 ~offset:0)
    ~stop:(Span.position ~file:"a.ash" ~line:1 ~column:2 ~offset:1)

let corpus =
  [
    "(lit 42)";
    "(named-var \"x\")";
    "(lam (x y) (var x))";
    "(app (lam (x) (var x)) (lit 1))";
    "(let x (lit 1) (var x))";
    "(letrec ((f (lam (n) (app (var g) (var n)))) (g (lam (n) (app (var f) (var n))))) (var f))";
    "(if (lit #t) (lit 1) (lit 2))";
    "(lam (x) (set x (lit 1)))";
    "(lam (x) (quote (var x)))";
    "(reifier (e r k) (app (var k) (var e)))";
  ]

(* Free identifiers *)

let test_free_idents () =
  let a = Ident.fresh "a" and b = Ident.fresh "b" in
  let scope = Core_reader.scope_of_list [ ("a", a); ("b", b) ] in
  let read_open text = Core_reader.read ~scope ~file:"a.ash" text in
  let free text = Alpha.free_idents (read_open text) in
  let is set idents =
    Ident.Set.equal set (Ident.Set.of_list idents)
  in
  check "a literal has no free identifiers" (is (free "(lit 1)") []);
  check "a named variable has no free identifiers" (is (free "(named-var \"a\")") []);
  check "a variable is free" (is (free "(var a)") [ a ]);
  check "a lambda binds its parameters" (is (free "(lam (x) (var x))") []);
  check "a lambda leaves other references free"
    (is (free "(lam (x) (app (var x) (var a)))") [ a ]);
  check "an application unions its parts" (is (free "(app (var a) (var b))") [ a; b ]);
  (* A let binder scopes the body but not the value, which is the difference
     from letrec and the reason this traversal is written out per form. *)
  check "a let binder does not scope its own value"
    (is (free "(let x (var a) (var x))") [ a ]);
  check "a letrec group scopes its own lambdas"
    (is (free "(letrec ((f (lam (n) (app (var f) (var a))))) (var f))") [ a ]);
  check "an if unions all three branches"
    (is (free "(if (var a) (var b) (lit 1))") [ a; b ]);
  (* Assignment reads the binding to find its cell, so the target is a
     reference. *)
  check "a set target is a reference" (is (free "(set a (lit 1))") [ a ]);
  check "a bound set target is not free" (is (free "(lam (x) (set x (var a)))") [ a ]);
  check "a quoted variable is free like any other"
    (is (free "(quote (var a))") [ a ]);
  check "a quoted variable bound outside the quote is bound"
    (is (free "(lam (x) (quote (var x)))") []);
  check "a reifier binds its three parameters"
    (is (free "(reifier (e r k) (app (var k) (app (var e) (var a))))") [ a ])

(* Alpha-equivalence *)

let test_equal () =
  List.iter (fun text -> equivalent ("two reads agree: " ^ text) text) corpus;
  check "a term equals itself" (List.for_all (fun t -> Alpha.equal (read t) (read t)) corpus);

  check "binder names do not matter"
    (Alpha.equal (read "(lam (x) (var x))") (read "(lam (y) (var y))"));
  check "binding structure does matter"
    (not (Alpha.equal (read "(lam (x) (var x))") (read "(lam (x) (lit 1))")));
  check "parameter count matters"
    (not (Alpha.equal (read "(lam (x y) (var x))") (read "(lam (x) (var x))")));
  check "argument count matters"
    (not
       (Alpha.equal
          (read "(lam (f) (app (var f) (lit 1)))")
          (read "(lam (f) (app (var f) (lit 1) (lit 1)))")));
  check "which parameter is used matters"
    (not (Alpha.equal (read "(lam (x y) (var x))") (read "(lam (x y) (var y))")));
  check "constants matter"
    (not (Alpha.equal (read "(lit 1)") (read "(lit 2)")));
  check "a named variable is not a variable"
    (not
       (Alpha.equal
          (read "(let x (lit 1) (var x))")
          (read "(let x (lit 1) (named-var \"x\"))")));

  (* Free identifiers are compared by identity: two different free variables are
     different variables however they print. *)
  let a = Ident.fresh "a" and b = Ident.fresh "b" and a' = Ident.fresh "a" in
  let with_scope pairs text =
    Core_reader.read ~scope:(Core_reader.scope_of_list pairs) ~file:"a.ash" text
  in
  check "the same free identifier is the same variable"
    (Alpha.equal (with_scope [ ("a", a) ] "(var a)") (with_scope [ ("a", a) ] "(var a)"));
  check "different free identifiers are different variables"
    (not
       (Alpha.equal (with_scope [ ("a", a) ] "(var a)") (with_scope [ ("b", b) ] "(var b)")));
  check "free identifiers that print alike are still different"
    (not
       (Alpha.equal (with_scope [ ("a", a) ] "(var a)") (with_scope [ ("a", a') ] "(var a)")));
  check "a free variable is not a bound one"
    (not (Alpha.equal (with_scope [ ("a", a) ] "(var a)") (read "(lam (a) (var a))")));

  (* Shadowing: two binders printing alike, with references to each. Text cannot
     express this, so it is built directly. *)
  let x1 = Ident.fresh "x" and x2 = Ident.fresh "x" in
  let nested inner_use outer_use =
    Core.let_ ~span:sp ~binder:x1
      ~value:(Core.lit ~span:sp (Constant.Num 1))
      ~body:
        (Core.let_ ~span:sp ~binder:x2
           ~value:(Core.lit ~span:sp (Constant.Num 2))
           ~body:
             (Core.app ~span:sp
                ~func:(Core.var ~span:sp outer_use)
                ~args:[ Core.var ~span:sp inner_use ]))
  in
  check "shadowed binders stay distinguishable"
    (not (Alpha.equal (nested x2 x1) (nested x1 x2)));
  check "the same shadowing term equals itself" (Alpha.equal (nested x2 x1) (nested x2 x1));

  (* Recursive groups correspond position by position. *)
  check "a renamed recursive group is equivalent"
    (Alpha.equal
       (read "(letrec ((f (lam (n) (app (var g) (var n)))) (g (lam (n) (var n)))) (var f))")
       (read "(letrec ((p (lam (m) (app (var q) (var m)))) (q (lam (m) (var m)))) (var p))"));
  check "reordering a recursive group changes it"
    (not
       (Alpha.equal
          (read "(letrec ((f (lam (n) (var n))) (g (lam (n) (lit 1)))) (var f))")
          (read "(letrec ((f (lam (n) (lit 1))) (g (lam (n) (var n)))) (var f))")));
  check "group size matters"
    (not
       (Alpha.equal
          (read "(letrec ((f (lam (n) (var n)))) (var f))")
          (read "(letrec ((f (lam (n) (var n))) (g (lam (n) (var n)))) (var f))")));

  (* Quotation and reifiers bind and refer like everything else. *)
  check "renaming under a quotation is equivalent"
    (Alpha.equal (read "(lam (x) (quote (var x)))") (read "(lam (y) (quote (var y)))"));
  check "a quotation is not its contents"
    (not (Alpha.equal (read "(quote (lit 1))") (read "(lit 1)")));
  check "renaming reifier parameters is equivalent"
    (Alpha.equal
       (read "(reifier (e r k) (app (var k) (var e)))")
       (read "(reifier (a b c) (app (var c) (var a)))"));
  check "which reifier parameter is used matters"
    (not
       (Alpha.equal
          (read "(reifier (e r k) (app (var k) (var e)))")
          (read "(reifier (e r k) (app (var k) (var r)))")));
  check "renaming a set target is equivalent"
    (Alpha.equal (read "(lam (x) (set x (lit 1)))") (read "(lam (y) (set y (lit 1)))"));

  (* Spans are metadata and take no part in meaning. *)
  check "layout does not matter"
    (Alpha.equal (read "(lam (x) (var x))")
       (Core_reader.read ~file:"other.ash" "  (lam (x)\n    (var x))"))

(* Canonical renaming *)

let test_canonicalize () =
  let terms = List.map read corpus in
  check "canonicalizing preserves meaning"
    (List.for_all (fun term -> Alpha.equal (Alpha.canonicalize term) term) terms);
  check "canonicalizing is idempotent"
    (List.for_all
       (fun term ->
         Core.equal_structure
           (Alpha.canonicalize (Alpha.canonicalize term))
           (Alpha.canonicalize term))
       terms);

  (* The point of canonical renaming: structural equality of canonicalized terms
     is alpha-equivalence, so a normalizer or a report can use it as a key. *)
  let pairs = List.concat_map (fun a -> List.map (fun b -> (a, b)) terms) terms in
  check "structural equality of canonical terms agrees with alpha-equivalence"
    (List.for_all
       (fun (a, b) ->
         Bool.equal (Alpha.equal a b)
           (Core.equal_structure (Alpha.canonicalize a) (Alpha.canonicalize b)))
       pairs);
  check_int "the corpus is compared pairwise" 100 (List.length pairs);

  check "alpha-variants canonicalize to the same term"
    (Core.equal_structure
       (Alpha.canonicalize (read "(lam (x) (var x))"))
       (Alpha.canonicalize (read "(lam (y) (var y))")));
  check "different terms do not"
    (not
       (Core.equal_structure
          (Alpha.canonicalize (read "(lam (x y) (var x))"))
          (Alpha.canonicalize (read "(lam (x y) (var y))"))));

  (* Free identifiers keep their identity, and cannot be confused with a
     renumbered binder even when they print the same way canonical binders do. *)
  let v = Ident.fresh "v" in
  let term =
    Core.lam ~span:sp ~params:[ Ident.fresh "v" ]
      ~body:(Core.var ~span:sp v)
  in
  let canonical = Alpha.canonicalize term in
  check "a free identifier survives canonicalization"
    (Ident.Set.equal (Alpha.free_idents canonical) (Ident.Set.singleton v));
  check "a canonical binder cannot collide with a free identifier"
    (List.for_all (fun ident -> Ident.id ident < 0) (Core.binders canonical));
  check "a term whose free name matches the canonical name is unchanged in meaning"
    (Alpha.equal canonical term);

  check "spans survive canonicalization"
    (Span.equal (Core.span (read "(lit 1)"))
       (Core.span (Alpha.canonicalize (read "(lit 1)"))))

let () =
  test_free_idents ();
  test_equal ();
  test_canonicalize ();
  if !failures > 0 then (
    Printf.printf "%d alpha assertion(s) failed\n" !failures;
    exit 1)
