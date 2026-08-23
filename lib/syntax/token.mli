(** Surface tokens.

    The lexicon of the Ash surface language (spec §4), separate from the lexer
    that scans it so the parser can name a token without depending on how it was
    found.

    Three renderings, for three different jobs: {!spelling} writes a token back
    as source, {!describe} is the noun phrase diagnostics put after "expected" or
    "found", and {!name} is the short tag golden output prints. *)

open Ash_core

type kind =
  (* Literals *)
  | Int of int  (** Decimal, non-negative: [-1] is unary minus applied to [1]. *)
  | String of string  (** Contents after escape processing. *)
  | Symbol of string  (** ['zero], without the quote. *)
  | True
  | False
  (* Names *)
  | Ident of string
      (** A name that is not a keyword. May end in [?], which is how [empty?] is
          spelled; [!] is prefix negation only and never part of a name. *)
  (* Keywords *)
  | Let
  | Var
  | Fn
  | If
  | Then
  | Else
  | Match
  | Open  (** [open fn eval(…)]: the open-recursive evaluator group (spec §6). *)
  | Up  (** [up { … }]: reflection to the level above (§5.2). *)
  | Meta_with  (** [meta_with(eval = …) { … }]: an overlay frame (§5.5). *)
  | Reifier  (** [reifier(exp, env, k) -> …] (§5.4). *)
  (* Operators *)
  | Pipe_forward  (** [|>] *)
  | Or  (** [||] *)
  | And  (** [&&] *)
  | Eq  (** [==] *)
  | Ne  (** [!=] *)
  | Lt
  | Le
  | Gt
  | Ge
  | Cons  (** [::], right associative *)
  | Plus
  | Minus
  | Star
  | Slash
  | Percent
  | Bang  (** [!], prefix negation *)
  | Assign  (** [:=], mutation of a [var] *)
  | Equals  (** [=], the binder in [let]/[fn]/[meta_with], never comparison *)
  | Arrow  (** [->] *)
  | Bar  (** [|], pattern alternative *)
  | Dot
      (** [.], the field access the spec's precedence table names. Ash values
          have no fields yet, so no parser consumes it; it is lexed rather than
          rejected as a stray character so that the diagnostic comes from the
          grammar rather than from the scanner. *)
  (* Punctuation *)
  | Comma
  | Semicolon  (** [e1; e2], sequencing sugar (spec §3). *)
  | Lparen
  | Rparen
  | Lbrace
  | Rbrace
  | Lbracket
  | Rbracket
  | Underscore  (** [_], the wildcard pattern. A name may start with [_]. *)
  (* Staging *)
  | Quote_open  (** [`{]. One token: the brace must follow the backtick. *)
  | Splice_open  (** [${]. Likewise. *)
  (* End *)
  | Eof

type t = {
  kind : kind;
  span : Span.t;
  starts_line : bool;
      (** Whether a line break, or the start of the file, comes before this token
          with nothing but whitespace and comments between.

          Line structure is a fact about the source, and a token stream that
          discarded it would force the parser to re-scan: the spec's blocks
          separate statements by newline
          ([{ let m = n % 3 \n if m == 0 then … }]) as well as by [;]. Whether
          the parser uses the flag is its decision; the lexer's job is not to
          throw the information away. *)
}

val equal_kind : kind -> kind -> bool
val equal : t -> t -> bool
(** Kind and span, including provenance. *)

val keywords : (string * kind) list
(** Every reserved word and the token it produces, in the order they are
    documented above. A name in this table is never an {!Ident}. *)

val keyword_of_string : string -> kind option
val is_keyword : string -> bool

val spelling : kind -> string
(** The token written back as source: [">="], ["let"], ["42"], [{|"a\nb"|}].
    {!Eof} has no spelling and yields [""]. *)

val describe : kind -> string
(** The noun phrase for diagnostics: ["an integer literal"], ["the keyword
    `then`"], ["end of input"]. *)

val name : kind -> string
(** A short tag for grouping in reports and golden output: ["int"], ["ident"],
    ["keyword"], ["operator"], ["punctuation"], ["quotation"], ["eof"]. *)

val to_string : t -> string
(** Tag, spelling, and location, for golden output and debugging. *)

val pp : Format.formatter -> t -> unit
