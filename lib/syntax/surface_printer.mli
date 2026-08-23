(** Deterministic structural rendering of surface syntax.

    The result is deliberately parenthesized rather than pretty Ash source: it
    exposes the parser's grouping and is therefore suitable for precedence
    golden tests. *)

val to_string : Surface.t -> string
val program_to_string : Surface.program -> string
val pp : Format.formatter -> Surface.t -> unit

