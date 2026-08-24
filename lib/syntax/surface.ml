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
  | Up of t

and binding = {
  binding_kind : binding_kind;
  binder : name;
  binding_value : t;
}

and named_function = {
  function_open : bool;
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

let make ~span shape = { shape; span }
let name ~span text = { text; span }
let with_span span expression = { expression with span }
let make_pattern ~span pattern_shape = { pattern_shape; pattern_span = span }
let with_pattern_span pattern_span pattern = { pattern with pattern_span }

let core_constructor_of_string = function
  | "Lit" -> Some Core_lit
  | "Var" -> Some Core_var
  | "NamedVar" -> Some Core_named_var
  | "Lam" -> Some Core_lam
  | "App" -> Some Core_app
  | "Let" -> Some Core_let
  | "LetRec" -> Some Core_letrec
  | "If" -> Some Core_if
  | "Set" -> Some Core_set
  | "Quote" -> Some Core_quote
  | "Reifier" -> Some Core_reifier
  | _ -> None

let core_constructor_name = function
  | Core_lit -> "Lit"
  | Core_var -> "Var"
  | Core_named_var -> "NamedVar"
  | Core_lam -> "Lam"
  | Core_app -> "App"
  | Core_let -> "Let"
  | Core_letrec -> "LetRec"
  | Core_if -> "If"
  | Core_set -> "Set"
  | Core_quote -> "Quote"
  | Core_reifier -> "Reifier"

let core_constructor_arity = function
  | Core_lit | Core_var | Core_named_var | Core_quote -> 1
  | Core_lam | Core_app | Core_letrec | Core_set | Core_reifier -> 2
  | Core_let | Core_if -> 3

let core_constructor_pattern_spelling constructor =
  let holes = List.init (core_constructor_arity constructor) (fun _ -> "<pattern>") in
  Printf.sprintf "%s(%s)" (core_constructor_name constructor) (String.concat ", " holes)

let rec pattern_binders pattern =
  match pattern.pattern_shape with
  | Wildcard_pattern | Literal_pattern _ -> []
  | Variable_pattern binder -> [ binder ]
  | List_pattern patterns -> List.concat_map pattern_binders patterns
  | Cons_pattern cons ->
      pattern_binders cons.pattern_head @ pattern_binders cons.pattern_tail
  | Alternative_pattern alternatives -> (
      match alternatives with [] -> [] | first :: _ -> pattern_binders first)
  | Constructor_pattern constructor ->
      List.concat_map pattern_binders constructor.constructor_arguments
  | Quasiquote_pattern quoted -> quotation_pattern_binders quoted
  | Group_pattern grouped -> pattern_binders grouped

and quotation_pattern_binders expression =
  match expression.shape with
  | Literal _ | Name _ -> []
  | Binding binding -> quotation_pattern_binders binding.binding_value
  | Named_function function_ -> quotation_pattern_binders function_.function_body
  | Function function_ -> quotation_pattern_binders function_.body
  | Call call ->
      quotation_pattern_binders call.callee
      @ List.concat_map quotation_pattern_binders call.arguments
  | Block statements | List_literal statements ->
      List.concat_map quotation_pattern_binders statements
  | Conditional conditional ->
      quotation_pattern_binders conditional.condition
      @ quotation_pattern_binders conditional.consequent
      @ quotation_pattern_binders conditional.alternative
  | Unary unary -> quotation_pattern_binders unary.unary_operand
  | Binary binary ->
      quotation_pattern_binders binary.left @ quotation_pattern_binders binary.right
  | Assignment assignment -> quotation_pattern_binders assignment.assignment_value
  | Group grouped | Quote grouped | Up grouped -> quotation_pattern_binders grouped
  | Match match_ ->
      quotation_pattern_binders match_.scrutinee
      @ List.concat_map
          (fun clause ->
            pattern_quotation_binders clause.clause_pattern
            @ quotation_pattern_binders clause.clause_body)
          match_.clauses
  | Splice (Expression_splice spliced) -> quotation_pattern_binders spliced
  | Splice (Pattern_splice spliced) -> pattern_binders spliced

and pattern_quotation_binders pattern =
  match pattern.pattern_shape with
  | Wildcard_pattern | Literal_pattern _ | Variable_pattern _ -> []
  | List_pattern patterns | Alternative_pattern patterns ->
      List.concat_map pattern_quotation_binders patterns
  | Cons_pattern cons ->
      pattern_quotation_binders cons.pattern_head
      @ pattern_quotation_binders cons.pattern_tail
  | Constructor_pattern constructor ->
      List.concat_map pattern_quotation_binders constructor.constructor_arguments
  | Quasiquote_pattern quoted -> quotation_pattern_binders quoted
  | Group_pattern grouped -> pattern_quotation_binders grouped

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
