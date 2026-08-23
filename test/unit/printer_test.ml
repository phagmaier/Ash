(* Unit tests for the Core printer (to-do task 0.6). *)

open Ash_core
open Ash_syntax

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_string name expected actual =
  if not (String.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name expected actual)

let check_raises_invalid_argument name thunk =
  match thunk () with
  | _ ->
      incr failures;
      Printf.printf "FAIL %s\n  expected Invalid_argument, got normal return\n" name
  | exception Invalid_argument _ -> ()

let sp =
  Span.make
    ~start:(Span.position ~file:"p.ash" ~line:1 ~column:1 ~offset:0)
    ~stop:(Span.position ~file:"p.ash" ~line:1 ~column:2 ~offset:1)

let lit n = Core.lit ~span:sp (Constant.Num n)

(* The law this module and Core_reader exist to satisfy together. *)
let round_trips term =
  let printed = Core_printer.to_string term in
  let scope = Core_printer.free_scope term in
  Alpha.equal (Core_reader.read ~scope ~file:"<printed>" printed) term

let check_round_trip name term = check ("print then read: " ^ name) (round_trips term)

let read text = Core_reader.read ~file:"p.ash" text

(* Every Core form survives the round trip. *)

let test_forms () =
  List.iter
    (fun (name, text) -> check_round_trip name (read text))
    [
      ("lit number", "(lit 42)");
      ("lit negative", "(lit -7)");
      ("lit boolean", "(lit #f)");
      ("lit string", "(lit \"a\\nb\\\"c\")");
      ("lit symbol", "(lit 'zero)");
      ("lit unit", "(lit unit)");
      ("lit nil", "(lit nil)");
      ("var", "(lam (x) (var x))");
      ("named-var", "(named-var \"x\")");
      ("lam", "(lam (x y) (app (var x) (var y)))");
      ("lam nullary", "(lam () (lit 1))");
      ("app", "(app (lam (x) (var x)) (lit 1))");
      ("app nullary", "(lam (f) (app (var f)))");
      ("let", "(let x (lit 1) (var x))");
      ("letrec", "(letrec ((f (lam (n) (app (var g) (var n)))) (g (lam (n) (var n)))) (var f))");
      ("letrec empty", "(letrec () (lit 1))");
      ("if", "(if (lit #t) (lit 1) (lit 2))");
      ("set", "(lam (x) (set x (lit 1)))");
      ("quote", "(quote (lit 1))");
      ("quote of a bound variable", "(lam (x) (quote (var x)))");
      ("reifier", "(reifier (e r k) (app (var k) (var e)))");
      ("nested", "(lam (f) (letrec ((g (lam (n) (if (var n) (quote (var f)) (app (var g) (var n)))))) (var g)))");
    ];
  check_string "the printed form is the canonical one" "(lam (x y) (app (var x) (var y)))"
    (Core_printer.to_string (read "(lam (x y) (app (var x) (var y)))"));
  check_string "constants print in datum notation, not surface notation"
    "(app (lit #t) (lit 'zero) (lit unit) (lit nil) (lit \"s\"))"
    (Core_printer.to_string
       (read "(app (lit #t) (lit 'zero) (lit unit) (lit nil) (lit \"s\"))"))

(* Renaming: a printed binder never shadows a visible name. *)

let test_renaming () =
  (* Two binders printing alike, with a reference to each. Printing them both as
     x would silently rebind the outer reference to the inner binder. *)
  let x1 = Ident.fresh "x" and x2 = Ident.fresh "x" in
  let shadowing =
    Core.let_ ~span:sp ~binder:x1 ~value:(lit 1)
      ~body:
        (Core.let_ ~span:sp ~binder:x2 ~value:(lit 2)
           ~body:
             (Core.app ~span:sp ~func:(Core.var ~span:sp x1) ~args:[ Core.var ~span:sp x2 ]))
  in
  check_string "a shadowing binder is renamed"
    "(let x (lit 1) (let x1 (lit 2) (app (var x) (var x1))))"
    (Core_printer.to_string shadowing);
  check_round_trip "shadowing" shadowing;

  let same_name_params =
    Core.lam ~span:sp ~params:[ x1; x2 ]
      ~body:(Core.app ~span:sp ~func:(Core.var ~span:sp x1) ~args:[ Core.var ~span:sp x2 ])
  in
  check_string "parameters printing alike are renamed apart"
    "(lam (x x1) (app (var x) (var x1)))"
    (Core_printer.to_string same_name_params);
  check_round_trip "same-name parameters" same_name_params;

  (* Renaming is scoped: leaving a scope frees the name again, so sibling
     subterms both get the plain name. *)
  let siblings =
    Core.app ~span:sp
      ~func:(Core.lam ~span:sp ~params:[ x1 ] ~body:(Core.var ~span:sp x1))
      ~args:[ Core.lam ~span:sp ~params:[ x2 ] ~body:(Core.var ~span:sp x2) ]
  in
  check_string "sibling scopes reuse the same name"
    "(app (lam (x) (var x)) (lam (x) (var x)))" (Core_printer.to_string siblings);

  (* A binder must not capture a free name either. *)
  let free_x = Ident.fresh "x" in
  let shadows_free =
    Core.lam ~span:sp ~params:[ x1 ]
      ~body:(Core.app ~span:sp ~func:(Core.var ~span:sp x1) ~args:[ Core.var ~span:sp free_x ])
  in
  check_string "a binder does not take a free name"
    "(lam (x1) (app (var x1) (var x)))" (Core_printer.to_string shadows_free);
  check_round_trip "binder next to a free name of the same spelling" shadows_free;

  (* Recursive groups and reifiers rename the same way. *)
  let f1 = Ident.fresh "f" and f2 = Ident.fresh "f" in
  let group =
    Core.letrec ~span:sp
      ~bindings:
        [
          Core.rec_binding ~span:sp ~name:f1
            (Core.lambda ~params:[ x1 ] ~body:(Core.var ~span:sp x1));
          Core.rec_binding ~span:sp ~name:f2
            (Core.lambda ~params:[ x2 ] ~body:(Core.var ~span:sp f1));
        ]
      ~body:(Core.var ~span:sp f2)
  in
  check_string "recursive binders printing alike are renamed apart"
    "(letrec ((f (lam (x) (var x))) (f1 (lam (x) (var f)))) (var f1))"
    (Core_printer.to_string group);
  check_round_trip "recursive group with same-name binders" group;

  let e = Ident.fresh "e" and e2 = Ident.fresh "e" and k = Ident.fresh "k" in
  let reifier =
    Core.reifier ~span:sp ~exp:e ~env:e2 ~cont:k
      ~body:(Core.app ~span:sp ~func:(Core.var ~span:sp k) ~args:[ Core.var ~span:sp e ])
  in
  check_string "reifier parameters printing alike are renamed apart"
    "(reifier (e e1 k) (app (var k) (var e)))" (Core_printer.to_string reifier);
  check_round_trip "reifier with same-name parameters" reifier;

  (* A binder name that cannot be read back is replaced; binders are renamed
     anyway, so nothing is lost. *)
  let awkward = Ident.fresh "not an atom" in
  check_string "an unreadable binder name is replaced" "(lam (v) (var v))"
    (Core_printer.to_string
       (Core.lam ~span:sp ~params:[ awkward ] ~body:(Core.var ~span:sp awkward)));
  check_round_trip "unreadable binder name"
    (Core.lam ~span:sp ~params:[ awkward ] ~body:(Core.var ~span:sp awkward))

(* Free identifiers *)

let test_free_identifiers () =
  let print = Ident.fresh "print" and value = Ident.fresh "value" in
  let open_term =
    Core.app ~span:sp ~func:(Core.var ~span:sp print) ~args:[ Core.var ~span:sp value ]
  in
  check_string "free identifiers print by their own name" "(app (var print) (var value))"
    (Core_printer.to_string open_term);
  check_round_trip "an open term with a reading scope" open_term;
  check "free_scope binds every free name"
    (match Core_reader.scope_find (Core_printer.free_scope open_term) "print" with
    | Some ident -> Ident.equal ident print
    | None -> false);

  (* A term whose free identifiers print alike has no faithful written form: no
     reading scope could tell them apart. Saying so beats printing a lie. *)
  let a = Ident.fresh "a" and a' = Ident.fresh "a" in
  check_raises_invalid_argument "two free identifiers printing alike are refused"
    (fun () ->
      Core_printer.to_string
        (Core.app ~span:sp ~func:(Core.var ~span:sp a) ~args:[ Core.var ~span:sp a' ]));
  check_raises_invalid_argument "an unreadable free name is refused" (fun () ->
      Core_printer.to_string (Core.var ~span:sp (Ident.fresh "not an atom")))

(* Determinism *)

let test_determinism () =
  let term = read "(lam (x) (let y (var x) (app (var y) (var x))))" in
  check_string "printing is repeatable" (Core_printer.to_string term)
    (Core_printer.to_string term);
  (* Alpha-variants print differently, because the printer keeps the names the
     author chose... *)
  check "alpha-variants keep their own names"
    (not
       (String.equal
          (Core_printer.to_string (read "(lam (x) (var x))"))
          (Core_printer.to_string (read "(lam (y) (var y))"))));
  (* ...and identically once those names have been canonicalized away, which is
     what a report or a golden comparison wants. *)
  check_string "canonicalized alpha-variants print identically"
    (Core_printer.to_string (Alpha.canonicalize (read "(lam (x) (var x))")))
    (Core_printer.to_string (Alpha.canonicalize (read "(lam (y) (var y))")));
  check_string "the canonical printed form is positional" "(lam (v) (var v))"
    (Core_printer.to_string (Alpha.canonicalize (read "(lam (x) (var x))")));
  check_string "canonical binders are numbered in first-occurrence order"
    "(lam (v v1) (app (var v1) (var v)))"
    (Core_printer.to_string (Alpha.canonicalize (read "(lam (a b) (app (var b) (var a)))")));

  (* The printed datum carries spans, so a printed term can still be located. *)
  let sexp = Core_printer.to_sexp (read "(lit 1)") in
  check "the printed datum keeps the term's span"
    (Span.equal (Core.span (read "(lit 1)")) sexp.Sexp.span)

let () =
  test_forms ();
  test_renaming ();
  test_free_identifiers ();
  test_determinism ();
  if !failures > 0 then (
    Printf.printf "%d printer assertion(s) failed\n" !failures;
    exit 1)
