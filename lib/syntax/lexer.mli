(** The surface lexer: source text to {!Token.t} list, with a span on every
    token.

    This is the Ash surface language of spec §4, not the canonical Core notation
    {!Sexp} reads. The two are deliberately separate: Core can be written down
    exactly long before the surface language exists, and the self-interpreter's
    corpus does not move when surface syntax does.

    {1 What it scans}

    - [#] comments, to end of line. (The Core reader uses [;] instead, because
      its [#t] and [#f] begin with a hash. Ash spells those [true] and [false],
      so [#] is free here and [;] is the sequencing operator.)
    - Decimal integer, string, symbol, and boolean literals. Integers are
      non-negative: [-1] is unary minus applied to [1], which is what the
      precedence table says.
    - Names and reserved words, per {!Token.keywords}.
    - Operators and punctuation, by maximal munch: the longest operator that
      matches wins, so [|>] is never [|] followed by [>].
    - [`{] and [${], each one token, because the brace must follow immediately.

    {1 What it does not do}

    It does not skip line structure silently: every token records whether a line
    break precedes it (see {!Token.t}), because the spec's blocks separate
    statements by newline as well as by [;].

    It does not resolve names, know the grammar, or care whether a token can
    appear where it did. A stray [.] lexes as an operator and is refused by the
    parser, which is the layer that can say what was expected instead. *)

val tokens : ?file:string -> string -> Token.t list
(** Every token in [source], ending with exactly one {!Token.Eof} whose span is
    the empty region at end of input.
    @raise Ash_core.Error.Ash_error with phase {!Ash_core.Error.Lex} and a
    located cause. *)

val is_name_start : char -> bool
(** A letter or [_]: what a name may begin with. *)

val is_name_char : char -> bool
(** A letter, digit, or [_]: what a name may continue with. A single trailing [?]
    is also allowed, which is how [empty?] is spelled, but [!] never is — it is
    prefix negation, and a name that could end in one would make [x!y]
    ambiguous. *)

val is_name : string -> bool
(** Whether [text] would lex as a single {!Token.Ident}: a well-formed name that
    is not reserved. The desugarer asks before inventing a name, so the lexical
    rules stay in one place. *)
