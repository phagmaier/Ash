open Ash_core

type t = {
  source : string;
  file : string;
  mutable offset : int;
  mutable line : int;
  mutable column : int;
}

let create ~file source = { source; file; offset = 0; line = 1; column = 1 }
let file c = c.file
let position c = Span.position ~file:c.file ~line:c.line ~column:c.column ~offset:c.offset
let at_end c = c.offset >= String.length c.source
let peek c = if at_end c then None else Some c.source.[c.offset]

let peek_ahead c n =
  let at = c.offset + n in
  if at >= String.length c.source then None else Some c.source.[at]

let advance c =
  if at_end c then invalid_arg "Cursor.advance: at end of input";
  (match c.source.[c.offset] with
  (* Columns are counted in bytes, as Span documents, so no decoding happens
     here: a multi-byte character advances the column by its byte length. *)
  | '\n' ->
      c.line <- c.line + 1;
      c.column <- 1
  | _ -> c.column <- c.column + 1);
  c.offset <- c.offset + 1

let span_from c start = Span.make ~start ~stop:(position c)
