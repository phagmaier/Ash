# 0001 — What one level of the tower costs

- **Date:** 2026-08-23
- **Task:** 4.4 (the depth harness the law suite runs on)
- **Reproduce:** the snippet at the end of this file, or the two artifacts the
  suite already keeps current: `test/golden/demos.expected`, which pins the
  level-2 count, and the coverage line `dune runtest` prints for
  `test/laws/tower_laws_test.ml`.

## What was measured

`Ash_tower.Depth.materialize` interposes an Ash interpreter —
`fn(e, r, k) -> base(e, r, k)`, semantically the identity — at every level below
a stated depth, so that each step of level *n* is a term level *n+1* must
evaluate. The table below is, for each depth: the value, the evaluator calls
level 0 makes, the evaluator calls the top level makes, and the ratio to the
level beneath it.

`1 + 1`

| depth | value | level-0 steps | top-level steps | ratio |
|---|---|---|---|---|
| 0 | 2 | 8 | 8 | — |
| 1 | 2 | 8 | 48 | 6.00x |
| 2 | 2 | 8 | 236 | 4.91x |
| 3 | 2 | 8 | 1180 | 5.00x |
| 4 | 2 | 8 | 5900 | 5.00x |
| 5 | 2 | 8 | 29500 | 5.00x |

`fn fact(n) = if n == 0 then 1 else n * fact(n - 1); fact(5)`

| depth | value | level-0 steps | top-level steps | ratio |
|---|---|---|---|---|
| 0 | 120 | 162 | 162 | — |
| 1 | 120 | 162 | 960 | 5.92x |
| 2 | 120 | 162 | 4720 | 4.91x |
| 3 | 120 | 162 | 23600 | 5.00x |
| 4 | 120 | 162 | 118000 | 5.00x |
| 5 | 120 | 162 | 590000 | 5.00x |

`fn count(n) = if n == 0 then 0 else count(n - 1); count(200)` (tail recursive)

| depth | value | level-0 steps | top-level steps | ratio |
|---|---|---|---|---|
| 0 | 0 | 4417 | 4417 | — |
| 1 | 0 | 4417 | 26520 | 6.00x |
| 2 | 0 | 4417 | 130390 | 4.91x |
| 3 | 0 | 4417 | 651950 | 5.00x |
| 4 | 0 | 4417 | 3259750 | 5.00x |
| 5 | 0 | 4417 | 16298750 | 5.00x |

## What it says

**The level-0 step count does not change with depth.** 8, 162, and 4417 are the
same at depth 0 and at depth 5. Interposing an interpreter changes who performs
the base program's steps, not how many there are. This is asserted, not just
observed: `tower_laws_test.ml` compares it for every program in the corpus.

**One level costs a factor of five, and the factor is flat.** After the first
level the ratio is 5.00x at every depth and for every program measured, so the
cost is `steps × 5^depth`. The first level reads 5.92–6.00x and the second
4.91x; the difference is the fixed setup of the first interposition amortized
over a small program, not a different per-level cost.

A flat multiplier is worth stating carefully, because §9 of the spec explicitly
deletes Revision 1's claim of a constant per-level factor and warns that Amin &
Rompf's own benchmarks show no uniform ratio between depths. Nothing here
contradicts that. The interposed interpreter is the *smallest possible* one —
three parameters forwarded to a primitive, with no dispatch of its own — so five
is a floor for this implementation, not a prediction about interpreters that do
real work. The Ash self-interpreter is a much larger program and would not give
this number. What the flatness does establish is that the harness itself
contributes no depth-dependent surprise, which is what a law suite running at
depths 0–5 needs from it.

**The tower stays within a constant host stack.** `count(200)` is tail recursive
and runs at depth 5, doing 16.3 million evaluator calls through five stacked
interpreters, without overflowing. That is the CPS design of ADR 0008 and the
reason ADR 0023 refused to attribute levels by wrapping each one in a host
exception handler.

**Depth 5 is affordable.** The slowest row above takes about 0.45 s. The law
suite's whole transparency pass — 96 programs at six depths — runs in under a
second, and only one corpus program (a 310 019-step loop) exceeds the budget,
at depth 3.

## Why this is the measurement the collapser has to beat

`fact(5)` is 162 steps of program. Under one level it is 960 steps of machinery
to perform those 162, and under five it is 590 000. None of that is observable to
the program: the value is 120 at every depth, and `tower_laws_test.ml` checks
that every effect is identical too. A cost that large and that invisible is
exactly what a staged collapser is for, and Phase 5's criterion — zero surviving
Core dispatch and zero surviving eval-cell dereferences on pure depth-1 samples —
is the claim that it can be removed entirely for the fragment where it can.

## Snippet

Drop this in `spike/spike.ml` with
`(executable (name spike) (libraries ash.core ash.syntax ash.runtime ash.tower))`
in `spike/dune`, then `dune exec ./spike/spike.exe`.

```ocaml
open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_tower

let () =
  List.iter
    (fun (name, source) ->
      Printf.printf "\n%s\n" name;
      let previous = ref 0 in
      for depth = 0 to 5 do
        let tower = Tower.create ~registry:(Primitives.create ~io:(Io.create ()) ()) () in
        let named =
          Ident.Set.fold (fun i acc -> (Ident.name i, i) :: acc)
            (Env.idents (Level.global (Tower.ground tower))) [] in
        let term = Desugar.program ~scope:(Desugar.scope_of_globals named)
            (Parser.program ~file:"m.ash" source) in
        let value = Depth.run tower ~depth term in
        let steps level = match Tower.find_level tower level with
          | Some l -> Machine.steps (Level.machine l) | None -> 0 in
        let top = steps depth in
        Printf.printf "  | %d | %s | %d | %d | %s |\n" depth (Value.to_string value)
          (steps 0) top
          (if depth = 0 then "—" else Printf.sprintf "%d.%02dx" (top / !previous) (top * 100 / !previous mod 100));
        previous := top
      done)
    [ ("`1 + 1`", "1 + 1");
      ("`fact(5)`", "fn fact(n) = if n == 0 then 1 else n * fact(n - 1)\nfact(5)");
      ("`count(200)` (tail recursive)", "fn count(n) = if n == 0 then 0 else count(n - 1)\ncount(200)") ]
```
