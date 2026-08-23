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

let make name arity impl =
  {
    Value.prim_name = name;
    prim_arity = arity;
    prim_class = Effect_class.Pure;
    prim_impl = impl;
  }

let unary name impl =
  let arity = Value.Exactly 1 in
  make name arity (fun ~call_site args k ->
      match args with
      | [ a ] -> k (impl ~span:call_site a)
      | [] | _ :: _ :: _ -> wrong_arity ~span:call_site ~name ~arity args)

let binary name impl =
  let arity = Value.Exactly 2 in
  make name arity (fun ~call_site args k ->
      match args with
      | [ a; b ] -> k (impl ~span:call_site a b)
      | [] | [ _ ] | _ :: _ :: _ :: _ -> wrong_arity ~span:call_site ~name ~arity args)

(* Arguments are checked left to right, in the order Ash evaluates them, so a
   call with two bad arguments reports the first one. *)
let numeric name combine =
  binary name (fun ~span a b ->
      let x = number ~span a in
      let y = number ~span b in
      combine ~span x y)

let arithmetic name f = numeric name (fun ~span:_ x y -> Value.Num (f x y))

let dividing name f =
  numeric name (fun ~span x y ->
      if y = 0 then fail ~span Error.Division_by_zero else Value.Num (f x y))

let ordering name f = numeric name (fun ~span:_ x y -> Value.Bool (f (Int.compare x y) 0))

let all =
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
    binary "==" (fun ~span:_ a b -> Value.Bool (Value.equal a b));
    binary "!=" (fun ~span:_ a b -> Value.Bool (not (Value.equal a b)));
    unary "not" (fun ~span a -> Value.Bool (not (boolean ~span a)));
    binary "cons" (fun ~span a b -> Value.List (a :: items ~span b));
    unary "head" (fun ~span a -> fst (non_empty ~span a));
    unary "tail" (fun ~span a -> Value.List (snd (non_empty ~span a)));
    unary "empty?" (fun ~span a -> Value.Bool (items ~span a = []));
    unary "length" (fun ~span a -> Value.Num (List.length (items ~span a)));
    (let arity = Value.At_least 0 in
     make "list" arity (fun ~call_site:_ args k -> k (Value.List args)));
  ]

let names = List.map (fun primitive -> primitive.Value.prim_name) all

let find name =
  List.find_opt (fun primitive -> String.equal primitive.Value.prim_name name) all

let globals () =
  List.map
    (fun primitive ->
      (Ident.fresh primitive.Value.prim_name, Value.Primitive primitive))
    all
