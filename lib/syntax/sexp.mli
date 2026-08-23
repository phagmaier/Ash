(** S-expression data with source spans.

    This is the lexical layer under the canonical Core reader. It is a debug and
    test notation, not the Ash surface syntax: the handwritten surface lexer and
    parser are Phase 1. Keeping the two apart means Core can be written down
    exactly and unambiguously long before the surface language exists, and it
    keeps the self-interpreter's test corpus independent of surface syntax
    changes.

    Notation: parenthesised lists, decimal integers, [#t] and [#f], double-quoted
    strings with the same escapes {!Constant.escape_string} produces, ['name]
    symbols, and bare atoms for everything else. [;] starts a comment that runs
    to end of line — [#] cannot, because [#t] and [#f] begin with it. *)

open Ash_core

type t = { datum : datum; span : Span.t }

and datum =
  | Int of int
  | Bool of bool
  | Str of string
  | Sym of string  (** ['name] *)
  | Atom of string  (** A bare token: a form head, an identifier, [unit]. *)
  | List of t list

val of_string : ?file:string -> string -> t list
(** Every datum in the input, in order.
    @raise Error.Ash_error with phase {!Error.Lex} and a located cause. *)

val one_of_string : ?file:string -> string -> t
(** Exactly one datum. @raise Error.Ash_error if the input holds none or several. *)

val to_string : t -> string
(** Canonical rendering: one space between list elements, no comments, no
    alignment. Reading the result yields the same datum, so this is the
    round-trip partner of {!of_string}. *)

val datum_name : datum -> string
(** A noun phrase for diagnostics, e.g. ["an integer"], ["a list"]. *)

val pp : Format.formatter -> t -> unit
