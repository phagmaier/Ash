open Ash_core

type name = { text : string; span : Span.t }

type binding_kind = Immutable | Mutable
type unary_operator = Negate | Not

type binary_operator =
  | Pipe_forward
  | Or
  | And
  | Equal
  | Not_equal
  | Less
  | Less_equal
  | Greater
  | Greater_equal
  | Cons
  | Add
  | Subtract
  | Multiply
  | Divide
  | Remainder

type t = { shape : shape; span : Span.t }

and shape =
  | Literal of Constant.t
  | Name of name
  | Binding of binding
  | Named_function of named_function
  | Function of function_literal
  | Call of call
  | Block of t list
  | Conditional of conditional
  | List_literal of t list
  | Unary of unary
  | Binary of binary
  | Assignment of assignment
  | Group of t

and binding = {
  binding_kind : binding_kind;
  binder : name;
  binding_value : t;
}

and named_function = {
  function_name : name;
  function_params : name list;
  function_body : t;
}

and function_literal = { params : name list; body : t }
and call = { callee : t; arguments : t list }

and conditional = {
  condition : t;
  consequent : t;
  alternative : t;
}

and unary = {
  unary_operator : unary_operator;
  unary_operator_span : Span.t;
  unary_operand : t;
}

and binary = {
  binary_operator : binary_operator;
  binary_operator_span : Span.t;
  left : t;
  right : t;
}

and assignment = {
  assignment_target : name;
  assignment_operator_span : Span.t;
  assignment_value : t;
}

type program = t list

let make ~span shape = { shape; span }
let name ~span text = { text; span }
let with_span span expression = { expression with span }

let unary_operator_spelling = function Negate -> "-" | Not -> "!"

let binary_operator_spelling = function
  | Pipe_forward -> "|>"
  | Or -> "||"
  | And -> "&&"
  | Equal -> "=="
  | Not_equal -> "!="
  | Less -> "<"
  | Less_equal -> "<="
  | Greater -> ">"
  | Greater_equal -> ">="
  | Cons -> "::"
  | Add -> "+"
  | Subtract -> "-"
  | Multiply -> "*"
  | Divide -> "/"
  | Remainder -> "%"

