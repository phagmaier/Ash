open Ash_core

let parenthesized head parts =
  match parts with
  | [] -> "(" ^ head ^ ")"
  | _ -> "(" ^ head ^ " " ^ String.concat " " parts ^ ")"

let name_list names =
  parenthesized "params" (List.map (fun (name : Surface.name) -> name.text) names)

let rec to_string expression =
  match expression.Surface.shape with
  | Surface.Literal constant -> Constant.to_string constant
  | Surface.Name name -> name.text
  | Surface.Binding binding ->
      parenthesized
        (match binding.binding_kind with Surface.Immutable -> "let" | Surface.Mutable -> "var")
        [ binding.binder.text; to_string binding.binding_value ]
  | Surface.Named_function function_ ->
      parenthesized "fn"
        [ function_.function_name.text; name_list function_.function_params;
          to_string function_.function_body ]
  | Surface.Function function_ ->
      parenthesized "fn" [ name_list function_.params; to_string function_.body ]
  | Surface.Call call ->
      parenthesized "call" (to_string call.callee :: List.map to_string call.arguments)
  | Surface.Block statements -> parenthesized "block" (List.map to_string statements)
  | Surface.Conditional conditional ->
      parenthesized "if"
        [ to_string conditional.condition; to_string conditional.consequent;
          to_string conditional.alternative ]
  | Surface.List_literal items -> parenthesized "list" (List.map to_string items)
  | Surface.Unary unary ->
      parenthesized (Surface.unary_operator_spelling unary.unary_operator)
        [ to_string unary.unary_operand ]
  | Surface.Binary binary ->
      parenthesized (Surface.binary_operator_spelling binary.binary_operator)
        [ to_string binary.left; to_string binary.right ]
  | Surface.Assignment assignment ->
      parenthesized ":="
        [ assignment.assignment_target.text; to_string assignment.assignment_value ]
  | Surface.Group grouped -> parenthesized "group" [ to_string grouped ]
  | Surface.Match match_ ->
      parenthesized "match"
        (to_string match_.scrutinee
        :: List.map
             (fun clause ->
               parenthesized "clause"
                 [ pattern_to_string clause.Surface.clause_pattern;
                   to_string clause.Surface.clause_body ])
             match_.clauses)
  | Surface.Quote quoted -> parenthesized "quote" [ to_string quoted ]
  | Surface.Splice (Surface.Expression_splice spliced) ->
      parenthesized "splice" [ to_string spliced ]
  | Surface.Splice (Surface.Pattern_splice spliced) ->
      parenthesized "pattern-splice" [ pattern_to_string spliced ]

and pattern_to_string pattern =
  match pattern.Surface.pattern_shape with
  | Surface.Wildcard_pattern -> "_"
  | Surface.Literal_pattern constant -> Constant.to_string constant
  | Surface.Variable_pattern binder -> binder.text
  | Surface.List_pattern patterns ->
      parenthesized "list-pattern" (List.map pattern_to_string patterns)
  | Surface.Cons_pattern cons ->
      parenthesized "::"
        [ pattern_to_string cons.pattern_head; pattern_to_string cons.pattern_tail ]
  | Surface.Alternative_pattern alternatives ->
      parenthesized "|" (List.map pattern_to_string alternatives)
  | Surface.Constructor_pattern constructor ->
      parenthesized (Surface.core_constructor_name constructor.constructor)
        (List.map pattern_to_string constructor.constructor_arguments)
  | Surface.Quasiquote_pattern quoted ->
      parenthesized "quasiquote-pattern" [ to_string quoted ]
  | Surface.Group_pattern grouped ->
      parenthesized "group-pattern" [ pattern_to_string grouped ]

let program_to_string program =
  String.concat "\n" (List.map to_string program)

let pp formatter expression = Format.pp_print_string formatter (to_string expression)
