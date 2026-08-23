(* Unit tests for the canonical Core s-expression reader (to-do task 0.5). *)

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

let check_int name expected actual =
  if not (Int.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %d\n  actual:   %d\n" name expected actual)

(* Every failure case is checked through the structured cause and the rendered
   location, so a malformed form is required to say both what and where. *)
let check_read_error name ~cause ~location source =
  match Core_reader.read ~file:"t.ash" source with
  | (_ : Core.t) ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an error, read successfully\n" name
  | exception Error.Ash_error error ->
      if not (Error.cause_equal error.Error.cause cause) then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong cause: %s\n" name (Error.to_string error));
      if not (String.equal location (Span.to_string error.Error.span)) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected location: %s\n  actual location:   %s\n" name
          location
          (Span.to_string error.Error.span))

(* The canonical spelling of every Core form. *)
let canonical =
  [
    ("lit", "(lit 42)");
    ("var", "(let x (lit 1) (var x))");
    ("named-var", "(named-var \"x\")");
    ("lam", "(lam (x y) (var x))");
    ("app", "(app (lam (x) (var x)) (lit 1))");
    ("let", "(let x (lit 1) (var x))");
    ("letrec", "(letrec ((f (lam (n) (app (var f) (var n))))) (var f))");
    ("if", "(if (lit #t) (lit 1) (lit 2))");
    ("set", "(lam (x) (set x (lit 1)))");
    ("quote", "(quote (lit 1))");
    ("reifier", "(reifier (e r k) (app (var k) (var e)))");
  ]

(* S-expression layer *)

let test_sexp_round_trip () =
  (* Every form's canonical text survives read-then-write unchanged, so the
     notation has exactly one spelling per term. *)
  List.iter
    (fun (name, text) ->
      check_string ("the canonical " ^ name ^ " form round-trips") text
        (Sexp.to_string (Sexp.one_of_string ~file:"t.ash" text)))
    canonical;
  List.iter
    (fun text ->
      check_string ("datum round-trips: " ^ text) text
        (Sexp.to_string (Sexp.one_of_string ~file:"t.ash" text)))
    [
      "42";
      "-7";
      "#t";
      "#f";
      "\"hi\"";
      "\"a\\nb\\\"c\\\\d\"";
      "'zero";
      "unit";
      "nil";
      "+";
      "()";
      "(a (b c) 1 \"s\" 'q)";
    ];
  check_string "escapes decode before they re-encode" "a\tb"
    (match (Sexp.one_of_string "\"a\\x09b\"").Sexp.datum with
    | Sexp.Str s -> s
    | Sexp.Int _ | Sexp.Bool _ | Sexp.Sym _ | Sexp.Atom _ | Sexp.List _ -> "")

let test_sexp_lexing () =
  check_int "comments and whitespace are skipped" 2
    (List.length (Sexp.of_string "; a comment\n1 ; trailing\n 2\n"));
  check_int "read_all reads every term" 2
    (List.length (Core_reader.read_all ~file:"t.ash" "(lit 1) (lit 2)"));
  check "a bare atom is an identifier"
    (match (Sexp.one_of_string "lam").Sexp.datum with
    | Sexp.Atom "lam" -> true
    | Sexp.Atom _ | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.List _ -> false);
  check "a negative integer is an integer"
    (match (Sexp.one_of_string "-7").Sexp.datum with
    | Sexp.Int (-7) -> true
    | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.Atom _ | Sexp.List _ -> false);
  check "a lone minus is still an identifier"
    (match (Sexp.one_of_string "-").Sexp.datum with
    | Sexp.Atom "-" -> true
    | Sexp.Atom _ | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.List _ -> false);

  (* Spans locate a datum exactly, including across lines. *)
  check_string "a datum span covers exactly its text" "t.ash:1:6-13"
    (match (Sexp.one_of_string ~file:"t.ash" "(lit (a b c)) ").Sexp.datum with
    | Sexp.List [ _; inner ] -> Span.to_string inner.Sexp.span
    | Sexp.List _ | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.Atom _ -> "?");
  check_string "line tracking survives newlines" "t.ash:2:3-4"
    (match (Sexp.one_of_string ~file:"t.ash" "(a\n  b)").Sexp.datum with
    | Sexp.List [ _; inner ] -> Span.to_string inner.Sexp.span
    | Sexp.List _ | Sexp.Int _ | Sexp.Bool _ | Sexp.Str _ | Sexp.Sym _ | Sexp.Atom _ -> "?")

(* Reading Core *)

let read text = Core_reader.read ~file:"t.ash" text

let test_forms () =
  List.iter
    (fun (name, text) ->
      let node = read text in
      let outermost = match name with "var" | "set" -> None | _ -> Some name in
      match outermost with
      | Some expected -> check_string ("reading a " ^ name ^ " form") expected (Core.kind_name node)
      | None -> check ("reading a " ^ name ^ " form succeeds") (Core.node_count node > 0))
    canonical;

  check "every literal shape reads"
    (List.for_all
       (fun (text, expected) ->
         match Core.shape (read text) with
         | Core.Lit constant -> Constant.equal constant expected
         | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
         | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
             false)
       [
         ("(lit 42)", Constant.Num 42);
         ("(lit -1)", Constant.Num (-1));
         ("(lit #t)", Constant.Bool true);
         ("(lit #f)", Constant.Bool false);
         ("(lit \"s\")", Constant.Str "s");
         ("(lit 'zero)", Constant.Sym "zero");
         ("(lit unit)", Constant.Unit);
         ("(lit nil)", Constant.Nil);
       ]);
  check "a named variable keeps its string"
    (match Core.shape (read "(named-var \"x\")") with
    | Core.NamedVar "x" -> true
    | Core.NamedVar _ | Core.Lit _ | Core.Var _ | Core.Lam _ | Core.App _ | Core.Let _
    | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
        false);
  check_int "an application keeps every argument" 3
    (match Core.shape (read "(lam (f) (app (var f) (lit 1) (lit 2) (lit 3)))") with
    | Core.Lam { Core.lam_body; _ } -> (
        match Core.shape lam_body with
        | Core.App { Core.args; _ } -> List.length args
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.Let _
        | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            -1)
    | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.App _ | Core.Let _
    | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
        -1);
  check_int "a nullary application is legal" 0
    (match Core.shape (read "(lam (f) (app (var f)))") with
    | Core.Lam { Core.lam_body; _ } -> (
        match Core.shape lam_body with
        | Core.App { Core.args; _ } -> List.length args
        | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.Let _
        | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
            -1)
    | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.App _ | Core.Let _
    | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
        -1)

(* Names resolve to identities, not to strings. *)

let body_of_lam node =
  match Core.shape node with
  | Core.Lam { Core.lam_body; _ } -> lam_body
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.App _ | Core.Let _ | Core.LetRec _
  | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
      node

let var_ident node =
  match Core.shape node with
  | Core.Var ident -> Some ident
  | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _ | Core.LetRec _
  | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
      None

let same_ident label a b =
  check label (match (a, b) with Some x, Some y -> Ident.equal x y | _ -> false)

let test_binding () =
  let identity = read "(lam (x) (var x))" in
  let binder = List.nth_opt (Core.binders identity) 0 in
  same_ident "a body variable resolves to its own binder" binder
    (var_ident (body_of_lam identity));

  (* Reading the same text twice must not produce the same binder: identities
     come from the reader, so two reads are alpha-equivalent, not equal. *)
  let again = read "(lam (x) (var x))" in
  check "two reads allocate different binders"
    (match (binder, List.nth_opt (Core.binders again) 0) with
    | Some a, Some b -> not (Ident.equal a b)
    | _ -> false);

  (* Shadowing is by identity: the inner binding wins, and the outer one is a
     different term even though both print as x. *)
  let shadowing = read "(let x (lit 1) (let x (lit 2) (var x)))" in
  let outer_binder = List.nth_opt (Core.binders shadowing) 0 in
  let inner =
    match Core.shape shadowing with
    | Core.Let { Core.let_body; _ } -> let_body
    | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
    | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
        shadowing
  in
  let inner_binder = List.nth_opt (Core.binders inner) 0 in
  let use =
    match Core.shape inner with
    | Core.Let { Core.let_body; _ } -> var_ident let_body
    | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
    | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
        None
  in
  same_ident "the innermost binding wins" inner_binder use;
  check "the shadowed binder is a different identity"
    (match (outer_binder, inner_binder) with
    | Some a, Some b -> (not (Ident.equal a b)) && Ident.same_name a b
    | _ -> false);

  (* A let does not see its own binding, which is what separates it from letrec. *)
  check_read_error "a let value cannot refer to its own binder"
    ~cause:(Error.Unbound_name "x") ~location:"t.ash:1:13-14"
    "(let x (var x) (lit 1))";

  (* Quoted code is read in the enclosing scope, so a quoted variable keeps the
     binder ID of the binding it was written under (spec D1). *)
  let quoted = read "(lam (x) (quote (var x)))" in
  let quoted_use =
    match Core.shape (body_of_lam quoted) with
    | Core.Quote inner -> var_ident inner
    | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
    | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Reifier _ ->
        None
  in
  same_ident "a quoted variable keeps its enclosing binder"
    (List.nth_opt (Core.binders quoted) 0)
    quoted_use;

  (* Every name in a recursive group is in scope for every lambda in it. *)
  let group =
    read "(letrec ((f (lam (n) (app (var g) (var n)))) (g (lam (n) (app (var f) (var n))))) (var f))"
  in
  check_int "a recursive group binds every name" 2 (List.length (Core.binders group));
  check "a sibling in the group is visible" (Core.node_count group > 0);

  (* A supplied scope is how open terms are read: there is no other way to give
     a free name an identity. *)
  let global = Ident.fresh "print" in
  let scope = Core_reader.scope_of_list [ ("print", global) ] in
  same_ident "a supplied scope resolves a free name" (Some global)
    (var_ident (Core_reader.read ~scope ~file:"t.ash" "(var print)"));
  check "scope_find reports what a scope holds"
    (match Core_reader.scope_find scope "print" with
    | Some ident -> Ident.equal ident global
    | None -> false);
  check "an empty scope holds nothing"
    (Core_reader.scope_find Core_reader.empty_scope "print" = None);

  (* Assignment never binds, so its target must already be in scope. *)
  let assignment = read "(lam (x) (set x (lit 1)))" in
  check "set targets the enclosing binder"
    (match Core.shape (body_of_lam assignment) with
    | Core.Set { Core.set_target; _ } -> (
        match List.nth_opt (Core.binders assignment) 0 with
        | Some binder -> Ident.equal binder set_target
        | None -> false)
    | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
    | Core.LetRec _ | Core.If _ | Core.Quote _ | Core.Reifier _ ->
        false)

(* Spans survive into Core *)

let test_spans () =
  let node = read "(app (lam (x) (var x)) (lit 1))" in
  check_string "a Core node keeps the span of its whole form" "t.ash:1:1-32"
    (Span.to_string (Core.span node));
  check_string "a subterm keeps its own span" "t.ash:1:24-31"
    (match Core.children node with
    | [ _; argument ] -> Span.to_string (Core.span argument)
    | _ -> "?");
  check "a read node is not marked generated" (not (Span.is_generated (Core.span node)));
  check_string "spans carry the file they were read from" "t.ash" (Span.file (Core.span node))

(* Malformed input identifies its location *)

let test_diagnostics () =
  check_read_error "an unknown head is reported at the head"
    ~cause:(Error.Unknown_form "lambda") ~location:"t.ash:1:2-8" "(lambda (x) (var x))";
  check_read_error "a wrong-arity form is reported at the form"
    ~cause:(Error.Malformed_form { form = "if"; expected = "(if <condition> <consequent> <alternative>)" })
    ~location:"t.ash:1:1-22" "(if (lit #t) (lit 1))";
  check_read_error "an unreadable literal is reported at the literal"
    ~cause:
      (Error.Malformed_form
         { form = "lit"; expected = "(lit <number | #t | #f | string | 'symbol | unit | nil>)" })
    ~location:"t.ash:1:6-9" "(lit foo)";
  check_read_error "a duplicate binder is reported at the repeat"
    ~cause:(Error.Duplicate_binder "x") ~location:"t.ash:1:9-10" "(lam (x x) (lit 1))";
  check_read_error "a free variable is reported where it is used"
    ~cause:(Error.Unbound_name "y") ~location:"t.ash:2:8-9" "(let x (lit 1)\n  (var y))";
  check_read_error "assigning an unbound name is reported"
    ~cause:(Error.Unbound_name "x") ~location:"t.ash:1:6-7" "(set x (lit 1))";
  check_read_error "a reifier with the wrong parameter count is reported"
    ~cause:
      (Error.Malformed_form { form = "reifier"; expected = "(reifier (<exp> <env> <cont>) <body>)" })
    ~location:"t.ash:1:1-24" "(reifier (e r) (var e))";
  check_read_error "a recursive binding that is not a lambda is reported"
    ~cause:(Error.Malformed_form { form = "lam"; expected = "(lam (<param> ...) <body>)" })
    ~location:"t.ash:1:13-20" "(letrec ((f (lit 1))) (var f))";
  check_read_error "a bare datum is not a Core form"
    ~cause:(Error.Unexpected { found = "an integer"; expected = "a Core form" })
    ~location:"t.ash:1:1-3" "42";
  check_read_error "a non-name binder is reported"
    ~cause:(Error.Unexpected { found = "an integer"; expected = "a name" })
    ~location:"t.ash:1:7-8" "(lam (1) (lit 1))";

  (* Lexical failures locate themselves too. *)
  check_read_error "an unterminated list is reported"
    ~cause:(Error.Unterminated "list") ~location:"t.ash:1:1-8" "(lit 1 ";
  check_read_error "an unterminated string is reported"
    ~cause:(Error.Unterminated "string literal") ~location:"t.ash:1:12-16" "(named-var \"ab)";
  check_read_error "a stray close paren is reported"
    ~cause:(Error.Unexpected { found = "`)`"; expected = "a datum" })
    ~location:"t.ash:1:1-2" ")";
  check_read_error "an unknown hash token is reported"
    ~cause:(Error.Unexpected { found = "`#x`"; expected = "`#t` or `#f`" })
    ~location:"t.ash:1:6-8" "(lit #x)";
  check_read_error "a bad string escape is reported"
    ~cause:(Error.Unexpected { found = "`\\q`"; expected = "a string escape" })
    ~location:"t.ash:1:14-16" "(named-var \"a\\q\")";
  check_read_error "a control character is reported"
    ~cause:(Error.Unexpected_character '\001') ~location:"t.ash:1:6-7" "(lit \001)";
  check_read_error "empty input is reported"
    ~cause:(Error.Unexpected { found = "end of input"; expected = "a datum" })
    ~location:"t.ash:1:1" "   ";
  check_read_error "trailing input is reported"
    ~cause:(Error.Unexpected { found = "an integer"; expected = "end of input" })
    ~location:"t.ash:1:9-11" "(lit 1) 42";

  (* Every reader diagnostic belongs to the read or lex phase and to no level. *)
  List.iter
    (fun source ->
      match Core_reader.read ~file:"t.ash" source with
      | (_ : Core.t) -> ()
      | exception Error.Ash_error error ->
          check "a reader error belongs to no tower level" (error.Error.level = None);
          check "a reader error names a syntactic phase"
            (error.Error.phase = Error.Read || error.Error.phase = Error.Lex))
    [ "(lambda (x) (var x))"; "(lit 1"; "42"; "(var nope)" ]

let () =
  test_sexp_round_trip ();
  test_sexp_lexing ();
  test_forms ();
  test_binding ();
  test_spans ();
  test_diagnostics ();
  if !failures > 0 then (
    Printf.printf "%d reader assertion(s) failed\n" !failures;
    exit 1)
