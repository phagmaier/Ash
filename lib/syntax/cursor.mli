(** A scanning position in a source string.

    The one piece of mutable state a lexer needs, scoped to a single scan and
    observable nowhere else, so it is a local counter rather than part of any Ash
    value.

    Both lexers in this project use it — the canonical Core reader's
    s-expressions and the surface lexer — because line and column counting feeds
    {!Ash_core.Span}, and two implementations of it would be two chances for a
    diagnostic to point at the wrong character. *)

open Ash_core

type t

val create : file:string -> string -> t
val file : t -> string

val position : t -> Span.position
(** Where the cursor is now: 1-based line and column, 0-based byte offset. *)

val at_end : t -> bool

val peek : t -> char option
(** The character at the cursor, without consuming it. *)

val peek_ahead : t -> int -> char option
(** [peek_ahead c 1] is the character after {!peek}. Lookahead is what
    distinguishes [::] from [:], and [`{] from a stray backtick. *)

val advance : t -> unit
(** Consume one character, tracking line and column. A newline advances the line
    and resets the column.
    @raise Invalid_argument at end of input, which is a scanner bug rather than a
    source error. *)

val span_from : t -> Span.position -> Span.t
(** The span from [start] to where the cursor is now — the shape every token and
    every located diagnostic needs. *)
