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

## Status

Research prototype, complete. The implementation plan in [`to-do.md`](to-do.md)
is fully checked through Phase 11 plus a post-release review-repair pass, the
full test suite is green, and every published number reproduces from the
commands below. Start with [`docs/evaluation.md`](docs/evaluation.md) for what
was found — including the limits and what is explicitly not claimed.

## What it looks like

```ash
fn fact(n) = if n <= 1 then 1 else n * fact(n - 1)
```

```ash
fn fib(n) = if n < 2 then n else fib(n - 1) + fib(n - 2)

up {
  let base = eval
  eval := fn(e, r, k) -> { println(head(code_view(e))); base(e, r, k) }
}
fib(3)   # prints one line per evaluated node as it runs
```

The second program replaces the evaluator running it and traces every step of
`fib(3)`. That is reflection on the language's own implementation, from inside
the language. (This is the essence of `examples/tracing.ash`; run it with
`--demo tracing` below.)

## Requirements

- OCaml 5.2 or newer, Dune 3.16 or newer, opam (recommended)
- Python 3, for the measurement script only

Tested with OCaml 5.4.1, Dune 3.24.2, opam 2.5.2, Python 3.14.7 on Linux
x86_64. The measurement data also pins these versions per run (see
`docs/progress/phase10-measurements.json`).

If you have opam:

```sh
opam switch create . --deps-only ocaml-base-compiler.5.2.0   # or newer
eval $(opam env)
```

## Reproduce everything

Every command below runs inside your active opam switch, from the repository
root. This sequence is the release check: start clean, then verify each layer.

```sh
rm -rf _build
opam exec -- dune build @fmt        # formatting gate (normalizes dune files)
opam exec -- dune build @all        # compile from scratch
opam exec -- dune runtest --force   # full suite: unit, differential, laws, goldens
```

Milestone 1 — the tower is real: a program replaces the evaluator running it,
and the replacement intercepts every nested step:

```sh
opam exec -- dune exec ash -- --demo tracing            # trace every node
opam exec -- dune exec ash -- --demo level-2-counting   # an interpreter running an interpreter
```

Milestone 2 — the interpretation is removable, and the removal is measured:

```sh
opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1
```

It prints three runs of the same program — ground, interpreted under the tower,
and the specialized residual — plus counts of any interpreter machinery that
survived into the residual. The reflection-meets-collapse demo keeps Fibonacci
recursive while inlining a known tracing evaluator into it:

```sh
opam exec -- dune exec ash -- --collapse examples/traced_fibonacci.ash --depth 1 --show-residual
opam exec -- dune exec ash -- --demo traced-fibonacci   # the unescaped trace
```

The classification — all four collapse classes, reproduced by one command:

```sh
python3 scripts/measure_phase10.py   # rewrites docs/progress/phase10-measurements.json
```

It runs the five `examples/classification_*.ash` programs at depths 0–3
(twenty tower/residual pairs, all agreeing on value and exact output) and
records sizes, steps, ratios, and the conservative class of each. Spot-check
one by hand:

```sh
opam exec -- dune exec ash -- --collapse examples/classification_partial.ash --depth 1
opam exec -- dune exec ash -- --collapse examples/classification_partial.ash --depth 1 --json
```

A tiny taste of the surface language (see `examples/`):

```ash
fn power(n, x) =
  if n == 0 then `{ 1 }
  else `{ ${x} * ${power(n - 1, x)} }

let pow5 = `{ fn(y) -> ${power(5, `{ y })} }
run(pow5)(2)   # 32 — built code, then executed
```

## Where to go next

| Document | What it is |
|----------|------------|
| [Ash Reflective Tower.md](Ash%20Reflective%20Tower.md) | The design spec — semantics, tower protocol, staging rules, measured claims |
| [docs/semantics.md](docs/semantics.md) | What a program means, as built: hygiene through classification |
| [docs/implementation.md](docs/implementation.md) | Where everything lives: modules, CLI, tests, common tasks |
| [docs/evaluation.md](docs/evaluation.md) | The research result: four classes, depth numbers, residue, limits, claims |
| [docs/decisions/](docs/decisions/) | Numbered architecture decisions (ADRs 0001–0042) |
| [docs/progress/](docs/progress/) | Depth-cost baseline, demo index, pinned measurement data |
| [to-do.md](to-do.md) | The implementation plan and session state |
| [AGENTS.md](AGENTS.md) | AI-agent guidance, build invariants — start here before changing code |

## License

MIT — see [LICENSE](LICENSE).
