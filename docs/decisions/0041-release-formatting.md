# 0041 — Release keeps hand formatting; no ocamlformat gate

- **Status:** accepted
- **Date:** 2026-09-18
- **Tasks:** 11.3
- **Builds on:** 0001

## Context

Task 11.3 asks for a formatting step in the release sequence. The project has
no `.ocamlformat` file, so `dune build @fmt` passes trivially (ocamlformat
disables itself per file with a warning). The question is whether the release
should pin a formatter configuration and reformat the tree to satisfy it.

## Decision

Keep the hand-maintained formatting style for OCaml sources; do not add an
`.ocamlformat` configuration. The release formatting step is `opam exec --
dune fmt` followed by `opam exec -- dune build @fmt`, which must exit 0.
`dune fmt` normalizes `dune` files (four needed it at release time, all
mechanically) and leaves `.ml`/`.mli` files alone, since ocamlformat disables
itself per file without a configuration to follow.

## Limits

Measured before deciding: pinning `profile = default, version = 0.29.0` in a
scratch copy of the tree and running `dune fmt` changes ~9,400 lines across
~130 files, dominated by rewrapping documentation comments in every `.mli`.
Those comments are load-bearing project documentation (interface contracts
the law suite is written against), laid out for 80-column reading across
forty tasks. Reformatting buys a mechanical gate at the price of churning
every file in the release. If a future task wants a real gate, it must first
find settings under which the format diff is small enough to review — the
scratch measurement above is the baseline to beat — and take the reformat as
its own change, not as release hygiene.

## Evidence

`opam exec -- dune build @fmt` exits 0 on the release tree. The scratch
measurement (`git archive HEAD` plus a default-profile `.ocamlformat`,
formatted with Dune 3.24.2 / ocamlformat 0.29.0) is reproducible from any
clean checkout and was discarded, not committed.
