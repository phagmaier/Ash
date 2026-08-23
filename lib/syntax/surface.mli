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

type core_constructor =
  | Core_lit
  | Core_var
  | Core_named_var
  | Core_lam
  | Core_app
  | Core_let
  | Core_letrec
  | Core_if
  | Core_set
  | Core_quote
  | Core_reifier

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
  | Match of match_expression
  | Quote of t
  | Splice of splice

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

and match_expression = { scrutinee : t; clauses : match_clause list }

and match_clause = {
  clause_pattern : pattern;
  clause_body : t;
  clause_span : Span.t;
}

and splice = Expression_splice of t | Pattern_splice of pattern

and pattern = { pattern_shape : pattern_shape; pattern_span : Span.t }

and pattern_shape =
  | Wildcard_pattern
  | Literal_pattern of Constant.t
  | Variable_pattern of name
  | List_pattern of pattern list
  | Cons_pattern of pattern_cons
  | Alternative_pattern of pattern list
  | Constructor_pattern of constructor_pattern
  | Quasiquote_pattern of t
  | Group_pattern of pattern

and pattern_cons = {
  pattern_head : pattern;
  pattern_cons_span : Span.t;
  pattern_tail : pattern;
}

and constructor_pattern = {
  constructor : core_constructor;
  constructor_name_span : Span.t;
  constructor_arguments : pattern list;
}

type program = t list

val make : span:Span.t -> shape -> t
val name : span:Span.t -> string -> name
val with_span : Span.t -> t -> t
val make_pattern : span:Span.t -> pattern_shape -> pattern
val with_pattern_span : Span.t -> pattern -> pattern

val pattern_binders : pattern -> name list
(** The unique binders in source order. Parser-produced patterns satisfy this
    contract; alternatives return the first arm's binder order after the parser
    has checked that every arm binds the same set. *)

val core_constructor_of_string : string -> core_constructor option
val core_constructor_name : core_constructor -> string
val core_constructor_arity : core_constructor -> int
val core_constructor_pattern_spelling : core_constructor -> string

val unary_operator_spelling : unary_operator -> string
val binary_operator_spelling : binary_operator -> string
