open Ash_core

type state = { tokens : Token.t array; mutable index : int }

let current state = state.tokens.(state.index)

let peek state distance =
  let index = min (Array.length state.tokens - 1) (state.index + distance) in
  state.tokens.(index)

let advance state =
  let token = current state in
  if not (Token.equal_kind token.kind Token.Eof) then state.index <- state.index + 1;
  token

let at state kind = Token.equal_kind (current state).kind kind

let fail token expected =
  Error.raise_cause ~phase:Error.Parse ~span:token.Token.span
    (Error.Unexpected { found = Token.describe token.kind; expected })

let expect state kind =
  let token = current state in
  if Token.equal_kind token.kind kind then advance state else fail token (Token.describe kind)

let expect_name state =
  let token = current state in
  match token.kind with
  | Token.Ident text ->
      ignore (advance state);
      Surface.name ~span:token.span text
  | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Let
  | Token.Var | Token.Fn | Token.If | Token.Then | Token.Else | Token.Match | Token.Open
  | Token.Up | Token.Meta_with | Token.Reifier | Token.Pipe_forward | Token.Or | Token.And
  | Token.Eq | Token.Ne | Token.Lt | Token.Le | Token.Gt | Token.Ge | Token.Cons
  | Token.Plus | Token.Minus | Token.Star | Token.Slash | Token.Percent | Token.Bang
  | Token.Assign | Token.Equals | Token.Arrow | Token.Bar | Token.Dot | Token.Comma
  | Token.Semicolon | Token.Lparen | Token.Rparen | Token.Lbrace | Token.Rbrace
  | Token.Lbracket | Token.Rbracket | Token.Underscore | Token.Quote_open
  | Token.Splice_open | Token.Eof ->
      fail token "a name"

let joined first last = Span.join first.Token.span last.Token.span
let node_span left right = Span.join left.Surface.span right.Surface.span

let check_distinct_names names =
  let rec walk seen = function
    | [] -> ()
    | (name : Surface.name) :: rest ->
        if List.mem name.text seen then
          Error.raise_cause ~phase:Error.Parse ~span:name.span
            (Error.Duplicate_binder name.text);
        walk (name.text :: seen) rest
  in
  walk [] names

let parse_parameters state =
  ignore (expect state Token.Lparen);
  let rec loop reversed =
    if at state Token.Rparen then
      let closing = advance state in
      let params = List.rev reversed in
      check_distinct_names params;
      (params, closing)
    else
      let parameter = expect_name state in
      if at state Token.Comma then (
        ignore (advance state);
        if at state Token.Rparen then fail (current state) "a name after `,`";
        loop (parameter :: reversed))
      else
        let closing = expect state Token.Rparen in
        let params = List.rev (parameter :: reversed) in
        check_distinct_names params;
        (params, closing)
  in
  loop []

let rec parse_statement state =
  match (current state).kind with
  | Token.Let -> parse_binding state Surface.Immutable
  | Token.Var -> parse_binding state Surface.Mutable
  | Token.Fn -> (
      match (peek state 1).kind with
      | Token.Ident _ -> parse_named_function state
      | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Let
      | Token.Var | Token.Fn | Token.If | Token.Then | Token.Else | Token.Match | Token.Open
      | Token.Up | Token.Meta_with | Token.Reifier | Token.Pipe_forward | Token.Or
      | Token.And | Token.Eq | Token.Ne | Token.Lt | Token.Le | Token.Gt | Token.Ge
      | Token.Cons | Token.Plus | Token.Minus | Token.Star | Token.Slash | Token.Percent
      | Token.Bang | Token.Assign | Token.Equals | Token.Arrow | Token.Bar | Token.Dot
      | Token.Comma | Token.Semicolon | Token.Lparen | Token.Rparen | Token.Lbrace
      | Token.Rbrace | Token.Lbracket | Token.Rbracket | Token.Underscore
      | Token.Quote_open | Token.Splice_open | Token.Eof ->
          parse_expression state)
  | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Ident _
  | Token.If | Token.Then | Token.Else | Token.Match | Token.Open | Token.Up
  | Token.Meta_with | Token.Reifier | Token.Pipe_forward | Token.Or | Token.And | Token.Eq
  | Token.Ne | Token.Lt | Token.Le | Token.Gt | Token.Ge | Token.Cons | Token.Plus
  | Token.Minus | Token.Star | Token.Slash | Token.Percent | Token.Bang | Token.Assign
  | Token.Equals | Token.Arrow | Token.Bar | Token.Dot | Token.Comma | Token.Semicolon
  | Token.Lparen | Token.Rparen | Token.Lbrace | Token.Rbrace | Token.Lbracket
  | Token.Rbracket | Token.Underscore | Token.Quote_open | Token.Splice_open | Token.Eof ->
      parse_expression state

and parse_binding state binding_kind =
  let opening = advance state in
  let binder = expect_name state in
  ignore (expect state Token.Equals);
  let binding_value = parse_expression state in
  Surface.make ~span:(Span.join opening.Token.span binding_value.Surface.span)
    (Surface.Binding { binding_kind; binder; binding_value })

and parse_named_function state =
  let opening = expect state Token.Fn in
  let function_name = expect_name state in
  let function_params, _ = parse_parameters state in
  ignore (expect state Token.Equals);
  let function_body = parse_expression state in
  Surface.make ~span:(Span.join opening.Token.span function_body.Surface.span)
    (Surface.Named_function { function_name; function_params; function_body })

and parse_expression state = parse_assignment state

and parse_assignment state =
  let target = parse_pipeline state in
  if at state Token.Assign then
    let operator = advance state in
    let assignment_target =
      match target.Surface.shape with
      | Surface.Name name -> name
      | Surface.Literal _ | Surface.Binding _ | Surface.Named_function _ | Surface.Function _
      | Surface.Call _ | Surface.Block _ | Surface.Conditional _ | Surface.List_literal _
      | Surface.Unary _ | Surface.Binary _ | Surface.Assignment _ | Surface.Group _ ->
          Error.raise_cause ~phase:Error.Parse ~span:target.Surface.span
            (Error.Unexpected
               {
                 found = "an expression that is not a name";
                 expected = "a name on the left of `:=`";
               })
    in
    let assignment_value = parse_assignment state in
    Surface.make ~span:(node_span target assignment_value)
      (Surface.Assignment
         {
           assignment_target;
           assignment_operator_span = operator.Token.span;
           assignment_value;
         })
  else target

and parse_pipeline state =
  parse_left_associative state parse_or (function
    | Token.Pipe_forward -> Some Surface.Pipe_forward
    | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Ident _
    | Token.Let | Token.Var | Token.Fn | Token.If | Token.Then | Token.Else | Token.Match
    | Token.Open | Token.Up | Token.Meta_with | Token.Reifier | Token.Or | Token.And
    | Token.Eq | Token.Ne | Token.Lt | Token.Le | Token.Gt | Token.Ge | Token.Cons
    | Token.Plus | Token.Minus | Token.Star | Token.Slash | Token.Percent | Token.Bang
    | Token.Assign | Token.Equals | Token.Arrow | Token.Bar | Token.Dot | Token.Comma
    | Token.Semicolon | Token.Lparen | Token.Rparen | Token.Lbrace | Token.Rbrace
    | Token.Lbracket | Token.Rbracket | Token.Underscore | Token.Quote_open
    | Token.Splice_open | Token.Eof ->
        None)

and parse_or state =
  parse_left_associative state parse_and (function
    | Token.Or -> Some Surface.Or
    | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Ident _
    | Token.Let | Token.Var | Token.Fn | Token.If | Token.Then | Token.Else | Token.Match
    | Token.Open | Token.Up | Token.Meta_with | Token.Reifier | Token.Pipe_forward
    | Token.And | Token.Eq | Token.Ne | Token.Lt | Token.Le | Token.Gt | Token.Ge
    | Token.Cons | Token.Plus | Token.Minus | Token.Star | Token.Slash | Token.Percent
    | Token.Bang | Token.Assign | Token.Equals | Token.Arrow | Token.Bar | Token.Dot
    | Token.Comma | Token.Semicolon | Token.Lparen | Token.Rparen | Token.Lbrace
    | Token.Rbrace | Token.Lbracket | Token.Rbracket | Token.Underscore | Token.Quote_open
    | Token.Splice_open | Token.Eof ->
        None)

and parse_and state =
  parse_left_associative state parse_comparison (function
    | Token.And -> Some Surface.And
    | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Ident _
    | Token.Let | Token.Var | Token.Fn | Token.If | Token.Then | Token.Else | Token.Match
    | Token.Open | Token.Up | Token.Meta_with | Token.Reifier | Token.Pipe_forward
    | Token.Or | Token.Eq | Token.Ne | Token.Lt | Token.Le | Token.Gt | Token.Ge
    | Token.Cons | Token.Plus | Token.Minus | Token.Star | Token.Slash | Token.Percent
    | Token.Bang | Token.Assign | Token.Equals | Token.Arrow | Token.Bar | Token.Dot
    | Token.Comma | Token.Semicolon | Token.Lparen | Token.Rparen | Token.Lbrace
    | Token.Rbrace | Token.Lbracket | Token.Rbracket | Token.Underscore | Token.Quote_open
    | Token.Splice_open | Token.Eof ->
        None)

and parse_comparison state =
  parse_left_associative state parse_cons (function
    | Token.Eq -> Some Surface.Equal
    | Token.Ne -> Some Surface.Not_equal
    | Token.Lt -> Some Surface.Less
    | Token.Le -> Some Surface.Less_equal
    | Token.Gt -> Some Surface.Greater
    | Token.Ge -> Some Surface.Greater_equal
    | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Ident _
    | Token.Let | Token.Var | Token.Fn | Token.If | Token.Then | Token.Else | Token.Match
    | Token.Open | Token.Up | Token.Meta_with | Token.Reifier | Token.Pipe_forward
    | Token.Or | Token.And | Token.Cons | Token.Plus | Token.Minus | Token.Star
    | Token.Slash | Token.Percent | Token.Bang | Token.Assign | Token.Equals | Token.Arrow
    | Token.Bar | Token.Dot | Token.Comma | Token.Semicolon | Token.Lparen | Token.Rparen
    | Token.Lbrace | Token.Rbrace | Token.Lbracket | Token.Rbracket | Token.Underscore
    | Token.Quote_open | Token.Splice_open | Token.Eof ->
        None)

and parse_cons state =
  let left = parse_additive state in
  if at state Token.Cons then
    let operator = advance state in
    let right = parse_cons state in
    make_binary Surface.Cons operator left right
  else left

and parse_additive state =
  parse_left_associative state parse_multiplicative (function
    | Token.Plus -> Some Surface.Add
    | Token.Minus -> Some Surface.Subtract
    | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Ident _
    | Token.Let | Token.Var | Token.Fn | Token.If | Token.Then | Token.Else | Token.Match
    | Token.Open | Token.Up | Token.Meta_with | Token.Reifier | Token.Pipe_forward
    | Token.Or | Token.And | Token.Eq | Token.Ne | Token.Lt | Token.Le | Token.Gt
    | Token.Ge | Token.Cons | Token.Star | Token.Slash | Token.Percent | Token.Bang
    | Token.Assign | Token.Equals | Token.Arrow | Token.Bar | Token.Dot | Token.Comma
    | Token.Semicolon | Token.Lparen | Token.Rparen | Token.Lbrace | Token.Rbrace
    | Token.Lbracket | Token.Rbracket | Token.Underscore | Token.Quote_open
    | Token.Splice_open | Token.Eof ->
        None)

and parse_multiplicative state =
  parse_left_associative state parse_unary (function
    | Token.Star -> Some Surface.Multiply
    | Token.Slash -> Some Surface.Divide
    | Token.Percent -> Some Surface.Remainder
    | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Ident _
    | Token.Let | Token.Var | Token.Fn | Token.If | Token.Then | Token.Else | Token.Match
    | Token.Open | Token.Up | Token.Meta_with | Token.Reifier | Token.Pipe_forward
    | Token.Or | Token.And | Token.Eq | Token.Ne | Token.Lt | Token.Le | Token.Gt
    | Token.Ge | Token.Cons | Token.Plus | Token.Minus | Token.Bang | Token.Assign
    | Token.Equals | Token.Arrow | Token.Bar | Token.Dot | Token.Comma | Token.Semicolon
    | Token.Lparen | Token.Rparen | Token.Lbrace | Token.Rbrace | Token.Lbracket
    | Token.Rbracket | Token.Underscore | Token.Quote_open | Token.Splice_open
    | Token.Eof ->
        None)

and parse_left_associative state parse_operand operator_of_token =
  let rec loop left =
    match operator_of_token (current state).kind with
    | None -> left
    | Some binary_operator ->
        let operator = advance state in
        let right = parse_operand state in
        loop (make_binary binary_operator operator left right)
  in
  loop (parse_operand state)

and make_binary binary_operator operator left right =
  Surface.make ~span:(node_span left right)
    (Surface.Binary
       {
         binary_operator;
         binary_operator_span = operator.Token.span;
         left;
         right;
       })

and parse_unary state =
  match (current state).kind with
  | Token.Minus -> parse_prefix_unary state Surface.Negate
  | Token.Bang -> parse_prefix_unary state Surface.Not
  | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False | Token.Ident _
  | Token.Let | Token.Var | Token.Fn | Token.If | Token.Then | Token.Else | Token.Match
  | Token.Open | Token.Up | Token.Meta_with | Token.Reifier | Token.Pipe_forward
  | Token.Or | Token.And | Token.Eq | Token.Ne | Token.Lt | Token.Le | Token.Gt
  | Token.Ge | Token.Cons | Token.Plus | Token.Star | Token.Slash | Token.Percent
  | Token.Assign | Token.Equals | Token.Arrow | Token.Bar | Token.Dot | Token.Comma
  | Token.Semicolon | Token.Lparen | Token.Rparen | Token.Lbrace | Token.Rbrace
  | Token.Lbracket | Token.Rbracket | Token.Underscore | Token.Quote_open
  | Token.Splice_open | Token.Eof ->
      parse_postfix state

and parse_prefix_unary state unary_operator =
  let operator = advance state in
  let unary_operand = parse_unary state in
  Surface.make ~span:(Span.join operator.Token.span unary_operand.Surface.span)
    (Surface.Unary
       {
         unary_operator;
         unary_operator_span = operator.Token.span;
         unary_operand;
       })

and parse_postfix state =
  let rec loop callee =
    match (current state).kind with
    | Token.Lparen ->
        let arguments, closing = parse_arguments state in
        let call =
          Surface.make ~span:(Span.join callee.Surface.span closing.Token.span)
            (Surface.Call { callee; arguments })
        in
        loop call
    | Token.Dot ->
        let dot = current state in
        Error.raise_cause ~phase:Error.Parse ~span:dot.Token.span
          (Error.Unsupported { what = "field access"; by = "the Ash surface language" })
    | Token.Int _ | Token.String _ | Token.Symbol _ | Token.True | Token.False
    | Token.Ident _ | Token.Let | Token.Var | Token.Fn | Token.If | Token.Then
    | Token.Else | Token.Match | Token.Open | Token.Up | Token.Meta_with | Token.Reifier
    | Token.Pipe_forward | Token.Or | Token.And | Token.Eq | Token.Ne | Token.Lt
    | Token.Le | Token.Gt | Token.Ge | Token.Cons | Token.Plus | Token.Minus
    | Token.Star | Token.Slash | Token.Percent | Token.Bang | Token.Assign
    | Token.Equals | Token.Arrow | Token.Bar | Token.Comma | Token.Semicolon
    | Token.Rparen | Token.Lbrace | Token.Rbrace | Token.Lbracket | Token.Rbracket
    | Token.Underscore | Token.Quote_open | Token.Splice_open | Token.Eof ->
        callee
  in
  loop (parse_primary state)

and parse_arguments state =
  ignore (expect state Token.Lparen);
  let rec loop reversed =
    if at state Token.Rparen then (List.rev reversed, advance state)
    else
      let argument = parse_expression state in
      if at state Token.Comma then (
        ignore (advance state);
        if at state Token.Rparen then fail (current state) "an expression after `,`";
        loop (argument :: reversed))
      else (List.rev (argument :: reversed), expect state Token.Rparen)
  in
  loop []

and parse_primary state =
  let token = current state in
  match token.kind with
  | Token.Int value ->
      ignore (advance state);
      Surface.make ~span:token.span (Surface.Literal (Constant.Num value))
  | Token.String value ->
      ignore (advance state);
      Surface.make ~span:token.span (Surface.Literal (Constant.Str value))
  | Token.Symbol value ->
      ignore (advance state);
      Surface.make ~span:token.span (Surface.Literal (Constant.Sym value))
  | Token.True ->
      ignore (advance state);
      Surface.make ~span:token.span (Surface.Literal (Constant.Bool true))
  | Token.False ->
      ignore (advance state);
      Surface.make ~span:token.span (Surface.Literal (Constant.Bool false))
  | Token.Ident text ->
      ignore (advance state);
      Surface.make ~span:token.span
        (Surface.Name (Surface.name ~span:token.span text))
  | Token.Fn -> parse_function state
  | Token.If -> parse_conditional state
  | Token.Lbrace -> parse_block state
  | Token.Lbracket -> parse_list state
  | Token.Lparen -> parse_group_or_unit state
  | Token.Let | Token.Var | Token.Then | Token.Else | Token.Match | Token.Open | Token.Up
  | Token.Meta_with | Token.Reifier | Token.Pipe_forward | Token.Or | Token.And | Token.Eq
  | Token.Ne | Token.Lt | Token.Le | Token.Gt | Token.Ge | Token.Cons | Token.Plus
  | Token.Minus | Token.Star | Token.Slash | Token.Percent | Token.Bang | Token.Assign
  | Token.Equals | Token.Arrow | Token.Bar | Token.Dot | Token.Comma | Token.Semicolon
  | Token.Rparen | Token.Rbrace | Token.Rbracket | Token.Underscore | Token.Quote_open
  | Token.Splice_open | Token.Eof ->
      fail token "an expression"

and parse_function state =
  let opening = expect state Token.Fn in
  let params, _ = parse_parameters state in
  ignore (expect state Token.Arrow);
  let body = parse_expression state in
  Surface.make ~span:(Span.join opening.Token.span body.Surface.span)
    (Surface.Function { params; body })

and parse_conditional state =
  let opening = expect state Token.If in
  let condition = parse_expression state in
  ignore (expect state Token.Then);
  let consequent = parse_expression state in
  ignore (expect state Token.Else);
  let alternative = parse_expression state in
  Surface.make ~span:(Span.join opening.Token.span alternative.Surface.span)
    (Surface.Conditional { condition; consequent; alternative })

and parse_block state =
  let opening = expect state Token.Lbrace in
  let statements = parse_statements state Token.Rbrace in
  let closing = expect state Token.Rbrace in
  Surface.make ~span:(joined opening closing) (Surface.Block statements)

and parse_list state =
  let opening = expect state Token.Lbracket in
  let rec loop reversed =
    if at state Token.Rbracket then
      let closing = advance state in
      Surface.make ~span:(joined opening closing)
        (Surface.List_literal (List.rev reversed))
    else
      let item = parse_expression state in
      if at state Token.Comma then (
        ignore (advance state);
        if at state Token.Rbracket then fail (current state) "an expression after `,`";
        loop (item :: reversed))
      else
        let closing = expect state Token.Rbracket in
        Surface.make ~span:(joined opening closing)
          (Surface.List_literal (List.rev (item :: reversed)))
  in
  loop []

and parse_group_or_unit state =
  let opening = expect state Token.Lparen in
  if at state Token.Rparen then
    let closing = advance state in
    Surface.make ~span:(joined opening closing) (Surface.Literal Constant.Unit)
  else
    let grouped = parse_expression state in
    let closing = expect state Token.Rparen in
    Surface.make ~span:(joined opening closing) (Surface.Group grouped)

and parse_statements state closing_kind =
  let rec loop reversed =
    if at state closing_kind then List.rev reversed
    else
      let statement = parse_statement state in
      let reversed = statement :: reversed in
      if at state closing_kind then List.rev reversed
      else if at state Token.Semicolon then (
        ignore (advance state);
        if at state closing_kind then List.rev reversed else loop reversed)
      else if (current state).starts_line then loop reversed
      else
        fail (current state)
          (Printf.sprintf "`;`, a line break, or %s" (Token.describe closing_kind))
  in
  loop []

let state_of_source ?file source =
  { tokens = Array.of_list (Lexer.tokens ?file source); index = 0 }

let expression ?file source =
  let state = state_of_source ?file source in
  let expression = parse_statement state in
  ignore (expect state Token.Eof);
  expression

let program ?file source =
  let state = state_of_source ?file source in
  let statements = parse_statements state Token.Eof in
  ignore (expect state Token.Eof);
  statements
