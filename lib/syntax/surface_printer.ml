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

let program_to_string program =
  String.concat "\n" (List.map to_string program)

let pp formatter expression = Format.pp_print_string formatter (to_string expression)

