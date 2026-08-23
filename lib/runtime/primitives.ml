open Ash_core

let fail ~span cause = Error.raise_cause ~phase:Error.Evaluate ~span cause

let type_error ~span ~expected value =
  fail ~span (Error.Unexpected { found = Value.type_phrase value; expected })

let wrong_arity ~span ~name ~arity args =
  fail ~span
    (Error.Arity_error
       {
         callee = Some name;
         expected = Value.arity_to_string arity;
         actual = List.length args;
       })

(* Argument accessors. Each enumerates the shapes it rejects rather than
   defaulting, so a new value shape has to be classified here too. *)

let number ~span value =
  match value with
  | Value.Num n -> n
  | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
  | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Environment _
  | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
      type_error ~span ~expected:"a number" value

let boolean ~span value =
  match value with
  | Value.Bool b -> b
  | Value.Num _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
  | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Environment _
  | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
      type_error ~span ~expected:"a boolean" value

let items ~span value =
  match value with
  | Value.List items -> items
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Environment _
  | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
      type_error ~span ~expected:"a list" value

let non_empty ~span value =
  match items ~span value with
  | item :: rest -> (item, rest)
  | [] -> type_error ~span ~expected:"a non-empty list" value

let cell ~span value =
  match value with
  | Value.Cell c -> c
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
  | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Environment _
  | Value.Code _ | Value.Primitive _ ->
      type_error ~span ~expected:"a cell" value

let filled ~span value =
  let c = cell ~span value in
  match Value.cell_contents c with
  | Some contents -> contents
  (* Unreachable through [cell_new], which always fills; reported rather than
     defaulted because a preallocated cell reaching a program is a bug, and
     "unfilled reads as unit" would hide it. *)
  | None ->
      fail ~span
        (Error.Unexpected { found = "an unfilled cell"; expected = "a filled cell" })

(* Builders. Each takes the effect class explicitly, so no primitive can be
   written down without saying what the specializer may do with it (spec §D7).

   Arity is re-checked here even though every applier checks it first: a
   [prim_impl] is a total function and an incomplete match would be a host
   crash rather than an Ash diagnostic. The two checks report identically. *)

let make ~name ~arity ~cls impl =
  { Value.prim_name = name; prim_arity = arity; prim_class = cls; prim_impl = impl }

(* The three wrappers cover every primitive that returns a value to its caller
   and never calls back into Ash, which is all of them but [callcc]: they drop
   the applier and invoke the continuation once, in tail position. *)

let nullary name cls impl =
  let arity = Value.Exactly 0 in
  make ~name ~arity ~cls (fun ~call_site ~apply:_ args k ->
      match args with
      | [] -> k (impl ~span:call_site)
      | _ :: _ -> wrong_arity ~span:call_site ~name ~arity args)

let unary name cls impl =
  let arity = Value.Exactly 1 in
  make ~name ~arity ~cls (fun ~call_site ~apply:_ args k ->
      match args with
      | [ a ] -> k (impl ~span:call_site a)
      | [] | _ :: _ :: _ -> wrong_arity ~span:call_site ~name ~arity args)

let binary name cls impl =
  let arity = Value.Exactly 2 in
  make ~name ~arity ~cls (fun ~call_site ~apply:_ args k ->
      match args with
      | [ a; b ] -> k (impl ~span:call_site a b)
      | [] | [ _ ] | _ :: _ :: _ :: _ -> wrong_arity ~span:call_site ~name ~arity args)

(* Arguments are checked left to right, in the order Ash evaluates them, so a
   call with two bad arguments reports the first one. *)
let numeric name combine =
  binary name Effect_class.Pure (fun ~span a b ->
      let x = number ~span a in
      let y = number ~span b in
      combine ~span x y)

let arithmetic name f = numeric name (fun ~span:_ x y -> Value.Num (f x y))

let dividing name f =
  numeric name (fun ~span x y ->
      if y = 0 then fail ~span Error.Division_by_zero else Value.Num (f x y))

let ordering name f = numeric name (fun ~span:_ x y -> Value.Bool (f (Int.compare x y) 0))

(* {1 The classes} *)

(* Foldable once every argument is static. Building an immutable list allocates
   in the host, but allocation is only observable when it can be mutated or
   compared by identity, and neither is true of a [List]: these stay pure, and
   the allocation class is about cells. *)
let pure =
  [
    (* Integer arithmetic. Division truncates toward zero and the remainder takes
       the sign of the dividend, as OCaml's operators do; dividing by zero is an
       error rather than a trap. *)
    arithmetic "+" ( + );
    arithmetic "-" ( - );
    arithmetic "*" ( * );
    dividing "/" ( / );
    dividing "%" ( mod );
    ordering "<" ( < );
    ordering "<=" ( <= );
    ordering ">" ( > );
    ordering ">=" ( >= );
    binary "==" Effect_class.Pure (fun ~span:_ a b -> Value.Bool (Value.equal a b));
    binary "!=" Effect_class.Pure (fun ~span:_ a b -> Value.Bool (not (Value.equal a b)));
    unary "not" Effect_class.Pure (fun ~span a -> Value.Bool (not (boolean ~span a)));
    binary "cons" Effect_class.Pure (fun ~span a b -> Value.List (a :: items ~span b));
    unary "head" Effect_class.Pure (fun ~span a -> fst (non_empty ~span a));
    unary "tail" Effect_class.Pure (fun ~span a -> Value.List (snd (non_empty ~span a)));
    unary "empty?" Effect_class.Pure (fun ~span a -> Value.Bool (items ~span a = []));
    unary "length" Effect_class.Pure (fun ~span a ->
        Value.Num (List.length (items ~span a)));
    make ~name:"list" ~arity:(Value.At_least 0) ~cls:Effect_class.Pure
      (fun ~call_site:_ ~apply:_ args k -> k (Value.List args));
    (* The one type test Ash has. The self-interpreter needs it because its
       value domain distinguishes an interpreted closure — a list carrying a
       private tag — from an interpreted scalar, and every other list operation
       fails rather than answering when handed a non-list. A predicate that
       answers is a different thing from an accessor that refuses, and only the
       predicate can be used to choose a branch. *)
    unary "list?" Effect_class.Pure (fun ~span:_ value ->
        Value.Bool
          (match value with
          | Value.List _ -> true
          | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
          | Value.Closure _ | Value.Reifier _ | Value.Continuation _
          | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
              false));
    (* What a desugared [match] falls through to. Core has no way to raise, and
       a match that runs out of clauses must not quietly answer unit, so the
       failure is a primitive like any other. Pure is the same judgement
       division by zero already gets: the result depends on nothing but the
       argument, so a specializer that folds it reports at specialization time a
       failure the program would certainly have reached. *)
    unary "match_error" Effect_class.Pure (fun ~span value ->
        fail ~span (Error.No_matching_clause (Value.to_string value)));
  ]

(* The store. Residualized by default: running [cell_set] during specialization
   would mutate the specializer's state instead of the program's. Phase 7's
   store splitting is what makes any of these static, and it needs an explicit
   discipline rather than an argument-is-known test. *)
let mutating dereferences =
  let cls = Effect_class.Allocation_or_mutation in
  [
    (* A fresh place each call. Two cells with equal contents are still two
       cells, which is what [Value.equal] already says. *)
    unary "cell_new" cls (fun ~span:_ initial -> Value.Cell (Value.cell initial));
    unary "deref" cls (fun ~span c -> filled ~span c);
    binary "cell_set" cls (fun ~span c value ->
        Value.fill_cell (cell ~span c) value;
        Value.Unit);
    (* The open-recursion cells of spec §D3, spelled apart from the ordinary
       ones. Same store, different meaning: these three are what an [open fn]
       group lowers to, so an [open_deref] in a term is exactly one evaluator
       group dereference, and the collapse report can count the ones that
       survive specialization without having to guess which cells were an
       interpreter's. Counting here rather than in the desugarer is what makes
       the count dynamic — it is dereferences performed, not dereferences
       written. *)
    unary "open_cell" cls (fun ~span:_ initial -> Value.Cell (Value.cell initial));
    unary "open_deref" cls (fun ~span c ->
        let contents = filled ~span c in
        (* After the read succeeds: a refused read is not a dereference. *)
        incr dereferences;
        contents);
    binary "open_set" cls (fun ~span c value ->
        Value.fill_cell (cell ~span c) value;
        Value.Unit);
  ]

(* What a value looks like when a program prints it rather than a diagnostic
   does: a string prints as its characters, because printing the escaped literal
   would make [print] useless for producing text. Everything else prints as it
   reads back. *)
let display = function
  | Value.Str s -> s
  | ( Value.Num _ | Value.Bool _ | Value.Sym _ | Value.Unit | Value.List _
    | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Environment _
    | Value.Cell _ | Value.Code _ | Value.Primitive _ ) as other ->
      Value.to_string other

(* Never executed at specialization time, whatever is known about the arguments.
   Folding [print("hi")] would move the effect from running the program to
   compiling it, which is the mistake D7 exists to prevent; compile-time logging
   gets its own primitive when it is wanted, rather than overloading these. *)
let observable io =
  let cls = Effect_class.Observable_effect in
  [
    unary "print" cls (fun ~span:_ value ->
        Io.write io (display value);
        Value.Unit);
    unary "println" cls (fun ~span:_ value ->
        Io.write io (display value ^ "\n");
        Value.Unit);
    nullary "read_line" cls (fun ~span ->
        match Io.read_line io with
        | Some line -> Value.Str line
        | None -> fail ~span Error.End_of_input);
  ]

(* Control. [callcc] is the whole class: it is what makes a continuation a value,
   and every other control operator this project needs so far is written in Ash
   from it. It is spelled without a slash because a surface program has to be
   able to name it, and `/` is division.

   Capturing is not itself an effect — nothing observable happens, and the
   argument decides what does — but the class is about what a specializer may
   do, and folding a capture at specialization time would capture the
   specializer's continuation rather than the program's. That is the same
   mistake D7 names for [print], so it gets the same treatment: bespoke rules,
   never automatic folding. *)
let control =
  [
    make ~name:"callcc" ~arity:(Value.Exactly 1) ~cls:Effect_class.Control
      (fun ~call_site ~apply args k ->
        match args with
        | [ receiver ] ->
            (* [k] is the continuation of the [callcc] call itself, so invoking
               the reified continuation later resumes exactly what the call
               would have returned into. Level 0 is the only level before Phase
               4; a captured continuation records it so that a reifier holding
               one cannot resume it on the wrong machine. *)
            let captured = Value.continuation ~capture:call_site ~level:0 k in
            apply ~call_site receiver [ Value.Continuation captured ] k
        | [] | _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"callcc" ~arity:(Value.Exactly 1) args);
    (* Applying a callee to a list of arguments whose length is only known at
       run time. Core [App] has a fixed number of argument positions, so a
       program that has built an argument list — which is what any evaluator's
       [apply] has — cannot spread it without this. The self-interpreter's
       [prim_apply] is the reason it exists (spec §6), and having it means the
       interpreted level inherits the host's arity, type, and division
       diagnostics instead of restating them.

       Control rather than Pure because its class is its callee's, and its
       callee is a value: nothing about the arguments being static says whether
       running it at specialization time is sound. A specializer that learns the
       callee rewrites it to a direct application under a bespoke rule; one that
       does not, residualizes it. That is the same treatment [callcc] gets, and
       for the same reason. *)
    make ~name:"invoke" ~arity:(Value.Exactly 2) ~cls:Effect_class.Control
      (fun ~call_site ~apply args k ->
        match args with
        | [ callee; arguments ] ->
            apply ~call_site callee (items ~span:call_site arguments) k
        | [] | [ _ ] | _ :: _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"invoke" ~arity:(Value.Exactly 2) args);
  ]

(* [Reflection] ([lift], [run], [reflect], [up]) waits for staging and the tower
   in Phases 3 and 4. It is empty rather than stubbed: a primitive that exists
   but refuses to run is a worse answer than one that is honestly not there yet,
   and nothing about the classification depends on a class being populated — the
   class is a field of the primitive, so a primitive without one cannot be
   written. *)

let build io dereferences =
  let primitives = pure @ mutating dereferences @ observable io @ control in
  (* Exactly one class per primitive is a property of the record type; what it
     cannot rule out is the same name registered twice with different classes,
     where a lookup would answer one and the environment bind the other. *)
  let seen = Hashtbl.create 64 in
  List.iter
    (fun primitive ->
      let name = primitive.Value.prim_name in
      if Hashtbl.mem seen name then
        invalid_arg (Printf.sprintf "Primitives: `%s` is registered twice" name);
      Hashtbl.add seen name ())
    primitives;
  primitives

type t = {
  io : Io.t;
  primitives : Value.primitive list;
  dereferences : int ref;
      (* Open-recursion cell reads, which the collapse report measures against
         (§9.2). Observationally inert: no primitive reads it, so no Ash value,
         diagnostic, or output can depend on it. *)
}

let create ?io () =
  let io = match io with Some io -> io | None -> Io.create () in
  let dereferences = ref 0 in
  { io; primitives = build io dereferences; dereferences }

let io t = t.io
let open_dereferences t = !(t.dereferences)
let reset_open_dereferences t = t.dereferences := 0
let all t = t.primitives

let find t name =
  List.find_opt
    (fun primitive -> String.equal primitive.Value.prim_name name)
    t.primitives

let globals t =
  List.map
    (fun primitive ->
      (Ident.fresh primitive.Value.prim_name, Value.Primitive primitive))
    t.primitives

(* The classification is the same for every registry, because only the
   implementations of the observable primitives depend on a stream. Deriving it
   from a real registry rather than writing a second table keeps them from
   drifting apart. *)
let classification =
  List.map
    (fun primitive -> (primitive.Value.prim_name, primitive.Value.prim_class))
    (build (Io.create ()) (ref 0))

let names = List.map fst classification
let count = List.length classification
let class_of name = List.assoc_opt name classification

let by_class cls =
  List.filter_map
    (fun (name, c) -> if Effect_class.equal c cls then Some name else None)
    classification
