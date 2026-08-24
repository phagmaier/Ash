open Ash_core

type projection =
  | Known of Value.value
  | Held of Value.value
  | Unknown

type key = {
  fn_lambda : Core.lambda;
  fn_env : Value.env;
  arguments : projection list;
}

type point = {
  residual : Ident.t;
  point_key : key;
}

(* Where a call was when the unroller started following it: the blocks that were
   open, the specialization-point scopes that were visible, and the calls that
   were already being inlined. Committing a specialization point reinstalls this
   context, so the residual function is bound where its call began rather than
   wherever the cycle happened to be noticed. *)
type context = {
  buffers : Emit.stack;
  scopes : point list ref list;
  actives : entry list;
}

and entry = {
  entry_key : key;
  entry_arguments : Value.value list;
  entry_context : context;
}

let project value =
  if Stage_value.is_dynamic value then Unknown
  else if Stage_value.is_purely_static value then Known value
  else Held value

let arguments k = k.arguments

let is_parameter = function
  | Unknown -> true
  | Known _ | Held _ -> false

let parameter_count k = List.length (List.filter is_parameter k.arguments)

(* Two projections describe the same specialization when the specializer knows
   the same thing about the argument.

   [Known] compares by value: two structurally equal fully static arguments make
   the same specialized body, and closures inside them compare by identity
   because that is what closure equality means (§D1).

   [Held] is a value the specializer holds whose contents are partially dynamic
   — a list with a known spine and unknown elements. Its dynamic parts are
   residual expressions, so only the very same value is the same argument;
   structural comparison would call two different partially static lists equal
   and tie a knot that is not there.

   [Unknown] is code: the argument becomes a parameter of the residual function,
   so the two calls agree about it precisely by both knowing nothing. *)
let same_projection a b =
  match (a, b) with
  | Known x, Known y -> Value.equal x y
  | Held x, Held y -> x == y
  | Unknown, Unknown -> true
  | (Known _ | Held _ | Unknown), _ -> false

(* Function identity is the lambda together with the environment it closed over:
   a [LetRec]-bound function dereferences one cell holding one closure, so the
   recursive call really is the same function, while two closures over the same
   lambda with different captures are two functions. *)
let same_key a b =
  a.fn_lambda == b.fn_lambda
  && a.fn_env == b.fn_env
  && List.compare_lengths a.arguments b.arguments = 0
  && List.for_all2 same_projection a.arguments b.arguments

(* {1 Budgets and generalization (spec §7.5)} *)

type budget = {
  max_inline_depth : int;
  max_residual_bindings : int;
}

(* The corpus's deepest static unrolling is a 10,000-step tail-recursive loop
   that folds to a literal and emits nothing, so both defaults are set to leave
   it — and everything smaller — alone. A budget that generalized a program the
   specializer could have decided would make every collapse result weaker for no
   reason: §7.5's own argument is that collapsing without generalizing is the
   stronger result. These are the sizes at which the specializer stops believing
   it is making progress, not sizes it is expected to reach. *)
let default_budget = { max_inline_depth = 25_000; max_residual_bindings = 50_000 }

let current_budget = ref default_budget
let budget () = !current_budget
let set_budget b =
  if b.max_inline_depth < 1 then invalid_arg "Specialize.set_budget: depth must be positive";
  if b.max_residual_bindings < 0 then
    invalid_arg "Specialize.set_budget: binding limit must not be negative";
  current_budget := b

type pressure =
  | Inline_depth of int
  | Residual_size of int

let pressure_name = function
  | Inline_depth _ -> "inlining-depth"
  | Residual_size _ -> "residual-size"

let pressure_limit = function
  | Inline_depth limit | Residual_size limit -> limit

let pressure_message p =
  match p with
  | Inline_depth limit ->
      Printf.sprintf "%d nested calls to it were already being inlined" limit
  | Residual_size limit ->
      Printf.sprintf "specialization had already emitted %d residual bindings" limit

type generalization = {
  gen_function : string;
  gen_parameter : string;
  gen_position : int;
  gen_pressure : pressure;
  gen_site : Span.t;
}

(* Which argument positions of one function are forced dynamic. Keyed by the
   function's identity and sticky for the run: a generalization that applied
   only to the call that triggered it would be undone by the next call, and the
   unrolling would resume. *)
type generalized = {
  gen_lambda : Core.lambda;
  gen_env : Value.env;
  mutable positions : int list;
}

type state = {
  mutable scopes : point list ref list;
  mutable active : entry list;
  mutable points : int;
  mutable calls : int;
  mutable forced : generalized list;
  mutable log : generalization list;
  mutable reifying : int;
}

let state =
  {
    scopes = [];
    active = [];
    points = 0;
    calls = 0;
    forced = [];
    log = [];
    reifying = 0;
  }

let reset () =
  state.scopes <- [];
  state.active <- [];
  state.points <- 0;
  state.calls <- 0;
  state.forced <- [];
  state.log <- [];
  state.reifying <- 0;
  Emit.reset_counts ()

(* Reifying a closure specializes its body, which may reify further closures.
   That nesting is not a call and has no key, so the depth budget is the only
   thing bounding it. *)
let reification_depth () = state.reifying

let with_reification f =
  state.reifying <- state.reifying + 1;
  Fun.protect f ~finally:(fun () -> state.reifying <- state.reifying - 1)

let points_created () = state.points
let memoized_calls () = state.calls
let generalizations () = List.rev state.log
let generalization_count () = List.length state.log

let forced_entry ~lambda ~env =
  List.find_opt
    (fun forced -> forced.gen_lambda == lambda && forced.gen_env == env)
    state.forced

let forced_positions ~lambda ~env =
  match forced_entry ~lambda ~env with
  | Some forced -> forced.positions
  | None -> []

(* The key a call is specialized under. Positions this function has already been
   generalized on are forced dynamic even when the specializer does know their
   value: that is what makes a generalization stick, and what makes the next
   call round to a key the memo table already holds. *)
let key ~lambda ~env ~arguments =
  let forced = forced_positions ~lambda ~env in
  {
    fn_lambda = lambda;
    fn_env = env;
    arguments =
      List.mapi
        (fun index argument ->
          if List.mem index forced then Unknown else project argument)
        arguments;
  }

(* How deep the unroller already is in this same function. Depth is counted per
   function rather than overall, so a program that nests many different
   functions is not mistaken for one that is going nowhere. *)
let inline_depth k =
  List.length
    (List.filter
       (fun entry ->
         entry.entry_key.fn_lambda == k.fn_lambda
         && entry.entry_key.fn_env == k.fn_env)
       state.active)

let pressure_of k =
  let b = !current_budget in
  if inline_depth k >= b.max_inline_depth then Some (Inline_depth b.max_inline_depth)
  else if Emit.emitted_count () >= b.max_residual_bindings then
    Some (Residual_size b.max_residual_bindings)
  else None

(* Which argument to give up on first.

   The unrolling is driven by whatever changed between this call and the nearest
   enclosing call to the same function, so those positions are the candidates,
   left to right. When nothing changed — the budget was reached for some other
   reason — any position the specializer still knows will do, and leftmost is as
   good a rule as any. Positions already dynamic are not candidates: there is
   nothing left to give up there. *)
let next_position k =
  let known =
    List.filteri
      (fun index _ -> not (is_parameter (List.nth k.arguments index)))
      (List.init (List.length k.arguments) Fun.id)
  in
  match known with
  | [] -> None
  | _ :: _ -> (
      let ancestor =
        List.find_opt
          (fun entry ->
            entry.entry_key.fn_lambda == k.fn_lambda
            && entry.entry_key.fn_env == k.fn_env)
          state.active
      in
      let differing =
        match ancestor with
        | None -> []
        | Some entry ->
            List.filter
              (fun index ->
                index < List.length entry.entry_key.arguments
                && not
                     (same_projection
                        (List.nth k.arguments index)
                        (List.nth entry.entry_key.arguments index)))
              known
      in
      match differing with
      | index :: _ -> Some index
      | [] -> Some (List.hd known))

let generalize k ~callee ~parameters ~site pressure =
  match next_position k with
  | None -> None
  | Some position ->
      (match forced_entry ~lambda:k.fn_lambda ~env:k.fn_env with
      | Some forced -> forced.positions <- position :: forced.positions
      | None ->
          state.forced <-
            { gen_lambda = k.fn_lambda; gen_env = k.fn_env; positions = [ position ] }
            :: state.forced);
      let parameter =
        match List.nth_opt parameters position with
        | Some ident -> Ident.name ident
        | None -> string_of_int position
      in
      state.log <-
        {
          gen_function = Option.value callee ~default:"an anonymous function";
          gen_parameter = parameter;
          gen_position = position;
          gen_pressure = pressure;
          gen_site = site;
        }
        :: state.log;
      Some
        {
          k with
          arguments =
            List.mapi
              (fun index projection ->
                if index = position then Unknown else projection)
              k.arguments;
        }

let lookup k =
  List.find_map
    (fun scope -> List.find_opt (fun point -> same_key point.point_key k) !scope)
    state.scopes

let active_entry k =
  List.find_opt (fun entry -> same_key entry.entry_key k) state.active

let entry_arguments entry = entry.entry_arguments

let define k residual =
  match state.scopes with
  | [] ->
      invalid_arg "Specialize.define: a specialization point needs a scope"
  | scope :: _ ->
      let point = { residual; point_key = k } in
      scope := point :: !scope;
      state.points <- state.points + 1;
      point

let count_call () = state.calls <- state.calls + 1
let active () = state.active

let enter k ~arguments =
  let entry =
    {
      entry_key = k;
      entry_arguments = arguments;
      entry_context =
        {
          buffers = Emit.stack ();
          scopes = state.scopes;
          actives = state.active;
        };
    }
  in
  state.active <- entry :: state.active

let restore saved = state.active <- saved

(* A specialization point is bound by a [LetRec] in the block that created it,
   so it is only reusable while that block is still open. Dropping the scope on
   the way out is what keeps a residual function from being called where its
   binding is not in scope — the two branches of a dynamic conditional each get
   their own. *)
let in_scope f =
  let scope = ref [] in
  state.scopes <- scope :: state.scopes;
  Fun.protect f ~finally:(fun () ->
      match state.scopes with
      | [] -> ()
      | _ :: rest -> state.scopes <- rest)

let with_entry_context entry f =
  let saved_scopes = state.scopes and saved_active = state.active in
  state.scopes <- entry.entry_context.scopes;
  state.active <- entry.entry_context.actives;
  Fun.protect
    ~finally:(fun () ->
      state.scopes <- saved_scopes;
      state.active <- saved_active)
    (fun () -> Emit.with_stack entry.entry_context.buffers f)

let residual_name point = point.residual
