(** The observable-effect boundary: buffered, injectable, and recorded.

    Ash's equivalence claims are about traces, not just answers. A program that
    prints [1] then [2] is not the program that prints [2] then [1], and the
    collapse report has to be able to say that a residual program produced
    {e exactly} the effects the source program did. That requires the effects to
    be values a test can compare, so every observable primitive writes here
    rather than to [stdout] directly.

    It is also what makes the D7 rule checkable rather than aspirational: if
    specialization ever executed [print], the difference would show up as an
    event recorded at the wrong time, in a buffer, instead of as characters that
    have already left the process.

    Input is scripted for the same reason. A test that reads supplies the lines
    it will read, so a program that consumes input is as deterministic as one
    that does not.

    An {!t} always records. Echoing to a channel is an additional output for
    interactive use, never a replacement for the record. *)

type event =
  | Wrote of string  (** The exact text an observable primitive emitted. *)
  | Read of string  (** A line an observable primitive consumed. *)

type t
(** One observable-effect stream: everything written, everything read, in the
    order it happened. *)

val create : ?echo:out_channel -> ?input:string list -> unit -> t
(** [create ()] is a pure buffer with no input, which is what tests want.
    [~echo] additionally writes through to a channel for the CLI; [~input] is the
    scripted lines {!read_line} will return, in order. *)

val write : t -> string -> unit
(** Record [text] as written, and echo it if this stream echoes. The text is
    exactly what the primitive emitted, newline included when there is one, so a
    recorded trace can be reassembled into the output verbatim. *)

val read_line : t -> string option
(** Consume the next scripted line, recording it. [None] when the input is
    exhausted; the caller decides what that means, because "no more input" is a
    program-level condition rather than a host error. *)

val feed : t -> string list -> unit
(** Append lines to the pending input. *)

val events : t -> event list
(** Everything that happened, oldest first. This is the trace two runs are
    compared by. *)

val written : t -> string list
(** Only the writes, oldest first. *)

val text : t -> string
(** The writes concatenated: what a reader of the output would have seen. *)

val pending_input : t -> string list
(** Input not yet consumed, next line first. *)

val clear : t -> unit
(** Forget the recorded events, leaving pending input alone. For a test that
    reuses one stream across cases. *)

val event_to_string : event -> string
(** ["wrote \"hi\\n\""], ["read \"answer\""] — an escaped, comparable rendering
    for test output. *)

val event_equal : event -> event -> bool
val trace : t -> string
(** Every event rendered and separated by ["; "]. *)
