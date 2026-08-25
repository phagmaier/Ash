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

let string ~span value =
  match value with
  | Value.Str text -> text
  | Value.Num _ | Value.Bool _ | Value.Sym _ | Value.Unit | Value.List _
  | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Environment _
  | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
      type_error ~span ~expected:"a string" value

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

let code ~span value =
  match value with
  | Value.Code node -> node
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.List _ | Value.Closure _ | Value.Reifier _ | Value.Continuation _
  | Value.Environment _ | Value.Cell _ | Value.Primitive _ ->
      type_error ~span ~expected:"code" value

let environment ~span value =
  match value with
  | Value.Environment env -> env
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
  | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Cell _
  | Value.Code _ | Value.Primitive _ ->
      type_error ~span ~expected:"an environment" value

(* Returned as a value rather than as a {!Value.continuation}: transferring is
   the applier's job, so the check here is about what the caller passed, not
   about how it is invoked. *)
let continuation ~span value =
  match value with
  | Value.Continuation _ -> value
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit | Value.List _
  | Value.Closure _ | Value.Reifier _ | Value.Environment _ | Value.Cell _
  | Value.Code _ | Value.Primitive _ ->
      type_error ~span ~expected:"a continuation" value

let code_variable ~span value =
  let node = code ~span value in
  match Core.shape node with
  | Core.Var ident -> ident
  | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
  | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
      fail ~span
        (Error.Unexpected
           {
             found = Printf.sprintf "code containing %s" (Core.kind_name node);
             expected = "code containing a variable";
           })

let integer ~span value = number ~span value

let source_span ~span value = Core.span (code ~span value)

let code_variables ~span value =
  List.map (code_variable ~span) (items ~span value)

let optional_callee ~span value =
  match value with
  | Value.List [] -> None
  | Value.List [ Value.Str name ] -> Some name
  | Value.List (_ :: _ :: _) | Value.List [ (Value.Num _ | Value.Bool _ | Value.Sym _
    | Value.Unit | Value.List _ | Value.Closure _ | Value.Reifier _
    | Value.Continuation _ | Value.Environment _ | Value.Cell _ | Value.Code _
    | Value.Primitive _) ] ->
      type_error ~span ~expected:"an empty list or a one-string list" value
  | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
  | Value.Closure _ | Value.Reifier _ | Value.Continuation _ | Value.Environment _
  | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
      type_error ~span ~expected:"an empty list or a one-string list" value

(* The level is deliberately absent here: an interpreted level's failure belongs
   to the level running the interpreter, which only the applying evaluator
   knows. Naming a level in the descriptor would fix it to the base program and
   be wrong for every materialized level above it. *)
let source_error_cause ~span descriptor =
  match items ~span descriptor with
  | [ Value.Sym "unbound_ident"; identity ] ->
      Error.Unbound_ident (code_variable ~span identity)
  | [ Value.Sym "unbound_name"; Value.Str name ] -> Error.Unbound_name name
  | [ Value.Sym "ambiguous_name"; Value.Str name; candidates ] ->
      Error.Ambiguous_name { name; candidates = code_variables ~span candidates }
  | [ Value.Sym "arity"; callee; expected; actual ] ->
      Error.Arity_error
        {
          callee = optional_callee ~span callee;
          expected = string_of_int (integer ~span expected);
          actual = integer ~span actual;
        }
  | [ Value.Sym "unexpected"; found; Value.Str expected ] ->
      Error.Unexpected { found = Value.type_phrase found; expected }
  | [ Value.Sym "continuation_reuse"; captured; first_used ] ->
      Error.Continuation_reuse
        {
          captured = source_span ~span captured;
          first_used = source_span ~span first_used;
        }
  | [ Value.Sym "unsupported"; Value.Str what; Value.Str by ] ->
      Error.Unsupported { what; by }
  | Value.Sym tag :: _ ->
      fail ~span
        (Error.Unexpected
           {
             found = Printf.sprintf "an unknown source-error descriptor `%s`" tag;
             expected = "a supported source-error descriptor";
           })
  | [] | Value.Num _ :: _ | Value.Bool _ :: _ | Value.Str _ :: _ | Value.Unit :: _
  | Value.List _ :: _ | Value.Closure _ :: _ | Value.Reifier _ :: _
  | Value.Continuation _ :: _ | Value.Environment _ :: _ | Value.Cell _ :: _
  | Value.Code _ :: _ | Value.Primitive _ :: _ ->
      type_error ~span ~expected:"a source-error descriptor headed by a symbol"
        descriptor

(* A destructured Core node uses ordinary Ash values for literals and strings,
   and [Code] for every syntactic component. Binder identities are represented
   as one-node [Var] code values; this keeps the value domain small while making
   them comparable and reusable without exposing the host gensym counter. *)
let code_view node =
  let span = Core.span node in
  let tagged name fields = Value.List (Value.Sym name :: fields) in
  let code node = Value.Code node in
  let ident_at span identity = code (Core.var ~span identity) in
  let ident identity = ident_at span identity in
  let idents identities = Value.List (List.map ident identities) in
  let lambda ?(span = span) definition = code (Core.of_lambda ~span definition) in
  match Core.shape node with
  | Core.Lit constant -> tagged "Lit" [ Value.of_constant constant ]
  | Core.Var identity -> tagged "Var" [ ident identity ]
  | Core.NamedVar name -> tagged "NamedVar" [ Value.Str name ]
  | Core.Lam definition ->
      tagged "Lam" [ idents definition.Core.params; code definition.Core.lam_body ]
  | Core.App { Core.func; args } ->
      tagged "App" [ code func; Value.List (List.map code args) ]
  | Core.Let { Core.let_binder; let_value; let_body } ->
      tagged "Let" [ ident let_binder; code let_value; code let_body ]
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      let binding definition =
        Value.List
          [
            ident_at definition.Core.rec_span definition.Core.rec_name;
            lambda ~span:definition.Core.rec_span definition.Core.rec_lambda;
          ]
      in
      tagged "LetRec"
        [ Value.List (List.map binding rec_bindings); code rec_body ]
  | Core.If { Core.condition; consequent; alternative } ->
      tagged "If" [ code condition; code consequent; code alternative ]
  | Core.Set { Core.set_target; set_value } ->
      tagged "Set" [ ident set_target; code set_value ]
  | Core.Quote quoted -> tagged "Quote" [ code quoted ]
  | Core.Reifier { Core.exp_param; env_param; cont_param; reifier_body } ->
      tagged "Reifier"
        [ idents [ exp_param; env_param; cont_param ]; code reifier_body ]

(* Builders. Each takes the effect class explicitly, so no primitive can be
   written down without saying what the specializer may do with it (spec §D7).

   Arity is re-checked here even though every applier checks it first: a
   [prim_impl] is a total function and an incomplete match would be a host
   crash rather than an Ash diagnostic. The two checks report identically. *)

(* [observes] defaults to the conservative judgement: every argument decides the
   result, so nothing folds until everything is known. A primitive that answers
   from an argument's spine alone says so once, here, rather than leaving the
   specializer to infer it (spec §7.4 step 1). *)
let make ~name ~arity ~cls ?(observes = Observation.whole_values) impl =
  {
    Value.prim_name = name;
    prim_arity = arity;
    prim_class = cls;
    prim_observes = observes;
    prim_impl = impl;
  }

(* The three wrappers cover primitives that need neither the evaluator callbacks
   nor the level they are running at: they drop both and invoke the continuation
   once, in tail position. *)

let nullary name cls impl =
  let arity = Value.Exactly 0 in
  make ~name ~arity ~cls (fun ~call_site ~level:_ ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
      match args with
      | [] -> k (impl ~span:call_site)
      | _ :: _ -> wrong_arity ~span:call_site ~name ~arity args)

let unary ?observes name cls impl =
  let arity = Value.Exactly 1 in
  make ~name ~arity ~cls ?observes (fun ~call_site ~level:_ ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
      match args with
      | [ a ] -> k (impl ~span:call_site a)
      | [] | _ :: _ :: _ -> wrong_arity ~span:call_site ~name ~arity args)

let binary ?observes name cls impl =
  let arity = Value.Exactly 2 in
  make ~name ~arity ~cls ?observes (fun ~call_site ~level:_ ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
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
    (* The immutable-data group. Each answers from the spine of its list
       argument, never from the elements, so the specializer may run it on a
       list whose spine is known even when the elements are still dynamic: that
       is what lets a loop over a statically shaped list unroll while the values
       it carries stay residual (spec §7.3, §7.4 step 1). *)
    binary ~observes:(Observation.of_positional [ Unobserved; Shape_only ])
      "cons" Effect_class.Pure (fun ~span a b -> Value.List (a :: items ~span b));
    unary ~observes:(Observation.of_positional [ Shape_only ])
      "head" Effect_class.Pure (fun ~span a -> fst (non_empty ~span a));
    unary ~observes:(Observation.of_positional [ Shape_only ])
      "tail" Effect_class.Pure (fun ~span a ->
        Value.List (snd (non_empty ~span a)));
    unary ~observes:(Observation.of_positional [ Shape_only ])
      "empty?" Effect_class.Pure (fun ~span a -> Value.Bool (items ~span a = []));
    unary ~observes:(Observation.of_positional [ Shape_only ])
      "length" Effect_class.Pure (fun ~span a ->
        Value.Num (List.length (items ~span a)));
    make ~name:"list" ~arity:(Value.At_least 0) ~cls:Effect_class.Pure
      ~observes:(Observation.uniform Observation.Unobserved)
      (fun ~call_site:_ ~level:_ ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k -> k (Value.List args));
    (* The one type test Ash has. The self-interpreter needs it because its
       value domain distinguishes an interpreted closure — a list carrying a
       private tag — from an interpreted scalar, and every other list operation
       fails rather than answering when handed a non-list. A predicate that
       answers is a different thing from an accessor that refuses, and only the
       predicate can be used to choose a branch. *)
    unary ~observes:(Observation.of_positional [ Shape_only ])
      "list?" Effect_class.Pure (fun ~span:_ value ->
        Value.Bool
          (match value with
          | Value.List _ -> true
          | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
          | Value.Closure _ | Value.Reifier _ | Value.Continuation _
          | Value.Environment _ | Value.Cell _ | Value.Code _ | Value.Primitive _ ->
              false));
    (* Code construction and observation are pure: Core and [Code] are
       immutable, and D7 explicitly puts Code constructors in the foldable
       class. Reflection stays reserved for [lift], [run], [reflect], [up], and
       reifier application, whose meaning depends on evaluator/tower state. *)
    unary "code?" Effect_class.Pure (fun ~span:_ value ->
        Value.Bool
          (match value with
          | Value.Code _ -> true
          | Value.Num _ | Value.Bool _ | Value.Str _ | Value.Sym _ | Value.Unit
          | Value.List _ | Value.Closure _ | Value.Reifier _
          | Value.Continuation _ | Value.Environment _ | Value.Cell _
          | Value.Primitive _ ->
              false));
    unary "code_view" Effect_class.Pure (fun ~span value ->
        code_view (code ~span value));
    unary "code_name" Effect_class.Pure (fun ~span value ->
        Value.Str (Ident.name (code_variable ~span value)));
    make ~name:"code_splice" ~arity:(Value.Exactly 3) ~cls:Effect_class.Pure
      (fun ~call_site ~level:_ ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
        match args with
        | [ template; marker; replacement ] ->
            let template = code ~span:call_site template in
            let marker = code_variable ~span:call_site marker in
            let replacement = code ~span:call_site replacement in
            k (Value.Code (Code.splice ~marker ~replacement template))
        | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"code_splice"
              ~arity:(Value.Exactly 3) args);
    make ~name:"code_match" ~arity:(Value.At_least 2) ~cls:Effect_class.Pure
      (fun ~call_site ~level:_ ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
        match args with
        | template :: subject :: markers ->
            let template = code ~span:call_site template in
            let subject = code ~span:call_site subject in
            let holes = List.map (code_variable ~span:call_site) markers in
            let result =
              match Code.match_template ~holes ~template subject with
              | None -> Value.List []
              | Some captures ->
                  Value.List [ Value.List (List.map (fun node -> Value.Code node) captures) ]
            in
            k result
        | [] | [ _ ] ->
            wrong_arity ~span:call_site ~name:"code_match"
              ~arity:(Value.At_least 2) args);
    unary "NamedVar" Effect_class.Pure (fun ~span value ->
        Value.Code (Core.named_var ~span (string ~span value)));
    (* What a desugared [match] falls through to. Core has no way to raise, and
       a match that runs out of clauses must not quietly answer unit, so the
       failure is a primitive like any other. Pure is the same judgement
       division by zero already gets: the result depends on nothing but the
       argument, so a specializer that folds it reports at specialization time a
       failure the program would certainly have reached. *)
    unary "match_error" Effect_class.Pure (fun ~span value ->
        fail ~span (Error.No_matching_clause (Value.to_string value)));
    (* The self-interpreter carries a subject node as Code. When it detects an
       evaluator error itself, [raise_at] anchors the structured cause at that
       node rather than at the helper call in [eval.ash]. The descriptor is a
       closed protocol, not an arbitrary host exception escape hatch. *)
    make ~name:"raise_at" ~arity:(Value.Exactly 2) ~cls:Effect_class.Pure
      (fun ~call_site ~level ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args _k ->
        match args with
        | [ site; descriptor ] ->
            (* An interpreted level fails where the ground evaluator would, so
               its error belongs to the level running the interpreter, exactly
               as an error that evaluator raises itself does. *)
            Error.raise_cause ~phase:Error.Evaluate
              ~span:(source_span ~span:call_site site) ~level
              (source_error_cause ~span:call_site descriptor)
        | [] | [ _ ] | _ :: _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"raise_at" ~arity:(Value.Exactly 2) args);
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

(* The compile-time channel of §D7. [static_log] exists so that "I want to see
   what the specializer did" never becomes a reason to fold [print], which is
   the mistake that makes compilation print and the compiled program silent.

   It is defined by where its text goes rather than by when it runs: never to
   the program's stream, always to the specialization log, which no Ash value,
   diagnostic, or equivalence claim reads. That is why running a source program
   containing one is not a difference from running its residual — the residual
   has no call left, and neither run wrote anything a trace compares.

   Its argument is {!Observation.Unobserved} because its staticness decides
   nothing: a dynamic argument is logged as the code it stands for, which is the
   useful answer at specialization time rather than a reason to refuse. *)
let compile_time log =
  let cls = Effect_class.Specialization_only in
  [
    unary ~observes:(Observation.uniform Observation.Unobserved) "static_log" cls (fun ~span:_ value ->
        Io.write log (display value ^ "\n");
        Value.Unit);
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
      (fun ~call_site ~level ~apply ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
        match args with
        | [ receiver ] ->
            (* [k] is the continuation of the [callcc] call itself, so invoking
               the reified continuation later resumes exactly what the call
               would have returned into. The level is the applying evaluator's:
               one registry serves the whole tower, so a captured continuation
               records where it came from and a reifier holding one cannot
               resume it on the wrong machine. *)
            let captured = Value.continuation ~capture:call_site ~level k in
            apply ~call_site receiver [ Value.Continuation captured ] k
        | [] | _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"callcc" ~arity:(Value.Exactly 1) args);
    (* Invoking a captured continuation by name (spec §5.2). A meta level holds
       the continuation of the level below and resumes it with a value; the
       transfer, including the one-shot check, is the ordinary application the
       applier already performs, so this is the spread of [invoke] narrowed to
       exactly one argument. The continuation it transfers to ignores the
       continuation of this call: [resume] does not return. *)
    make ~name:"resume" ~arity:(Value.Exactly 2) ~cls:Effect_class.Control
      (fun ~call_site ~level:_ ~apply ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
        match args with
        | [ cont; value ] ->
            apply ~call_site (continuation ~span:call_site cont) [ value ] k
        | [] | [ _ ] | _ :: _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"resume" ~arity:(Value.Exactly 2) args);
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
      (fun ~call_site ~level:_ ~apply ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
        match args with
        | [ callee; arguments ] ->
            apply ~call_site callee (items ~span:call_site arguments) k
        | [] | [ _ ] | _ :: _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"invoke" ~arity:(Value.Exactly 2) args);
    (* As [invoke], but the spread application is attributed to a Core node
       supplied as Code. This is the source-preserving application path used by
       the real-Code self-interpreter. *)
    make ~name:"invoke_at" ~arity:(Value.Exactly 3) ~cls:Effect_class.Control
      (fun ~call_site ~level:_ ~apply ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
        match args with
        | [ site; callee; arguments ] ->
            let call_site = source_span ~span:call_site site in
            apply ~call_site callee (items ~span:call_site arguments) k
        | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"invoke_at"
              ~arity:(Value.Exactly 3) args);
  ]

(* Evaluator-dependent operations. [lift] delegates Code construction because a
   lifted list must refer to this level's hygienic [list] global. [run] delegates
   both analysis and execution, so it cannot accidentally retain the registry's
   construction environment or its caller's lexical frame. [reflect] and
   [meta_error] delegate for a sharper reason: one registry serves every level
   (ADR 0017), so the primitive values are shared and only the applying
   evaluator knows which level is running. [up] is sugar over a reifier and the
   five [meta_*]/[tower_*] readers below. *)
(* A nullary reader of the evaluator's [meta] callback. Nullary rather than a
   name-taking [meta("eval")] so that each question is a distinct registered
   primitive with its own class and its own site in a residual program. *)
let meta_reader name query =
  make ~name ~arity:(Value.Exactly 0) ~cls:Effect_class.Reflection
    (fun ~call_site ~level:_ ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta args k ->
      match args with
      | [] -> k (meta ~call_site query)
      | _ :: _ -> wrong_arity ~span:call_site ~name ~arity:(Value.Exactly 0) args)

let reflection =
  [
    make ~name:"lift" ~arity:(Value.Exactly 1) ~cls:Effect_class.Reflection
      (fun ~call_site ~level:_ ~apply:_ ~lift ~run:_ ~reflect:_ ~meta:_ args k ->
        match args with
        | [ value ] -> k (Value.Code (lift ~call_site value))
        | [] | _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"lift" ~arity:(Value.Exactly 1) args);
    make ~name:"run" ~arity:(Value.Exactly 1) ~cls:Effect_class.Reflection
      (fun ~call_site ~level:_ ~apply:_ ~lift:_ ~run ~reflect:_ ~meta:_ args k ->
        match args with
        | [ value ] -> run ~call_site (code ~span:call_site value) k
        | [] | _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"run" ~arity:(Value.Exactly 1) args);
    (* The inverse of reifier application (spec §5.4): drop one level, evaluate
       [code] in [env] there, and transfer to a continuation captured there. The
       identity reifier is the round trip, and it must be observationally the
       identity function — the argument is evaluated once, on the level that
       wrote it, with that level's effects in that order. *)
    make ~name:"reflect" ~arity:(Value.Exactly 3) ~cls:Effect_class.Reflection
      (fun ~call_site ~level:_ ~apply:_ ~lift:_ ~run:_ ~reflect ~meta:_ args k ->
        match args with
        | [ subject; env; cont ] ->
            reflect ~call_site
              ~code:(code ~span:call_site subject)
              ~env:(environment ~span:call_site env)
              ~cont:(continuation ~span:call_site cont)
              k
        | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"reflect" ~arity:(Value.Exactly 3) args);
    (* Failing deliberately at the level that runs it. Reflection rather than
       Pure because the level is part of the result: folding it during
       specialization would report the failure at whatever level the specializer
       happened to run at, which is the same mistake D7 names for [print]. *)
    make ~name:"meta_error" ~arity:(Value.Exactly 1) ~cls:Effect_class.Reflection
      (fun ~call_site ~level ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args _k ->
        match args with
        | [ message ] ->
            Error.raise_cause ~phase:Error.Evaluate ~span:call_site ~level
              (Error.Meta_error (string ~span:call_site message))
        | [] | _ :: _ :: _ ->
            wrong_arity ~span:call_site ~name:"meta_error" ~arity:(Value.Exactly 1)
              args);
    (* The rest of [up]'s meta bindings (spec §5.2). Each is a question about the
       level below the one asking, so each is a level-crossing observation and
       none can be folded: the answer depends on which machine ran the call, and
       a specializer that answered from its own position would name the wrong
       level's evaluator.

       [meta_eval] and [meta_apply] answer with the level below's group cells
       themselves, not copies, which is what makes [eval := f] persistent: every
       dereference that level has already written reads the new value. *)
    meta_reader "meta_eval" Value.Below_eval_cell;
    meta_reader "meta_apply" Value.Below_apply_cell;
    meta_reader "meta_global" Value.Below_global_env;
    (* The level a term is being evaluated at, counted from the base program, so
       the base program always answers 0 (§D9). This is the relative numbering
       that keeps depth out of the invariance claim. *)
    make ~name:"tower_level" ~arity:(Value.Exactly 0) ~cls:Effect_class.Reflection
      (fun ~call_site ~level ~apply:_ ~lift:_ ~run:_ ~reflect:_ ~meta:_ args k ->
        match args with
        | [] -> k (Value.Num level)
        | _ :: _ ->
            wrong_arity ~span:call_site ~name:"tower_level" ~arity:(Value.Exactly 0)
              args);
    (* And the deliberate opt-in of §D9: how deep the tower actually is. A
       program that calls this is depth-sensitive by construction, which is the
       point — the collapse report can detect it syntactically instead of having
       to prove it. *)
    meta_reader "tower_depth" Value.Tower_depth;
  ]

let build io log dereferences =
  let primitives =
    pure @ mutating dereferences @ observable io @ compile_time log @ control
    @ reflection
  in
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
  log : Io.t;
      (* The specialization log: where {!Effect_class.Specialization_only}
         primitives write. A second stream rather than a tagged event in the
         first, because "the program printed nothing" has to stay a statement
         about [io] alone — a test that had to filter would be one refactor away
         from not filtering. *)
  primitives : Value.primitive list;
  dereferences : int ref;
      (* Open-recursion cell reads, which the collapse report measures against
         (§9.2). Observationally inert: no primitive reads it, so no Ash value,
         diagnostic, or output can depend on it. *)
}

let create ?io () =
  let io = match io with Some io -> io | None -> Io.create () in
  let log = Io.create () in
  let dereferences = ref 0 in
  { io; log; primitives = build io log dereferences; dereferences }

let io t = t.io
let log t = t.log
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
   implementations of the streaming primitives depend on a stream. Deriving it
   from a real registry rather than writing a second table keeps them from
   drifting apart. *)
let classification =
  List.map
    (fun primitive -> (primitive.Value.prim_name, primitive.Value.prim_class))
    (build (Io.create ()) (Io.create ()) (ref 0))

let names = List.map fst classification
let count = List.length classification
let class_of name = List.assoc_opt name classification

let by_class cls =
  List.filter_map
    (fun (name, c) -> if Effect_class.equal c cls then Some name else None)
    classification
