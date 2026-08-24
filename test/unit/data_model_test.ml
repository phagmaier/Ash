(* Unit tests for the Core language and runtime value data model (to-do 0.3).

   The acceptance criterion is coverage plus explicit failure: there is a fixture
   for every Core form and every value shape, and every enumeration below is
   asserted to be complete, so adding a variant without extending the fixtures
   fails here rather than silently falling through some default case. *)

open Ash_core

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

let check_raises_invalid_argument name thunk =
  match thunk () with
  | _ ->
      incr failures;
      Printf.printf "FAIL %s\n  expected Invalid_argument, got normal return\n" name
  | exception Invalid_argument _ -> ()

let check_no_raise name thunk =
  match thunk () with
  | _ -> ()
  | exception exn ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected exception: %s\n" name
        (Printexc.to_string exn)

let distinct strings =
  List.length (List.sort_uniq String.compare strings) = List.length strings

(* A single arbitrary source span; Core is what is under test here, not spans. *)
let sp =
  Span.make
    ~start:(Span.position ~file:"fixture.ash" ~line:1 ~column:1 ~offset:0)
    ~stop:(Span.position ~file:"fixture.ash" ~line:1 ~column:2 ~offset:1)

(* One fixture per Core form. *)

let x = Ident.fresh "x"
let y = Ident.fresh "y"
let f = Ident.fresh "f"
let g = Ident.fresh "g"
let e_param = Ident.fresh "e"
let r_param = Ident.fresh "r"
let k_param = Ident.fresh "k"
let one = Core.lit ~span:sp (Constant.Num 1)
let var_x = Core.var ~span:sp x
let named = Core.named_var ~span:sp "x"
let identity = Core.lam ~span:sp ~params:[ x ] ~body:var_x
let call = Core.app ~span:sp ~func:identity ~args:[ one ]
let let_node = Core.let_ ~span:sp ~binder:y ~value:one ~body:(Core.var ~span:sp y)

let letrec_node =
  Core.letrec ~span:sp
    ~bindings:
      [
        Core.rec_binding ~span:sp ~name:f
          (Core.lambda ~params:[ x ] ~body:(Core.app ~span:sp ~func:(Core.var ~span:sp g) ~args:[ var_x ]));
        Core.rec_binding ~span:sp ~name:g
          (Core.lambda ~params:[ y ] ~body:(Core.var ~span:sp y));
      ]
    ~body:(Core.app ~span:sp ~func:(Core.var ~span:sp f) ~args:[ one ])

let if_node =
  Core.if_ ~span:sp ~condition:(Core.lit ~span:sp (Constant.Bool true))
    ~consequent:one ~alternative:(Core.lit ~span:sp (Constant.Num 2))

let set_node = Core.set ~span:sp ~target:x ~value:one
let quote_node = Core.quote ~span:sp call

let reifier_definition =
  Core.reifier_def ~exp:e_param ~env:r_param ~cont:k_param
    ~body:(Core.app ~span:sp ~func:(Core.var ~span:sp k_param) ~args:[ Core.var ~span:sp e_param ])

let reifier_node =
  Core.reifier ~span:sp ~exp:e_param ~env:r_param ~cont:k_param
    ~body:(Core.app ~span:sp ~func:(Core.var ~span:sp k_param) ~args:[ Core.var ~span:sp e_param ])

(* [one] and [var_x] stand in for Lit and Var; every form appears exactly once. *)
let core_fixtures =
  [
    ("lit", one);
    ("var", var_x);
    ("named-var", named);
    ("lam", identity);
    ("app", call);
    ("let", let_node);
    ("letrec", letrec_node);
    ("if", if_node);
    ("set", set_node);
    ("quote", quote_node);
    ("reifier", reifier_node);
  ]

let test_core_coverage () =
  check_int "a fixture exists for every Core form" 11 (List.length core_fixtures);
  check "Core kind names are distinct" (distinct (List.map fst core_fixtures));
  List.iter
    (fun (expected, node) ->
      check_string ("kind_name " ^ expected) expected (Core.kind_name node))
    core_fixtures;
  (* Every fixture is reachable through the exhaustive traversal, so a form whose
     [children] case was forgotten cannot hide behind an empty result. *)
  List.iter
    (fun (name, node) -> check ("node_count is positive for " ^ name) (Core.node_count node > 0))
    core_fixtures

let test_core_structure () =
  check "lit has no children" (Core.children one = []);
  check "var has no children" (Core.children var_x = []);
  check "named-var has no children" (Core.children named = []);
  check_int "lam has one child" 1 (List.length (Core.children identity));
  check_int "app children are func then args" 2 (List.length (Core.children call));
  check_int "let has value and body" 2 (List.length (Core.children let_node));
  check_int "letrec has one child per binding plus the body" 3
    (List.length (Core.children letrec_node));
  check_int "if has three children" 3 (List.length (Core.children if_node));
  check_int "set has one child" 1 (List.length (Core.children set_node));
  check_int "quote has its quoted term as a child" 1
    (List.length (Core.children quote_node));
  check_int "reifier has one child" 1 (List.length (Core.children reifier_node));

  check "lam binds its parameters" (List.equal Ident.equal [ x ] (Core.binders identity));
  check "let binds its binder" (List.equal Ident.equal [ y ] (Core.binders let_node));
  check "letrec binds every name"
    (List.equal Ident.equal [ f; g ] (Core.binders letrec_node));
  check "reifier binds exp, env and cont"
    (List.equal Ident.equal [ e_param; r_param; k_param ] (Core.binders reifier_node));
  check "set binds nothing: it assigns an existing cell"
    (Core.binders set_node = []);
  check "app binds nothing" (Core.binders call = []);
  check "if binds nothing" (Core.binders if_node = []);
  check "quote binds nothing at this level" (Core.binders quote_node = []);
  check "lit binds nothing" (Core.binders one = []);
  check "var binds nothing" (Core.binders var_x = []);
  check "named-var binds nothing" (Core.binders named = []);

  (* node_count reaches quoted subterms: quoted code is program text and the
     collapse report has to be able to size it. *)
  check_int "node_count counts a leaf" 1 (Core.node_count one);
  check_int "node_count counts through a quote"
    (1 + Core.node_count call)
    (Core.node_count quote_node);
  check_int "node_count of the identity call" 4 (Core.node_count call);

  check "reifier_def matches the node it builds"
    (match Core.shape reifier_node with
    | Core.Reifier definition ->
        Ident.equal definition.Core.exp_param reifier_definition.Core.exp_param
        && Ident.equal definition.Core.env_param reifier_definition.Core.env_param
        && Ident.equal definition.Core.cont_param reifier_definition.Core.cont_param
    | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
    | Core.Let _ | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ ->
        false)

let test_core_provenance () =
  check "a fresh node keeps its span" (Span.equal sp (Core.span one));
  let moved = Core.with_span Span.unknown one in
  check "with_span replaces the span" (Span.is_unknown (Core.span moved));
  check "with_span keeps the shape" (String.equal "lit" (Core.kind_name moved));
  let emitted = Core.mark_generated ~by:"stage/let-insert" one in
  check "mark_generated marks the node" (Span.is_generated (Core.span emitted));
  check "mark_generated keeps the origin positions"
    (Span.equal sp (Span.source_span (Core.span emitted)));
  check "mark_generated does not mark subterms"
    (not (Span.is_generated (Core.span (List.hd (Core.children (Core.mark_generated ~by:"p" call))))))

let test_core_contracts () =
  (* Hygiene makes repeated printed names ordinary; repeated identities are not. *)
  let x' = Ident.fresh "x" in
  check_no_raise "same printed name, different binders is legal" (fun () ->
      Core.lam ~span:sp ~params:[ x; x' ] ~body:var_x);
  check_raises_invalid_argument "a lambda rejects a repeated binder" (fun () ->
      Core.lam ~span:sp ~params:[ x; x ] ~body:var_x);
  check_raises_invalid_argument "letrec rejects a repeated binder" (fun () ->
      Core.letrec ~span:sp
        ~bindings:
          [
            Core.rec_binding ~span:sp ~name:f (Core.lambda ~params:[ x ] ~body:var_x);
            Core.rec_binding ~span:sp ~name:f (Core.lambda ~params:[ y ] ~body:var_x);
          ]
        ~body:one);
  check_raises_invalid_argument "a reifier rejects repeated parameters" (fun () ->
      Core.reifier ~span:sp ~exp:e_param ~env:e_param ~cont:k_param ~body:one);
  check_no_raise "an empty application is legal" (fun () ->
      Core.app ~span:sp ~func:identity ~args:[])

(* One fixture per value shape. *)

let closure_value =
  Value.Closure
    {
      Value.clo_lambda = Core.lambda ~params:[ x ] ~body:var_x;
      clo_env = Value.empty_env;
      clo_name = Some f;
    }

let reifier_value =
  Value.Reifier
    { Value.reif_def = reifier_definition; reif_env = Value.empty_env; reif_name = None }

let continuation_fixture = Value.continuation ~capture:sp ~level:0 (fun v -> v)

let cell_fixture = Value.cell (Value.Num 1)

let primitive_fixture =
  {
    Value.prim_name = "+";
    prim_arity = Value.Exactly 2;
    prim_class = Effect_class.Pure;
    prim_impl =
      (fun ~call_site:_ ~level:_ ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
        match args with
        | [ Value.Num a; Value.Num b ] -> k (Value.Num (a + b))
        | _ -> k Value.Unit);
  }

let value_fixtures =
  [
    ("number", Value.Num 1);
    ("boolean", Value.Bool true);
    ("string", Value.Str "hi");
    ("symbol", Value.Sym "zero");
    ("unit", Value.Unit);
    ("list", Value.List [ Value.Num 1; Value.Num 2 ]);
    ("closure", closure_value);
    ("reifier", reifier_value);
    ("continuation", Value.Continuation continuation_fixture);
    ("environment", Value.Environment Value.empty_env);
    ("cell", Value.Cell cell_fixture);
    ("code", Value.Code call);
    ("primitive", Value.Primitive primitive_fixture);
  ]

let test_value_coverage () =
  check_int "a fixture exists for every value shape" 13 (List.length value_fixtures);
  check "value type names are distinct" (distinct (List.map fst value_fixtures));
  List.iter
    (fun (expected, value) ->
      check_string ("type_name " ^ expected) expected (Value.type_name value))
    value_fixtures;
  (* Rendering every shape proves the printer has no missing case, and that no
     shape drags the printer into the cyclic part of the value graph. *)
  List.iter
    (fun (name, value) ->
      check ("to_string is non-empty for " ^ name)
        (String.length (Value.to_string value) > 0))
    value_fixtures

let test_value_printing () =
  check_string "numbers print as constants" "1" (Value.to_string (Value.Num 1));
  check_string "strings print escaped" "\"a\\nb\"" (Value.to_string (Value.Str "a\nb"));
  check_string "symbols print with a tick" "'zero" (Value.to_string (Value.Sym "zero"));
  check_string "unit prints as ()" "()" (Value.to_string Value.Unit);
  check_string "the empty list prints as []" "[]" (Value.to_string (Value.List []));
  check_string "lists print structurally" "[1, 2]"
    (Value.to_string (Value.List [ Value.Num 1; Value.Num 2 ]));
  check_string "named closures print their name" "#<closure f>"
    (Value.to_string closure_value);
  check_string "anonymous reifiers print opaquely" "#<reifier>"
    (Value.to_string reifier_value);
  check_string "code prints its form" "#<code app>" (Value.to_string (Value.Code call));
  check_string "primitives print name and arity" "#<primitive +/2>"
    (Value.to_string (Value.Primitive primitive_fixture));
  check_string "environments print their depth" "#<env 0 frames>"
    (Value.to_string (Value.Environment Value.empty_env))

let test_constant_bridge () =
  let constants =
    [
      Constant.Num 3;
      Constant.Bool false;
      Constant.Str "s";
      Constant.Sym "s";
      Constant.Unit;
      Constant.Nil;
    ]
  in
  List.iter
    (fun constant ->
      let round_tripped = Value.to_constant (Value.of_constant constant) in
      check
        ("constants round-trip through values: " ^ Constant.to_string constant)
        (match round_tripped with
        | Some back -> Constant.equal constant back
        | None -> false))
    constants;
  check "Nil becomes the empty list value"
    (match Value.of_constant Constant.Nil with
    | Value.List [] -> true
    | Value.List (_ :: _) | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _
    | Value.Unit | Value.Closure _ | Value.Reifier _ | Value.Continuation _
    | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
        false);
  (* Values with identity have no constant form: they must be rejected, not
     approximated. *)
  List.iter
    (fun (name, value) ->
      check (name ^ " has no constant form") (Value.to_constant value = None))
    [
      ("a non-empty list", Value.List [ Value.Num 1 ]);
      ("a closure", closure_value);
      ("a reifier", reifier_value);
      ("a continuation", Value.Continuation continuation_fixture);
      ("an environment", Value.Environment Value.empty_env);
      ("a cell", Value.Cell cell_fixture);
      ("code", Value.Code call);
      ("a primitive", Value.Primitive primitive_fixture);
    ]

let test_cells () =
  let filled = Value.cell (Value.Num 1) in
  check "a filled cell is filled" (Value.is_filled filled);
  check "cell contents are readable"
    (match Value.cell_contents filled with
    | Some (Value.Num 1) -> true
    | Some _ | None -> false);
  let empty = Value.preallocated_cell () in
  (* LetRec preallocates; reading before filling must be reportable rather than
     silently yielding some default value. *)
  check "a preallocated cell is not filled" (not (Value.is_filled empty));
  check "a preallocated cell has no contents" (Value.cell_contents empty = None);
  Value.fill_cell empty (Value.Str "filled");
  check "filling makes a cell readable" (Value.is_filled empty);
  check "cells are mutable in place"
    (match Value.cell_contents empty with
    | Some (Value.Str "filled") -> true
    | Some _ | None -> false);
  (* Aliasing is cell identity, not contents equality. *)
  let a = Value.cell (Value.Num 1) and b = Value.cell (Value.Num 1) in
  check "a cell is the same cell as itself" (Value.same_cell a a);
  check "equal contents do not make cells the same" (not (Value.same_cell a b));
  Value.fill_cell a (Value.Num 2);
  check "mutating one cell leaves its twin alone"
    (match Value.cell_contents b with
    | Some (Value.Num 1) -> true
    | Some _ | None -> false)

let test_continuations () =
  let k = Value.continuation ~capture:sp ~level:0 (fun v -> v) in
  check "a fresh continuation is unused" (not (Value.continuation_used k));
  check "a fresh continuation has no first use" (Value.continuation_first_use k = None);
  check "the capture site is retained" (Span.equal sp (Value.continuation_capture_site k));
  let use_site =
    Span.make
      ~start:(Span.position ~file:"fixture.ash" ~line:9 ~column:1 ~offset:80)
      ~stop:(Span.position ~file:"fixture.ash" ~line:9 ~column:4 ~offset:83)
  in
  Value.mark_continuation_used k ~at:use_site;
  check "marking records the use" (Value.continuation_used k);
  check "marking records where"
    (match Value.continuation_first_use k with
    | Some site -> Span.equal use_site site
    | None -> false);
  (* The reuse diagnostic names both sites, so a second attempt must not
     overwrite the evidence of the first. *)
  let second_site = Span.point (Span.position ~file:"other.ash" ~line:2 ~column:1 ~offset:5) in
  Value.mark_continuation_used k ~at:second_site;
  check "a second use does not overwrite the first-use site"
    (match Value.continuation_first_use k with
    | Some site -> Span.equal use_site site
    | None -> false);
  check "printing shows a used continuation" (String.equal "#<continuation used>" (Value.to_string (Value.Continuation k)))

let test_environments () =
  let cell_x = Value.cell (Value.Num 1) and cell_y = Value.cell (Value.Num 2) in
  let outer = Value.frame_of_list [ (x, cell_x) ] in
  let inner = Value.frame_of_list [ (y, cell_y) ] in
  let env = Value.push_frame inner (Value.push_frame outer Value.empty_env) in
  check_int "the empty environment has no frames" 0 (List.length Value.empty_env);
  check_int "pushing frames grows the chain" 2 (List.length env);
  check "the innermost frame is first"
    (match env with
    | frame :: _ -> Ident.Map.mem y frame.Value.bindings
    | [] -> false);
  check "frames map identifiers to the very cells they were built from"
    (match env with
    | _ :: frame :: _ -> Value.same_cell cell_x (Ident.Map.find x frame.Value.bindings)
    | [] | [ _ ] -> false)

let test_primitives () =
  check "Exactly matches its arity" (Value.arity_matches (Value.Exactly 2) 2);
  check "Exactly rejects other arities" (not (Value.arity_matches (Value.Exactly 2) 3));
  check "At_least accepts its minimum" (Value.arity_matches (Value.At_least 1) 1);
  check "At_least accepts more" (Value.arity_matches (Value.At_least 1) 4);
  check "At_least rejects fewer" (not (Value.arity_matches (Value.At_least 1) 0));
  check_string "Exactly prints as a number" "2" (Value.arity_to_string (Value.Exactly 2));
  check_string "At_least prints its bound" "at least 1"
    (Value.arity_to_string (Value.At_least 1));
  (* A primitive is CPS so that control primitives need no evaluator special
     case: applying one delivers its result to the continuation. *)
  let result =
    primitive_fixture.Value.prim_impl ~call_site:sp ~level:0
      ~apply:(fun ~call_site:_ _ _ _ -> Value.Unit)
      ~lift:(fun ~call_site:_ _ -> one)
      ~run:(fun ~call_site:_ _ _ -> Value.Unit)
      ~reflect:(fun ~call_site:_ ~code:_ ~env:_ ~cont:_ _ -> Value.Unit)
      ~meta:(fun ~call_site:_ _ -> Value.Unit)
      [ Value.Num 2; Value.Num 3 ]
      (fun v -> v)
  in
  check "a primitive delivers its result to the continuation"
    (match result with Value.Num 5 -> true | _ -> false)

let test_effect_classes () =
  check_int "every effect class is enumerated" 5 (List.length Effect_class.all);
  check "effect class names are distinct"
    (distinct (List.map Effect_class.name Effect_class.all));
  check_string "the allocation class is named for both halves" "allocation/mutation"
    (Effect_class.name Effect_class.Allocation_or_mutation);
  (* D7: static arguments justify folding only for pure primitives, and no
     argument knowledge ever justifies running an observable effect early. *)
  check "only pure primitives fold when static"
    (List.filter Effect_class.may_fold_when_static Effect_class.all
    = [ Effect_class.Pure ]);
  check "only observable effects always residualize"
    (List.filter Effect_class.always_residualizes Effect_class.all
    = [ Effect_class.Observable_effect ]);
  check "classes compare equal to themselves"
    (List.for_all (fun c -> Effect_class.equal c c && Effect_class.compare c c = 0)
       Effect_class.all);
  check "distinct classes are unequal"
    (not (Effect_class.equal Effect_class.Pure Effect_class.Control))

let () =
  test_core_coverage ();
  test_core_structure ();
  test_core_provenance ();
  test_core_contracts ();
  test_value_coverage ();
  test_value_printing ();
  test_constant_bridge ();
  test_cells ();
  test_continuations ();
  test_environments ();
  test_primitives ();
  test_effect_classes ();
  if !failures > 0 then (
    Printf.printf "%d data-model assertion(s) failed\n" !failures;
    exit 1)
