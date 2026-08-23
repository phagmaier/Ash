(** Handwritten parser for the Ash surface language in spec §4.

    Infix precedence follows the spec from pipelines (loosest) through calls
    (tightest). All binary levels associate left except [::], which associates
    right; mutation is a right-associative syntactic layer below pipelines.

    Newlines separate statements only in a program or braced block. Elsewhere
    they are whitespace, so a function body may begin on the line after [=] and
    a binary operator at the start of a line continues the preceding expression.
    Semicolons separate statements in those same statement lists. *)

val expression : ?file:string -> string -> Surface.t
(** Parse exactly one statement-shaped expression and require end of input.
    This accepts bindings and named function declarations as well as ordinary
    expressions.
    @raise Ash_core.Error.Ash_error with phase [Parse] on malformed syntax. *)

val program : ?file:string -> string -> Surface.program
(** Parse zero or more statements separated by a newline or semicolon.
    @raise Ash_core.Error.Ash_error with phase [Parse] on malformed syntax. *)

val pattern : ?file:string -> string -> Surface.pattern
(** Parse exactly one pattern, including alternatives and quasiquote patterns,
    and require end of input. Alternatives must bind identical name sets.
    @raise Ash_core.Error.Ash_error with phase [Parse] on malformed syntax. *)
