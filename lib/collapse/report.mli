(** The human collapse report of spec §9.4.

    One renderer, used by the CLI and by the golden test, so what is pinned is
    what a reader sees. Everything printed here is a counter or an AST walk, and
    every figure is reproducible: nothing in the output depends on wall time,
    host stack depth, allocation order, or heap layout — the four channels §D9
    excludes from Ash's claims, plus the one (heap words) that varies with the
    OCaml runtime rather than with the program. {!Metrics.t} still carries the
    heap measurement for the measurement suite that reports it with its
    environment pinned (task 10.4). *)

val to_string : Metrics.t -> string
