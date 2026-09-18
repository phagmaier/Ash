(** The human collapse report of spec §9.4.

    One renderer, used by the CLI and by the golden test, so what is pinned is
    what a reader sees. Everything printed here is a counter or an AST walk, and
    every figure is reproducible: nothing in the output depends on wall time,
    host stack depth, allocation order, or heap layout — the four channels §D9
    excludes from Ash's claims, plus the one (heap words) that varies with the
    OCaml runtime rather than with the program. {!Metrics.t} still carries the
    heap measurement for the version-pinned measurement suite. *)

val to_string : ?show_residual:bool -> Metrics.t -> string
(** [show_residual] includes canonical residual Core and exact escaped output
    bytes. The default keeps the compact report used by existing examples. *)

val to_json : Metrics.t -> string
(** One JSON object containing raw sizes, steps, classification, residue cases
    and sites, reasons, and outcomes. No host-specific formatting is applied to
    numbers. *)
