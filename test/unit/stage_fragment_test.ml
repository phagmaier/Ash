(* Staging the pure fragment: higher-order Core, recursion, and immutable data
   (to-do task 5.3, spec §7.4 step 1).

   The acceptance shape is one comparison repeated: stage a source program whose
   result still depends on values the specializer does not know, then run the
   residual on concrete arguments and require the same answer the source gives
   on the same arguments.  A residual that merely looks small proves nothing;
   these tests always execute it. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_stage

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "stage_fragment_test.ash"

let ground () =
  let registry = Primitives.create () in
  let globals = Primitives.globals registry in
  let named = List.map (fun (ident, _) -> (Ident.name ident, ident)) globals in
  let scope = Core_reader.scope_of_list named in
  let env = Env.extend globals Value.empty_env in
  (registry, scope, env)

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

(* Calls to a named global surviving in the residual.  Residual calls carry the
   level's own hygienic binding for the primitive, so matching on the printed
   name of the callee identifies them without depending on allocation order. *)
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

let residual_of ~env source = Staged_eval.fold ~env source

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

(* Stage [source_text], apply the residual and the source to the same argument
   terms, and require the same outcome.  [inspect] additionally states what the
   residual may still contain. *)
let check_residual ?(inspect = fun _ -> ()) name ~args source_text =
  let _, scope, env = ground () in
  let source = read_with scope source_text in
  let expected = outcome ~env (apply_at scope source args) in
  match residual_of ~env source with
  | exception Error.Ash_error error ->
      (* A pure computation the program certainly reaches may fail at stage time.
         That is only correct when the source fails the same way. *)
      let staged = Error (Error.to_string error) in
      if not (same_outcome expected staged) then (
        incr failures;
        Printf.printf "FAIL %s\n  source:   %s\n  staging:  %s\n" name
          (describe expected) (describe staged))
  | residual ->
      let open_names =
        Code.unresolved_dependencies ~available:(Env.idents env) residual
      in
      if open_names <> [] then (
        incr failures;
        Printf.printf "FAIL %s\n  residual is open in: %s\n" name
          (String.concat ", "
             (List.map (fun d -> Ident.name d.Code.ident) open_names)));
      let actual = outcome ~env (apply_at scope residual args) in
      if not (same_outcome expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  source:   %s\n  residual: %s\n  residual Core: %s\n"
          name (describe expected) (describe actual)
          (Core_printer.to_string residual))
      else inspect residual

let check_residual_value ?inspect name source_text =
  check_residual ?inspect name ~args:[] source_text

(* {1 Higher-order Core} *)

let inc = "(lam (y) (app (var +) (var y) (lit 1)))"
let dbl = "(lam (y) (app (var *) (var y) (lit 2)))"

let test_higher_order () =
  (* A static function argument disappears into the residual: the specializer
     applies it, it is not passed. *)
  check_residual "a static function argument is applied away" ~args:[ "(lit 5)" ]
    ~inspect:(fun residual ->
      check "twice residualizes only its arithmetic"
        (calls_to ~name:"+" residual = 2))
    (Printf.sprintf
       "(let twice (lam (f v) (app (var f) (app (var f) (var v))))\n\
       \  (lam (x) (app (var twice) %s (var x))))" inc);

  (* A closure reaching a position the specializer cannot see into is not an
     error: its lambda is reified and its body specialized. *)
  check_residual "a closure crossing into a dynamic call"
    ~args:[ "(lam (f) (app (var f) (lit 21)))" ]
    (Printf.sprintf "(lam (g) (app (var g) %s))" dbl);

  (* Reifying one closure twice must keep two independent binding structures. *)
  check_residual "the same closure reified twice"
    ~args:[ "(lam (p q) (app (var +) (app (var p) (lit 1)) (app (var q) (lit 10))))" ]
    (Printf.sprintf "(lam (g) (let f %s (app (var g) (var f) (var f))))" inc);

  (* Both branches of a dynamic conditional produce closures; the application of
     the unknown result residualizes. *)
  let branching =
    Printf.sprintf "(lam (b x) (app (if (var b) %s %s) (var x)))" inc dbl
  in
  check_residual "a closure chosen by a dynamic branch, true"
    ~args:[ "(lit #t)"; "(lit 5)" ] branching;
  check_residual "a closure chosen by a dynamic branch, false"
    ~args:[ "(lit #f)"; "(lit 5)" ] branching;

  (* A closure that captured a dynamic value stays applicable at stage time. *)
  check_residual "a curried closure capturing a dynamic value" ~args:[ "(lit 4)" ]
    ~inspect:(fun residual ->
      check "the curried lambda is gone" (calls_to ~name:"+" residual = 1))
    "(lam (x)\n\
    \  (let adder (lam (n) (lam (m) (app (var +) (var n) (var m))))\n\
    \    (app (app (var adder) (var x)) (lit 5))))";

  (* A higher-order fold over a spine the specializer knows unrolls completely,
     even though every element it folds over is dynamic. *)
  check_residual "a higher-order fold over a static spine" ~args:[ "(lit 4)" ]
    ~inspect:(fun residual ->
      check "the fold's own recursion is gone"
        (calls_to ~name:"empty?" residual = 0
        && calls_to ~name:"head" residual = 0
        && calls_to ~name:"tail" residual = 0))
    "(letrec ((fold (lam (f acc xs)\n\
    \                 (if (app (var empty?) (var xs))\n\
    \                     (var acc)\n\
    \                     (app (var fold) (var f)\n\
    \                          (app (var f) (var acc) (app (var head) (var xs)))\n\
    \                          (app (var tail) (var xs)))))))\n\
    \  (lam (x) (app (var fold) (lam (a b) (app (var +) (var a) (var b))) (lit 0)\n\
    \                (app (var list) (var x) (lit 2) (var x)))))"

(* {1 Recursion} *)

let power =
  "(letrec ((power (lam (n x)\n\
  \                  (if (app (var ==) (var n) (lit 0))\n\
  \                      (lit 1)\n\
  \                      (app (var *) (var x)\n\
  \                           (app (var power) (app (var -) (var n) (lit 1)) (var x)))))))\n\
  \  (lam (x) (app (var power) (lit 3) (var x))))"

let test_recursion () =
  (* Recursion controlled by static data unrolls; the dynamic base survives. *)
  check_residual "static-exponent power" ~args:[ "(lit 2)" ]
    ~inspect:(fun residual ->
      check "power's control flow is gone"
        (calls_to ~name:"==" residual = 0 && calls_to ~name:"-" residual = 0);
      check "three multiplications survive" (calls_to ~name:"*" residual = 3))
    power;

  (* Mutual recursion is static control like any other. *)
  check_residual "mutual recursion decides a static branch" ~args:[ "(lit 7)" ]
    ~inspect:(fun residual ->
      check "no residual comparison" (calls_to ~name:"==" residual = 0))
    "(letrec ((even? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #t)\n\
    \                            (app (var odd?) (app (var -) (var n) (lit 1))))))\n\
    \         (odd? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #f)\n\
    \                           (app (var even?) (app (var -) (var n) (lit 1)))))))\n\
    \  (lam (x) (if (app (var even?) (lit 10)) (var x) (app (var +) (var x) (lit 1)))))";

  (* Recursion over a list whose spine is static and whose elements are not. *)
  check_residual "a recursive map over a static spine" ~args:[ "(lit 5)" ]
    ~inspect:(fun residual ->
      check "the traversal is gone"
        (calls_to ~name:"empty?" residual = 0
        && calls_to ~name:"head" residual = 0
        && calls_to ~name:"tail" residual = 0
        && calls_to ~name:"cons" residual = 0))
    "(letrec ((mapinc (lam (l)\n\
    \                   (if (app (var empty?) (var l))\n\
    \                       (lit nil)\n\
    \                       (app (var cons) (app (var +) (app (var head) (var l)) (lit 1))\n\
    \                            (app (var mapinc) (app (var tail) (var l))))))))\n\
    \  (lam (x) (app (var mapinc) (app (var list) (var x) (lit 7)))))";

  check_residual "append written recursively over static spines"
    ~args:[ "(lit 1)"; "(lit 2)" ]
    ~inspect:(fun residual ->
      check "append is fully unrolled" (calls_to ~name:"empty?" residual = 0))
    "(letrec ((append (lam (xs ys)\n\
    \                   (if (app (var empty?) (var xs))\n\
    \                       (var ys)\n\
    \                       (app (var cons) (app (var head) (var xs))\n\
    \                            (app (var append) (app (var tail) (var xs)) (var ys)))))))\n\
    \  (lam (a b) (app (var append) (app (var list) (var a) (lit 9)) (app (var list) (var b)))))";

  check_residual "reverse with an accumulator over a static spine"
    ~args:[ "(lit 1)"; "(lit 2)" ]
    "(letrec ((rev (lam (xs acc)\n\
    \                (if (app (var empty?) (var xs))\n\
    \                    (var acc)\n\
    \                    (app (var rev) (app (var tail) (var xs))\n\
    \                         (app (var cons) (app (var head) (var xs)) (var acc)))))))\n\
    \  (lam (a b) (app (var rev) (app (var list) (var a) (var b) (lit 3)) (lit nil))))"

(* {1 Immutable data} *)

let test_immutable_data () =
  (* The spine is known even though the element is not, so both list operations
     disappear and the residual is the identity. *)
  check_residual "head of a cons of a dynamic value" ~args:[ "(lit 3)" ]
    ~inspect:(fun residual ->
      check "no list operation survives"
        (calls_to ~name:"cons" residual = 0 && calls_to ~name:"head" residual = 0))
    "(lam (x) (app (var head) (app (var cons) (var x) (lit nil))))";

  check_residual "length counts a spine of dynamic elements" ~args:[ "(lit 3)" ]
    ~inspect:(fun residual ->
      check "length is folded" (calls_to ~name:"length" residual = 0))
    "(lam (x) (app (var length) (app (var list) (var x) (var x) (var x))))";

  check_residual "nested partially static data" ~args:[ "(lit 8)" ]
    ~inspect:(fun residual ->
      check "both selections fold" (calls_to ~name:"head" residual = 0))
    "(lam (x) (app (var head) (app (var head) (app (var list) (app (var list) (var x))))))";

  (* A list the specializer holds must reach the residual program as a list. *)
  check_residual "a partially static list returned to the residual"
    ~args:[ "(lit 4)" ]
    "(lam (x) (app (var head) (app (var tail) (app (var list) (lit 1) (app (var +) (var x) (lit 1))))))";

  (* A list carrying a closure crosses a dynamic boundary by reifying both the
     spine and the closure inside it. *)
  check_residual "a static spine carrying a closure crosses a boundary"
    ~args:[ "(lam (p) (app (app (var head) (var p)) (app (var head) (app (var tail) (var p)))))" ]
    (Printf.sprintf
       "(lam (g) (app (var g) (app (var list) %s (lit 3))))" inc);

  (* The other half of the policy: a primitive that inspects element values must
     not fold merely because the spine is known. *)
  let equal_lists =
    "(lam (x) (app (var ==) (app (var list) (var x)) (app (var list) (lit 1))))"
  in
  check_residual "structural equality over dynamic elements does not fold, equal"
    ~args:[ "(lit 1)" ]
    ~inspect:(fun residual ->
      check "the comparison survives" (calls_to ~name:"==" residual = 1))
    equal_lists;
  check_residual "structural equality over dynamic elements does not fold, unequal"
    ~args:[ "(lit 2)" ] equal_lists;

  let is_list = "(lam (x) (app (var list?) (var x)))" in
  check_residual "list? of an unknown value does not fold, list"
    ~args:[ "(app (var list) (lit 1))" ]
    ~inspect:(fun residual ->
      check "the type test survives" (calls_to ~name:"list?" residual = 1))
    is_list;
  check_residual "list? of an unknown value does not fold, number"
    ~args:[ "(lit 1)" ] is_list;

  check_residual "length of an unknown list does not fold"
    ~args:[ "(app (var list) (lit 1) (lit 2))" ]
    ~inspect:(fun residual ->
      check "the traversal survives" (calls_to ~name:"length" residual = 1))
    "(lam (l) (app (var length) (var l)))";

  (* An error the source program certainly reaches is reported at stage time in
     the same way the ground evaluator reports it. *)
  check_residual_value "head of the empty list still fails"
    "(app (var head) (lit nil))"

(* {1 The fold policy itself} *)

let test_fold_policy () =
  let registry, _scope, _env = ground () in
  let primitive name =
    match Primitives.find registry name with
    | Some primitive -> primitive
    | None -> failwith ("no primitive named " ^ name)
  in
  let dummy = Span.point (Span.position ~file ~line:1 ~column:1 ~offset:0) in
  let dynamic = Value.Code (Core.var ~span:dummy (Ident.fresh "x")) in
  let static = Value.Num 1 in
  let spine = Value.List [ dynamic; static ] in

  check "cons does not observe what it conses"
    (Stage_value.may_fold (primitive "cons") [ dynamic; Value.List [] ]);
  check "cons observes the shape of its tail"
    (not (Stage_value.may_fold (primitive "cons") [ static; dynamic ]));
  check "head observes only the spine"
    (Stage_value.may_fold (primitive "head") [ spine ]);
  check "head needs a known spine"
    (not (Stage_value.may_fold (primitive "head") [ dynamic ]));
  check "length observes only the spine"
    (Stage_value.may_fold (primitive "length") [ spine ]);
  check "list observes nothing"
    (Stage_value.may_fold (primitive "list") [ dynamic; dynamic ]);
  check "list? needs a known constructor"
    (not (Stage_value.may_fold (primitive "list?") [ dynamic ]));
  check "equality observes element values"
    (not (Stage_value.may_fold (primitive "==") [ spine; spine ]));
  check "arithmetic observes its arguments"
    (not (Stage_value.may_fold (primitive "+") [ static; dynamic ]));
  check "arithmetic folds on known arguments"
    (Stage_value.may_fold (primitive "+") [ static; static ]);
  (* Class still dominates: no argument knowledge makes an effect foldable. *)
  check "an observable effect never folds"
    (not (Stage_value.may_fold (primitive "print") [ static ]));
  check "a store operation never folds"
    (not (Stage_value.may_fold (primitive "cell_new") [ static ]));

  check "a shape-static list may carry dynamic elements"
    (Stage_value.is_shape_static spine);
  check "dynamic code is not shape-static"
    (not (Stage_value.is_shape_static dynamic));
  check "a list of dynamic elements is not purely static"
    (not (Stage_value.is_purely_static spine))

let () =
  test_higher_order ();
  test_recursion ();
  test_immutable_data ();
  test_fold_policy ();
  if !failures > 0 then (
    Printf.printf "%d pure-fragment staging assertion(s) failed\n" !failures;
    exit 1)
