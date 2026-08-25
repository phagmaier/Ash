# Ash

Ash is a small programming language with a superpower: programs can reach up and
replace the very machinery that is running them. It is a hygienic language with a
self-interpreter written in itself, a *reflective tower* that materializes one
interpreter level at a time only when a program actually asks for one, and a
*staged collapser* — a partial evaluator that removes interpretation where it
can, and explains precisely where it cannot.

The interesting question Ash answers is not "how fast is the compiled code?" but
"where does reflection end and compilation begin?" Its collapse report shows, for
a given program, what the interpreter did beside what survives in the residual
program — measured, not asserted.

## What it looks like

```ash
fn fact(n) = if n <= 1 then 1 else n * fact(n - 1)
```

```ash
up {
  let base = eval
  eval := fn(e, r, k) -> { print(show(e)); base(e, r, k) }
}
fib(3)   # prints one line per evaluated node as it runs
```

The second program replaces the evaluator running it and traces every step of
`fib(3)` — 59 lines of output for a five-line program. That is reflection on the
language's own implementation, from inside the language.

Two packaged demos show this working:

```sh
opam exec -- dune exec ash -- --demo tracing            # trace every node
opam exec -- dune exec ash -- --demo level-2-counting   # an interpreter running an interpreter
```

## Requirements

- OCaml 5.2 or newer
- Dune 3.16 or newer
- opam (recommended) to manage the toolchain

If you have opam:

```sh
opam switch create . --deps-only ocaml-base-compiler.5.2.0   # or newer
eval $(opam env)
```

## Quickstart

Run everything inside your active opam switch:

```sh
opam exec -- dune build @all          # compile
opam exec -- dune runtest             # run the full test suite
opam exec -- dune exec ash -- --help  # see what the CLI can do
```

To watch specialization at work, run the collapse report:

```sh
opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1
```

It prints three runs of the same program — ground, interpreted under the tower,
and the specialized residual — plus counts of any interpreter machinery that
survived into the residual.

A tiny taste of the surface language (see `examples/`):

```ash
fn power(n, x) =
  if n == 0 then `{ 1 }
  else `{ ${x} * ${power(n - 1, x)} }

let pow5 = `{ fn(y) -> ${power(5, `{ y })} }
run(pow5)(2)   # 32 — built code, then executed
```

## Where to go next

**For Developers:** all AI-agent guidance, build invariants, architecture
decisions, and the implementation plan live in [`AGENTS.md`](AGENTS.md).
Start there before changing code.

The full design — semantics, the tower protocol, staging rules, and the measured
claims — is in [`Ash Reflective Tower.md`](Ash%20Reflective%20Tower.md), and the
ordered implementation plan is in [`to-do.md`](to-do.md).
