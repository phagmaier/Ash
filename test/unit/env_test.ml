(* Unit tests for explicit environments and cells (to-do task 0.4). *)

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

(* Every error path is checked through the structured error, not its rendering,
   so a message reword cannot silently change what was reported. *)
let check_error name ~expect thunk =
  match thunk () with
  | _ ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an Ash error, got normal return\n" name
  | exception Error.Ash_error error ->
      if not (expect error) then (
        incr failures;
        Printf.printf "FAIL %s\n  unexpected error: %s\n" name
          (Error.to_string_debug error))

let span_at line column =
  let position = Span.position ~file:"env.ash" ~line ~column ~offset:((line * 80) + column) in
  Span.make ~start:position
    ~stop:(Span.position ~file:"env.ash" ~line ~column:(column + 1) ~offset:((line * 80) + column + 1))

let use = span_at 3 5

let is_num expected = function
  | Some (Value.Num n) -> Int.equal n expected
  | Some _ | None -> false

let bound_num expected = function
  | Env.Bound (Value.Num n) -> Int.equal n expected
  | Env.Bound _ | Env.Unbound | Env.Unfilled -> false

(* Shadowing *)

let test_shadowing () =
  let outer_x = Ident.fresh "x" in
  let inner_x = Ident.fresh "x" in
  let env = Env.bind outer_x (Value.Num 1) Value.empty_env in
  let shadowed = Env.bind inner_x (Value.Num 2) env in

  (* Identity, not name: both bindings exist at once and each resolves to its
     own cell even though they print alike. *)
  check "the outer binding is still reachable by identity"
    (bound_num 1 (Env.state shadowed outer_x));
  check "the inner binding resolves to its own value"
    (bound_num 2 (Env.state shadowed inner_x));
  check "the shadowing frame did not disturb the original environment"
    (bound_num 1 (Env.state env outer_x));
  check "the inner binding is invisible in the enclosing environment"
    (Env.state env inner_x = Env.Unbound);
  check_int "each binding pushed one frame" 2 (Env.depth shadowed);
  check_int "the enclosing chain is unchanged" 1 (Env.depth env);
  check_int "both identifiers are bound in the chain" 2
    (Ident.Set.cardinal (Env.idents shadowed));

  (* Shadowing within one frame is impossible by identity, and a repeated
     identity would silently drop a binding rather than shadow it. *)
  check_raises_invalid_argument "extend rejects a repeated binder identity" (fun () ->
      Env.extend [ (outer_x, Value.Num 1); (outer_x, Value.Num 2) ] Value.empty_env);
  check_raises_invalid_argument "preallocate rejects a repeated binder identity"
    (fun () -> Env.preallocate [ outer_x; outer_x ] Value.empty_env)

(* Closure-visible mutation *)

let test_closure_visible_mutation () =
  let counter = Ident.fresh "counter" in
  let captured = Env.bind counter (Value.Num 0) Value.empty_env in
  (* A closure captures the environment chain. Later frames are invisible to it,
     but assignment reaches the shared cell, which is exactly why bindings are
     cells rather than values. *)
  let inner = Env.bind (Ident.fresh "tmp") Value.Unit captured in
  check "assignment through an extended chain succeeds"
    (Env.assign inner counter (Value.Num 1));
  check "the captured environment sees the mutation"
    (bound_num 1 (Env.state captured counter));
  check "and so does the extended one" (bound_num 1 (Env.state inner counter));

  (* Rebinding is not assignment: it pushes a frame the captured chain cannot
     see, so the two mechanisms stay distinguishable. *)
  let rebound = Env.bind counter (Value.Num 99) captured in
  check "rebinding shadows only in the new chain"
    (bound_num 99 (Env.state rebound counter));
  check "rebinding leaves the captured chain alone"
    (bound_num 1 (Env.state captured counter));

  (* Cells are shared, not copied: the very cell in the frame is what lookup
     returns. *)
  let cell = Option.get (Env.lookup captured counter) in
  Value.fill_cell cell (Value.Num 7);
  check "lookup returns the frame's own cell"
    (bound_num 7 (Env.state captured counter));

  (* Assignment never creates a binding. *)
  let absent = Ident.fresh "absent" in
  check "assigning an unbound identifier fails"
    (not (Env.assign captured absent (Value.Num 1)));
  check "and creates nothing" (Env.state captured absent = Env.Unbound)

(* Recursive preallocation *)

let test_preallocation () =
  let f = Ident.fresh "f" and g = Ident.fresh "g" in
  let env = Env.preallocate [ f; g ] Value.empty_env in
  (* LetRec allocates first so the lambdas it then evaluates can already see
     every sibling name. Until they are filled, reading one is an error rather
     than some default value. *)
  check "a preallocated binding is bound" (Option.is_some (Env.lookup env f));
  check "a preallocated binding is unfilled" (Env.state env f = Env.Unfilled);
  check_error "reading an unfilled binding is reported"
    ~expect:(fun error -> Error.cause_equal error.Error.cause (Error.Unfilled_binding f))
    (fun () -> Env.read_exn ~phase:Error.Evaluate ~span:use env f);

  check "filling a preallocated binding succeeds" (Env.assign env f (Value.Num 1));
  check "the filled binding reads back" (bound_num 1 (Env.state env f));
  check "its sibling is still unfilled" (Env.state env g = Env.Unfilled);
  check "one frame holds the whole recursive group" (Env.depth env = 1);
  (* The cells are the ones the closures captured, so filling after the fact is
     what makes the group mutually recursive. *)
  let cell_f = Option.get (Env.lookup env f) in
  check "the filled cell is the preallocated one" (is_num 1 (Value.cell_contents cell_f))

(* Lookup by printed name *)

let test_name_lookup () =
  let outer_x = Ident.fresh "x" in
  let inner_x = Ident.fresh "x" in
  let y = Ident.fresh "y" in
  let env =
    Env.bind inner_x (Value.Num 2) (Env.extend [ (outer_x, Value.Num 1); (y, Value.Num 3) ] Value.empty_env)
  in
  check "a name resolves to the innermost frame that mentions it"
    (match Env.lookup_by_name env "x" with
    | Env.Name_found (_, cell) -> is_num 2 (Value.cell_contents cell)
    | Env.Name_unbound | Env.Name_ambiguous _ -> false);
  check "a name only bound further out is still found"
    (match Env.lookup_by_name env "y" with
    | Env.Name_found (_, cell) -> is_num 3 (Value.cell_contents cell)
    | Env.Name_unbound | Env.Name_ambiguous _ -> false);
  check "an unbound name is reported as unbound"
    (Env.lookup_by_name env "nope" = Env.Name_unbound);

  (* Name lookup finds the cell, so a reflective assignment through a name is
     visible to identity lookups of that same binding. *)
  (match Env.lookup_by_name env "x" with
  | Env.Name_found (_, cell) -> Value.fill_cell cell (Value.Num 20)
  | Env.Name_unbound | Env.Name_ambiguous _ -> ());
  check "name lookup yields the binding's own cell"
    (bound_num 20 (Env.state env inner_x));
  check "and does not touch the shadowed binding"
    (bound_num 1 (Env.state env outer_x));

  (* Two distinct binders printing alike in one frame have no non-arbitrary
     winner. Choosing by allocation order would make the gensym counter
     observable, so the ambiguity is reported. *)
  let ambiguous = Env.extend [ (outer_x, Value.Num 1); (inner_x, Value.Num 2) ] Value.empty_env in
  check "one frame binding a name twice is ambiguous"
    (match Env.lookup_by_name ambiguous "x" with
    | Env.Name_ambiguous candidates -> List.length candidates = 2
    | Env.Name_found _ | Env.Name_unbound -> false);
  check "identity lookup is unaffected by the name ambiguity"
    (bound_num 1 (Env.state ambiguous outer_x)
    && bound_num 2 (Env.state ambiguous inner_x));
  check "an inner frame resolves the name before the ambiguous one is reached"
    (match Env.lookup_by_name (Env.bind (Ident.fresh "x") (Value.Num 5) ambiguous) "x" with
    | Env.Name_found (_, cell) -> is_num 5 (Value.cell_contents cell)
    | Env.Name_unbound | Env.Name_ambiguous _ -> false)

(* Failure behaviour *)

let test_failures () =
  let x = Ident.fresh "x" in
  let env = Value.empty_env in
  check_error "an unbound identifier reports its cause, span, phase and level"
    ~expect:(fun error ->
      Error.equal error
        (Error.make ~phase:Error.Evaluate ~span:use ~level:1 (Error.Unbound_ident x)))
    (fun () -> Env.lookup_exn ~phase:Error.Evaluate ~span:use ~level:1 env x);
  check_error "read_exn reports an unbound identifier too"
    ~expect:(fun error -> Error.cause_equal error.Error.cause (Error.Unbound_ident x))
    (fun () -> Env.read_exn ~phase:Error.Evaluate ~span:use env x);
  check_error "assign_exn reports an unbound identifier"
    ~expect:(fun error -> Error.cause_equal error.Error.cause (Error.Unbound_ident x))
    (fun () -> Env.assign_exn ~phase:Error.Evaluate ~span:use env x (Value.Num 1));
  check_error "an unbound name reports the name it looked for"
    ~expect:(fun error -> Error.cause_equal error.Error.cause (Error.Unbound_name "ghost"))
    (fun () -> Env.lookup_by_name_exn ~phase:Error.Evaluate ~span:use env "ghost");
  let a = Ident.fresh "dup" and b = Ident.fresh "dup" in
  let ambiguous = Env.extend [ (a, Value.Unit); (b, Value.Unit) ] Value.empty_env in
  let candidates =
    match Env.lookup_by_name ambiguous "dup" with
    | Env.Name_ambiguous candidates -> candidates
    | Env.Name_found _ | Env.Name_unbound -> []
  in
  check_int "both same-name binders are reported as candidates" 2 (List.length candidates);
  check_error "an ambiguous name names its candidates"
    ~expect:(fun error ->
      Error.cause_equal error.Error.cause
        (Error.Ambiguous_name { name = "dup"; candidates }))
    (fun () -> Env.lookup_by_name_exn ~phase:Error.Evaluate ~span:use ambiguous "dup");

  (* The rendered message locates the use site and never leaks a unique ID,
     which would make golden diagnostics depend on allocation order. *)
  let rendered =
    match Env.lookup_exn ~phase:Error.Evaluate ~span:use env x with
    | (_ : Value.cell) -> "no error"
    | exception Error.Ash_error error -> Error.to_string error
  in
  check_string "an unbound identifier renders with its location"
    "env.ash:3:5-6: evaluate error: unbound identifier `x`" rendered

let () =
  test_shadowing ();
  test_closure_visible_mutation ();
  test_preallocation ();
  test_name_lookup ();
  test_failures ();
  if !failures > 0 then (
    Printf.printf "%d environment assertion(s) failed\n" !failures;
    exit 1)
