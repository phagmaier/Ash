(** Core literal constants: the payload of the [Lit] Core form.

    The domain is deliberately closed and small. Every constant is immutable, has
    decidable structural equality, and prints back to something the Core reader
    accepts, which is what lets differential and golden tests compare oracle, CPS,
    tower, and residual runs by value rather than by approximation. *)

type t =
  | Num of int
      (** Exact machine-word integer. Ash has no floating point: see
          [docs/decisions/0002-core-constants-and-identifiers.md]. *)
  | Bool of bool
  | Str of string  (** Immutable byte string. *)
  | Sym of string  (** Interned-by-value symbol, written ['name]. *)
  | Unit  (** The result of an expression evaluated for effect. *)
  | Nil  (** The empty list, written [[]]. *)

val equal : t -> t -> bool
(** Structural equality. Two constants are equal exactly when they are
    indistinguishable to an Ash program, so this is the equality differential
    tests compare with. *)

val compare : t -> t -> int
(** A total order used for deterministic printing and canonical keys. Constants
    of different shapes are ordered by shape in constructor order. *)

val type_name : t -> string
(** The name used in type and arity error messages, e.g. ["number"]. *)

val to_string : t -> string
(** Surface/Core notation: [42], [true], ["hi\n"], ['sym], [()], [[]]. *)

val pp : Format.formatter -> t -> unit

val escape_string : string -> string
(** Render [s] as a double-quoted Ash string literal, escaping so that reading the
    result yields [s]. Exposed because the printer escapes symbols the same way
    when they contain characters the lexer cannot read back bare. *)
