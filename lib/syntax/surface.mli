(** Source-located Ash surface syntax before hygiene and desugaring.

    This tree preserves the distinctions that matter to later lowering: a
    named function is recursive syntax rather than an ordinary [let], mutable
    bindings are distinct from immutable ones, and pipelines remain operators
    until the desugarer rewrites them. Names are still strings here; hygienic
    identities are allocated only while resolving binding structure in the
    desugarer. *)

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

val make : span:Span.t -> shape -> t
val name : span:Span.t -> string -> name
val with_span : Span.t -> t -> t

val unary_operator_spelling : unary_operator -> string
val binary_operator_spelling : binary_operator -> string

