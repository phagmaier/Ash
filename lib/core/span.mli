(** Source locations for surface syntax, Core, residual provenance, and errors.

    Every syntactic node carries a span. A node that a later phase invents is not
    span-less: it keeps the span of the user code it came from and additionally
    records a {e generated} marker naming the phase that produced it. Diagnostics
    can therefore always point at real user text, while the collapse report can
    still distinguish written code from emitted code. *)

(** A single point in a source file. *)
type position = {
  file : string;  (** Path or pseudo-path such as [<stdin>]. *)
  line : int;  (** 1-based line number. *)
  column : int;  (** 1-based column, counted in bytes. *)
  offset : int;  (** 0-based byte offset from the start of the file. *)
}

(** A half-open region [start, stop) together with its provenance. *)
type t = { start : position; stop : position; origin : origin }

and origin =
  | Source  (** The region was written by a human in [start.file]. *)
  | Generated of generated  (** The node was produced by a phase. *)

and generated = {
  by : string;  (** Name of the phase or expander, e.g. ["desugar/seq"]. *)
  from : t;  (** The span this node was derived from. May itself be generated. *)
}

(** {1 Positions} *)

val position : file:string -> line:int -> column:int -> offset:int -> position
val start_of_file : string -> position

val compare_position : position -> position -> int
(** Orders by [file], then [offset]. Positions in different files are ordered by
    file name so that sorting is total; the ordering across files is arbitrary. *)

val equal_position : position -> position -> bool
val string_of_position : position -> string

(** {1 Spans} *)

val make : start:position -> stop:position -> t
(** A source-written span. Use {!generated} to mark a span as emitted. *)

val point : position -> t
(** The empty span at [position], used for zero-width diagnostics. *)

val unknown : t
(** Placeholder for nodes with no known location. Constructing Core with
    [unknown] is allowed but a phase that can supply a real span must. *)

val is_unknown : t -> bool
val file : t -> string

val join : t -> t -> t
(** [join a b] is the smallest span covering both. Unknown spans are absorbed. If
    the two spans come from different files, [a] wins, because a cross-file join
    means one of the nodes was expanded from elsewhere and [a] is by convention
    the node being built. The result is generated if either input is; the left
    origin is preferred so that the nearest enclosing generator is reported. *)

(** {1 Provenance} *)

val generated : by:string -> from:t -> t
(** Mark a node as produced by phase [by] out of the code at [from]. The
    positions are inherited from [from], so errors still point at user text. *)

val is_generated : t -> bool

val source_span : t -> t
(** Strip every generated layer, yielding the underlying human-written span. For
    a [Source] span this is the identity. *)

val generators : t -> string list
(** Phase names from the outermost generator inward; [[]] for source spans. *)

(** {1 Comparison and printing} *)

val equal : t -> t -> bool
(** Structural equality including provenance. Semantic comparisons of Core must
    not use this: spans are metadata, not meaning. *)

val compare : t -> t -> int
val to_string : t -> string
val pp : Format.formatter -> t -> unit
