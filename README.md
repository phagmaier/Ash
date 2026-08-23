# Ash

Ash is a small hygienic language with a CPS self-interpreter, a lazily
materialized reflective tower, and a staged partial evaluator that explains where
interpreter behavior can and cannot be erased.

The detailed design is in [`Ash Reflective Tower.md`](Ash%20Reflective%20Tower.md),
and the ordered implementation plan is in [`to-do.md`](to-do.md).

## Requirements

- OCaml 5.2 or newer
- Dune 3.16 or newer
- opam is recommended for managing the toolchain

The currently verified development environment uses OCaml 5.4.1 and Dune 3.24.2.

## Build and test

Run commands inside the active opam switch:

```sh
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune exec ash -- --help
```

The CLI is only a bootstrap shell at present. Follow the first unchecked task in
`to-do.md` to continue implementation.

## Development workflow

Read `AGENTS.md` before changing code. At the end of each completed task, update
the checklist's Current state and Handoff log so a later session can resume from
the single prompt `continue`.
