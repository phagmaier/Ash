open Ash_core

(* Names to identities. The parser has only strings, so this is the pass that
   makes lexical identity mean something: one [Ident.fresh] per binder, and every
   occurrence resolved through the scope rather than by comparing text later. *)

module Names = Map.Make (String)

type binding = {
  ident : Ident.t;
  assignable : bool;
      (* [var] rather than [let]. Cells are mutable either way, so nothing after
         this pass could tell the two apart; the distinction has to be decided
         here or not at all. *)
  open_cell : bool;
      (* An [open fn] group member. The identity holds the group's cell rather
         than the function, so reading the name is [open_deref] and assigning to
         it is [open_set] (spec §D3). Assignable, and deliberately so: replacing
         a group member is what a meta level does. *)
}

type scope = { lexical : binding Names.t; globals : Ident.t Names.t }

let empty_scope = { lexical = Names.empty; globals = Names.empty }

let scope_of_globals bindings =
  let add scope (name, ident) =
    if Names.mem name scope.globals then
      invalid_arg
        (Printf.sprintf "Desugar.scope_of_globals: `%s` is bound twice" name)
    else
      {
        lexical =
          Names.add name { ident; assignable = false; open_cell = false }
            scope.lexical;
        globals = Names.add name ident scope.globals;
      }
  in
  List.fold_left add empty_scope bindings

let required_primitives =
  [
    "+"; "-"; "*"; "/"; "%"; "<"; "<="; ">"; ">="; "=="; "!="; "not"; "cons";
    "list"; "empty?"; "head"; "tail"; "match_error"; "open_cell"; "open_deref";
    "open_set";
  ]

let fail ~span cause = Error.raise_cause ~phase:Error.Desugar ~span cause

let unsupported ~span what =
  fail ~span
    (Error.Unsupported
       {
         what;
         by = "the desugarer, which lowers no code construction before Phase 3";
       })

(* Provenance. A node the desugarer invents keeps the positions of the surface it
   came from and records which rewrite made it, so a diagnostic still points at
   user text while the collapse report can tell written code from emitted code. *)
let gen by node = Core.mark_generated ~by node

let by_seq = "desugar/seq"
let by_unit = "desugar/unit"
let by_fn = "desugar/fn"
let by_operator = "desugar/operator"
let by_negate = "desugar/negate"
let by_pipe = "desugar/pipe"
let by_and = "desugar/and"
let by_or = "desugar/or"
let by_list = "desugar/list"
let by_match = "desugar/match"
let by_open = "desugar/open"

let bind_name ?(open_cell = false) scope ~assignable name ident =
  { scope with lexical = Names.add name { ident; assignable; open_cell } scope.lexical }

let bind_names ?open_cell scope ~assignable pairs =
  List.fold_left
    (fun scope (name, ident) -> bind_name ?open_cell scope ~assignable name ident)
    scope pairs

(* Generated calls resolve against the globals, never the lexical scope: a
   program that binds its own [head] still gets the primitive in the code this
   module writes, and its own binding everywhere it wrote one. *)
let primitive scope ~by ~span name =
  match Names.find_opt name scope.globals with
  | Some ident -> gen by (Core.var ~span ident)
  | None -> fail ~span (Error.Unbound_name name)

let call_primitive scope ~by ~span name args =
  gen by (Core.app ~span ~func:(primitive scope ~by ~span name) ~args)

let unit_node ~by ~span = gen by (Core.lit ~span Constant.Unit)

(* One identity per binder, refusing a printed name twice in the same binder
   list: two same-named parameters would build a frame no name lookup could
   resolve, and the choice between them would be arbitrary. *)
let fresh_binders names =
  let rec go seen acc = function
    | [] -> List.rev acc
    | (name : Surface.name) :: rest ->
        if List.mem name.Surface.text seen then
          fail ~span:name.Surface.span (Error.Duplicate_binder name.Surface.text)
        else
          go (name.Surface.text :: seen)
            ((name.Surface.text, Ident.fresh name.Surface.text) :: acc)
            rest
  in
  go [] [] names

let binary_primitive = function
  | Surface.Equal -> "=="
  | Surface.Not_equal -> "!="
  | Surface.Less -> "<"
  | Surface.Less_equal -> "<="
  | Surface.Greater -> ">"
  | Surface.Greater_equal -> ">="
  | Surface.Cons -> "cons"
  | Surface.Add -> "+"
  | Surface.Subtract -> "-"
  | Surface.Multiply -> "*"
  | Surface.Divide -> "/"
  | Surface.Remainder -> "%"
  (* Handled before this table: these three are control, not calls. *)
  | Surface.Pipe_forward | Surface.Or | Surface.And ->
      invalid_arg "Desugar.binary_primitive: not a primitive operator"

(* {1 Patterns}

   Collecting binders and checking what is supported is one traversal, because
   both have to happen before a clause body can be lowered: the body is lowered
   under the pattern's binders, and an unsupported form has no binders to give
   it. *)

let unsupported_pattern (pattern : Surface.pattern) =
  match pattern.Surface.pattern_shape with
  | Surface.Constructor_pattern constructor ->
      unsupported ~span:pattern.Surface.pattern_span
        (Printf.sprintf "the `%s` pattern"
           (Surface.core_constructor_pattern_spelling constructor.Surface.constructor))
  | Surface.Quasiquote_pattern _ ->
      unsupported ~span:pattern.Surface.pattern_span "a quasiquote pattern"
  | Surface.Wildcard_pattern | Surface.Literal_pattern _ | Surface.Variable_pattern _
  | Surface.List_pattern _ | Surface.Cons_pattern _ | Surface.Alternative_pattern _
  | Surface.Group_pattern _ ->
      invalid_arg "Desugar.unsupported_pattern: this pattern is supported"

let name_set names =
  List.sort_uniq String.compare
    (List.map (fun (name : Surface.name) -> name.Surface.text) names)

(* Binders in source order, unique along every path a match can take. Repeating
   a name in one path would make the body's scope depend on which occurrence won;
   repeating it in separate alternative arms is fine, because only one arm runs.
   Every arm must bind the same set, since they share one body. *)
let rec pattern_binders (pattern : Surface.pattern) =
  match pattern.Surface.pattern_shape with
  | Surface.Wildcard_pattern | Surface.Literal_pattern _ -> []
  | Surface.Variable_pattern name -> [ name ]
  | Surface.Group_pattern inner -> pattern_binders inner
  | Surface.List_pattern patterns -> binders_of_all patterns
  | Surface.Cons_pattern cons ->
      binders_of_all [ cons.Surface.pattern_head; cons.Surface.pattern_tail ]
  | Surface.Alternative_pattern alternatives -> (
      match alternatives with
      | [] -> []
      | first :: rest ->
          let expected = pattern_binders first in
          let expected_names = name_set expected in
          List.iter
            (fun (arm : Surface.pattern) ->
              let actual = name_set (pattern_binders arm) in
              if not (List.equal String.equal expected_names actual) then
                fail ~span:arm.Surface.pattern_span
                  (Error.Inconsistent_pattern_binders
                     { expected = expected_names; actual }))
            rest;
          expected)
  | Surface.Constructor_pattern _ | Surface.Quasiquote_pattern _ ->
      unsupported_pattern pattern

and binders_of_all patterns =
  List.fold_left
    (fun collected pattern ->
      List.fold_left
        (fun collected (name : Surface.name) ->
          if
            List.exists
              (fun (seen : Surface.name) ->
                String.equal seen.Surface.text name.Surface.text)
              collected
          then fail ~span:name.Surface.span (Error.Duplicate_binder name.Surface.text)
          else collected @ [ name ])
        collected (pattern_binders pattern))
    [] patterns

let rec has_alternative (pattern : Surface.pattern) =
  match pattern.Surface.pattern_shape with
  | Surface.Alternative_pattern _ -> true
  | Surface.Wildcard_pattern | Surface.Literal_pattern _ | Surface.Variable_pattern _
    ->
      false
  | Surface.Group_pattern inner -> has_alternative inner
  | Surface.List_pattern patterns -> List.exists has_alternative patterns
  | Surface.Cons_pattern cons ->
      has_alternative cons.Surface.pattern_head
      || has_alternative cons.Surface.pattern_tail
  | Surface.Constructor_pattern constructor ->
      List.exists has_alternative constructor.Surface.constructor_arguments
  | Surface.Quasiquote_pattern _ -> false

let binder_ident ~span binders name =
  match List.assoc_opt name binders with
  | Some ident -> ident
  | None ->
      (* Unreachable for patterns [pattern_binders] has walked: an arm that binds
         a name the clause does not have is already an inconsistent alternative. *)
      fail ~span (Error.Unbound_name name)

(* {1 Expressions} *)

let rec lower scope (node : Surface.t) =
  let span = node.Surface.span in
  match node.Surface.shape with
  | Surface.Literal constant -> Core.lit ~span constant
  | Surface.Name name -> (
      match Names.find_opt name.Surface.text scope.lexical with
      (* The dereference is the whole point of [open]: a reference to a group
         member resolves at the moment it is evaluated, so replacing the cell
         intercepts the next step rather than the next top-level call. It is the
         same rewrite inside the group and after it, because a caller that held
         the old function would be a direct reference no replacement reaches. *)
      | Some { ident; open_cell = true; _ } ->
          call_primitive scope ~by:by_open ~span "open_deref"
            [ gen by_open (Core.var ~span ident) ]
      | Some { ident; open_cell = false; _ } -> Core.var ~span ident
      | None -> fail ~span (Error.Unbound_name name.Surface.text))
  | Surface.Binding _ | Surface.Named_function _ ->
      (* The parser only produces these in statement positions, where
         [lower_statements] gives them a body. *)
      fail ~span
        (Error.Unexpected { found = "a definition"; expected = "an expression" })
  | Surface.Function { Surface.params; body } ->
      let binders = fresh_binders params in
      let inner = bind_names scope ~assignable:false binders in
      Core.lam ~span ~params:(List.map snd binders) ~body:(lower inner body)
  | Surface.Call { Surface.callee; arguments } ->
      Core.app ~span ~func:(lower scope callee)
        ~args:(List.map (lower scope) arguments)
  | Surface.Block statements -> lower_statements scope ~span statements
  | Surface.Conditional { Surface.condition; consequent; alternative } ->
      Core.if_ ~span ~condition:(lower scope condition)
        ~consequent:(lower scope consequent)
        ~alternative:(lower scope alternative)
  | Surface.List_literal [] -> gen by_list (Core.lit ~span Constant.Nil)
  | Surface.List_literal items ->
      call_primitive scope ~by:by_list ~span "list" (List.map (lower scope) items)
  | Surface.Unary
      { Surface.unary_operator; unary_operator_span; unary_operand } -> (
      let operand = lower scope unary_operand in
      match unary_operator with
      | Surface.Not ->
          gen by_operator
            (Core.app ~span
               ~func:(primitive scope ~by:by_operator ~span:unary_operator_span "not")
               ~args:[ operand ])
      (* Ash has no negation primitive and no negative literals: the lexer reads
         [-] as an operator, so negation is subtraction from zero. *)
      | Surface.Negate ->
          gen by_negate
            (Core.app ~span
               ~func:(primitive scope ~by:by_negate ~span:unary_operator_span "-")
               ~args:
                 [
                   gen by_negate (Core.lit ~span:unary_operator_span (Constant.Num 0));
                   operand;
                 ]))
  | Surface.Binary
      { Surface.binary_operator; binary_operator_span; left; right } -> (
      match binary_operator with
      | Surface.Pipe_forward -> lower_pipeline scope ~span ~left ~right
      (* [If] requires a boolean, so the sugar keeps that check rather than
         answering the left operand's value. Short-circuiting is the whole
         point: the right operand is a branch, not an argument. *)
      | Surface.And ->
          gen by_and
            (Core.if_ ~span ~condition:(lower scope left)
               ~consequent:(lower scope right)
               ~alternative:
                 (gen by_and (Core.lit ~span:binary_operator_span (Constant.Bool false))))
      | Surface.Or ->
          gen by_or
            (Core.if_ ~span ~condition:(lower scope left)
               ~consequent:
                 (gen by_or (Core.lit ~span:binary_operator_span (Constant.Bool true)))
               ~alternative:(lower scope right))
      | Surface.Equal | Surface.Not_equal | Surface.Less | Surface.Less_equal
      | Surface.Greater | Surface.Greater_equal | Surface.Cons | Surface.Add
      | Surface.Subtract | Surface.Multiply | Surface.Divide | Surface.Remainder ->
          gen by_operator
            (Core.app ~span
               ~func:
                 (primitive scope ~by:by_operator ~span:binary_operator_span
                    (binary_primitive binary_operator))
               ~args:[ lower scope left; lower scope right ]))
  | Surface.Assignment
      { Surface.assignment_target; assignment_operator_span = _; assignment_value } -> (
      let name = assignment_target.Surface.text in
      match Names.find_opt name scope.lexical with
      | None -> fail ~span:assignment_target.Surface.span (Error.Unbound_name name)
      | Some { assignable = false; _ } ->
          fail ~span:assignment_target.Surface.span (Error.Immutable_binding name)
      | Some { ident; assignable = true; open_cell = true } ->
          (* Replacing a group member. [Set] would rebind the name that holds the
             cell; what is wanted is to write through it, so that every
             dereference already written sees the replacement. *)
          call_primitive scope ~by:by_open ~span "open_set"
            [ gen by_open (Core.var ~span ident); lower scope assignment_value ]
      | Some { ident; assignable = true; open_cell = false } ->
          Core.set ~span ~target:ident ~value:(lower scope assignment_value))
  | Surface.Group inner -> lower scope inner
  | Surface.Match { Surface.scrutinee; clauses } ->
      lower_match scope ~span ~scrutinee ~clauses
  | Surface.Quote _ -> unsupported ~span "a quotation"
  | Surface.Splice _ -> unsupported ~span "a splice"

(* [x |> f(a)] is [f(x, a)]: the piped value becomes the first argument of a call
   written at the right. Anything else — including a parenthesized call — is
   applied to the piped value alone, which is how [x |> (f(a))] asks for the
   result of [f(a)] to be the function. *)
and lower_pipeline scope ~span ~left ~right =
  let piped = lower scope left in
  match right.Surface.shape with
  | Surface.Call { Surface.callee; arguments } ->
      gen by_pipe
        (Core.app ~span ~func:(lower scope callee)
           ~args:(piped :: List.map (lower scope) arguments))
  | Surface.Literal _ | Surface.Name _ | Surface.Binding _ | Surface.Named_function _
  | Surface.Function _ | Surface.Block _ | Surface.Conditional _
  | Surface.List_literal _ | Surface.Unary _ | Surface.Binary _ | Surface.Assignment _
  | Surface.Group _ | Surface.Match _ | Surface.Quote _ | Surface.Splice _ ->
      gen by_pipe (Core.app ~span ~func:(lower scope right) ~args:[ piped ])

(* {1 Statements}

   A statement list is a right-nested chain of [Let]s. Definitions bind for the
   rest of the list, everything else is sequenced through a binder nothing
   mentions, and a list ending in a definition evaluates to unit so that a file
   of definitions is a program. *)
and lower_statements scope ~span statements =
  match statements with
  | [] -> unit_node ~by:by_unit ~span
  | { Surface.shape = Surface.Named_function first; _ } :: _ ->
      let open_group = first.Surface.function_open in
      let group, rest = take_functions ~open_group [] statements in
      lower_function_group scope ~span ~open_group ~group ~rest
  | { Surface.shape = Surface.Binding binding; span = statement_span } :: rest ->
      let name = binding.Surface.binder.Surface.text in
      let ident = Ident.fresh name in
      let assignable =
        match binding.Surface.binding_kind with
        | Surface.Mutable -> true
        | Surface.Immutable -> false
      in
      let value = lower scope binding.Surface.binding_value in
      let inner = bind_name scope ~assignable name ident in
      Core.let_ ~span:statement_span ~binder:ident ~value
        ~body:(lower_rest inner ~span ~after:statement_span rest)
  | [ single ] -> lower scope single
  | statement :: rest ->
      let statement_span = statement.Surface.span in
      gen by_seq
        (Core.let_ ~span:statement_span ~binder:(Ident.fresh "_")
           ~value:(lower scope statement)
           ~body:(lower_statements scope ~span rest))

(* The body of a definition's [Let] or [LetRec]: the rest of the list, or unit
   when the definition was last. *)
and lower_rest scope ~span ~after statements =
  match statements with
  | [] -> unit_node ~by:by_unit ~span:after
  | _ :: _ -> lower_statements scope ~span statements

(* A run of adjacent definitions of the same kind. An [open fn] and a plain [fn]
   are different binding forms, so a run of one ends where the other begins
   rather than the two silently sharing a group. *)
and take_functions ~open_group collected statements =
  match statements with
  | ({ Surface.shape = Surface.Named_function definition; _ } as statement) :: rest
    when Bool.equal definition.Surface.function_open open_group ->
      take_functions ~open_group (statement :: collected) rest
  | ([] | { Surface.shape = _; _ } :: _) as rest -> (List.rev collected, rest)

(* Adjacent [fn] declarations are one recursive group, so mutual recursion needs
   no separate syntax. Their names are in scope in every body, including their
   own. Adjacent [open fn] declarations are one open-recursive group instead:
   same scoping, but the names denote cells (spec §D3). *)
and lower_function_group scope ~span ~open_group ~group ~rest =
  let definitions =
    List.map
      (fun (statement : Surface.t) ->
        match statement.Surface.shape with
        | Surface.Named_function definition -> (statement.Surface.span, definition)
        | Surface.Literal _ | Surface.Name _ | Surface.Binding _ | Surface.Function _
        | Surface.Call _ | Surface.Block _ | Surface.Conditional _
        | Surface.List_literal _ | Surface.Unary _ | Surface.Binary _
        | Surface.Assignment _ | Surface.Group _ | Surface.Match _ | Surface.Quote _
        | Surface.Splice _ ->
            invalid_arg "Desugar.lower_function_group: not a named function")
      group
  in
  let names =
    List.map
      (fun (_, definition) -> definition.Surface.function_name)
      definitions
  in
  let binders = fresh_binders names in
  let group_span =
    match definitions with
    | [] -> span
    | (first, _) :: _ ->
        List.fold_left
          (fun accumulated (definition_span, _) -> Span.join accumulated definition_span)
          first definitions
  in
  if open_group then
    lower_open_group scope ~span ~definitions ~binders ~group_span ~rest
  else
    let inner = bind_names scope ~assignable:false binders in
    let bindings =
      List.map2
        (fun (definition_span, definition) (_, ident) ->
          let params = fresh_binders definition.Surface.function_params in
          let body_scope = bind_names inner ~assignable:false params in
          let lambda =
            Core.lambda ~params:(List.map snd params)
              ~body:(lower body_scope definition.Surface.function_body)
          in
          Core.rec_binding ~span:definition_span ~name:ident lambda)
        definitions binders
    in
    gen by_fn
      (Core.letrec ~span:group_span ~bindings
         ~body:(lower_rest inner ~span ~after:group_span rest))

(* An open group is not a [LetRec]: the binder holds the group member's cell, not
   the member. Allocate every cell, fill each with its lambda, then run the rest,
   all of it under a scope in which the group's names read and write through
   those cells. Evaluating a lambda calls nothing, so no cell is dereferenced
   while it still holds the placeholder — the same argument that makes [LetRec]'s
   preallocation total. *)
and lower_open_group scope ~span ~definitions ~binders ~group_span ~rest =
  let inner = bind_names ~open_cell:true scope ~assignable:true binders in
  let after = lower_rest inner ~span ~after:group_span rest in
  let filled =
    List.fold_right2
      (fun (definition_span, definition) (_, ident) body ->
        let params = fresh_binders definition.Surface.function_params in
        let body_scope = bind_names inner ~assignable:false params in
        let lambda =
          Core.lam ~span:definition_span ~params:(List.map snd params)
            ~body:(lower body_scope definition.Surface.function_body)
        in
        gen by_open
          (Core.let_ ~span:definition_span ~binder:(Ident.fresh "_")
             ~value:
               (call_primitive inner ~by:by_open ~span:definition_span "open_set"
                  [ gen by_open (Core.var ~span:definition_span ident); lambda ])
             ~body))
      definitions binders after
  in
  List.fold_right2
    (fun (definition_span, _) (_, ident) body ->
      gen by_open
        (Core.let_ ~span:definition_span ~binder:ident
           ~value:
             (call_primitive scope ~by:by_open ~span:definition_span "open_cell"
                [ unit_node ~by:by_open ~span:definition_span ])
           ~body))
    definitions binders filled

(* {1 Match}

   Clauses are tried in order. Each one's failure continuation is a thunk holding
   the clauses after it, so the term a test falls through to is always a nullary
   call: a pattern may mention its failure several times without the remaining
   clauses being copied once per mention. The chain ends in [match_error], since
   a match that runs out of clauses must fail rather than answer unit. *)
and lower_match scope ~span ~scrutinee ~clauses =
  let subject = Ident.fresh "scrutinee" in
  let rec remaining = function
    | [] ->
        call_primitive scope ~by:by_match ~span "match_error"
          [ gen by_match (Core.var ~span subject) ]
    | (clause : Surface.match_clause) :: rest ->
        let clause_span = clause.Surface.clause_span in
        let next = Ident.fresh "next_clause" in
        let failure =
          gen by_match
            (Core.app ~span:clause_span
               ~func:(gen by_match (Core.var ~span:clause_span next))
               ~args:[])
        in
        gen by_match
          (Core.let_ ~span:clause_span ~binder:next
             ~value:
               (gen by_match
                  (Core.lam ~span:clause_span ~params:[] ~body:(remaining rest)))
             ~body:(lower_clause scope ~subject ~failure clause))
  in
  gen by_match
    (Core.let_ ~span ~binder:subject ~value:(lower scope scrutinee)
       ~body:(remaining clauses))

and lower_clause scope ~subject ~failure (clause : Surface.match_clause) =
  let pattern = clause.Surface.clause_pattern in
  let clause_span = clause.Surface.clause_span in
  let names = pattern_binders pattern in
  (* The identities the test binds. One set for the whole clause, reused by every
     alternative arm: the arms are separate branches, so binding the same
     identity in each is not a repeated binder. *)
  let bound = List.map (fun (name : Surface.name) -> (name.Surface.text, Ident.fresh name.Surface.text)) names in
  if has_alternative pattern then
    (* The body is shared by every arm, so it becomes a function of the clause's
       binders and each arm calls it. Inlining it instead would copy the body
       once per arm. *)
    let parameters =
      List.map (fun (name : Surface.name) -> (name.Surface.text, Ident.fresh name.Surface.text)) names
    in
    let body_scope = bind_names scope ~assignable:false parameters in
    let body = Ident.fresh "clause_body" in
    let success =
      gen by_match
        (Core.app ~span:clause_span
           ~func:(gen by_match (Core.var ~span:clause_span body))
           ~args:
             (List.map
                (fun (_, ident) -> gen by_match (Core.var ~span:clause_span ident))
                bound))
    in
    gen by_match
      (Core.let_ ~span:clause_span ~binder:body
         ~value:
           (gen by_match
              (Core.lam ~span:clause_span
                 ~params:(List.map snd parameters)
                 ~body:(lower body_scope clause.Surface.clause_body)))
         ~body:
           (lower_pattern scope ~binders:bound ~subject ~success ~failure pattern))
  else
    let body_scope = bind_names scope ~assignable:false bound in
    let success = lower body_scope clause.Surface.clause_body in
    lower_pattern scope ~binders:bound ~subject ~success ~failure pattern

(* [subject] is an identity rather than a term so that a test can mention the
   value it is matching as often as it needs to without duplicating work. *)
and lower_pattern scope ~binders ~subject ~success ~failure (pattern : Surface.pattern) =
  let span = pattern.Surface.pattern_span in
  let subject_var () = gen by_match (Core.var ~span subject) in
  let prim name args = call_primitive scope ~by:by_match ~span name args in
  match pattern.Surface.pattern_shape with
  | Surface.Wildcard_pattern -> success
  | Surface.Group_pattern inner ->
      lower_pattern scope ~binders ~subject ~success ~failure inner
  | Surface.Variable_pattern name ->
      let ident = binder_ident ~span binders name.Surface.text in
      gen by_match
        (Core.let_ ~span ~binder:ident ~value:(subject_var ()) ~body:success)
  | Surface.Literal_pattern constant ->
      gen by_match
        (Core.if_ ~span
           ~condition:(prim "==" [ subject_var (); gen by_match (Core.lit ~span constant) ])
           ~consequent:success ~alternative:failure)
  | Surface.Cons_pattern cons ->
      lower_nonempty scope ~binders ~subject ~span ~failure
        ~head:cons.Surface.pattern_head
        ~tail:(fun ~subject ~success ->
          lower_pattern scope ~binders ~subject ~success ~failure
            cons.Surface.pattern_tail)
        ~success
  | Surface.List_pattern items ->
      lower_list_pattern scope ~binders ~subject ~span ~failure ~success items
  | Surface.Alternative_pattern alternatives ->
      let rec arms = function
        | [] -> failure
        | [ last ] -> lower_pattern scope ~binders ~subject ~success ~failure last
        | arm :: rest ->
            let next = Ident.fresh "next_alternative" in
            let arm_failure =
              gen by_match
                (Core.app ~span ~func:(gen by_match (Core.var ~span next)) ~args:[])
            in
            gen by_match
              (Core.let_ ~span ~binder:next
                 ~value:(gen by_match (Core.lam ~span ~params:[] ~body:(arms rest)))
                 ~body:
                   (lower_pattern scope ~binders ~subject ~success ~failure:arm_failure
                      arm))
      in
      arms alternatives
  | Surface.Constructor_pattern _ | Surface.Quasiquote_pattern _ ->
      unsupported_pattern pattern

(* A list pattern is a cons chain that ends by requiring the rest to be empty. *)
and lower_list_pattern scope ~binders ~subject ~span ~failure ~success items =
  match items with
  | [] ->
      gen by_match
        (Core.if_ ~span
           ~condition:
             (call_primitive scope ~by:by_match ~span "empty?"
                [ gen by_match (Core.var ~span subject) ])
           ~consequent:success ~alternative:failure)
  | item :: rest ->
      lower_nonempty scope ~binders ~subject ~span ~failure ~head:item
        ~tail:(fun ~subject ~success ->
          lower_list_pattern scope ~binders ~subject ~span ~failure ~success rest)
        ~success

(* The shape both cons and list patterns share: refuse the empty list, then match
   the head and the tail. [head] and [tail] run only under the [empty?] test, so
   neither can fail. *)
and lower_nonempty scope ~binders ~subject ~span ~failure ~head ~tail ~success =
  let subject_var () = gen by_match (Core.var ~span subject) in
  let prim name args = call_primitive scope ~by:by_match ~span name args in
  let head_ident = Ident.fresh "head" in
  let tail_ident = Ident.fresh "tail" in
  let matched =
    gen by_match
      (Core.let_ ~span ~binder:head_ident ~value:(prim "head" [ subject_var () ])
         ~body:
           (gen by_match
              (Core.let_ ~span ~binder:tail_ident ~value:(prim "tail" [ subject_var () ])
                 ~body:
                   (lower_pattern scope ~binders ~subject:head_ident
                      ~success:(tail ~subject:tail_ident ~success)
                      ~failure head))))
  in
  gen by_match
    (Core.if_ ~span
       ~condition:(prim "empty?" [ subject_var () ])
       ~consequent:failure ~alternative:matched)

let expression ?(scope = empty_scope) (node : Surface.t) =
  lower_statements scope ~span:node.Surface.span [ node ]

let program ?(scope = empty_scope) statements =
  let span =
    match statements with
    | [] -> Span.unknown
    | first :: rest ->
        List.fold_left
          (fun accumulated (statement : Surface.t) ->
            Span.join accumulated statement.Surface.span)
          first.Surface.span rest
  in
  lower_statements scope ~span statements
