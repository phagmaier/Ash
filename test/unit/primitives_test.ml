(* Unit tests for the classified primitive registry and the observable-effect
   stream it writes to (to-do task 0.9). *)

open Ash_core
open Ash_syntax
open Ash_runtime

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let check_int name expected actual =
  if not (Int.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %d\n  actual:   %d\n" name expected actual)

let check_string name expected actual =
  if not (String.equal expected actual) then (
    incr failures;
    Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name expected actual)

let sp =
  Span.make
    ~start:(Span.position ~file:"p.ash" ~line:1 ~column:1 ~offset:0)
    ~stop:(Span.position ~file:"p.ash" ~line:1 ~column:2 ~offset:1)

let ground registry =
  let globals = Primitives.globals registry in
  let scope =
    Core_reader.scope_of_list
      (List.map (fun (ident, _) -> (Ident.name ident, ident)) globals)
  in
  (Env.extend globals Value.empty_env, scope)

let run_in registry text =
  let env, scope = ground registry in
  Evaluator.eval ~env (Core_reader.read ~scope ~file:"p.ash" text)

let check_value name expected registry text =
  match run_in registry text with
  | actual ->
      if not (Value.equal expected actual) then (
        incr failures;
        Printf.printf "FAIL %s\n  expected: %s\n  actual:   %s\n" name
          (Value.to_string expected) (Value.to_string actual))
  | exception Error.Ash_error error ->
      incr failures;
      Printf.printf "FAIL %s\n  unexpected error: %s\n" name (Error.to_string error)

let check_error name ~cause registry text =
  match run_in registry text with
  | value ->
      incr failures;
      Printf.printf "FAIL %s\n  expected an error, got %s\n" name (Value.to_string value)
  | exception Error.Ash_error error ->
      if not (Error.cause_equal error.Error.cause cause) then (
        incr failures;
        Printf.printf "FAIL %s\n  wrong cause: %s\n" name (Error.to_string error))

(* Applying a primitive the way the evaluator does, so what is checked is the
   path a program actually takes. *)
let apply primitive args =
  let machine = Evaluator.machine () in
  Machine.apply machine ~call_site:sp (Value.Primitive primitive) args (fun v -> v)

let attempt f = match f () with value -> Ok value | exception Error.Ash_error e -> Error e

(* The classification itself *)

(* Written down independently of the registry, so a primitive added without a
   deliberate classification decision fails here rather than inheriting whatever
   class its neighbour had. *)
let expected_classification =
  let pure = Effect_class.Pure
  and mutating = Effect_class.Allocation_or_mutation
  and observable = Effect_class.Observable_effect in
  [
    ("+", pure); ("-", pure); ("*", pure); ("/", pure); ("%", pure);
    ("<", pure); ("<=", pure); (">", pure); (">=", pure);
    ("==", pure); ("!=", pure); ("not", pure);
    ("cons", pure); ("head", pure); ("tail", pure); ("empty?", pure);
    ("length", pure); ("list", pure);
    ("cell_new", mutating); ("deref", mutating); ("cell_set", mutating);
    ("print", observable); ("println", observable); ("read_line", observable);
  ]

let sorted_names names = List.sort String.compare names

let test_classification () =
  let registry = Primitives.create () in
  check_int "the registry is the classification" Primitives.count
    (List.length (Primitives.all registry));
  check "names are distinct"
    (List.length (List.sort_uniq String.compare Primitives.names)
    = List.length Primitives.names);
  check "every registered primitive is in the classification"
    (List.for_all
       (fun p ->
         match Primitives.class_of p.Value.prim_name with
         | Some cls -> Effect_class.equal cls p.Value.prim_class
         | None -> false)
       (Primitives.all registry));
  check "the classification matches the expected table"
    (List.equal
       (fun (a, x) (b, y) -> String.equal a b && Effect_class.equal x y)
       (List.sort compare expected_classification)
       (List.sort compare Primitives.classification));

  (* Exactly one class each: the classes cover every name, and cover it once.
     Iterating [Effect_class.all] is what makes this exhaustive — a new class
     could not be forgotten here. *)
  let by_class = List.concat_map Primitives.by_class Effect_class.all in
  check_int "the classes cover every primitive" Primitives.count (List.length by_class);
  check "and no primitive twice"
    (List.equal String.equal (sorted_names Primitives.names) (sorted_names by_class));
  List.iter
    (fun cls ->
      List.iter
        (fun name ->
          check
            (Printf.sprintf "`%s` is only in %s" name (Effect_class.name cls))
            (match Primitives.class_of name with
            | Some actual -> Effect_class.equal actual cls
            | None -> false))
        (Primitives.by_class cls))
    Effect_class.all;

  (* The staging policy follows from the class, so it is asked of the class and
     not of the primitive. Folding anything outside the pure class at
     specialization time is the D7 mistake. *)
  check "only pure primitives may fold when static"
    (List.for_all
       (fun (name, cls) ->
         Bool.equal
           (Effect_class.may_fold_when_static cls)
           (List.mem name (Primitives.by_class Effect_class.Pure)))
       Primitives.classification);
  check "only observable primitives always residualize"
    (List.for_all
       (fun (name, cls) ->
         Bool.equal
           (Effect_class.always_residualizes cls)
           (List.mem name (Primitives.by_class Effect_class.Observable_effect)))
       Primitives.classification);

  (* Control and reflection are honestly empty rather than stubbed. When 1.5 and
     the tower fill them, this says so instead of quietly passing. *)
  check "control is empty until one-shot continuations exist"
    (Primitives.by_class Effect_class.Control = []);
  check "reflection is empty until staging and the tower exist"
    (Primitives.by_class Effect_class.Reflection = []);

  check "an unregistered name has no class" (Primitives.class_of "nope" = None);
  check "find locates a primitive by name"
    (match Primitives.find registry "+" with
    | Some p -> String.equal p.Value.prim_name "+"
    | None -> false);
  check "find reports an unknown name" (Primitives.find registry "nope" = None)

(* Arity, checked the same way for every primitive *)

let test_arity () =
  let registry = Primitives.create () in
  List.iter
    (fun primitive ->
      let name = primitive.Value.prim_name in
      let arity = primitive.Value.prim_arity in
      let expected = Value.arity_to_string arity in
      List.iter
        (fun count ->
          if not (Value.arity_matches arity count) then (
            let args = List.init count (fun _ -> Value.Num 1) in
            let cause =
              Error.Arity_error { callee = Some name; expected; actual = count }
            in
            (* Through the evaluator: one message shape, naming the primitive,
               its arity, and what it was given, at the call site. *)
            (match attempt (fun () -> apply primitive args) with
            | Ok value ->
                incr failures;
                Printf.printf "FAIL `%s` accepted %d argument(s), returning %s\n" name
                  count (Value.to_string value)
            | Error error ->
                check
                  (Printf.sprintf "`%s` with %d argument(s) is an arity error" name count)
                  (Error.cause_equal error.Error.cause cause);
                check
                  (Printf.sprintf "`%s` reports arity at the call site" name)
                  (Span.equal error.Error.span sp);
                check
                  (Printf.sprintf "`%s` reports arity from the evaluate phase" name)
                  (error.Error.phase = Error.Evaluate));
            (* And directly: an implementation is a total function, so it checks
               again, and the two checks must not disagree. *)
            match
              attempt (fun () -> primitive.Value.prim_impl ~call_site:sp args (fun v -> v))
            with
            | Ok _ ->
                incr failures;
                Printf.printf "FAIL `%s` did not check its own arity at %d\n" name count
            | Error error ->
                check
                  (Printf.sprintf "`%s` checks arity identically inside" name)
                  (Error.cause_equal error.Error.cause cause)))
        [ 0; 1; 2; 3 ])
    (Primitives.all registry);
  (* A variadic primitive accepts every count, so the loop above must not be the
     only thing this test does. *)
  check "the variadic primitive takes any number of arguments"
    (List.for_all
       (fun count ->
         match Primitives.find registry "list" with
         | Some p -> Value.arity_matches p.Value.prim_arity count
         | None -> false)
       [ 0; 1; 2; 3 ])

(* Argument types, listed per primitive so a new one cannot arrive untested *)

type expectation =
  | Rejects of (Value.value list * string * string) list
      (** Arguments, the phrase for what was found, the phrase expected. *)
  | Total of Value.value list
      (** A primitive that accepts every value: a call that must succeed. *)

let type_expectations =
  let n = Value.Num 1 and s = Value.Str "x" and b = Value.Bool true in
  let numeric name =
    ( name,
      Rejects
        [
          ([ s; n ], "a string", "a number");
          (* The second argument is only reached because the first was fine, so
             this is also the left-to-right check. *)
          ([ n; b ], "a boolean", "a number");
        ] )
  in
  [
    numeric "+"; numeric "-"; numeric "*"; numeric "/"; numeric "%";
    numeric "<"; numeric "<="; numeric ">"; numeric ">=";
    ("==", Total [ n; Value.Unit ]);
    ("!=", Total [ s; Value.List [] ]);
    ("not", Rejects [ ([ n ], "a number", "a boolean") ]);
    ("cons", Rejects [ ([ n; n ], "a number", "a list") ]);
    ( "head",
      Rejects
        [
          ([ n ], "a number", "a list");
          ([ Value.List [] ], "the empty list", "a non-empty list");
        ] );
    ( "tail",
      Rejects
        [
          ([ n ], "a number", "a list");
          ([ Value.List [] ], "the empty list", "a non-empty list");
        ] );
    ("empty?", Rejects [ ([ n ], "a number", "a list") ]);
    ("length", Rejects [ ([ s ], "a string", "a list") ]);
    ("list", Total [ n; s; b ]);
    ("cell_new", Total [ n ]);
    ("deref", Rejects [ ([ n ], "a number", "a cell") ]);
    ("cell_set", Rejects [ ([ n; n ], "a number", "a cell") ]);
    ("print", Total [ s ]);
    ("println", Total [ n ]);
    ("read_line", Total []);
  ]

let test_type_errors () =
  (* The table is only worth anything if it covers the registry, so that is
     checked before it is used. *)
  check "every primitive has a type expectation"
    (List.equal String.equal
       (sorted_names Primitives.names)
       (sorted_names (List.map fst type_expectations)));
  let registry = Primitives.create ~io:(Io.create ~input:[ "a line" ] ()) () in
  List.iter
    (fun (name, expectation) ->
      match Primitives.find registry name with
      | None ->
          incr failures;
          Printf.printf "FAIL `%s` is not registered\n" name
      | Some primitive -> (
          match expectation with
          | Total args -> (
              match attempt (fun () -> apply primitive args) with
              | Ok _ -> ()
              | Error error ->
                  incr failures;
                  Printf.printf "FAIL `%s` rejected a value it accepts: %s\n" name
                    (Error.to_string error))
          | Rejects cases ->
              List.iter
                (fun (args, found, expected) ->
                  let cause = Error.Unexpected { found; expected } in
                  match attempt (fun () -> apply primitive args) with
                  | Ok value ->
                      incr failures;
                      Printf.printf "FAIL `%s` accepted %s, returning %s\n" name found
                        (Value.to_string value)
                  | Error error ->
                      check
                        (Printf.sprintf "`%s` rejects %s" name found)
                        (Error.cause_equal error.Error.cause cause);
                      check
                        (Printf.sprintf "`%s` reports the type error at the call site" name)
                        (Span.equal error.Error.span sp);
                      check
                        (Printf.sprintf "`%s` reports the type error from the evaluate phase"
                           name)
                        (error.Error.phase = Error.Evaluate))
                cases))
    type_expectations

(* Allocation and mutation *)

let test_cells () =
  let registry = Primitives.create () in
  check_value "a cell reads back what it was given" (Value.Num 7) registry
    "(app (var deref) (app (var cell_new) (lit 7)))";
  check_value "assignment is visible through the same cell" (Value.Num 9) registry
    "(let c (app (var cell_new) (lit 7))\n\
    \  (let _ (app (var cell_set) (var c) (lit 9))\n\
    \    (app (var deref) (var c))))";
  check_value "assignment evaluates to unit" Value.Unit registry
    "(let c (app (var cell_new) (lit 0)) (app (var cell_set) (var c) (lit 1)))";
  (* Two cells with equal contents are two places, which is what makes the store
     something Phase 7 has to reason about rather than fold away. *)
  check_value "cells are distinct places" (Value.Bool false) registry
    "(app (var ==) (app (var cell_new) (lit 1)) (app (var cell_new) (lit 1)))";
  check_value "and a cell is itself" (Value.Bool true) registry
    "(let c (app (var cell_new) (lit 1)) (app (var ==) (var c) (var c)))";
  (* Aliasing: a closure that captured the cell sees a later write. *)
  check_value "a captured cell is shared, not copied" (Value.Num 5) registry
    "(let c (app (var cell_new) (lit 1))\n\
    \  (let read (lam () (app (var deref) (var c)))\n\
    \    (let _ (app (var cell_set) (var c) (lit 5))\n\
    \      (app (var read)))))";
  check_error "dereferencing a number is a type error"
    ~cause:(Error.Unexpected { found = "a number"; expected = "a cell" })
    registry "(app (var deref) (lit 1))";
  check "cells do not write to the observable stream"
    (Io.events (Primitives.io registry) = [])

(* Observable effects *)

let test_output () =
  let io = Io.create () in
  let registry = Primitives.create ~io () in
  check_value "printing evaluates to unit" Value.Unit registry
    "(app (var print) (lit 1))";
  check_string "and the write is recorded" "wrote \"1\"" (Io.trace io);
  Io.clear io;

  (* Order is part of what a program means, so the trace is compared as a
     sequence and not as a set. *)
  let (_ : Value.value) =
    run_in registry
      "(let _ (app (var println) (lit 1))\n\
      \  (let _ (app (var println) (lit 2)) (app (var print) (lit 3))))"
  in
  check_string "writes are recorded in order"
    "wrote \"1\\n\"; wrote \"2\\n\"; wrote \"3\"" (Io.trace io);
  check_string "and reassemble into the output" "1\n2\n3" (Io.text io);
  Io.clear io;

  (* A program prints a string's characters; a diagnostic prints its literal.
     Printing the escaped form would make [print] useless for producing text. *)
  let (_ : Value.value) = run_in registry "(app (var print) (lit \"a\\nb\"))" in
  check_string "a printed string is its characters" "a\nb" (Io.text io);
  check_string "while its literal form is escaped" "\"a\\nb\""
    (Value.to_string (Value.Str "a\nb"));
  Io.clear io;

  let (_ : Value.value) = run_in registry "(app (var print) (lit nil))" in
  check_string "other values print as they read back" "[]" (Io.text io);
  Io.clear io;

  (* Nothing reaches the stream unless the program put it there: a test that
     leaks output is a test that cannot be compared. *)
  let (_ : Value.value) = run_in registry "(app (var +) (lit 1) (lit 2))" in
  check "a pure program writes nothing" (Io.events io = [])

let test_input () =
  let io = Io.create ~input:[ "first"; "second" ] () in
  let registry = Primitives.create ~io () in
  check_value "reading yields the next line" (Value.Str "first") registry
    "(app (var read_line))";
  check_value "and consumes it" (Value.Str "second") registry "(app (var read_line))";
  check_string "reads are recorded too" "read \"first\"; read \"second\"" (Io.trace io);
  check_error "reading past the end is an error" ~cause:Error.End_of_input registry
    "(app (var read_line))";
  Io.feed io [ "third" ];
  check_value "and more input can be supplied" (Value.Str "third") registry
    "(app (var read_line))";

  (* Interleaving proves the two directions share one ordered trace. *)
  let io = Io.create ~input:[ "x" ] () in
  let registry = Primitives.create ~io () in
  let (_ : Value.value) =
    run_in registry
      "(let _ (app (var print) (lit \"in: \")) (app (var print) (app (var read_line))))"
  in
  check_string "reads and writes share one trace"
    "wrote \"in: \"; read \"x\"; wrote \"x\"" (Io.trace io)

(* The stream itself *)

let test_io () =
  let io = Io.create () in
  check "a fresh stream has no events" (Io.events io = []);
  check "and no input" (Io.pending_input io = []);
  Io.write io "a";
  Io.write io "b";
  check "writes are ordered oldest first"
    (List.equal String.equal [ "a"; "b" ] (Io.written io));
  check_string "text is the writes concatenated" "ab" (Io.text io);
  check "read_line reports exhaustion rather than failing" (Io.read_line io = None);
  Io.feed io [ "one"; "two" ];
  check "feeding queues input"
    (List.equal String.equal [ "one"; "two" ] (Io.pending_input io));
  check "read_line consumes in order" (Io.read_line io = Some "one");
  check "and leaves the rest"
    (List.equal String.equal [ "two" ] (Io.pending_input io));
  check "events record both directions"
    (List.equal Io.event_equal
       [ Io.Wrote "a"; Io.Wrote "b"; Io.Read "one" ]
       (Io.events io));
  Io.clear io;
  check "clearing forgets the events" (Io.events io = []);
  check "but not the pending input"
    (List.equal String.equal [ "two" ] (Io.pending_input io));
  check_string "events render escaped" "wrote \"a\\nb\""
    (Io.event_to_string (Io.Wrote "a\nb"));

  (* Echoing is an additional output for interactive use, never a replacement
     for the record. *)
  let path = Filename.temp_file "ash_io" ".txt" in
  let channel = open_out path in
  let echoing = Io.create ~echo:channel () in
  Io.write echoing "echoed";
  close_out channel;
  let contents =
    let input = open_in path in
    let text = really_input_string input (in_channel_length input) in
    close_in input;
    Sys.remove path;
    text
  in
  check_string "an echoing stream writes through" "echoed" contents;
  check_string "and still records" "echoed" (Io.text echoing)

(* Globals: what a materialized tower level clones *)

let test_globals () =
  let registry = Primitives.create () in
  check_int "globals bind every primitive" Primitives.count
    (List.length (Primitives.globals registry));
  (* A materialized level gets its own cloned globals, so identities must not be
     shared between two calls. *)
  check "globals allocate fresh identities each time"
    (match (Primitives.globals registry, Primitives.globals registry) with
    | (a, _) :: _, ((b, _) :: _) -> (not (Ident.equal a b)) && Ident.same_name a b
    | _, _ -> false);
  (* The values are shared, though: output is one stream of events for the whole
     tower, not one per level. *)
  let one, other = (Primitives.globals registry, Primitives.globals registry) in
  let print_value bindings =
    List.find_map
      (fun (ident, value) ->
        if String.equal (Ident.name ident) "print" then Some value else None)
      bindings
  in
  check "cloned globals share the primitive values"
    (match (print_value one, print_value other) with
    | Some a, Some b -> Value.equal a b
    | _, _ -> false);
  (* Two registries are two streams, which is what makes a test deterministic. *)
  let a = Primitives.create () and b = Primitives.create () in
  let (_ : Value.value) = run_in a "(app (var print) (lit 1))" in
  check "a second registry has its own stream" (Io.events (Primitives.io b) = []);
  check_string "and the first kept the event" "wrote \"1\"" (Io.trace (Primitives.io a))

let () =
  test_classification ();
  test_arity ();
  test_type_errors ();
  test_cells ();
  test_output ();
  test_input ();
  test_io ();
  test_globals ();
  if !failures > 0 then (
    Printf.printf "%d primitive assertion(s) failed\n" !failures;
    exit 1)
