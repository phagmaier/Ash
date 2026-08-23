type value =
  | Num of int
  | Bool of bool
  | Str of string
  | Sym of string
  | Unit
  | List of value list
  | Closure of closure
  | Reifier of reifier
  | Continuation of continuation
  | Environment of env
  | Cell of cell
  | Code of Core.t
  | Primitive of primitive

and answer = value

and closure = {
  clo_lambda : Core.lambda;
  clo_env : env;
  clo_name : Ident.t option;
}

and reifier = { reif_def : Core.reifier; reif_env : env; reif_name : Ident.t option }

and continuation = {
  cont_invoke : value -> answer;
  mutable cont_used : bool;
  cont_capture : Span.t;
  cont_level : int;
  mutable cont_first_use : Span.t option;
}

and env = frame list
and frame = { bindings : cell Ident.Map.t }
and cell = { mutable contents : value option }

and primitive = {
  prim_name : string;
  prim_arity : arity;
  prim_class : Effect_class.t;
  prim_impl : call_site:Span.t -> apply:applier -> value list -> (value -> answer) -> answer;
}

and applier = call_site:Span.t -> value -> value list -> (value -> answer) -> answer
and arity = Exactly of int | At_least of int

(* Constants *)

let of_constant = function
  | Constant.Num n -> Num n
  | Constant.Bool b -> Bool b
  | Constant.Str s -> Str s
  | Constant.Sym s -> Sym s
  | Constant.Unit -> Unit
  | Constant.Nil -> List []

let to_constant = function
  | Num n -> Some (Constant.Num n)
  | Bool b -> Some (Constant.Bool b)
  | Str s -> Some (Constant.Str s)
  | Sym s -> Some (Constant.Sym s)
  | Unit -> Some Constant.Unit
  | List [] -> Some Constant.Nil
  | List (_ :: _) | Closure _ | Reifier _ | Continuation _ | Environment _ | Cell _
  | Code _ | Primitive _ ->
      None

(* Cells *)

let cell value = { contents = Some value }
let preallocated_cell () = { contents = None }
let cell_contents c = c.contents
let is_filled c = Option.is_some c.contents
let fill_cell c value = c.contents <- Some value
let same_cell a b = a == b

(* Continuations *)

let continuation ~capture ~level invoke =
  {
    cont_invoke = invoke;
    cont_used = false;
    cont_capture = capture;
    cont_level = level;
    cont_first_use = None;
  }

let continuation_used k = k.cont_used
let continuation_capture_site k = k.cont_capture
let continuation_level k = k.cont_level
let continuation_first_use k = k.cont_first_use

let mark_continuation_used k ~at =
  (* The first-use site is evidence for the reuse diagnostic, so it is written
     once and never overwritten by a later attempt. *)
  if not k.cont_used then (
    k.cont_used <- true;
    k.cont_first_use <- Some at)

(* Environments *)

let empty_env : env = []

let frame_of_list bindings =
  (* A duplicate identity would silently drop a binding, so it is a host bug
     rather than something to resolve by last-one-wins. Repeated printed names
     are fine; repeated identities are not. *)
  let add map (ident, cell) =
    if Ident.Map.mem ident map then
      invalid_arg
        (Printf.sprintf "Value.frame_of_list: duplicate binder %s"
           (Ident.to_string ident));
    Ident.Map.add ident cell map
  in
  { bindings = List.fold_left add Ident.Map.empty bindings }

let push_frame frame env = frame :: env

(* Arities *)

let arity_matches arity count =
  match arity with
  | Exactly n -> Int.equal count n
  | At_least n -> count >= n

let arity_to_string = function
  | Exactly n -> string_of_int n
  | At_least n -> Printf.sprintf "at least %d" n

(* Description *)

let type_name = function
  | Num _ -> "number"
  | Bool _ -> "boolean"
  | Str _ -> "string"
  | Sym _ -> "symbol"
  | Unit -> "unit"
  | List _ -> "list"
  | Closure _ -> "closure"
  | Reifier _ -> "reifier"
  | Continuation _ -> "continuation"
  | Environment _ -> "environment"
  | Cell _ -> "cell"
  | Code _ -> "code"
  | Primitive _ -> "primitive"

let type_phrase = function
  | Num _ -> "a number"
  | Bool _ -> "a boolean"
  | Str _ -> "a string"
  | Sym _ -> "a symbol"
  | Unit -> "unit"
  | List [] -> "the empty list"
  | List (_ :: _) -> "a list"
  | Closure _ -> "a closure"
  | Reifier _ -> "a reifier"
  | Continuation _ -> "a continuation"
  | Environment _ -> "an environment"
  | Cell _ -> "a cell"
  | Code _ -> "code"
  | Primitive _ -> "a primitive"

let rec equal a b =
  match (a, b) with
  | Num x, Num y -> Int.equal x y
  | Bool x, Bool y -> Bool.equal x y
  | Str x, Str y -> String.equal x y
  | Sym x, Sym y -> String.equal x y
  | Unit, Unit -> true
  | List x, List y -> List.equal equal x y
  (* Identity, not structure: two closures with the same body are two closures,
     and two cells with the same contents are two places. *)
  | Closure x, Closure y -> x == y
  | Reifier x, Reifier y -> x == y
  | Continuation x, Continuation y -> x == y
  | Environment x, Environment y -> x == y
  | Cell x, Cell y -> same_cell x y
  | Code x, Code y -> Alpha.equal x y
  | Primitive x, Primitive y -> String.equal x.prim_name y.prim_name
  | ( ( Num _ | Bool _ | Str _ | Sym _ | Unit | List _ | Closure _ | Reifier _
      | Continuation _ | Environment _ | Cell _ | Code _ | Primitive _ ),
      _ ) ->
      false

let named prefix = function
  | None -> Printf.sprintf "#<%s>" prefix
  | Some ident -> Printf.sprintf "#<%s %s>" prefix (Ident.name ident)

let rec to_string = function
  | Num n -> Constant.to_string (Constant.Num n)
  | Bool b -> Constant.to_string (Constant.Bool b)
  | Str s -> Constant.to_string (Constant.Str s)
  | Sym s -> Constant.to_string (Constant.Sym s)
  | Unit -> Constant.to_string Constant.Unit
  | List items -> "[" ^ String.concat ", " (List.map to_string items) ^ "]"
  | Closure { clo_name; _ } -> named "closure" clo_name
  | Reifier { reif_name; _ } -> named "reifier" reif_name
  | Continuation k ->
      if k.cont_used then "#<continuation used>" else "#<continuation>"
  | Environment env -> Printf.sprintf "#<env %d frames>" (List.length env)
  | Cell c -> if is_filled c then "#<cell>" else "#<cell unfilled>"
  | Code core -> Printf.sprintf "#<code %s>" (Core.kind_name core)
  | Primitive { prim_name; prim_arity; _ } ->
      Printf.sprintf "#<primitive %s/%s>" prim_name (arity_to_string prim_arity)

let pp formatter value = Format.pp_print_string formatter (to_string value)
