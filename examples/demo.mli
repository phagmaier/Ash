(** The packaged tower demos (to-do task 4.5).

    Two programs, both written in Ash and both stored as `.ash` source next to
    this module: the §5.3 trace, in which a program replaces the evaluator that
    is running it, and the §5.6 level-2 count, in which one meta level measures
    the work another does. They are the milestone-1 evidence, so they are
    packaged rather than left as prose: the CLI runs them and a golden test pins
    what they print.

    A demo runs on its own tower over a buffered {!Ash_runtime.Io} stream, so its
    trace is a value. {!report_to_string} is the single renderer both the CLI and
    the golden test use, which is what stops expected output from drifting away
    from actual output. *)

open Ash_core

type t = { name : string; title : string; source : string }

val all : t list
val names : string list
val find : string -> t option

type outcome = Answered of Value.value | Failed of Error.t

type report = {
  demo : t;
  output : string list;
      (** The lines that appeared on the stream, in order. *)
  outcome : outcome;
  materialized : int;
}

val run : t -> report
val report_to_string : report -> string
